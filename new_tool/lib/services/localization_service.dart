import '../models/asc_resource.dart';
import 'asc_client.dart';
import 'logging.dart';
import 'run_state.dart';
import 'workspace.dart';

class LocalizationService {
  final AscClient client;
  final LoggingService _log = LoggingService.instance;

  LocalizationService(this.client);

  Future<List<AscResource>> list(String versionId) async {
    final items = await client.getAllData(
      '/v1/appStoreVersions/$versionId/appStoreVersionLocalizations',
    );
    return items.map(AscResource.fromJson).toList();
  }

  Map<String, dynamic> _attrsFor(
    Workspace ws,
    String locale,
    String fallback, {
    Set<String> includeEmptyFields = const <String>{},
  }) {
    final attrs = <String, dynamic>{};
    final description = ws.textFor(ws.descriptions, locale, fallback);
    final keywords = ws.textFor(ws.keywords, locale, fallback);
    final subtitle = ws.textFor(ws.subtitles, locale, fallback);
    final whatsNew = ws.textFor(ws.releaseNotes, locale, fallback);
    if (description.isNotEmpty || includeEmptyFields.contains('description')) {
      attrs['description'] = description;
    }
    if (keywords.isNotEmpty || includeEmptyFields.contains('keywords')) {
      attrs['keywords'] = keywords;
    }
    if (subtitle.isNotEmpty || includeEmptyFields.contains('subtitle')) {
      attrs['subtitle'] = subtitle;
    }
    final isInitialVersion = ws.config.metadata.updateVersion.isEmpty;
    if (!isInitialVersion &&
        (whatsNew.isNotEmpty || includeEmptyFields.contains('whatsNew'))) {
      attrs['whatsNew'] = whatsNew;
    }
    final meta = ws.config.metadata;
    final marketingUrl = meta.marketingUrl ?? '';
    if (marketingUrl.isNotEmpty ||
        includeEmptyFields.contains('marketingUrl')) {
      attrs['marketingUrl'] = marketingUrl;
    }
    final supportUrl = meta.supportUrl ?? '';
    if (supportUrl.isNotEmpty || includeEmptyFields.contains('supportUrl')) {
      attrs['supportUrl'] = supportUrl;
    }
    return attrs;
  }

  String? _extractLockedAttribute(String body) {
    final single =
        RegExp(r"Attribute '([^']+)' cannot be edited").firstMatch(body);
    if (single != null) return single.group(1);
    final unknown =
        RegExp(r"'([^']+)' is not an attribute on").firstMatch(body);
    if (unknown != null) return unknown.group(1);
    return null;
  }

  Future<Map<String, dynamic>> _patchWithRetry(
      String locId, Map<String, dynamic> attrs, String locale) async {
    var working = Map<String, dynamic>.from(attrs);
    const maxRetries = 6;
    for (var i = 0; i < maxRetries; i++) {
      if (working.isEmpty) {
        _log.warn('$locale: no editable attributes left; skipping',
            scope: 'locale');
        return const {};
      }
      try {
        final json = await client.patchJson(
          '/v1/appStoreVersionLocalizations/$locId',
          {
            'data': {
              'id': locId,
              'type': 'appStoreVersionLocalizations',
              'attributes': working,
            },
          },
        );
        return json;
      } on AscApiException catch (e) {
        if (e.statusCode != 409) rethrow;
        final locked = _extractLockedAttribute(e.body);
        if (locked == null || !working.containsKey(locked)) rethrow;
        _log.warn("$locale: dropping locked attribute '$locked' and retrying",
            scope: 'locale');
        working.remove(locked);
      }
    }
    throw StateError('$locale: exceeded retry budget on locked attributes');
  }

  Future<Map<String, dynamic>> _postWithRetry(
      Map<String, dynamic> body, String locale) async {
    final data = body['data'] as Map<String, dynamic>;
    var attrs = Map<String, dynamic>.from(data['attributes'] as Map);
    const maxRetries = 6;
    for (var i = 0; i < maxRetries; i++) {
      data['attributes'] = attrs;
      try {
        return await client.postJson('/v1/appStoreVersionLocalizations', body);
      } on AscApiException catch (e) {
        if (e.statusCode != 409) rethrow;
        final locked = _extractLockedAttribute(e.body);
        if (locked == null || !attrs.containsKey(locked)) rethrow;
        _log.warn("$locale: dropping locked attribute '$locked' and retrying",
            scope: 'locale');
        attrs.remove(locked);
      }
    }
    throw StateError('$locale: exceeded retry budget on locked attributes');
  }

  Future<AscResource> upsert({
    required String versionId,
    required String locale,
    required Workspace workspace,
    RunState? control,
    // When true (Live Update tab), push only the `whatsNew` attribute and
    // leave description / keywords / subtitle / URLs untouched.
    bool onlyWhatsNew = false,
    // When non-null, PATCH only these attribute keys — used by per-field
    // update buttons. Supersedes [onlyWhatsNew] when both are provided.
    Set<String>? onlyFields,
    // Used only by per-field update buttons. When true, include the requested
    // field even if its local value is empty so the PATCH is still attempted.
    bool forcefulUpdate = false,
  }) async {
    await control?.checkpoint();
    final fallback = workspace.config.defaultLanguage;
    final existing = await list(versionId);
    final found = existing.firstWhere(
      (e) => (e.attributes['locale'] ?? '') == locale,
      orElse: () => AscResource(
          id: '', type: '', attributes: const {}, relationships: const {}),
    );
    final full = _attrsFor(
      workspace,
      locale,
      fallback,
      includeEmptyFields:
          forcefulUpdate && onlyFields != null ? onlyFields : const <String>{},
    );
    Map<String, dynamic> attrs;
    if (onlyFields != null) {
      attrs = Map.fromEntries(
          full.entries.where((e) => onlyFields.contains(e.key)));
    } else if (onlyWhatsNew) {
      attrs = full.containsKey('whatsNew')
          ? <String, dynamic>{'whatsNew': full['whatsNew']}
          : <String, dynamic>{};
    } else {
      attrs = full;
    }

    if (found.id.isNotEmpty) {
      if (attrs.isEmpty) {
        _log.info('$locale: no text changes; skipping PATCH',
            scope: 'locale');
        return found;
      }
      final json = await _patchWithRetry(found.id, attrs, locale);
      if (json.isEmpty) return found;
      _log.success('$locale: metadata updated', scope: 'locale');
      return AscResource.fromJson(json['data'] as Map<String, dynamic>);
    }

    final body = {
      'data': {
        'type': 'appStoreVersionLocalizations',
        'attributes': {
          'locale': locale,
          ...attrs,
        },
        'relationships': {
          'appStoreVersion': {
            'data': {'id': versionId, 'type': 'appStoreVersions'},
          },
        },
      },
    };
    final json = await _postWithRetry(body, locale);
    _log.success('$locale: metadata created', scope: 'locale');
    return AscResource.fromJson(json['data'] as Map<String, dynamic>);
  }
}
