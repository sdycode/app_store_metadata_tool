'use strict';

// Self-diagnostic: annotate the build badge with the live DOM checkbox
// count. Tells us instantly whether a "single checkbox" complaint is
// (a) cached HTML (badge shows no suffix) (b) CSS hiding the 2nd element
// (badge shows "checkboxes: 2" but UI shows one) (c) server served 1
// checkbox (badge shows "checkboxes: 1").
(function selfDiagnose() {
  function paint() {
    var badge = document.getElementById('build-badge');
    if (!badge) return;
    var rm = document.getElementById('ss-replace-mismatch');
    var fr = document.getElementById('ss-force-replace');
    var counts = [rm ? 'mismatch✓' : 'mismatch✗', fr ? 'force✓' : 'force✗'];
    badge.textContent = badge.textContent + ' · ' + counts.join(' ');
    console.log('[self-diag] ss checkboxes in DOM:', {
      ssReplaceMismatch: !!rm,
      ssForceReplace: !!fr,
    });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', paint);
  } else {
    paint();
  }
})();

const LEVELS = ['debug', 'info', 'warn', 'error', 'success'];

const state = {
  workspace: null,
  selectedLocales: new Set(),
  // Two independent SS knobs, both checked by default (matches the Flutter
  // app's "belt + braces" upload). Both apply in both tabs.
  forcefulReplace: true,
  replaceOnMismatch: true,
  // Default-off knob for the individual field buttons only.
  forcefulIndividualUpdate: false,
  nextLogIndex: 0,
  logs: [],
  enabledLevels: new Set(LEVELS),
  query: '',
  controlState: { active: false, paused: false, cancelled: false, action: '' },
  tab: 'new-push',
};

// ---- DOM helpers ----------------------------------------------------------
const $ = (sel) => document.querySelector(sel);
const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'html') node.innerHTML = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (v === true) node.setAttribute(k, '');
    else if (v != null && v !== false) node.setAttribute(k, v);
  }
  for (const c of children) {
    if (c == null) continue;
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
};
const htmlEscape = (s) =>
    String(s).replace(/[&<>"']/g, (c) =>
        ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---- Theme ---------------------------------------------------------------
const THEME_STORAGE_KEY = 'metadata-uploader-theme';

function applyTheme(theme, persist) {
  const next = theme === 'dark' ? 'dark' : 'light';
  document.documentElement.dataset.theme = next;
  document.querySelectorAll('[data-theme-choice]').forEach((button) => {
    const active = button.dataset.themeChoice === next;
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  });
  if (persist) {
    try {
      localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch (_) {}
  }
}

function initialTheme() {
  try {
    return localStorage.getItem(THEME_STORAGE_KEY) === 'dark' ? 'dark' : 'light';
  } catch (_) {
    return document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light';
  }
}

// ---- Wire initial UI ------------------------------------------------------
applyTheme(initialTheme(), false);
document.querySelectorAll('[data-theme-choice]').forEach((button) => {
  button.addEventListener('click', () => applyTheme(button.dataset.themeChoice, true));
});

$('#btn-pick-folder').addEventListener('click', () => $('#folder-input').click());
$('#folder-input').addEventListener('change', onFolderPicked);
$('#btn-pick-key').addEventListener('click', () => $('#key-file-input').click());
$('#key-file-input').addEventListener('change', onKeyPicked);
$('#btn-load').addEventListener('click', uploadWorkspace);

document.querySelectorAll('.tab').forEach((t) => {
  t.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach((x) => x.classList.remove('active'));
    t.classList.add('active');
    state.tab = t.dataset.tab;
    renderTabScopedActions();
    renderMismatch();
    postOptions();
  });
});
renderTabScopedActions();

$('#ss-force-replace').addEventListener('change', (e) => {
  state.forcefulReplace = e.target.checked;
  postOptions();
});
$('#ss-replace-mismatch').addEventListener('change', (e) => {
  state.replaceOnMismatch = e.target.checked;
  postOptions();
});
$('#field-forceful-update').addEventListener('change', (e) => {
  state.forcefulIndividualUpdate = e.target.checked;
  postOptions();
});

document.querySelectorAll('input[name="locale-set"]').forEach((r) => {
  r.addEventListener('change', async () => {
    const picked = document.querySelector('input[name="locale-set"]:checked').value;
    // Server-side switch resets selectedLocales; client re-syncs via /status.
    await fetch('/options', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ localeSet: picked }),
    });
  });
});

