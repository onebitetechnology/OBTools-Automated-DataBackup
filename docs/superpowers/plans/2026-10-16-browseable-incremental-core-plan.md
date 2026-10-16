# Browseable Incremental Backup Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and fault-test the Windows version-2 incremental storage engine that maintains a complete ordinary-file `Latest Backup` and ordinary-file earlier versions without enabling it for customers yet.

**Architecture:** Four focused PowerShell 5.1-compatible worker libraries own repository layout, manifest/diff logic, preflight planning, and durable transactions. `backup-engine.ps1` invokes them only behind an internal development flag while the existing snapshot engine remains the production fallback. This phase deliberately excludes automatic retention, restore/migration, and Electron UX; each receives its own implementation plan after the core format proves crash-safe.

**Tech Stack:** Windows PowerShell 5.1, PowerShell Core for fast cross-platform unit checks, UTF-8 JSON/JSONL metadata, SHA-256, Electron packaging through the existing `package.json` configuration

**Spec:** `docs/superpowers/specs/2026-10-16-browseable-incremental-backups-design.md`

## Global Constraints

- Windows-only; no macOS backup or cross-operating-system restore support.
- User content stays as ordinary files; `.datasafe` contains metadata and transaction records only.
- `Latest Backup` is never pruned and is changed only by a verified, journaled transaction.
- Multiple PCs use UUID identity and isolated repositories even when friendly names collide.
- NTFS is recommended, exFAT is supported, and FAT32 preflight rejects any pending file larger than 4 GiB.
- Use Windows long-path-safe operations for every scan, copy, hash, move, remove, and verification path.
- Do not follow reparse points, junctions, or symbolic links outside selected sources.
- An inaccessible source, suspicious deletion set, unreadable required file, or insufficient peak space aborts before `Latest Backup` changes.
- All worker code remains compatible with Windows PowerShell 5.1; do not introduce a PowerShell 7-only API or syntax.
- The Electron app remains the sole owner of notifications; workers emit structured status and logs only.
- Phase 1 never deletes history automatically and cannot be enabled by the consumer-facing UI.
- Integrate and verify `datasafe-hotfix-handoff-2026-10-16.zip` on the Mac source branch before starting Task 1; the plan assumes its long-path, hidden-runner, and Chromium-exclusion fixes are present.

## Review Focus

- Case-insensitive path collisions such as `Report.docx` and `report.docx` must abort planning rather than overwrite one file.
- A source file that changes between scan and staging must abort before apply and leave the committed backup untouched.
- A user-edited or corrupt file already in `Latest Backup` must be detected before it is archived or replaced.
- A full drive or forced process failure after any journaled operation must recover to one committed state, never a mixed success state.
- Two runs with the same display timestamp or two PCs with the same friendly name must receive collision-free folders while preserving their UUID identities.

---

## Program Decomposition

This is **Plan 1 of 4**:

1. **Core engine (this plan):** repository, manifests, change planning, staging, journaling, apply, rollback, internal integration.
2. **Repository maintenance:** automatic retention cohorts, free-space reserve, multi-PC pruning fairness, periodic integrity scrub.
3. **Recovery and migration:** point-in-time restore, `Recovered Files`, legacy snapshot discovery, journaled version-2 migration.
4. **Consumer integration:** setup, progress, deletion review, recovery UI, notification ownership, rollout flags, support diagnostics.

Plans 2–4 must consume the interfaces stabilized here rather than duplicating storage logic.

### Task 1: Repository Layout, Identity, and Filesystem Capabilities

**Files:**
- Create: `windows/DataSafe.Repository.ps1`
- Create: `tests/windows/Run-IncrementalRepositoryTests.ps1`
- Modify: `windows/DataSafe.Safety.ps1`

**Interfaces:**
- Consumes: long-path helpers from `DataSafe.Safety.ps1`.
- Produces: `Get-DataSafeComputerId -StatePath <string> -> string`; `Get-DataSafeDestinationCapabilities -DriveRoot <string> -> PSCustomObject`; `Initialize-DataSafeRepository -DriveRoot <string> -ComputerName <string> -ComputerId <string> -> PSCustomObject`; `Read-DataSafeRepository -RepositoryRoot <string> -> PSCustomObject`.
- Repository result properties: `FormatVersion`, `ComputerId`, `ComputerName`, `Root`, `LatestRoot`, `HistoryRoot`, `MetadataRoot`, `ManifestRoot`, `TransactionRoot`, and `StagingRoot`.

