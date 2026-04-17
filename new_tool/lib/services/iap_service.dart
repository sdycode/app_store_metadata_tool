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
    // Prefer the targeted filter query — cheaper and more reliable than
    // paginating the whole list (which can miss draft IAPs in odd states).
    try {
      final json = await client.getJson(
        '/v1/apps/$appId/inAppPurchasesV2',
        query: {
          'filter[productId]': productId,
          'limit': 1,
        },
      );
      final data = json['data'];
      if (data is List && data.isNotEmpty) {
        final r = AscResource.fromJson(data.first as Map<String, dynamic>);
        _log.debug(
            'IAP lookup by productId=$productId → ${r.id} (state=${r.attributes['state']})',
            scope: 'iap');
        return r;
      }
    } on AscApiException catch (e) {
      _log.warn(
          'IAP filter[productId] lookup failed ($e) — falling back to full list',
          scope: 'iap');
    }
    // Fallback: full paginated list.
    final list = await listForApp(appId);
    _log.debug('IAP fallback list: ${list.length} records', scope: 'iap');
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

  /// Applies [available_in_all_territories] + [territories] from config
  /// to the newly created / existing IAP. Without this the IAP stays in
  /// a draft state and never surfaces on the store.
  Future<void> setAvailability({
    required String iapId,
    required bool availableInAllTerritories,
    required List<String> territoryIds,
  }) async {
    try {
      List<String> territories;
      if (availableInAllTerritories) {
        // Fetch all known territory IDs from Apple.
        final all = await client.getAllData('/v1/territories');
        territories = all
            .map((t) => (t['id'] ?? '').toString())
            .where((id) => id.isNotEmpty)
            .toList();
        _log.info(
            'IAP $iapId: enabling all ${territories.length} territories',
            scope: 'iap');
      } else {
        territories = territoryIds.where((t) => t.isNotEmpty).toList();
        if (territories.isEmpty) {
          _log.warn(
              'IAP $iapId: availability has no territories — skipping',
              scope: 'iap');
          return;
        }
      }

      await client.postJson('/v1/inAppPurchaseAvailabilities', {
        'data': {
          'type': 'inAppPurchaseAvailabilities',
          'attributes': {
            'availableInNewTerritories': availableInAllTerritories,
          },
          'relationships': {
            'inAppPurchase': {
              'data': {'id': iapId, 'type': 'inAppPurchases'},
            },
            'availableTerritories': {
              'data': territories
                  .map((id) => {'id': id, 'type': 'territories'})
                  .toList(),
            },
          },
        },
      });
      _log.success(
          'IAP $iapId: availability set (${territories.length} territories)',
          scope: 'iap');
    } catch (e) {
      // Apple returns 409 if availability already exists for this IAP —
      // that's fine (means it's already published and we don't need to
      // create again). Log it as a warning, not an error.
      _log.warn('IAP $iapId: availability setup failed ($e)', scope: 'iap');
    }
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

  /// Resolves a dollar amount (e.g. "0.99") in a territory to Apple's
  /// opaque inAppPurchasePricePoint ID by going through the IAP's own
  /// relationship (per-IAP scope). The global endpoint
  /// `/v1/inAppPurchasePricePoints` rejects with 403 on most key roles,
  /// so we go through the authorised relationship instead.
  ///
  /// Endpoint: `GET /v1/inAppPurchases/{iapId}/pricePoints?filter[territory]={id}`
  Future<String?> getPricePointId({
    required String iapId,
    required String price,
    required String territory,
  }) async {
    final wanted = double.tryParse(price);
    if (wanted == null) {
      _log.error('pricePoint "$price" is not a number', scope: 'iap');
      return null;
    }
    String path = '/v1/inAppPurchases/$iapId/pricePoints';
    Map<String, dynamic>? query = {
      'filter[territory]': territory,
      'limit': 200,
    };
    int scanned = 0;
    while (true) {
      final json = await client.getJson(path, query: query);
      final data = (json['data'] as List?) ?? const [];
      for (final e in data) {
        scanned++;
        final attrs = (e['attributes'] as Map?) ?? const {};
        final cp = double.tryParse((attrs['customerPrice'] ?? '').toString());
        // Float tolerance avoids rounding mismatches ("0.99" vs "0.9900").
        if (cp != null && (cp - wanted).abs() < 0.001) {
          final id = (e['id'] ?? '').toString();
          _log.debug(
              'pricePoint: resolved $price $territory → $id (scanned $scanned)',
              scope: 'iap');
          return id;
        }
      }
      final next =
          (json['links'] is Map) ? (json['links']['next'] as String?) : null;
      if (next == null) break;
      path = next;
      query = null; // next URL already carries the filter query params
    }
    _log.error(
        'pricePoint: no match for $price $territory (scanned $scanned) — '
        'verify the tier exists in that territory',
        scope: 'iap');
    return null;
  }

  Future<void> setPriceSchedule(
      {required String iapId, required IapPricing pricing}) async {
    if (pricing.pricePoint.isEmpty) return;
    final territory =
        pricing.territory.isEmpty ? 'USA' : pricing.territory;
    _log.info(
        'IAP $iapId: resolving price point for \$${pricing.pricePoint} in $territory',
        scope: 'iap');

    final pointId = await getPricePointId(
      iapId: iapId,
      price: pricing.pricePoint,
      territory: territory,
    );
    if (pointId == null) return;

    // Unique include-id per IAP so concurrent runs don't collide.
    final includeId = 'manual-$iapId';
    // Endpoint is /v1 for BOTH v1 and v2 IAPs; only the relationship key
    // differs (`inAppPurchase` for v1, `inAppPurchaseV2` for v2). The
    // /v2/inAppPurchasePriceSchedules path does not exist.
    try {
      await client.postJson('/v1/inAppPurchasePriceSchedules', {
        'data': {
          'type': 'inAppPurchasePriceSchedules',
          'relationships': {
            'inAppPurchaseV2': {
              'data': {'id': iapId, 'type': 'inAppPurchases'},
            },
            'manualPrices': {
              'data': [
                {'id': includeId, 'type': 'inAppPurchasePrices'},
              ],
            },
          },
        },
        'included': [
          {
            'id': includeId,
            'type': 'inAppPurchasePrices',
            'attributes': {'startDate': null},
            'relationships': {
              'inAppPurchasePricePoint': {
                'data': {
                  'id': pointId,
                  'type': 'inAppPurchasePricePoints',
                },
              },
            },
          },
        ],
      });
      _log.success(
          'IAP $iapId: price set → \$${pricing.pricePoint} $territory (pointId=$pointId)',
          scope: 'iap');
    } on AscApiException catch (e) {
      _log.error(
          'IAP $iapId: price schedule POST failed — $e',
          scope: 'iap');
    } catch (e) {
      _log.error('IAP $iapId: price schedule failed ($e)', scope: 'iap');
    }
  }

  /// Fetches the IAP's existing review screenshot (singular relationship
  /// on V2 IAPs) and deletes it. Returns true on success.
  Future<bool> _deleteExistingReviewScreenshot(String iapId) async {
    try {
      final json = await client.getJson(
          '/v2/inAppPurchases/$iapId/appStoreReviewScreenshot');
      final data = json['data'];
      if (data is Map<String, dynamic>) {
        final id = (data['id'] ?? '').toString();
        if (id.isNotEmpty) {
          await client.delete('/v1/inAppPurchaseAppStoreReviewScreenshots/$id');
          _log.info('IAP review image: deleted existing ($id)', scope: 'iap');
          return true;
        }
      }
    } on AscApiException catch (e) {
      _log.warn('IAP review image: could not fetch existing ($e)',
          scope: 'iap');
    }
    return false;
  }

  Future<String?> uploadReviewImage({
    required String iapId,
    required File image,
  }) async {
    final fileName = p.basename(image.path);
    _log.info(
        '▶ IAP review image: uploading $fileName (${image.path})',
        scope: 'iap');

    final Uint8List bytes;
    try {
      bytes = await image.readAsBytes();
    } catch (e) {
      _log.error('IAP review image: cannot read file: $e', scope: 'iap');
      return null;
    }
    final checksum = md5.convert(bytes).toString();
    _log.debug(
        'IAP review image: size=${bytes.length} md5=$checksum',
        scope: 'iap');

    // Step 1 — reserve. Apple only allows one review screenshot per IAP;
    // if one exists the POST 409s with MEDIA_ASSET_CREATION_NOT_ALLOWED.
    // In that case we delete the existing and retry once so the user's
    // latest image wins.
    Map<String, dynamic> buildReserveBody() => {
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
        };

    Map<String, dynamic>? reserveJson;
    try {
      reserveJson = await client.postJson(
          '/v1/inAppPurchaseAppStoreReviewScreenshots', buildReserveBody());
    } on AscApiException catch (e) {
      final alreadyExists =
          e.statusCode == 409 && e.body.contains('already exists');
      if (!alreadyExists) {
        _log.error('IAP review image: reserve failed ($e)', scope: 'iap');
        return null;
      }
      _log.warn(
          'IAP review image: one already exists — deleting and retrying',
          scope: 'iap');
      final deleted = await _deleteExistingReviewScreenshot(iapId);
      if (!deleted) {
        _log.error(
            'IAP review image: could not remove existing screenshot — skipping',
            scope: 'iap');
        return null;
      }
      try {
        reserveJson = await client.postJson(
            '/v1/inAppPurchaseAppStoreReviewScreenshots', buildReserveBody());
      } on AscApiException catch (e2) {
        _log.error(
            'IAP review image: reserve retry still failed ($e2)',
            scope: 'iap');
        return null;
      }
    }
    final reserved =
        AscResource.fromJson(reserveJson['data'] as Map<String, dynamic>);
    final ops = (reserved.attributes['uploadOperations'] as List?) ?? const [];
    _log.debug(
        'IAP review image: reserved id=${reserved.id} operations=${ops.length}',
        scope: 'iap');

    // Step 2 — upload bytes across every upload operation Apple returned.
    int totalUploaded = 0;
    for (final op in ops) {
      final parsed = AscUploadOperation.fromJson(op as Map<String, dynamic>);
      final headers = <String, String>{};
      for (final h in parsed.requestHeaders) {
        headers[h.name] = h.value;
      }
      final slice = Uint8List.sublistView(
          bytes, parsed.offset, parsed.offset + parsed.length);
      try {
        await client.uploadBinary(
            method: parsed.method,
            url: parsed.url,
            headers: headers,
            bytes: slice);
      } on AscApiException catch (e) {
        _log.error(
            'IAP review image: binary upload failed on ${parsed.method} ${parsed.url} → $e',
            scope: 'iap');
        return null;
      }
      totalUploaded += slice.length;
    }
    if (totalUploaded != bytes.length) {
      _log.error(
          'IAP review image: byte mismatch (sent=$totalUploaded expected=${bytes.length})',
          scope: 'iap');
      return null;
    }
    _log.debug('IAP review image: all $totalUploaded bytes sent', scope: 'iap');

    // Step 3 — commit.
    try {
      await client.patchJson(
          '/v1/inAppPurchaseAppStoreReviewScreenshots/${reserved.id}', {
        'data': {
          'id': reserved.id,
          'type': 'inAppPurchaseAppStoreReviewScreenshots',
          'attributes': {
            'uploaded': true,
            'sourceFileChecksum': checksum,
          },
        },
      });
    } on AscApiException catch (e) {
      _log.error(
          'IAP review image: commit PATCH failed ($e) — Apple rejected the asset',
          scope: 'iap');
      return null;
    }

    _log.success(
        '✓ IAP review image uploaded ($fileName, ${bytes.length} bytes)',
        scope: 'iap');
    return reserved.id;
  }

  Future<IapSyncResult> syncOne({
    required String appId,
    required IapMetadata iap,
    required Workspace workspace,
    RunState? control,
  }) async {
    await control?.checkpoint();
    _log.info(
        '▶ IAP ${iap.productId}: starting sync',
        scope: 'iap');

    // Step 1 — find or create the IAP record.
    final existing = await findByProductId(appId, iap.productId);
    AscResource record;
    String action;
    if (existing != null) {
      record = await patchIap(iapId: existing.id, iap: iap);
      action = 'updated';
      _log.success('IAP ${iap.productId}: patched existing (id=${record.id})',
          scope: 'iap');
    } else {
      try {
        record = await createIap(appId: appId, iap: iap);
        action = 'created';
        _log.success('IAP ${iap.productId}: created (id=${record.id})',
            scope: 'iap');
      } on AscApiException catch (e) {
        // 409 means the productId already exists but listForApp missed it
        // (pagination lag / consistency). Re-lookup and patch.
        if (e.statusCode == 409) {
          _log.warn(
              'IAP ${iap.productId}: 409 on create — re-fetching and patching',
              scope: 'iap');
          final retry = await findByProductId(appId, iap.productId);
          if (retry == null) rethrow;
          record = await patchIap(iapId: retry.id, iap: iap);
          action = 'updated (after 409)';
          _log.success(
              'IAP ${iap.productId}: patched after 409 (id=${record.id})',
              scope: 'iap');
        } else {
          rethrow;
        }
      }
    }

    // Step 2 — localizations (names + descriptions per locale).
    await control?.checkpoint();
    await syncLocalizations(iapId: record.id, iap: iap);

    // Step 3 — pricing (may fail on invalid price_point ID; non-fatal).
    if (iap.pricing != null) {
      await control?.checkpoint();
      await setPriceSchedule(iapId: record.id, pricing: iap.pricing!);
    }

    // Step 4 — territory availability. REQUIRED for the IAP to be visible
    // on the App Store; without this the IAP stays in a draft / hidden state.
    final inApp = workspace.config.inApp;
    if (inApp != null) {
      await control?.checkpoint();
      await setAvailability(
        iapId: record.id,
        availableInAllTerritories: inApp.availableInAllTerritories,
        territoryIds: inApp.territories,
      );
    }

    // Step 5 — review screenshot.
    String? reviewImageId;
    final reviewPath = workspace.config.inApp?.reviewImagePath ?? '';
    if (reviewPath.isEmpty) {
      _log.info('IAP ${iap.productId}: no review_image_path in config',
          scope: 'iap');
    } else {
      await control?.checkpoint();
      final absolute = p.join(workspace.root.path, reviewPath);
      final file = File(absolute);
      _log.debug('IAP review image: resolving $reviewPath → $absolute',
          scope: 'iap');
      if (!await file.exists()) {
        _log.error(
            'IAP ${iap.productId}: review image NOT FOUND at $absolute '
            '— check config.review_image_path and workspace folder structure',
            scope: 'iap');
      } else {
        try {
          reviewImageId =
              await uploadReviewImage(iapId: record.id, image: file);
        } catch (e) {
          _log.error(
              'IAP ${iap.productId}: review image upload threw: $e',
              scope: 'iap');
        }
      }
    }

    _log.success(
        '✓ IAP ${iap.productId}: sync done ($action)',
        scope: 'iap');
    return IapSyncResult(
      productId: iap.productId,
      action: action,
      iapId: record.id,
      reviewImage: reviewImageId,
    );
  }
}