document.querySelectorAll('[data-action]').forEach((b) => {
  b.addEventListener('click', () => {
    // Highlight the clicked button while its action is in flight; the
    // poll loop clears it once control.isActive goes false.
    document
        .querySelectorAll('[data-action].running')
        .forEach((x) => x.classList.remove('running'));
    b.classList.add('running');
    runAction(b.dataset.action);
  });
});

document.querySelectorAll('[data-locale-op]').forEach((b) => {
  b.addEventListener('click', () => {
    if (!state.workspace) return;
    // Use the ACTIVE locale set (the 15-or-39 preset the user picked),
    // not config.json's list — the chips are rendered from activeLocaleSet,
    // so "All" must select every rendered chip.
    const all = state.activeLocaleSet || [];
    const op = b.dataset.localeOp;
    if (op === 'all') state.selectedLocales = new Set(all);
    else if (op === 'none') state.selectedLocales = new Set();
    else if (op === 'invert') {
      state.selectedLocales = new Set(all.filter((l) => !state.selectedLocales.has(l)));
    } else if (op === 'toggle-regional') {
      // Quick include/exclude of ar-SA, hi, zh-Hans, zh-Hant as a group —
      // these 4 often need to be toggled together (different script, RTL,
      // or distinct regional requirements).
      const REGIONAL = ['ar-SA', 'hi', 'zh-Hans', 'zh-Hant'];
      const relevant = REGIONAL.filter((l) => all.includes(l));
      const allCurrentlySelected =
          relevant.length > 0 &&
          relevant.every((l) => state.selectedLocales.has(l));
      if (allCurrentlySelected) {
        relevant.forEach((l) => state.selectedLocales.delete(l));
      } else {
        relevant.forEach((l) => state.selectedLocales.add(l));
      }
    }
    renderLocales();
    renderKeywordBlock();
    updateActionGate();
    postLocales();
  });
});

$('#btn-pause').addEventListener('click', () => fetch('/action/pause', { method: 'POST' }));
$('#btn-resume').addEventListener('click', () => fetch('/action/resume', { method: 'POST' }));
$('#btn-cancel').addEventListener('click', () => fetch('/action/cancel', { method: 'POST' }));
$('#btn-clear-logs').addEventListener('click', async () => {
  await fetch('/action/clear-logs', { method: 'POST' });
  state.logs = [];
  state.nextLogIndex = 0;
  renderLogs();
});
$('#log-search').addEventListener('input', (e) => {
  state.query = e.target.value;
  renderLogs();
});

// Level filter chips
const chipsHost = $('#level-chips');
for (const lvl of LEVELS) {
  const chip = el(
    'span',
    { class: `level-chip ${lvl} selected`, title: `${lvl} — click to toggle` },
    lvl.toUpperCase()
  );
  chip.addEventListener('click', () => {
    if (state.enabledLevels.has(lvl)) state.enabledLevels.delete(lvl);
    else state.enabledLevels.add(lvl);
    chip.classList.toggle('selected');
    renderLogs();
  });
  chipsHost.appendChild(chip);
}

// ---- Workspace upload -----------------------------------------------------
async function isServerReachable() {
  try {
    const r = await fetch('/health', { method: 'GET' });
    return r.ok;
  } catch (_) {
    return false;
  }
}


function onFolderPicked(e) {
  const files = e.target.files;
  if (!files || files.length === 0) {
    $('#workspace-path').textContent = 'No folder picked';
    return;
  }
  const root = files[0].webkitRelativePath?.split('/')?.[0] || '(folder)';
  $('#workspace-path').textContent = `${root} — ${files.length} files ready`;
  $('#load-hint').textContent = 'Ready — click Load to upload';
}

function onKeyPicked(e) {
  const f = e.target.files?.[0];
  $('#key-summary').textContent = f ? f.name : 'from folder';
}

