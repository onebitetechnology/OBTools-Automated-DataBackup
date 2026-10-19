const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const { createRequire } = require('node:module');
const crypto = require('node:crypto');
const mainPath = path.resolve(__dirname, '../main.js');
const realRequire = createRequire(mainPath);
const id = '22222222-2222-4222-8222-222222222222';
const legacyId = '11111111-1111-4111-8111-111111111111';
function harness(t, v2 = true) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'datasafe-main-ipc-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const legacy = { id: legacyId, driveLetter: 'X', selectedPath: root, baseFolder: path.relative(path.parse(root).root, path.join(root, 'backups')) };
  const beta = { ...legacy, id, backupFormatVersion: 2, volumeUniqueId: 'volume-A', manualBetaConfirmedAt: '2026-10-19T00:00:00.000Z' };
  const config = { installId: 'fixture', destination: v2 ? beta : legacy, knownDestinations: [legacy, ...(v2 ? [beta] : [])], jobs: [{ id: 'one', name: 'Documents', enabled: true, path: '%USERPROFILE%\\Documents', type: 'folder' }], schedule: { enabled: false }, reminders: { enabled: false }, cloudCheck: { enabled: false } };
  const configPath = path.join(root, 'config.json');
  fs.writeFileSync(configPath, JSON.stringify(config)); fs.writeFileSync(path.join(root, 'status.json'), '{}');
  fs.writeFileSync(path.join(root, 'incremental-computer-id.json'), 'identity-test-sentinel');
  const handlers = new Map(), calls = [], opens = [], events = [];
  const electron = { app: { isPackaged: false, isReady: () => true, getPath: () => root, getVersion: () => '1.0.0-beta', setAppUserModelId() {}, disableHardwareAcceleration() {}, whenReady: () => new Promise(() => {}), on() {}, quit() {} },
    BrowserWindow: { getAllWindows: () => [{ isDestroyed: () => false, webContents: { send: (channel, payload) => events.push({ channel, payload }) } }] },
    ipcMain: { handle: (name, fn) => handlers.set(name, fn) }, shell: { openPath: async p => { opens.push(p); return ''; } }, Menu: {}, Notification: {}, Tray: function() {}, dialog: {} };
  let resolveError = null, held = null;
  const spawn = (_exe, args) => {
    const script = path.basename(args[args.indexOf('-File') + 1]); const supplied = args[args.indexOf('-ConfigPath') + 1]; const c = JSON.parse(fs.readFileSync(supplied, 'utf8')); const action = args[args.indexOf('-Action') + 1];
    calls.push({ script, supplied, config: c, args, identityAdjacent: fs.existsSync(path.join(path.dirname(supplied), 'incremental-computer-id.json')) });
    const child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
    queueMicrotask(async () => {
      if (held?.script === script) { held.started(); await held.gate; }
      let data, code = 0;
      if (script === 'manage-beta-test-tasks.ps1') data = { confirmedPaused: action === 'Pause', tasks: [], warnings: [] };
      else if (action === 'InspectVolume') data = { connected: true, volumeUniqueId: 'volume-A' };
      else if (action === 'ResolveLocation') { data = resolveError ? { error: resolveError } : { destinationId: c.destination.id, computerId: 'pc', locationId: 'latest', path: path.join(root, 'resolved-private') }; code = resolveError ? 1 : 0; }
      else if (script === 'inspect-backup-catalog.ps1') data = { schema: 'datasafe.app-catalog', formatVersion: 1, destinationId: c.destination.id, backupFormatVersion: 2, connection: 'connected', volumeMatch: true, state: 'committed', currentComputerId: 'pc', lastKnown: false, checkedAtUtc: '2026-10-19T00:00:00Z', repositories: [{ computerId: 'pc', ownedByCurrentComputer: true, state: 'committed', currentManifestId: 'sha256:old', currentTransactionId: 'old', committedAt: null, backupCreatedAt: '2026-10-18T00:00:00Z', locations: [{ locationId: 'latest', kind: 'latest', partial: false }], capabilities: { browse: true, manualBackup: true, legacyRestore: false, manualVerify: false, automaticRetention: false } }], legacySnapshots: [], warnings: [], latestCommittedAt: null };
      else if (script === 'backup-engine.ps1') {
        const operationId = args[args.indexOf('-AppOperationId') + 1];
        child.stdout.emit('data', Buffer.from('__OB_PROGRESS__:' + JSON.stringify({ operationId, destinationId: c.destination.id, backupFormatVersion: 2, phase: 'complete', percent: 100 }) + '\n'));
        data = { schema: 'datasafe.app-backup-result', formatVersion: 1, operationId, destinationId: c.destination.id, backupFormatVersion: 2, outcome: 'busy', transactionId: null, committedAt: null, warnings: [], message: 'busy' };
      } else data = { message: 'unexpected script' };
      child.stdout.emit('data', Buffer.from('__OB_RESULT__:' + JSON.stringify(data) + '\n')); child.emit('close', code);
    }); return child;
  };
  // Load app modules in the same realm as main, as Electron does. Policy
  // deliberately rejects non-plain records; cross-realm VM objects aren't IPC.
  const modules = new Map(); let context;
  const localRequire = name => {
    if (name === 'electron') return electron;
    if (name === 'child_process') return { spawn };
    if (!name.startsWith('./')) return realRequire(name);
    const filename = realRequire.resolve(name);
    if (!modules.has(filename)) {
      const module = { exports: {} }; modules.set(filename, module);
      vm.runInContext(`(function(require, module, exports) { ${fs.readFileSync(filename, 'utf8')}\n})`, context, { filename })(localRequire, module, module.exports);
    }
    return modules.get(filename).exports;
  };
  context = vm.createContext({ require: localRequire, __dirname: path.dirname(mainPath), process: { platform: 'win32', env: { ...process.env, PUBLIC: root }, on() {} }, console, Buffer, setTimeout: () => 0, setInterval: () => ({ unref() {} }), clearInterval() {} });
  vm.runInContext('globalThis.structuredClone = value => JSON.parse(JSON.stringify(value))', context);
  vm.runInContext(fs.readFileSync(mainPath, 'utf8'), context, { filename: mainPath });
  return { root, configPath, config, legacy, calls, opens, events, context,
    hold(script) { let started, release; const start = new Promise(r => { started = r; }); held = { script, started, gate: new Promise(r => { release = r; }) }; return { started: start, release }; },
    set resolveError(v) { resolveError = v; }, invoke: (name, payload) => { assert.ok(handlers.has(name), `Missing ${name}`); context.ipcPayload = payload; const localPayload = payload === undefined ? undefined : vm.runInContext('JSON.parse(JSON.stringify(ipcPayload))', context); return handlers.get(name)({}, localPayload); }, readConfig: () => JSON.parse(fs.readFileSync(configPath, 'utf8')) };
}
test('actual restore and automation handlers fail closed for forged v2 requests', async t => {
  const h = harness(t); for (const name of ['restore:plan', 'restore:run', 'automation:install']) await assert.rejects(async () => h.invoke(name, { snapshotName: 'old', jobId: 'one', backupFormatVersion: 1, destinationId: legacyId }), /incremental|beta|unsupported/i);
  assert.equal(h.calls.length, 0);
});
test('actual state and save round trip v1/v2 identity without adding Public sources', async t => {
  const h = harness(t); const state = await h.invoke('state:get'); assert.equal(state.catalog.destinationId, id); assert.equal(state.config.destination.backupFormatVersion, 2);
  assert.deepEqual(h.readConfig().jobs, h.config.jobs); assert.equal(h.readConfig().knownDestinations.length, 2);
  await h.invoke('config:save', { ...h.config, destination: { ...h.config.destination, backupFormatVersion: 1 }, knownDestinations: [], schedule: { enabled: true } });
  assert.equal(h.readConfig().destination.backupFormatVersion, 2); assert.equal(h.readConfig().schedule.enabled, false); assert.equal(h.readConfig().knownDestinations.length, 2);
  assert.equal(h.calls.some(c => c.script === 'install-scheduled-backup.ps1'), false);
});
test('candidate inspection uses proposed shadow config with adjacent identity; pause uses persisted ownership path', async t => {
  const h = harness(t, false); await h.invoke('beta:enroll-incremental', { destinationId: legacyId, confirmedManualTesting: true, confirmedLimitations: true });
  const enrolled = h.readConfig(); assert.equal(enrolled.destination.backupFormatVersion, 2); assert.notEqual(enrolled.destination.id, legacyId);
  const catalogs = h.calls.filter(c => c.script === 'inspect-backup-catalog.ps1'); assert.ok(catalogs.some(c => c.config.destination.id === enrolled.destination.id));
  for (const c of catalogs) { assert.notEqual(c.supplied, h.configPath); assert.equal(c.identityAdjacent, true); assert.equal(fs.existsSync(c.supplied), false); }
  for (const c of h.calls.filter(c => c.script === 'manage-beta-test-tasks.ps1')) assert.equal(c.supplied, h.configPath);
  assert.equal(fs.readFileSync(path.join(h.root, 'incremental-computer-id.json'), 'utf8'), 'identity-test-sentinel');
  await h.invoke('state:get'); assert.deepEqual(h.readConfig().jobs, h.config.jobs);
});
test('actual browse handler rejects traversal, reparse, stale and raw paths without shell opens', async t => {
  const h = harness(t); for (const reason of ['traversal', 'reparse', 'stale']) { h.resolveError = reason; const r = await h.invoke('backups:open-location', { destinationId: id, computerId: 'pc', locationId: 'latest' }); assert.equal(r.opened, false); }
  const raw = await h.invoke('backups:open-location', { destinationId: id, computerId: 'pc', locationId: 'latest', path: 'C:\\Windows' }); assert.equal(raw.opened, false); assert.equal(h.opens.length, 0);
  h.resolveError = null; const opened = await h.invoke('backups:open-location', { destinationId: id, computerId: 'pc', locationId: 'latest' }); assert.equal(opened.opened, true); assert.equal(JSON.stringify(opened).includes('resolved-private'), false);
});
test('actual v2 worker adapter correlates arguments and withholds complete on busy zero exit', async t => {
  const h = harness(t); const result = await h.invoke('backup:run'); assert.equal(result.lastAttempt.outcome, 'busy');
  const worker = h.calls.find(c => c.script === 'backup-engine.ps1'); assert.ok(worker.args.includes('-ManualBetaRun')); assert.ok(worker.args.includes('-AppOperationId')); assert.notEqual(worker.supplied, h.configPath); assert.equal(fs.existsSync(worker.supplied), false);
  assert.equal(h.events.some(e => e.channel === 'backup:progress' && e.payload.phase === 'complete'), false);
});
test('status watcher uses cached v2 view without launching catalog or projecting legacy snapshots', async t => {
  const h = harness(t); await h.invoke('state:get'); const before = h.calls.length;
  vm.runInContext('syncExternalStatus({ publish: true })', h.context); assert.equal(h.calls.length, before);
  const state = await h.invoke('state:get'); assert.equal(state.status.recentSnapshots.length, 0); assert.equal(state.catalog.backupFormatVersion, 2);
});
test('legacy settings task installation is serialized before enrollment pause', async t => {
  const h = harness(t, false), hold = h.hold('install-scheduled-backup.ps1');
  const saving = h.invoke('config:save', { ...h.config, schedule: { enabled: true } }); await hold.started;
  const enrolling = h.invoke('beta:enroll-incremental', { destinationId: legacyId, confirmedManualTesting: true, confirmedLimitations: true });
  await new Promise(setImmediate); assert.equal(h.calls.some(c => c.script === 'manage-beta-test-tasks.ps1'), false);
  hold.release(); await saving; await enrolling;
  assert.equal(h.readConfig().destination.backupFormatVersion, 2);
});
test('legacy selection does not grant restore authority to forged v2 or missing snapshot IDs', async t => {
  const h = harness(t, false);
  for (const payload of [{ destinationId: id, backupFormatVersion: 2, snapshotName: '2026-10-19_01-00-00', jobId: 'one' }, { snapshotName: '../Latest', jobId: 'one' }]) {
    for (const action of ['restore:plan', 'restore:run']) await assert.rejects(async () => h.invoke(action, payload), /catalog|snapshot|destination|unsupported/i);
  }
  assert.equal(h.calls.filter(c => c.script === 'restore-snapshot.ps1').length, 0);
});
test('main worker boundary refuses manual integrity verification on v2', async t => {
  const h = harness(t); await assert.rejects(async () => vm.runInContext("runPowerShell('verify-backup-integrity.ps1')", h.context), /incremental|unsupported/i);
  assert.equal(h.calls.length, 0);
});
test('state response stays aligned when external selection changes during catalog inspection', async t => {
  const h = harness(t), hold = h.hold('inspect-backup-catalog.ps1');
  const pending = h.invoke('state:get'); await hold.started;
  fs.writeFileSync(h.configPath, JSON.stringify({ ...h.readConfig(), destination: h.legacy })); hold.release();
  const state = await pending; assert.equal(state.config.destination.id, legacyId); assert.equal(state.catalog.destinationId, legacyId);
});
test('actual delayed worker completion cannot overwrite externally changed selection', async t => {
  const h = harness(t), hold = h.hold('backup-engine.ps1');
  const pending = h.invoke('backup:run'); await hold.started;
  fs.writeFileSync(h.configPath, JSON.stringify({ ...h.readConfig(), destination: h.legacy }));
  const selected = await h.invoke('backups:refresh'); assert.equal(selected.catalog.destinationId, legacyId);
  hold.release(); const result = await pending;
  assert.equal(result.config.destination.id, legacyId); assert.equal(result.catalog.destinationId, legacyId); assert.equal(result.lastAttempt, null); assert.equal(result.activeOperation, null);
  assert.equal(h.events.some(e => e.channel === 'backup:progress' && e.payload.phase === 'complete'), false);
});
test('explicit legacy selection retains validated snapshot catalog and restore path', async t => {
  const h = harness(t, false), snapshotName = '2026-10-19_01-00-00';
  const snapshot = path.join(h.root, 'backups', 'snapshots', snapshotName); fs.mkdirSync(snapshot, { recursive: true });
  const index = path.join(snapshot, '.datasafe-integrity.jsonl'); fs.writeFileSync(index, '');
  const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const manifest = path.join(snapshot, '.datasafe-manifest.json');
  fs.writeFileSync(manifest, JSON.stringify({ formatVersion: 1, snapshotName, jobs: [{ id: 'one', name: 'Test source', type: 'folder' }], integrity: { indexFile: '.datasafe-integrity.jsonl', indexSha256: hash(index) } }));
  fs.writeFileSync(path.join(snapshot, '.datasafe-complete.json'), JSON.stringify({ formatVersion: 1, snapshotName, completedAt: '2026-10-19T01:00:00.000Z', manifestFile: '.datasafe-manifest.json', manifestSha256: hash(manifest), integrityIndexFile: '.datasafe-integrity.jsonl', integrityIndexSha256: hash(index) }));
  const state = await h.invoke('state:get'); assert.equal(state.catalog.schema, 'datasafe.app-catalog'); assert.equal(state.catalog.backupFormatVersion, 1); assert.equal(state.catalog.legacySnapshots[0].name, snapshotName);
  await h.invoke('restore:plan', { snapshotName, jobId: 'one' }); assert.equal(h.calls.filter(c => c.script === 'restore-snapshot.ps1').length, 1);
});
test('v2 tray does not treat raw worker or historical legacy status as confirmed success', async t => {
  const h = harness(t);
  const unverified = vm.runInContext("summarizeProtectionForTray(readJson(dataPaths().configPath), { lastBackupAt: new Date().toISOString(), lastBackupResult: 'success', lastBackupMessage: 'Unverified worker completion' })", h.context);
  assert.notEqual(unverified.level, 'good'); assert.match(unverified.message, /manual|catalog|incremental/i);
  const warning = vm.runInContext(`summarizeProtectionForTray(readJson(dataPaths().configPath), { appBackups: { '${id}': { lastAttempt: { outcome: 'committed-with-warning', message: 'Cleanup needs attention' }, lastCommitted: { transactionId: 'old', committedAt: null } } } })`, h.context);
  assert.equal(warning.level, 'warning'); assert.match(warning.message, /Cleanup/);
});
