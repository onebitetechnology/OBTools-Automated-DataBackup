const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { createBackupService } = require('../backup-service');
const { createBackupCatalogReader } = require('../backup-catalog');
const { inspectSnapshotsAtBaseRoot } = require('../backup-safety');
const fixtureKeys = ['CONFIG', 'STATUS', 'BIN', 'ROOT'].map(key => `DATASAFE_APP_FIXTURE_${key}`);
const supplied = fixtureKeys.filter(key => process.env[key]);

function assertNoFixturePath(value, fixtureRoot) {
  if (typeof value === 'string') assert.equal(value.includes(fixtureRoot), false, 'Public result leaked fixture path');
  else if (value && typeof value === 'object') {
    for (const field of Object.values(value)) assertNoFixturePath(field, fixtureRoot);
  }
}

// Break caught: JSON escaping hides a real Windows path from the browse oracle.
test('public result redaction oracle rejects intentionally leaking Windows string fields', () => {
  const fixtureRoot = 'C:\\Users\\fixture\\AppData\\Local\\Temp\\datasafe-app-test';
  const leaking = JSON.parse(JSON.stringify({ opened: true, details: [{ path: `${fixtureRoot}\\drive\\Latest Backup` }] }));
  assert.throws(() => assertNoFixturePath(leaking, fixtureRoot), /Public result leaked fixture path/);
  assert.doesNotThrow(() => assertNoFixturePath({ opened: true, message: 'Backup folder opened.' }, fixtureRoot));
});

