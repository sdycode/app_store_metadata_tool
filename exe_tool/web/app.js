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

// ---- Wire initial UI ------------------------------------------------------
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
    renderMismatch();
    postOptions();
  });
});

$('#ss-force-replace').addEventListener('change', (e) => {
  state.forcefulReplace = e.target.checked;
  postOptions();
});
$('#ss-replace-mismatch').addEventListener('change', (e) => {
  state.replaceOnMismatch = e.target.checked;
  postOptions();
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
    const all = state.workspace.localizations;
    const op = b.dataset.localeOp;
    if (op === 'all') state.selectedLocales = new Set(all);
    else if (op === 'none') state.selectedLocales = new Set();
    else if (op === 'invert') {
      state.selectedLocales = new Set(all.filter((l) => !state.selectedLocales.has(l)));
    }
    renderLocales();
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
    $('#ss-force-replace').checked = state.forcefulReplace;
    $('#ss-replace-mismatch').checked = state.replaceOnMismatch;
    renderLocales();
    renderWarnings(s.workspace.warnings || []);
    renderMismatch();
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
    b.disabled = !enabled;
  });
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

function renderLocales() {
  const host = $('#locale-chips');
  host.innerHTML = '';
  const ws = state.workspace;
  if (!ws) return;
  for (const loc of ws.localizations) {
    const chip = el(
      'span',
      {
        class: 'chip' + (state.selectedLocales.has(loc) ? ' selected' : ''),
      },
      loc
    );
    chip.addEventListener('click', () => {
      if (state.selectedLocales.has(loc)) state.selectedLocales.delete(loc);
      else state.selectedLocales.add(loc);
      renderLocales();
      postLocales();
    });
    host.appendChild(chip);
  }
  $('#locale-count').textContent = `(${state.selectedLocales.size}/${ws.localizations.length})`;
  $('#locale-empty-hint').classList.toggle('hidden', state.selectedLocales.size > 0);
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
