import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// File-backed replacement for shared_preferences. Stores one JSON doc per
/// bundle+version pair under the workspace root (~/.asc_upload_tool/).
class ResumeState {
  bool versionDone;
  Map<String, bool> metadataByLocale;
  Map<String, bool> screenshotsByLocale;
  Map<String, bool> ipadScreenshotsByLocale;
  Map<String, bool> iapByProduct;

  ResumeState({
    this.versionDone = false,
    Map<String, bool>? metadataByLocale,
    Map<String, bool>? screenshotsByLocale,
    Map<String, bool>? ipadScreenshotsByLocale,
    Map<String, bool>? iapByProduct,
  })  : metadataByLocale = metadataByLocale ?? {},
        screenshotsByLocale = screenshotsByLocale ?? {},
        ipadScreenshotsByLocale = ipadScreenshotsByLocale ?? {},
        iapByProduct = iapByProduct ?? {};

  Map<String, dynamic> toJson() => {
        'versionDone': versionDone,
        'metadataByLocale': metadataByLocale,
        'screenshotsByLocale': screenshotsByLocale,
        'ipadScreenshotsByLocale': ipadScreenshotsByLocale,
        'iapByProduct': iapByProduct,
      };

  factory ResumeState.fromJson(Map<String, dynamic> j) => ResumeState(
        versionDone: (j['versionDone'] ?? false) as bool,
        metadataByLocale: ((j['metadataByLocale'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v == true)),
        screenshotsByLocale: ((j['screenshotsByLocale'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v == true)),
        ipadScreenshotsByLocale:
            ((j['ipadScreenshotsByLocale'] as Map?) ?? const {})
                .map((k, v) => MapEntry(k.toString(), v == true)),
        iapByProduct: ((j['iapByProduct'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v == true)),
      );
}

class ResumeService {
  final Directory rootDir;

  ResumeService(this.rootDir);

  File _fileFor(String bundleId, String versionHint) {
    final name = '${bundleId}__'
        '${versionHint.isEmpty ? 'editable' : versionHint}.json';
    return File(p.join(rootDir.path, name));
  }

  Future<ResumeState> load(String bundleId, String versionHint) async {
    final f = _fileFor(bundleId, versionHint);
    if (!await f.exists()) return ResumeState();
    try {
      return ResumeState.fromJson(
          jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return ResumeState();
    }
  }

  Future<void> save(
      String bundleId, String versionHint, ResumeState state) async {
    await rootDir.create(recursive: true);
    final f = _fileFor(bundleId, versionHint);
    await f.writeAsString(jsonEncode(state.toJson()));
  }

  Future<void> clear(String bundleId, String versionHint) async {
    final f = _fileFor(bundleId, versionHint);
    if (await f.exists()) await f.delete();
  }
}
