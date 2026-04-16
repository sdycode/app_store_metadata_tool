import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/asc_resource.dart';
import 'asc_client.dart';
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

  String detectDisplayType(int width, int height) {
    final long = width > height ? width : height;
    final short = width > height ? height : width;

    if (long == 2868 && short == 1320) return 'APP_IPHONE_69';
    if (long == 2796 && short == 1290) return 'APP_IPHONE_67';
    if (long == 2778 && short == 1284) return 'APP_IPHONE_67';
    if (long == 2688 && short == 1242) return 'APP_IPHONE_65';
    if (long == 2436 && short == 1125) return 'APP_IPHONE_58';
    if (long == 2208 && short == 1242) return 'APP_IPHONE_55';
    if (long == 1334 && short == 750) return 'APP_IPHONE_47';
    if (long == 1136 && short == 640) return 'APP_IPHONE_40';
    if (long == 2732 && short == 2048) return 'APP_IPAD_PRO_3GEN_129';
    if (long == 2064 && short == 2752) return 'APP_IPAD_PRO_129';
    if (long == 2388 && short == 1668) return 'APP_IPAD_PRO_3GEN_11';
    if (long == 2224 && short == 1668) return 'APP_IPAD_105';
    if (long == 2048 && short == 1536) return 'APP_IPAD_97';
    _log.warn('Unknown screenshot size ${width}x$height → APP_IPHONE_67',
        scope: 'screenshot');
    return 'APP_IPHONE_67';
  }

  Map<String, int>? _readImageSize(Uint8List bytes) {
    final png = _readPngSize(bytes);
    if (png != null) return png;
    final jpg = _readJpegSize(bytes);
    if (jpg != null) return jpg;
    return null;
  }

  Map<String, int>? _readPngSize(Uint8List bytes) {
    if (bytes.length < 24) return null;
    const pngSig = [137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != pngSig[i]) return null;
    }
    final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    return {'width': w, 'height': h};
  }

  Map<String, int>? _readJpegSize(Uint8List b) {
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
    var i = 2;
    while (i + 3 < b.length) {
      if (b[i] != 0xFF) return null;
      while (i < b.length && b[i] == 0xFF) {
        i++;
      }
      if (i >= b.length) return null;
      final marker = b[i];
      i++;
      if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
        continue;
      }
      if (i + 1 >= b.length) return null;
      final segLen = (b[i] << 8) | b[i + 1];
      final isSof = (marker >= 0xC0 && marker <= 0xCF) &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (i + 7 >= b.length) return null;
        final h = (b[i + 3] << 8) | b[i + 4];
        final w = (b[i + 5] << 8) | b[i + 6];
        return {'width': w, 'height': h};
      }
      i += segLen;
    }
    return null;
  }

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
    final primaryExists = primary.existsSync();
    final primaryShots = primaryExists ? _listLocalShots(primary) : const <File>[];
    if (primaryExists && primaryShots.isNotEmpty) {
      _log.info('$locale: using own folder (${primaryShots.length} files)',
          scope: 'screenshot');
      return primary;
    }
    final reason = !primaryExists
        ? 'folder not found at ${primary.path}'
        : 'folder has 0 valid images (only .png/.jpg/.jpeg, no hidden files)';
    _log.warn(
        '$locale: FALLBACK to ${ws.config.defaultLanguage} — $reason',
        scope: 'screenshot');
    return ws.screenshotDirFor(ws.config.defaultLanguage);
  }

  Future<ScreenshotUploadOutcome> syncLocale({
    required String localizationId,
    required String locale,
    required Workspace workspace,
    required bool replaceAll,
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

    if (replaceAll) {
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
            '$locale/$displayType: wiped ${shots.length} existing (replace mode)',
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

      final existingShots =
          replaceAll ? <AscResource>[] : await listShots(set.id);

      if (replaceAll) {
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
