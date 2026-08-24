import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/asc_resource.dart';
import 'app_info_service.dart';
import 'app_service.dart';
import 'asc_client.dart';
import 'auth.dart';
import 'iap_service.dart';
import 'localization_service.dart';
import 'logging.dart';
import 'resume_service.dart';
import 'run_state.dart';
import 'screenshot_service.dart';
import 'validation_service.dart';
import 'version_service.dart';
import 'workspace.dart';

/// Built-in locale presets. The UI forces the user to pick one of these two
/// sets regardless of what's declared in config.json. Uploads and screenshot
/// sync run against the selected set; missing locale data falls back to
/// default_language (typically en-US) as the rest of the pipeline already does.
const List<String> kLocaleSet15 = [
  'en-US',
  'ja',
  'en-GB',
  'de-DE',
  'fr-FR',
  'en-AU',
  'en-CA',
  'nl-NL',
  'hi',
  'no',
  'da',
  'fi',
  'it',
  'es-ES',
  'ko',
];

const List<String> kLocaleSet39 = [
  'ar-SA',
  'ca',
  'cs',
  'da',
  'de-DE',
  'el',
  'en-AU',
  'en-CA',
  'en-GB',
  'en-US',
  'es-ES',
  'es-MX',
  'fi',
  'fr-CA',
  'fr-FR',
  'he',
  'hi',
  'hr',
  'hu',
  'id',
  'it',
  'ja',
  'ko',
  'ms',
  'nl-NL',
  'no',
  'pl',
  'pt-BR',
  'pt-PT',
  'ro',
  'ru',
  'sk',
  'sv',
  'th',
  'tr',
  'uk',
  'vi',
  'zh-Hans',
  'zh-Hant',
];

class _LocaleUploadFailure {
  final String step;
  final String locale;
  final String reason;

  const _LocaleUploadFailure({
    required this.step,
    required this.locale,
    required this.reason,
  });

  String get copyLine => '$step | $locale | $reason';
}

const Map<String, String> _metadataCheckLabels = {
  'name': 'Name',
  'description': 'Description',
  'keywords': 'Keywords',
  'subtitle': 'Subtitle',
  'release-notes': 'Release Notes',
  'marketing-url': 'Marketing URL',
  'support-url': 'Support URL',
  'privacy-url': 'Privacy URL',
  'copyright': 'Copyright',
  'category': 'Category',
};

const Set<String> _versionLocaleCheckFields = {
  'description',
  'keywords',
  'subtitle',
  'release-notes',
  'marketing-url',
  'support-url',
};

const Set<String> _appInfoLocaleCheckFields = {
  'name',
  'privacy-url',
};

class _ScreenshotReadiness {
  final Map<String, int> totalByDisplay = <String, int>{};
  final Map<String, int> readyByDisplay = <String, int>{};
  final Map<String, int> inProcessByDisplay = <String, int>{};
  final Map<String, int> stateCounts = <String, int>{};

  void addSet(String display, List<AscResource> shots) {
    final key = display.isEmpty ? '(unknown display)' : display;
    var readyCount = 0;
    for (final shot in shots) {
      final state = _screenshotDeliveryState(shot);
      stateCounts[state] = (stateCounts[state] ?? 0) + 1;
      if (state == 'COMPLETE') readyCount++;
    }
    final inProcessCount = shots.length - readyCount;
    totalByDisplay[key] = (totalByDisplay[key] ?? 0) + shots.length;
    readyByDisplay[key] = (readyByDisplay[key] ?? 0) + readyCount;
    if (inProcessCount > 0) {
      inProcessByDisplay[key] = (inProcessByDisplay[key] ?? 0) + inProcessCount;
    }
  }

  int get total => _sumCounts(totalByDisplay.values);
  int get ready => _sumCounts(readyByDisplay.values);
  int get inProcess => total - ready;

  Map<String, dynamic> toJson() => {
        'totalByDisplay': totalByDisplay,
        'readyByDisplay': readyByDisplay,
        'inProcessByDisplay': inProcessByDisplay,
        'stateCounts': stateCounts,
        'total': total,
        'ready': ready,
        'inProcess': inProcess,
      };
}

int _sumCounts(Iterable<int> values) => values.fold<int>(0, (a, b) => a + b);

String _screenshotDeliveryState(AscResource shot) {
  final raw = shot.attributes['assetDeliveryState'];
  if (raw is Map) {
    final state = (raw['state'] ?? '').toString().trim();
    if (state.isNotEmpty) return state.toUpperCase();
  }
  return 'UNKNOWN';
}

String _formatCounts(Map<String, int> counts, {bool includeZero = false}) {
  final entries = counts.entries
      .where((e) => includeZero || e.value > 0)
      .map((e) => '${e.key}:${e.value}')
      .toList();
  return entries.isEmpty ? '-' : entries.join(', ');
}

String _stateBreakdown(_ScreenshotReadiness readiness) {
  if (readiness.stateCounts.isEmpty) return '';
  return ', states=${_formatCounts(readiness.stateCounts)}';
}

String _ssIssueLine(
  String locale,
  int localCount,
  _ScreenshotReadiness readiness,
  String fallbackNote,
) {
  return '$locale: local=$localCount, ready=${readiness.ready}, '
      'inProcess=${readiness.inProcess}, total=${readiness.total}'
      '$fallbackNote${_stateBreakdown(readiness)}';
}

class OrchestratorRuntime {
  final Workspace workspace;
  final AuthService auth;
  final AscClient client;
  final AppService apps;
  final VersionService versions;
  final LocalizationService locs;
  final ScreenshotService screenshots;
  final IapService iap;
  final AppInfoService appInfo;
  final ValidationService validator;
  final ResumeService resume;

  OrchestratorRuntime({
    required this.workspace,
    required this.auth,
    required this.client,
    required this.apps,
    required this.versions,
    required this.locs,
    required this.screenshots,
    required this.iap,
    required this.appInfo,
    required this.validator,
    required this.resume,
  });

  factory OrchestratorRuntime.build(Workspace ws) {
    final auth = AuthService(creds: ws.config.creds, p8Key: ws.p8Key);
    final client = AscClient(auth);
    return OrchestratorRuntime(
      workspace: ws,
      auth: auth,
      client: client,
      apps: AppService(client),
      versions: VersionService(client),
      locs: LocalizationService(client),
      screenshots: ScreenshotService(client),
      iap: IapService(client),
      appInfo: AppInfoService(client),
      validator: ValidationService(),
      resume: ResumeService(Directory(p.join(ws.root.path, '.asc_resume'))),
    );
  }

  void dispose() => client.close();
}

class Orchestrator {
  final OrchestratorRuntime r;
  final LoggingService _log = LoggingService.instance;
  final RunState control = RunState();
  Set<String> selectedLocales;

  /// Which built-in locale set (15 or 39) is active. Supersedes config.
  /// Auto-detected on construction from config.localizations.length; user
  /// can switch via the UI radios.
  List<String> activeLocaleSet;
  String get activeLocaleSetName =>
      activeLocaleSet.length == kLocaleSet39.length ? '39' : '15';

  /// Force wipe + re-upload all existing screenshots regardless of count.
  /// Both checkboxes default to true; user can toggle independently.
  bool forcefulReplace = true;

  /// When forcefulReplace is false: still delete + re-upload if the local
  /// file count differs from App Store's existing count. If both flags are
  /// false, we only upload into empty sets and never touch existing assets.
  bool replaceOnMismatch = true;

  /// True when the Live Update tab is selected. In that mode
  /// [uploadMetadata] only pushes per-locale `whatsNew` values and skips
  /// copyright / app-info (category / name / privacyPolicyUrl) updates,
  /// because those are carried over from the previously shipped version.
  bool liveUpdateMode = false;

  /// Default-off override for the individual per-locale field buttons.
  /// Full metadata uploads keep the normal empty-field skip behavior.
  bool forcefulIndividualUpdate = false;

  Orchestrator(this.r)
      : activeLocaleSet = _autoPreset(r.workspace.config.localizations),
        selectedLocales =
            Set<String>.from(_autoPreset(r.workspace.config.localizations));

  /// Pick the closer built-in preset based on how many locales the config
  /// declares. Config with ~39 locales → 39-set; anything smaller → 15-set.
  static List<String> _autoPreset(List<String> configLocales) {
    return configLocales.length >= kLocaleSet39.length - 4
        ? kLocaleSet39
        : kLocaleSet15;
  }

  /// Switch preset at runtime (called from the UI radio). Resets
  /// [selectedLocales] to the full new preset so the chips are consistent.
  void useLocaleSet(String name) {
    activeLocaleSet = name == '39' ? kLocaleSet39 : kLocaleSet15;
    selectedLocales = Set<String>.from(activeLocaleSet);
  }

  List<String> _effectiveLocales() {
    // SELECTED preset is the source of truth, not config.json. If config
    // declares fewer locales, downstream services still attempt uploads for
    // every selected locale — missing per-locale text falls back to
    // default_language (usually en-US) as the rest of the pipeline does.
    return activeLocaleSet.where(selectedLocales.contains).toList();
  }

