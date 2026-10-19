const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const root = path.resolve(__dirname, '..');
const viewPath = path.join(root, 'backup-view.js');
const view = fs.existsSync(viewPath) ? require(viewPath) : {};
const destinationId = 'beta-destination';
function fixture() {
  const destination = { id: destinationId, driveLetter: 'X', label: 'Sample USB', backupFormatVersion: 2, volumeUniqueId: 'volume-A', manualBetaConfirmedAt: '2026-10-19T00:00:00Z' };
  const repository = { computerId: 'pc', computerName: 'Test PC', ownedByCurrentComputer: true, state: 'committed', currentManifestId: 'manifest-A', currentTransactionId: 'tx-A', committedAt: null, backupCreatedAt: '2026-10-18T10:00:00Z', locations: [{ locationId: 'latest', kind: 'latest', partial: false }, { locationId: 'previous-A', kind: 'previous', partial: true }, { locationId: 'deleted-A', kind: 'deleted', partial: true }], capabilities: { browse: true, manualBackup: true, legacyRestore: false, manualVerify: false, automaticRetention: false } };
  return { config: { destination, knownDestinations: [destination], jobs: [], schedule: { enabled: false }, reminders: { enabled: false }, cloudCheck: { enabled: false }, terms: { version: '2026-03-16', acceptedVersion: '2026-03-16', acceptedAt: '2026-10-19T00:00:00Z' } }, status: { recentSnapshots: [], snapshotCatalog: [] }, catalog: { schema: 'datasafe.app-catalog', formatVersion: 1, destinationId, backupFormatVersion: 2, connection: 'connected', volumeMatch: true, state: 'committed', checkedAtUtc: '2026-10-19T00:00:00Z', lastKnown: false, currentComputerId: 'pc', latestCommittedAt: null, repositories: [repository], legacySnapshots: [], warnings: [] }, lastAttempt: null, activeOperation: null, meta: { version: 'test', isPackaged: false } };
}

// Break caught: extrapolating phase percent into byte progress or a guessed ETA.
test('v2 phases have elapsed time but no guessed ETA', () => {
  for (const phase of ['starting', 'scanning', 'staging', 'applying', 'finished-with-issue']) {
    const result = view.projectBackupProgress({ operation: { backupFormatVersion: 2, startedAt: '2026-10-19T00:00:00Z' }, progress: { phase, percent: 90 }, now: '2026-10-19T00:20:00Z' });
    assert.equal(result.elapsedSeconds, 1200); assert.equal(result.etaSeconds, null); assert.equal(result.indeterminate, true); assert.equal(result.percent, null);
  }
});
// Break caught: presenting transaction history as dated complete snapshots.
test('partial history is not a dated complete snapshot; unchanged does not increase snapshot count', () => {
  const f = fixture(), initial = view.projectBackupView(f);
  assert.equal(initial.repositories[0].locations[0].label, 'Latest Backup');
  assert.equal(initial.repositories[0].locations[0].partial, false);
  const history = initial.repositories[0].locations.slice(1);
  for (const location of history) { assert.equal(location.partial, true); assert.match(location.label, /Earlier Versions/); assert.match(location.explanation, /partial.*not a complete snapshot/i); }
  f.lastAttempt = { destinationId, backupFormatVersion: 2, outcome: 'committed', transactionId: 'tx-A', committedAt: null, copyBytes: 0 };
  const unchanged = view.projectBackupView(f);
  assert.equal(unchanged.snapshotCount, 1); assert.equal(initial.snapshotCount, 1);
  assert.match(unchanged.message, /no file content needed copying/i); assert.match(unchanged.message, /still.*verification I\/O/i);
  assert.match(unchanged.backupTimeLabel, /backup created/i); assert.doesNotMatch(unchanged.backupTimeLabel, /completed|committed at/i);
});
// Break caught: same-kind groups lose their dates, making recovery navigation ambiguous.
test('same-kind history groups retain distinguishable producer labels as text with partial-history copy', async () => {
  const f = fixture();
  const labels = ['Backup from 2026-10-18 10-00-00 - Previous Versions', 'Backup from 2026-10-19 11-00-00 <sample> - Previous Versions'];
  f.catalog.repositories[0].locations = labels.map((label, i) => ({ locationId: `previous-${i}`, label, kind: 'previous', partial: true }));
  const result = view.projectBackupView(f);
  assert.notEqual(result.repositories[0].locations[0].label, result.repositories[0].locations[1].label);
  const h = renderer(f); await settle();
  const rows = h.node('backup-locations').children;
  for (let i = 0; i < labels.length; i++) {
    assert.ok(result.repositories[0].locations[i].label.includes(labels[i]));
    assert.match(result.repositories[0].locations[i].explanation, /partial.*not a complete snapshot/i);
    const button = rows[i + 1].children[0];
    assert.ok(button.textContent.includes(labels[i]), 'Producer label must be rendered using textContent');
    await button.click(); assert.equal(h.calls.at(-1)[1].locationId, `previous-${i}`);
  }
});

