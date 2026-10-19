const assert = require('node:assert/strict');
const test = require('node:test');
const { createBackupCatalogReader } = require('../backup-catalog');
const config = id => ({ destination: { id, backupFormatVersion: 2, volumeUniqueId: 'volume-' + id, manualBetaConfirmedAt: '2026-10-19T01:00:00Z' } });
const catalog = id => ({ schema: 'datasafe.app-catalog', formatVersion: 1, destinationId: id, backupFormatVersion: 2,
  connection: 'connected', volumeMatch: true, state: 'committed', checkedAtUtc: '2026-10-19T02:00:00Z', lastKnown: false,
  currentComputerId: 'pc', latestCommittedAt: null, latestBackupCreatedAt: '2026-10-19T01:00:00Z',
  repositories: [{ computerId: 'pc', computerName: 'PC', ownedByCurrentComputer: true, state: 'committed',
    currentManifestId: 'manifest', currentTransactionId: 'transaction', committedAt: null, backupCreatedAt: '2026-10-19T01:00:00Z',
    locations: [{ locationId: 'opaque', kind: 'latest', label: 'Latest Backup', transactionId: 'transaction', partial: false }],
    capabilities: { browse: true, manualBackup: true, legacyRestore: false, manualVerify: false, automaticRetention: false } }], legacySnapshots: [], warnings: [] });
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