- [ ] **Step 1: Write failing repository tests**

Add assertions that initialization creates `DataSafe Backups/<friendly name>/Latest Backup`, `Earlier Versions`, `.datasafe/manifests`, `.datasafe/transactions`, `.datasafe/staging`, and `repository.json` with `formatVersion = 2` and the exact UUID. Initialize a second UUID with the same friendly name and assert it receives a distinct suffixed folder. Add capability assertions for NTFS recommendation, exFAT support, and a FAT32 `maxFileBytes = 4294967295` result.

- [ ] **Step 2: Run the repository tests and verify the red state**

Run: `pwsh -NoProfile -File tests/windows/Run-IncrementalRepositoryTests.ps1`

Expected: FAIL because `DataSafe.Repository.ps1` and its public functions do not exist.

- [ ] **Step 3: Implement the repository interfaces**

Use UTF-8 JSON with an explicit schema and atomic temporary-file rename. Sanitize only the friendly directory segment; store and compare the UUID as authoritative identity. Add focused atomic JSON-write and safe same-volume move primitives to `DataSafe.Safety.ps1` rather than duplicating filesystem logic.

- [ ] **Step 4: Run repository tests on PowerShell Core and Windows PowerShell 5.1**

Run on the Mac source checkout: `pwsh -NoProfile -File tests/windows/Run-IncrementalRepositoryTests.ps1`

Run on the Windows test PC: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\windows\Run-IncrementalRepositoryTests.ps1`

Expected from each: `Result: <count> passed; 0 failed.`

- [ ] **Step 5: Commit Task 1**

```bash
git add windows/DataSafe.Repository.ps1 windows/DataSafe.Safety.ps1 tests/windows/Run-IncrementalRepositoryTests.ps1
git commit -m "feat: add incremental repository layout"
```

### Task 2: Version-2 Manifests and Deterministic Change Sets

**Files:**
- Create: `windows/DataSafe.Manifest.ps1`
- Create: `tests/windows/Run-IncrementalManifestTests.ps1`
- Modify: `windows/DataSafe.Repository.ps1`

**Interfaces:**
- Consumes: repository object from Task 1 and `Get-DataSafeSha256` from `DataSafe.Safety.ps1`.
- Produces: `New-DataSafeSourceManifest -Jobs <object[]> -PreviousManifest <object|null> -HashProvider <scriptblock|null> -> PSCustomObject`; `Compare-DataSafeManifests -Previous <object|null> -Current <object> -> PSCustomObject`; `Write-DataSafeManifest -Repository <object> -Manifest <object> -TransactionId <string> -> string`; `Read-DataSafeManifest -Path <string> -> PSCustomObject`.
- Manifest entries use `sourceId`, `relativePath`, `entryType`, `length`, `modifiedUtc`, `attributes`, `sha256`, and `versionLocation`.
- Change-set result properties: `Added`, `ContentChanged`, `MetadataChanged`, `Deleted`, `Unchanged`, `SourceErrors`, and aggregate byte/count totals.

- [ ] **Step 1: Write failing manifest tests**

Cover an initial scan, a second unchanged scan that invokes the injected hash provider zero times, one content change, one metadata-only change with identical SHA-256, an addition, a deletion, a rename represented as delete-plus-add, Unicode paths, long paths, and a case-insensitive normalized-path collision that throws before returning a manifest.

- [ ] **Step 2: Run the manifest tests and verify the red state**

Run: `pwsh -NoProfile -File tests/windows/Run-IncrementalManifestTests.ps1`

Expected: FAIL because the manifest interfaces are undefined.

- [ ] **Step 3: Implement manifest enumeration and comparison**

Key entries by `sourceId + normalized relative path` using ordinal case-insensitive comparison. Reuse a previous hash only when size and modification time are unchanged. Hash new or changed candidates, but classify an identical hash as metadata-only. Reject duplicate normalized paths, unsafe traversal, or entries escaping a selected source.

- [ ] **Step 4: Run manifest and existing hotfix regression tests**

Run: `pwsh -NoProfile -File tests/windows/Run-IncrementalManifestTests.ps1`

Run on Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\windows\Run-HotfixRegressionTests.ps1`

