# Browseable Incremental Backups Design

**Date:** 2026-10-16

**Status:** Approved in conversation; awaiting written-spec review

**Target:** DataSafe for Windows

## Purpose

DataSafe will add incremental backups without turning customer files into a proprietary archive. A non-technical user must be able to connect the backup drive, open File Explorer, recognize the computer and folders, and copy files without installing DataSafe.

The design favors transparency and safe recovery over maximum possible deduplication. It is Windows-only and does not require a backup created on one operating system to be restorable on another.

## Success Criteria

- `Latest Backup` is a complete, ordinary-file mirror of the most recent successful backup.
- Earlier file versions and deleted files remain ordinary, directly browseable files.
- An unchanged backup recopies no user file content.
- A changed file creates one new ordinary copy and preserves the prior ordinary copy according to retention policy.
- An interrupted backup recovers to either the previous committed state or the new committed state; it never silently presents a mixed state as complete.
- An unavailable source cannot be interpreted as a mass deletion.
- Multiple PCs can use the same drive without mixing their data.
- DataSafe manages retention automatically while never pruning `Latest Backup`.
- Existing snapshot-format drives remain readable and can be upgraded without recopying the newest snapshot.

## Non-Goals

- macOS backup or cross-operating-system restore support
- Proprietary archives, encrypted containers, or content-addressed user-file storage
- Block-level deduplication
- NTFS hard-link snapshots
- Cloud replication
- Open-file capture through Volume Shadow Copy Service; unreadable or locked files are reported and prevent a fully successful result until a separate VSS design is approved
- A USN Change Journal accelerator in the first release; the manifest scan leaves room for this later without changing the on-drive format

## User-Visible Drive Layout

```text
DataSafe Backups/
  Office PC/
    Latest Backup/
      Documents/
      Pictures/
      ...
    Earlier Versions/
      Backup from 2026-10-15 09-00-00/
        Previous Versions/
          Documents/
          ...
        Deleted Files/
          Documents/
          ...
      Legacy Complete Backups/
        2026-09-30_18-00-00/
          ...
    README - How to recover your files.txt
    .datasafe/
      repository.json
      manifests/
      transactions/
      staging/
```

All user content under `Latest Backup`, `Previous Versions`, `Deleted Files`, and `Legacy Complete Backups` is stored in its original file format. `.datasafe` contains metadata and transaction records only; it never contains encoded user-file content.

Each computer directory has a friendly name chosen from the Windows computer name. A UUID stored locally and in `.datasafe/repository.json` is the authoritative identity. Directory names are never used as the sole identity, so two PCs with the same friendly name cannot overwrite one another. Name collisions receive an understandable suffix while retaining distinct UUIDs.

The README explains, in plain language, where the newest files, earlier versions, and deleted files are located and how to copy them without DataSafe.

## Version Semantics

Every successful backup has a committed timestamp and manifest.

`Latest Backup` represents the newest committed manifest. When a file that existed in the previous committed manifest is changed or deleted:

- Its prior copy is moved to `Earlier Versions/Backup from <previous successful timestamp>/Previous Versions/<relative path>` when replaced.
- Its prior copy is moved to `Earlier Versions/Backup from <previous successful timestamp>/Deleted Files/<relative path>` when deleted.
- The relative path beneath the selected source remains recognizable.

A history folder contains only files that stopped being current after that backup; it is not presented as a complete snapshot. The README and UI state this explicitly. Folder names include seconds, and a friendly numeric suffix resolves the unlikely case of two committed backups with the same displayed timestamp. The manifest timestamp and transaction UUID remain authoritative.

A newly created file has no prior copy to archive. Its absence from older states is recorded in the manifests. A rename is treated as one deletion and one addition in the first release. Metadata-only changes that leave file content identical update the manifest and supported attributes without creating a duplicate content version.

For an app-assisted point-in-time restore, DataSafe reads the selected manifest, locates each required version in `Latest Backup` or `Earlier Versions`, verifies it, and restores it. If metadata is unavailable, the ordinary files remain manually recoverable even though automated point-in-time reconstruction may be unavailable.

## Change Detection

The first backup enumerates every selected source and creates a manifest containing the relative path, type, size, modification time, supported attributes, SHA-256 hash, and version location.

Subsequent backups still enumerate selected sources for correctness, but compare size and modification time with the last committed manifest:

- Unchanged size and modification time: skip content copy.
- New path or changed size/time: hash the source and compare it with the previous content hash when one exists.
- Same hash with metadata changes: update metadata only.
- Different hash: stage a new copy.
- Path missing from an accessible source: propose a deletion.