test('actual copied worker connects to the app service', { timeout: 600000, skip: supplied.length === 0 ? 'Run tests/windows/Run-AppIntegrationTests.ps1 for actual-worker qualification.' : false }, async t => {
  assert.equal(supplied.length, 4, 'All four fixture paths must be supplied by the PowerShell wrapper.');
  const h = createActualWorkerHarness(t);
  let authority, originalTransaction;
  await t.test('InitialCreatesBrowseableLatest', async () => {
    const state = await h.run();
    authority = await h.confirm(state);
    originalTransaction = authority.pointer.transactionId;
    assert.equal(state.lastAttempt.copyBytes, 40);
    assert.equal(state.lastAttempt.scanCounts.files, 4);
    assert.deepEqual(h.latestBytes(), h.sourceBytes());
    assert.equal(state.catalog.repositories[0].capabilities.browse, true);
    assert.equal(fs.existsSync(path.join(h.drive, 'Legacy', 'snapshots')), false);
  });
  await t.test('UnchangedCopiesZeroContent', async () => {
    const state = await h.run();
    authority = await h.confirm(state);
    const unchangedResult = state.lastAttempt;
    assert.equal(unchangedResult.copyBytes, 0);
    assert.deepEqual(h.latestBytes(), h.sourceBytes());
    assert.equal(Object.keys(h.bytes(authority.repository.HistoryRoot)).length, 0);
  });
  await t.test('ChangedPreservesPreviousBytes', async () => {
    const originalBytes = fs.readFileSync(path.join(h.source, 'a.txt'));
    fs.writeFileSync(path.join(h.source, 'a.txt'), 'changed-a-longer');
    const state = await h.run(); authority = await h.confirm(state);
    assert.equal(state.lastAttempt.copyBytes, 16);
    assert.equal(state.lastAttempt.historyCounts.previousVersions, 1);
    const previous = state.catalog.repositories[0].locations.find(l => l.kind === 'previous');
    assert.equal(previous.partial, true);
    const resolved = await h.reader.resolveLocation(h.config(), { computerId: state.catalog.currentComputerId, locationId: previous.locationId });
    const previousVersionBytes = fs.readFileSync(path.join(resolved.path, 'Docs', 'a.txt'));
    assert.deepEqual(previousVersionBytes, originalBytes);
    assert.deepEqual(h.latestBytes(), h.sourceBytes());
  });
  await t.test('DeletedPreservesDeletedBytes', async () => {
    const deletedSourceBytes = fs.readFileSync(path.join(h.source, 'b.txt'));
    fs.unlinkSync(path.join(h.source, 'b.txt'));
    const state = await h.run(); authority = await h.confirm(state);
    assert.equal(state.lastAttempt.historyCounts.deletedFiles, 1);
    const deleted = state.catalog.repositories[0].locations.find(l => l.kind === 'deleted');
    assert.equal(deleted.partial, true);
    const resolved = await h.reader.resolveLocation(h.config(), { computerId: state.catalog.currentComputerId, locationId: deleted.locationId });
    const deletedVersionBytes = fs.readFileSync(path.join(resolved.path, 'Docs', 'b.txt'));
    assert.deepEqual(deletedVersionBytes, deletedSourceBytes);
    assert.deepEqual(h.latestBytes(), h.sourceBytes());
  });
  await t.test('ReadOnlyBrowseDoesNotChangeTree', async () => {
    const before = h.inventory(h.root);
    const state = await h.service.getState({ refresh: true });
    const repo = state.catalog.repositories[0];
    for (const location of repo.locations) {
      const result = await h.service.openLocation({ destinationId: h.config().destination.id, computerId: repo.computerId, locationId: location.locationId });
      assert.equal(result.opened, true);
      assertNoFixturePath(result, h.root);
    }
    assert.deepEqual(h.inventory(h.root), before);
    assertNoFixturePath(state.catalog, h.root);
    await h.authority();
  });
  await t.test('UnavailableDrivePreservesCommit', async () => {
    const prior = (await h.service.getState()).lastCommitted;
    const pointerBefore = fs.readFileSync(h.pointerPath());
    fs.renameSync(h.drive, h.owned('drive-offline'));
    try {
      const count = h.workers.length, events = h.events.length;
      const state = await h.run();
      assert.equal(state.catalog.state, 'disconnected'); assert.equal(state.catalog.lastKnown, true);
      assert.equal(state.lastAttempt.outcome, 'blocked'); assert.deepEqual(state.lastCommitted, prior);
      assert.equal(h.workers.length, count);
      assert.equal(h.events.slice(events).some(e => e.phase === 'complete'), false);
    } finally { fs.renameSync(h.owned('drive-offline'), h.drive); }
    assert.deepEqual(fs.readFileSync(h.pointerPath()), pointerBefore);
    assert.deepEqual(h.latestBytes(), h.sourceBytes()); await h.authority();
  });
  await t.test('UnavailableSourceAndDeletionReviewRefuseNewCommit', async () => {
    const pointerBefore = fs.readFileSync(h.pointerPath()), latestBefore = h.latestBytes();
    const config = h.config(); const prior = (await h.service.getState({ refresh: true })).lastCommitted;
    h.writeConfig({ ...config, jobs: [{ ...config.jobs[0], path: h.owned('missing-source') }] });
    const missing = await h.run();
    assert.equal(missing.lastAttempt.outcome, 'failed'); assert.equal(missing.lastAttempt.scanCounts.sourceErrors, 1);
    assert.deepEqual(missing.lastCommitted, prior); assert.deepEqual(fs.readFileSync(h.pointerPath()), pointerBefore);
    h.writeConfig(config);
    const a = fs.readFileSync(path.join(h.source, 'a.txt')), c = fs.readFileSync(path.join(h.source, 'c.txt'));
    fs.unlinkSync(path.join(h.source, 'a.txt')); fs.unlinkSync(path.join(h.source, 'c.txt'));
    try {
      const refused = await h.run();
      assert.equal(refused.lastAttempt.outcome, 'failed'); assert.match(refused.lastAttempt.message, /deletion review/i);
      assert.deepEqual(refused.lastCommitted, prior); assert.deepEqual(fs.readFileSync(h.pointerPath()), pointerBefore);
      assert.deepEqual(h.latestBytes(), latestBefore); await h.authority();
    } finally { fs.writeFileSync(path.join(h.source, 'a.txt'), a); fs.writeFileSync(path.join(h.source, 'c.txt'), c); }
  });
  await t.test('RecoveryWarningRemainsSavedWithAttention', async () => {
    const fault = await h.interrupt('warning');
    try {
      const ready = h.json(h.owned('fault-ready.json'));
      const pending = await h.service.getState({ refresh: true });
      assert.equal(pending.catalog.state, 'recovery-required');
      const state = await h.run();
      const strict = await h.confirm(state, 'committed-with-warning');
      assert.equal(state.lastAttempt.recoveryAction, 'committed');
      assert.equal(state.lastCommitted.transactionId, ready.transactionId);
      assert.equal(strict.pointer.transactionId, ready.transactionId);
      assert.equal(state.catalog.repositories[0].state, 'recovery-required');
      assert.equal(state.catalog.repositories[0].capabilities.browse, false);
      assert.ok(state.lastAttempt.warnings.some(w => w.Code === 'JournalFinalizationFailed'));
      const open = await h.service.openLocation({ destinationId: h.config().destination.id, computerId: state.catalog.currentComputerId, locationId: 'latest' });
      assert.equal(open.opened, false);
      assert.deepEqual(h.latestBytes(), h.sourceBytes());
    } finally { await fault.release(); }
    await h.confirm(await h.run());
  });
  await t.test('InterruptedRollbackIsNotNewBackup', async () => {
    const prior = (await h.service.getState()).lastCommitted, pointerBefore = fs.readFileSync(h.pointerPath());
    const latestBefore = h.latestBytes(), config = h.config();
    const fault = await h.interrupt('rollback'); await fault.release();
    const rolledBackId = h.json(h.owned('fault-ready.json')).transactionId;
    h.writeConfig({ ...config, jobs: [{ ...config.jobs[0], path: h.owned('missing-source') }] });
    try {
      const state = await h.run();
      assert.equal(state.lastAttempt.outcome, 'failed'); assert.equal(state.lastAttempt.recoveryAction, 'rolledBack');
      assert.deepEqual(state.lastCommitted, prior); assert.deepEqual(fs.readFileSync(h.pointerPath()), pointerBefore);
      assert.deepEqual(h.latestBytes(), latestBefore); await h.authority();
      assert.notEqual(state.lastAttempt.transactionId, originalTransaction);
      assert.equal(state.catalog.state, 'committed');
      assert.equal(state.catalog.repositories[0].capabilities.browse, true);
      assert.equal(state.catalog.repositories[0].capabilities.manualBackup, true);
      assert.equal(state.catalog.repositories[0].locations.some(location => location.transactionId === rolledBackId), false);
    } finally { h.writeConfig(config); }
    const next = await h.run(); await h.confirm(next);
    assert.deepEqual(h.latestBytes(), h.sourceBytes());
    assert.equal(next.catalog.repositories[0].locations.some(location => location.transactionId === rolledBackId), false);
  });
  await t.test('SameLetterWrongVolumeCannotWrite', async () => {
    const before = h.inventory(h.drive), pointerBefore = fs.readFileSync(h.pointerPath());
    const prior = (await h.service.getState()).lastCommitted;
    // Change between service validation and actual worker preflight. Only the
    // copied fixture's resolver reads this file; production gets no bypass.
    h.beforeWorker = () => fs.writeFileSync(h.owned('volume.txt'), 'different-USB-same-letter');
    try {
      const state = await h.run();
      assert.equal(state.lastAttempt.outcome, 'blocked');
      assert.deepEqual(state.lastCommitted, prior); assert.deepEqual(h.inventory(h.drive), before);
      assert.deepEqual(fs.readFileSync(h.pointerPath()), pointerBefore);
      assert.equal(h.lastWorker.data.outcome, 'blocked');
    } finally { h.beforeWorker = null; fs.writeFileSync(h.owned('volume.txt'), 'fixture-volume'); }
    await h.authority();
  });
  await t.test('StaleOperationAndCatalogCannotImportForeignSuccess', async () => {
    await h.confirm(await h.run());
    const original = h.config(), other = { ...original, destination: { ...original.destination, id: crypto.randomUUID(), volumeUniqueId: 'other-volume' } };
    const persisted = structuredClone(h.json(h.statusPath).appBackups[original.destination.id]);
    const held = h.holdWorker(); const pending = h.run(); await held.started;
    h.writeConfig(other); await h.service.getState({ refresh: true }); held.release();
    const state = await pending;
    assert.equal(state.catalog.destinationId, other.destination.id);
    assert.equal(state.lastAttempt, null); assert.equal(state.lastCommitted, null);
    assert.deepEqual(h.json(h.statusPath).appBackups[original.destination.id], persisted);
    assert.equal(h.events.some(e => e.operationId === h.lastWorker.data.operationId && e.phase === 'complete'), false);
    h.writeConfig(original);
    const gate = h.holdCatalog(); const stale = h.reader.refresh(original, { force: true }); await gate.started;
    h.writeConfig(other); const selected = await h.reader.refresh(other, { force: true }); gate.release();
    assert.equal(await stale, null); assert.equal(selected.destinationId, other.destination.id);
    assert.equal(h.reader.peek(other.destination.id).destinationId, other.destination.id);
    h.writeConfig(original); await h.service.getState({ refresh: true }); await h.authority();
  });
  await t.test('LegacyRestoreStillUsesLegacyCatalog', async () => {
    const config = h.config(), before = h.inventory(h.owned('drive/DataSafe Backups'));
    const legacy = { ...config, installId: crypto.randomUUID(), destination: { ...config.destination, id: crypto.randomUUID(), backupFormatVersion: 1 } };
    h.writeConfig(legacy);
    try {
      const worker = await h.script('backup-engine.ps1', legacy, ['-AllowNewDestination']);
      assert.equal(worker.code, 0, worker.stderr + worker.stdout);
      const state = await h.service.getState({ refresh: true });
      assert.equal(state.catalog.backupFormatVersion, 1); assert.equal(state.catalog.repositories.length, 0);
      assert.equal(state.catalog.legacySnapshots.length, 1);
      const snapshot = state.catalog.legacySnapshots[0];
      assert.deepEqual(h.bytes(path.join(h.drive, 'Legacy', 'snapshots', snapshot.name, 'Docs')), h.sourceBytes());
      const restored = h.owned('legacy-restored');
      fs.mkdirSync(restored);
      const result = await h.script('restore-snapshot.ps1', legacy, ['-SnapshotName', snapshot.name, '-JobId', 'docs', '-RestoreMode', 'alternate', '-TargetPath', restored, '-Action', 'restore']);
      assert.equal(result.code, 0, result.stderr + result.stdout);
      assert.ok(result.data.targetPath.startsWith(restored + path.sep));
      assert.deepEqual(h.bytes(result.data.targetPath), h.sourceBytes());
      assert.deepEqual(h.inventory(h.owned('drive/DataSafe Backups')), before);
      await assert.rejects(h.run(), /explicitly enrolled/);
    } finally { h.writeConfig(config); }
  });
});

