const { getBackupFormat, normalizeBackupDestination } = require('./backup-format');

const clone = value => value == null ? value : structuredClone(value);

function createBackupCatalogReader({ inspectLegacy, runReadOnly, now = () => new Date() } = {}) {
  const cache = new Map();
  let selection = null;
  let generation = 0;
  let inFlight = null;

  function context(config) {
    const format = getBackupFormat(config);
    const destination = normalizeBackupDestination(config.destination);
    if (typeof destination.id !== 'string' || !destination.id) throw new Error('Catalog requires a destination identity.');
    // Include the entire selected record: reusing an id with a new volume/path
    // must not reuse a cached validation of the old binding.
    return { id: destination.id, format, key: JSON.stringify({ destination, format }) };
  }

  function project(value, ctx) {
    if (!value || value.schema !== 'datasafe.app-catalog' || value.formatVersion !== 1 ||
        value.destinationId !== ctx.id || value.backupFormatVersion !== ctx.format) {
      throw new Error('Catalog response does not match the selected destination/format.');
    }
    const result = clone(value);
    const previous = cache.get(ctx.id);
    if (result.connection === 'disconnected') {
      if (previous?.key === ctx.key) {
        result.repositories = clone(previous.value.repositories);
        result.legacySnapshots = clone(previous.value.legacySnapshots);
        result.latestCommittedAt = previous.value.latestCommittedAt;
        result.latestBackupCreatedAt = previous.value.latestBackupCreatedAt;
      }
      result.lastKnown = true;
      result.state = 'disconnected';
    }
    const counts = new Map();
    for (const repo of result.repositories) counts.set(repo.computerId?.toLowerCase(), (counts.get(repo.computerId?.toLowerCase()) || 0) + 1);
    for (const repo of result.repositories) {
      const ambiguous = counts.get(repo.computerId?.toLowerCase()) > 1;
      const safe = result.connection === 'connected' && result.volumeMatch === true && !result.lastKnown && result.state !== 'invalid';
      repo.capabilities.manualBackup = Boolean(repo.capabilities.manualBackup && safe && !ambiguous && repo.ownedByCurrentComputer &&
        repo.computerId?.toLowerCase() === result.currentComputerId?.toLowerCase() && ['empty', 'committed', 'recovery-required'].includes(repo.state));
      repo.capabilities.browse = Boolean(repo.capabilities.browse && safe && !ambiguous && repo.state === 'committed');
      if (ctx.format === 2) {
        repo.capabilities.legacyRestore = false;
        repo.capabilities.manualVerify = false;
        repo.capabilities.automaticRetention = false;
      }
    }
    result.checkedAtUtc ||= now().toISOString();
    return result;
  }

  // Promise<Catalog|null>: null means superseded, never a cache value. The
  // caller must ignore it (destination switches and forced refreshes cancel).
  async function refresh(config, { force = false } = {}) {
    const ctx = context(config);
    if (selection !== ctx.key) { selection = ctx.key; generation++; inFlight = null; }
    if (!force && inFlight?.generation === generation) return clone(await inFlight.promise);
    const saved = cache.get(ctx.id);
    if (!force && saved?.key === ctx.key) return clone(saved.value);
    if (force) generation++;
    const requestGeneration = generation;
    const snapshot = clone(config);
    const promise = (async () => {
      const value = ctx.format === 1 && inspectLegacy
        ? await inspectLegacy(snapshot) : await runReadOnly('Inspect', snapshot, {});
      if (requestGeneration !== generation || selection !== ctx.key) return null;
      const result = project(value, ctx);
      cache.set(ctx.id, { key: ctx.key, value: result });
      return clone(result);
    })();
    inFlight = { generation: requestGeneration, promise };
    try { return await promise; }
    finally { if (inFlight?.promise === promise) inFlight = null; }
  }

  async function resolveLocation(config, identifiers) {
    const ctx = context(config);
    if (selection !== null && selection !== ctx.key) throw new Error('Browse destination is no longer selected.');
    if (!identifiers || Object.keys(identifiers).sort().join(',') !== 'computerId,locationId' ||
        !['computerId','locationId'].every(k => typeof identifiers[k] === 'string' && identifiers[k].length > 0)) {
      throw new Error('Location requests require only computerId and locationId.');
    }
    const selectedGeneration = generation;
    const selectedKey = selection;
    const result = await runReadOnly('ResolveLocation', clone(config), clone(identifiers));
    if (generation !== selectedGeneration || selection !== selectedKey) throw new Error('Destination changed during location resolution.');
    if (!result || result.destinationId !== ctx.id || result.computerId !== identifiers.computerId ||
        result.locationId !== identifiers.locationId || typeof result.path !== 'string' || !result.path) {
      throw new Error('Resolved location does not match the requested destination and location.');
    }
    return result;
  }

  return { refresh, peek: destinationId => clone(cache.get(destinationId)?.value ?? null), resolveLocation };
}

module.exports = { createBackupCatalogReader };
