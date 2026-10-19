const test = require('node:test');
const assert = require('node:assert/strict');
const { createBackupService } = require('../backup-service');

const copy = x => structuredClone(x);
const legacy = { id: '11111111-1111-4111-8111-111111111111', driveLetter: 'F', baseFolder: 'Old Backups' };
const beta = { ...legacy, id: '22222222-2222-4222-8222-222222222222', backupFormatVersion: 2,
  volumeUniqueId: 'volume-A', manualBetaConfirmedAt: '2026-10-19T00:00:00.000Z' };
const timestamp = '2026-10-19T01:00:00.000Z';
function fixture(v2 = false) {
  let config = { destination: copy(v2 ? beta : legacy), knownDestinations: [copy(legacy), ...(v2 ? [copy(beta)] : [])],
    jobs: [{ id: 'one', enabled: true, type: 'folder', path: 'C:\\fixture-source' }],
    schedule: { enabled: !v2, frequency: 'weekly', time: '18:30' }, reminders: { enabled: !v2, staleDays: 7 }, cloudCheck: { enabled: !v2, detail: 'saved' } };
  let status = {}; let catalog = null; let n = 2;
  const events = [], tasks = [], opens = [], workerCalls = [], refreshes = [];
  const repo = () => ({ computerId: 'pc', ownedByCurrentComputer: true, state: 'committed', currentManifestId: 'sha256:old', currentTransactionId: 'old', committedAt: '2026-10-18T01:00:00.000Z', capabilities: { browse: true, manualBackup: true }, locations: [{ locationId: 'latest', kind: 'latest', partial: false }] });
  const makeCatalog = c => ({ schema: 'datasafe.app-catalog', formatVersion: 1, destinationId: c.destination.id, backupFormatVersion: c.destination.backupFormatVersion || 1,
    connection: 'connected', volumeMatch: true, state: 'committed', lastKnown: false, checkedAtUtc: timestamp, currentComputerId: 'pc', latestCommittedAt: null,
    repositories: c.destination.backupFormatVersion === 2 ? [repo()] : [], legacySnapshots: [], warnings: [] });
  const ports = {
    readConfig: async () => copy(config), writeConfig: async c => { config = copy(c); }, readStatus: async () => copy(status), writeStatus: async s => { status = copy(s); },
    now: () => new Date(timestamp), newId: () => `${++n}3333333-3333-4333-8333-333333333333`, publish: e => events.push(copy(e)),
    taskControl: async (action, c, confirmed) => { tasks.push({ action, c, confirmed }); return { confirmedPaused: action === 'Pause' && confirmed, tasks: [], warnings: [] }; },
    getVolumeIdentity: async () => ({ connected: true, volumeUniqueId: 'volume-A' }),
    openPath: async p => { opens.push(p); return ''; },
    catalogReader: { refresh: async (c, options) => { refreshes.push({ c, options }); catalog = makeCatalog(c); return copy(catalog); }, peek: id => catalog?.destinationId === id ? copy(catalog) : null,
      resolveLocation: async (c, ids) => ({ destinationId: c.destination.id, ...ids, path: 'F:\\DataSafe Backups\\PC\\Latest' }) },
    runWorker: async args => { workerCalls.push(args); return { ok: true, code: 0, message: 'done', data: { schema: 'datasafe.app-backup-result', formatVersion: 1, operationId: args.operationId,
      destinationId: args.config.destination.id, backupFormatVersion: 2, outcome: 'committed', transactionId: 'old', committedAt: '2026-10-18T01:00:00.000Z', recoveryAction: 'none', scanCounts: { files: 1 }, copyBytes: 0, historyCounts: {}, warnings: [], message: 'done' } }; }
  };
  return { ports, service: () => createBackupService(ports), get config() { return config; }, set config(c) { config = c; }, get status() { return status; }, events, tasks, opens, workerCalls, refreshes, makeCatalog };
}
const enroll = service => service.enrollIncrementalTest({ destinationId: legacy.id, confirmedManualTesting: true, confirmedLimitations: true });

