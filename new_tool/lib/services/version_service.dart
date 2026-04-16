import '../models/asc_resource.dart';
import 'asc_client.dart';
import 'logging.dart';

class VersionService {
  final AscClient client;
  final LoggingService _log = LoggingService.instance;
  static const List<String> editableStates = [
    'PREPARE_FOR_SUBMISSION',
    'DEVELOPER_REJECTED',
    'REJECTED',
    'METADATA_REJECTED',
    'WAITING_FOR_REVIEW',
    'INVALID_BINARY',
  ];

  VersionService(this.client);

  Future<List<AscResource>> listVersions(String appId) async {
    final list = await client.getAllData(
      '/v1/apps/$appId/appStoreVersions',
      query: {'filter[platform]': 'IOS'},
    );
    return list.map(AscResource.fromJson).toList();
  }

  Future<AscResource?> findEditable(String appId) async {
    final versions = await listVersions(appId);
    for (final v in versions) {
      final state = (v.attributes['appStoreState'] ?? '').toString();
      if (state == 'PREPARE_FOR_SUBMISSION') return v;
    }
    for (final v in versions) {
      final state = (v.attributes['appStoreState'] ?? '').toString();
      if (editableStates.contains(state)) return v;
    }
    return null;
  }

  Future<AscResource?> findByVersionString(
      String appId, String versionString) async {
    final versions = await listVersions(appId);
    for (final v in versions) {
      if ((v.attributes['versionString'] ?? '') == versionString) return v;
    }
    return null;
  }

  Future<AscResource> create(
      {required String appId, required String versionString}) async {
    final json = await client.postJson('/v1/appStoreVersions', {
      'data': {
        'type': 'appStoreVersions',
        'attributes': {
          'versionString': versionString,
          'platform': 'IOS',
        },
        'relationships': {
          'app': {
            'data': {'id': appId, 'type': 'apps'},
          },
        },
      },
    });
    final res = AscResource.fromJson(json['data'] as Map<String, dynamic>);
    _log.success('Created version $versionString (id=${res.id})',
        scope: 'version');
    return res;
  }

  /// Patch version-level attributes (copyright, releaseType, etc).
  /// Silently no-ops when every field is empty.
  Future<AscResource> patchMetadata({
    required String versionId,
    String? copyright,
    String? releaseType,
  }) async {
    final attrs = <String, dynamic>{};
    if (copyright != null && copyright.isNotEmpty) {
      attrs['copyright'] = copyright;
    }
    if (releaseType != null && releaseType.isNotEmpty) {
      attrs['releaseType'] = releaseType;
    }
    if (attrs.isEmpty) {
      return AscResource(
          id: versionId,
          type: 'appStoreVersions',
          attributes: const {},
          relationships: const {});
    }
    final json = await client.patchJson('/v1/appStoreVersions/$versionId', {
      'data': {
        'id': versionId,
        'type': 'appStoreVersions',
        'attributes': attrs,
      },
    });
    return AscResource.fromJson(json['data'] as Map<String, dynamic>);
  }

  Future<AscResource> getOrCreate(
      {required String appId, required String updateVersion}) async {
    if (updateVersion.isEmpty) {
      final existing = await findEditable(appId);
      if (existing != null) {
        _log.info(
            'Using editable version ${existing.attributes['versionString']} (id=${existing.id})',
            scope: 'version');
        return existing;
      }
      _log.info('No editable version; creating 1.0', scope: 'version');
      return create(appId: appId, versionString: '1.0');
    }
    final existing = await findByVersionString(appId, updateVersion);
    if (existing != null) {
      _log.info('Using version $updateVersion (id=${existing.id})',
          scope: 'version');
      return existing;
    }
    _log.info('Version $updateVersion not found; creating', scope: 'version');
    return create(appId: appId, versionString: updateVersion);
  }
}