// Break caught: latest failure/warning losing the last committed identity or inventing success.
test('warning, rollback and failed attempt retain authoritative latest backup', () => {
  for (const [outcome, recoveryAction, title] of [['committed-with-warning', 'retained', /saved.*attention/i], ['failed', 'rolledBack', /rolled back/i], ['failed', 'none', /needs attention/i], ['busy', 'none', /already running/i]]) {
    const f = fixture(); f.lastAttempt = { destinationId, backupFormatVersion: 2, outcome, recoveryAction, message: 'Check the drive', warnings: ['Cleanup evidence retained'] };
    const result = view.projectBackupView(f); assert.match(result.title, title); assert.equal(result.snapshotCount, 1); assert.match(result.message, /Check the drive/);
    assert.equal(result.repositories[0].locations[0].locationId, 'latest');
  }
  const f = fixture(); f.catalog.state = 'recovery-required'; f.catalog.repositories[0].state = 'recovery-required'; f.catalog.repositories[0].capabilities.browse = false;
  f.lastAttempt = { destinationId, backupFormatVersion: 2, outcome: 'committed-with-warning' };
  const result = view.projectBackupView(f); assert.match(result.title, /saved.*attention/i); assert.equal(result.repositories[0].locations[0].canOpen, false);
});

// Break caught: real worker Code/Message objects vanish into object coercion.
test('structured worker warnings render readable safe Message and Code text', async () => {
  const f = fixture();
  f.lastAttempt = { destinationId, backupFormatVersion: 2, outcome: 'committed-with-warning', warnings: [
    { Code: 'StagingCleanupFailed', Message: 'Staging cleanup needs review <sample>.' },
    { Code: 'JournalFinalizationFailed' }, 'String warning remains visible',
    { Message: { nested: 'not display text' }, Code: 42 }, null
  ] };
  const result = view.projectBackupView(f);
  assert.match(result.message, /Staging cleanup needs review <sample>\./);
  assert.match(result.message, /JournalFinalizationFailed/);
  assert.match(result.message, /String warning remains visible/);
  assert.doesNotMatch(result.message, /\[object Object\]|undefined|null|42/);
  const h = renderer(f); await settle();
  assert.ok(h.node('protection-message').textContent.includes('Staging cleanup needs review <sample>.'));
  assert.doesNotMatch(h.node('protection-message').textContent, /\[object Object\]/);
});
test('disconnected last-known history and other PCs are read-only, estimates and unsupported tools are explicit', () => {
  const f = fixture(); f.catalog.connection = 'disconnected'; f.catalog.lastKnown = true;
  let result = view.projectBackupView(f); assert.match(result.message, /last.known|disconnected/i); assert.equal(result.canManualBackup, false); assert.equal(result.repositories[0].locations[0].canOpen, false);
  f.catalog.connection = 'connected'; f.catalog.lastKnown = false; f.catalog.repositories[0].ownedByCurrentComputer = false;
  result = view.projectBackupView(f); assert.equal(result.repositories[0].readOnly, true); assert.equal(result.repositories[0].locations[0].canOpen, true);
  assert.match(result.storageEstimate, /not calculated/i);
  for (const key of ['manualVerify', 'automaticRetention', 'legacyRestore']) assert.equal(result.capabilities[key], false);
  assert.match(result.limitations, /verify/i); assert.match(result.limitations, /assisted restore/i); assert.match(result.limitations, /automatic retention/i);
});
test('Public sources refuse enrollment without changing jobs; foreign catalog and attempt cannot import success', () => {
  const f = fixture(); f.config.destination.backupFormatVersion = 1; f.config.jobs = [{ enabled: true, includePublicFolder: 'Documents', path: 'C:\\sample' }];
  const before = JSON.stringify(f.config.jobs); let result = view.projectBackupView(f);
  assert.equal(result.canEnroll, false); assert.match(result.enrollmentIssue, /Public/); assert.equal(JSON.stringify(f.config.jobs), before);
  f.config.destination.backupFormatVersion = 2; f.catalog.destinationId = 'other'; f.lastAttempt = { destinationId: 'other', backupFormatVersion: 2, outcome: 'committed', copyBytes: 0 };
  result = view.projectBackupView(f); assert.equal(result.snapshotCount, 0); assert.notEqual(result.title, 'Your backup is up to date'); assert.equal(result.repositories.length, 0);
});