function createActualWorkerHarness(t) {
  const [configPath, statusPath, bin, root] = fixtureKeys.map(key => path.resolve(process.env[key]));
  assert.equal(path.dirname(root).toLowerCase(), path.resolve(os.tmpdir()).toLowerCase());
  assert.match(path.basename(root), /^datasafe-app-[0-9a-f]{32}$/);
  function owned(relative) {
    const value = path.resolve(root, relative);
    assert.ok(value.startsWith(root + path.sep), 'Fixture path escaped the owned root.');
    return value;
  }
  for (const value of [configPath, statusPath, bin]) assert.ok(value.startsWith(root + path.sep));
  const json = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  const runtime = json(owned('runtime.json'));
  const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').toUpperCase();
  for (const item of runtime.copiedFixtureHashes) assert.equal(sha(path.join(bin, item.name)), item.sha256);
  t.diagnostic(`Actual subprocess runtime ${runtime.powerShell} (${runtime.version}); copied source ${runtime.workerSource}; hashes ${JSON.stringify(runtime.copiedFixtureHashes)}`);
  const drive = owned('drive'), source = owned('source'), events = [], workers = [], children = new Set();
  const config = () => json(configPath), writeConfig = value => fs.writeFileSync(configPath, JSON.stringify(value));
  let authorityValue, workerGate, catalogGate;
  const h = { root, drive, source, owned, json, statusPath, config, writeConfig, events, workers, beforeWorker: null };
  const quoted = value => `'${String(value).replaceAll("'", "''")}'`;
  function processRun(args, onProgress) {
    const child = spawn(runtime.powerShell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args], { windowsHide: true });
    children.add(child);
    let stdout = '', stderr = '', pending = '';
    const done = new Promise((resolve, reject) => {
      child.stdout.on('data', bytes => {
        const text = bytes.toString(); stdout += text; pending += text;
        const lines = pending.split(/\r?\n/); pending = lines.pop();
        for (const line of lines) if (line.startsWith('__OB_PROGRESS__:')) onProgress?.(JSON.parse(line.slice(16)));
      });
      child.stderr.on('data', bytes => { stderr += bytes.toString(); });
      child.on('error', reject);
      child.on('close', code => {
        children.delete(child);
        const markers = stdout.split(/\r?\n/).filter(line => line.startsWith('__OB_RESULT__:'));
        try { resolve({ code, ok: code === 0, stdout, stderr, data: markers.length === 1 ? JSON.parse(markers[0].slice(14)) : null }); } catch (error) { reject(error); }
      });
    });
    return { child, done };
  }
  async function script(name, selected, args = [], onProgress) {
    const shadow = owned(`config-${crypto.randomUUID()}.json`);
    fs.writeFileSync(shadow, JSON.stringify(selected), { flag: 'wx' });
    try { return await processRun(['-File', path.join(bin, name), '-ConfigPath', shadow, '-StatusPath', statusPath, ...args], onProgress).done; }
    finally { fs.unlinkSync(shadow); }
  }
  function helperCommand(command) {
    return `$ErrorActionPreference='Stop'; . ${quoted(path.join(bin, 'DataSafe.Transaction.ps1'))}; . ${quoted(path.join(bin, 'AppIntegrationTestHelpers.ps1'))}; ${command}`;
  }
  async function authority() {
    const result = await processRun(['-Command', helperCommand(`$a=Read-AppFixtureAuthority ${quoted(root)}; Write-Output ('__OB_RESULT__:'+ (ConvertTo-Json $a -Depth 40 -Compress))`)]).done;
    assert.equal(result.code, 0, result.stderr + result.stdout); assert.ok(result.data);
    const a = result.data;
    const pointer = json(path.join(a.repository.MetadataRoot, 'current-manifest.json'));
    assert.deepEqual(a.pointer, pointer);
    const manifestPath = path.join(a.repository.MetadataRoot, pointer.manifestPath);
    assert.equal(sha(manifestPath), pointer.sha256.toUpperCase());
    assert.deepEqual(a.manifest, json(manifestPath));
    // The qualified manifest carries no transactionId or commit clock. Its
    // identity is the independently hashed manifest named by the strict pointer.
    authorityValue = a;
    return a;
  }
  function bytes(folder) {
    const files = {};
    function visit(dir) {
      for (const name of fs.readdirSync(dir).sort()) {
        const file = path.join(dir, name), stat = fs.lstatSync(file);
        assert.equal(stat.isSymbolicLink(), false);
        if (stat.isDirectory()) visit(file); else files[path.relative(folder, file).replaceAll('\\', '/')] = fs.readFileSync(file);
      }
    }
    visit(folder); return files;
  }
  function inventory(folder) {
    const entries = {};
    function visit(dir) {
      for (const name of fs.readdirSync(dir).sort()) {
        const file = path.join(dir, name), stat = fs.lstatSync(file), relative = path.relative(folder, file);
        assert.equal(stat.isSymbolicLink(), false);
        entries[relative] = stat.isDirectory() ? 'directory' : `file:${sha(file)}`;
        if (stat.isDirectory()) visit(file);
      }
    }
    visit(folder); return entries;
  }
  function hold(which) {
    let start, release;
    const gate = { started: new Promise(resolve => { start = resolve; }), wait: new Promise(resolve => { release = resolve; }), start, release: () => release() };
    gate.start = start;
    if (which === 'worker') workerGate = gate; else catalogGate = gate;
    return gate;
  }
  const reader = createBackupCatalogReader({
    runReadOnly: async (action, selected, identifiers) => {
      const result = await script('inspect-backup-catalog.ps1', selected, ['-Action', action, ...Object.entries(identifiers).flatMap(([key, value]) => [`-${key}`, value])]);
      assert.equal(result.code, 0, result.stderr + result.stdout); assert.ok(result.data);
      if (action === 'Inspect' && catalogGate) { const gate = catalogGate; catalogGate = null; gate.start(); await gate.wait; }
      return result.data;
    },
    inspectLegacy: async selected => {
      const info = inspectSnapshotsAtBaseRoot(path.join(drive, selected.destination.baseFolder));
      return { schema: 'datasafe.app-catalog', formatVersion: 1, destinationId: selected.destination.id, backupFormatVersion: 1, connection: 'connected', volumeMatch: null, state: info.snapshots.length ? 'committed' : 'empty', lastKnown: false, currentComputerId: null, latestCommittedAt: info.snapshots[0]?.completedAt || null, repositories: [], legacySnapshots: info.snapshots.map(snapshot => ({ name: snapshot.name, completedAt: snapshot.completedAt, jobs: snapshot.manifest.jobs })), warnings: [] };
    }
  });
  const service = createBackupService({
    readConfig: async () => config(), writeConfig: async value => writeConfig(value),
    readStatus: async () => json(statusPath), writeStatus: async value => fs.writeFileSync(statusPath, JSON.stringify(value)),
    catalogReader: reader, now: () => new Date(), newId: () => crypto.randomUUID(),
    getVolumeIdentity: async selected => {
      const result = await script('inspect-backup-catalog.ps1', selected, ['-Action', 'InspectVolume']);
      assert.equal(result.code, 0, result.stderr + result.stdout); return result.data;
    },
    taskControl: async () => { throw new Error('Task APIs are mocked and forbidden in the actual-worker workflow.'); },
    openPath: async target => { assert.ok(target.startsWith(drive + path.sep)); assert.ok(fs.statSync(target).isDirectory()); return ''; },
    publish: event => events.push(structuredClone(event)),
    runWorker: async request => {
      h.beforeWorker?.();
      const result = await script('backup-engine.ps1', request.config, ['-ManualBetaRun', '-AppOperationId', request.operationId, ...(request.allowNewDestination ? ['-AllowNewDestination'] : [])], request.onProgress);
      assert.ok(result.data, result.stdout + result.stderr);
      workers.push(result); h.lastWorker = result;
      if (workerGate) { const gate = workerGate; workerGate = null; gate.start(); await gate.wait; }
      return result;
    }
  });
  async function confirm(state, outcome = 'committed') {
    assert.equal(state.lastAttempt.outcome, outcome, state.lastAttempt.message);
    const a = await authority(), repo = state.catalog.repositories.find(r => r.ownedByCurrentComputer);
    assert.equal(repo.currentTransactionId, a.pointer.transactionId);
    assert.equal(repo.currentManifestId.toUpperCase(), `sha256:${a.pointer.sha256}`.toUpperCase());
    assert.equal(repo.backupCreatedAt, a.manifest.createdUtc);
    assert.equal(repo.committedAt, null); assert.equal(state.lastAttempt.committedAt, null);
    assert.equal(state.lastCommitted.committedAt, null);
    assert.equal(state.lastCommitted.transactionId, a.pointer.transactionId);
    for (const key of ['operationId', 'destinationId', 'transactionId', 'outcome', 'scanCounts', 'copyBytes', 'historyCounts', 'warnings', 'recoveryAction']) assert.deepEqual(state.lastAttempt[key], h.lastWorker.data[key]);
    assert.ok(Number.isFinite(Date.parse(state.lastAttempt.attemptedAt)));
    assert.ok(events.some(e => e.operationId === state.lastAttempt.operationId && e.destinationId === state.lastAttempt.destinationId && e.outcome === outcome && e.phase === (outcome === 'committed' ? 'complete' : 'finished-with-issue')));
    assert.equal(events.filter(e => e.operationId === state.lastAttempt.operationId && e.phase === 'complete').length, outcome === 'committed' ? 1 : 0, 'Only catalog-confirmed ordinary success may emit exactly one complete event.');
    assert.deepEqual(json(statusPath).appBackups[config().destination.id].lastCommitted, state.lastCommitted);
    return a;
  }
  async function interrupt(mode) {
    for (const file of ['fault-ready.json', 'fault-release']) if (fs.existsSync(owned(file))) fs.unlinkSync(owned(file));
    const run = processRun(['-Command', helperCommand(`Invoke-AppFixtureInterruption ${quoted(root)} ${quoted(mode)}`)]);
    let finished = false, result;
    run.done.then(value => { finished = true; result = value; });
    const deadline = Date.now() + 30000;
    while (!fs.existsSync(owned('fault-ready.json'))) {
      assert.equal(finished, false, result?.stderr + result?.stdout); assert.ok(Date.now() < deadline, 'Fault fixture did not become ready.');
      await new Promise(resolve => setTimeout(resolve, 30));
    }
    return { release: async () => { fs.writeFileSync(owned('fault-release'), 'release'); const result = await run.done; assert.equal(result.code, 0, result.stderr + result.stdout); } };
  }
  t.after(async () => {
    fs.writeFileSync(owned('fault-release'), 'release');
    await Promise.all([...children].map(child => new Promise(resolve => { child.once('close', resolve); child.kill(); })));
    for (const item of runtime.copiedFixtureHashes) assert.equal(sha(path.join(bin, item.name)), item.sha256, 'Copied scripts changed while testing.');
  });
  Object.assign(h, { reader, service, script, authority, bytes, inventory, confirm, interrupt, holdWorker: () => hold('worker'), holdCatalog: () => hold('catalog'), run: () => service.runBackup({ allowNewDestination: true }), sourceBytes: () => bytes(source), latestBytes: () => bytes(path.join(authorityValue.repository.LatestRoot, 'Docs')), pointerPath: () => path.join(authorityValue.repository.MetadataRoot, 'current-manifest.json') });
  return h;
}