Expected: both suites report zero failures.

- [ ] **Step 5: Commit Task 2**

```bash
git add windows/DataSafe.Manifest.ps1 windows/DataSafe.Repository.ps1 tests/windows/Run-IncrementalManifestTests.ps1
git commit -m "feat: add incremental manifests and diffing"
```

### Task 3: Preflight Plan and Destructive-Change Safeguards

**Files:**
- Create: `windows/DataSafe.IncrementalPlan.ps1`
- Create: `tests/windows/Run-IncrementalPlanTests.ps1`
- Modify: `windows/DataSafe.Manifest.ps1`

**Interfaces:**
- Consumes: repository and change-set objects from Tasks 1–2.
- Produces: `New-DataSafeIncrementalPlan -Repository <object> -PreviousManifest <object|null> -CurrentManifest <object> -Capabilities <object> -FreeBytes <long> -> PSCustomObject`.
- Plan result properties: `TransactionId`, `PreviousBackupTimestamp`, `DisplayHistoryFolder`, `Operations`, `StageBytes`, `PeakRequiredBytes`, `DeletionReviewRequired`, `DeletionCountsBySource`, and `BlockingErrors`.

- [ ] **Step 1: Write failing preflight tests**

Assert that the plan blocks an unavailable source; blocks a FAT32 file of `4294967296` bytes; requires deletion review at 20 deleted files and 10% of a source or at 50% of any non-empty source; blocks insufficient `PeakRequiredBytes`; produces unique suffixed history folders for identical display timestamps; and emits no delete operation before review. Add the Review Focus case for case-insensitive collisions as a blocking error even if a handcrafted manifest bypasses Task 2 validation.

- [ ] **Step 2: Run plan tests and verify the red state**

Run: `pwsh -NoProfile -File tests/windows/Run-IncrementalPlanTests.ps1`

Expected: FAIL because `New-DataSafeIncrementalPlan` is undefined.

- [ ] **Step 3: Implement deterministic planning**

Order operations by source ID and normalized relative path. Calculate peak usage from staging bytes, metadata overhead, and the required reserve; do not count same-volume history moves as new content bytes. A plan with any blocking error remains serializable for diagnostics but cannot be executed.

- [ ] **Step 4: Run repository, manifest, and plan suites**

Run all three `Run-Incremental*Tests.ps1` scripts under `pwsh`, then repeat the plan suite under Windows PowerShell 5.1.

Expected: every suite reports zero failures.

- [ ] **Step 5: Commit Task 3**

```bash
git add windows/DataSafe.IncrementalPlan.ps1 windows/DataSafe.Manifest.ps1 tests/windows/Run-IncrementalPlanTests.ps1
git commit -m "feat: add incremental backup preflight"
```

### Task 4: Verified Staging and Durable Transaction Journal

**Files:**
- Create: `windows/DataSafe.Transaction.ps1`
- Create: `tests/windows/Run-IncrementalTransactionTests.ps1`
- Modify: `windows/DataSafe.Safety.ps1`

**Interfaces:**
- Consumes: executable plan from Task 3.
- Produces: `New-DataSafeTransaction -Repository <object> -Plan <object> -> PSCustomObject`; `Stage-DataSafeTransaction -Transaction <object> -HashProvider <scriptblock|null> -> PSCustomObject`; `Read-DataSafeTransaction -Path <string> -> PSCustomObject`; `Set-DataSafeTransactionState -Transaction <object> -State <prepared|applying|committed|rollingBack|rolledBack> -> void`.
- Each journal operation records `sequence`, `kind`, `sourcePath`, `currentPath`, `historyPath`, `stagedPath`, `expectedOldSha256`, `expectedNewSha256`, and `status`.

- [ ] **Step 1: Write failing staging and journal tests**

Assert that only added/content-changed files enter staging; each staged copy is read back and hash verified; a source changing after manifest scan causes staging to fail; journal writes survive a forced process exception; corrupt staged content blocks `prepared`; and a second transaction cannot acquire the repository lock.

- [ ] **Step 2: Run transaction tests and verify the red state**

Run: `pwsh -NoProfile -File tests/windows/Run-IncrementalTransactionTests.ps1`

Expected: FAIL because the transaction interfaces are undefined.

