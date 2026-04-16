import '../models/asc_resource.dart';
import 'asc_client.dart';
import 'logging.dart';

class AppService {
  final AscClient client;
  final LoggingService _log = LoggingService.instance;

  AppService(this.client);

  Future<AscResource?> findByBundleId(String bundleId) async {
    final json = await client.getJson('/v1/apps', query: {
      'filter[bundleId]': bundleId,
      'limit': 1,
    });
    final data = json['data'];
    if (data is List && data.isNotEmpty) {
      final app = AscResource.fromJson(data.first as Map<String, dynamic>);
      _log.info('App matched: id=${app.id} (bundle=$bundleId)', scope: 'app');
      return app;
    }
    _log.warn('No app found for bundle $bundleId', scope: 'app');
    return null;
  }

  Future<AscResource> requireByBundleId(String bundleId) async {
    final app = await findByBundleId(bundleId);
    if (app == null) {
      throw StateError('App not found for bundleId: $bundleId');
    }
    return app;
  }
}
