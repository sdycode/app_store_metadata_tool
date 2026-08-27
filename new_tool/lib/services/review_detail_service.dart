import '../models/asc_resource.dart';
import 'asc_client.dart';
import 'logging.dart';

/// App Review Information — the reviewer-facing block on an app-store
/// version (contact name/phone/email, demo account, and free-text notes).
///
/// Apple stores this as ONE `appStoreReviewDetail` per `appStoreVersion`, not
/// per locale, so a single PATCH covers every locale the version ships in.
///
/// This service deliberately touches only two attributes:
///   * `notes` — filled from `app_review_information_notes.txt`.
///   * `demoAccountRequired` — the "Sign-in required" checkbox, which stays
///     unchecked (false) unless somebody has already turned it on by hand.
/// Contact fields are entered manually in App Store Connect, so they are
/// never sent and therefore never overwritten.
class ReviewDetailService {
  final AscClient client;
  final LoggingService _log = LoggingService.instance;

  ReviewDetailService(this.client);

  /// Reads the version's review detail. Apple returns `data: null` for a
  /// version that has none yet, and 404 on some accounts — both mean
  /// "nothing there yet", so both come back as null instead of throwing.
  Future<AscResource?> find(String versionId) async {
    try {
      final json = await client
          .getJson('/v1/appStoreVersions/$versionId/appStoreReviewDetail');
      final data = json['data'];
      if (data is Map<String, dynamic> && data['id'] != null) {
        return AscResource.fromJson(data);
      }
      return null;
    } on AscApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Pushes [notes] onto the version's review detail, creating the record if
  /// the version has none. Returns the resource that was written.
  ///
  /// [notes] must be non-empty — callers skip the whole step when the notes
  /// file is blank, so an empty value never reaches Apple and can never wipe
  /// notes that are already live.
  Future<AscResource> upsertNotes({
    required String versionId,
    required String notes,
  }) async {
    final trimmed = notes.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('App Review notes are empty; nothing to upload');
    }

    final existing = await find(versionId);

    if (existing == null) {
      // No review detail yet — create one carrying the notes, with sign-in
      // explicitly unchecked so Apple does not prompt for demo credentials.
      final json = await client.postJson('/v1/appStoreReviewDetails', {
        'data': {
          'type': 'appStoreReviewDetails',
          'attributes': {
            'notes': trimmed,
            'demoAccountRequired': false,
          },
          'relationships': {
            'appStoreVersion': {
              'data': {'id': versionId, 'type': 'appStoreVersions'},
            },
          },
        },
      });
      _log.success(
          'App Review notes created (${trimmed.length} chars, '
          'sign-in required: off)',
          scope: 'review-detail');
      return AscResource.fromJson(json['data'] as Map<String, dynamic>);
    }

    final attrs = <String, dynamic>{'notes': trimmed};

    // "Sign-in required" is a manual decision: leave it alone once somebody
    // has turned it on (with demo credentials attached), otherwise pin it to
    // the unchecked default.
    final signInRequired = existing.attributes['demoAccountRequired'] == true;
    if (signInRequired) {
      _log.warn(
          'App Review detail ${existing.id}: "Sign-in required" is already ON '
          '— left untouched (only notes updated)',
          scope: 'review-detail');
    } else {
      attrs['demoAccountRequired'] = false;
    }

    final json =
        await client.patchJson('/v1/appStoreReviewDetails/${existing.id}', {
      'data': {
        'id': existing.id,
        'type': 'appStoreReviewDetails',
        'attributes': attrs,
      },
    });
    _log.success(
        'App Review notes updated (${trimmed.length} chars'
        '${signInRequired ? '' : ', sign-in required: off'})',
        scope: 'review-detail');
    return AscResource.fromJson(json['data'] as Map<String, dynamic>);
  }
}
