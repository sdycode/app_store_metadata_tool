import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/asc_resource.dart';
import '../models/config.dart';
import 'asc_client.dart';
import 'logging.dart';
import 'run_state.dart';
import 'workspace.dart';

class IapSyncResult {
  final String productId;
  final String action;
  final String? iapId;
  final String? reviewImage;
  IapSyncResult(
      {required this.productId,
      required this.action,
      this.iapId,
      this.reviewImage});
}

class IapService {
  final AscClient client;
  final LoggingService _log = LoggingService.instance;

  IapService(this.client);

  Future<List<AscResource>> listForApp(String appId) async {
    final items =
        await client.getAllData('/v1/apps/$appId/inAppPurchasesV2');
    return items.map(AscResource.fromJson).toList();
  }

  Future<AscResource?> findByProductId(String appId, String productId) async {
    final list = await listForApp(appId);
    for (final iap in list) {
      if ((iap.attributes['productId'] ?? '') == productId) return iap;
    }
    return null;
  }

  Future<AscResource> createIap(
      {required String appId, required IapMetadata iap}) async {
    final json = await client.postJson('/v2/inAppPurchases', {
      'data': {
        'type': 'inAppPurchases',
        'attributes': {
          'name': iap.referenceName,
          'productId': iap.productId,
          'inAppPurchaseType': iap.purchaseType,
          'familySharable': iap.familySharable,
          'reviewNote': iap.reviewNotes,
        },
        'relationships': {
          'app': {
            'data': {'id': appId, 'type': 'apps'},
          },
        },
      },
    });
    return AscResource.fromJson(json['data'] as Map<String, dynamic>);
  }

  Future<AscResource> patchIap(
      {required String iapId, required IapMetadata iap}) async {
    final json = await client.patchJson('/v2/inAppPurchases/$iapId', {
      'data': {
        'id': iapId,
        'type': 'inAppPurchases',
        'attributes': {
          'name': iap.referenceName,
          'familySharable': iap.familySharable,
          'reviewNote': iap.reviewNotes,
        },
      },
    });
    return AscResource.fromJson(json['data'] as Map<String, dynamic>);
  }

  Future<void> syncLocalizations(
      {required String iapId, required IapMetadata iap}) async {
    final existing = await client
        .getAllData('/v2/inAppPurchases/$iapId/inAppPurchaseLocalizations');
    final byLocale = <String, AscResource>{};
    for (final e in existing) {
      final r = AscResource.fromJson(e);
      byLocale[(r.attributes['locale'] ?? '') as String] = r;
    }
    for (final loc in iap.localizations) {
      final attrs = {
        'locale': loc.locale,
        'name': loc.name,
        'description': loc.description,
      };
      if (byLocale.containsKey(loc.locale)) {
        final r = byLocale[loc.locale]!;
        await client.patchJson('/v1/inAppPurchaseLocalizations/${r.id}', {
          'data': {
            'id': r.id,
            'type': 'inAppPurchaseLocalizations',
            'attributes': {
              'name': loc.name,
              'description': loc.description,
            },
          },
        });
        _log.success('IAP ${iap.productId} / ${loc.locale}: loc updated',
            scope: 'iap');
      } else {
        await client.postJson('/v1/inAppPurchaseLocalizations', {
          'data': {
            'type': 'inAppPurchaseLocalizations',
            'attributes': attrs,
            'relationships': {
              'inAppPurchaseV2': {
                'data': {'id': iapId, 'type': 'inAppPurchases'},
              },
            },
          },
        });
        _log.success('IAP ${iap.productId} / ${loc.locale}: loc created',
            scope: 'iap');
      }
    }
  }