async function uploadWorkspace() {
  const folderInput = $('#folder-input');
  const files = folderInput.files;
  if (!files || files.length === 0) {
    alert('Pick a folder first.');
    return;
  }
  const form = new FormData();
  for (const f of files) {
    form.append('files', f, f.webkitRelativePath || f.name);
  }
  const issuerId = $('#issuer-id').value.trim();
  const keyId = $('#key-id').value.trim();
  const keyFile = $('#key-file-input').files?.[0];
  if (issuerId) form.append('issuerId', issuerId);
  if (keyId) form.append('keyId', keyId);
  if (keyFile) form.append('keyFile', keyFile, keyFile.name);

  $('#btn-load').disabled = true;
  $('#load-hint').textContent = `Uploading ${files.length} files…`;
  let loadedRoot = null;
  try {
    let resp;
    try {
      resp = await fetch('/upload', { method: 'POST', body: form });
    } catch (netErr) {
      // "Failed to fetch" is a network-layer error — either the server died
      // or the FormData was built from stale File refs. Verify server is
      // alive, and if it is, explain it's likely the File refs.
      const reachable = await isServerReachable();
      if (!reachable) {
        throw new Error(
            'Server at this URL is not responding. Is `dart run bin/server.dart` still running in the terminal?');
      }
      throw new Error(
          'Browser could not send the request (likely stale file handles from a previous upload). Pick the folder again and retry.');
    }
    if (!resp.ok) throw new Error(await resp.text());
    const data = await resp.json();
    applyStatus(data.status);
    loadedRoot = data?.status?.workspace?.root ?? null;
    $('#load-hint').textContent =
        'Workspace loaded. To re-load, pick the folder again.';
  } catch (err) {
    alert('Upload failed: ' + (err?.message || err));
    $('#load-hint').textContent = 'Load failed — see logs';
  } finally {
    // Browsers release File handles after the first fetch consumes them;
    // a second submit with the same FileList triggers "Failed to fetch".
    // Reset both file inputs so the user re-picks next time and every
    // File reference is fresh.
    folderInput.value = '';
    $('#key-file-input').value = '';
    if (loadedRoot) {
      $('#workspace-path').textContent = loadedRoot;
    }
    $('#key-summary').textContent = 'auto-detected from folder';
    $('#btn-load').disabled = false;
  }
}

// ---- Actions --------------------------------------------------------------
async function runAction(path) {
  try {
    await postLocales();
    await postOptions();
    const resp = await fetch(path, { method: 'POST' });
    if (resp.status === 400) alert('Pick a folder first.');
    if (resp.status === 409) alert('Another action is already running.');
  } catch (e) {
    alert('Failed: ' + e);
  }
}

async function postLocales() {
  if (!state.workspace) return;
  await fetch('/locales', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ locales: Array.from(state.selectedLocales) }),
  });
}

async function postOptions() {
  if (!state.workspace) return;
  await fetch('/options', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      forcefulReplace: state.forcefulReplace,
      replaceOnMismatch: state.replaceOnMismatch,
      forcefulIndividualUpdate: state.forcefulIndividualUpdate,
      liveUpdateMode: state.tab === 'live-update',
    }),
  });
}

// ---- Status + logs polling ------------------------------------------------
async function pollOnce() {
  try {
    const [statusR, logsR] = await Promise.all([
      fetch('/status'),
      fetch(`/logs?since=${state.nextLogIndex}`),
    ]);
    if (statusR.ok) {
      const s = await statusR.json();
      applyStatus(s);
    }
    if (logsR.ok) {
      const j = await logsR.json();
      if (j.entries.length > 0) {
        state.logs.push(...j.entries);
        state.nextLogIndex = j.entries[j.entries.length - 1].index + 1;
        renderLogs();
      }
    }
  } catch (e) {
    // ignore transient errors
  } finally {
    setTimeout(pollOnce, 1000);
  }
}
pollOnce();