class Element {
  constructor(id = '') { this.id = id; this.children = []; this.listeners = {}; this.hidden = false; this.value = ''; this.textContent = ''; this.checked = false; this.disabled = false; this.style = {}; this.dataset = {}; this.nodes = new Map(); this.classList = { add() {}, remove() {}, toggle() {} }; this.content = this; }
  set innerHTML(value) { this.children = []; this.value = ''; }
  get innerHTML() { return ''; }
  appendChild(child) { this.children.push(child); if (child.selected || (this.children.length === 1 && child.value)) this.value = child.value; return child; }
  replaceChildren(...children) { this.children = children; }
  querySelector(selector) { if (!this.nodes.has(selector)) this.nodes.set(selector, new Element()); return this.nodes.get(selector); }
  querySelectorAll() { return []; }
  closest() { return new Element(); }
  cloneNode() { return new Element(); }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  removeAttribute() {}
  setAttribute() {}
  async click() { if (!this.disabled) { await this.listeners.click?.({ target: this }); await this.onclick?.(); } }
}
const settle = async () => { for (let i = 0; i < 12; i++) await new Promise(setImmediate); };
function renderer(payload = fixture(), desktop = true) {
  const nodes = new Map(), calls = [], subscriptions = {};
  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  const node = id => { if (!ids.has(id)) return null; if (!nodes.has(id)) nodes.set(id, new Element(id)); return nodes.get(id); };
  const api = { getState: async () => JSON.parse(JSON.stringify(payload)), saveConfig: async config => ({ ...payload, config }), analyzeStorage: async () => ({ storage: { requiredBytes: 123456 } }), refreshBackups: async () => JSON.parse(JSON.stringify(payload)),
    enrollIncrementalTest: async request => { calls.push(['enroll', request]); return payload; }, openBackupLocation: async request => { calls.push(['open', request]); return { opened: true }; },
    runBackup: async () => { calls.push(['backup']); return payload; }, planRestore: async request => { calls.push(['plan', request]); return { plan: { sourceFiles: 1 } }; }, restoreSnapshot: async request => { calls.push(['restore', request]); return {}; },
    onBackupProgress: fn => { subscriptions.progress = fn; }, onStatusChanged: fn => { subscriptions.status = fn; } };
  const context = vm.createContext({ window: desktop ? { onebiteDesktop: api } : {}, document: { getElementById: node, createElement: () => new Element(), body: new Element(), addEventListener() {}, querySelectorAll: () => [] }, console, Intl, Date, setTimeout: () => 0, clearTimeout() {}, setInterval: () => 1, clearInterval() {}, fetch: async () => ({ ok: true, json: async () => payload }) });
  // Execute the actual page's script order, not a test-only order which could
  // hide a missing packaged asset or a load-before-definition failure.
  const bundled = require('../electron-builder.config').files;
  for (const match of html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"[^>]*>/g)) {
    assert.ok(bundled.includes(match[1]), `Page script ${match[1]} is not packaged`);
    vm.runInContext(fs.readFileSync(path.join(root, match[1]), 'utf8'), context, { filename: match[1] });
  }
  return { context, node, calls, subscriptions, api, payload, run: source => vm.runInContext(source, context) };
}
test('actual preload maps enrollment, refresh, opaque browse and unsubscribes progress/status', async () => {
  let api; const calls = [], listeners = new Map();
  const ipcRenderer = { invoke: async (...args) => { calls.push(args); return 'ok'; }, on: (channel, fn) => listeners.set(channel, fn), removeListener: (channel, fn) => { assert.equal(listeners.get(channel), fn); listeners.delete(channel); } };
  vm.runInNewContext(fs.readFileSync(path.join(root, 'preload.js'), 'utf8'), { require: () => ({ contextBridge: { exposeInMainWorld: (_name, value) => { api = value; } }, ipcRenderer }) });
  const request = { destinationId, computerId: 'pc', locationId: 'latest' };
  assert.equal(await api.enrollIncrementalTest({ confirmedManualTesting: true }), 'ok'); await api.refreshBackups(); await api.openBackupLocation(request);
  assert.equal(calls[0][0], 'beta:enroll-incremental'); assert.equal(calls[1][0], 'backups:refresh'); assert.equal(calls[2][0], 'backups:open-location'); assert.equal(calls[2][1], request);
  for (const [method, channel] of [['onBackupProgress', 'backup:progress'], ['onStatusChanged', 'status:changed']]) { let received; const off = api[method](p => { received = p; }); listeners.get(channel)({}, request); assert.equal(received, request); off(); assert.equal(listeners.has(channel), false); }
});
test('renderer refuses v2 restore even with forged selectors; legacy still previews and restores', async () => {
  const h = renderer(); await settle(); h.node('restore-snapshot-select').value = '2026-10-18_10-00-00'; h.node('restore-job-select').value = 'job'; h.node('restore-mode-select').value = 'original';
  await h.run('runRestore()'); await h.run('performRestore()'); assert.equal(h.calls.some(c => ['plan', 'restore'].includes(c[0])), false);
  h.payload.config.destination.backupFormatVersion = 1; h.payload.catalog = null; h.payload.config.jobs = [{ id: 'job', name: 'Sample', path: 'C:\\sample' }];
  h.payload.status.recentSnapshots = ['2026-10-18_10-00-00']; h.payload.status.snapshotCatalog = [{ name: '2026-10-18_10-00-00', jobs: [{ id: 'job', name: 'Sample', sourcePath: 'C:\\sample' }] }];
  await h.run('load()'); await h.run('runRestore()'); await h.run('performRestore()'); assert.deepEqual(h.calls.filter(c => ['plan', 'restore'].includes(c[0])).map(c => c[0]), ['plan', 'restore']);
});
test('renderer ignores foreign/stale progress and raw status success; matching progress has no ETA', async () => {
  const f = fixture(); f.activeOperation = { operationId: 'op-current', destinationId, backupFormatVersion: 2, startedAt: '2026-10-19T00:00:00Z' };
  const h = renderer(f); await settle();
  h.subscriptions.progress({ operationId: 'op-old', destinationId, backupFormatVersion: 2, phase: 'complete', percent: 100 }); await settle(); assert.equal(h.run('state.backupProgress'), null);
  h.subscriptions.progress({ operationId: 'op-current', destinationId: 'other', backupFormatVersion: 2, phase: 'scanning', percent: 90 }); await settle(); assert.equal(h.run('state.backupProgress'), null);
  h.subscriptions.progress({ operationId: 'op-current', destinationId, backupFormatVersion: 2, phase: 'scanning', percent: 90 }); await settle();
  assert.equal(h.run('getBackupProgressView().indeterminate'), true); assert.match(h.run('getBackupProgressView().timing.etaText'), /not available/i);
  h.subscriptions.status({ status: { lastBackupResult: 'success', lastBackupAt: '2099-01-01', recentSnapshots: ['forged'] }, catalog: { ...f.catalog, destinationId: 'other' } }); await settle();
  assert.notEqual(h.node('last-backup').textContent, '2099-01-01'); assert.equal(h.node('snapshot-count').textContent, '1');
});
test('renderer stale refresh cannot import a catalog after selection changes', async () => {
  const h = renderer(); await settle(); let resolve;
  h.api.refreshBackups = () => new Promise(r => { resolve = r; });
  const pending = h.run('refreshBackupCatalog()'); await settle(); h.run("state.config.destination = { id: 'new-destination', backupFormatVersion: 2 }");
  resolve(h.payload); await pending; assert.notEqual(h.run('state.catalog?.destinationId'), destinationId);
});
// Break caught: a same-destination read started before a terminal action can
// resurrect its old operation or erase the terminal attempt after it arrives.
for (const [snapshot, force, outcome] of [['active', true, 'failed'], ['idle', false, 'failed'], ['active', false, 'committed'], ['idle', true, 'committed']]) {
  test(`older same-destination ${snapshot} refresh cannot replace a newer ${outcome} action result`, async () => {
    const f = fixture(), h = renderer(f); await settle();
    const old = JSON.parse(JSON.stringify(f));
    old.catalog.repositories[0].currentTransactionId = 'older-transaction';
    old.activeOperation = snapshot === 'active' ? { operationId: 'old-op', destinationId, backupFormatVersion: 2, startedAt: '2026-10-19T00:00:00Z' } : null;
    let resolve;
    h.api[force ? 'refreshBackups' : 'getState'] = () => new Promise(r => { resolve = r; });
    const pending = h.run(`refreshBackupCatalog({ force: ${force} })`); await settle();
    const terminal = { ...f, lastAttempt: { operationId: 'new-op', destinationId, backupFormatVersion: 2, outcome, transactionId: 'tx-A', message: 'Latest run result' }, activeOperation: null };
    h.api.runBackup = async () => terminal;
    await h.run("invokeAction('/api/run-backup', { skipSave: true })");
    const expectedTitle = outcome === 'failed' ? 'Backup needs attention' : 'Your backup is up to date';
    assert.equal(h.node('protection-state').textContent, expectedTitle);
    resolve(old); await pending;
    assert.equal(h.node('protection-state').textContent, expectedTitle);
    assert.equal(h.node('run-backup').disabled, false);
    assert.equal(h.run('state.activeOperation'), null);
    assert.equal(h.run('state.lastAttempt.operationId'), 'new-op');
    assert.equal(h.run('state.catalog.repositories[0].currentTransactionId'), 'tx-A');
  });
}
test('a current same-destination refresh and matching progress still apply after a terminal result', async () => {
  const f = fixture(), h = renderer(f); await settle();
  h.api.runBackup = async () => ({ ...f, lastAttempt: { destinationId, backupFormatVersion: 2, outcome: 'failed', message: 'Earlier run failed' } });
  await h.run("invokeAction('/api/run-backup', { skipSave: true })");
  const current = { ...f, activeOperation: { operationId: 'next-op', destinationId, backupFormatVersion: 2, startedAt: '2026-10-19T00:00:00Z' } };
  h.api.refreshBackups = async () => current; await h.run('refreshBackupCatalog()');
  assert.equal(h.node('protection-state').textContent, 'Backup in progress');
  assert.equal(h.node('run-backup').disabled, true);
  h.subscriptions.progress({ operationId: 'next-op', destinationId, backupFormatVersion: 2, phase: 'scanning', percent: 90 }); await settle();
  assert.equal(h.run('state.backupProgress.operationId'), 'next-op');
  assert.equal(h.run('state.backupProgress.phase'), 'scanning');
  assert.equal(h.run('getBackupProgressView().indeterminate'), true);
});
test('untagged stale status notifications do not import v2 success into a selected Legacy set', async () => {
  const f = fixture(); f.config.destination.backupFormatVersion = 1; f.catalog.backupFormatVersion = 1; f.catalog.volumeMatch = null; f.catalog.repositories = [];
  const h = renderer(f); await settle();
  h.subscriptions.status({ status: { lastBackupResult: 'success', lastBackupAt: '2099-01-01', recentSnapshots: ['old-v2-success'] } }); await settle();
  assert.equal(h.node('snapshot-count').textContent, '0'); assert.equal(h.run('state.status.lastBackupAt'), undefined);
});
test('renderer enrollment requires both confirmations and compatible jobs; browse sends IDs only', async () => {
  const f = fixture(); f.config.destination.backupFormatVersion = 1; f.catalog.backupFormatVersion = 1; f.catalog.volumeMatch = null; f.config.jobs = [{ id: 'sample', enabled: true, path: 'C:\\sample', type: 'folder' }];
  const h = renderer(f); await settle(); await h.run('enrollIncrementalTest()'); assert.equal(h.calls.length, 0);
  h.node('beta-confirm-manual').checked = true; await h.run('enrollIncrementalTest()'); assert.equal(h.calls.length, 0);
  h.node('beta-confirm-limitations').checked = true; await h.run('enrollIncrementalTest()'); assert.equal(h.calls[0][0], 'enroll'); assert.equal(h.calls[0][1].destinationId, destinationId);
  f.config.destination.backupFormatVersion = 2; f.catalog.backupFormatVersion = 2; f.catalog.volumeMatch = true; await h.run('load()');
  await h.run("openBackupLocation('pc', 'latest')"); assert.deepEqual(JSON.parse(JSON.stringify(h.calls.at(-1))), ['open', { destinationId, computerId: 'pc', locationId: 'latest' }]);
  await h.run("openBackupLocation('pc', '../forged')"); assert.equal(h.calls.filter(c => c[0] === 'open').length, 1);
});
test('preview renderer offers no real v2 enrollment, backup or open action', async () => {
  const h = renderer(fixture(), false); await settle(); h.node('beta-confirm-manual').checked = true; h.node('beta-confirm-limitations').checked = true;
  await h.run('enrollIncrementalTest()'); await h.run("openBackupLocation('pc', 'latest')"); await h.run("invokeAction('/api/run-backup', { skipSave: true })");
  assert.equal(h.node('run-backup').disabled, true); assert.match(h.node('protection-message').textContent, /preview|installed/i); assert.doesNotMatch(h.node('result-modal-title').textContent, /Backup Complete/);
});
test('actual renderer result is destination-bound and a failed run never animates success', async () => {
  const f = fixture(), h = renderer(f); await settle();
  h.api.runBackup = async () => ({ ...f, status: { lastBackupResult: 'success', lastBackupAt: '2099-01-01' }, lastAttempt: { destinationId, backupFormatVersion: 2, outcome: 'failed', message: 'Source unavailable' } });
  await h.run("invokeAction('/api/run-backup', { skipSave: true })");
  assert.match(h.node('result-modal-title').textContent, /needs attention/i); assert.equal(h.node('result-progress-shell').hidden, true); assert.equal(h.node('snapshot-count').textContent, '1');
  let resolve; h.api.runBackup = () => new Promise(r => { resolve = r; }); const pending = h.run("invokeAction('/api/run-backup', { skipSave: true })"); await settle();
  h.run("state.config.destination = { id: 'switched', backupFormatVersion: 2 }; clearBackupSelection(); renderStatus()");
  resolve({ ...f, lastAttempt: { destinationId, backupFormatVersion: 2, outcome: 'committed', copyBytes: 0 } }); await pending;
  assert.equal(h.node('snapshot-count').textContent, '0'); assert.notEqual(h.node('result-modal-title').textContent, 'Your backup is up to date');
});
test('actual rendered limitations, manual-only settings and other-PC browse stay capability-driven', async () => {
  const f = fixture(); f.catalog.repositories.push({ ...f.catalog.repositories[0], computerId: 'other-pc', ownedByCurrentComputer: false, computerName: 'Other laptop' });
  const h = renderer(f); await settle();
  for (const id of ['schedule-enabled', 'reminders-enabled', 'cloud-check-enabled', 'retention-days', 'install-automation', 'run-restore']) assert.equal(h.node(id).disabled, true, id);
  assert.match(h.node('backup-size-estimate').textContent, /not calculated/i); assert.match(h.node('destination-integrity-summary').textContent, /unavailable/i);
  assert.match(h.node('beta-limitations').textContent, /assisted restore.*automatic retention/i);
  const rows = h.node('backup-locations').children; assert.ok(rows.some(row => /Other PC.*read-only/.test(row.textContent)));
  const otherLatest = rows[5].children[0]; await otherLatest.click(); assert.equal(h.calls.at(-1)[1].computerId, 'other-pc');
  f.catalog.repositories[1].capabilities = { ...f.catalog.repositories[1].capabilities, browse: false }; await h.run('load()');
  assert.equal(h.node('backup-locations').children[5].children[0].disabled, true);
});
test('Public jobs and stale legacy catalog cannot enroll via the actual handler', async () => {
  const f = fixture(); f.config.destination.backupFormatVersion = 1; f.catalog.backupFormatVersion = 1; f.catalog.volumeMatch = null;
  f.config.jobs = [{ id: 'sample', enabled: true, path: 'C:\\sample', includePublicDesktop: true }];
  const h = renderer(f); await settle(); h.node('beta-confirm-manual').checked = true; h.node('beta-confirm-limitations').checked = true;
  await h.run('enrollIncrementalTest()'); assert.equal(h.calls.length, 0); assert.match(h.node('beta-summary').textContent, /Public/);
  h.run("state.config.jobs[0].includePublicDesktop = false; state.catalog.destinationId = 'stale'"); await h.run('enrollIncrementalTest()'); assert.equal(h.calls.length, 0);
});
test('enrollment refuses unsaved source and automation drafts without saving or enrolling; displayed choices are current', async () => {
  const f = fixture(); f.config.destination.backupFormatVersion = 1; f.catalog.backupFormatVersion = 1; f.catalog.volumeMatch = null;
  f.config.jobs = [{ id: 'sample', enabled: true, path: 'C:\\saved-samples', type: 'folder' }];
  f.config.schedule = { enabled: true, frequency: 'weekly', dayOfWeek: 'Monday', time: '12:00' };
  f.config.betaTest = { previousAutomation: { schedule: { enabled: false }, reminders: { enabled: false }, cloudChecks: { enabled: false } } };
  const h = renderer(f); await settle(); let saves = 0; h.api.saveConfig = async () => { saves++; };
  assert.match(h.node('beta-summary').textContent, /Schedule: enabled/);
  h.node('beta-confirm-manual').checked = true; h.node('beta-confirm-limitations').checked = true;
  h.run("state.config.jobs[0].path = 'C:\\\\draft-samples'");
  await h.run('enrollIncrementalTest()'); assert.equal(h.calls.length, 0); assert.equal(saves, 0); assert.match(h.node('result-modal-message').textContent, /save.*before/i);
  h.node('beta-confirm-manual').checked = true; h.node('beta-confirm-limitations').checked = true;
  h.run("state.config.jobs[0].path = 'C:\\\\saved-samples'"); h.node('schedule-time').value = '14:00';
  await h.run('enrollIncrementalTest()'); assert.equal(h.calls.length, 0); assert.equal(saves, 0);
  h.node('schedule-time').value = '12:00'; h.node('beta-confirm-manual').checked = true; h.node('beta-confirm-limitations').checked = true;
  await h.run('enrollIncrementalTest()'); assert.equal(h.calls.filter(c => c[0] === 'enroll').length, 1);
});
test('non-backup responses keep the validated v2 catalog and stale terminal errors do not replace the selected view', async () => {
  const f = fixture(), h = renderer(f); await settle();
  h.api.checkCloud = async () => ({ status: { cloud: { summary: 'Reviewed', level: 'info' } } });
  await h.run("invokeAction('/api/check-cloud', { skipSave: true })");
  assert.equal(h.node('snapshot-count').textContent, '1'); assert.equal(h.run('state.catalog.destinationId'), destinationId);
  let reject; h.api.runBackup = () => new Promise((_resolve, r) => { reject = r; });
  const pending = h.run("invokeAction('/api/run-backup', { skipSave: true })"); await settle();
  h.run("state.config.destination = { id: 'new-target', backupFormatVersion: 2 }; clearBackupSelection(); renderStatus()");
  reject(new Error('old destination failure')); await pending;
  assert.notEqual(h.node('protection-message').textContent, 'old destination failure'); assert.notEqual(h.node('result-modal-message').textContent, 'old destination failure');
});
test('preview cannot forge enrollment through a legacy config save and legacy simulation is disclosed', async () => {
  const f = fixture(); f.config.destination.backupFormatVersion = 1;
  let saved = 0;
  const context = vm.createContext({ require: name => name === 'http' ? { createServer: () => ({ listen() {} }) } : name === 'fs' ? { readFileSync: filename => JSON.stringify(String(filename).endsWith('config.json') ? f.config : f.status), writeFileSync: () => { saved++; } } : name.endsWith('package.json') ? { version: 'test' } : require(name.startsWith('./') ? path.join(root, name) : name), __dirname: root, process: { platform: 'darwin', env: {} }, console, URL });
  vm.runInContext(fs.readFileSync(path.join(root, 'server.js'), 'utf8'), context);
  const request = async (url, body) => {
    const req = new EventEmitter(); req.method = 'POST'; req.url = url; let code, result;
    context.req = req; context.res = { writeHead: value => { code = value; }, end: value => { result = JSON.parse(value); } };
    const pending = vm.runInContext('handleApi(req, res)', context); queueMicrotask(() => { req.emit('data', Buffer.from(JSON.stringify(body))); req.emit('end'); }); await pending; return { code, result };
  };
  const forged = await request('/api/config', { ...f.config, destination: { ...f.config.destination, backupFormatVersion: 2 } }); assert.equal(forged.code, 409); assert.equal(saved, 0);
  const simulation = await request('/api/run-backup', {}); assert.equal(simulation.code, 200); assert.match(simulation.result.status.lastBackupMessage, /Preview mode: simulated backup/);
});
test('preview server rejects v2 mutation routes without worker, config or status writes', async () => {
  const f = fixture(), writes = [], workers = [];
  const memory = { readFileSync: filename => JSON.stringify(String(filename).endsWith('config.json') ? f.config : f.status), writeFileSync: (...args) => writes.push(args) };
  const context = vm.createContext({ require: name => name === 'http' ? { createServer: () => ({ listen() {} }) } : name === 'fs' ? memory : name === 'child_process' ? { spawn: (...args) => workers.push(args) } : name.endsWith('package.json') ? { version: 'test' } : require(name.startsWith('./') ? path.join(root, name) : name), __dirname: root, process: { platform: 'darwin', env: {} }, console, URL });
  vm.runInContext(fs.readFileSync(path.join(root, 'server.js'), 'utf8'), context);
  for (const url of ['/api/enroll-incremental', '/api/open-backup-location', '/api/run-backup', '/api/install-automation', '/api/restore-plan', '/api/restore-snapshot', '/api/config']) {
    const req = new EventEmitter(); req.method = 'POST'; req.url = url; let code, result;
    context.req = req; context.res = { writeHead: value => { code = value; }, end: value => { result = JSON.parse(value); } };
    const pending = vm.runInContext('handleApi(req, res)', context); queueMicrotask(() => { req.emit('data', Buffer.from(JSON.stringify(f.config))); req.emit('end'); }); await pending;
    assert.equal(code, 409, url); assert.match(result.error, /preview|installed/i);
  }
  assert.equal(writes.length, 0); assert.equal(workers.length, 0);
});