- [ ] **Step 3: Implement staging and journal durability**

Write journals through a flushed temporary file and atomic rename. Do not enter `prepared` until every staged file matches the plan hash and every operation is fully serialized. Reuse the existing exclusive DataSafe operation-lock behavior.

- [ ] **Step 4: Run transaction tests under both PowerShell runtimes**

Run the transaction suite under `pwsh` and Windows PowerShell 5.1.

Expected: zero failures and no files outside the temporary test repository.

- [ ] **Step 5: Commit Task 4**

```bash
git add windows/DataSafe.Transaction.ps1 windows/DataSafe.Safety.ps1 tests/windows/Run-IncrementalTransactionTests.ps1
git commit -m "feat: add verified incremental staging"
```

### Task 5: Apply, Commit, Rollback, and Crash Recovery

**Files:**
- Modify: `windows/DataSafe.Transaction.ps1`
- Modify: `tests/windows/Run-IncrementalTransactionTests.ps1`
- Create: `tests/windows/Run-IncrementalFaultInjectionTests.ps1`

**Interfaces:**
- Consumes: prepared transaction from Task 4.
- Produces: `Invoke-DataSafeTransaction -Transaction <object> -AfterOperation <scriptblock|null> -> PSCustomObject`; `Recover-DataSafeTransaction -Repository <object> -TransactionPath <string> -> PSCustomObject`; `Undo-DataSafeTransaction -Transaction <object> -> PSCustomObject`.
- Recovery result properties: `FinalState`, `RecoveredOperationCount`, `ManifestPath`, and `Warnings`.

- [ ] **Step 1: Write failing apply and fault-injection tests**

Cover add, replace, delete, and metadata-only operations. Assert old copies land under `Backup from <previous timestamp>/Previous Versions` or `Deleted Files`; `Latest Backup` matches the new manifest; and the manifest pointer changes only after all operations verify. Inject failure after every journal sequence and assert recovery reaches exactly the old or new manifest. Add explicit tests that a manually altered current file aborts before archive, a full-drive write failure leaves the old commit recoverable, and same-timestamp history paths never collide.

- [ ] **Step 2: Run fault-injection tests and verify the red state**

Run: `pwsh -NoProfile -File tests/windows/Run-IncrementalFaultInjectionTests.ps1`

Expected: FAIL because apply and recovery functions are undefined.

- [ ] **Step 3: Implement journaled apply and recovery**

Before archiving an existing current file, verify it matches `expectedOldSha256`. Flush the operation's completed state after each same-volume move or promotion. Commit the new manifest through a verified temporary file and atomic current-pointer replacement. Recovery chooses roll-forward only when every remaining staged object is present and verified; otherwise it rolls back.

- [ ] **Step 4: Run all fault points repeatedly**

Run: `1..20 | ForEach-Object { pwsh -NoProfile -File tests/windows/Run-IncrementalFaultInjectionTests.ps1; if ($LASTEXITCODE) { exit $LASTEXITCODE } }`

Run once under Windows PowerShell 5.1.

Expected: every iteration reports zero failures; no committed manifest references a missing version.

- [ ] **Step 5: Commit Task 5**

```bash
git add windows/DataSafe.Transaction.ps1 tests/windows/Run-IncrementalTransactionTests.ps1 tests/windows/Run-IncrementalFaultInjectionTests.ps1
git commit -m "feat: add crash-safe incremental commit"
```

### Task 6: Development-Only Backup Engine Integration

**Files:**
- Modify: `windows/backup-engine.ps1`
- Modify: `windows/DataSafe.Safety.ps1`
- Create: `tests/windows/Run-IncrementalEngineIntegrationTests.ps1`

**Interfaces:**
- Consumes: Tasks 1–5 public functions.
- Produces: internal config field `incrementalFormatVersion: 2`; structured status fields `backupFormatVersion`, `scanCounts`, `copyBytes`, `historyCounts`, `transactionId`, and `recoveryAction`.
- Existing configurations with no internal field continue through the version-1 snapshot path unchanged.

- [ ] **Step 1: Write failing engine integration tests**

Run a first version-2 backup, an unchanged second run, a one-file change, and one deletion in temporary repositories. Assert `Latest Backup` is complete and browseable, the unchanged run copies zero user-file bytes, the prior version is ordinary content in history, and status contains the defined structured fields. Run without the internal field and assert the existing snapshot layout remains unchanged. Assert none of the worker scripts contain popup or tray-notification APIs.