// ---- Rendering ------------------------------------------------------------
function applyStatus(s) {
  if (s.workspace) {
    if (!state.workspace) {
      state.selectedLocales = new Set(s.selectedLocales || s.workspace.localizations);
    } else {
      state.selectedLocales = new Set(s.selectedLocales);
    }
    state.workspace = s.workspace;
    $('#workspace-path').textContent = s.workspace.root;
    $('#info-grid').classList.remove('hidden');
    $('#info-grid').innerHTML = '';
    const add = (k, v) => {
      $('#info-grid').appendChild(el('div', { class: 'k' }, k));
      $('#info-grid').appendChild(el('div', { class: 'v' }, v || '—'));
    };
    add('Bundle', s.workspace.bundleId);
    add('App ID', s.workspace.appId);
    add('Version', s.workspace.updateVersion || '(editable)');
    add('Locales', s.workspace.localizations.join(', '));
    add('IAPs', String(s.workspace.iapCount));
    add('Key file', s.workspace.keyFile);
    // Sync checkboxes with server-reported options.
    if (typeof s.forcefulReplace === 'boolean') {
      state.forcefulReplace = s.forcefulReplace;
    }
    if (typeof s.replaceOnMismatch === 'boolean') {
      state.replaceOnMismatch = s.replaceOnMismatch;
    }
    if (typeof s.forcefulIndividualUpdate === 'boolean') {
      state.forcefulIndividualUpdate = s.forcefulIndividualUpdate;
    }
    $('#ss-force-replace').checked = state.forcefulReplace;
    $('#ss-replace-mismatch').checked = state.replaceOnMismatch;
    $('#field-forceful-update').checked = state.forcefulIndividualUpdate;
    // Locale set + keyword data live on the top-level status payload.
    state.activeLocaleSet = s.activeLocaleSet || [];
    state.activeLocaleSetName = s.activeLocaleSetName || '15';
    state.configLocaleCount = s.configLocaleCount || 0;
    state.keywordLengths = s.keywordLengths || {};
    state.effectiveKeywordLengths = s.effectiveKeywordLengths || {};
    state.fallbackUsage = s.fallbackUsage || {};
    state.defaultLanguage = s.defaultLanguage || 'en-US';
    renderLocaleSetCard();
    renderLocales();
    renderWarnings(s.workspace.warnings || []);
    renderJsonSyntaxBlock(s.workspace.jsonSyntaxErrors || []);
    renderKeywordBlock();
    renderFallbackUsage();
    renderMismatch();
    renderTabScopedActions();
    renderExtracted(s.extracted);
    updateActionGate();
  }
  state.controlState = s.control || state.controlState;
  renderRunBar();
}

/// Enforces a contract between the selected tab and config.update_version:
///   - update_version == "" → New Push tab
///   - update_version != "" → Live Update tab
/// On mismatch: show a big red banner and disable all action buttons.
function renderMismatch() {
  const card = $('#mismatch-card');
  const detail = $('#mismatch-detail');
  const ws = state.workspace;
  // Clear any tab "wrong" markings first.
  document.querySelectorAll('.tab.wrong').forEach((x) => x.classList.remove('wrong'));

  if (!ws) {
    card.classList.add('hidden');
    setActionsEnabled(true);
    return;
  }
  const uv = (ws.updateVersion || '').trim();
  const tab = state.tab;
  const isEmpty = uv.length === 0;
  const expected = isEmpty ? 'new-push' : 'live-update';
  const mismatch = tab !== expected;

  if (!mismatch) {
    card.classList.add('hidden');
    setActionsEnabled(true);
    return;
  }

  card.classList.remove('hidden');
  // Also mark the currently-selected (wrong) tab in red so it stands out.
  document
      .querySelectorAll(`.tab[data-tab="${tab}"]`)
      .forEach((el) => el.classList.add('wrong'));

  const expectedLabel = expected === 'new-push' ? 'New Push' : 'Live Update';
  const currentLabel = tab === 'new-push' ? 'New Push' : 'Live Update';
  if (isEmpty) {
    detail.innerHTML =
        `<code>update_version</code> is <b>empty</b> → config expects <b>${expectedLabel}</b>.<br>` +
        `You are currently on <b>${currentLabel}</b>. Switch tabs or set <code>update_version</code> in config.json.`;
  } else {
    detail.innerHTML =
        `<code>update_version</code> = <b>"${uv}"</b> → config expects <b>${expectedLabel}</b>.<br>` +
        `You are currently on <b>${currentLabel}</b>. Switch tabs or clear <code>update_version</code> in config.json.`;
  }
  setActionsEnabled(false);
}

