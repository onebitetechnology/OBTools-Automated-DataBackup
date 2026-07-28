# DataSafe Backup Format

Format version: 1

## Destination identity

Each managed backup root contains `.datasafe-backup.json`. Before any backup or restore, DataSafe verifies:

- the marker is readable
- `installId` matches the local installation
- `destinationId` matches the configured destination

Scheduled and catch-up backups cannot initialize a markerless destination. The first backup to a new destination must be started manually in DataSafe.

## Snapshot lifecycle

1. Preflight checks destination identity, free space, and a 64 KB write/flush/read/delete probe.
2. Data is copied once to `snapshots/.incomplete-<timestamp>-<guid>.incomplete`.
3. DataSafe reads each copied file and writes `.datasafe-integrity.jsonl`.
4. DataSafe writes `.datasafe-manifest.json`.
5. DataSafe hashes the manifest and integrity index, then writes `.datasafe-complete.json`.
6. The staging folder is renamed to `snapshots/yyyy-MM-dd_HH-mm-ss`.
7. Retention runs only after the rename succeeds.

A folder is a usable snapshot only when its timestamp is valid, all three metadata files exist, the format is supported, names agree, and the manifest hash matches the completion record.

## Integrity records

Each JSON line in `.datasafe-integrity.jsonl` contains:

- relative file path
- byte length
- last-write time in UTC
- SHA-256 hash

The completion record stores the SHA-256 hash of the entire integrity index. Backup creation reads every destination file to create the index. The weekly integrity task fully verifies the newest completed snapshot.

## Restore safety

Alternate restore:

- verifies completion metadata and checksums for the selected backup item
- always creates a unique destination folder
- removes incomplete output if restore fails

Original-location restore:

- builds a conflict report before confirmation
- verifies the selected backup item
- copies the current target to `restore-safety/<restore-id>/original`
- checksum verifies the safety copy
- writes `restore-journal.json`
- attempts automatic rollback if restore fails
- retains the safety copy and journal after success

## Compatibility

Timestamp folders created before format version 1 do not have trustworthy completion metadata. DataSafe excludes them from current snapshot and restore lists. They must not be deleted automatically; a technician should review them before cleanup or migration.