- [ ] **Step 2: Run integration tests and verify the red state**

Run on Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\windows\Run-IncrementalEngineIntegrationTests.ps1`

Expected: FAIL because the backup engine does not route to the version-2 libraries.

- [ ] **Step 3: Integrate the version-2 engine behind the internal field**

Dot-source all four new libraries after `DataSafe.Safety.ps1`. Recover any unfinished version-2 transaction before scanning. Refuse a version-2 run when deletion review is required; do not create a consumer bypass in this phase. The existing `electron-builder.config.js` packages the complete `windows` directory through `extraResources`, so no allowlist change is required.

- [ ] **Step 4: Run incremental and legacy suites**

Run the engine integration suite, every `Run-Incremental*Tests.ps1` suite, the existing Windows worker tests, and the hotfix regression suite under Windows PowerShell 5.1.

Expected: all report zero failures; the legacy test fixtures and outputs remain unchanged.

- [ ] **Step 5: Build and inspect the Windows package**

Run `npm run dist:win` on the Mac build machine. Inspect the unpacked artifact and assert it contains `DataSafe.Repository.ps1`, `DataSafe.Manifest.ps1`, `DataSafe.IncrementalPlan.ps1`, and `DataSafe.Transaction.ps1` under the packaged `resources/windows` directory.

Expected: build exits 0 and all four files are present.

- [ ] **Step 6: Commit Task 6**

```bash
git add windows/backup-engine.ps1 windows/DataSafe.Safety.ps1 tests/windows/Run-IncrementalEngineIntegrationTests.ps1
git commit -m "feat: integrate incremental backup engine"
```

### Task 7: Windows Media Matrix and Phase-1 Review Gate

**Files:**
- Create: `tests/windows/Run-IncrementalMediaMatrix.ps1`
- Create: `docs/testing/incremental-phase-1.md`
- Modify: `tests/windows/Run-IncrementalEngineIntegrationTests.ps1`

**Interfaces:**
- Consumes: packaged version-2 worker engine from Task 6.
- Produces: repeatable NTFS/exFAT/FAT32 test record and the stable interface inventory required by Plans 2–4.

- [ ] **Step 1: Add media-matrix tests**

Test real or disposable NTFS and exFAT destinations for initial, unchanged, changed, deleted, disconnect/reconnect, and long-path cases. On FAT32, assert normal small files work in compatibility mode and a sparse or generated file larger than 4 GiB is rejected during preflight without modifying `Latest Backup`. Use a unique temporary root and never point the suite at a customer's backup repository.

- [ ] **Step 2: Run the complete matrix on the Windows test PC**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\windows\Run-IncrementalMediaMatrix.ps1 -NtfsRoot <disposable NTFS path> -ExFatRoot <disposable exFAT path> -Fat32Root <disposable FAT32 path>`

Expected: zero failures, zero visible PowerShell windows when launched through the packaged runner, and no remaining transaction locks or staging directories.

- [ ] **Step 3: Record the phase evidence and interfaces**

In `docs/testing/incremental-phase-1.md`, record commit, package version, OS build, PowerShell version, filesystems, test counts, build artifact hash, and the exact public function/property inventory from Tasks 1–6. Do not copy user file paths or contents into the record.

- [ ] **Step 4: Run the full project verification command**

Run `npm test`, the complete Windows worker test set, and `npm run dist:win`.

Expected: every command exits 0; no Critical or Important review finding remains.

- [ ] **Step 5: Commit Task 7**

```bash
git add tests/windows/Run-IncrementalMediaMatrix.ps1 tests/windows/Run-IncrementalEngineIntegrationTests.ps1 docs/testing/incremental-phase-1.md
git commit -m "test: verify incremental engine media matrix"
```

## Phase Completion Gate

Phase 1 is complete only when the fault-injection suite proves every journal interruption recoverable, the unchanged second run copies zero user-file bytes, the legacy engine remains unchanged by default, the packaged artifact contains every new worker, and the Windows media matrix passes. Do not expose `incrementalFormatVersion: 2` in the UI or migrate a real backup drive during this phase.

After this gate, create the repository-maintenance plan against the stabilized interfaces before implementing retention.