function setActionsEnabled(enabled) {
  document.querySelectorAll('[data-action]').forEach((b) => {
    b.disabled = !enabled && b.dataset.action !== '/action/validate';
  });
}

function renderTabScopedActions() {
  const isLiveUpdate = state.tab === 'live-update';
  document.querySelectorAll('[data-live-only]').forEach((el) => {
    el.classList.toggle('hidden', !isLiveUpdate);
  });
}

/// Compound gate: actions are enabled only if NO blocking condition is
/// active. Blocking conditions: tab↔version mismatch, keyword length >100,
/// or invalid metadata JSON. Validate stays clickable so it can report the
/// hard failures on demand.
function updateActionGate() {
  const tabMismatch = !$('#mismatch-card').classList.contains('hidden');
  const keywordBlocked =
      !$('#keyword-block').classList.contains('hidden');
  const jsonCard = $('#json-syntax-block');
  const jsonBlocked = jsonCard && !jsonCard.classList.contains('hidden');
  setActionsEnabled(!tabMismatch && !keywordBlocked && !jsonBlocked);
}

function renderLocaleSetCard() {
  const card = $('#locale-set-card');
  if (!state.workspace) {
    card.classList.add('hidden');
    return;
  }
  card.classList.remove('hidden');
  const name = state.activeLocaleSetName || '15';
  $('#locale-set-15').checked = name === '15';
  $('#locale-set-39').checked = name === '39';

  // Conflict message: compares the count the user picked to what config.json
  // actually declares. Selection wins; this is purely advisory so the user
  // can edit config or switch set if they want alignment.
  const active = (state.activeLocaleSet || []).length;
  const cfg = state.configLocaleCount || 0;
  const hint = $('#locale-set-conflict');
  if (active !== cfg && cfg > 0) {
    hint.classList.remove('hidden');
    hint.innerHTML =
        `⚠ <b>config.json</b> declares <b>${cfg}</b> locale(s), but you selected the <b>${name}-locale</b> set (<b>${active}</b>). ` +
        `Selection wins — uploads run for <b>${active}</b> locale(s); missing per-locale data falls back to <b>en-US</b>.`;
  } else {
    hint.classList.add('hidden');
  }
}

function renderKeywordBlock() {
  const card = $('#keyword-block');
  const detail = $('#keyword-block-detail');
  if (!state.workspace) {
    card.classList.add('hidden');
    return;
  }
  // Use EFFECTIVE lengths (own value OR default-language fallback) — a
  // too-long en-US keyword set propagates to every locale that inherits
  // via fallback, so the violation list must reflect that too.
  const active = new Set(
      (state.activeLocaleSet || []).filter((l) => state.selectedLocales.has(l)));
  const effective = state.effectiveKeywordLengths || {};
  const own = state.keywordLengths || {};
  const violations = [];
  for (const locale of active) {
    const len = effective[locale] ?? 0;
    if (len > 100) {
      const hasOwn = Object.prototype.hasOwnProperty.call(own, locale);
      violations.push({ locale, len, hasOwn });
    }
  }
  if (violations.length === 0) {
    card.classList.add('hidden');
    return;
  }
  card.classList.remove('hidden');
  const rows = violations
      .map((v) => `<li><b>${v.locale}</b>: ${v.len} chars${v.hasOwn ? '' : ` (inherited from <b>${state.defaultLanguage}</b>)`}</li>`)
      .join('');
  detail.innerHTML =
      'Apple rejects keywords longer than 100 characters. ' +
      'Trim the following locale(s) in <code>keywords.json</code> ' +
      '(locales marked "inherited" fall back to <code>' + state.defaultLanguage + '</code> — ' +
      'fixing that one entry resolves them all):<ul>' + rows + '</ul>';
}

