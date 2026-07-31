# Data Protection And Reliability Design

## Goal

Close the production-readiness gaps that could cause DataSafe to restore
unverified data, restore a historical snapshot to an unsafe location, or make
an unsupported cloud or preview-server claim.

## Scope

This increment implements safeguards that work entirely inside the Windows
desktop application and its local backup format:

- Treat a completed snapshot as a closed, checksum-indexed file tree. A restore
  must fail when a selected backup item contains a file absent from the signed
  integrity index.
- Read the selected snapshot's manifest to identify its backed-up item. A
  missing or changed current job may still restore to a separate folder. An
  original-location restore remains available only when the current job still
  exactly matches the stored source path and item type.
- Reject alternate restore locations inside the backup repository, selected
  snapshot, or original source tree.
- Use the same status-file operation lock for backups and mutating restores.
- Avoid catch-up duplicates after a completed backup reported a non-fatal
  retention warning.
- Describe cloud checking as a local OneDrive configuration check, never as a
  confirmed cloud-backup health signal. Preserve an error status rather than
  retaining stale success state.
- Restrict the Mac/web preview to loopback, reject traversal paths, and make
  its mutating API endpoints explicitly preview-only.
- Keep app data on uninstall by default, run tests before release publishing,
  and record code-signing as a required release input.

## Non-Goals

- Calling OneDrive, Dropbox, Google Drive, or Backblaze provider APIs. Those
  require a product-specific authorization and support model.
- Enabling Windows code signing without an organization certificate and its
  securely stored key.
- Building the signed reseller deployment-profile service. This needs a
  separate key-management and deployment-console design.
- Migrating Electron to a new major version in the same safety patch. That is a
  separately testable dependency upgrade.

## Design

### Snapshot Integrity

`Test-DataSafeIntegrityIndex` will parse the integrity index into a map and
compare it with the actual files beneath the requested restore prefix. Metadata
files are excluded. A missing indexed file, mismatched checksum, duplicate
index record, unsafe relative path, or unindexed on-disk file fails the check.

### Historical Recovery

Snapshot manifests will include enough immutable job metadata to locate the
backed-up content and present its original source identity. Restore resolves
the item from that manifest rather than from the editable current job list.
Separate-folder restore uses the manifest record. Original-location restore
requires a current job with the same id, expanded source path, and type; any
mismatch requires a separate-folder restore.

### Restore Containment And Concurrency

The selected alternate base folder and generated child must not be inside the
DataSafe base root, snapshot root, or original source path. Backup and restore
share an exclusive operation lock at `<status>.lock`; planning remains
read-only and does not acquire it.

### Honest State And Release Hygiene

Cloud health distinguishes a local configuration check from a verified provider
sync. Failures write a fresh error state. The local browser preview only binds
to `127.0.0.1`, serves normalized paths under `assets`, and identifies its
simulations clearly. Uninstall preserves recovery configuration. CI runs the
test suite before building and publishing; a signing step remains conditional
on provisioned certificate secrets.

## Verification

Automated Node tests will exercise completed snapshot inspection and the
PowerShell safety module when a PowerShell runtime is available. The release
workflow will run `npm test` before packaging. Static JavaScript and PowerShell
parse checks remain required. Windows validation still includes a real external
drive, interrupted backup, blocked restore target, changed-job recovery, and
uninstall/reinstall test.
