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
  final List<JsonSyntaxIssue> jsonSyntaxErrors;

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
    this.jsonSyntaxErrors = const [],
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

class JsonSyntaxIssue {
  final String fileName;
  final String message;
  final int? line;
  final int? column;

  JsonSyntaxIssue({
    required this.fileName,
    required this.message,
    this.line,
    this.column,
  });

  String get location {
    if (line == null || column == null) return '';
    return ' at line $line, column $column';
  }

  String get displayMessage => '$fileName is not valid JSON$location: $message';

  Map<String, dynamic> toJson() => {
        'file': fileName,
        'message': message,
        'line': line,
        'column': column,
      };
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

    final jsonSyntaxErrors = <JsonSyntaxIssue>[];

    JsonSyntaxIssue syntaxIssue(File f, FormatException e) {
      int? line;
      int? column;
      final source = e.source;
      final offset = e.offset;
      if (source is String && offset != null) {
        final boundedOffset = offset.clamp(0, source.length).toInt();
        var lineNumber = 1;
        var columnNumber = 1;
        for (var i = 0; i < boundedOffset; i++) {
          if (source.codeUnitAt(i) == 10) {
            lineNumber++;
            columnNumber = 1;
          } else {
            columnNumber++;
          }
        }
        line = lineNumber;
        column = columnNumber;
      }
      return JsonSyntaxIssue(
        fileName: p.basename(f.path),
        message: e.message,
        line: line,
        column: column,
      );
    }

    Future<Map<String, String>> readOne(
      File f, {
      bool trackSyntaxErrors = false,
    }) async {
      try {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          return decoded
              .map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      } on FormatException catch (e) {
        final issue = syntaxIssue(f, e);
        if (trackSyntaxErrors) {
          jsonSyntaxErrors.add(issue);
          _log.error(issue.displayMessage, scope: 'workspace');
        } else {
          _log.warn(issue.displayMessage, scope: 'workspace');
        }
      }
      return {};
    }

    /// Reads the first file in [candidates] that actually exists (case-
    /// insensitive match against the folder). Only warns when none of them
    /// is present — so e.g. having just `releasenotes.json` does NOT also
    /// log "release_notes.json not found".
    Future<Map<String, String>> readLocaleMap(
      List<String> candidates, {
      bool trackSyntaxErrors = false,
    }) async {
      for (final name in candidates) {
        final f = File(p.join(root.path, name));
        if (await f.exists()) {
          return readOne(f, trackSyntaxErrors: trackSyntaxErrors);
        }
      }
      _log.warn('${candidates.join(" / ")} not found; treated as empty',
          scope: 'workspace');
      return {};
    }

    final descriptions = await readLocaleMap(
      ['description.json'],
      trackSyntaxErrors: true,
    );
    final keywords = await readLocaleMap(['keywords.json']);
    final subtitles = await readLocaleMap(['subtitle.json']);
    // Accept either spelling of the release-notes file. Whichever exists
    // first wins; the other is not checked (no spurious "not found" warn).
    final releaseNotes = await readLocaleMap(
      ['releasenotes.json', 'release_notes.json'],
      trackSyntaxErrors: true,
    );

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

    // Coverage report — how many locales have their own translation vs
    // will rely on the default-language fallback. Informational, not
    // blocking. Keywords also shows the en-US length so a too-long
    // en-US value (which propagates to every fallback locale) is visible.
    final def = cfg.defaultLanguage;
    void cov(String label, Map<String, String> data) {
      final own = data.keys.toList()..sort();
      _log.info(
          '$label.json: ${own.length} locale(s) have own value → ${own.join(', ')}'
          '${data.containsKey(def) ? '' : '  [WARNING: $def missing — fallbacks will be empty!]'}',
          scope: 'workspace');
    }

    cov('description', descriptions);
    cov('keywords', keywords);
    cov('subtitle', subtitles);
    cov('releasenotes', releaseNotes);

    final defKw = keywords[def] ?? '';
    if (defKw.length > 100) {
      _log.warn(
          'keywords["$def"] is ${defKw.length} chars — because every locale '
          'without its own keywords falls back to $def, ALL locales will be '
          'rejected by Apple. Trim keywords.json["$def"] to ≤100 chars.',
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
      jsonSyntaxErrors: jsonSyntaxErrors,
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