/// Renders the "Extracted details" card at the top of the log panel —
/// a compact preview of what will actually hit Apple's API when the
/// upload buttons are clicked. Uses en-US values for the textual
/// previews.
function renderExtracted(ex) {
  const card = document.getElementById('extracted-card');
  const body = document.getElementById('extracted-body');
  if (!card || !body) return;
  if (!ex) {
    card.classList.add('hidden');
    return;
  }
  card.classList.remove('hidden');
  const clip = (s, n) => {
    if (!s) return '—';
    if (s.length <= n) return s;
    return s.slice(0, n) + '…';
  };
  const urlOrDash = (u) => {
    if (!u) return '—';
    const safe = htmlEscape(u);
    if (/^https?:\/\//i.test(u)) {
      return `<a href="${safe}" target="_blank" rel="noopener">${safe}</a>`;
    }
    return `<span class="bad">${safe}</span>`;
  };
  const kv = (k, v) =>
      `<div class="ex-row"><div class="ex-k">${k}</div><div class="ex-v">${v}</div></div>`;
  const section = (title, rows) =>
      `<div class="ex-section"><div class="ex-title">${title}</div>${rows.join('')}</div>`;

  const enUS = ex.en_us || {};
  const urls = ex.urls || {};
  const jsonErrors = ex.json_syntax_errors || [];
  const locationText = (err) =>
      err.line && err.column ? `line ${err.line}, column ${err.column}` : 'unknown location';
  const jsonErrorBlock = jsonErrors.length === 0 ? '' : section(
      'JSON syntax errors',
      jsonErrors.map((err) =>
          kv(`<code>${htmlEscape(err.file || 'unknown')}</code>`,
              `<span class="bad">${htmlEscape(locationText(err))}: ${htmlEscape(err.message || 'Invalid JSON')}</span>`)));

  const appInfo = section('App info', [
    kv('Name', htmlEscape(ex.name || '—')),
    kv('Bundle / App ID', `${htmlEscape(ex.package_id || '')} <span class="dim">/ ${htmlEscape(ex.app_id || '')}</span>`),
    kv('Category', htmlEscape(ex.primary_category || '—')),
    kv('Copyright', htmlEscape(ex.copyright || '—')),
    kv('Update version', ex.update_version ? htmlEscape(ex.update_version) : '<span class="dim">(editable)</span>'),
    kv('Contact', htmlEscape(ex.email || '—')),
  ]);

  const urlBlock = section('URLs', [
    kv('Marketing', urlOrDash(urls.marketing)),
    kv('Support', urlOrDash(urls.support)),
    kv('Privacy', urlOrDash(urls.privacy)),
  ]);

  const contentBlock = section('en-US content preview', [
    kv('Subtitle', htmlEscape(enUS.subtitle || '—')),
    kv('Keywords', `<code>${htmlEscape(enUS.keywords || '—')}</code>`),
    kv('Description', `<div class="ex-multiline">${htmlEscape(clip(enUS.description, 400))}</div>`),
    kv('Release notes', `<div class="ex-multiline">${htmlEscape(clip(enUS.release_notes, 400))}</div>`),
  ]);

  const iapRows = (ex.iaps || []).map((iap) => {
    const localesText = (iap.localizations || [])
        .map((l) => `${l.locale}: ${l.name}`)
        .join(' · ');
    return `<li>
      <b>${htmlEscape(iap.product_id || '')}</b>
      <span class="dim">${htmlEscape(iap.reference_name || '')}</span>
      <span class="ex-pill">${htmlEscape(iap.purchase_type || '')}</span>
      ${iap.family_sharable ? '<span class="ex-pill">family</span>' : ''}
      <span class="ex-pill">$${htmlEscape(iap.price_point || '?')} ${htmlEscape(iap.territory || '')}</span>
      ${localesText ? `<div class="dim">${htmlEscape(localesText)}</div>` : ''}
    </li>`;
  }).join('');
  const iapBlock = section(
      `In-app purchases (${ex.iap_count || 0})`,
      [
        (ex.iap_count ?? 0) === 0
            ? '<div class="ex-row"><div class="ex-v dim">none declared</div></div>'
            : `<ul class="ex-iap-list">${iapRows}</ul>`,
        ex.review_image_path
            ? kv('Review image', `<code>${htmlEscape(ex.review_image_path)}</code>`)
            : '',
      ]);

  body.innerHTML = jsonErrorBlock + appInfo + urlBlock + contentBlock + iapBlock;
  const subtitle = document.getElementById('extracted-subtitle');
  if (subtitle) {
    subtitle.textContent =
        `— ${ex.update_version ? 'v' + ex.update_version : 'editable version'}`;
  }
}

