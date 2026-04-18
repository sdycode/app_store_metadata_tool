import '../models/asc_resource.dart';
import 'asc_client.dart';
import 'logging.dart';
import 'run_state.dart';

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
    _log.warn(
        'No editable appInfo; falling back to ${infos.first.id}',
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

  Future<List<AscResource>> listLocalizations(String appInfoId) async {
    final list = await client
        .getAllData('/v1/appInfos/$appInfoId/appInfoLocalizations');
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
  }) async {
    await control?.checkpoint();
    final attrs = <String, dynamic>{};
    if (name != null && name.trim().isNotEmpty) attrs['name'] = name.trim();
    if (privacyPolicyUrl != null) {
      if (_isValidHttpUrl(privacyPolicyUrl)) {
        attrs['privacyPolicyUrl'] = privacyPolicyUrl;
      } else if (privacyPolicyUrl.isNotEmpty) {
        _log.warn(
            '$locale: Skipping privacyPolicyUrl — not a valid http/https URL: "$privacyPolicyUrl"',
            scope: 'appinfo');
      }
    }
    if (attrs.isEmpty) return null;

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
      return null;
    }
  }
}
