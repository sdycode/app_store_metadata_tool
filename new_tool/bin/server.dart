import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asc_upload_tool/services/logging.dart';
import 'package:asc_upload_tool/services/orchestrator.dart';
import 'package:asc_upload_tool/services/workspace.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

const int kDefaultPort = 3000;

/// Global server state — one workspace + orchestrator at a time (local tool).
OrchestratorRuntime? _runtime;
Orchestrator? _orch;
Future<void>? _activeTask;
int _boundPort = kDefaultPort;

Future<void> main(List<String> args) async {
  final webDir = _locateWebDir();
  final preferredPort = _resolvePort(args);
  // Bind on IPv6 with v6Only=false so the same socket accepts BOTH IPv6
  // (::1) and IPv4 (127.0.0.1) loopback. Firefox resolves `localhost` to
  // ::1 first, and a server bound only to 127.0.0.1 will intermittently
  // appear unreachable ("Failed to fetch"). Binding dual-stack fixes it.
  final server = await _bindServer(preferredPort);
  _boundPort = server.port;
  server.autoCompress = true;
  print('ASC upload tool listening on http://localhost:$_boundPort');

  // Auto-open browser (macOS/Linux/Windows best-effort).
  unawaited(_openBrowser('http://localhost:$_boundPort'));

  await for (final req in server) {
    unawaited(_handle(req, webDir));
  }
}

int _resolvePort(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--port' && i + 1 < args.length) {
      return int.tryParse(args[i + 1]) ?? kDefaultPort;
    }
    if (arg.startsWith('--port=')) {
      return int.tryParse(arg.substring('--port='.length)) ?? kDefaultPort;
    }
  }
  return int.tryParse(Platform.environment['PORT'] ?? '') ?? kDefaultPort;
}

Future<HttpServer> _bindServer(int preferredPort) async {
  SocketException? lastError;
  for (var offset = 0; offset <= 20; offset++) {
    final port = preferredPort + offset;
    try {
      return await HttpServer.bind(
        InternetAddress.anyIPv6,
        port,
        v6Only: false,
      );
    } on SocketException catch (e) {
      lastError = e;
    }
  }
  throw StateError(
      'Could not bind ports $preferredPort-${preferredPort + 20}: $lastError');
}

Directory _locateWebDir() {
  // Resolve in several ways so the same code path works for:
  //   - `dart run bin/server.dart` (cwd = package root)
  //   - compiled `./asc-server` launched via double-click (cwd = ~)
  //   - compiled `./asc-server` launched from elsewhere
  // `Platform.resolvedExecutable` is the Dart VM or the compiled binary;
  // its parent dir is where we placed `web/` alongside the exe.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final scriptDir = File.fromUri(Platform.script).parent.path;
  final candidates = [
    Directory(p.join(Directory.current.path, 'web')),
    Directory(p.join(Directory.current.path, 'new_tool', 'web')),
    Directory(p.join(exeDir, 'web')),
    Directory(p.join(exeDir, '..', 'web')),
    Directory(p.join(scriptDir, 'web')),
    Directory(p.join(scriptDir, '..', 'web')),
  ];
  for (final d in candidates) {
    if (d.existsSync()) return d;
  }
  throw StateError(
      'Could not locate web/ directory. Run from new_tool/ with: dart run bin/server.dart');
}