/// Non-blocking info card listing locales that lack own translations for
/// each text field. They will upload using the default-language fallback.
function renderFallbackUsage() {
  const card = $('#fallback-card');
  const host = $('#fallback-list');
  if (!card || !host) return;
  host.innerHTML = '';
  const fu = state.fallbackUsage || {};
  const active = new Set(
      (state.activeLocaleSet || []).filter((l) => state.selectedLocales.has(l)));
  const sections = [
    ['description', 'description.json'],
    ['keywords', 'keywords.json'],
    ['subtitle', 'subtitle.json'],
    ['releasenotes', 'releasenotes.json'],
  ];
  let shown = 0;
  for (const [key, label] of sections) {
    const list = (fu[key] || []).filter((l) => active.has(l));
    if (list.length === 0) continue;
    const li = el('li', {}, el('b', {}, label + ': '),
        list.join(', ') + ' — fallback to ' + state.defaultLanguage);
    host.appendChild(li);
    shown++;
  }
  card.classList.toggle('hidden', shown === 0);
}

function renderWarnings(list) {
  const card = $('#warnings-card');
  const host = $('#warnings-list');
  host.innerHTML = '';
  if (!list || list.length === 0) {
    card.classList.add('hidden');
    return;
  }
  card.classList.remove('hidden');
  for (const msg of list) {
    host.appendChild(el('li', {}, msg));
  }
}

function renderJsonSyntaxBlock(list) {
  const card = $('#json-syntax-block');
  const detail = $('#json-syntax-detail');
  if (!card || !detail) return;
  const errors = list || [];
  if (errors.length === 0) {
    card.classList.add('hidden');
    detail.innerHTML = '';
    return;
  }
  card.classList.remove('hidden');
  const rows = errors
      .map((err) => {
        const loc = err.line && err.column
            ? ` at line ${err.line}, column ${err.column}`
            : '';
        return `<li><code>${htmlEscape(err.file || 'unknown')}</code>${htmlEscape(loc)}: ${htmlEscape(err.message || 'Invalid JSON')}</li>`;
      })
      .join('');
  detail.innerHTML =
      'Fix the JSON syntax and load the workspace again before uploading metadata.' +
      '<ul>' + rows + '</ul>';
}

function renderLocales() {
  const host = $('#locale-chips');
  host.innerHTML = '';
  const ws = state.workspace;
  if (!ws) return;
  const all = state.activeLocaleSet || [];
  const cfgSet = new Set(ws.localizations || []);
  for (const loc of all) {
    const selected = state.selectedLocales.has(loc);
    const inConfig = cfgSet.has(loc);
    const chip = el(
      'span',
      {
        class:
            'chip' + (selected ? ' selected' : '') + (inConfig ? '' : ' extra'),
        title: inConfig
            ? loc
            : loc + ' — not in config.json; will use en-US fallback',
      },
      loc
    );
    chip.addEventListener('click', () => {
      if (state.selectedLocales.has(loc)) state.selectedLocales.delete(loc);
      else state.selectedLocales.add(loc);
      renderLocales();
      renderKeywordBlock();
      updateActionGate();
      postLocales();
    });
    host.appendChild(chip);
  }
  $('#locale-count').textContent = `(${state.selectedLocales.size}/${all.length})`;
  $('#locale-empty-hint').classList.toggle('hidden', state.selectedLocales.size > 0);

  // Regional-toggle button below the chips — shows current inclusion state
  // for ar-SA, hi, zh-Hans, zh-Hant. Button itself hides when none of
  // those locales exist in the active preset.
  const REGIONAL = ['ar-SA', 'hi', 'zh-Hans', 'zh-Hant'];
  const relevant = REGIONAL.filter((l) => all.includes(l));
  const btn = $('#btn-toggle-regional');
  const icon = $('#regional-icon');
  const title = $('#regional-title');
  const codes = $('#regional-codes');
  if (btn && icon && title && codes) {
    if (relevant.length === 0) {
      btn.classList.add('hidden');
    } else {
      btn.classList.remove('hidden');
      const selectedCount =
          relevant.filter((l) => state.selectedLocales.has(l)).length;
      const allIn = selectedCount === relevant.length;
      const noneIn = selectedCount === 0;
      codes.textContent = relevant.join(', ');
      btn.classList.remove('state-all', 'state-none', 'state-partial');
      if (allIn) {
        btn.classList.add('state-all');
        icon.textContent = '✓';
        title.textContent = 'Included — click to exclude';
      } else if (noneIn) {
        btn.classList.add('state-none');
        icon.textContent = '✕';
        title.textContent = 'Excluded — click to include';
      } else {
        btn.classList.add('state-partial');
        icon.textContent = '◐';
        title.textContent =
            `Partial (${selectedCount}/${relevant.length}) — click to include all`;
      }
    }
  }
}

