import 'dart:io';

import 'package:path/path.dart' as p;

import 'image_size.dart';
import 'logging.dart';
import 'screenshot_service.dart';
import 'workspace.dart';

class ValidationReport {
  final List<String> hardFailures;
  final List<String> softWarnings;

  ValidationReport({required this.hardFailures, required this.softWarnings});
  bool get ok => hardFailures.isEmpty;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'hardFailures': hardFailures,
        'softWarnings': softWarnings,
      };
}

class ValidationService {
  final LoggingService _log = LoggingService.instance;

  ValidationReport run(Workspace ws) {
    final hard = <String>[];
    final soft = <String>[];

    if (ws.config.metadata.packageId.isEmpty) {
      hard.add('metadata.package_id is empty');
    }
    if (ws.config.creds.keyId.isEmpty) {
      hard.add('app_store_connect.key_id empty');
    }
    if (ws.config.creds.issuerId.isEmpty) {
      hard.add('app_store_connect.issuer_id empty');
    }
    if (!ws.p8Key.existsSync()) {
      hard.add('.p8 key not found: ${ws.p8Key.path}');
    }
    for (final issue in ws.jsonSyntaxErrors) {
      hard.add(issue.displayMessage);
    }

    if (ws.config.localizations.isEmpty) {
      soft.add(
          'no localizations declared; will use default ${ws.config.defaultLanguage}');
    }

    final fallback = ws.config.defaultLanguage;
    for (final locale in ws.config.localizations) {
      if (!ws.descriptions.containsKey(locale) &&
          !ws.descriptions.containsKey(fallback)) {
        soft.add('$locale: description missing (and no fallback)');
      }
      final dir = ws.screenshotDirFor(locale);
      if (!dir.existsSync()) {
        soft.add('$locale: screenshots folder missing → fallback en-US');
        continue;
      }
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => !p.basename(f.path).startsWith('.'))
          .toList();
      if (files.isEmpty) {
        soft.add('$locale: screenshots folder empty → fallback en-US');
      }
    }

    _validateIpadScreenshots(ws, soft);

    if (ws.config.inApp != null) {
      for (final iap in ws.config.inApp!.iapMetadata) {
        if (iap.productId.isEmpty) hard.add('iap with empty product_id');
        if (iap.localizations.isEmpty) {
          soft.add('IAP ${iap.productId}: no localizations');
        }
      }
      final reviewImg = ws.config.inApp!.reviewImagePath;
      if (reviewImg.isNotEmpty) {
        final abs = File(p.join(ws.root.path, reviewImg));
        if (!abs.existsSync()) {
          soft.add('IAP review image not found: $reviewImg');
        }
      }
    }

    for (final m in hard) {
      _log.error(m, scope: 'validate');
    }
    for (final m in soft) {
      _log.warn(m, scope: 'validate');
    }
    if (hard.isEmpty && soft.isEmpty) {
      _log.success('Validation passed cleanly', scope: 'validate');
    } else if (hard.isEmpty) {
      _log.success('Validation passed with ${soft.length} soft warning(s)',
          scope: 'validate');
    }
    return ValidationReport(hardFailures: hard, softWarnings: soft);
  }

  /// Pre-flight check for `screenshots/ipad/<locale>`.
  ///
  /// Purely additive to the existing checks: it never removes or downgrades
  /// anything above. Every iPad image is measured here so an unusable
  /// resolution is reported at Validate time instead of being silently
  /// skipped mid-upload.
  ///
  /// Directories are validated once each — with the en-US fallback most
  /// locales resolve to the same folder, and repeating the same warning 39
  /// times would bury the real problems.
  void _validateIpadScreenshots(Workspace ws, List<String> soft) {
    final ipadRoot = ws.ipadScreenshotsRoot;
    if (!ipadRoot.existsSync()) {
      soft.add('screenshots/ipad folder missing — no iPad screenshots will '
          'be uploaded (expected screenshots/ipad/<locale>/*.png)');
      return;
    }

    final fallback = ws.config.defaultLanguage;
    final fallbackDir = ws.ipadScreenshotDirFor(fallback);
    final fallbackHasShots = _imageFiles(fallbackDir).isNotEmpty;
    if (!fallbackHasShots) {
      soft.add('iPad: screenshots/ipad/$fallback is missing or empty — '
          'locales without their own iPad folder have nothing to fall back to');
    }

    final locales = ws.config.localizations.isEmpty
        ? <String>[fallback]
        : ws.config.localizations;

    // folder path -> the locales that resolve to it, so one bad file is
    // reported once with the full list of affected locales.
    final resolved = <String, List<String>>{};
    for (final locale in locales) {
      final primary = ws.ipadScreenshotDirFor(locale);
      final usePrimary = _imageFiles(primary).isNotEmpty;
      if (!usePrimary && locale != fallback) {
        if (fallbackHasShots) {
          soft.add('iPad: $locale has no screenshots/ipad/$locale → '
              'falling back to ipad/$fallback');
        } else {
          soft.add('iPad: $locale has no screenshots/ipad/$locale and no '
              'fallback → no iPad screenshots for this locale');
        }
      }
      final dir = usePrimary ? primary : fallbackDir;
      resolved
          .putIfAbsent(p.relative(dir.path, from: ws.root.path), () => [])
          .add(locale);
    }

    for (final entry in resolved.entries) {
      final dir = Directory(p.join(ws.root.path, entry.key));
      final files = _imageFiles(dir);
      if (files.isEmpty) continue;
      final used = entry.value.join(', ');
      for (final f in files) {
        final name = p.basename(f.path);
        final size = readImageSize(f.readAsBytesSync());
        if (size == null) {
          soft.add('iPad: ${entry.key}/$name is not a readable PNG/JPEG — '
              'it will be skipped on upload (used by: $used)');
          continue;
        }
        final w = size['width']!;
        final h = size['height']!;
        if (_isAcceptedIpadSize(w, h)) continue;
        soft.add('iPad: ${entry.key}/$name is ${w}x$h — not an accepted iPad '
            'size. Use $kIpadAcceptedSizesText. This file will be skipped on '
            'upload (used by: $used)');
      }
    }
  }

  bool _isAcceptedIpadSize(int width, int height) {
    final long = width > height ? width : height;
    final short = width > height ? height : width;
    for (final size in kIpadScreenshotSizes) {
      if (short == size[0] && long == size[1]) return true;
    }
    return false;
  }

  List<File> _imageFiles(Directory dir) {
    if (!dir.existsSync()) return const [];
    return dir.listSync().whereType<File>().where((f) {
      final n = p.basename(f.path).toLowerCase();
      if (n.startsWith('.')) return false;
      return n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg');
    }).toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  }
}
