import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/config.dart';
import 'logging.dart';

/// In-memory representation of an uploaded folder on disk (temp dir).
class Workspace {
  final Directory root;
  final UploadConfig config;
  final File p8Key;
  final Map<String, String> descriptions;
  final Map<String, String> keywords;
  final Map<String, String> subtitles;
  final Map<String, String> releaseNotes;

  /// Non-blocking warnings raised at load time (prefix mismatches, missing
  /// assets, etc). Displayed in the UI and also logged.
  final List<String> warnings;

  Workspace({
    required this.root,
    required this.config,
    required this.p8Key,
    required this.descriptions,
    required this.keywords,
    required this.subtitles,
    required this.releaseNotes,
    this.warnings = const [],
  });

  Directory get screenshotsRoot => Directory(p.join(root.path, 'screenshots'));
  Directory get iapRoot => Directory(p.join(root.path, 'iap'));

  Directory screenshotDirFor(String locale) =>
      Directory(p.join(screenshotsRoot.path, locale));

  String textFor(Map<String, String> source, String locale, String fallback) {
    return source[locale] ?? source[fallback] ?? '';
  }
}

class WorkspaceHardFail implements Exception {
  final String message;
  WorkspaceHardFail(this.message);
  @override
  String toString() => 'WorkspaceHardFail: $message';
}

class WorkspaceLoader {
  final LoggingService _log = LoggingService.instance;

  /// Given a directory that mirrors the Flutter-app's reference layout
  /// (config.json + AuthKey_*.p8 + description.json + etc + screenshots/
  /// + iap/), load everything we need for uploads.
  ///
  /// Optional overrides let the caller replace the credentials
  /// (`key_id` / `issuer_id`) and/or the `.p8` file supplied inside the
  /// folder. Useful when the UI lets users upload a folder whose
  /// config.json has empty creds, or when using a shared folder with
  /// different ASC accounts.
  Future<Workspace> fromDirectory(
    Directory root, {
    File? keyFileOverride,
    String? keyIdOverride,
    String? issuerIdOverride,
  }) async {
    if (!await root.exists()) {
      throw WorkspaceHardFail('Workspace folder does not exist: ${root.path}');
    }
    final configFile = File(p.join(root.path, 'config.json'));
    if (!await configFile.exists()) {
      throw WorkspaceHardFail('config.json missing in ${root.path}');
    }
    final Map<String, dynamic> raw;
    try {
      raw = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw WorkspaceHardFail('config.json is not valid JSON: ${e.message}');
    }
    // Patch raw config with any caller-supplied override *before*
    // constructing UploadConfig so downstream code sees consistent creds.
    final asc = (raw['app_store_connect'] as Map?) ?? {};
    if (keyIdOverride != null && keyIdOverride.isNotEmpty) {
      asc['key_id'] = keyIdOverride;
    }
    if (issuerIdOverride != null && issuerIdOverride.isNotEmpty) {
      asc['issuer_id'] = issuerIdOverride;
    }
    raw['app_store_connect'] = asc;

    final UploadConfig cfg;
    try {
      cfg = UploadConfig.fromJson(raw);
    } catch (e) {
      throw WorkspaceHardFail('config.json has invalid structure: $e');
    }
    final File p8;
    if (keyFileOverride != null && await keyFileOverride.exists()) {
      p8 = keyFileOverride;
      _log.info('Using uploaded .p8 override', scope: 'workspace');
    } else {
      p8 = await _findP8(root, cfg.creds.keyId);
    }

    Future<Map<String, String>> readLocaleMap(String name) async {
      final f = File(p.join(root.path, name));
      if (!await f.exists()) {
        _log.warn('$name not found; treated as empty', scope: 'workspace');
        return {};
      }
      try {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          return decoded
              .map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      } on FormatException catch (e) {
        _log.warn('$name invalid JSON: ${e.message}', scope: 'workspace');
      }
      return {};
    }

    final descriptions = await readLocaleMap('description.json');
    final keywords = await readLocaleMap('keywords.json');
    final subtitles = await readLocaleMap('subtitle.json');
    // Accept either releasenotes.json or release_notes.json (user folders
    // have been seen with both spellings). Whichever exists first wins; if
    // both exist, merge with release_notes.json taking precedence.
    final releaseNotesA = await readLocaleMap('releasenotes.json');
    final releaseNotesB = await readLocaleMap('release_notes.json');
    final releaseNotes = {...releaseNotesA, ...releaseNotesB};

    // Pre-flight sanity checks — non-blocking.
    final warnings = <String>[];

    // IAP product_id prefix must share first two dot-segments with package_id.
    final pkg = cfg.metadata.packageId;
    final pkgPrefix = _twoSegmentPrefix(pkg);
    if (pkgPrefix.isNotEmpty && cfg.inApp != null) {
      for (final iap in cfg.inApp!.iapMetadata) {
        final pid = iap.productId.trim();
        if (pid.isEmpty) continue;
        final pidPrefix = _twoSegmentPrefix(pid);
        if (pidPrefix != pkgPrefix) {
          final msg = 'IAP product_id "$pid" prefix "$pidPrefix" does not '
              'match package_id "$pkg" prefix "$pkgPrefix" '
              '(review config.json before uploading)';
          warnings.add(msg);
          _log.warn(msg, scope: 'workspace');
        }
      }
    }

    // Keywords are limited to 100 characters per locale by Apple — flag any
    // over-limit entries so the user can trim before uploading. Without this
    // Apple rejects the PATCH for that locale with a validation error.
    keywords.forEach((locale, value) {
      if (value.length > 100) {
        final msg = 'keywords["$locale"] is ${value.length} chars '
            '(limit 100) — upload will be rejected for this locale';
        warnings.add(msg);
        _log.warn(msg, scope: 'workspace');
      }
    });

    _log.success(
        'Loaded workspace: ${cfg.metadata.packageId} (${cfg.localizations.length} locales)'
        '${warnings.isEmpty ? '' : '  [${warnings.length} warning(s)]'}',
        scope: 'workspace');

    // Log the expected tab so the user sees it even before checking the UI.
    final expectedTab = cfg.metadata.updateVersion.isEmpty
        ? 'New Push (update_version is empty)'
        : 'Live Update (update_version = "${cfg.metadata.updateVersion}")';
    _log.info('Mode expected from config.json → $expectedTab',
        scope: 'workspace');

    return Workspace(
      root: root,
      config: cfg,
      p8Key: p8,
      descriptions: descriptions,
      keywords: keywords,
      subtitles: subtitles,
      releaseNotes: releaseNotes,
      warnings: warnings,
    );
  }

  /// Returns the first two dot-separated segments of [id], e.g. for
  /// "com.zapp.testbuild" → "com.zapp". Returns "" when fewer than 2
  /// segments are present.
  String _twoSegmentPrefix(String id) {
    final parts = id.split('.');
    if (parts.length < 2) return '';
    return '${parts[0]}.${parts[1]}';
  }

  Future<File> _findP8(Directory root, String keyId) async {
    final expected = File(p.join(root.path, 'AuthKey_$keyId.p8'));
    if (await expected.exists()) return expected;
    await for (final e in root.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.p8')) return e;
    }
    throw WorkspaceHardFail(
        'No .p8 key found in ${root.path} (expected AuthKey_$keyId.p8)');
  }
}
