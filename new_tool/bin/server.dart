import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asc_upload_tool/services/logging.dart';
import 'package:asc_upload_tool/services/orchestrator.dart';
import 'package:asc_upload_tool/services/workspace.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

const int kPort = 3000;

/// Global server state — one workspace + orchestrator at a time (local tool).
OrchestratorRuntime? _runtime;
Orchestrator? _orch;
Future<void>? _activeTask;

Future<void> main(List<String> args) async {
  final webDir = _locateWebDir();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, kPort);
  server.autoCompress = true;
  print('ASC upload tool listening on http://localhost:$kPort');

  // Auto-open browser (macOS/Linux/Windows best-effort).
  unawaited(_openBrowser('http://localhost:$kPort'));

  await for (final req in server) {
    unawaited(_handle(req, webDir));
  }
}

Directory _locateWebDir() {
  // When running from `dart run bin/server.dart` cwd is the package root.
  final candidates = [
    Directory(p.join(Directory.current.path, 'web')),
    Directory(p.join(Directory.current.path, 'new_tool', 'web')),
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
        await _serveFile(req, File(p.join(webDir.path, 'index.html')), 'text/html');
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
      if (path == '/logs') {
        final since = int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
        final entries =
            LoggingService.instance.since(since).map((e) => e.toJson()).toList();
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
            LoggingService.instance.info('Validation: ${jsonEncode(r.toJson())}',
                scope: 'validate');
          });
          return;
        case '/action/upload-metadata':
          await _runAction(req, 'Upload Metadata', _orch!.uploadMetadata);
          return;
        case '/action/upload-screenshots':
          await _runAction(req, 'Upload Screenshots', _orch!.uploadScreenshots);
          return;
        case '/action/upload-iap':
          await _runAction(req, 'Upload IAP', _orch!.uploadIap);
          return;
        case '/action/upload-all':
          await _runAction(req, 'Upload All', _orch!.uploadAll);
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
            await _orch!.checkScreenshots();
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
          },
    'control': _orch?.control.toJson() ?? {'active': false},
    'selectedLocales': _orch?.selectedLocales.toList() ?? const [],
    'replaceScreenshots': _orch?.replaceScreenshots ?? true,
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
  if (data.containsKey('replaceScreenshots')) {
    _orch!.replaceScreenshots = data['replaceScreenshots'] as bool;
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
  await req.response.addStream(file.openRead());
  await req.response.close();
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

