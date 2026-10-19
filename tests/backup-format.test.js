const test = require('node:test');
const assert = require('node:assert/strict');
const { getBackupFormat, normalizeBackupDestination, BackupPolicyError } = require('../backup-format');

test('format defaults and precedence', () => {
  assert.equal(getBackupFormat({ destination: {} }), 1);
  assert.equal(getBackupFormat({ incrementalFormatVersion: 2, destination: { backupFormatVersion: 1 } }), 1);
  assert.equal(getBackupFormat({ incrementalFormatVersion: 2, destination: {} }), 2);
  assert.equal(getBackupFormat({ incrementalFormatVersion: 'invalid', destination: { backupFormatVersion: 2 } }), 2);
  assert.equal(getBackupFormat({}), 1);
});

test('format rejects coercion', () => {
  for (const value of ['2', 0, 3, null, true, [2], {}, NaN, undefined]) {
    assert.throws(() => getBackupFormat({ destination: { backupFormatVersion: value } }), BackupPolicyError);
    assert.throws(() => getBackupFormat({ incrementalFormatVersion: value, destination: {} }), BackupPolicyError);
  }
});

test('destination metadata round trips without changing existing choices', () => {
  const record = { id: '9ea0c9e4-92d1-4819-9191-205f36a837ac', driveLetter: 'F:',
    baseFolder: 'Unchanged Legacy Folder', backupFormatVersion: 2,
    volumeUniqueId: '\\\\?\\Volume{7252693e-e341-45b2-8368-3530b72e3fb2}\\',
    manualBetaConfirmedAt: '2026-10-19T01:02:03.000Z' };
  assert.deepEqual(normalizeBackupDestination(JSON.parse(JSON.stringify(record))), record);
  assert.notEqual(normalizeBackupDestination(record), record);
  assert.deepEqual(normalizeBackupDestination({ driveLetter: 'F:' }), { driveLetter: 'F:' });
  assert.equal(getBackupFormat({ destination: normalizeBackupDestination({ backupFormatVersion: 1 }) }), 1);
});

test('destination rejects malformed metadata', () => {
  for (const record of [null, [], 'F:', { backupFormatVersion: '2' },
    { volumeUniqueId: null }, { volumeUniqueId: ' ' }, { volumeUniqueId: 12 },
    { manualBetaConfirmedAt: null }, { manualBetaConfirmedAt: 'yesterday' },
    { manualBetaConfirmedAt: '2026-02-30T00:00:00Z' },
    { manualBetaConfirmedAt: '2026-10-19T00:00:00-06:00' }]) {
    assert.throws(() => normalizeBackupDestination(record), BackupPolicyError);
  }
});
