import '../models/asc_resource.dart';
import 'asc_client.dart';
import 'logging.dart';
import 'run_state.dart';

// The age-rating questionnaire field sets below mirror the live App Store
// Connect API schema (AgeRatingDeclaration.Attributes, OpenAPI spec v4.3 —
// Apple's 2025 "new age ratings" questionnaire). Verified field-by-field
// against the spec so a fresh upload's unanswered (null) questions still get
// an explicit lowest answer.

/// Age-rating questions whose lowest answer is the string `NONE`. These are
/// the content-frequency questions ("None / Infrequent or Mild / Frequent or
/// Intense") plus the override fields, which also accept `NONE` to mean
/// "no override".
const Set<String> kAgeRatingNoneEnums = {
  'alcoholTobaccoOrDrugUseOrReferences',
  'contests',
  'gamblingSimulated',
  'gunsOrOtherWeapons',
  'horrorOrFearThemes',
  'matureOrSuggestiveThemes',
  'medicalOrTreatmentInformation',
  'profanityOrCrudeHumor',
  'sexualContentGraphicAndNudity',
  'sexualContentOrNudity',
  'violenceCartoonOrFantasy',
  'violenceRealistic',
  'violenceRealisticProlongedGraphicOrSadistic',
  'ageRatingOverride',
  'ageRatingOverrideV2',
  'koreaAgeRatingOverride',
};

/// Age-rating yes/no questions whose lowest answer is `false`. Covers the new
/// 2025 "In-App Controls" (parental controls, age assurance) and
/// "Capabilities" (web access, user-generated content, messaging, advertising)
/// questions, plus deprecated booleans kept in case an older API version still
/// returns them.
const Set<String> kAgeRatingFalseBooleans = {
  'advertising',
  'ageAssurance',
  'gambling',
  'gamblingAndContests',
  'healthOrWellnessTopics',
  'lootBox',
  'messagingAndChat',
  'parentalControls',
  'seventeenPlus',
  'unrestrictedWebAccess',
  'userGeneratedContent',
};

/// Free-text developer URL on the declaration — NOT a content question, so the
/// "lowest answer" pass must leave it untouched (never coerce it to `NONE`).
const String kAgeRatingDeveloperUrlField = 'developerAgeRatingInfoUrl';

/// Wraps the App-level (not version-level) metadata: primary/secondary
/// categories on `appInfos`, and per-locale name / privacyPolicyUrl on
/// `appInfoLocalizations`. The app name in ASC lives here, NOT on
/// `appStoreVersionLocalizations`.
class AppInfoService {
  final AscClient client;
  final LoggingService _log = LoggingService.instance;

  static const List<String> editableStates = [
    'PREPARE_FOR_SUBMISSION',
    'DEVELOPER_REJECTED',
    'REJECTED',
    'METADATA_REJECTED',
    'WAITING_FOR_REVIEW',
  ];

  AppInfoService(this.client);

  Future<List<AscResource>> listAppInfos(String appId) async {
    final list = await client.getAllData('/v1/apps/$appId/appInfos');
    return list.map(AscResource.fromJson).toList();
  }

  /// Apps usually have 2 appInfos (live + editable). Pick the editable one.
  Future<AscResource> findEditable(String appId) async {
    final infos = await listAppInfos(appId);
    if (infos.isEmpty) {
      throw StateError('No appInfos returned for app $appId');
    }
    for (final i in infos) {
      final state = (i.attributes['appStoreState'] ?? '').toString();
      if (state == 'PREPARE_FOR_SUBMISSION') return i;
    }
    for (final i in infos) {
      final state = (i.attributes['appStoreState'] ?? '').toString();
      if (editableStates.contains(state)) return i;
    }
    _log.warn('No editable appInfo; falling back to ${infos.first.id}',
        scope: 'appinfo');
    return infos.first;
  }

  /// PATCHes category relationships on the editable appInfo. Skips silently
  /// if every slot is empty.
  Future<void> patchCategories(
    String appInfoId, {
    String? primaryCategory,
    String? secondaryCategory,
    String? primarySubcategoryOne,
    String? primarySubcategoryTwo,
    String? secondarySubcategoryOne,
    String? secondarySubcategoryTwo,
  }) async {
    final rels = <String, dynamic>{};
    void addRel(String key, String? id) {
      if (id == null || id.isEmpty) return;
      rels[key] = {
        'data': {'id': id, 'type': 'appCategories'},
      };
    }

    addRel('primaryCategory', primaryCategory);
    addRel('secondaryCategory', secondaryCategory);
    addRel('primarySubcategoryOne', primarySubcategoryOne);
    addRel('primarySubcategoryTwo', primarySubcategoryTwo);
    addRel('secondarySubcategoryOne', secondarySubcategoryOne);
    addRel('secondarySubcategoryTwo', secondarySubcategoryTwo);

    if (rels.isEmpty) return;

    try {
      await client.patchJson('/v1/appInfos/$appInfoId', {
        'data': {
          'id': appInfoId,
          'type': 'appInfos',
          'relationships': rels,
        },
      });
      _log.success(
          'appInfo $appInfoId: categories updated (${rels.keys.join(', ')})',
          scope: 'appinfo');
    } on AscApiException catch (e) {
      _log.error('appInfo $appInfoId: category patch failed: $e',
          scope: 'appinfo');
    }
  }

