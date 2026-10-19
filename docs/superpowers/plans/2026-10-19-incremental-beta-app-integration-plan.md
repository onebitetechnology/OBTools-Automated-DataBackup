# Incremental Beta App Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver an explicitly enrolled, manual-only incremental backup beta through DataSafe's normal Windows update path, with truthful results and ordinary-file browsing while preserving legacy backups.

**Architecture:** Retain the qualified v2 storage engine and add a strict read-only PowerShell catalog, small Node policy/service modules, and capability-driven renderer controls. Bind destinations to actual Windows volumes, correlate every app operation, and require confirmed automation pause before enrollment. Integrate and qualify on the feature branch before any publishing workflow runs.

**Tech Stack:** Electron/CommonJS, Node's built-in test runner, Windows PowerShell 5.1 and PowerShell 7, existing NSIS/electron-builder/GitHub Actions tooling; no new runtime dependencies planned.

**Spec:** `docs/superpowers/specs/2026-10-19-incremental-beta-app-integration-design.md` (approved 2026-10-19). Read it alongside this plan and the existing core plan; this plan does not repeat or supersede storage-format decisions.

## Global Constraints

- The new-format layout remains the qualified drive-root `DataSafe Backups/<PC>/...`, not the legacy `<baseFolder>/snapshots` tree.
- Existing source choices are not silently changed.
- Keep transaction/manifests/repository schemas stable. No weaker validation or format fork to satisfy the renderer.
- This first v2 UI beta is manual-test-only. Legacy automation continues unchanged when the selected destination is legacy.
- Installation/update alone does not enable/disable schedules or register/remove tasks.
- No real task registration/deletion or installed configuration writes occur during automated development tests; mock these boundaries.
- A v2 history group is never passed to `restore-snapshot.ps1`.
- Discovery never calls repository initialization, creates a computer identity, acquires a mutation lease, repairs transactions or writes backup metadata.
- No drive formatting or repair action is added.
- Use the normal app identity and beta update channel, as requested. No separate private installer/feed is required.
- Do not overwrite the `1.0.10-beta.69` artifact or reuse a published tag.
- During development use `dist:win` (`--publish never`) or a nonpublishing verification job. Do not push to main merely to transfer files or trigger an unfinished build.
- Full point-in-time restore, retention/pruning, migration, deletion approval and merged-Public mapping are excluded. Single-tester beta acceptance does not close the original Phase-1 consumer gate.
- Preserve the existing isolated worktree and recorded core evidence. Expand fault tests only if a storage primitive changes; do not restart historical multi-hour campaigns by default.

## Review Focus

1. A different USB reuses `F:` between validation and execution: recheck `volumeUniqueId` before metadata writes and before browsing (Tasks 1, 2, 4).
2. An old asynchronous catalog/progress result arrives after a destination switch: reject it; never import another destination's success (Tasks 2, 4, 5).
3. Local identity is missing, or two same-name/duplicate-UUID PC repositories exist: read without adoption/creation; deny ambiguous mutation (Task 2).
4. Task queries fail, removal only partly succeeds, or an owned task is already running: do not claim automation is paused or enroll v2 (Tasks 3, 4).
5. A journal/current pointer is corrupt, interrupted, or accompanied by an abandoned atomic-writer temporary file: preserve qualified distinctions, do not fabricate a new commit or offer legacy Restore (Tasks 2, 4, 6).

---

## File map and shared contracts

Paths below are repository-relative; all work occurs in the existing `codex/browseable-incremental-core` worktree. Keep existing large files in place and extract only the focused seams below.

| Files | Responsibility |
| --- | --- |
| `backup-format.js`; `windows/DataSafe.AppIntegration.ps1` | Effective-format policy and app/worker boundary; PS module also hosts read-only projection helpers. |
| `windows/inspect-backup-catalog.ps1`; `backup-catalog.js` | Strict storage projection, location resolution, catalog caching and stale-response rejection. |
| `windows/manage-beta-test-tasks.ps1` | Inspect/pause only the five owned DataSafe tasks, with confirmed absence and no process termination. |
| `backup-service.js`; limited `main.js` edits | Enrollment, protected settings, operation correlation, status classification, capability-checked IPC. |
| `backup-view.js`; `app.js`; `preload.js`; `index.html`; limited `styles.css` edits | Pure view/progress projection and normal app controls; no storage parsing in renderer. |
| `windows/backup-engine.ps1`; five background entry points listed in Task 3 | Explicit-format dispatch, fresh app outcomes, manual-only enforcement. |
| `tests/*.test.js`; new `tests/windows/Run-App*.ps1`, catalog/task suites | Injected-boundary tests and disposable actual-worker integration. |
| `electron-builder.config.js`; workflow; package/version files; release checklist | Required runtime resources, nonpublishing gates, beta-only delivery and exact-artifact evidence. |

New public contracts (keep these names consistent; internal helpers remain private):