  Future<void> setPriceSchedule(
      {required String iapId, required IapPricing pricing}) async {
    if (pricing.pricePoint.isEmpty) return;
    try {
      await client.postJson('/v1/inAppPurchasePriceSchedules', {
        'data': {
          'type': 'inAppPurchasePriceSchedules',
          'relationships': {
            'inAppPurchase': {
              'data': {'id': iapId, 'type': 'inAppPurchases'},
            },
            'manualPrices': {
              'data': [
                {'id': 'manual-0', 'type': 'inAppPurchasePrices'},
              ],
            },
          },
        },
        'included': [
          {
            'id': 'manual-0',
            'type': 'inAppPurchasePrices',
            'attributes': {'startDate': null},
            'relationships': {
              'inAppPurchasePricePoint': {
                'data': {
                  'id': pricing.pricePoint,
                  'type': 'inAppPurchasePricePoints',
                },
              },
            },
          },
        ],
      });
      _log.success('IAP $iapId: price point ${pricing.pricePoint} set',
          scope: 'iap');
    } catch (e) {
      _log.warn('IAP $iapId: price schedule failed ($e)', scope: 'iap');
    }
  }

  Future<String?> uploadReviewImage({
    required String iapId,
    required File image,
  }) async {
    final bytes = await image.readAsBytes();
    final fileName = p.basename(image.path);
    final reserveJson =
        await client.postJson('/v1/inAppPurchaseAppStoreReviewScreenshots', {
      'data': {
        'type': 'inAppPurchaseAppStoreReviewScreenshots',
        'attributes': {
          'fileName': fileName,
          'fileSize': bytes.length,
        },
        'relationships': {
          'inAppPurchaseV2': {
            'data': {'id': iapId, 'type': 'inAppPurchases'},
          },
        },
      },
    });
    final reserved =
        AscResource.fromJson(reserveJson['data'] as Map<String, dynamic>);
    final ops = (reserved.attributes['uploadOperations'] as List?) ?? const [];

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
          bytes: slice);
      totalUploaded += slice.length;
    }
    if (totalUploaded != bytes.length) {
      throw StateError(
          'IAP review image byte mismatch: sent=$totalUploaded expected=${bytes.length}');
    }

    final checksum = md5.convert(bytes).toString();
    await client
        .patchJson('/v1/inAppPurchaseAppStoreReviewScreenshots/${reserved.id}', {
      'data': {
        'id': reserved.id,
        'type': 'inAppPurchaseAppStoreReviewScreenshots',
        'attributes': {
          'uploaded': true,
          'sourceFileChecksum': checksum,
        },
      },
    });
    _log.success('IAP review image uploaded ($fileName)', scope: 'iap');
    return reserved.id;
  }

  Future<IapSyncResult> syncOne({
    required String appId,
    required IapMetadata iap,
    required Workspace workspace,
    RunState? control,
  }) async {
    await control?.checkpoint();
    final existing = await findByProductId(appId, iap.productId);
    AscResource record;
    String action;
    if (existing == null) {
      record = await createIap(appId: appId, iap: iap);
      action = 'created';
      _log.success('IAP ${iap.productId} created (id=${record.id})',
          scope: 'iap');
    } else {
      record = await patchIap(iapId: existing.id, iap: iap);
      action = 'updated';
      _log.success('IAP ${iap.productId} updated (id=${record.id})',
          scope: 'iap');
    }

    await control?.checkpoint();
    await syncLocalizations(iapId: record.id, iap: iap);
    if (iap.pricing != null) {
      await setPriceSchedule(iapId: record.id, pricing: iap.pricing!);
    }

    String? reviewImageId;
    final reviewPath = workspace.config.inApp?.reviewImagePath ?? '';
    if (reviewPath.isNotEmpty) {
      final file = File(p.join(workspace.root.path, reviewPath));
      if (await file.exists()) {
        reviewImageId = await uploadReviewImage(iapId: record.id, image: file);
      } else {
        _log.warn('IAP review image missing at $reviewPath', scope: 'iap');
      }
    }

    return IapSyncResult(
      productId: iap.productId,
      action: action,
      iapId: record.id,
      reviewImage: reviewImageId,
    );
  }
}