Every staged user file is read back and SHA-256 verified before it can replace a current version. A scheduled integrity job performs a full verification of the latest backup at least monthly and remains available on demand.

The scan is O(number of files), but write volume is proportional to new and changed files. The UI reports separate scanning and copying phases and calculates copy ETA from bytes that actually require transfer.

## Backup Transaction

Only one backup, restore, migration, or repository-maintenance operation may own a PC repository at a time.

Each backup uses a durable transaction record with `prepared`, `applying`, and `committed` states:

1. **Validate**
   - Verify repository and PC identities.
   - Confirm every configured source root is accessible.
   - Load and validate the previous committed manifest.
   - Build the change set and apply deletion safeguards.
   - Estimate staging, history, and reserve space.
2. **Prepare**
   - Prune only retention-eligible history if space is needed.
   - Copy new and changed files to `.datasafe/staging/<transaction UUID>`.
   - Read back and verify each staged file.
   - Write and flush the complete operation journal before applying changes.
3. **Apply**
   - Before replacing or deleting a current file, move it on the same volume into its ordinary-file history location.
   - Promote each verified staged file into `Latest Backup` using a same-volume rename where supported.
   - Record and flush each completed operation in the journal.
4. **Commit**
   - Write the new manifest to a temporary name, verify it, then atomically rename it to its committed name.
   - Update the repository's current-manifest pointer atomically.
   - Mark the transaction committed before removing temporary data.

No retention pruning occurs after a transaction enters `applying` and before it commits or rolls back.

If power is lost or the drive is disconnected, the next attachment detects the unfinished journal before allowing another operation. It either completes safe pending promotions or rolls back completed promotions using the archived prior files. Recovery validates hashes and then returns the repository to a single committed manifest. An interrupted state is never labeled as a successful backup.

## Deletion and Source-Safety Rules

- Failure to enumerate a source root aborts the run before any deletion is applied.
- A missing removable or network source is an unavailable source, not an empty source.
- A scheduled run pauses for review when proposed deletions are both at least 20 files and at least 10% of the previous manifest for that source, or when at least half of any non-empty source would be deleted.
- Until reviewed in the Electron app, `Latest Backup` remains unchanged.
- Reparse points, junctions, and symbolic links outside selected source roots are not followed.
- Unsafe path traversal and duplicate normalized paths abort the run.
- Locked or unreadable required files are reported by name and abort the transaction during preparation; the previously committed `Latest Backup` remains unchanged.

## Filesystem Support

NTFS is the recommended Windows destination because it supports large files, journaling, long paths, and reliable same-volume operations.

ExFAT remains supported using DataSafe's transaction journal and integrity checks. FAT32 is supported only in compatibility mode when all selected files fit its individual-file limit. DataSafe prominently warns that FAT32 cannot store files larger than 4 GiB and aborts before making changes if the pending backup contains one. DataSafe never formats or reformats a drive automatically.

The engine continues to use Windows long-path-safe operations for scanning, staging, history, verification, recovery, pruning, and restore.

## Automatic Retention and Space Management

Retention applies only to `Earlier Versions` and legacy complete snapshots. `Latest Backup` is never eligible for pruning.

Default automatic policy:

- Keep every previous version for 30 days.
- Keep deleted files for at least 90 days.
- After the all-version period, retain the most recent available version of each file for each calendar month in the preceding 12 months.
- After 12 months, retain the most recent available version of each file for each calendar year while space permits.
- Remove eligible versions oldest first when additional space is required.

After scanning, DataSafe estimates the pending transaction's peak space requirement. It prunes eligible history only while no backup transaction is active and targets post-backup free space of at least the larger of 5 GiB or 10% of drive capacity.

Pruning is itself a journaled repository-maintenance operation. It first commits the removal of expired restore points and version references, then deletes only history files no longer referenced by any retained manifest. An interruption may temporarily leave extra unreferenced files, but it cannot leave a retained manifest pointing to a deleted version. Empty history directories are removed after their contents become unreferenced.

If the backup cannot fit without violating guaranteed retention, DataSafe stops before modifying `Latest Backup` and explains that a larger drive is needed. It never silently shortens the guaranteed retention window.

The completion summary reports unchanged, added, updated, deleted, and pruned counts in plain language. Detailed paths remain available in an expandable report rather than a technical popup.

## Restore Experience

Manual recovery requires no application: users browse `Latest Backup` or the ordinary files in `Earlier Versions` and copy them with File Explorer.

DataSafe provides three primary actions:

- **Find a file**
- **Restore a folder**
- **Restore everything**

