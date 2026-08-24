import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/asc_resource.dart';
import 'asc_client.dart';
import 'image_size.dart';
import 'logging.dart';
import 'run_state.dart';
import 'workspace.dart';

class ScreenshotUploadOutcome {
  final String locale;
  final String displayType;
  final int uploaded;
  final int deleted;
  final String action;

  ScreenshotUploadOutcome({
    required this.locale,
    required this.displayType,
    required this.uploaded,
    required this.deleted,
    required this.action,
  });
}

/// The only resolutions Apple accepts for the iPad screenshot slot.
/// Each pair is [short, long]; both orientations are valid, so
/// 2064x2752 / 2752x2064 / 2048x2732 / 2732x2048 all pass.
const List<List<int>> kIpadScreenshotSizes = <List<int>>[
  <int>[2064, 2752],
  <int>[2048, 2732],
];

/// Apple never shipped a distinct "iPad 13-inch" enum value — both accepted
/// iPad sizes are uploaded under APP_IPAD_PRO_3GEN_129 despite its name.
const String kIpadDisplayType = 'APP_IPAD_PRO_3GEN_129';

/// Human-readable list of the accepted iPad sizes, reused in every warning
/// so the log and the validator say exactly the same thing.
const String kIpadAcceptedSizesText =
    '2064x2752, 2752x2064, 2048x2732 or 2732x2048';

/// True for any App Store Connect display type that belongs to an iPad.
bool isIpadDisplayType(String displayType) =>
    displayType.toUpperCase().startsWith('APP_IPAD');

class ScreenshotService {
  final AscClient client;
  final LoggingService _log = LoggingService.instance;

  ScreenshotService(this.client);

  Future<List<AscResource>> listSets(String localizationId) async {
    final items = await client.getAllData(
      '/v1/appStoreVersionLocalizations/$localizationId/appScreenshotSets',
    );
    return items.map(AscResource.fromJson).toList();
  }

  Future<AscResource> createSet({
    required String localizationId,
    required String displayType,
  }) async {
    final json = await client.postJson('/v1/appScreenshotSets', {
      'data': {
        'type': 'appScreenshotSets',
        'attributes': {'screenshotDisplayType': displayType},
        'relationships': {
          'appStoreVersionLocalization': {
            'data': {
              'id': localizationId,
              'type': 'appStoreVersionLocalizations',
            },
          },
        },
      },
    });
    return AscResource.fromJson(json['data'] as Map<String, dynamic>);
  }

  Future<List<AscResource>> listShots(String setId) async {
    final items =
        await client.getAllData('/v1/appScreenshotSets/$setId/appScreenshots');
    return items.map(AscResource.fromJson).toList();
  }

  Future<void> deleteShot(String id) =>
      client.delete('/v1/appScreenshots/$id');

  /// Maps a PNG/JPG resolution to Apple's screenshotDisplayType enum.
  /// Accepts both portrait and landscape orientations for each known size.
  /// Returns null when the resolution isn't recognized — callers must skip
  /// those files instead of uploading to a guessed display type (Apple
  /// rejects mismatched dimensions with IMAGE_INCORRECT_DIMENSIONS).
  String? detectDisplayType(int width, int height) {
    final long = width > height ? width : height;
    final short = width > height ? height : width;

    // iPhone
    if (long == 2868 && short == 1320) return 'APP_IPHONE_69';
    if (long == 2796 && short == 1290) return 'APP_IPHONE_67';
    if (long == 2778 && short == 1284) return 'APP_IPHONE_67';
    if (long == 2688 && short == 1242) return 'APP_IPHONE_65';
    if (long == 2436 && short == 1125) return 'APP_IPHONE_58';
    if (long == 2208 && short == 1242) return 'APP_IPHONE_55';
    if (long == 1334 && short == 750) return 'APP_IPHONE_47';
    if (long == 1136 && short == 640) return 'APP_IPHONE_40';
    // iPad
    if (long == 2732 && short == 2048) return 'APP_IPAD_PRO_3GEN_129';
    if (long == 2752 && short == 2064) return 'APP_IPAD_PRO_129';
    if (long == 2388 && short == 1668) return 'APP_IPAD_PRO_3GEN_11';
    if (long == 2224 && short == 1668) return 'APP_IPAD_105';
    if (long == 2048 && short == 1536) return 'APP_IPAD_97';
    return null;
  }