test('enrollment preserves legacy records, source choices and full previous automation', async () => {
  const f = fixture(), before = copy(f.config), s = f.service(); await enroll(s);
  assert.notEqual(f.config.destination.id, legacy.id); assert.equal(f.config.destination.backupFormatVersion, 2);
  assert.deepEqual(f.config.jobs, before.jobs); assert.deepEqual(f.config.knownDestinations.find(d => d.id === legacy.id), legacy);
  assert.deepEqual(f.config.betaTest.previousAutomation, { schedule: before.schedule, reminders: before.reminders, cloudChecks: before.cloudCheck });
  assert.equal(f.config.betaTest.previousDestinationId, legacy.id); assert.equal(f.config.schedule.enabled, false); assert.equal(f.config.cloudCheck.enabled, false);
  assert.equal(f.config.destination.volumeUniqueId, 'volume-A'); assert.equal(f.config.destination.manualBetaConfirmedAt, timestamp);
  assert.equal(f.refreshes.at(-1).c.destination.id, f.config.destination.id);
});
test('same volume cannot acquire duplicate v2 target regardless of base folder', async () => {
  const f = fixture(); f.config.knownDestinations.push({ ...beta, baseFolder: 'different' });
  await assert.rejects(enroll(f.service()), /already|duplicate/i); assert.equal(f.tasks.length, 0); assert.equal(f.config.destination.id, legacy.id);
});
test('unconfirmed, failed pause and swapped volume retain legacy selection', async () => {
  const f = fixture(), s = f.service(); await assert.rejects(s.enrollIncrementalTest({ destinationId: legacy.id }), /confirm/i);
  assert.equal(f.tasks.filter(t => t.action === 'Pause').length, 0);
  f.ports.taskControl = async () => ({ confirmedPaused: false, tasks: [], warnings: ['One task is still running'] });
  await assert.rejects(enroll(s), /pause|running/i); assert.equal(f.config.destination.id, legacy.id);
  f.ports.taskControl = async () => { f.ports.getVolumeIdentity = async () => ({ connected: true, volumeUniqueId: 'volume-B' }); return { confirmedPaused: true }; };
  await assert.rejects(enroll(s), /volume.*paused/i); assert.equal(f.config.destination.id, legacy.id);
});
test('config revision race and incompatible Public sources stop enrollment', async () => {
  const f = fixture(); f.ports.taskControl = async () => { f.config.jobs.push({ id: 'changed' }); return { confirmedPaused: true }; };
  await assert.rejects(enroll(f.service()), /changed/i); assert.equal(f.config.destination.id, legacy.id);
  const g = fixture(); g.config.jobs[0].includePublicFolder = 'Documents';
  await assert.rejects(enroll(g.service()), /Public/i); assert.equal(g.tasks.length, 0);
});
test('renderer cannot forge enrollment, erase records, change binding or inherit internal flag', async () => {
  const f = fixture(), s = f.service(); await s.saveConfig({ ...f.config, destination: beta, knownDestinations: [beta], incrementalFormatVersion: 2, betaTest: { forged: true } });
  assert.equal(f.config.destination.backupFormatVersion, 1); assert.equal(f.config.destination.volumeUniqueId, undefined); assert.equal(f.config.betaTest, undefined); assert.equal(f.config.incrementalFormatVersion, undefined);
  assert.ok(f.config.knownDestinations.some(d => d.id === legacy.id));
  const g = fixture(true); await g.service().saveConfig({ ...g.config, destination: { ...beta, volumeUniqueId: 'forged', backupFormatVersion: 1 }, knownDestinations: [], schedule: { enabled: true }, cloudCheck: { enabled: true } });
  assert.equal(g.config.destination.backupFormatVersion, 2); assert.equal(g.config.destination.volumeUniqueId, 'volume-A'); assert.equal(g.config.schedule.enabled, false); assert.equal(g.config.cloudCheck.enabled, false); assert.equal(g.config.knownDestinations.length, 2);
});
test('switching back never resumes automation, even when candidate carries old choices', async () => {
  const f = fixture(), old = copy(f.config), s = f.service(); await enroll(s); await s.saveConfig(old);
  assert.equal(f.config.destination.id, legacy.id); assert.equal(f.config.schedule.enabled, false); assert.equal(f.tasks.filter(t => t.action === 'Pause').length, 1);
  assert.equal(f.config.betaTest.previousAutomation.cloudChecks.detail, 'saved');
});
test('busy exit zero and failed attempt preserve authoritative previous commit', async () => {
  for (const outcome of ['busy', 'failed', 'blocked']) {
    const f = fixture(true), worker = f.ports.runWorker; f.ports.runWorker = async a => { const r = await worker(a); r.data.outcome = outcome; return r; };
    const s = f.service(), before = await s.getState({ refresh: true }), after = await s.runBackup();
    assert.equal(after.lastAttempt.outcome, outcome); assert.equal(after.lastCommitted.committedAt, before.lastCommitted.committedAt);
    assert.equal(f.events.some(e => e.phase === 'complete'), false);
  }
});
test('worker correlation mismatches never import success or its fields', async () => {
  for (const field of ['operationId', 'destinationId', 'backupFormatVersion']) {
    const f = fixture(true), worker = f.ports.runWorker; f.ports.runWorker = async a => { const r = await worker(a); r.data[field] = 'forged'; r.data.message = 'foreign success'; return r; };
    const after = await f.service().runBackup(); assert.equal(after.lastAttempt.outcome, 'failed'); assert.notEqual(after.lastAttempt.message, 'foreign success');
  }
});
test('commit confirmation uses owned transaction and manifest, not aggregate timestamp', async () => {
  for (const change of ['transaction', 'manifest', 'time']) {
    const f = fixture(true), worker = f.ports.runWorker; f.ports.runWorker = async a => { const r = await worker(a); if (change === 'time') r.data.committedAt = timestamp; else r.data.transactionId = 'new'; return r; };
    const refresh = f.ports.catalogReader.refresh; f.ports.catalogReader.refresh = async (...a) => { const c = await refresh(...a); c.latestCommittedAt = timestamp; if (change === 'manifest') { c.repositories[0].currentTransactionId = 'new'; c.repositories[0].currentManifestId = null; } return c; };
    assert.equal((await f.service().runBackup()).lastAttempt.outcome, 'failed');
  }
});
test('warning and rollback preserve fields and do not manufacture new snapshot/time', async () => {
  const f = fixture(true), worker = f.ports.runWorker; f.ports.runWorker = async a => { const r = await worker(a); r.data.outcome = 'committed-with-warning'; r.data.recoveryAction = 'rolledBack'; r.data.warnings = ['cleanup']; return r; };
  const s = f.service(), before = await s.getState({ refresh: true }), after = await s.runBackup();
  assert.deepEqual(after.lastCommitted, before.lastCommitted); assert.equal(after.lastAttempt.outcome, 'committed-with-warning'); assert.equal(after.lastAttempt.recoveryAction, 'rolledBack'); assert.deepEqual(after.lastAttempt.scanCounts, { files: 1 });
  assert.equal(f.events.at(-1).phase, 'finished-with-issue');
});
test('stage 100 and worker complete wait for authoritative completion; external destination change drops late result', async () => {
  const f = fixture(true); let finish, started; const start = new Promise(r => { started = r; }); const worker = f.ports.runWorker;
  f.ports.runWorker = async a => { a.onProgress({ operationId: a.operationId, destinationId: beta.id, backupFormatVersion: 2, phase: 'copy', percent: 100 }); a.onProgress({ operationId: a.operationId, destinationId: beta.id, backupFormatVersion: 2, phase: 'complete', percent: 100 }); started(); await new Promise(r => { finish = r; }); return worker(a); };
  const s = f.service(), running = s.runBackup(); await start;
  assert.equal(f.events.some(e => e.phase === 'complete'), false); assert.ok((await s.getState()).activeOperation);
  f.config = { ...f.config, destination: copy(legacy) }; const changed = await s.getState({ refresh: true }); assert.equal(changed.catalog.destinationId, legacy.id);
  finish(); const after = await running; assert.equal(after.catalog.destinationId, legacy.id); assert.equal(after.lastAttempt, null); assert.equal(after.activeOperation, null);
});
test('superseded null refresh never clears the selected catalog and timer reads do not refresh', async () => {
  const f = fixture(true), s = f.service(); const before = await s.getState({ refresh: true }); const count = f.refreshes.length;
  await s.getState(); assert.equal(f.refreshes.length, count); f.ports.catalogReader.refresh = async () => null;
  assert.deepEqual((await s.getState({ refresh: true })).catalog, before.catalog);
});
test('open is capability checked, freshly resolved, volume checked and never exposes private paths', async () => {
  const f = fixture(true), s = f.service(); const request = { destinationId: beta.id, computerId: 'pc', locationId: 'latest' };
  const result = await s.openLocation(request); assert.deepEqual(result, { opened: true, message: 'Backup location opened.' }); assert.equal(f.opens.length, 1);
  for (const reason of ['traversal', 'reparse', 'stale']) {
    f.ports.catalogReader.resolveLocation = async () => { throw new Error(reason); }; assert.equal((await s.openLocation(request)).opened, false);
  }
  f.ports.getVolumeIdentity = async () => ({ connected: true, volumeUniqueId: 'other' }); assert.equal((await s.openLocation(request)).opened, false); assert.equal(f.opens.length, 1);
  assert.equal((await s.openLocation({ ...request, path: 'C:\\anything' })).opened, false);
});
test('single owned recovery is runnable but invalid and foreign recovery are blocked', async () => {
  for (const state of ['recovery-required', 'invalid', 'foreign']) {
    const f = fixture(true), refresh = f.ports.catalogReader.refresh; f.ports.catalogReader.refresh = async (...a) => { const c = await refresh(...a); c.state = state === 'foreign' ? 'recovery-required' : state; c.repositories[0].state = c.state; if (state === 'foreign') c.repositories[0].ownedByCurrentComputer = false; return c; };
    await f.service().runBackup(); assert.equal(f.workerCalls.length, state === 'recovery-required' ? 1 : 0);
  }
});
test('queued save does not modify frozen worker config before completion', async () => {
  const f = fixture(true); let finish, started; const start = new Promise(r => { started = r; }); const worker = f.ports.runWorker;
  f.ports.runWorker = async a => { started(); await new Promise(r => { finish = r; }); return worker(a); };
  const s = f.service(), run = s.runBackup(); await start; const save = s.saveConfig({ ...f.config, destination: legacy });
  assert.equal(f.config.destination.id, beta.id); finish(); await run; await save; assert.equal(f.config.destination.id, legacy.id);
});
test('unchanged transaction cannot authorize a substituted manifest', async () => {
  const f = fixture(true), refresh = f.ports.catalogReader.refresh; let reads = 0;
  f.ports.catalogReader.refresh = async (...args) => { const c = await refresh(...args); if (++reads > 1) c.repositories[0].currentManifestId = 'sha256:substituted'; return c; };
  assert.equal((await f.service().runBackup()).lastAttempt.outcome, 'failed');
});
test('status persistence error releases operation state and serialization queue', async () => {
  const f = fixture(true), s = f.service(); f.ports.writeStatus = async () => { throw new Error('status write denied'); };
  await assert.rejects(s.runBackup(), /write denied/); assert.equal((await s.getState()).activeOperation, null);
  await s.saveConfig({ ...f.config, destination: legacy }); assert.equal(f.config.destination.id, legacy.id);
});
test('missing local identity is allowed only for explicitly enrolled safe new repository', async () => {
  const f = fixture(true); f.ports.catalogReader.refresh = async c => ({ ...f.makeCatalog(c), state: 'identity-missing', currentComputerId: null, repositories: [] });
  await f.service().runBackup(); assert.equal(f.workerCalls.length, 1);
});
test('new authoritative transaction commits with unknown time and persists independently of legacy status', async () => {
  const f = fixture(true), worker = f.ports.runWorker, refresh = f.ports.catalogReader.refresh; let completed = false;
  f.ports.runWorker = async args => { const result = await worker(args); completed = true; result.data.transactionId = 'new'; result.data.committedAt = null; return result; };
  f.ports.catalogReader.refresh = async (...args) => { const c = await refresh(...args); if (completed) { c.repositories[0].currentTransactionId = 'new'; c.repositories[0].currentManifestId = 'sha256:new'; c.repositories[0].committedAt = null; } return c; };
  const s = f.service(), result = await s.runBackup();
  assert.equal(result.lastAttempt.outcome, 'committed'); assert.deepEqual(result.lastCommitted, { destinationId: beta.id, transactionId: 'new', committedAt: null });
  assert.equal(f.events.at(-1).phase, 'complete'); assert.equal(f.status.lastBackupAt, undefined);
  assert.deepEqual((await f.service().getState()).lastCommitted, result.lastCommitted);
});
test('selection change during status persistence suppresses old completion event', async () => {
  const f = fixture(true), write = f.ports.writeStatus;
  f.ports.writeStatus = async status => { await write(status); f.config = { ...f.config, destination: legacy }; };
  const result = await f.service().runBackup(); assert.equal(result.catalog.destinationId, legacy.id);
  assert.equal(f.events.some(e => e.phase === 'complete'), false);
});
test('matching retained-cleanup warning is saved-with-attention, never browse authority', async () => {
  for (const variant of ['matching', 'wrong-transaction', 'invalid']) {
    const f = fixture(true), worker = f.ports.runWorker, refresh = f.ports.catalogReader.refresh; let completed = false, cached = null;
    f.ports.runWorker = async args => { const r = await worker(args); completed = true; r.data.outcome = 'committed-with-warning'; r.data.warnings = [{ Code: 'StagingCleanupFailed', Message: 'Cleanup retained' }]; return r; };
    f.ports.catalogReader.refresh = async (...args) => {
      const c = await refresh(...args);
      if (completed) { c.state = variant === 'invalid' ? 'invalid' : 'recovery-required'; c.repositories[0].state = c.state; c.repositories[0].capabilities.browse = false; c.repositories[0].locations = []; if (variant === 'wrong-transaction') c.repositories[0].currentTransactionId = 'different'; }
      cached = copy(c); return c;
    };
    f.ports.catalogReader.peek = () => copy(cached);
    const result = await f.service().runBackup();
    assert.equal(result.lastAttempt.outcome, variant === 'matching' ? 'committed-with-warning' : 'failed');
    assert.equal(result.catalog.repositories[0].capabilities.browse, false); assert.equal(f.events.at(-1).phase, 'finished-with-issue');
  }
});
