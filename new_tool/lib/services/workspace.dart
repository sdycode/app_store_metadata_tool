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

  Workspace({
    required this.root,
    required this.config,
    required this.p8Key,
    required this.descriptions,
    required this.keywords,
    required this.subtitles,
    required this.releaseNotes,
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
    final releaseNotes = await readLocaleMap('releasenotes.json');

    _log.success(
        'Loaded workspace: ${cfg.metadata.packageId} (${cfg.localizations.length} locales)',
        scope: 'workspace');

    // Dump the screenshots inventory so the user can see exactly what the
    // server received — makes silent fallbacks immediately visible.
    final ssRoot = Directory(p.join(root.path, 'screenshots'));
    if (ssRoot.existsSync()) {
      final lines = <String>[];
      for (final entry in ssRoot.listSync()) {
        if (entry is! Directory) continue;
        final name = p.basename(entry.path);
        final imageFiles = entry
            .listSync()
            .whereType<File>()
            .where((f) {
              final n = p.basename(f.path).toLowerCase();
              if (n.startsWith('.')) return false;
              return n.endsWith('.png') ||
                  n.endsWith('.jpg') ||
                  n.endsWith('.jpeg');
            })
            .toList();
          final otherFiles = entry
            .listSync()
            .whereType<File>()
            .where((f) {
              final n = p.basename(f.path).toLowerCase();
              return !imageFiles.contains(f) && !n.startsWith('.');
            })
            .map((f) => p.basename(f.path))
            .toList();
        final tag = otherFiles.isEmpty ? '' : '  [ignored: ${otherFiles.join(', ')}]';
        lines.add('  $name: ${imageFiles.length} image(s)$tag');
      }
      _log.info(
          'screenshots/ inventory:\n${lines.isEmpty ? '  (empty)' : lines.join('\n')}',
          scope: 'workspace');
    } else {
      _log.warn('screenshots/ folder missing in workspace',
          scope: 'workspace');
    }

    return Workspace(
      root: root,
      config: cfg,
      p8Key: p8,
      descriptions: descriptions,
      keywords: keywords,
      subtitles: subtitles,
      releaseNotes: releaseNotes,
    );
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