function renderRunBar() {
  const bar = $('#run-bar');
  const c = state.controlState;
  if (!c.active) {
    bar.classList.add('hidden');
    // Clear the action-button highlight when nothing is running.
    document
        .querySelectorAll('[data-action].running')
        .forEach((x) => x.classList.remove('running'));
    return;
  }
  bar.classList.remove('hidden');
  $('#run-indicator').classList.toggle('paused', !!c.paused);
  // Spinner only when actively running (not when paused).
  $('#run-spinner').classList.toggle('hidden', !!c.paused);
  $('#run-label').textContent = c.paused ? `Paused — ${c.action}` : `Running — ${c.action}`;
  $('#btn-pause').classList.toggle('hidden', !!c.paused);
  $('#btn-resume').classList.toggle('hidden', !c.paused);
}

function renderLogs() {
  const list = $('#log-list');
  const q = state.query.toLowerCase();
  const filtered = state.logs.filter((e) => {
    if (!state.enabledLevels.has(e.level)) return false;
    if (!q) return true;
    return (
      e.message.toLowerCase().includes(q) ||
      (e.scope || '').toLowerCase().includes(q)
    );
  });
  $('#log-count').textContent = `(${filtered.length}/${state.logs.length})`;
  list.innerHTML = '';
  for (const entry of filtered) {
    list.appendChild(renderEntry(entry, q));
  }
  // auto-scroll when not filtering
  if (!q) list.scrollTop = list.scrollHeight;
}

function renderEntry(entry, q) {
  const time = (entry.time || '').split('T')[1]?.split('.')[0] || '';
  const firstLine = entry.message.split('\n', 1)[0];
  const node = el('div', { class: `log ${entry.level}` });
  if ((entry.scope || '') === 'check-ss' &&
      firstLine.includes('IMPORTANT CHECK SS SUMMARY')) {
    node.classList.add('important-summary');
    node.classList.add('expanded');
  }
  const header = el('div', { class: 'line' });
  header.appendChild(el('span', { class: 'time' }, time));
  if (entry.scope) header.appendChild(el('span', { class: 'scope' }, `[${entry.scope}]`));
  header.appendChild(highlight(firstLine, q));
  node.appendChild(header);
  if (entry.message.includes('\n')) {
    node.appendChild(el('div', { class: 'body' }, highlight(entry.message, q)));
    header.addEventListener('click', () => node.classList.toggle('expanded'));
    node.style.cursor = 'pointer';
  }
  return node;
}

function highlight(text, q) {
  if (!q) return document.createTextNode(text);
  const lower = text.toLowerCase();
  const needle = q.toLowerCase();
  const frag = document.createDocumentFragment();
  let i = 0;
  while (i < text.length) {
    const idx = lower.indexOf(needle, i);
    if (idx < 0) {
      frag.appendChild(document.createTextNode(text.slice(i)));
      break;
    }
    if (idx > i) frag.appendChild(document.createTextNode(text.slice(i, idx)));
    frag.appendChild(el('mark', {}, text.slice(idx, idx + needle.length)));
    i = idx + needle.length;
  }
  return frag;
}