- `backup-format.js`: `getBackupFormat(config) -> 1 | 2` throws `BackupPolicyError` for unsupported values; `normalizeBackupDestination(record) -> object` preserves explicit format, volume and enrollment fields while rejecting malformed ones. Existing normalization supplies legacy defaults before using this policy.
- Destination additions: numeric `backupFormatVersion`, nonempty Windows `volumeUniqueId` for app-enrolled v2, ISO UTC `manualBetaConfirmedAt`. Enrollment produces a new destination-record UUID; it never converts the legacy record. Root `incrementalFormatVersion` is internal compatibility only when the destination lacks its own field.
- Config addition `betaTest`: `{ previousDestinationId, previousAutomation: { schedule, reminders, cloudChecks }, pausedAtUtc }`. Store copies of the existing choice objects, not only enabled booleans. Only main enrollment/settings code may write these protected fields; renderer payloads cannot forge them.
- `Catalog` envelope: `{ schema: 'datasafe.app-catalog', formatVersion: 1, destinationId, backupFormatVersion, connection, volumeMatch, state, checkedAtUtc, lastKnown, currentComputerId, latestCommittedAt, repositories, legacySnapshots, warnings }`. `state` is `checking | disconnected | identity-missing | empty | committed | recovery-required | invalid`; `connection` is `connected | disconnected`; `volumeMatch` is `true | false | null`.
- Each v2 repository: `{ computerId, computerName, ownedByCurrentComputer, state, currentManifestId, currentTransactionId, committedAt, locations, capabilities }`. `currentManifestId` is an opaque identity of the strict reader's authoritative manifest, not an exposed filesystem path. Each location: `{ locationId, label, kind: 'latest' | 'previous' | 'deleted', transactionId, partial }`. `latest` has `partial: false`; history groups have `partial: true`. No absolute paths are returned to the renderer. Capabilities explicitly name `browse`, `manualBackup`, `legacyRestore`, `manualVerify`, `automaticRetention`; v2 only permits the first two when otherwise safe, and another PC never permits `manualBackup`.
- `AppBackupResult`: `{ schema: 'datasafe.app-backup-result', formatVersion: 1, operationId, destinationId, backupFormatVersion: 2, outcome, transactionId, committedAt, recoveryAction, scanCounts, copyBytes, historyCounts, warnings, message }`. `outcome` is `committed | committed-with-warning | blocked | failed | busy`; unavailable identities/times are `null`, never manufactured. Reuse existing worker count structures, units and recovery-action values unchanged.
- App progress adds `operationId`, `destinationId`, `backupFormatVersion` to existing marker fields. A percentage from a storage phase is not a measured byte percentage.
- Run Windows suites directly from the worktree with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <suite>`; repeat new/affected PS suites with `pwsh -NoProfile -File <suite>`. Failures must produce nonzero exit codes. All fixture roots are GUID-scoped under the OS temp directory and cleanup is limited to a recorded owned root. No test uses installed app config or existing backup content.

## Task 1: Make format selection and app-worker outcomes explicit

**Files:** Create `backup-format.js`, `windows/DataSafe.AppIntegration.ps1`, `tests/backup-format.test.js`, `tests/windows/Run-AppFormatPolicyTests.ps1`. Modify `windows/backup-engine.ps1`, `tests/windows/Run-IncrementalEngineIntegrationTests.ps1`, `tests/windows/Run-IncrementalMediaMatrix.ps1` and any fixture-copy lists in `tests/windows/Run-IncrementalMediaMatrixFailureTests.ps1` that actually enumerate worker modules.

**Interfaces:** Produces the format policy and `AppBackupResult` above. PS `Get-DataSafeBackupFormat -Config <object>` matches Node precedence exactly. `Assert-DataSafeAppDestination -Config <object> -ActualVolumeUniqueId <string> -ManualBetaRun <bool>` throws before v2 initialization on invalid explicit enrollment. Worker adds `-ManualBetaRun` and `-AppOperationId <UUID>`; these do not alter existing root-flag fixture invocations. Actual volume lookup uses the resolved Windows volume identity, not drive label/letter or repository UUID.

- [ ] **Step 1: Add policy/worker regression tests.** Pin absent-to-legacy, explicit precedence, strict numeric types and metadata round trips. Include these Node assertions in named tests `format defaults and precedence` / `format rejects coercion`:

  ```js
  assert.equal(getBackupFormat({ destination: {} }), 1);
  assert.equal(getBackupFormat({ incrementalFormatVersion: 2, destination: { backupFormatVersion: 1 } }), 1);
  assert.equal(getBackupFormat({ incrementalFormatVersion: 2, destination: {} }), 2);
  for (const value of ['2', 0, 3, null]) assert.throws(() => getBackupFormat({ destination: { backupFormatVersion: value } }));
  ```

  PS named cases: `WrongVolumeBeforeWrites` compares the disposable destination's byte tree before/after; `ExplicitV2RequiresManualConfirmation` rejects missing confirmation/switch/operation UUID; `InternalFlagCompatibility` still runs the existing test path; `BusyIsFreshNonSuccess` emits a matching `busy` result even when the existing busy exit code is zero. Test unsupported merged-Public jobs and invalid format before repository creation. Define all fixture/assertion helpers locally in the new suite; actual volume lookup is a test-only injected resolver in the copied fixture, not a production bypass.
- [ ] **Step 2: Run RED.** `node --test tests/backup-format.test.js` and the new PS suite. Expect missing module/parameter/assertion failures, not a passing source-text check.
- [ ] **Step 3: Implement policy and structured app boundary.** Import the PS helper from the worker; explicit destination 2 requires valid binding/manual enrollment and an explicit manual app invocation. Compare volume again before mutation after destination resolution. Emit `__OB_RESULT__:` for every app outcome, including busy/blocked, and correlate progress. Keep legacy/root-flag behavior and transaction algorithms unchanged. Block nonmanual explicit-v2 execution before generic failure handling can overwrite existing committed status. Do not translate rollback into a new commit or discard recovery warnings.
- [ ] **Step 4: Update copied module lists and run GREEN.** Add the required helper to engine/media fixture copies and packaged hash checks; rename the brittle “seven packaged…” label to “required packaged worker/launcher hashes match source.” Missing resources must still fail. Run both new suites, `npm test`, and existing `Run-IncrementalEngineIntegrationTests.ps1` in both runtimes; require zero failures and retained independent byte/history assertions. Do not run the real-media matrix without its authorized disposable parent.
- [ ] **Step 5: Commit only Task 1 files.** `git commit -m "feat: add explicit app backup format and result protocol"` after reviewing the staged diff.

## Task 2: Provide a strict, genuinely read-only backup catalog

**Files:** Modify `windows/DataSafe.AppIntegration.ps1` and the pending-journal discovery seam in `windows/backup-engine.ps1`. Create `windows/inspect-backup-catalog.ps1`, `backup-catalog.js`, `tests/backup-catalog.test.js`, `tests/windows/Run-BackupCatalogTests.ps1`, `tests/windows/AppIntegrationTestHelpers.ps1`.

**Interfaces:** Consumes Task 1 format policy and existing Repository/Manifest/Transaction validators. PS `Get-DataSafePendingTransactionEvidence -Repository <object> -> object` shares the worker's exact qualified filename/temp/reparse rules; worker and reader call it. New script accepts `-ConfigPath`, `-StatusPath`, `-Action Inspect|InspectVolume|ResolveLocation`, optional `-ComputerId`, `-LocationId`, and emits one result marker. Inspect returns `Catalog`; InspectVolume returns `{ connected, volumeUniqueId }` from fresh Windows volume resolution without requiring enrollment. ResolveLocation returns `{ destinationId, computerId, locationId, path }` privately to main after fresh volume/layout/reparse validation. `createBackupCatalogReader({ inspectLegacy, runReadOnly, now })` exposes async `refresh(config, { force = false } = {}) -> Catalog`, synchronous `peek(destinationId) -> Catalog | null`, and async `resolveLocation(config, { computerId, locationId }) -> object`. Calls to `runReadOnly(action, config, identifiers) -> Promise<object>` use the script protocol, not Node raw-metadata parsing.

- [ ] **Step 1: Add read-only and asynchronous tests.** `New-AppFixture` in the shared PS test helper returns GUID-owned `Root`, `Bin`, `Source`, `Destination`, `ConfigPath`, `StatusPath`; it copies required modules and only shims destination/volume lookup into that fixture. `Remove-AppFixture` verifies every cleanup target is beneath its recorded root. In catalog tests assert a sorted path/type/content-hash inventory is identical before/after reading, including missing-local-identity and recovery-required fixtures. Cover legacy/v2 coexistence, same-name PCs, duplicate UUIDs, foreign ownership, absent/corrupt current pointer/manifest, unknown objects, reparse replacement, valid pending journal, exact abandoned writer-temp warnings, and malformed journal names. Missing identity returns `identity-missing`, not a generated ID. A valid single pending transaction can permit an explicit owned manual recovery run; invalid/ambiguous state cannot.

  Node tests `coalesces refresh` and `drops stale destination response` use controlled promises: two same-generation refreshes invoke `runReadOnly` once; destination B remains selected after delayed A resolves. `disconnected catalog is last known` asserts `lastKnown === true` with no integrity-pass claim. Foreign/ambiguous repositories assert `manualBackup === false`. Cached reads cannot authorize location opens.

  ```js
  assert.equal(disconnectedCatalog.lastKnown, true);
  assert.equal(foreignRepository.capabilities.manualBackup, false);
  assert.equal(missingIdentityCatalog.currentComputerId, null);
  assert.deepEqual(treeAfterRead, treeBeforeRead);
  ```
- [ ] **Step 2: Run RED.** `node --test tests/backup-catalog.test.js` and `Run-BackupCatalogTests.ps1`; expect missing reader/entry point and real behavioral failures.
- [ ] **Step 3: Implement shared strict projection.** Extract pending-discovery logic without weakening it. Use existing strict repository, current-pointer and manifest readers; do not initialize/recover/lock-for-mutation in Inspect. Treat unknown/corrupt relevant entries as attention states, not successful empty history. Read other PCs without adopting them. Use opaque catalog-derived location identifiers, no renderer-supplied path segments. Validate containment and every relevant reparse boundary again on ResolveLocation; reject changed volume/layout. Refresh on startup/destination/manual/completion only; timer polling reads cache. Generation checks prevent stale response publication.
- [ ] **Step 4: Run GREEN.** New Node/PS suites in both runtimes, existing engine integration and the existing focused abandoned-atomic-writer/recovery cases covering the extracted seam. Record exact commands/results; do not claim a fresh full historical fault campaign. Require byte-level read-only equality and no local identity creation.
- [ ] **Step 5: Commit Task 2 files.** `git commit -m "feat: expose validated read-only backup catalogs"`.

## Task 3: Enforce confirmed manual-only beta operation

**Files:** Create `windows/manage-beta-test-tasks.ps1`, `tests/windows/Run-BetaAutomationTests.ps1`. Modify `windows/DataSafe.AppIntegration.ps1`, `windows/install-scheduled-backup.ps1`, `windows/check-backup-catchup.ps1`, `windows/check-reminders.ps1`, `windows/verify-backup-integrity.ps1`, `windows/check-cloud-health.ps1`. Do not modify unrelated task behavior.

**Interfaces:** `manage-beta-test-tasks.ps1 -Action Inspect|Pause -ConfigPath <path> -StatusPath <path> -ScriptRoot <path> [-Confirmed]` returns `{ confirmedPaused, tasks, warnings }` through the result marker. Each task record includes name, ownership, running/enabled/absent state and query/removal errors. Exact managed names: `OneBiteBackupRun`, `OneBiteBackupCatchUp`, `OneBiteBackupReminder`, `OneBiteBackupIntegrity`, `OneBiteBackupCloudHealth`. PS `Test-DataSafeManualBetaConfig -Config <object> -> bool` means effective explicit destination format 2, not the root-flag fixture compatibility path. Task 4 consumes confirmation; it owns saved prior choices.

- [ ] **Step 1: Add mocked-task tests.** Named cases: `InspectNeverMutates`, `PauseRequiresConfirmation`, `AllOwnedTasksAbsent`, `QueryDeniedIsNotAbsent`, `ForeignTaskNeverRemoved`, `PartialRemovalBlocksEnrollment`, `RunningTaskBlocksEnrollment`, `TransitionLockBusyBlocksPause`, `EveryBackgroundEntryPointRefusesV2`, `LegacyActionsUnchanged`. Override scheduled-task cmdlets and launch boundaries inside the test process; never call real registration/deletion. Assert absent only after a successful query distinguishes not-found from permission/other errors. Assert zero backup/verify/cloud/reminder launches and unchanged fixture status for guarded explicit-v2 paths. Confirm legacy task arguments and enablement remain unchanged.

  ```powershell
  if ($queryDeniedResult.confirmedPaused -ne $false) { throw 'Denied task query must block enrollment' }
  if ($foreignTaskRemovalCalls.Count -ne 0) { throw 'Foreign task was modified' }
  if ($v2BackgroundLaunchCalls.Count -ne 0) { throw 'Manual-only background guard failed' }
  ```
- [ ] **Step 2: Run RED.** Run `Run-BetaAutomationTests.ps1` in Windows PowerShell; expect missing helper and guard assertions to fail.
- [ ] **Step 3: Implement inspect/pause and all entry-point guards.** Match task ownership by expected principal, script action and exact quoted config/status arguments; refuse ambiguous/foreign tasks. During confirmed pause hold the existing status-operation lock, disable future owned triggers, refuse to proceed while any owned task is running, remove only owned tasks, then positively requery absence. Do not kill workers; failures leave an actionable partial-pause result, not enrollment permission. Never pause merely by installing/updating or switching destinations. The installer must not register explicit-v2 automation; backup-engine's Task 1 gate prevents stale direct launches. Other helpers return an explicit unsupported/skipped result before any legacy status/snapshot action.
- [ ] **Step 4: Run GREEN.** New suite in both PS runtimes plus `Run-HotfixRegressionTests.ps1` and `Run-IncrementalFinalRegressionTests.ps1` for affected task/launcher/safety boundaries. Require no OS task writes. Document which guards execute before side effects; do not mistake printed warning text for proof of skipped work.
- [ ] **Step 5: Commit Task 3 files.** `git commit -m "feat: gate incremental beta behind confirmed manual operation"`.

## Task 4: Integrate protected enrollment and authoritative operations in main

**Files:** Create `backup-service.js`, `tests/backup-service.test.js`, `tests/app-ipc.test.js`. Modify `main.js`, `backup-format.js`, `backup-catalog.js` only at their defined policy seams.

**Interfaces:** `createBackupService(ports)` exposes `getState({ refresh = false } = {}) -> Promise<BackupAppState>`, `enrollIncrementalTest({ destinationId, confirmedManualTesting, confirmedLimitations }) -> Promise<BackupAppState>`, `runBackup({ allowNewDestination = false } = {}) -> Promise<BackupAppState>`, `openLocation({ destinationId, computerId, locationId }) -> Promise<{ opened: boolean, message: string }>`, and `saveConfig(candidate) -> Promise<BackupAppState>`. `BackupAppState` is `{ catalog, lastAttempt, lastCommitted, activeOperation }`; `lastAttempt` is an `AppBackupResult` plus `attemptedAt`, `lastCommitted` is `{ destinationId, transactionId, committedAt }`, and `activeOperation` is `{ operationId, destinationId, backupFormatVersion, startedAt, phase }`; absent records are `null`. Main merges this projection into its existing app state rather than replacing unrelated state fields.

Inject ports `readConfig() -> Promise<object>`, `writeConfig(config) -> Promise<void>`, `readStatus() -> Promise<object>`, `writeStatus(status) -> Promise<void>`, `catalogReader`, `runWorker`, `taskControl`, `getVolumeIdentity`, `openPath(path) -> Promise<string>`, `publish(event) -> void`, `now() -> Date`, `newId() -> UUID string`; tests provide all of them. `runWorker({ config, operationId, manualBetaRun, allowNewDestination, onProgress }) -> Promise<{ ok, code, message, data }>` wraps existing `runPowerShell`. `taskControl(action, config, confirmed) -> Promise<TaskPauseResult>` uses Task 3. `getVolumeIdentity(config) -> Promise<{ connected, volumeUniqueId }>` invokes Task 2's uncached InspectVolume action, independently of worker mutation. `publish(event)` carries destination/operation identity. Legacy operations retain the existing path.

New IPC: `beta:enroll-incremental`, `backups:refresh`, `backups:open-location`. Existing `backup:run`, `state:get`, `config:save`, `restore:plan`, `restore:run` become format/capability aware. Keep preload API mapping in Task 5. No IPC accepts arbitrary restore format, raw browse path, volume identity or manual confirmation timestamp as authority.

- [ ] **Step 1: Add service and mocked-Electron boundary tests.** Pin `enrollment preserves legacy and source choices`, `same volume cannot acquire duplicate v2 target`, `unconfirmed or failed pause leaves legacy selected`, `volume swapped during pause blocks enrollment`, `renderer cannot forge enrollment`, and `switching back never resumes automation`. Distinct same-volume v1/v2 record IDs survive normalization/config round trip. Fake Electron IPC tests invoke the actual registered handlers with isolated config and mocked spawn/shell/task ports, not only regex assertions. Assert forged v2 restore requests never invoke `restore-snapshot.ps1`; traversal/reparse/stale-location opens never call shell.

  Operation tests: busy exit zero is not success; mismatched operation/destination results are ignored; failed attempt preserves committed timestamp; committed-with-warning remains attention; rollback preserves old commit; unchanged commit does not add a snapshot; finalization requires matching authoritative catalog transaction/time. Stage progress at 100 does not emit finished success. Delayed completion after destination change cannot overwrite the new view. Config save cannot re-enable automation for v2 or copy the internal root flag onto an unformatted destination.

  ```js
  assert.equal(afterFailedAttempt.lastCommitted.committedAt, beforeAttempt.lastCommitted.committedAt);
  assert.equal(afterFailedAttempt.lastAttempt.outcome, 'failed');
  assert.equal(restoreWorkerCalls.length, 0); // forged v2 restore request
  assert.equal(shellOpenCalls.length, 0); // stale/substituted location request
  ```
- [ ] **Step 2: Run RED.** `node --test tests/backup-service.test.js tests/app-ipc.test.js`; expect missing service and current unsafe legacy reconciliation/IPC assumptions to fail.
- [ ] **Step 3: Implement service enrollment/settings boundary.** Serialize enrollment/config/run operations. Inspect and display previous automation choices; only explicit confirmation performs pause. Save `betaTest` and new v2 record only after confirmed pause, unchanged config revision, current volume identity and compatible enabled sources; otherwise retain legacy selection and surface partial pause honestly. Preserve both known records and protect format/binding/confirmation fields from generic renderer writes. An explicit return-to-legacy can offer saved prior choices for a separate settings confirmation; never restore choices/tasks automatically. Reject duplicate local v2 target per volume regardless of legacy base-folder text.
- [ ] **Step 4: Implement main operation/IPC adapter.** Add optional `onProgress` callback to `runPowerShell(scriptName, extraArgs = [], options = {})` while preserving legacy default publishing. Route explicit v2 through the service, require fresh matching worker result, refresh catalog and compare committed transaction/time before classifying success. Preserve all worker fields; separate last attempt from last committed record. Hold worker `complete` progress until catalog verification. Allow recovery of a single validated owned pending transaction through the worker; invalid/ambiguous identity stays blocked. Use format-specific reconciliation; the 30-second status watcher must not launch catalog PS or replace v2 data with legacy snapshots. Recheck selected catalog/volume before open; keep resolved path main-only. Main restore/manual-verify/task-install paths fail closed for v2, including forged IPC.
- [ ] **Step 5: Run GREEN.** `node --test tests/backup-format.test.js tests/backup-catalog.test.js tests/backup-service.test.js tests/app-ipc.test.js` then `npm test`. All fixture configs remain separate from installed app data. Review failure persistence and serialization behavior with controlled races.
- [ ] **Step 6: Commit Task 4 files.** `git commit -m "feat: integrate safe incremental beta operations in Electron main"`.

## Task 5: Add clear beta controls, truthful progress and browse-only history

**Files:** Create `backup-view.js`, `tests/backup-view.test.js`. Modify `preload.js`, `app.js`, `index.html`, `styles.css` only as needed, `server.js` preview capability boundary, `electron-builder.config.js` runtime allowlist.

**Interfaces:** UMD `backup-view.js` exports to CommonJS and `window.DataSafeBackupView`: `projectBackupView({ config, catalog, lastAttempt, activeOperation, now }) -> object`, `projectBackupProgress({ operation, progress, now }) -> { label, elapsedSeconds, indeterminate, percent, etaSeconds }`. V2 `etaSeconds` is `null` unless real measured transferred-byte/rate fields exist; this slice adds no such measurement. Preload exposes `enrollIncrementalTest(request)`, `refreshBackups()`, `openBackupLocation(request)` mapped to Task 4 IPC. Reuse existing state/progress subscriptions with destination/operation filtering; no raw location paths.

- [ ] **Step 1: Add behavioral view tests.** `v2 phases have elapsed time but no guessed ETA` asserts `etaSeconds === null` and `indeterminate === true` for phase-only progress, even after 20 minutes/90 phase percent. `partial history is not a dated complete snapshot` asserts history labels and `partial` explanations; `unchanged result does not increase snapshot count` asserts no fabricated count. Cover saved-with-warning, rollback, failed attempt with retained last commit, last-known/disconnected labels, source-Public refusal, another-PC read-only, storage estimate explicitly uncalculated, disabled verify/retention/assisted restore. VM/DOM-stub tests exercise actual renderer handlers and preload channel bindings with injected APIs: forged/stale events cannot change view; v2 cannot invoke restore; legacy still previews/restores through existing APIs. Preview mode offers no real v2 enrollment/backup/open action and cannot report a simulated v2 run as real success.

  ```js
  assert.equal(v2PhaseView.etaSeconds, null);
  assert.equal(v2PhaseView.indeterminate, true);
  assert.equal(previousVersionLocation.partial, true);
  assert.equal(latestBackupLocation.partial, false);
  ```
- [ ] **Step 2: Run RED.** `node --test tests/backup-view.test.js tests/app-ipc.test.js`; require behavioral failure before changing renderer.
- [ ] **Step 3: Implement view module and app bindings.** Add a destination-specific “Start incremental beta test” action showing actual volume, future drive-root layout, existing automation choices and manual/browse-only limitations. Require both confirmations and compatible sample-source choices; do not silently alter jobs. Label coexisting destination records Legacy/Incremental. Display Latest Backup as complete and Earlier Versions as partial changed/deleted history. Open by trusted IDs; separate current/other PCs. Keep legacy Restore available when its validated legacy destination is selected. Show an explicit disabled explanation for v2 Verify/assisted restore/automatic retention, not legacy estimates or settings masquerading as v2 support. Use plain phases from the spec and “no file content needed copying” for unchanged results; never claim no verification I/O. Failures do not animate success/100%.
- [ ] **Step 4: Wire resources and run GREEN.** Load `backup-view.js` before `app.js`; explicitly allowlist `backup-format.js`, `backup-catalog.js`, `backup-service.js`, `backup-view.js` in builder. Browser preview rejects unsupported v2 mutation routes and retains its legacy simulation disclosure. Run new tests and `npm test`. Review screen copy against all beta limitations; native installed-app visual acceptance remains Task 8, not a claimed automated screenshot pass.
- [ ] **Step 5: Commit Task 5 files.** `git commit -m "feat: add incremental beta enrollment and browseable history UI"`.

## Task 6: Prove actual worker-to-app behavior on disposable files

**Files:** Create `tests/windows/Run-AppIntegrationTests.ps1`, `tests/app-worker-integration.test.js`; extend `tests/windows/AppIntegrationTestHelpers.ps1`, `tests/app-ipc.test.js` only for shared fixtures and legacy regression. Modify no qualified storage primitive merely to make tests easier.

**Interfaces:** `Run-AppIntegrationTests.ps1 [-WorkerRoot <path>]` invokes the actual copied worker/catalog scripts through a Node service harness; default source is this checkout, packaged smoke supplies extracted packaged `windows` directory. New Node test harness consumes `DATASAFE_APP_FIXTURE_CONFIG`, `DATASAFE_APP_FIXTURE_STATUS`, `DATASAFE_APP_FIXTURE_BIN`, `DATASAFE_APP_FIXTURE_ROOT` only when the PS suite supplies all four. Standalone Node test discovery skips the actual-worker case explicitly if unset; CI must run the PS wrapper, so skips are not qualification. Task APIs remain mocked. The helper restricts source/destination/cleanup to owned fixtures.

- [ ] **Step 1: Add independent acceptance oracles.** Named cases: `InitialCreatesBrowseableLatest`, `UnchangedCopiesZeroContent`, `ChangedPreservesPreviousBytes`, `DeletedPreservesDeletedBytes`, `ReadOnlyBrowseDoesNotChangeTree`, `UnavailableDrivePreservesCommit`, `UnavailableSourceAndDeletionReviewRefuseNewCommit`, `RecoveryWarningRemainsSavedWithAttention`, `InterruptedRollbackIsNotNewBackup`, `SameLetterWrongVolumeCannotWrite`, `LegacyRestoreStillUsesLegacyCatalog`. Compare actual source/Latest/history bytes, independently reread strict current pointer/manifest, and assert service events/time/counts match. A subprocess exit or status JSON alone is never the content oracle. Add stale operation/catalog interleaving in the actual harness and verify no foreign success. Forced faults use existing test-only process/fixture boundaries, not a production bypass or drive unplug automation.

  ```js
  assert.equal(unchangedResult.copyBytes, 0);
  assert.deepEqual(latestBytes, sourceBytes);
  assert.deepEqual(previousVersionBytes, originalBytes);
  assert.deepEqual(deletedVersionBytes, deletedSourceBytes);
  ```
- [ ] **Step 2: Run RED.** New PS wrapper in Windows PowerShell before implementing its Node process/fixture adapter. Expect failure at that missing integration seam, then implement it. Individual component tests already passing is expected; do not alter qualified storage behavior to manufacture a failure.
- [ ] **Step 3: Complete integration seams found by the suite.** Limit fixes to Task 1–5 boundaries. Any required primitive change is a reviewed scope escalation with explicit covering fault/recovery tests and updated evidence, not an incidental test workaround. Preserve original fixture compatibility and v1 status/restore behavior.
- [ ] **Step 4: Run GREEN and record focused regressions.** Run new PS wrapper in both runtimes, `npm test`, all new PS suites, existing engine integration and affected Safety/Recovery/launcher suites. List exact pass/fail/skip counts and source commit. Do not repeat old 124-case/20-repeat campaigns without diff-based need or relabel old results. Real FAT32/exFAT requires the operator-authorized disposable-parent workflow; no existing backup data is touched.
- [ ] **Step 5: Commit Task 6 files/focused fixes.** `git commit -m "test: qualify app-connected incremental backup workflows"`.

## Task 7: Qualify nonpublishing packaging and isolate beta metadata

**Files:** Modify `.github/workflows/build-windows-installer.yml`, `electron-builder.config.js`, `package.json`, `package-lock.json` only when the release version is chosen. Create `tests/release-policy.test.js`, `docs/release/incremental-beta-checklist.md`, `tests/windows/Test-AppPackage.ps1` with `-PackagedRoot <path> -SourceRoot <path>` (read-only hash/resource/load checks).

**Interfaces:** The Windows workflow has a nonpublishing verify/build path (including main pushes) and a separately approved `publish-qualified` dispatch taking the verified build's run ID and source SHA. Verify/build runs Node plus Task 1/2/3/6 PS suites and affected engine tests before building, then stores its installer, beta metadata and hash/source manifest as one immutable CI artifact. Publish-qualified downloads that artifact and checks run/SHA/hash; it does not rebuild. `Test-AppPackage.ps1` asserts every required JS module is present/loadable with Electron's packaged resolution and every required PS/VBS resource matches the recorded source bytes; it does not execute installed-user configuration. Packaged smoke calls Task 6 with extracted packaged resources.

- [ ] **Step 1: Add release-policy regressions.** Assert beta config cannot generate/upload `latest.yml` or stable metadata; stable configuration keeps its existing channel behavior. Assert required new runtime modules/resources are packaged and any omitted helper fails comparison. Workflow tests verify PS integration gates run before build/publish and `dist:win` remains `--publish never`. Use config evaluation/structured workflow checks and artifact inspection, not only matching a “beta” label.

  ```js
  assert.equal(betaBuilderConfig.generateUpdatesFilesForAllChannels, false);
  assert.equal(betaBuilderConfig.appId, 'ca.onebitetechnology.backupcompanion');
  assert.equal(betaBuilderConfig.win.publish[0].channel, 'beta');
  assert.equal(betaArtifactNames.includes('latest.yml'), false);
  ```
- [ ] **Step 2: Run RED.** `node --test tests/release-policy.test.js`; existing all-channel beta metadata behavior must fail the new isolation assertion.
- [ ] **Step 3: Implement nonpublishing gates and exact-artifact release flow.** Disable all-channel metadata generation for beta; preserve stable release behavior. Replace unconditional publish-on-main with the explicit verify/build versus publish-qualified modes above, without changing app identity or making a new feed. Make creating/reusing release assets exclusive to publish-qualified; refuse an existing conflicting tag/asset rather than overwrite it. Add a read-only remote-main/tag/version preflight and record the Mac project's actual current source/version from an accessible checkout or operator evidence. Reconcile newer changes on a feature branch; never reset Mac/local work. Choose an unused higher beta version only after this check and update lockfile consistently. If Mac/remote access or signing/publishing credentials are unavailable, prepare a precise handoff and stop the affected release step; do not pretend coordination occurred or send another chat a message without user authorization.
- [ ] **Step 4: Run GREEN without publishing.** Run `npm ci`, `npm test`, required PS gates and `npm run dist:win` in the nonpublishing Windows verify/build job. Inspect unpacked resources, run package equality checks and disposable NTFS packaged smoke before retaining that job's exact artifact for publication. A local development build is permitted but is not substituted for the CI-qualified artifact. Record source commit, CI run ID, exact commands/results, installer filename/version/SHA-256 and bundle equality in the checklist. Keep known external qualifications (real exFAT, physical in-flight interruption, production performance, installed UI, Mac reproduction) pending unless actually performed. This is a new artifact; do not overwrite October 17–18 evidence.
- [ ] **Step 5: Commit Task 7 files and request whole-branch review.** `git commit -m "build: qualify incremental beta packaging and channel isolation"`. Use the previously approved independent review workflow; resolve actionable findings with focused tests. No main push or publishing dispatch in this task. Present the reviewed release candidate, exact test evidence, remaining limitations and release action for approval.

## Task 8: Publish the approved beta and guide installed-app acceptance

**Files:** Update `docs/release/incremental-beta-checklist.md` with release evidence and acceptance results; add release notes through the existing release mechanism only after the publishing gate below. No storage-format changes.

**Interfaces:** Consumes Task 7's reviewed candidate, exact artifact/hash and publishing approval. Produces a normal beta release/update with stable feed unchanged, followed by honestly recorded operator acceptance; publication alone is not app acceptance.

- [ ] **Step 1: Check release prerequisites.** Confirm actual remote/source reconciliation, unused tag/version, green required tests, no unresolved blocker, normal beta channel and approved exact release action. Snapshot existing stable/latest metadata hashes before publishing. If any approval, credential, artifact or Mac-build handoff is missing, report the exact blocker; do not bypass by inventing another channel or triggering main prematurely.
- [ ] **Step 2: Publish once through the approved workflow.** Publish the already qualified installer and its matching beta metadata. Verify downloaded release asset SHA-256 equals Task 7, beta metadata references that asset/version, and stable/latest metadata hashes remain unchanged. Preserve installer/source/release evidence. Release notes disclose manual-only enrollment, browse/copy recovery, no v2 assisted restore, retention or migration. Rollback is an explicit known installer/new beta after preserving settings, not rewriting v2 storage or promising safe old-app writes.
- [ ] **Step 3: Guide Jeff through the real app update.** Check for updates → Download → Install, then confirm installed version, retained legacy settings/history and no unrequested task changes. This uses the normal app and identity. Obtain explicit setup confirmation inside the new enrollment UI before it pauses tasks; development-time permission is not a substitute for this app action.
- [ ] **Step 4: Run operator acceptance in small steps.** Use a compatible custom sample folder and explicitly selected test USB. Enroll; run initial backup; open Latest from app; repeat unchanged and inspect zero-copy result; change/delete samples and browse partial previous/deleted history; disconnect between runs and reconnect; switch to legacy and test its safe restore preview/fixture restore. Observe extra terminal-window flashes separately; ask Jeff for observations where native UI cannot be inspected. Do not unplug during an active real-data backup or claim in-flight qualification from between-run removal. Do not resume old schedules automatically.
- [ ] **Step 5: Record the result and hand off remaining work.** Save exact installed version, sample test results, operator observations, limitations and failures in the checklist; commit docs. If acceptance fails, diagnose with logs and narrowly scoped fixes/new beta rather than erasing test evidence. Only declare “ready for your sample-data testing” after Task 7, and only declare installed-app acceptance passed after Task 8's actual checks. Separate subsequent restore/retention/automation/performance projects from this beta.

## Self-review and execution handoff

- Spec 1 → Tasks 1/4/5; spec 2 → Task 2/4; spec 3 → Tasks 1/4/5; spec 4 → Tasks 2/4/5; spec 5 → Tasks 1/3/4/5; spec 6 → all component boundaries; spec 7 → Tasks 7/8; spec 8 → Tasks 1–8 automated/operator gates.
- Five Review Focus conditions each have owning tests above. Legacy/root-flag compatibility, Public-job refusal, volume binding, read-only identity, protected IPC, partial history, no fake ETA, manual automation and exact artifact/feed isolation have explicit assertions/gates.
- Public interface names/envelopes are defined once above and consumed consistently. Keep existing engine count/recovery structures rather than inventing a second storage schema.
- Each task produces a testable policy, reader, guard, service, view, integration suite or release gate; no setup-only task. Favor signatures/assertions over writing implementation bodies in this plan.
- Preserve Jeff's previously approved subagent/review execution approach. Written-plan review is required before Task 1; approving the design alone is not that gate. No product implementation, dependency installation, publishing or real app/task mutation was performed while drafting this plan.