  /// The age-rating questionnaire is a single `ageRatingDeclaration` attached
  /// to the app-level appInfo (just like categories). This answers EVERY
  /// question in Apple's 2025 questionnaire with its lowest-exposure option —
  /// content-frequency enums → `NONE`, the "In-App Controls" / "Capabilities"
  /// yes/no questions → `false`, `kidsAgeBand` → null, override fields →
  /// `NONE` — which is exactly what Apple computes into a 4+ rating. The
  /// `developerAgeRatingInfoUrl` free-text field is left untouched.
  ///
  /// We read the live declaration first and answer from the curated field
  /// sets, so a brand-new app whose questions are still `null` gets every
  /// answer filled (not skipped). Only echoing back attributes Apple actually
  /// returns keeps the PATCH aligned with the caller's API version. Any field
  /// neither in our sets nor a plain yes/no is reported so the user can finish
  /// it by hand rather than risk a wrong value.
  Future<void> setLowestAgeRating(String appInfoId) async {
    final related =
        await client.getJson('/v1/appInfos/$appInfoId/ageRatingDeclaration');
    final data = related['data'];
    if (data is! Map || data['id'] == null) {
      throw StateError(
          'appInfo $appInfoId has no ageRatingDeclaration to update');
    }
    final declId = data['id'].toString();
    final current = (data['attributes'] as Map?) ?? const {};

    // Drive answers from the curated field sets (not the live value's runtime
    // type), so a fresh upload's unanswered (null) questions still get an
    // explicit lowest answer instead of being skipped.
    final attrs = <String, dynamic>{};
    final skipped = <String>[];
    current.forEach((rawKey, value) {
      final key = rawKey.toString();
      if (key == 'kidsAgeBand') {
        // Not a Kids-category app → no age band.
        attrs[key] = null;
      } else if (key == kAgeRatingDeveloperUrlField) {
        // Free-text URL, not a content question — leave whatever the developer
        // set; never coerce it to a content-answer value.
      } else if (kAgeRatingNoneEnums.contains(key)) {
        attrs[key] = 'NONE';
      } else if (kAgeRatingFalseBooleans.contains(key)) {
        attrs[key] = false;
      } else if (value is bool) {
        // Unrecognised yes/no question (e.g. a field Apple adds later) →
        // safest "no".
        attrs[key] = false;
      } else {
        // Unrecognised enum/string/null question: we can't safely guess its
        // value token (it might be a URL or a non-NONE enum), so leave it for
        // the user and surface it below.
        skipped.add(key);
      }
    });

    // Apple rejects sending the legacy override together with the V2 override
    // (409 STATE_ERROR.AGE_RATING_OVERRIDE_V1_AND_V2_NOT_ALLOWED): "The
    // attribute 'ageRatingOverride' cannot be set when 'ageRatingOverrideV2' is
    // set." When the declaration exposes V2 (the new system), keep only V2.
    if (attrs.containsKey('ageRatingOverride') &&
        attrs.containsKey('ageRatingOverrideV2')) {
      attrs.remove('ageRatingOverride');
    }

    if (attrs.isEmpty) {
      throw StateError(
          'ageRatingDeclaration $declId returned no settable attributes');
    }

    // Fast path: one PATCH for everything. A single request is atomic, so if
    // Apple rejects ANY answer the whole batch is rejected and nothing is set.
    // On rejection we fall back to setting each answer in its own PATCH and
    // continue past individual failures, so one problem question can never
    // block all the others.
    try {
      await _patchAgeRatingDeclaration(declId, attrs);
      _log.success(
          'ageRatingDeclaration $declId: set ${attrs.length} answer(s) to the '
          'lowest option in one request (→ 4+)',
          scope: 'age-rating');
    } on AscApiException catch (e) {
      _log.warn(
          'ageRatingDeclaration $declId: combined PATCH rejected ($e). '
          'Retrying field-by-field so one bad answer cannot block the rest…',
          scope: 'age-rating');
      var ok = 0;
      final failed = <String>[];
      for (final entry in attrs.entries) {
        try {
          await _patchAgeRatingDeclaration(declId, {entry.key: entry.value});
          ok++;
        } on AscApiException catch (inner) {
          failed.add(entry.key);
          _log.error(
              'ageRatingDeclaration $declId: "${entry.key}" → ${entry.value} '
              'failed: $inner',
              scope: 'age-rating');
        }
      }
      if (ok > 0) {
        _log.success(
            'ageRatingDeclaration $declId: $ok/${attrs.length} answer(s) set '
            'field-by-field (→ 4+ once every question is answered)',
            scope: 'age-rating');
      }
      if (failed.isNotEmpty) {
        _log.warn(
            'ageRatingDeclaration $declId: ${failed.length} answer(s) could '
            'not be set: ${failed.join(', ')}',
            scope: 'age-rating');
      }
      // Only surface a hard failure if literally nothing went through.
      if (ok == 0) rethrow;
    }

    if (skipped.isNotEmpty) {
      _log.warn(
          'ageRatingDeclaration $declId: ${skipped.length} unrecognised, '
          'unanswered question(s) left untouched: ${skipped.join(', ')}',
          scope: 'age-rating');
    }
  }

