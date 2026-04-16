'use strict';

const LEVELS = ['debug', 'info', 'warn', 'error', 'success'];

const state = {
  workspace: null,
  selectedLocales: new Set(),
  replaceScreenshots: true,
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
    const replace = state.tab === 'new-push';
    state.replaceScreenshots = replace;
    $('#replace-ss').checked = replace;
    renderReplaceHint();
    postOptions();
  });
});

$('#replace-ss').addEventListener('change', (e) => {
  state.replaceScreenshots = e.target.checked;
  renderReplaceHint();
  postOptions();
});

document.querySelectorAll('[data-action]').forEach((b) => {
  b.addEventListener('click', () => runAction(b.dataset.action));
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

renderReplaceHint();

// ---- Workspace upload -----------------------------------------------------
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
  try {
    const resp = await fetch('/upload', { method: 'POST', body: form });
    if (!resp.ok) throw new Error(await resp.text());
    const data = await resp.json();
    applyStatus(data.status);
    $('#load-hint').textContent = 'Workspace loaded. Run any action.';
  } catch (err) {
    alert('Upload failed: ' + err);
    $('#load-hint').textContent = 'Load failed — see logs';
  } finally {
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
    body: JSON.stringify({ replaceScreenshots: state.replaceScreenshots }),
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
    state.replaceScreenshots = !!s.replaceScreenshots;
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
    $('#replace-ss').checked = state.replaceScreenshots;
    renderReplaceHint();
    renderLocales();
  }
  state.controlState = s.control || state.controlState;
  renderRunBar();
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
    return;
  }
  bar.classList.remove('hidden');
  $('#run-indicator').classList.toggle('paused', !!c.paused);
  $('#run-label').textContent = c.paused ? `Paused — ${c.action}` : `Running — ${c.action}`;
  $('#btn-pause').classList.toggle('hidden', !!c.paused);
  $('#btn-resume').classList.toggle('hidden', !c.paused);
}

function renderReplaceHint() {
  const hint = state.tab === 'new-push'
    ? 'Replace SS — wipes all existing screenshots across display types'
    : 'Replace SS — off = skip when count matches';
  $('#replace-hint').textContent = hint;
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
