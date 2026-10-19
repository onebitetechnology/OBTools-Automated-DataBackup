class BackupPolicyError extends Error {
  constructor(message) {
    super(message);
    this.name = 'BackupPolicyError';
  }
}

const owns = (value, name) => value != null && Object.hasOwn(value, name);

function getBackupFormat(config = {}) {
  const value = owns(config.destination, 'backupFormatVersion')
    ? config.destination.backupFormatVersion
    : owns(config, 'incrementalFormatVersion') ? config.incrementalFormatVersion : 1;
  if (typeof value !== 'number' || (value !== 1 && value !== 2)) {
    throw new BackupPolicyError('Unsupported backup format version; expected numeric 1 or 2.');
  }
  return value;
}

function isUtcTimestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$/.test(value)) return false;
  const date = new Date(value);
  // Date.parse normalizes impossible dates (for example February 30).
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 19) === value.slice(0, 19);
}

function normalizeBackupDestination(record) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    throw new BackupPolicyError('Backup destination must be an object.');
  }
  if (owns(record, 'backupFormatVersion')) getBackupFormat({ destination: record });
  if (owns(record, 'volumeUniqueId') && (typeof record.volumeUniqueId !== 'string' || !record.volumeUniqueId.trim())) {
    throw new BackupPolicyError('Backup destination volumeUniqueId must be a nonempty string.');
  }
  if (owns(record, 'manualBetaConfirmedAt') && !isUtcTimestamp(record.manualBetaConfirmedAt)) {
    throw new BackupPolicyError('Backup destination manualBetaConfirmedAt must be an ISO UTC timestamp.');
  }
  // Existing destination normalization supplies legacy defaults. Do not add
  // fields here that would conceal the internal-root compatibility path.
  return { ...record };
}

module.exports = { BackupPolicyError, getBackupFormat, normalizeBackupDestination };