  Map<String, int>? _readImageSize(Uint8List bytes) => readImageSize(bytes);

  List<File> _listLocalShots(Directory dir) {
    if (!dir.existsSync()) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final n = p.basename(f.path).toLowerCase();
          if (n.startsWith('.')) return false;
          return n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg');
        })
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
  }

  Directory _resolveLocaleDir(Workspace ws, String locale) {
    final primary = ws.screenshotDirFor(locale);
    if (primary.existsSync() && _listLocalShots(primary).isNotEmpty) {
      return primary;
    }
    return ws.screenshotDirFor(ws.config.defaultLanguage);
  }

  /// iPad counterpart of [detectDisplayType]. Deliberately strict: only the
  /// four resolutions Apple currently accepts for the iPad slot map to a
  /// display type, everything else returns null so the caller skips the file
  /// instead of triggering IMAGE_INCORRECT_DIMENSIONS on upload.
  String? detectIpadDisplayType(int width, int height) {
    final long = width > height ? width : height;
    final short = width > height ? height : width;
    for (final size in kIpadScreenshotSizes) {
      if (short == size[0] && long == size[1]) return kIpadDisplayType;
    }
    return null;
  }

  /// `screenshots/ipad/<locale>`, falling back to `screenshots/ipad/<default>`
  /// when the locale has no folder of its own or the folder is empty —
  /// same rule the iPhone path uses, just one level deeper.
  Directory _resolveIpadLocaleDir(Workspace ws, String locale) {
    final primary = ws.ipadScreenshotDirFor(locale);
    if (primary.existsSync() && _listLocalShots(primary).isNotEmpty) {
      return primary;
    }
    return ws.ipadScreenshotDirFor(ws.config.defaultLanguage);
  }

  /// Uploads `screenshots/ipad/<locale>` for one locale.
  ///
  /// Kept separate from [syncLocale] on purpose, and scoped so it can only
  /// ever touch iPad display-type sets: even with [forcefulReplace] on it
  /// wipes just the sets it is about to refill, so iPhone screenshots on the
  /// same localization are never deleted.
  Future<ScreenshotUploadOutcome> syncLocaleIpad({
    required String localizationId,
    required String locale,
    required Workspace workspace,
    // Always wipe the iPad set's existing shots and re-upload.
    required bool forcefulReplace,
    // When forcefulReplace is false: still replace the iPad set's shots if
    // the local file count differs from the remote count.
    required bool replaceOnMismatch,
    RunState? control,
  }) async {
    await control?.checkpoint();
    final dir = _resolveIpadLocaleDir(workspace, locale);
    final localFiles = _listLocalShots(dir);
    final sourceFolder = p.join('ipad', p.basename(dir.path));

    if (localFiles.isEmpty) {
      _log.info('$locale: no local iPad screenshots; keeping existing',
          scope: 'screenshot-ipad');
      return ScreenshotUploadOutcome(
        locale: locale, displayType: '-', uploaded: 0, deleted: 0, action: 'kept');
    }

    final groups = <String, List<File>>{};
    for (final f in localFiles) {
      final bytes = await f.readAsBytes();
      final size = _readImageSize(bytes);
      final name = p.basename(f.path);
      if (size == null) {
        _log.warn(
            '$locale: cannot read dimensions of $name — skipping (not PNG/JPEG)',
            scope: 'screenshot-ipad');
        continue;
      }
      final displayType =
          detectIpadDisplayType(size['width']!, size['height']!);
      if (displayType == null) {
        _log.warn(
            '$locale ← $sourceFolder/$name ${size['width']}x${size['height']}: '
            'UNSUPPORTED iPad resolution — skipping this file. '
            'Accepted iPad sizes: $kIpadAcceptedSizesText.',
            scope: 'screenshot-ipad');
        continue;
      }
      _log.info(
          '$locale ← $sourceFolder/$name ${size['width']}x${size['height']} → $displayType',
          scope: 'screenshot-ipad');
      groups.putIfAbsent(displayType, () => []).add(f);
    }
    if (groups.isEmpty) {
      _log.warn('$locale: no uploadable iPad images after dimension check',
          scope: 'screenshot-ipad');
      return ScreenshotUploadOutcome(
        locale: locale, displayType: '-', uploaded: 0, deleted: 0, action: 'skipped');
    }

    int totalUploaded = 0;
    int totalDeleted = 0;
    final actions = <String>[];

    final existingSets = await listSets(localizationId);

    for (final entry in groups.entries) {
      await control?.checkpoint();
      final displayType = entry.key;
      final files = entry.value;
      AscResource? set = existingSets.firstWhere(
        (s) => (s.attributes['screenshotDisplayType'] ?? '') == displayType,
        orElse: () => AscResource(
            id: '', type: '', attributes: const {}, relationships: const {}),
      );
      if (set.id.isEmpty) {
        set = await createSet(
            localizationId: localizationId, displayType: displayType);
        _log.info('$locale/$displayType: created set ${set.id}',
            scope: 'screenshot-ipad');
      }

      final existingShots = await listShots(set.id);

      if (forcefulReplace) {
        for (final s in existingShots) {
          await control?.checkpoint();
          await deleteShot(s.id);
          totalDeleted++;
        }
        if (existingShots.isNotEmpty) {
          _log.info(
              '$locale/$displayType: wiped ${existingShots.length} existing '
              '(forceful replace)',
              scope: 'screenshot-ipad');
        }
        await _uploadAllIpad(set.id, files, locale, displayType, control);
        totalUploaded += files.length;
        actions.add('replaced');
        continue;
      }

      if (existingShots.isEmpty) {
        await _uploadAllIpad(set.id, files, locale, displayType, control);
        totalUploaded += files.length;
        actions.add('uploaded');
        continue;
      }

      if (existingShots.length != files.length) {
        if (!replaceOnMismatch) {
          _log.info(
              '$locale/$displayType: count mismatch '
              '(${existingShots.length} vs ${files.length}) — keeping existing '
              '(both replace options are off)',
              scope: 'screenshot-ipad');
          actions.add('kept');
          continue;
        }
        for (final s in existingShots) {
          await control?.checkpoint();
          await deleteShot(s.id);
          totalDeleted++;
        }
        _log.info(
            '$locale/$displayType: count mismatch '
            '(${existingShots.length}→${files.length}); replaced',
            scope: 'screenshot-ipad');
        await _uploadAllIpad(set.id, files, locale, displayType, control);
        totalUploaded += files.length;
        actions.add('replaced');
        continue;
      }

      _log.info('$locale/$displayType: same count (${files.length}); skipping',
          scope: 'screenshot-ipad');
      actions.add('skipped');
    }

    return ScreenshotUploadOutcome(
      locale: locale,
      displayType: groups.keys.join(','),
      uploaded: totalUploaded,
      deleted: totalDeleted,
      action: actions.join(','),
    );
  }

  Future<void> _uploadAllIpad(String setId, List<File> files, String locale,
      String displayType, RunState? control) async {
    for (final f in files) {
      await control?.checkpoint();
      await uploadOne(setId: setId, file: f);
      _log.success('$locale/$displayType: uploaded ${p.basename(f.path)}',
          scope: 'screenshot-ipad');
    }
  }

  Future<ScreenshotUploadOutcome> syncLocale({
    required String localizationId,
    required String locale,
    required Workspace workspace,
    // Always wipe every existing set's shots and re-upload.
    required bool forcefulReplace,
    // When forcefulReplace is false: still replace a set's shots if the
    // local file count differs from the remote count. When both are false
    // existing shots are left alone and local files only fill empty sets.
    required bool replaceOnMismatch,
    RunState? control,
  }) async {
    await control?.checkpoint();
    final dir = _resolveLocaleDir(workspace, locale);
    final localFiles = _listLocalShots(dir);
    final sourceFolder = p.basename(dir.path);

    if (localFiles.isEmpty) {
      _log.info('$locale: no local screenshots; keeping existing',
          scope: 'screenshot');
      return ScreenshotUploadOutcome(
        locale: locale, displayType: '-', uploaded: 0, deleted: 0, action: 'kept');
    }

    final groups = <String, List<File>>{};
    for (final f in localFiles) {
      final bytes = await f.readAsBytes();
      final size = _readImageSize(bytes);
      final name = p.basename(f.path);
      if (size == null) {
        _log.warn(
            '$locale: cannot read dimensions of $name — skipping (not PNG/JPEG)',
            scope: 'screenshot');
        continue;
      }
      final displayType = detectDisplayType(size['width']!, size['height']!);
      if (displayType == null) {
        // Don't upload to a guessed display type — Apple rejects with
        // IMAGE_INCORRECT_DIMENSIONS. Log loudly so the user knows WHY
        // this file was skipped, and continue with the rest (per the
        // requirement: do NOT stop the run just because one file is bad).
        _log.warn(
            '$locale ← $sourceFolder/$name ${size['width']}x${size['height']}: '
            'UNSUPPORTED resolution — skipping this file. '
            'Accepted iPhone sizes: 1242x2688, 1284x2778, 1290x2796, 1320x2868 '
            '(and their landscape rotations).',
            scope: 'screenshot');
        continue;
      }
      _log.info(
          '$locale ← $sourceFolder/$name ${size['width']}x${size['height']} → $displayType',
          scope: 'screenshot');
      groups.putIfAbsent(displayType, () => []).add(f);
    }
    if (groups.isEmpty) {
      _log.warn('$locale: no uploadable images after dimension check',
          scope: 'screenshot');
      return ScreenshotUploadOutcome(
        locale: locale, displayType: '-', uploaded: 0, deleted: 0, action: 'skipped');
    }

    int totalUploaded = 0;
    int totalDeleted = 0;
    final actions = <String>[];

    final existingSets = await listSets(localizationId);

    // Forceful replace: wipe EVERY existing shot across EVERY display-type
    // set for this locale, then the per-group loop below just uploads.
    if (forcefulReplace) {
      for (final set in existingSets) {
        await control?.checkpoint();
        final displayType =
            (set.attributes['screenshotDisplayType'] ?? '').toString();
        final shots = await listShots(set.id);
        if (shots.isEmpty) continue;
        for (final s in shots) {
          await control?.checkpoint();
          await deleteShot(s.id);
          totalDeleted++;
        }
        _log.info(
            '$locale/$displayType: wiped ${shots.length} existing (forceful replace)',
            scope: 'screenshot');
      }
    }

    for (final entry in groups.entries) {
      await control?.checkpoint();
      final displayType = entry.key;
      final files = entry.value;
      AscResource? set = existingSets.firstWhere(
        (s) => (s.attributes['screenshotDisplayType'] ?? '') == displayType,
        orElse: () => AscResource(
            id: '', type: '', attributes: const {}, relationships: const {}),
      );
      if (set.id.isEmpty) {
        set = await createSet(
            localizationId: localizationId, displayType: displayType);
        _log.info('$locale/$displayType: created set ${set.id}',
            scope: 'screenshot');
      }

      // Existing shots already wiped above when forcefulReplace=true.
      final existingShots =
          forcefulReplace ? <AscResource>[] : await listShots(set.id);

      if (forcefulReplace) {
        await _uploadAll(set.id, files, locale, displayType, control);
        totalUploaded += files.length;
        actions.add('replaced');
        continue;
      }

      if (existingShots.isEmpty) {
        await _uploadAll(set.id, files, locale, displayType, control);
        totalUploaded += files.length;
        actions.add('uploaded');
        continue;
      }

      if (existingShots.length != files.length) {
        if (!replaceOnMismatch) {
          _log.info(
              '$locale/$displayType: count mismatch '
              '(${existingShots.length} vs ${files.length}) — keeping existing '
              '(both replace options are off)',
              scope: 'screenshot');
          actions.add('kept');
          continue;
        }
        for (final s in existingShots) {
          await control?.checkpoint();
          await deleteShot(s.id);
          totalDeleted++;
        }
        _log.info(
            '$locale/$displayType: count mismatch (${existingShots.length}→${files.length}); replaced',
            scope: 'screenshot');
        await _uploadAll(set.id, files, locale, displayType, control);
        totalUploaded += files.length;
        actions.add('replaced');
        continue;
      }

      _log.info(
          '$locale/$displayType: same count (${files.length}); skipping',
          scope: 'screenshot');
      actions.add('skipped');
    }

    return ScreenshotUploadOutcome(
      locale: locale,
      displayType: groups.keys.join(','),
      uploaded: totalUploaded,
      deleted: totalDeleted,
      action: actions.join(','),
    );
  }

  Future<void> _uploadAll(String setId, List<File> files, String locale,
      String displayType, RunState? control) async {
    for (final f in files) {
      await control?.checkpoint();
      await uploadOne(setId: setId, file: f);
      _log.success('$locale/$displayType: uploaded ${p.basename(f.path)}',
          scope: 'screenshot');
    }
  }

  Future<void> uploadOne(
      {required String setId, required File file}) async {
    final bytes = await file.readAsBytes();
    final fileName = p.basename(file.path);
    final checksum = md5.convert(bytes).toString();
    _log.debug(
        'uploadOne $fileName size=${bytes.length} md5=$checksum',
        scope: 'screenshot');

    final reserveJson = await client.postJson('/v1/appScreenshots', {
      'data': {
        'type': 'appScreenshots',
        'attributes': {
          'fileName': fileName,
          'fileSize': bytes.length,
        },
        'relationships': {
          'appScreenshotSet': {
            'data': {'id': setId, 'type': 'appScreenshotSets'},
          },
        },
      },
    });
    final reserved =
        AscResource.fromJson(reserveJson['data'] as Map<String, dynamic>);
    final ops = (reserved.attributes['uploadOperations'] as List?) ?? const [];
    _log.debug('reserved id=${reserved.id} operations=${ops.length}',
        scope: 'screenshot');

    int totalUploaded = 0;
    for (final op in ops) {
      final parsed = AscUploadOperation.fromJson(op as Map<String, dynamic>);
      final headers = <String, String>{};
      for (final h in parsed.requestHeaders) {
        headers[h.name] = h.value;
      }
      final slice = Uint8List.sublistView(
          bytes, parsed.offset, parsed.offset + parsed.length);
      await client.uploadBinary(
        method: parsed.method,
        url: parsed.url,
        headers: headers,
        bytes: slice,
      );
      totalUploaded += slice.length;
    }
    if (totalUploaded != bytes.length) {
      throw StateError(
          'Upload byte mismatch for $fileName: sent=$totalUploaded expected=${bytes.length}');
    }

    await client.patchJson('/v1/appScreenshots/${reserved.id}', {
      'data': {
        'id': reserved.id,
        'type': 'appScreenshots',
        'attributes': {
          'uploaded': true,
          'sourceFileChecksum': checksum,
        },
      },
    });

    await _awaitAssetReady(reserved.id, fileName);
  }

  Future<void> _awaitAssetReady(String id, String fileName) async {
    const maxAttempts = 20;
    const delay = Duration(seconds: 2);
    for (var i = 0; i < maxAttempts; i++) {
      await Future.delayed(delay);
      final snap = await client.getJson('/v1/appScreenshots/$id');
      final data = (snap['data'] as Map<String, dynamic>?);
      final attrs = (data?['attributes'] as Map<String, dynamic>?) ?? const {};
      final state = (attrs['assetDeliveryState'] as Map<String, dynamic>?) ??
          const {};
      final stateStr = (state['state'] ?? '').toString();
      final errors = (state['errors'] as List?) ?? const [];

      if (stateStr.isEmpty ||
          stateStr == 'UPLOADING' ||
          stateStr == 'AWAITING_UPLOAD') {
        continue;
      }

      if (errors.isNotEmpty || stateStr == 'FAILED') {
        throw AscApiException(
          422,
          'POLL',
          '/v1/appScreenshots/$id',
          'assetDeliveryState=$stateStr errors=$errors',
        );
      }

      _log.success('$fileName: Apple validated upload ($stateStr)',
          scope: 'screenshot');
      return;
    }
    _log.warn(
        '$fileName: still UPLOADING after ${maxAttempts * delay.inSeconds}s; continuing',
        scope: 'screenshot');
  }
}
