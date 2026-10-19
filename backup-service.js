const { getBackupFormat, normalizeBackupDestination } = require('./backup-format');

const clone = value => value == null ? value : structuredClone(value);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const sameVolume = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
const automationKeys = ['schedule', 'reminders', 'cloudCheck'];
const protectedDestinationKeys = ['backupFormatVersion', 'volumeUniqueId', 'manualBetaConfirmedAt'];

function createBackupService(ports) {
  let queue = Promise.resolve();
  let catalog = null;
  let selectedKey = null;
  let activeOperation = null;
  const records = new Map();
  const serialize = action => {
    const pending = queue.then(action);
    queue = pending.catch(() => {});
    return pending;
  };
  const key = config => JSON.stringify({ destination: config.destination, format: getBackupFormat(config) });
  const selected = async config => key(await ports.readConfig()) === key(config);
  function ownedRepository(value) {
    const owned = (value?.repositories || []).filter(r => r.ownedByCurrentComputer && r.computerId === value.currentComputerId);
    return owned.length === 1 ? owned[0] : null;
  }
  function connected(value) { return value && value.connection === 'connected' && value.volumeMatch === true && !value.lastKnown && value.state !== 'invalid'; }
  function canRun(value) {
    if (!connected(value)) return false;
    const own = ownedRepository(value);
    if (own) return Boolean(own.capabilities?.manualBackup && ['empty', 'committed', 'recovery-required'].includes(own.state));
    // Explicit enrollment can create a new local identity/repository, never
    // adopt an existing PC. Pending/ambiguous repositories still fail closed.
    return ['empty', 'identity-missing', 'committed'].includes(value.state) &&
      (value.repositories || []).every(r => r.state === 'committed' && !r.ownedByCurrentComputer);
  }
  async function recordFor(config) {
    const id = config.destination.id;
    if (!records.has(id)) {
      const saved = (await ports.readStatus()).appBackups?.[id];
      records.set(id, { lastAttempt: clone(saved?.lastAttempt || null), lastCommitted: clone(saved?.lastCommitted || null) });
    }
    return records.get(id);
  }
  async function refreshCatalog(config, force) {
    const value = await ports.catalogReader.refresh(config, { force });
    if (value && await selected(config)) {
      catalog = value; selectedKey = key(config);
    }
    return value;
  }
  async function getState({ refresh = false } = {}) {
    const config = await ports.readConfig();
    const changed = selectedKey !== key(config);
    if (changed) { catalog = null; selectedKey = key(config); }
    if (refresh || changed) await refreshCatalog(config, true);
    else catalog = ports.catalogReader.peek(config.destination.id) || catalog;
    // A slower request must not assemble the old selection's records with a
    // new selection's catalog. Null refresh is cancellation, not empty history.
    if (!await selected(config)) return getState();
    const record = await recordFor(config);
    const own = ownedRepository(catalog);
    if (!record.lastCommitted && connected(catalog) && own?.currentTransactionId && own.currentManifestId) {
      record.lastCommitted = { destinationId: config.destination.id, transactionId: own.currentTransactionId, committedAt: own.committedAt ?? null };
    }
    return clone({ catalog, ...record, activeOperation: activeOperation?.destinationId === config.destination.id ? activeOperation : null });
  }
  function compatibleSources(config) {
    const jobs = (config.jobs || []).filter(job => job.enabled);
    if (!jobs.length) throw new Error('Select at least one enabled backup source.');
    if (jobs.some(job => (job.includePublicFolder && String(job.includePublicFolder).trim()) || job.includePublicDesktop)) {
      throw new Error('Merged Public-folder sources are unsupported in the incremental beta. Source choices have not been changed.');
    }
  }
  async function assertVolume(config) {
    const volume = await ports.getVolumeIdentity(config);
    if (!volume?.connected || !sameVolume(volume.volumeUniqueId, config.destination.volumeUniqueId)) throw new Error('Destination volume changed or is disconnected.');
    return volume;
  }
  function pauseAutomation(config) {
    for (const name of automationKeys) config[name] = { ...config[name], enabled: false };
  }
  function knownRecords(config) {
    const byId = new Map((config.knownDestinations || []).map(d => [d.id, clone(d)]));
    byId.set(config.destination.id, clone(config.destination));
    return byId;
  }
  async function enrollIncrementalTest(request = {}) {
    return serialize(async () => {
      const config = await ports.readConfig();
      if (request.destinationId !== config.destination.id) throw new Error('Selected destination changed.');
      if (request.confirmedManualTesting !== true || request.confirmedLimitations !== true) {
        const inspection = await ports.taskControl('Inspect', config, false);
        throw new Error(`Confirm manual testing and beta limitations before pausing automation. ${(inspection.warnings || []).join(' ')}`);
      }
      if (getBackupFormat(config) !== 1) throw new Error('Select a legacy destination before enrollment.');
      compatibleSources(config);
      const volume = await ports.getVolumeIdentity(config);
      if (!volume?.connected || !volume.volumeUniqueId) throw new Error('A connected Windows volume identity is required.');
      const known = knownRecords(config);
      if ([...known.values()].some(d => d.backupFormatVersion === 2 && sameVolume(d.volumeUniqueId, volume.volumeUniqueId))) {
        throw new Error('This volume already has an incremental beta destination. Select that record.');
      }
      const proposed = clone(config);
      proposed.destination = { ...config.destination, id: ports.newId(), backupFormatVersion: 2, volumeUniqueId: volume.volumeUniqueId, manualBetaConfirmedAt: ports.now().toISOString(), lastSnapshotAt: null, lastSnapshotName: null };
      normalizeBackupDestination(proposed.destination);
      const candidateCatalog = await ports.catalogReader.refresh(proposed, { force: true });
      if (!candidateCatalog || !canRun(candidateCatalog)) throw new Error('The proposed destination catalog cannot safely authorize incremental testing.');
      const pause = await ports.taskControl('Pause', config, true);
      if (pause?.confirmedPaused !== true) throw new Error(`Automation pause is incomplete; legacy remains selected. ${(pause?.warnings || []).join(' ')}`);
      try {
        if (!same(await ports.readConfig(), config)) throw new Error('Configuration changed while automation was paused; enrollment was not saved.');
        await assertVolume(proposed);
        // Recheck after pausing, not just before the potentially long task query.
        const finalCatalog = await ports.catalogReader.refresh(proposed, { force: true });
        if (!finalCatalog || !canRun(finalCatalog)) throw new Error('Destination catalog changed after pausing; enrollment was not saved.');
        if (!same(await ports.readConfig(), config)) throw new Error('Configuration changed; enrollment was not saved.');
        await assertVolume(proposed);
        proposed.betaTest = { previousDestinationId: config.destination.id, previousAutomation: { schedule: clone(config.schedule), reminders: clone(config.reminders), cloudChecks: clone(config.cloudCheck) }, pausedAtUtc: ports.now().toISOString() };
        pauseAutomation(proposed);
        known.set(proposed.destination.id, proposed.destination); proposed.knownDestinations = [...known.values()];
        await ports.writeConfig(proposed);
        return await getState({ refresh: true });
      } catch (error) {
        throw new Error(`${error.message} Enrollment could not be confirmed; automation remains paused.`);
      }
    });
  }
  async function saveConfig(candidate) {
    return serialize(async () => {
      const current = await ports.readConfig();
      if (!candidate || typeof candidate !== 'object' || !candidate.destination) throw new Error('A destination is required.');
      const known = knownRecords(current);
      const sanitize = input => {
        const previous = known.get(input.id);
        // Bound v2 records are main-owned; an ordinary settings save cannot
        // relocate/rebind/reformat them or fabricate a confirmation.
        if (previous?.backupFormatVersion === 2) return { ...previous, label: input.label ?? previous.label };
        const result = { ...input };
        for (const name of protectedDestinationKeys) delete result[name];
        if (previous) for (const name of protectedDestinationKeys) if (Object.hasOwn(previous, name)) result[name] = previous[name];
        // A new/unformatted UI destination never inherits the internal flag.
        if (!Object.hasOwn(result, 'backupFormatVersion')) result.backupFormatVersion = 1;
        return normalizeBackupDestination(result);
      };
      for (const input of candidate.knownDestinations || []) {
        if (input?.id) known.set(input.id, sanitize(input));
      }
      const destination = sanitize(candidate.destination);
      if (!destination.id) destination.id = ports.newId();
      known.set(destination.id, destination);
      const next = { ...clone(candidate), destination, knownDestinations: [...known.values()] };
      delete next.incrementalFormatVersion; delete next.betaTest;
      if (Object.hasOwn(current, 'incrementalFormatVersion')) next.incrementalFormatVersion = current.incrementalFormatVersion;
      if (current.betaTest) next.betaTest = clone(current.betaTest);
      if (getBackupFormat(next) === 2 || (getBackupFormat(current) === 2 && destination.id !== current.destination.id)) pauseAutomation(next);
      if (getBackupFormat(next) === 2) compatibleSources(next);
      await ports.writeConfig(next);
      return getState({ refresh: true });
    });
  }
  async function persistAttempt(config, result) {
    const record = await recordFor(config);
    record.lastAttempt = { ...clone(result), attemptedAt: activeOperation.startedAt };
    const status = await ports.readStatus();
    await ports.writeStatus({ ...status, appBackups: { ...status.appBackups, [config.destination.id]: clone(record) } });
  }
  async function runBackup({ allowNewDestination = false } = {}) {
    return serialize(async () => {
      const config = await ports.readConfig();
      if (getBackupFormat(config) !== 2 || config.destination.backupFormatVersion !== 2) throw new Error('Incremental service requires an explicitly enrolled destination.');
      normalizeBackupDestination(config.destination);
      const operationId = ports.newId(), destinationId = config.destination.id;
      activeOperation = { operationId, destinationId, backupFormatVersion: 2, startedAt: ports.now().toISOString(), phase: 'starting' };
      let result = { schema: 'datasafe.app-backup-result', formatVersion: 1, operationId, destinationId, backupFormatVersion: 2, outcome: 'blocked', transactionId: null, committedAt: null, recoveryAction: 'none', scanCounts: null, copyBytes: null, historyCounts: null, warnings: [], message: '' };
      let workerStarted = false, previousRepository = null;
      try {
        compatibleSources(config);
        const before = await getState({ refresh: true });
        if (!canRun(before.catalog)) throw new Error('The selected catalog does not authorize manual backup.');
        previousRepository = ownedRepository(before.catalog);
        await assertVolume(config);
        if (!same(await ports.readConfig(), config)) throw new Error('Configuration changed before backup started.');
        workerStarted = true;
        const response = await ports.runWorker({ config: clone(config), operationId, manualBetaRun: true, allowNewDestination: Boolean(allowNewDestination), onProgress: progress => {
          if (progress?.operationId !== operationId || progress.destinationId !== destinationId || progress.backupFormatVersion !== 2 || progress.phase === 'complete') return;
          // Progress itself is not commit evidence; even phase-local 100% is
          // only a stage update. Check current selection before publication.
          Promise.resolve(ports.readConfig()).then(current => {
            if (key(current) === key(config) && activeOperation?.operationId === operationId) {
              activeOperation.phase = progress.phase; ports.publish(clone(progress));
            }
          }).catch(() => {});
        } });
        if (!await selected(config)) return getState({ refresh: true });
        const data = response?.data;
        if (!data || data.schema !== result.schema || data.formatVersion !== 1 || data.operationId !== operationId || data.destinationId !== destinationId || data.backupFormatVersion !== 2 || !['committed', 'committed-with-warning', 'blocked', 'failed', 'busy'].includes(data.outcome)) {
          throw new Error('Worker result is missing or does not match this operation and destination.');
        }
        result = clone(data);
        const fresh = await refreshCatalog(config, true);
        if (!await selected(config)) return getState();
        if (['committed', 'committed-with-warning'].includes(result.outcome)) {
          const own = ownedRepository(fresh);
          // Retained finalization evidence can need recovery even though the
          // qualified current pointer proves this commit. Preserve attention;
          // this does not grant browsing or turn a warning into plain success.
          const authoritativeState = own?.state === 'committed' ||
            (result.outcome === 'committed-with-warning' && own?.state === 'recovery-required');
          if (!response.ok || !connected(fresh) || !authoritativeState || !own.currentManifestId || !result.transactionId || own.currentTransactionId !== result.transactionId ||
              (result.currentManifestId != null && result.currentManifestId !== own.currentManifestId) ||
              (previousRepository?.currentTransactionId === result.transactionId && previousRepository.currentManifestId !== own.currentManifestId) ||
              (result.committedAt != null && result.committedAt !== own.committedAt)) {
            result = { ...result, outcome: 'failed', message: 'Worker completion was not confirmed by the authoritative local repository catalog.' };
          } else {
            const record = await recordFor(config);
            record.lastCommitted = { destinationId, transactionId: own.currentTransactionId, committedAt: own.committedAt ?? null };
          }
        }
      } catch (error) { result = { ...result, outcome: workerStarted ? 'failed' : 'blocked', message: error.message }; }
      finally {
        if (!await selected(config)) activeOperation = null;
      }
      try {
        if (await selected(config)) {
          await persistAttempt(config, result);
          if (await selected(config)) ports.publish({ operationId, destinationId, backupFormatVersion: 2, phase: result.outcome === 'committed' ? 'complete' : 'finished-with-issue', outcome: result.outcome, detail: result.message });
        }
      } finally { activeOperation = null; }
      return getState();
    });
  }
  async function openLocation(request = {}) {
    try {
      if (Object.keys(request).sort().join(',') !== 'computerId,destinationId,locationId') throw new Error('Request only a catalog location identity.');
      const config = await ports.readConfig();
      if (request.destinationId !== config.destination.id || getBackupFormat(config) !== 2) throw new Error('Browse destination is no longer selected.');
      const fresh = await refreshCatalog(config, true);
      const repos = (fresh?.repositories || []).filter(r => r.computerId === request.computerId);
      if (!connected(fresh) || repos.length !== 1 || !repos[0].capabilities?.browse || !repos[0].locations.some(l => l.locationId === request.locationId)) throw new Error('Location is not in the current browseable catalog.');
      const location = await ports.catalogReader.resolveLocation(config, { computerId: request.computerId, locationId: request.locationId });
      await assertVolume(config);
      if (!await selected(config)) throw new Error('Destination changed during location resolution.');
      const error = await ports.openPath(location.path);
      return { opened: !error, message: error ? 'Could not open the validated backup location.' : 'Backup location opened.' };
    } catch (_error) { return { opened: false, message: 'Backup location could not be validated. Refresh the selected destination and try again.' }; }
  }
  return { getState, enrollIncrementalTest, runBackup, openLocation, saveConfig };
}

module.exports = { createBackupService };