Future<void> _handle(HttpRequest req, Directory webDir) async {
  try {
    _applyCors(req.response);
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }
    final path = req.uri.path;
    if (req.method == 'GET') {
      if (path == '/' || path == '/index.html') {
        // Serve index.html with cache-busting query strings on asset refs.
        // A fresh token per request guarantees the browser fetches new JS/CSS
        // even if it ignored Cache-Control, has a stale ServiceWorker, or
        // was opened in a tab that cached the previous server's response.
        final html =
            await File(p.join(webDir.path, 'index.html')).readAsString();
        final v = DateTime.now().microsecondsSinceEpoch.toString();
        final patched = html
            .replaceAll('href="/style.css"', 'href="/style.css?v=$v"')
            .replaceAll('src="/app.js"', 'src="/app.js?v=$v"')
            // Inject a visible build badge so you can verify which response
            // the browser rendered. If the on-screen token matches what the
            // terminal logs below, you're on fresh code. If not → cache.
            .replaceAll(
                '<body>', '<body>\n<div id="build-badge">build $v</div>');
        LoggingService.instance
            .info('Served / with build token $v', scope: 'server');
        _writeStatic(req, 'text/html', patched);
        return;
      }
      if (path == '/app.js') {
        await _serveFile(
            req, File(p.join(webDir.path, 'app.js')), 'application/javascript');
        return;
      }
      if (path == '/style.css') {
        await _serveFile(
            req, File(p.join(webDir.path, 'style.css')), 'text/css');
        return;
      }
      if (path == '/health') {
        await _json(req, {
          'ok': true,
          'port': _boundPort,
          'ts': DateTime.now().toIso8601String()
        });
        return;
      }
      if (path == '/logs') {
        final since =
            int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
        final entries = LoggingService.instance
            .since(since)
            .map((e) => e.toJson())
            .toList();
        await _json(req, {
          'entries': entries,
          'total': LoggingService.instance.entries.length,
        });
        return;
      }
      if (path == '/status') {
        await _json(req, _statusSnapshot());
        return;
      }
    }

    if (req.method == 'POST') {
      switch (path) {
        case '/upload':
          await _handleUpload(req);
          return;
        case '/locales':
          await _handleSetLocales(req);
          return;
        case '/options':
          await _handleSetOptions(req);
          return;
        case '/action/check-auth':
          await _runAction(req, 'Check Auth', () async {
            await _orch!.checkAuth();
          });
          return;
        case '/action/validate':
          await _runSyncAction(req, 'Validate', () {
            final r = _orch!.r.validator.run(_orch!.r.workspace);
            LoggingService.instance.info(
                'Validation: ${jsonEncode(r.toJson())}',
                scope: 'validate');
          });
          return;
        case '/action/upload-metadata':
          await _runAction(req, 'Upload Metadata', _orch!.uploadMetadata);
          return;
        case '/action/upload-screenshots':
          await _runAction(req, 'Upload Screenshots', _orch!.uploadScreenshots);
          return;
        case '/action/upload-ipad-screenshots':
          await _runAction(req, 'Upload iPad Screenshots',
              _orch!.uploadIpadScreenshots);
          return;
        case '/action/upload-iap':
          await _runAction(req, 'Upload IAP', _orch!.uploadIap);
          return;
        case '/action/upload-all':
          await _runAction(req, 'Upload All', _orch!.uploadAll);
          return;
        case '/action/update-name':
          await _runAction(req, 'Update Name', _orch!.updateAppName);
          return;
        case '/action/update-description':
          await _runAction(req, 'Update Description', _orch!.updateDescription);
          return;
        case '/action/update-keywords':
          await _runAction(req, 'Update Keywords', _orch!.updateKeywords);
          return;
        case '/action/update-subtitle':
          await _runAction(req, 'Update Subtitle', _orch!.updateSubtitle);
          return;
        case '/action/update-release-notes':
          await _runAction(
              req, 'Update Release Notes', _orch!.updateReleaseNotes);
          return;
        case '/action/update-marketing-url':
          await _runAction(
              req, 'Update Marketing URL', _orch!.updateMarketingUrl);
          return;
        case '/action/update-support-url':
          await _runAction(req, 'Update Support URL', _orch!.updateSupportUrl);
          return;
        case '/action/update-privacy-url':
          await _runAction(req, 'Update Privacy URL', _orch!.updatePrivacyUrl);
          return;
        case '/action/update-copyright':
          await _runAction(req, 'Update Copyright', _orch!.updateCopyright);
          return;
        case '/action/update-review-notes':
          await _runAction(
              req, 'Update App Review Notes', _orch!.updateReviewNotes);
          return;
        case '/action/update-category':
          await _runAction(
              req, 'Update Category', _orch!.updatePrimaryCategory);
          return;
        case '/action/update-age-rating':
          await _runAction(
              req, 'Set Age Rating (lowest → 4+)', _orch!.updateAgeRating);
          return;
        case '/action/check-status':
          await _runAction(req, 'Check Status', () async {
            final report = await _orch!.checkStatus();
            LoggingService.instance.info(
                'Status:\n${const JsonEncoder.withIndent('  ').convert(report)}',
                scope: 'status');
          });
          return;
        case '/action/check-screenshots':
          await _runAction(req, 'Check Screenshots', () async {
            final report = await _orch!.checkScreenshots();
            _logJsonReport('Screenshot ASC report', report, scope: 'check-ss');
          });
          return;
        case '/action/check-ipad-screenshots':
          await _runAction(req, 'Check iPad Screenshots', () async {
            final report = await _orch!.checkIpadScreenshots();
            _logJsonReport('iPad screenshot ASC report', report,
                scope: 'check-ipad-ss');
          });
          return;
        case '/action/check-metadata-all':
          await _runAction(req, 'Check All Metadata', () async {
            final report = await _orch!.checkMetadata();
            _logJsonReport('Metadata ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-name':
          await _runAction(req, 'Check Name', () async {
            final report = await _orch!.checkMetadata(fields: {'name'});
            _logJsonReport('Name ASC report', report, scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-description':
          await _runAction(req, 'Check Description', () async {
            final report = await _orch!.checkMetadata(fields: {'description'});
            _logJsonReport('Description ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-keywords':
          await _runAction(req, 'Check Keywords', () async {
            final report = await _orch!.checkMetadata(fields: {'keywords'});
            _logJsonReport('Keywords ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-subtitle':
          await _runAction(req, 'Check Subtitle', () async {
            final report = await _orch!.checkMetadata(fields: {'subtitle'});
            _logJsonReport('Subtitle ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-release-notes':
          await _runAction(req, 'Check Release Notes', () async {
            final report =
                await _orch!.checkMetadata(fields: {'release-notes'});
            _logJsonReport('Release Notes ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-marketing-url':
          await _runAction(req, 'Check Marketing URL', () async {
            final report =
                await _orch!.checkMetadata(fields: {'marketing-url'});
            _logJsonReport('Marketing URL ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-support-url':
          await _runAction(req, 'Check Support URL', () async {
            final report = await _orch!.checkMetadata(fields: {'support-url'});
            _logJsonReport('Support URL ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-privacy-url':
          await _runAction(req, 'Check Privacy URL', () async {
            final report = await _orch!.checkMetadata(fields: {'privacy-url'});
            _logJsonReport('Privacy URL ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-copyright':
          await _runAction(req, 'Check Copyright', () async {
            final report = await _orch!.checkMetadata(fields: {'copyright'});
            _logJsonReport('Copyright ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-metadata-category':
          await _runAction(req, 'Check Category', () async {
            final report = await _orch!.checkMetadata(fields: {'category'});
            _logJsonReport('Category ASC report', report,
                scope: 'metadata-check');
          });
          return;
        case '/action/check-app-names':
          await _runAction(req, 'Check App Name Availability', () async {
            await _orch!.checkAppNames();
          });
          return;
        case '/action/pause':
          _orch?.control.pause();
          await _json(req, _statusSnapshot());
          return;
        case '/action/resume':
          _orch?.control.resume();
          await _json(req, _statusSnapshot());
          return;
        case '/action/cancel':
          _orch?.control.cancel();
          await _json(req, _statusSnapshot());
          return;
        case '/action/clear-logs':
          LoggingService.instance.clear();
          await _json(req, {'ok': true});
          return;
      }
    }

    req.response.statusCode = 404;
    req.response.write('Not Found: ${req.method} $path');
    await req.response.close();
  } catch (e, st) {
    LoggingService.instance.error('Request failed: $e', scope: 'server');
    print(st);
    try {
      req.response.statusCode = 500;
      req.response.write('Server error: $e');
      await req.response.close();
    } catch (_) {}
  }
}

/// For every active locale, returns the length of the keyword string
/// we would actually PATCH to Apple — i.e. the locale's own value if
/// keywords.json has it, else the default-language fallback.
Map<String, int> _effectiveKeywordLengths() {
  final orch = _orch;
  if (orch == null) return const {};
  final ws = orch.r.workspace;
  final fallback = ws.config.defaultLanguage;
  final fb = ws.keywords[fallback] ?? '';
  final out = <String, int>{};
  for (final locale in orch.activeLocaleSet) {
    final own = ws.keywords[locale];
    out[locale] = (own ?? fb).length;
  }
  return out;
}

/// Per-text-field list of locales missing their own translation — those
/// will upload using the default-language fallback value. Surfaces as a
/// non-blocking warning in the UI so the user knows.
Map<String, List<String>> _fallbackUsage() {
  final orch = _orch;
  if (orch == null) return const {};
  final ws = orch.r.workspace;
  final missing = <String, List<String>>{
    'description': [],
    'keywords': [],
    'subtitle': [],
    'releasenotes': [],
  };
  for (final locale in orch.activeLocaleSet) {
    if (!ws.descriptions.containsKey(locale)) {
      missing['description']!.add(locale);
    }
    if (!ws.keywords.containsKey(locale)) missing['keywords']!.add(locale);
    if (!ws.subtitles.containsKey(locale)) missing['subtitle']!.add(locale);
    if (!ws.releaseNotes.containsKey(locale)) {
      missing['releasenotes']!.add(locale);
    }
  }
  return missing;
}

/// Builds a compact summary of everything the tool will push — shown at
/// the top of the log panel so the user can eyeball the payload before
/// clicking Upload. en-US values are used for preview fields.
Map<String, dynamic> _extractedSummary(Workspace ws) {
  final meta = ws.config.metadata;
  final def = ws.config.defaultLanguage;
  String? pick(Map<String, String> m) => m['en-US'] ?? m[def];
  final iaps = (ws.config.inApp?.iapMetadata ?? const [])
      .map((iap) => {
            'product_id': iap.productId,
            'reference_name': iap.referenceName,
            'purchase_type': iap.purchaseType,
            'family_sharable': iap.familySharable,
            'price_point': iap.pricing?.pricePoint ?? '',
            'territory': iap.pricing?.territory ?? '',
            'localizations': iap.localizations
                .map((l) => {'locale': l.locale, 'name': l.name})
                .toList(),
            'review_notes': iap.reviewNotes,
          })
      .toList();
  return {
    'name': meta.name ?? '',
    'package_id': meta.packageId,
    'app_id': meta.appId,
    'email': meta.email ?? '',
    'primary_category': meta.primaryCategory ?? '',
    'copyright': meta.copyright ?? '',
    'update_version': meta.updateVersion,
    'urls': {
      'marketing': meta.marketingUrl ?? '',
      'support': meta.supportUrl ?? '',
      'privacy': meta.privacyUrl ?? '',
    },
    // en-US previews of each text field (empty string if neither en-US nor
    // default_language has it).
    'en_us': {
      'description': pick(ws.descriptions) ?? '',
      'keywords': pick(ws.keywords) ?? '',
      'subtitle': pick(ws.subtitles) ?? '',
      'release_notes': pick(ws.releaseNotes) ?? '',
    },
    // App Review notes are version-level free text (one value for every
    // locale), so they sit outside the per-locale `en_us` preview.
    'review_notes': ws.reviewNotes,
    'review_notes_limit': kReviewNotesMaxLength,
    'json_syntax_errors':
        ws.jsonSyntaxErrors.map((issue) => issue.toJson()).toList(),
    'iap_count': iaps.length,
    'iaps': iaps,
    'review_image_path': ws.config.inApp?.reviewImagePath ?? '',
  };
}

Map<String, dynamic> _statusSnapshot() {
  final ws = _orch?.r.workspace;
  return {
    'workspace': ws == null
        ? null
        : {
            'root': ws.root.path,
            'bundleId': ws.config.metadata.packageId,
            'appId': ws.config.metadata.appId,
            'updateVersion': ws.config.metadata.updateVersion,
            'localizations': ws.config.localizations,
            'iapCount': ws.config.inApp?.iapMetadata.length ?? 0,
            'keyFile': ws.p8Key.path,
            'warnings': ws.warnings,
            'jsonSyntaxErrors':
                ws.jsonSyntaxErrors.map((issue) => issue.toJson()).toList(),
          },
    'control': _orch?.control.toJson() ?? {'active': false},
    'selectedLocales': _orch?.selectedLocales.toList() ?? const [],
    'activeLocaleSet': _orch?.activeLocaleSet ?? const [],
    'activeLocaleSetName': _orch?.activeLocaleSetName ?? '15',
    'configLocaleCount': ws?.config.localizations.length ?? 0,
    // Raw per-file lengths (diagnostics only; UI prefers `effectiveKeywordLengths`).
    'keywordLengths': ws == null
        ? const <String, int>{}
        : ws.keywords.map((k, v) => MapEntry(k, v.length)),
    // For every active locale, the length of what we'll actually send to
    // Apple — the locale's own value if present, else the default-language
    // fallback. This is what the upload payload will be, so validation
    // against Apple's 100-char keyword limit must use these numbers.
    'effectiveKeywordLengths': _effectiveKeywordLengths(),
    // Per-field list of locales that DO NOT have their own translation
    // and will use the default-language fallback instead. Non-blocking
    // info for the UI to warn about.
    'fallbackUsage': _fallbackUsage(),
    'defaultLanguage': ws?.config.defaultLanguage ?? 'en-US',
    // Human-readable summary of what's extracted from the workspace — used
    // by the "Extracted details" card at the top of the log panel so the
    // user can eyeball exactly what the tool will push before clicking any
    // upload button.
    'extracted': ws == null ? null : _extractedSummary(ws),
    'forcefulReplace': _orch?.forcefulReplace ?? true,
    'replaceOnMismatch': _orch?.replaceOnMismatch ?? true,
    'forcefulIndividualUpdate': _orch?.forcefulIndividualUpdate ?? false,
    'liveUpdateMode': _orch?.liveUpdateMode ?? false,
  };
}

Future<void> _runAction(
    HttpRequest req, String label, Future<void> Function() body) async {
  if (_orch == null) {
    req.response.statusCode = 400;
    req.response.write('No workspace loaded. Upload a folder first.');
    await req.response.close();
    return;
  }
  if (_activeTask != null) {
    req.response.statusCode = 409;
    req.response.write('An action is already running.');
    await req.response.close();
    return;
  }
  final completer = Completer<void>();
  _activeTask = completer.future;
  // Respond immediately; the UI polls /logs and /status.
  await _json(req, {'started': true, 'action': label});
  try {
    LoggingService.instance.info('▶ $label', scope: 'server');
    await _orch!.runGuarded(label, body);
    LoggingService.instance.success('✓ $label complete', scope: 'server');
  } catch (e) {
    LoggingService.instance.error('$label failed: $e', scope: 'server');
  } finally {
    _activeTask = null;
    completer.complete();
  }
}

Future<void> _runSyncAction(
    HttpRequest req, String label, void Function() body) async {
  if (_orch == null) {
    req.response.statusCode = 400;
    req.response.write('No workspace loaded. Upload a folder first.');
    await req.response.close();
    return;
  }
  try {
    LoggingService.instance.info('▶ $label', scope: 'server');
    body();
    LoggingService.instance.success('✓ $label complete', scope: 'server');
    await _json(req, {'ok': true});
  } catch (e) {
    LoggingService.instance.error('$label failed: $e', scope: 'server');
    req.response.statusCode = 500;
    req.response.write('$e');
    await req.response.close();
  }
}

void _logJsonReport(String title, Map<String, dynamic> report,
    {required String scope}) {
  LoggingService.instance.info(
      '$title:\n${const JsonEncoder.withIndent('  ').convert(report)}',
      scope: scope);
}

Future<void> _handleSetLocales(HttpRequest req) async {
  if (_orch == null) {
    req.response.statusCode = 400;
    req.response.write('No workspace loaded');
    await req.response.close();
    return;
  }
  final body = await utf8.decodeStream(req);
  final data = jsonDecode(body) as Map<String, dynamic>;
  final list = (data['locales'] as List).map((e) => e.toString()).toSet();
  _orch!.selectedLocales = list;
  await _json(req, _statusSnapshot());
}

Future<void> _handleSetOptions(HttpRequest req) async {
  if (_orch == null) {
    req.response.statusCode = 400;
    req.response.write('No workspace loaded');
    await req.response.close();
    return;
  }
  final body = await utf8.decodeStream(req);
  final data = jsonDecode(body) as Map<String, dynamic>;
  if (data.containsKey('forcefulReplace')) {
    _orch!.forcefulReplace = data['forcefulReplace'] as bool;
  }
  if (data.containsKey('replaceOnMismatch')) {
    _orch!.replaceOnMismatch = data['replaceOnMismatch'] as bool;
  }
  if (data.containsKey('forcefulIndividualUpdate')) {
    _orch!.forcefulIndividualUpdate = data['forcefulIndividualUpdate'] as bool;
  }
  if (data.containsKey('liveUpdateMode')) {
    _orch!.liveUpdateMode = data['liveUpdateMode'] as bool;
  }
  if (data.containsKey('localeSet')) {
    _orch!.useLocaleSet(data['localeSet'].toString());
  }
  await _json(req, _statusSnapshot());
}

/// Accepts a multipart upload of an entire folder (webkitdirectory).
/// Every part carries a filename of the form `relativePath` — we
/// reconstruct the directory tree under a fresh temp dir, then load
/// the Workspace from it.
Future<void> _handleUpload(HttpRequest req) async {
  final ct = req.headers.contentType?.value ?? '';
  if (!ct.startsWith('multipart/form-data')) {
    req.response.statusCode = 400;
    req.response.write('Expected multipart/form-data, got $ct');
    await req.response.close();
    return;
  }
  final boundary = req.headers.contentType!.parameters['boundary'];
  if (boundary == null) {
    req.response.statusCode = 400;
    req.response.write('Missing multipart boundary');
    await req.response.close();
    return;
  }

  // Dispose any previous workspace so ports/handles are clean.
  _runtime?.dispose();
  _runtime = null;
  _orch = null;

  final tmpRoot = await Directory.systemTemp.createTemp('asc_ws_');
  final overrideDir = await Directory.systemTemp.createTemp('asc_override_');
  File? keyFileOverride;
  String? issuerIdOverride;
  String? keyIdOverride;
  int fileCount = 0;
  try {
    final transformer = MimeMultipartTransformer(boundary);
    await for (final part in req.cast<List<int>>().transform(transformer)) {
      final disposition = part.headers['content-disposition'] ?? '';
      final nameMatch = RegExp('name="([^"]+)"').firstMatch(disposition);
      final filenameMatch =
          RegExp('filename="([^"]*)"').firstMatch(disposition);
      final fieldName = nameMatch?.group(1) ?? '';
      final filename = filenameMatch?.group(1) ?? '';

      // --- text fields (no filename) -----------------------------------
      if (fieldName == 'issuerId' && filename.isEmpty) {
        issuerIdOverride = (await utf8.decoder.bind(part).join()).trim();
        if (issuerIdOverride.isEmpty) issuerIdOverride = null;
        continue;
      }
      if (fieldName == 'keyId' && filename.isEmpty) {
        keyIdOverride = (await utf8.decoder.bind(part).join()).trim();
        if (keyIdOverride.isEmpty) keyIdOverride = null;
        continue;
      }

      // --- keyFile (.p8 override) --------------------------------------
      if (fieldName == 'keyFile' && filename.isNotEmpty) {
        final dest = File(p.join(overrideDir.path, 'key.p8'));
        final sink = dest.openWrite();
        await part.pipe(sink);
        keyFileOverride = dest;
        continue;
      }

      // --- folder tree -------------------------------------------------
      if (fieldName != 'files' || filename.isEmpty) {
        await part.drain<void>();
        continue;
      }
      final rel = filename.replaceAll('\\', '/');
      if (rel.contains('..') || rel.startsWith('/')) {
        await part.drain<void>();
        continue;
      }
      final dest = File(p.join(tmpRoot.path, rel));
      await dest.parent.create(recursive: true);
      final sink = dest.openWrite();
      await part.pipe(sink);
      fileCount++;
    }

    // Browsers upload with webkitRelativePath = "<rootFolderName>/<...>".
    // Descend into the single top-level folder if present.
    final root = await _resolveRoot(tmpRoot);
    final ws = await WorkspaceLoader().fromDirectory(
      root,
      keyFileOverride: keyFileOverride,
      keyIdOverride: keyIdOverride,
      issuerIdOverride: issuerIdOverride,
    );
    final runtime = OrchestratorRuntime.build(ws);
    final orch = Orchestrator(runtime);
    _runtime = runtime;
    _orch = orch;
    LoggingService.instance.success(
        'Workspace loaded from upload ($fileCount files)',
        scope: 'server');
    await _json(req, {
      'ok': true,
      'files': fileCount,
      'status': _statusSnapshot(),
    });
  } catch (e) {
    LoggingService.instance.error('Upload failed: $e', scope: 'server');
    req.response.statusCode = 400;
    req.response.write('$e');
    await req.response.close();
  }
}

Future<Directory> _resolveRoot(Directory tmp) async {
  final entries = tmp.listSync();
  if (entries.length == 1 && entries.first is Directory) {
    return entries.first as Directory;
  }
  return tmp;
}

Future<void> _serveFile(HttpRequest req, File file, String contentType) async {
  if (!await file.exists()) {
    req.response.statusCode = 404;
    await req.response.close();
    return;
  }
  req.response.headers.contentType = ContentType.parse(contentType);
  _applyNoCache(req.response);
  await req.response.addStream(file.openRead());
  await req.response.close();
}

/// Writes a pre-built string body with no-cache headers. Used for the
/// rewritten index.html that carries cache-busting `?v=<ts>` on asset refs.
/// Uses utf8.encode to preserve unicode (emoji, em-dashes, arrows) because
/// the default HttpResponse.write() goes through latin-1 and throws on
/// non-ASCII characters.
Future<void> _writeStatic(
    HttpRequest req, String contentType, String body) async {
  final ct = contentType.contains('charset=')
      ? contentType
      : '$contentType; charset=utf-8';
  req.response.headers.contentType = ContentType.parse(ct);
  _applyNoCache(req.response);
  req.response.add(utf8.encode(body));
  await req.response.close();
}

void _applyNoCache(HttpResponse res) {
  res.headers
      .set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
  res.headers.set('Pragma', 'no-cache');
  res.headers.set('Expires', '0');
}

Future<void> _json(HttpRequest req, Object body) async {
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

void _applyCors(HttpResponse res) {
  res.headers.set('Access-Control-Allow-Origin', '*');
  res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
}

Future<void> _openBrowser(String url) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', url]);
    }
  } catch (_) {
    // best-effort only
  }
}