The default restore destination is a timestamped `Recovered Files` folder. Overwriting an existing destination requires explicit confirmation after a conflict preview. DataSafe verifies the selected backup versions before restore and verifies the restored copies afterward.

The app can filter versions by computer, date, original path, and whether they were replaced or deleted. Technical manifest or hash details are hidden by default but available in support diagnostics.

## Multiple-PC Behavior

Each PC has an isolated user-visible directory, repository metadata, manifest chain, history, staging area, transaction journal, and retention calculation. A transaction for one PC cannot mutate another PC's files.

Drive-level free-space planning considers all PC repositories. Pruning is fair and conservative: only retention-eligible history may be removed, and DataSafe reports which computer's old versions were pruned. The latest backup for every PC is protected.

## Legacy Snapshot Migration

DataSafe continues to discover, verify, browse, and restore the existing snapshot format.

The upgrade flow is explicit and journaled:

1. Verify the newest completed legacy snapshot and its integrity metadata.
2. Create the new PC repository metadata and migration journal.
3. Move the newest legacy snapshot on the same volume into `Latest Backup`; do not recopy it.
4. Move the newest snapshot's legacy control files into `.datasafe/legacy-metadata/<snapshot timestamp>` so `Latest Backup` contains only the recognizable backup tree. Preserve their original paths in the migration journal for rollback.
5. Move older completed snapshots intact into `Earlier Versions/Legacy Complete Backups`.
6. Generate the first version-2 manifest from `Latest Backup` and verify it.
7. Commit the version-2 repository only after the new layout passes verification.

Before commit, the journal can restore the original directory names and layout. After commit, legacy complete backups remain ordinary, browseable folders and remain restorable by DataSafe. Automatic retention ages them out as new incremental history accumulates; the migration does not immediately delete them.

Incomplete legacy `.stage*` directories are not treated as completed backups. Cleanup requires the same safe long-path and transaction rules and occurs only after completed legacy snapshots are identified.

## Consumer-Facing Status and Errors

The Electron app is the only owner of notifications and prompts. Background workers emit structured status and logs and never open PowerShell windows, tray balloons, or modal dialogs.

Primary progress language:

- “Checking your files”
- “Preparing 12 updates”
- “Saving previous versions”
- “Verifying the backup”
- “Your backup is up to date”

Errors state what remained safe and what the user should do. Examples:

- “The Documents folder was unavailable, so DataSafe left your existing backup unchanged.”
- “This drive needs 18 GB more free space. Your latest backup and protected history were not removed.”
- “The drive was disconnected. Reconnect it and DataSafe will safely resume or undo the unfinished update.”

## Test Strategy

Unit tests cover:

- Manifest comparison and normalized path handling
- Version-location selection for point-in-time restore
- Retention cohorts and protected windows
- Space estimation and reserve calculations
- Source-unavailable and mass-deletion safeguards
- Transaction-state transitions, replay, and rollback
- PC identity and friendly-name collisions
- Legacy migration planning

Integration tests use real filesystem operations and cover:

- A second unchanged run copies zero user-file bytes
- One changed file archives exactly one prior ordinary copy
- New, changed, renamed, and deleted files
- File Explorer browsing without DataSafe
- Restore from latest, previous, deleted, and legacy locations
- Long paths and Unicode names
- Files larger than 4 GiB on NTFS/exFAT and FAT32 preflight rejection
- Multiple PCs sharing one drive
- Insufficient space before staging and during simulated faults
- Drive removal or process termination at every journaled operation
- Recovery to the previous or new committed manifest with no mixed success state
- Corrupt staging content, manifests, journals, and archived versions
- Reparse points and paths that escape a selected source
- Legacy migration rollback and commit
- Retention that never removes any PC's latest backup

End-to-end acceptance tests verify the Electron setup, progress, deletion-review, recovery, migration, and error-language flows without visible terminal windows.

## Rollout and Compatibility

The on-drive format receives a new explicit format version. The reader supports both the current snapshot format and the new incremental format before the writer is enabled.

Rollout sequence:

1. Ship read-only discovery and restore support for both formats.
2. Ship the version-2 engine behind a development flag with fault-injection tests.
3. Validate new repositories and legacy migrations on Windows test machines and NTFS, exFAT, and FAT32 media.
4. Enable new repositories for beta users while retaining legacy restore support.
5. Offer journaled migration to existing users only after beta verification.

The format does not depend on PowerShell-specific serialization. Metadata uses documented UTF-8 JSON/JSONL schemas with explicit versions so future workers can read it without changing the ordinary-file layout.
