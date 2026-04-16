import 'dart:io';

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
  bool replaceScreenshots = true;

  Orchestrator(this.r)
      : selectedLocales = Set<String>.from(r.workspace.config.localizations);

  List<String> _effectiveLocales() {
    final declared = r.workspace.config.localizations;
    return declared.where(selectedLocales.contains).toList();
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
        _log.error(
            'Auth FAILED — 401: check key_id / issuer_id / .p8 match',
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

  Future<void> uploadMetadata() async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to upload', scope: 'orchestrator');
      return;
    }
    final state = await r.resume
        .load(ws.config.metadata.packageId, ws.config.metadata.updateVersion);

    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.getOrCreate(
      appId: app.id,
      updateVersion: ws.config.metadata.updateVersion,
    );

    // Version-level copyright from config.json → version.attributes.copyright
    final copyright = ws.config.metadata.copyright ?? '';
    if (copyright.isNotEmpty) {
      try {
        await r.versions.patchMetadata(
          versionId: version.id,
          copyright: copyright,
        );
        _log.success('version ${version.id}: copyright set to "$copyright"',
            scope: 'orchestrator');
      } catch (e) {
        _log.error('version ${version.id}: copyright patch failed: $e',
            scope: 'orchestrator');
      }
    }

    state.versionDone = true;
    await r.resume.save(ws.config.metadata.packageId,
        ws.config.metadata.updateVersion, state);

    // Per-locale version localization (description / keywords / subtitle / whatsNew / URLs)
    for (final locale in locales) {
      try {
        await control.checkpoint();
        await r.locs.upsert(
          versionId: version.id,
          locale: locale,
          workspace: ws,
          control: control,
        );
        state.metadataByLocale[locale] = true;
        await r.resume.save(ws.config.metadata.packageId,
            ws.config.metadata.updateVersion, state);
      } on CancelledException {
        rethrow;
      } catch (e) {
        _log.error('$locale metadata failed: $e', scope: 'orchestrator');
      }
    }

    // App-level metadata (categories + per-locale name + privacyPolicyUrl).
    await _applyAppInfo(app.id, locales);
  }

  /// Push primary category onto the editable appInfo and upsert each
  /// selected locale's appInfoLocalization with app name + privacyPolicyUrl.
  Future<void> _applyAppInfo(String appId, List<String> locales) async {
    final ws = r.workspace;
    final meta = ws.config.metadata;
    final primaryCategory = (meta.primaryCategory ?? '').trim();
    final privacyUrl = (meta.privacyUrl ?? '').trim();
    final defaultName = (meta.name ?? '').trim();
    final specific = ws.config.specificNameLocales;

    // Skip entirely if there's nothing to push.
    final hasName = defaultName.isNotEmpty || specific.isNotEmpty;
    if (primaryCategory.isEmpty && privacyUrl.isEmpty && !hasName) {
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
        final nameForLocale =
            (specific[locale]?.trim().isNotEmpty ?? false)
                ? specific[locale]!.trim()
                : defaultName;
        await r.appInfo.upsertLocalization(
          appInfoId: appInfo.id,
          locale: locale,
          name: nameForLocale.isEmpty ? null : nameForLocale,
          privacyPolicyUrl: privacyUrl.isEmpty ? null : privacyUrl,
          control: control,
        );
      } on CancelledException {
        rethrow;
      } catch (e) {
        _log.error('$locale appInfo loc failed: $e', scope: 'orchestrator');
      }
    }
  }

  Future<void> uploadScreenshots() async {
    final ws = r.workspace;
    final locales = _effectiveLocales();
    if (locales.isEmpty) {
      _log.warn('No locales selected; nothing to upload', scope: 'orchestrator');
      return;
    }
    final state = await r.resume
        .load(ws.config.metadata.packageId, ws.config.metadata.updateVersion);

    final app = await r.apps.requireByBundleId(ws.config.metadata.packageId);
    final version = await r.versions.getOrCreate(
      appId: app.id,
      updateVersion: ws.config.metadata.updateVersion,
    );
    final existingLocalizations = await r.locs.list(version.id);

    for (final locale in locales) {
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
        _log.warn('$locale: no localization id; skipping screenshots',
            scope: 'orchestrator');
        continue;
      }
      try {
        final outcome = await r.screenshots.syncLocale(
          localizationId: localizationId,
          locale: locale,
          workspace: ws,
          replaceAll: replaceScreenshots,
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
        _log.error('$locale screenshots failed: $e', scope: 'orchestrator');
      }
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
            appId: app.id,
            iap: iapMeta,
            workspace: ws,
            control: control);
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
    await uploadMetadata();
    await uploadScreenshots();
    await uploadIap();
  }

  Future<Map<String, dynamic>> checkScreenshots() async {
    final ws = r.workspace;
    final locales =
        _effectiveLocales().isEmpty ? ws.config.localizations : _effectiveLocales();
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
    for (final locale in locales) {
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
      final usedFallback = !(primary.existsSync() &&
              _countLocal(primary) > 0) &&
          locale != ws.config.defaultLanguage;
      final localDir = (primary.existsSync() && _countLocal(primary) > 0)
          ? primary
          : fallback;
      final localCount = _countLocal(localDir);

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
    }
    report['locales'] = rows;
    return report;
  }

  int _countLocal(Directory dir) {
    if (!dir.existsSync()) return 0;
    return dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final n = p.basename(f.path).toLowerCase();
          if (n.startsWith('.')) return false;
          return n.endsWith('.png') ||
              n.endsWith('.jpg') ||
              n.endsWith('.jpeg');
        })
        .length;
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
