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
  Future<void> updateReleaseNotes() =>
      _runPerLocaleVersionField('whatsNew', 'release notes');
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

  Future<Map<String, dynamic>> checkScreenshots() async {
    final ws = r.workspace;
    final locales = _effectiveLocales().isEmpty
        ? ws.config.localizations
        : _effectiveLocales();
    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.findEditable(app.id) ??
        await r.versions.getOrCreate(
          appId: app.id,
          updateVersion: ws.config.metadata.updateVersion,
        );
    final localizations = await r.locs.list(version.id);
    final report = <String, dynamic>{
      'app': app.id,
      'versionId': version.id,
      'versionString': version.attributes['versionString'],
    };
    final rows = <String, dynamic>{};
    final notUploaded = <String>[];
    final countMismatch = <String>[];
    final checkErrors = <String>[];
    for (final locale in locales) {
      try {
        await control.checkpoint();
        final loc = localizations.firstWhere(
          (l) => (l.attributes['locale'] ?? '') == locale,
          orElse: () => AscResource(
              id: '', type: '', attributes: const {}, relationships: const {}),
        );
        final remote = <String, int>{};
        int remoteTotal = 0;
        final hasLoc = loc.id.isNotEmpty;
        if (hasLoc) {
          final sets = await r.screenshots.listSets(loc.id);
          for (final s in sets) {
            final display =
                (s.attributes['screenshotDisplayType'] ?? '').toString();
            final shots = await r.screenshots.listShots(s.id);
            remote[display] = shots.length;
            remoteTotal += shots.length;
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
          'remote': remote,
          'remoteTotal': remoteTotal,
          'local': localCount,
          'localFolder':
              usedFallback ? '${ws.config.defaultLanguage} (fallback)' : locale,
        };

        final summary = StringBuffer()
          ..write('$locale → remote=$remoteTotal (')
          ..write(remote.entries.map((e) => '${e.key}:${e.value}').join(', '))
          ..write('), local=$localCount');
        if (!hasLoc) summary.write('  [no remote localization yet]');
        if (usedFallback) {
          summary.write('  [local falls back to ${ws.config.defaultLanguage}]');
        }
        _log.info(summary.toString(), scope: 'check-ss');

        if (localCount > 0 && remoteTotal == 0) {
          final locNote = hasLoc ? '' : ', no remote localization';
          notUploaded
              .add('$locale: local=$localCount, remote=0$locNote$fallbackNote');
        } else if (remoteTotal != localCount) {
          countMismatch.add(
              '$locale: local=$localCount, remote=$remoteTotal$fallbackNote');
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
    report['locales'] = rows;
    final hasIssues = notUploaded.isNotEmpty ||
        countMismatch.isNotEmpty ||
        checkErrors.isNotEmpty;
    if (!hasIssues) {
      _log.success('Check SS summary: all checked locale counts match',
          scope: 'check-ss');
    } else {
      final summary = StringBuffer()..writeln('Check SS summary');
      if (notUploaded.isNotEmpty) {
        summary.writeln('Not uploaded (${notUploaded.length}):');
        for (final line in notUploaded) {
          summary.writeln('- $line');
        }
      }
      if (countMismatch.isNotEmpty) {
        summary.writeln('Count mismatch (${countMismatch.length}):');
        for (final line in countMismatch) {
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
    final report = <String, dynamic>{};
    final app = await r.apps.findByBundleId(ws.config.metadata.packageId);
    if (app == null) {
      report['app'] = null;
      return report;
    }
    report['app'] = {
      'id': app.id,
      'bundleId': app.attributes['bundleId'],
      'name': app.attributes['name'],
    };
    final versions = await r.versions.listVersions(app.id);
    report['versions'] = versions
        .map((v) => {
              'id': v.id,
              'versionString': v.attributes['versionString'],
              'state': v.attributes['appStoreState'],
            })
        .toList();
    final editable = await r.versions.findEditable(app.id);
    if (editable != null) {
      final locs = await r.locs.list(editable.id);
      final locSummary = <String, dynamic>{};
      for (final l in locs) {
        final locale = (l.attributes['locale'] ?? '').toString();
        final shots = <String, int>{};
        final sets = await r.screenshots.listSets(l.id);
        for (final s in sets) {
          final display =
              (s.attributes['screenshotDisplayType'] ?? '').toString();
          final shotsList = await r.screenshots.listShots(s.id);
          shots[display] = shotsList.length;
        }
        locSummary[locale] = {
          'description':
              (l.attributes['description'] ?? '').toString().isNotEmpty,
          'keywords': (l.attributes['keywords'] ?? '').toString().isNotEmpty,
          'subtitle': (l.attributes['subtitle'] ?? '').toString().isNotEmpty,
          'whatsNew': (l.attributes['whatsNew'] ?? '').toString().isNotEmpty,
          'screenshots': shots,
        };
      }
      report['editableLocalizations'] = locSummary;
    }
    final iaps = await r.iap.listForApp(app.id);
    report['iaps'] = iaps
        .map((i) => {
              'id': i.id,
              'productId': i.attributes['productId'],
              'state': i.attributes['state'],
            })
        .toList();
    return report;
  }
}