  /// PATCHes a partial set of age-rating answers onto one declaration. Used
  /// both for the combined fast path and the per-field fallback.
  Future<void> _patchAgeRatingDeclaration(
      String declId, Map<String, dynamic> attributes) async {
    await client.patchJson('/v1/ageRatingDeclarations/$declId', {
      'data': {
        'id': declId,
        'type': 'ageRatingDeclarations',
        'attributes': attributes,
      },
    });
  }

  Future<List<AscResource>> listLocalizations(String appInfoId) async {
    final list =
        await client.getAllData('/v1/appInfos/$appInfoId/appInfoLocalizations');
    return list.map(AscResource.fromJson).toList();
  }

  bool _isValidHttpUrl(String? s) {
    if (s == null || s.isEmpty) return false;
    final u = Uri.tryParse(s);
    return u != null &&
        u.isAbsolute &&
        (u.scheme == 'http' || u.scheme == 'https');
  }

  /// Upsert a locale-specific app-info record. This is where the visible
  /// app name per-locale is stored. Non-fatal on error.
  Future<AscResource?> upsertLocalization({
    required String appInfoId,
    required String locale,
    String? name,
    String? privacyPolicyUrl,
    RunState? control,
    bool throwOnError = false,
  }) async {
    await control?.checkpoint();
    final attrs = <String, dynamic>{};
    if (name != null && name.trim().isNotEmpty) attrs['name'] = name.trim();
    String? invalidPrivacyReason;
    if (privacyPolicyUrl != null) {
      if (_isValidHttpUrl(privacyPolicyUrl)) {
        attrs['privacyPolicyUrl'] = privacyPolicyUrl;
      } else if (privacyPolicyUrl.isNotEmpty) {
        invalidPrivacyReason =
            'privacyPolicyUrl is not a valid http/https URL: "$privacyPolicyUrl"';
        _log.warn(
            '$locale: Skipping privacyPolicyUrl — not a valid http/https URL: "$privacyPolicyUrl"',
            scope: 'appinfo');
      }
    }
    if (attrs.isEmpty) {
      if (throwOnError && invalidPrivacyReason != null) {
        throw StateError('$locale: $invalidPrivacyReason');
      }
      return null;
    }

    final existing = await listLocalizations(appInfoId);
    final found = existing.firstWhere(
      (e) => (e.attributes['locale'] ?? '') == locale,
      orElse: () => AscResource(
          id: '', type: '', attributes: const {}, relationships: const {}),
    );

    try {
      if (found.id.isNotEmpty) {
        final json =
            await client.patchJson('/v1/appInfoLocalizations/${found.id}', {
          'data': {
            'id': found.id,
            'type': 'appInfoLocalizations',
            'attributes': attrs,
          },
        });
        _log.success(
            '$locale: appInfo localization updated (${attrs.keys.join(', ')})',
            scope: 'appinfo');
        return AscResource.fromJson(json['data'] as Map<String, dynamic>);
      }
      final json = await client.postJson('/v1/appInfoLocalizations', {
        'data': {
          'type': 'appInfoLocalizations',
          'attributes': {
            'locale': locale,
            ...attrs,
          },
          'relationships': {
            'appInfo': {
              'data': {'id': appInfoId, 'type': 'appInfos'},
            },
          },
        },
      });
      _log.success(
          '$locale: appInfo localization created (${attrs.keys.join(', ')})',
          scope: 'appinfo');
      return AscResource.fromJson(json['data'] as Map<String, dynamic>);
    } on AscApiException catch (e) {
      _log.error('$locale: appInfo localization failed: $e', scope: 'appinfo');
      if (throwOnError) rethrow;
      return null;
    }
  }
}
