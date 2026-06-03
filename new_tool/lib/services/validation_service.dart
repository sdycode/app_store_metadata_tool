import 'dart:io';

import 'package:path/path.dart' as p;

import 'logging.dart';
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
}