  String _failureReason(Object error) {
    final text = error.toString().trim();
    if (text.isEmpty) return error.runtimeType.toString();
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  void _addUnique(List<String> target, String value) {
    if (!target.contains(value)) target.add(value);
  }

  String _metadataLabel(String field) => _metadataCheckLabels[field] ?? field;

  String _metadataFieldList(Iterable<String> fields) =>
      fields.map(_metadataLabel).join(', ');

  Map<String, AscResource> _byLocale(List<AscResource> resources) {
    final out = <String, AscResource>{};
    for (final resource in resources) {
      final locale = (resource.attributes['locale'] ?? '').toString();
      if (locale.isNotEmpty) out[locale] = resource;
    }
    return out;
  }

  Future<AscResource?> _findVersionForChecks(String appId) async {
    final updateVersion = r.workspace.config.metadata.updateVersion.trim();
    if (updateVersion.isNotEmpty) {
      final exact = await r.versions.findByVersionString(appId, updateVersion);
      if (exact != null) return exact;
    }
    return r.versions.findEditable(appId);
  }

  String _versionAttrForCheckField(String field) {
    switch (field) {
      case 'description':
        return 'description';
      case 'keywords':
        return 'keywords';
      case 'subtitle':
        return 'subtitle';
      case 'release-notes':
        return 'whatsNew';
      case 'marketing-url':
        return 'marketingUrl';
      case 'support-url':
        return 'supportUrl';
    }
    throw StateError('Unknown version metadata check field: $field');
  }

  String _sourceFileForVersionField(String field) {
    switch (field) {
      case 'description':
        return 'description.json';
      case 'keywords':
        return 'keywords.json';
      case 'subtitle':
        return 'subtitle.json';
      case 'release-notes':
        return 'releasenotes.json';
      case 'marketing-url':
        return 'config.json metadata.marketing_url';
      case 'support-url':
        return 'config.json metadata.support_url';
    }
    throw StateError('Unknown version metadata check field: $field');
  }

  String _localVersionValue(Workspace ws, String field, String locale) {
    switch (field) {
      case 'description':
        return ws.textFor(ws.descriptions, locale, ws.config.defaultLanguage);
      case 'keywords':
        return ws.textFor(ws.keywords, locale, ws.config.defaultLanguage);
      case 'subtitle':
        return ws.textFor(ws.subtitles, locale, ws.config.defaultLanguage);
      case 'release-notes':
        return ws.textFor(ws.releaseNotes, locale, ws.config.defaultLanguage);
      case 'marketing-url':
        return (ws.config.metadata.marketingUrl ?? '').trim();
      case 'support-url':
        return (ws.config.metadata.supportUrl ?? '').trim();
    }
    throw StateError('Unknown version metadata check field: $field');
  }

  bool _hasOwnVersionValue(Workspace ws, String field, String locale) {
    switch (field) {
      case 'description':
        return ws.descriptions.containsKey(locale);
      case 'keywords':
        return ws.keywords.containsKey(locale);
      case 'subtitle':
        return ws.subtitles.containsKey(locale);
      case 'release-notes':
        return ws.releaseNotes.containsKey(locale);
      case 'marketing-url':
      case 'support-url':
        return true;
    }
    throw StateError('Unknown version metadata check field: $field');
  }

  String _appInfoAttrForCheckField(String field) {
    switch (field) {
      case 'name':
        return 'name';
      case 'privacy-url':
        return 'privacyPolicyUrl';
    }
    throw StateError('Unknown app-info metadata check field: $field');
  }

  String _localAppInfoValue(Workspace ws, String field, String locale) {
    switch (field) {
      case 'name':
        final specific = ws.config.specificNameLocales[locale]?.trim();
        if (specific != null && specific.isNotEmpty) return specific;
        return (ws.config.metadata.name ?? '').trim();
      case 'privacy-url':
        return (ws.config.metadata.privacyUrl ?? '').trim();
    }
    throw StateError('Unknown app-info metadata check field: $field');
  }

  bool _hasOwnAppInfoValue(Workspace ws, String field, String locale) {
    switch (field) {
      case 'name':
        final specific = ws.config.specificNameLocales[locale]?.trim();
        return specific != null && specific.isNotEmpty;
      case 'privacy-url':
        return true;
    }
    throw StateError('Unknown app-info metadata check field: $field');
  }

  bool _isValidHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.isAbsolute &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  String _lengthLabel(String value) => '${value.length} chars';

  String? _relationshipId(dynamic relationship) {
    if (relationship is! Map) return null;
    final data = relationship['data'];
    if (data is! Map) return null;
    final id = data['id'];
    return id?.toString();
  }

  Future<String?> _readPrimaryCategoryId(String appInfoId) async {
    final json = await r.client
        .getJson('/v1/appInfos/$appInfoId/relationships/primaryCategory');
    return _relationshipId(json);
  }

  void _recordLocaleFailure(
    List<_LocaleUploadFailure> failures, {
    required String step,
    required String locale,
    Object? error,
    String? reason,
  }) {
    final failure = _LocaleUploadFailure(
      step: step,
      locale: locale,
      reason:
          reason ?? (error == null ? 'unknown error' : _failureReason(error)),
    );
    failures.add(failure);
    _log.error('$locale $step failed: ${failure.reason}',
        scope: 'orchestrator');
  }

  void _logLocaleFailureSummary(
    String title,
    List<_LocaleUploadFailure> failures, {
    int startIndex = 0,
  }) {
    final relevant = failures.skip(startIndex).toList(growable: false);
    if (relevant.isEmpty) {
      _log.success('$title: no per-locale failures', scope: 'upload-summary');
      return;
    }

    final out = StringBuffer()
      ..writeln('$title: ${relevant.length} per-locale failure(s)')
      ..writeln('Copyable summary:')
      ..writeln('step | locale | reason');
    for (final failure in relevant) {
      out.writeln(failure.copyLine);
    }
    _log.error(out.toString().trimRight(), scope: 'upload-summary');
  }

  Future<T?> runGuarded<T>(String label, Future<T> Function() body) async {
    control.startRun(label);
    try {
      return await body();
    } on CancelledException {
      _log.warn('$label: cancelled by user', scope: 'orchestrator');
      return null;
    } finally {
      control.endRun();
    }
  }

  Future<bool> checkAuth() async {
    try {
      final token = await r.auth.getToken();
      _log.info('JWT minted (${token.length} chars)', scope: 'auth');
      await r.client.getJson('/v1/apps', query: {'limit': 1});
      _log.success('Auth OK — Apple accepted the JWT', scope: 'auth');
      return true;
    } on AscApiException catch (e) {
      if (e.statusCode == 401) {
        _log.error('Auth FAILED — 401: check key_id / issuer_id / .p8 match',
            scope: 'auth');
      } else {
        _log.error('Auth check failed: $e', scope: 'auth');
      }
      return false;
    } catch (e) {
      _log.error('Auth check failed (local): $e', scope: 'auth');
      return false;
    }
  }

  Future<void> uploadMetadata() => _uploadMetadata();

  Future<void> _uploadMetadata({
    List<_LocaleUploadFailure>? failureSink,
    bool logSummary = true,
  }) async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to upload',
          scope: 'orchestrator');
      return;
    }
    final failures = failureSink ?? <_LocaleUploadFailure>[];
    final summaryStart = failures.length;
    final state = await r.resume
        .load(ws.config.metadata.packageId, ws.config.metadata.updateVersion);

    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.getOrCreate(
      appId: app.id,
      updateVersion: ws.config.metadata.updateVersion,
    );
    state.versionDone = true;
    await r.resume.save(
        ws.config.metadata.packageId, ws.config.metadata.updateVersion, state);

    for (final locale in locales) {
      try {
        await control.checkpoint();
        await r.locs.upsert(
          versionId: version.id,
          locale: locale,
          workspace: ws,
          control: control,
          onlyWhatsNew: liveUpdateMode,
        );
        state.metadataByLocale[locale] = true;
        await r.resume.save(ws.config.metadata.packageId,
            ws.config.metadata.updateVersion, state);
      } on CancelledException {
        rethrow;
      } catch (e) {
        _recordLocaleFailure(
          failures,
          step: 'version metadata',
          locale: locale,
          error: e,
        );
      }
    }

    if (liveUpdateMode) {
      _log.info('Live Update mode: only whatsNew per locale was pushed',
          scope: 'orchestrator');
      if (forcefulIndividualUpdate) {
        _log.warn(
            'Forcefull Update applies only to the individual field buttons; Upload Metadata still pushes only release notes in Live Update mode',
            scope: 'orchestrator');
      }
    }

    // App-level metadata (categories + per-locale name + privacyPolicyUrl).
    // Runs in BOTH New Push and Live Update — the app name is App-level,
    // not Version-level, so Apple won't auto-inherit it between versions.
    // User explicitly asked to forcefully push it on every upload.
    await _applyAppInfo(app.id, locales, failures);
    if (logSummary) {
      _logLocaleFailureSummary(
        'Upload Metadata',
        failures,
        startIndex: summaryStart,
      );
    }
  }

  /// PATCHes the editable appInfo with primary category + per-locale name
  /// + privacyPolicyUrl. Non-fatal — if a locale fails, the rest proceed.
  Future<void> _applyAppInfo(
    String appId,
    List<String> locales,
    List<_LocaleUploadFailure> failures,
  ) async {
    final ws = r.workspace;
    final meta = ws.config.metadata;
    final primaryCategory = (meta.primaryCategory ?? '').trim();
    final privacyUrl = (meta.privacyUrl ?? '').trim();
    final defaultName = (meta.name ?? '').trim();
    final specific = ws.config.specificNameLocales;

    final hasName = defaultName.isNotEmpty || specific.isNotEmpty;
    if (primaryCategory.isEmpty && privacyUrl.isEmpty && !hasName) {
      _log.info('app-info: nothing to push (no name / category / privacy_url)',
          scope: 'orchestrator');
      return;
    }

    final AscResource appInfo;
    try {
      appInfo = await r.appInfo.findEditable(appId);
    } catch (e) {
      _log.error('app-info step skipped: $e', scope: 'orchestrator');
      return;
    }

    if (primaryCategory.isNotEmpty) {
      try {
        await control.checkpoint();
        await r.appInfo.patchCategories(
          appInfo.id,
          primaryCategory: primaryCategory,
        );
      } on CancelledException {
        rethrow;
      } catch (e) {
        _log.error('category patch failed: $e', scope: 'orchestrator');
      }
    }

    if (!hasName && privacyUrl.isEmpty) return;

    for (final locale in locales) {
      try {
        await control.checkpoint();
        final perLocale = specific[locale]?.trim();
        final nameForLocale = (perLocale != null && perLocale.isNotEmpty)
            ? perLocale
            : defaultName;
        await r.appInfo.upsertLocalization(
          appInfoId: appInfo.id,
          locale: locale,
          name: nameForLocale.isEmpty ? null : nameForLocale,
          privacyPolicyUrl: privacyUrl.isEmpty ? null : privacyUrl,
          control: control,
          throwOnError: true,
        );
      } on CancelledException {
        rethrow;
      } catch (e) {
        _recordLocaleFailure(
          failures,
          step: 'app info',
          locale: locale,
          error: e,
        );
      }
    }
  }

  // =====================================================================
  // Per-field update entry points. Each button in the UI hits one of these
  // so the uploader can push just a single attribute across all selected
  // locales, without touching the rest.
  // =====================================================================

  Future<void> _runPerLocaleVersionField(String attrKey, String label) async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to upload',
          scope: 'orchestrator');
      return;
    }
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.getOrCreate(
      appId: app.id,
      updateVersion: ws.config.metadata.updateVersion,
    );
    _log.info(
        'target version ${version.attributes['versionString'] ?? '(unknown)'} '
        '(id=${version.id}, state=${version.attributes['appStoreState'] ?? version.attributes['appVersionState'] ?? 'unknown'}, '
        'forcefull=${forcefulIndividualUpdate ? 'on' : 'off'})',
        scope: 'orchestrator');
    _log.info('▶ update $label → ${locales.length} locale(s)',
        scope: 'orchestrator');
    final failures = <_LocaleUploadFailure>[];
    for (final locale in locales) {
      try {
        await control.checkpoint();
        await r.locs.upsert(
          versionId: version.id,
          locale: locale,
          workspace: ws,
          control: control,
          onlyFields: {attrKey},
          forcefulUpdate: forcefulIndividualUpdate,
        );
      } on CancelledException {
        rethrow;
      } catch (e) {
        _recordLocaleFailure(
          failures,
          step: label,
          locale: locale,
          error: e,
        );
      }
    }
    _logLocaleFailureSummary('Update $label', failures);
  }

  Future<void> updateDescription() =>
      _runPerLocaleVersionField('description', 'description');
  Future<void> updateKeywords() =>
      _runPerLocaleVersionField('keywords', 'keywords');
  Future<void> updateSubtitle() =>
      _runPerLocaleVersionField('subtitle', 'subtitle');
  bool get _releaseNotesActionsAllowed =>
      liveUpdateMode &&
      r.workspace.config.metadata.updateVersion.trim().isNotEmpty;

  String get _releaseNotesLiveOnlyMessage =>
      'Release Notes is available only on the Live Update tab with a non-empty config.json metadata.update_version';

  Future<void> updateReleaseNotes() async {
    if (!_releaseNotesActionsAllowed) {
      _log.warn(_releaseNotesLiveOnlyMessage, scope: 'orchestrator');
      return;
    }
    await _runPerLocaleVersionField('whatsNew', 'release notes');
  }

  Future<void> updateMarketingUrl() =>
      _runPerLocaleVersionField('marketingUrl', 'marketing URL');
  Future<void> updateSupportUrl() =>
      _runPerLocaleVersionField('supportUrl', 'support URL');

  /// Version-level copyright (single PATCH on the version, not per-locale).
  Future<void> updateCopyright() async {
    final ws = r.workspace;
    final copyright = (ws.config.metadata.copyright ?? '').trim();
    if (copyright.isEmpty) {
      _log.warn('copyright is empty in config.json; nothing to push',
          scope: 'orchestrator');
      return;
    }
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.getOrCreate(
      appId: app.id,
      updateVersion: ws.config.metadata.updateVersion,
    );
    try {
      await r.versions
          .patchMetadata(versionId: version.id, copyright: copyright);
      _log.success('copyright set to "$copyright"', scope: 'orchestrator');
    } catch (e) {
      _log.error('copyright patch failed: $e', scope: 'orchestrator');
    }
  }

  /// App-name per selected locale (AppInfoLocalization.name).
  Future<void> updateAppName() async {
    await _applyAppInfoSubset(includeName: true);
  }

  /// Privacy policy URL per selected locale (AppInfoLocalization.privacyPolicyUrl).
  Future<void> updatePrivacyUrl() async {
    await _applyAppInfoSubset(includePrivacyUrl: true);
  }

  /// Primary category on the app-level appInfo (once, not per-locale).
  Future<void> updatePrimaryCategory() async {
    final ws = r.workspace;
    final cat = (ws.config.metadata.primaryCategory ?? '').trim();
    if (cat.isEmpty) {
      _log.warn('primary_category is empty in config.json; nothing to push',
          scope: 'orchestrator');
      return;
    }
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    try {
      final appInfo = await r.appInfo.findEditable(app.id);
      await r.appInfo.patchCategories(appInfo.id, primaryCategory: cat);
    } catch (e) {
      _log.error('primary-category update failed: $e', scope: 'orchestrator');
    }
  }

  /// Age-rating questionnaire on the app-level appInfo. One click answers
  /// every question with its lowest-exposure option (→ 4+). App-level like
  /// the category, so it ignores the selected-locale set. Reads nothing from
  /// config.json — the "lowest everything" answers are fixed.
  Future<void> updateAgeRating() async {
    final ws = r.workspace;
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    try {
      final appInfo = await r.appInfo.findEditable(app.id);
      await r.appInfo.setLowestAgeRating(appInfo.id);
    } catch (e) {
      _log.error('age-rating update failed: $e', scope: 'orchestrator');
    }
  }

  Future<void> _applyAppInfoSubset({
    bool includeName = false,
    bool includePrivacyUrl = false,
  }) async {
    final ws = r.workspace;
    final meta = ws.config.metadata;
    final defaultName = (meta.name ?? '').trim();
    final privacyUrl = (meta.privacyUrl ?? '').trim();
    final specific = ws.config.specificNameLocales;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to upload',
          scope: 'orchestrator');
      return;
    }
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final appInfo = await r.appInfo.findEditable(app.id);
    final label = [
      if (includeName) 'name',
      if (includePrivacyUrl) 'privacy URL',
    ].join(' + ');
    final failures = <_LocaleUploadFailure>[];
    for (final locale in locales) {
      try {
        await control.checkpoint();
        String? nameForLocale;
        if (includeName) {
          final perLocale = specific[locale]?.trim();
          nameForLocale = (perLocale != null && perLocale.isNotEmpty)
              ? perLocale
              : defaultName;
          if (nameForLocale.isEmpty) nameForLocale = null;
        }
        await r.appInfo.upsertLocalization(
          appInfoId: appInfo.id,
          locale: locale,
          name: nameForLocale,
          privacyPolicyUrl:
              includePrivacyUrl && privacyUrl.isNotEmpty ? privacyUrl : null,
          control: control,
          throwOnError: true,
        );
      } on CancelledException {
        rethrow;
      } catch (e) {
        _recordLocaleFailure(
          failures,
          step: 'app info $label',
          locale: locale,
          error: e,
        );
      }
    }
    _logLocaleFailureSummary('Update $label', failures);
  }

  Future<void> uploadScreenshots() => _uploadScreenshots();

  Future<void> _uploadScreenshots({
    List<_LocaleUploadFailure>? failureSink,
    bool logSummary = true,
  }) async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to upload',
          scope: 'orchestrator');
      return;
    }
    final failures = failureSink ?? <_LocaleUploadFailure>[];
    final summaryStart = failures.length;
    final state = await r.resume
        .load(ws.config.metadata.packageId, ws.config.metadata.updateVersion);

    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.getOrCreate(
      appId: app.id,
      updateVersion: ws.config.metadata.updateVersion,
    );
    final existingLocalizations = await r.locs.list(version.id);

    for (final locale in locales) {
      try {
        await control.checkpoint();
        final loc = existingLocalizations.firstWhere(
          (e) => (e.attributes['locale'] ?? '') == locale,
          orElse: () => AscResource(
              id: '', type: '', attributes: const {}, relationships: const {}),
        );
        String localizationId = loc.id;
        if (localizationId.isEmpty) {
          final created = await r.locs.upsert(
              versionId: version.id,
              locale: locale,
              workspace: ws,
              control: control);
          localizationId = created.id;
        }
        if (localizationId.isEmpty) {
          _recordLocaleFailure(
            failures,
            step: 'screenshots',
            locale: locale,
            reason: 'no localization id; skipped screenshots',
          );
          continue;
        }
        final outcome = await r.screenshots.syncLocale(
          localizationId: localizationId,
          locale: locale,
          workspace: ws,
          forcefulReplace: forcefulReplace,
          replaceOnMismatch: replaceOnMismatch,
          control: control,
        );
        _log.info(
            '$locale: action=${outcome.action} uploaded=${outcome.uploaded} deleted=${outcome.deleted}',
            scope: 'orchestrator');
        state.screenshotsByLocale[locale] = true;
        await r.resume.save(ws.config.metadata.packageId,
            ws.config.metadata.updateVersion, state);
      } on CancelledException {
        rethrow;
      } catch (e) {
        _recordLocaleFailure(
          failures,
          step: 'screenshots',
          locale: locale,
          error: e,
        );
      }
    }
    if (logSummary) {
      _logLocaleFailureSummary(
        'Upload Screenshots',
        failures,
        startIndex: summaryStart,
      );
    }
  }

  Future<void> uploadIpadScreenshots() => _uploadIpadScreenshots();

  /// Same shape as [_uploadScreenshots] but reads `screenshots/ipad/<locale>`
  /// and only ever writes iPad display-type sets, so the iPhone assets on the
  /// same localization are left alone.
  Future<void> _uploadIpadScreenshots({
    List<_LocaleUploadFailure>? failureSink,
    bool logSummary = true,
  }) async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to upload',
          scope: 'orchestrator');
      return;
    }
    if (!ws.ipadScreenshotsRoot.existsSync()) {
      _log.warn(
          'No screenshots/ipad folder in this workspace — nothing to upload. '
          'Expected layout: screenshots/ipad/<locale>/*.png',
          scope: 'orchestrator');
      return;
    }
    final failures = failureSink ?? <_LocaleUploadFailure>[];
    final summaryStart = failures.length;
    final state = await r.resume
        .load(ws.config.metadata.packageId, ws.config.metadata.updateVersion);

    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.getOrCreate(
      appId: app.id,
      updateVersion: ws.config.metadata.updateVersion,
    );
    final existingLocalizations = await r.locs.list(version.id);

    for (final locale in locales) {
      try {
        await control.checkpoint();
        final loc = existingLocalizations.firstWhere(
          (e) => (e.attributes['locale'] ?? '') == locale,
          orElse: () => AscResource(
              id: '', type: '', attributes: const {}, relationships: const {}),
        );
        String localizationId = loc.id;
        if (localizationId.isEmpty) {
          final created = await r.locs.upsert(
              versionId: version.id,
              locale: locale,
              workspace: ws,
              control: control);
          localizationId = created.id;
        }
        if (localizationId.isEmpty) {
          _recordLocaleFailure(
            failures,
            step: 'ipad-screenshots',
            locale: locale,
            reason: 'no localization id; skipped iPad screenshots',
          );
          continue;
        }
        final outcome = await r.screenshots.syncLocaleIpad(
          localizationId: localizationId,
          locale: locale,
          workspace: ws,
          forcefulReplace: forcefulReplace,
          replaceOnMismatch: replaceOnMismatch,
          control: control,
        );
        _log.info(
            '$locale (iPad): action=${outcome.action} uploaded=${outcome.uploaded} deleted=${outcome.deleted}',
            scope: 'orchestrator');
        state.ipadScreenshotsByLocale[locale] = true;
        await r.resume.save(ws.config.metadata.packageId,
            ws.config.metadata.updateVersion, state);
      } on CancelledException {
        rethrow;
      } catch (e) {
        _recordLocaleFailure(
          failures,
          step: 'ipad-screenshots',
          locale: locale,
          error: e,
        );
      }
    }
    if (logSummary) {
      _logLocaleFailureSummary(
        'Upload iPad Screenshots',
        failures,
        startIndex: summaryStart,
      );
    }
  }

  Future<void> uploadIap() async {
    final ws = r.workspace;
    if (ws.config.inApp == null || ws.config.inApp!.iapMetadata.isEmpty) {
      _log.info('No IAPs declared; skipping', scope: 'orchestrator');
      return;
    }
    final state = await r.resume
        .load(ws.config.metadata.packageId, ws.config.metadata.updateVersion);
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);

    for (final iapMeta in ws.config.inApp!.iapMetadata) {
      try {
        await control.checkpoint();
        await r.iap.syncOne(
            appId: app.id, iap: iapMeta, workspace: ws, control: control);
        state.iapByProduct[iapMeta.productId] = true;
        await r.resume.save(ws.config.metadata.packageId,
            ws.config.metadata.updateVersion, state);
      } on CancelledException {
        rethrow;
      } catch (e) {
        _log.error('IAP ${iapMeta.productId} failed: $e',
            scope: 'orchestrator');
      }
    }
  }

  Future<void> uploadAll() async {
    final failures = <_LocaleUploadFailure>[];
    await _uploadMetadata(failureSink: failures, logSummary: false);
    await _uploadScreenshots(failureSink: failures, logSummary: false);
    await uploadIap();
    _logLocaleFailureSummary('Upload All', failures);
  }

  Future<Map<String, dynamic>> checkMetadata({Set<String>? fields}) async {
    final ws = r.workspace;
    final allApplicableFields = _metadataCheckLabels.keys
        .where(
            (field) => field != 'release-notes' || _releaseNotesActionsAllowed)
        .toSet();
    final requested =
        fields == null || fields.isEmpty ? allApplicableFields : fields.toSet();
    final unknown = requested
        .where((field) => !_metadataCheckLabels.containsKey(field))
        .toList(growable: false);
    if (unknown.isNotEmpty) {
      throw StateError(
          'Unknown metadata check field(s): ${unknown.join(', ')}');
    }
    if (requested.contains('release-notes') && !_releaseNotesActionsAllowed) {
      _log.warn(_releaseNotesLiveOnlyMessage, scope: 'metadata-check');
      requested.remove('release-notes');
      if (requested.isEmpty) {
        return {
          'fields': const ['release-notes'],
          'locales': _effectiveLocales(),
          'skipped': true,
          'reason': _releaseNotesLiveOnlyMessage,
        };
      }
    }
    final orderedFields = _metadataCheckLabels.keys
        .where(requested.contains)
        .toList(growable: false);
    final locales = _effectiveLocales();
    final report = <String, dynamic>{
      'source': 'App Store Connect',
      'fields': orderedFields,
      'locales': locales,
    };
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to check',
          scope: 'metadata-check');
      return report;
    }

    final localIssues = <String>[];
    final localFallbacks = <String>[];
    final remoteMissing = <String>[];
    final mismatches = <String>[];
    final checkErrors = <String>[];
    final rows = <String, dynamic>{};

    final app = await r.apps.findByBundleId(ws.config.metadata.packageId);
    if (app == null) {
      final msg = 'App not found for bundle ${ws.config.metadata.packageId}';
      _log.error('Check Metadata failed: $msg', scope: 'metadata-check');
      report['error'] = msg;
      return report;
    }
    report['app'] = {
      'id': app.id,
      'bundleId': app.attributes['bundleId'],
      'name': app.attributes['name'],
    };
    _log.info(
        'ASC metadata check: app=${app.id}, bundle=${ws.config.metadata.packageId}, selectedLocales=${locales.length}, fields=${_metadataFieldList(orderedFields)}',
        scope: 'metadata-check');

    final needsVersion =
        orderedFields.any(_versionLocaleCheckFields.contains) ||
            orderedFields.contains('copyright');
    AscResource? version;
    final versionByLocale = <String, AscResource>{};
    if (needsVersion) {
      try {
        version = await _findVersionForChecks(app.id);
        if (version == null) {
          _addUnique(
            checkErrors,
            ws.config.metadata.updateVersion.trim().isEmpty
                ? 'No editable ASC version found; version metadata checks skipped'
                : 'ASC version "${ws.config.metadata.updateVersion}" not found; version metadata checks skipped',
          );
        } else {
          report['version'] = {
            'id': version.id,
            'versionString': version.attributes['versionString'],
            'state': version.attributes['appStoreState'],
          };
          versionByLocale.addAll(_byLocale(await r.locs.list(version.id)));
          _log.info(
              'ASC version metadata read: version=${version.id}, localizations=${versionByLocale.length}',
              scope: 'metadata-check');
        }
      } catch (e) {
        _addUnique(
            checkErrors, 'Version metadata read failed: ${_failureReason(e)}');
      }
    }

    final needsAppInfo =
        orderedFields.any(_appInfoLocaleCheckFields.contains) ||
            orderedFields.contains('category');
    AscResource? appInfo;
    final appInfoByLocale = <String, AscResource>{};
    String? remoteCategoryId;
    if (needsAppInfo) {
      try {
        appInfo = await r.appInfo.findEditable(app.id);
        report['appInfo'] = {
          'id': appInfo.id,
          'state': appInfo.attributes['appStoreState'],
        };
        appInfoByLocale
            .addAll(_byLocale(await r.appInfo.listLocalizations(appInfo.id)));
        _log.info(
            'ASC app-info metadata read: appInfo=${appInfo.id}, localizations=${appInfoByLocale.length}',
            scope: 'metadata-check');
        if (orderedFields.contains('category')) {
          remoteCategoryId =
              _relationshipId(appInfo.relationships['primaryCategory']);
          try {
            remoteCategoryId ??= await _readPrimaryCategoryId(appInfo.id);
          } catch (e) {
            _addUnique(checkErrors,
                'Category relationship read failed: ${_failureReason(e)}');
          }
        }
      } catch (e) {
        _addUnique(
            checkErrors, 'App-info metadata read failed: ${_failureReason(e)}');
      }
    }

    for (final locale in locales) {
      final row = <String, dynamic>{};
      final versionLoc = versionByLocale[locale];
      final appInfoLoc = appInfoByLocale[locale];

      for (final field in orderedFields) {
        if (!_versionLocaleCheckFields.contains(field)) continue;
        final label = _metadataLabel(field);
        final source = _sourceFileForVersionField(field);
        if (field == 'release-notes' &&
            ws.config.metadata.updateVersion.trim().isEmpty) {
          row[field] = {
            'local': 'not-applicable',
            'remote': 'not-applicable',
            'reason':
                'release notes are not sent for an initial editable version',
          };
          continue;
        }

        final expected = _localVersionValue(ws, field, locale);
        final hasOwn = _hasOwnVersionValue(ws, field, locale);
        final fieldRow = <String, dynamic>{
          'localLength': expected.length,
          'localSource': hasOwn ? 'own' : ws.config.defaultLanguage,
        };
        row[field] = fieldRow;

        if (!hasOwn && locale != ws.config.defaultLanguage) {
          _addUnique(localFallbacks,
              '$locale / $label: no own value in $source; using ${ws.config.defaultLanguage}');
        }
        if (expected.isEmpty) {
          _addUnique(
              localIssues, '$locale / $label: local value missing in $source');
        }
        if (field == 'keywords' && expected.length > 100) {
          _addUnique(localIssues,
              '$locale / Keywords: local value is ${expected.length} chars (Apple limit 100)');
        }
        if ((field == 'marketing-url' || field == 'support-url') &&
            expected.isNotEmpty &&
            !_isValidHttpUrl(expected)) {
          _addUnique(
              localIssues, '$locale / $label: local URL is not http/https');
        }

        if (version == null) {
          fieldRow['remote'] = 'no-version';
          continue;
        }
        if (versionLoc == null) {
          fieldRow['remote'] = 'missing-localization';
          _addUnique(remoteMissing,
              '$locale / $label: ASC version localization missing');
          continue;
        }
        final attr = _versionAttrForCheckField(field);
        final actual = (versionLoc.attributes[attr] ?? '').toString();
        fieldRow['remoteLength'] = actual.length;
        if (actual.isEmpty) {
          fieldRow['remote'] = 'missing';
          _addUnique(remoteMissing, '$locale / $label: ASC field is empty');
        } else if (expected.isNotEmpty && actual != expected) {
          fieldRow['remote'] = 'mismatch';
          _addUnique(mismatches,
              '$locale / $label: local ${_lengthLabel(expected)}, ASC ${_lengthLabel(actual)}');
        } else {
          fieldRow['remote'] = 'ok';
        }
      }

      for (final field in orderedFields) {
        if (!_appInfoLocaleCheckFields.contains(field)) continue;
        final label = _metadataLabel(field);
        final source = field == 'name'
            ? 'config.json metadata.name / specific_name_locales'
            : 'config.json metadata.privacy_url';
        final expected = _localAppInfoValue(ws, field, locale);
        final hasOwn = _hasOwnAppInfoValue(ws, field, locale);
        final fieldRow = <String, dynamic>{
          'localLength': expected.length,
          'localSource': hasOwn || field != 'name' ? 'config' : 'metadata.name',
        };
        row[field] = fieldRow;

        if (field == 'name' && !hasOwn && locale != ws.config.defaultLanguage) {
          _addUnique(localFallbacks,
              '$locale / Name: no specific_name_locales value; using metadata.name');
        }
        if (expected.isEmpty) {
          _addUnique(
              localIssues, '$locale / $label: local value missing in $source');
        }
        if (field == 'privacy-url' &&
            expected.isNotEmpty &&
            !_isValidHttpUrl(expected)) {
          _addUnique(localIssues,
              '$locale / Privacy URL: local URL is not http/https');
        }

        if (appInfo == null) {
          fieldRow['remote'] = 'no-app-info';
          continue;
        }
        if (appInfoLoc == null) {
          fieldRow['remote'] = 'missing-localization';
          _addUnique(remoteMissing,
              '$locale / $label: ASC app-info localization missing');
          continue;
        }
        final attr = _appInfoAttrForCheckField(field);
        final actual = (appInfoLoc.attributes[attr] ?? '').toString();
        fieldRow['remoteLength'] = actual.length;
        if (actual.isEmpty) {
          fieldRow['remote'] = 'missing';
          _addUnique(remoteMissing, '$locale / $label: ASC field is empty');
        } else if (expected.isNotEmpty && actual != expected) {
          fieldRow['remote'] = 'mismatch';
          _addUnique(mismatches,
              '$locale / $label: local ${_lengthLabel(expected)}, ASC ${_lengthLabel(actual)}');
        } else {
          fieldRow['remote'] = 'ok';
        }
      }

      rows[locale] = row;
    }

    if (orderedFields.contains('copyright')) {
      final expected = (ws.config.metadata.copyright ?? '').trim();
      final actual = (version?.attributes['copyright'] ?? '').toString();
      report['copyright'] = {
        'localLength': expected.length,
        'remoteLength': actual.length,
      };
      if (expected.isEmpty) {
        _addUnique(localIssues,
            'Copyright: local value missing in config.json metadata.copyright');
      }
      if (version == null) {
        _addUnique(remoteMissing, 'Copyright: no ASC version found');
      } else if (actual.isEmpty) {
        _addUnique(remoteMissing, 'Copyright: ASC field is empty');
      } else if (expected.isNotEmpty && actual != expected) {
        _addUnique(mismatches,
            'Copyright: local ${_lengthLabel(expected)}, ASC ${_lengthLabel(actual)}');
      }
    }

    if (orderedFields.contains('category')) {
      final expected = (ws.config.metadata.primaryCategory ?? '').trim();
      report['category'] = {
        'local': expected,
        'remote': remoteCategoryId,
      };
      if (expected.isEmpty) {
        _addUnique(localIssues,
            'Category: local value missing in config.json metadata.primary_category');
      }
      if (appInfo == null) {
        _addUnique(remoteMissing, 'Category: no editable ASC appInfo found');
      } else if ((remoteCategoryId ?? '').isEmpty) {
        _addUnique(remoteMissing, 'Category: ASC primary category is empty');
      } else if (expected.isNotEmpty && remoteCategoryId != expected) {
        _addUnique(
            mismatches, 'Category: local "$expected", ASC "$remoteCategoryId"');
      }
    }

    report['metadata'] = rows;
    report['summary'] = {
      'localIssues': localIssues,
      'localFallbacks': localFallbacks,
      'remoteMissing': remoteMissing,
      'mismatches': mismatches,
      'checkErrors': checkErrors,
    };

    final title = orderedFields.length == allApplicableFields.length
        ? 'Check Metadata Summary'
        : 'Check ${_metadataFieldList(orderedFields)} Summary';
    final summary = StringBuffer()
      ..writeln(title)
      ..writeln('Selected locales (${locales.length}): ${locales.join(', ')}')
      ..writeln('Fields: ${_metadataFieldList(orderedFields)}');
    void section(String name, List<String> lines) {
      if (lines.isEmpty) return;
      summary.writeln('$name (${lines.length}):');
      for (final line in lines) {
        summary.writeln('- $line');
      }
    }

    section('Local missing / invalid', localIssues);
    section('Local fallback values', localFallbacks);
    section('Missing on ASC', remoteMissing);
    section('ASC/local mismatch', mismatches);
    section('Check errors', checkErrors);

    final hasErrors = localIssues.isNotEmpty ||
        remoteMissing.isNotEmpty ||
        mismatches.isNotEmpty ||
        checkErrors.isNotEmpty;
    final text = summary.toString().trimRight();
    if (hasErrors) {
      _log.error(text, scope: 'metadata-check');
    } else if (localFallbacks.isNotEmpty) {
      _log.warn(text, scope: 'metadata-check');
    } else {
      _log.success('$text\nAll checked metadata is present and matches ASC.',
          scope: 'metadata-check');
    }
    return report;
  }

  Future<Map<String, dynamic>> checkScreenshots() async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to check', scope: 'check-ss');
      return const {
        'source': 'App Store Connect',
        'locales': <String, dynamic>{},
      };
    }
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await _findVersionForChecks(app.id);
    if (version == null) {
      final message = ws.config.metadata.updateVersion.trim().isEmpty
          ? 'No editable ASC version found; cannot check screenshots'
          : 'ASC version "${ws.config.metadata.updateVersion}" not found; cannot check screenshots';
      _log.error(message, scope: 'check-ss');
      return {
        'source': 'App Store Connect',
        'app': app.id,
        'versionId': null,
        'error': message,
        'locales': <String, dynamic>{},
      };
    }
    final localizations = await r.locs.list(version.id);
    _log.info(
        'ASC screenshot check: app=${app.id}, version=${version.id}, selectedLocales=${locales.length}',
        scope: 'check-ss');
    final report = <String, dynamic>{
      'source': 'App Store Connect',
      'app': app.id,
      'versionId': version.id,
      'versionString': version.attributes['versionString'],
      'selectedLocales': locales,
    };
    final rows = <String, dynamic>{};
    final noReadyScreenshots = <String>[];
    final readyCountMismatch = <String>[];
    final inProcessScreenshots = <String>[];
    final checkErrors = <String>[];
    for (final locale in locales) {
      try {
        await control.checkpoint();
        final loc = localizations.firstWhere(
          (l) => (l.attributes['locale'] ?? '') == locale,
          orElse: () => AscResource(
              id: '', type: '', attributes: const {}, relationships: const {}),
        );
        final readiness = _ScreenshotReadiness();
        final hasLoc = loc.id.isNotEmpty;
        if (hasLoc) {
          final sets = await r.screenshots.listSets(loc.id);
          for (final s in sets) {
            final display =
                (s.attributes['screenshotDisplayType'] ?? '').toString();
            final shots = await r.screenshots.listShots(s.id);
            readiness.addSet(display, shots);
          }
        }
        final primary = ws.screenshotDirFor(locale);
        final fallback = ws.screenshotDirFor(ws.config.defaultLanguage);
        final usedFallback =
            !(primary.existsSync() && _countLocal(primary) > 0) &&
                locale != ws.config.defaultLanguage;
        final localDir = (primary.existsSync() && _countLocal(primary) > 0)
            ? primary
            : fallback;
        final localCount = _countLocal(localDir);
        final fallbackNote =
            usedFallback ? ', fallback=${ws.config.defaultLanguage}' : '';

        rows[locale] = {
          'localization': hasLoc ? 'exists' : 'missing',
          'remote': readiness.totalByDisplay,
          'remoteReady': readiness.readyByDisplay,
          'remoteInProcess': readiness.inProcessByDisplay,
          'remoteStateCounts': readiness.stateCounts,
          'remoteTotal': readiness.total,
          'remoteReadyTotal': readiness.ready,
          'remoteInProcessTotal': readiness.inProcess,
          'local': localCount,
          'localFolder':
              usedFallback ? '${ws.config.defaultLanguage} (fallback)' : locale,
        };

        final summary = StringBuffer()
          ..write(
              '$locale -> local=$localCount, ASC ready=${readiness.ready}, ')
          ..write('inProcess=${readiness.inProcess}, total=${readiness.total}')
          ..write(' (ready: ')
          ..write(_formatCounts(readiness.readyByDisplay, includeZero: true))
          ..write('; inProcess: ')
          ..write(_formatCounts(readiness.inProcessByDisplay))
          ..write('; states: ')
          ..write(_formatCounts(readiness.stateCounts))
          ..write(')');
        if (!hasLoc) summary.write('  [no remote localization yet]');
        if (usedFallback) {
          summary.write('  [local falls back to ${ws.config.defaultLanguage}]');
        }
        _log.info(summary.toString(), scope: 'check-ss');

        if (localCount > 0 && readiness.ready == 0) {
          final locNote = hasLoc ? '' : ', no remote localization';
          noReadyScreenshots.add(_ssIssueLine(
              locale, localCount, readiness, '$locNote$fallbackNote'));
        } else if (readiness.ready != localCount) {
          readyCountMismatch
              .add(_ssIssueLine(locale, localCount, readiness, fallbackNote));
        } else if (readiness.inProcess > 0) {
          inProcessScreenshots
              .add(_ssIssueLine(locale, localCount, readiness, fallbackNote));
        }
      } on CancelledException {
        rethrow;
      } catch (e) {
        final reason = _failureReason(e);
        checkErrors.add('$locale: $reason');
        rows[locale] = {'error': reason};
        _log.error('$locale check screenshots failed: $reason',
            scope: 'check-ss');
      }
    }
    report['summary'] = {
      'noReadyScreenshots': noReadyScreenshots,
      'readyCountMismatch': readyCountMismatch,
      'inProcessScreenshots': inProcessScreenshots,
      'checkErrors': checkErrors,
    };
    report['locales'] = rows;
    final hasIssues = noReadyScreenshots.isNotEmpty ||
        readyCountMismatch.isNotEmpty ||
        inProcessScreenshots.isNotEmpty ||
        checkErrors.isNotEmpty;
    if (!hasIssues) {
      _log.success(
          'Check SS summary: all checked locale ready counts match local, '
          'and no in-process screenshots were found',
          scope: 'check-ss');
    } else {
      final summary = StringBuffer()
        ..writeln('IMPORTANT CHECK SS SUMMARY')
        ..writeln(
            'Only assetDeliveryState.state=COMPLETE is counted as ready for review.');
      if (noReadyScreenshots.isNotEmpty) {
        summary.writeln(
            'No ready ASC screenshots (${noReadyScreenshots.length}):');
        for (final line in noReadyScreenshots) {
          summary.writeln('- $line');
        }
      }
      if (readyCountMismatch.isNotEmpty) {
        summary.writeln('Ready count mismatch (${readyCountMismatch.length}):');
        for (final line in readyCountMismatch) {
          summary.writeln('- $line');
        }
      }
      if (inProcessScreenshots.isNotEmpty) {
        summary.writeln(
            'In-process / not-ready ASC screenshots (${inProcessScreenshots.length}):');
        for (final line in inProcessScreenshots) {
          summary.writeln('- $line');
        }
      }
      if (checkErrors.isNotEmpty) {
        summary.writeln('Check errors (${checkErrors.length}):');
        for (final line in checkErrors) {
          summary.writeln('- $line');
        }
      }
      _log.error(summary.toString().trimRight(), scope: 'check-ss');
    }
    return report;
  }

  /// iPad counterpart of [checkScreenshots]: local counts come from
  /// `screenshots/ipad/<locale>` and remote counts are filtered to iPad
  /// display-type sets only.
  Future<Map<String, dynamic>> checkIpadScreenshots() async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to check',
          scope: 'check-ipad-ss');
      return const {
        'source': 'App Store Connect',
        'locales': <String, dynamic>{},
      };
    }
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await _findVersionForChecks(app.id);
    if (version == null) {
      final message = ws.config.metadata.updateVersion.trim().isEmpty
          ? 'No editable ASC version found; cannot check iPad screenshots'
          : 'ASC version "${ws.config.metadata.updateVersion}" not found; cannot check iPad screenshots';
      _log.error(message, scope: 'check-ipad-ss');
      return {
        'source': 'App Store Connect',
        'app': app.id,
        'versionId': null,
        'error': message,
        'locales': <String, dynamic>{},
      };
    }
    final localizations = await r.locs.list(version.id);
    _log.info(
        'ASC iPad screenshot check: app=${app.id}, version=${version.id}, selectedLocales=${locales.length}',
        scope: 'check-ipad-ss');
    final report = <String, dynamic>{
      'source': 'App Store Connect',
      'platform': 'iPad',
      'app': app.id,
      'versionId': version.id,
      'versionString': version.attributes['versionString'],
      'selectedLocales': locales,
    };
    final rows = <String, dynamic>{};
    final noReadyScreenshots = <String>[];
    final readyCountMismatch = <String>[];
    final inProcessScreenshots = <String>[];
    final checkErrors = <String>[];
    for (final locale in locales) {
      try {
        await control.checkpoint();
        final loc = localizations.firstWhere(
          (l) => (l.attributes['locale'] ?? '') == locale,
          orElse: () => AscResource(
              id: '', type: '', attributes: const {}, relationships: const {}),
        );
        final readiness = _ScreenshotReadiness();
        final hasLoc = loc.id.isNotEmpty;
        if (hasLoc) {
          final sets = await r.screenshots.listSets(loc.id);
          for (final s in sets) {
            final display =
                (s.attributes['screenshotDisplayType'] ?? '').toString();
            if (!isIpadDisplayType(display)) continue;
            final shots = await r.screenshots.listShots(s.id);
            readiness.addSet(display, shots);
          }
        }
        final primary = ws.ipadScreenshotDirFor(locale);
        final fallback = ws.ipadScreenshotDirFor(ws.config.defaultLanguage);
        final usedFallback =
            !(primary.existsSync() && _countLocal(primary) > 0) &&
                locale != ws.config.defaultLanguage;
        final localDir = (primary.existsSync() && _countLocal(primary) > 0)
            ? primary
            : fallback;
        final localCount = _countLocal(localDir);
        final fallbackNote =
            usedFallback ? ', fallback=${ws.config.defaultLanguage}' : '';

        rows[locale] = {
          'localization': hasLoc ? 'exists' : 'missing',
          'remote': readiness.totalByDisplay,
          'remoteReady': readiness.readyByDisplay,
          'remoteInProcess': readiness.inProcessByDisplay,
          'remoteStateCounts': readiness.stateCounts,
          'remoteTotal': readiness.total,
          'remoteReadyTotal': readiness.ready,
          'remoteInProcessTotal': readiness.inProcess,
          'local': localCount,
          'localFolder': usedFallback
              ? 'ipad/${ws.config.defaultLanguage} (fallback)'
              : 'ipad/$locale',
        };

        final summary = StringBuffer()
          ..write(
              '$locale (iPad) -> local=$localCount, ASC ready=${readiness.ready}, ')
          ..write('inProcess=${readiness.inProcess}, total=${readiness.total}')
          ..write(' (ready: ')
          ..write(_formatCounts(readiness.readyByDisplay, includeZero: true))
          ..write('; inProcess: ')
          ..write(_formatCounts(readiness.inProcessByDisplay))
          ..write('; states: ')
          ..write(_formatCounts(readiness.stateCounts))
          ..write(')');
        if (!hasLoc) summary.write('  [no remote localization yet]');
        if (usedFallback) {
          summary.write(
              '  [local falls back to ipad/${ws.config.defaultLanguage}]');
        }
        _log.info(summary.toString(), scope: 'check-ipad-ss');

        if (localCount > 0 && readiness.ready == 0) {
          final locNote = hasLoc ? '' : ', no remote localization';
          noReadyScreenshots.add(_ssIssueLine(
              locale, localCount, readiness, '$locNote$fallbackNote'));
        } else if (readiness.ready != localCount) {
          readyCountMismatch
              .add(_ssIssueLine(locale, localCount, readiness, fallbackNote));
        } else if (readiness.inProcess > 0) {
          inProcessScreenshots
              .add(_ssIssueLine(locale, localCount, readiness, fallbackNote));
        }
      } on CancelledException {
        rethrow;
      } catch (e) {
        final reason = _failureReason(e);
        checkErrors.add('$locale: $reason');
        rows[locale] = {'error': reason};
        _log.error('$locale check iPad screenshots failed: $reason',
            scope: 'check-ipad-ss');
      }
    }
    report['summary'] = {
      'noReadyScreenshots': noReadyScreenshots,
      'readyCountMismatch': readyCountMismatch,
      'inProcessScreenshots': inProcessScreenshots,
      'checkErrors': checkErrors,
    };
    report['locales'] = rows;
    final hasIssues = noReadyScreenshots.isNotEmpty ||
        readyCountMismatch.isNotEmpty ||
        inProcessScreenshots.isNotEmpty ||
        checkErrors.isNotEmpty;
    if (!hasIssues) {
      _log.success(
          'Check iPad SS summary: all checked locale ready counts match local, '
          'and no in-process iPad screenshots were found',
          scope: 'check-ipad-ss');
    } else {
      final summary = StringBuffer()
        ..writeln('IMPORTANT CHECK IPAD SS SUMMARY')
        ..writeln(
            'Only assetDeliveryState.state=COMPLETE is counted as ready for review.')
        ..writeln('Local source: screenshots/ipad/<locale>; '
            'remote counts cover iPad display types only.');
      if (noReadyScreenshots.isNotEmpty) {
        summary.writeln(
            'No ready ASC iPad screenshots (${noReadyScreenshots.length}):');
        for (final line in noReadyScreenshots) {
          summary.writeln('- $line');
        }
      }
      if (readyCountMismatch.isNotEmpty) {
        summary.writeln('Ready count mismatch (${readyCountMismatch.length}):');
        for (final line in readyCountMismatch) {
          summary.writeln('- $line');
        }
      }
      if (inProcessScreenshots.isNotEmpty) {
        summary.writeln(
            'In-process / not-ready ASC iPad screenshots (${inProcessScreenshots.length}):');
        for (final line in inProcessScreenshots) {
          summary.writeln('- $line');
        }
      }
      if (checkErrors.isNotEmpty) {
        summary.writeln('Check errors (${checkErrors.length}):');
        for (final line in checkErrors) {
          summary.writeln('- $line');
        }
      }
      _log.error(summary.toString().trimRight(), scope: 'check-ipad-ss');
    }
    return report;
  }

  String _storeCountryForLocale(String locale) {
    const overrides = {
      'ar-SA': 'SA',
      'ca': 'ES',
      'cs': 'CZ',
      'da': 'DK',
      'de-DE': 'DE',
      'el': 'GR',
      'en-AU': 'AU',
      'en-CA': 'CA',
      'en-GB': 'GB',
      'en-US': 'US',
      'es-ES': 'ES',
      'es-MX': 'MX',
      'fi': 'FI',
      'fr-CA': 'CA',
      'fr-FR': 'FR',
      'he': 'IL',
      'hi': 'IN',
      'hr': 'HR',
      'hu': 'HU',
      'id': 'ID',
      'it': 'IT',
      'ja': 'JP',
      'ko': 'KR',
      'ms': 'MY',
      'nl-NL': 'NL',
      'no': 'NO',
      'pl': 'PL',
      'pt-BR': 'BR',
      'pt-PT': 'PT',
      'ro': 'RO',
      'ru': 'RU',
      'sk': 'SK',
      'sv': 'SE',
      'th': 'TH',
      'tr': 'TR',
      'uk': 'UA',
      'vi': 'VN',
      'zh-Hans': 'CN',
      'zh-Hant': 'TW',
    };
    return overrides[locale] ?? 'US';
  }

  String _normalizedAppName(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  Future<Map<String, dynamic>> checkAppNames() async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to check', scope: 'app-name');
      return const {'locales': <String, dynamic>{}};
    }

    final defaultName = (ws.config.metadata.name ?? '').trim();
    final specific = ws.config.specificNameLocales;
    if (defaultName.isEmpty && specific.isEmpty) {
      _log.error('config.json metadata.name is empty; cannot check app names',
          scope: 'app-name');
      return const {'locales': <String, dynamic>{}};
    }

    final rows = <String, dynamic>{};
    final available = <String>[];
    final conflicts = <String>[];
    final checkErrors = <String>[];
    final ownAppId = ws.config.metadata.appId.trim();
    final bundleId = ws.config.metadata.packageId.trim();

    for (final locale in locales) {
      try {
        await control.checkpoint();
        final configured = specific[locale]?.trim();
        final expected = configured != null && configured.isNotEmpty
            ? configured
            : defaultName;
        if (expected.isEmpty) {
          available.add('$locale: skipped, empty configured app name');
          rows[locale] = {'expected': expected, 'skipped': true};
          continue;
        }

        final country = _storeCountryForLocale(locale);
        final uri = Uri.https('itunes.apple.com', '/search', {
          'term': expected,
          'country': country,
          'entity': 'software',
          'limit': '200',
        });
        final response = await http.get(uri);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
              'Search API returned ${response.statusCode}: ${response.body}');
        }
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final results = (decoded['results'] as List?) ?? const [];
        final expectedNorm = _normalizedAppName(expected);
        final matching = <Map<String, dynamic>>[];
        for (final item in results) {
          if (item is! Map<String, dynamic>) continue;
          final trackName = (item['trackName'] ?? '').toString();
          if (_normalizedAppName(trackName) != expectedNorm) continue;
          final trackId = (item['trackId'] ?? '').toString();
          final remoteBundleId = (item['bundleId'] ?? '').toString();
          final isOwnApp = (ownAppId.isNotEmpty && trackId == ownAppId) ||
              (bundleId.isNotEmpty && remoteBundleId == bundleId);
          if (!isOwnApp) matching.add(item);
        }

        rows[locale] = {
          'expected': expected,
          'country': country,
          'conflicts': matching
              .map((item) => {
                    'trackId': item['trackId'],
                    'trackName': item['trackName'],
                    'sellerName': item['sellerName'],
                    'bundleId': item['bundleId'],
                    'trackViewUrl': item['trackViewUrl'],
                  })
              .toList(),
        };

        if (matching.isEmpty) {
          available.add('$locale/$country: "$expected" no exact public match');
        } else {
          final names = matching.map((item) {
            final seller = (item['sellerName'] ?? '').toString();
            final trackId = (item['trackId'] ?? '').toString();
            final remoteBundleId = (item['bundleId'] ?? '').toString();
            return '$seller, appId=$trackId, bundle=$remoteBundleId';
          }).join('; ');
          conflicts
              .add('$locale/$country: "$expected" exact public match → $names');
        }
      } on CancelledException {
        rethrow;
      } catch (e) {
        final reason = _failureReason(e);
        checkErrors.add('$locale: $reason');
        rows[locale] = {'error': reason};
      }
    }

    final report = {
      'locales': rows,
    };

    final hasIssues = conflicts.isNotEmpty || checkErrors.isNotEmpty;
    final summary = StringBuffer()
      ..writeln('App Name Availability Summary')
      ..writeln(
          'Source: public App Store Search API, exact public matches only')
      ..writeln('Note: this is not an App Store Connect reservation check.');
    if (conflicts.isNotEmpty) {
      summary.writeln('Possible conflicts (${conflicts.length}):');
      for (final line in conflicts) {
        summary.writeln('- $line');
      }
    }
    if (available.isNotEmpty) {
      summary.writeln('No exact public match (${available.length}):');
      for (final line in available) {
        summary.writeln('- $line');
      }
    }
    if (checkErrors.isNotEmpty) {
      summary.writeln('Check errors (${checkErrors.length}):');
      for (final line in checkErrors) {
        summary.writeln('- $line');
      }
    }

    final text = summary.toString().trimRight();
    if (hasIssues) {
      _log.error(text, scope: 'app-name');
    } else {
      _log.success(text, scope: 'app-name');
    }
    return report;
  }

  int _countLocal(Directory dir) {
    if (!dir.existsSync()) return 0;
    return dir.listSync().whereType<File>().where((f) {
      final n = p.basename(f.path).toLowerCase();
      if (n.startsWith('.')) return false;
      return n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg');
    }).length;
  }

  Future<Map<String, dynamic>> checkStatus() async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    final report = <String, dynamic>{
      'source': 'App Store Connect',
      'selectedLocales': locales,
    };
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to check', scope: 'status');
      return report;
    }

    final missingLocalizations = <String>[];
    final missingMetadata = <String>[];
    final missingScreenshots = <String>[];
    final inProcessScreenshots = <String>[];
    final missingAppInfo = <String>[];
    final globalMissing = <String>[];
    final checkErrors = <String>[];

    final app = await r.apps.findByBundleId(ws.config.metadata.packageId);
    if (app == null) {
      report['app'] = null;
      _log.error(
          'Check Status: app not found for bundle ${ws.config.metadata.packageId}',
          scope: 'status');
      return report;
    }
    report['app'] = {
      'id': app.id,
      'bundleId': app.attributes['bundleId'],
      'name': app.attributes['name'],
    };
    _log.info(
        'ASC status check: app=${app.id}, bundle=${ws.config.metadata.packageId}, selectedLocales=${locales.length}',
        scope: 'status');

    final versions = await r.versions.listVersions(app.id);
    report['versions'] = versions
        .map((v) => {
              'id': v.id,
              'versionString': v.attributes['versionString'],
              'state': v.attributes['appStoreState'],
            })
        .toList();

    final editable = await _findVersionForChecks(app.id);
    if (editable == null) {
      _addUnique(
          checkErrors,
          ws.config.metadata.updateVersion.trim().isEmpty
              ? 'No editable ASC version found'
              : 'ASC version "${ws.config.metadata.updateVersion}" not found');
    } else {
      report['checkedVersion'] = {
        'id': editable.id,
        'versionString': editable.attributes['versionString'],
        'state': editable.attributes['appStoreState'],
      };
      final copyright = (editable.attributes['copyright'] ?? '').toString();
      if (copyright.isEmpty) {
        globalMissing.add('Copyright: ASC version copyright is empty');
      }
      final locs = await r.locs.list(editable.id);
      final locByLocale = _byLocale(locs);
      final locSummary = <String, dynamic>{};
      for (final locale in locales) {
        final l = locByLocale[locale];
        if (l == null) {
          locSummary[locale] = {'localization': 'missing'};
          missingLocalizations.add(locale);
          continue;
        }
        final readiness = _ScreenshotReadiness();
        final sets = await r.screenshots.listSets(l.id);
        for (final s in sets) {
          final display =
              (s.attributes['screenshotDisplayType'] ?? '').toString();
          final shotsList = await r.screenshots.listShots(s.id);
          readiness.addSet(display, shotsList);
        }
        if (readiness.ready == 0) {
          missingScreenshots.add('$locale: no ready ASC screenshots '
              '(inProcess=${readiness.inProcess}, total=${readiness.total}'
              '${_stateBreakdown(readiness)})');
        } else if (readiness.inProcess > 0) {
          inProcessScreenshots.add('$locale: ready=${readiness.ready}, '
              'inProcess=${readiness.inProcess}, total=${readiness.total}'
              '${_stateBreakdown(readiness)}');
        }
        final attrChecks = <String, String>{
          'description': 'Description',
          'keywords': 'Keywords',
          'subtitle': 'Subtitle',
          if (ws.config.metadata.updateVersion.trim().isNotEmpty)
            'whatsNew': 'Release Notes',
          'marketingUrl': 'Marketing URL',
          'supportUrl': 'Support URL',
        };
        for (final entry in attrChecks.entries) {
          if ((l.attributes[entry.key] ?? '').toString().isEmpty) {
            missingMetadata.add('$locale / ${entry.value}: ASC field is empty');
          }
        }
        locSummary[locale] = {
          'localization': 'exists',
          'description':
              (l.attributes['description'] ?? '').toString().isNotEmpty,
          'keywords': (l.attributes['keywords'] ?? '').toString().isNotEmpty,
          'subtitle': (l.attributes['subtitle'] ?? '').toString().isNotEmpty,
          'whatsNew': (l.attributes['whatsNew'] ?? '').toString().isNotEmpty,
          'marketingUrl':
              (l.attributes['marketingUrl'] ?? '').toString().isNotEmpty,
          'supportUrl':
              (l.attributes['supportUrl'] ?? '').toString().isNotEmpty,
          'screenshots': readiness.totalByDisplay,
          'screenshotReady': readiness.readyByDisplay,
          'screenshotInProcess': readiness.inProcessByDisplay,
          'screenshotStateCounts': readiness.stateCounts,
          'screenshotTotals': readiness.toJson(),
        };
      }
      report['editableLocalizations'] = locSummary;
    }

    try {
      final appInfo = await r.appInfo.findEditable(app.id);
      final appInfoLocs =
          _byLocale(await r.appInfo.listLocalizations(appInfo.id));
      final appInfoSummary = <String, dynamic>{};
      for (final locale in locales) {
        final loc = appInfoLocs[locale];
        if (loc == null) {
          appInfoSummary[locale] = {'localization': 'missing'};
          missingAppInfo.add('$locale: ASC app-info localization missing');
          continue;
        }
        final hasName = (loc.attributes['name'] ?? '').toString().isNotEmpty;
        final hasPrivacy =
            (loc.attributes['privacyPolicyUrl'] ?? '').toString().isNotEmpty;
        if (!hasName) missingAppInfo.add('$locale / Name: ASC field is empty');
        if (!hasPrivacy) {
          missingAppInfo.add('$locale / Privacy URL: ASC field is empty');
        }
        appInfoSummary[locale] = {
          'localization': 'exists',
          'name': hasName,
          'privacyPolicyUrl': hasPrivacy,
        };
      }
      try {
        final categoryId =
            _relationshipId(appInfo.relationships['primaryCategory']) ??
                await _readPrimaryCategoryId(appInfo.id);
        report['primaryCategory'] = categoryId;
        if ((categoryId ?? '').isEmpty) {
          globalMissing.add('Category: ASC primary category is empty');
        }
      } catch (e) {
        checkErrors.add('Category read failed: ${_failureReason(e)}');
      }
      report['appInfoLocalizations'] = appInfoSummary;
    } catch (e) {
      checkErrors.add('App-info read failed: ${_failureReason(e)}');
    }

    final iaps = await r.iap.listForApp(app.id);
    report['iaps'] = iaps
        .map((i) => {
              'id': i.id,
              'productId': i.attributes['productId'],
              'state': i.attributes['state'],
            })
        .toList();
    report['summary'] = {
      'missingLocalizations': missingLocalizations,
      'missingMetadata': missingMetadata,
      'missingScreenshots': missingScreenshots,
      'inProcessScreenshots': inProcessScreenshots,
      'missingAppInfo': missingAppInfo,
      'globalMissing': globalMissing,
      'checkErrors': checkErrors,
    };

    final summary = StringBuffer()
      ..writeln('Check Status Summary')
      ..writeln('Selected locales (${locales.length}): ${locales.join(', ')}');
    void section(String name, List<String> lines) {
      if (lines.isEmpty) return;
      summary.writeln('$name (${lines.length}):');
      for (final line in lines) {
        summary.writeln('- $line');
      }
    }

    section('Missing ASC version localizations', missingLocalizations);
    section('Missing ASC version metadata', missingMetadata);
    section('Missing ASC screenshots', missingScreenshots);
    section(
        'ASC screenshots still processing / not ready', inProcessScreenshots);
    section('Missing ASC app-info metadata', missingAppInfo);
    section('Missing ASC global metadata', globalMissing);
    section('Check errors', checkErrors);

    final hasIssues = missingLocalizations.isNotEmpty ||
        missingMetadata.isNotEmpty ||
        missingScreenshots.isNotEmpty ||
        inProcessScreenshots.isNotEmpty ||
        missingAppInfo.isNotEmpty ||
        globalMissing.isNotEmpty ||
        checkErrors.isNotEmpty;
    final text = summary.toString().trimRight();
    if (hasIssues) {
      _log.error(text, scope: 'status');
    } else {
      _log.success('$text\nAll selected locales have required ASC metadata.',
          scope: 'status');
    }
    return report;
  }
}