test('coalesces refresh and returns cached reads without polling storage', async () => {
  const wait = deferred(); let calls = 0;
  const reader = createBackupCatalogReader({ runReadOnly: async action => { assert.equal(action, 'Inspect'); calls++; return wait.promise; } });
  const a = reader.refresh(config('a')); const b = reader.refresh(config('a'));
  wait.resolve(catalog('a')); assert.deepEqual(await a, await b); assert.equal(calls, 1);
  await reader.refresh(config('a')); assert.equal(calls, 1); assert.equal(reader.peek('a').state, 'committed');
});
test('drops stale destination response', async () => {
  const a = deferred(); const b = deferred();
  const reader = createBackupCatalogReader({ runReadOnly: (_, c) => c.destination.id === 'a' ? a.promise : b.promise });
  const old = reader.refresh(config('a')); const selected = reader.refresh(config('b'));
  b.resolve(catalog('b')); await selected; a.resolve(catalog('a')); assert.equal(await old, null);
  assert.equal(reader.peek('a'), null); assert.equal(reader.peek('b').destinationId, 'b');
});
test('forced refresh supersedes older response for the same destination', async () => {
  const a = deferred(); const b = deferred(); let n = 0;
  const reader = createBackupCatalogReader({ runReadOnly: () => (++n === 1 ? a.promise : b.promise) });
  const old = reader.refresh(config('a')); const fresh = reader.refresh(config('a'), { force: true });
  const next = catalog('a'); next.repositories[0].currentManifestId = 'new'; b.resolve(next); await fresh;
  a.resolve(catalog('a')); assert.equal(await old, null); assert.equal(reader.peek('a').repositories[0].currentManifestId, 'new');
});
test('disconnected catalog is last known, disables capabilities and adds no integrity claim', async () => {
  let result = catalog('a'); const reader = createBackupCatalogReader({ runReadOnly: async () => result });
  await reader.refresh(config('a'));
  result = { ...catalog('a'), connection: 'disconnected', state: 'disconnected', volumeMatch: null, repositories: [] };
  const disconnected = await reader.refresh(config('a'), { force: true });
  assert.equal(disconnected.lastKnown, true); assert.equal(disconnected.repositories[0].currentManifestId, 'manifest');
  assert.equal(disconnected.repositories[0].capabilities.browse, false); assert.equal(disconnected.repositories[0].capabilities.manualBackup, false);
  assert.equal(disconnected.integrity, undefined); assert.equal(disconnected.latestCommittedAt, null);
});
test('foreign and ambiguous repositories cannot acquire manual backup capability', async () => {
  const value = catalog('a'); value.repositories[0].ownedByCurrentComputer = false;
  value.repositories.push({ ...value.repositories[0], ownedByCurrentComputer: true });
  const reader = createBackupCatalogReader({ runReadOnly: async () => value });
  const actual = await reader.refresh(config('a'));
  assert.ok(actual.repositories.every(r => !r.capabilities.manualBackup));
});
test('unbound internal-root catalog cannot advertise normal app capabilities', async () => {
  const value = catalog('a'); value.volumeMatch = false;
  const reader = createBackupCatalogReader({ runReadOnly: async () => value });
  const actual = await reader.refresh({ destination: { id: 'a' }, incrementalFormatVersion: 2 });
  assert.equal(actual.repositories[0].capabilities.browse, false);
  assert.equal(actual.repositories[0].capabilities.manualBackup, false);
});
test('cached reads cannot authorize location opens; resolve always uses fresh private protocol', async () => {
  const calls = []; let refuse = false;
  const reader = createBackupCatalogReader({ runReadOnly: async (action, c, ids) => {
    calls.push({ action, ids }); if (action === 'Inspect') return catalog(c.destination.id);
    if (refuse) throw new Error('changed volume'); return { destinationId: 'a', ...ids, path: 'X:\\safe' };
  } });
  await reader.refresh(config('a'));
  assert.equal((await reader.resolveLocation(config('a'), { computerId: 'pc', locationId: 'opaque' })).path, 'X:\\safe');
  refuse = true; await assert.rejects(reader.resolveLocation(config('a'), { computerId: 'pc', locationId: 'opaque' }), /changed volume/);
  assert.deepEqual(calls.slice(1).map(c => c.action), ['ResolveLocation', 'ResolveLocation']);
  await assert.rejects(reader.resolveLocation(config('a'), { computerId: 'pc', locationId: 'opaque', path: 'C:\\' }));
});
test('rejects mismatched response identity and invalid format before publishing', async () => {
  const reader = createBackupCatalogReader({ runReadOnly: async () => catalog('b') });
  await assert.rejects(reader.refresh(config('a')), /destination/i); assert.equal(reader.peek('a'), null);
  await assert.rejects(reader.refresh({ destination: { backupFormatVersion: '2' } }), /format/i);
});
test('same destination id with changed binding invalidates cached results', async () => {
  let calls = 0; const reader = createBackupCatalogReader({ runReadOnly: async () => { calls++; return catalog('a'); } });
  await reader.refresh(config('a')); const changed = config('a'); changed.destination.volumeUniqueId = 'replacement';
  await reader.refresh(changed); assert.equal(calls, 2);
});
test('rejects browse requests for an old selection and discards in-flight resolves after a switch', async () => {
  const wait = deferred(); let resolutions = 0;
  const reader = createBackupCatalogReader({ runReadOnly: async (action, c, ids) => {
    if (action === 'Inspect') return catalog(c.destination.id);
    resolutions++; return wait.promise;
  } });
  await reader.refresh(config('a'));
  const pending = reader.resolveLocation(config('a'), { computerId: 'pc', locationId: 'opaque' });
  await reader.refresh(config('b'));
  wait.resolve({ destinationId: 'a', computerId: 'pc', locationId: 'opaque', path: 'X:\\safe' });
  await assert.rejects(pending, /changed/i);
  await assert.rejects(reader.resolveLocation(config('a'), { computerId: 'pc', locationId: 'opaque' }), /selected|selection/i);
  assert.equal(resolutions, 1);
});
test('legacy format routes through injected legacy inspector and retains its separate records', async () => {
  let calls = 0;
  const reader = createBackupCatalogReader({ inspectLegacy: async () => { calls++; return { ...catalog('a'), backupFormatVersion: 1, repositories: [], legacySnapshots: [{ id: 'legacy' }] }; }, runReadOnly: () => { throw new Error('wrong reader'); } });
  const value = await reader.refresh({ destination: { id: 'a' } });
  assert.equal(value.backupFormatVersion, 1); assert.equal(value.legacySnapshots[0].id, 'legacy'); assert.equal(calls, 1);
});
