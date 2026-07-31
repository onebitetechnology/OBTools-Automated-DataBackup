# Data Protection And Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make DataSafe's restore, scheduling, status, preview, and release paths accurately enforce the safety guarantees shown to customers.

**Architecture:** Keep backup-format assertions in `windows/DataSafe.Safety.ps1`, where both backup and restore can use them. Let the snapshot manifest retain immutable recovery metadata, while the renderer and Electron shell consume that record only for selected-snapshot recovery. Harden the local preview and release workflow without exposing production behavior through the browser server.

**Tech Stack:** Electron, Node.js built-in test runner, PowerShell, GitHub Actions, NSIS/electron-builder.

## Global Constraints

- The product is Windows desktop only; the Mac browser server remains a local visual preview.
- A restore must fail closed when snapshot integrity, path containment, or current-job identity cannot be proven.
- Provider API health and code signing remain explicitly unavailable until credentials are supplied.
- Every changed behavior has a regression test or an executable parser/smoke check.

---

### Task 1: Verify Closed Snapshot Trees

**Files:**
- Modify: `windows/DataSafe.Safety.ps1`
- Modify: `tests/backup-safety.test.js`

**Interfaces:**
- Produces: `Test-DataSafeIntegrityIndex -SnapshotPath <path> -RelativePrefix <path>` rejects unindexed files and duplicate/unsafe index records.

- [x] Add a test fixture containing a valid completion record, a valid integrity entry, and an extra file beneath the selected item.
- [x] Run the test against the current PowerShell module and confirm it accepts the extra file before the implementation.
- [x] Compare the actual non-metadata file tree beneath the requested prefix with the index map and reject extras.
- [x] Re-run the fixture and the full Node test suite.

### Task 2: Protect Historical Restore And Concurrent Operations

**Files:**
- Modify: `windows/DataSafe.Safety.ps1`
- Modify: `windows/backup-engine.ps1`
- Modify: `windows/restore-snapshot.ps1`
- Modify: `tests/backup-safety.test.js`

**Interfaces:**
- Produces: snapshot manifest job records contain source path and restore-relevant metadata.
- Produces: restore can resolve a snapshot record; original mode requires an unchanged current job.
- Produces: `Acquire-DataSafeOperationLock` and `Release-DataSafeOperationLock` protect mutating backup and restore actions.

- [x] Add failing fixtures for alternate targets under the source or repository, missing current jobs, and changed original paths.
- [x] Add manifest job metadata and resolve the selected item from the completed manifest.
- [x] Reject unsafe alternate destinations and require a matching active job for original mode.
- [x] Move the existing backup lock helpers into the shared safety module and hold the same lock for restore actions.
- [x] Verify with PowerShell tests, parser checks, and backup test suite.

### Task 3: Repair Status, Preview, And Lifecycle Claims

**Files:**
- Modify: `windows/check-backup-catchup.ps1`
- Modify: `windows/check-cloud-health.ps1`
- Modify: `main.js`
- Modify: `app.js`
- Modify: `server.js`
- Modify: `tests/backup-safety.test.js`

**Interfaces:**
- Produces: catch-up considers the most recent completed snapshot time, even when retention warned.
- Produces: cloud status level is `info`, `warning`, or `error` and its summary describes local configuration only.
- Produces: preview server binds to loopback and only serves normalized in-root static paths.

- [x] Write failures for a recent warning-status backup being marked due and for preview paths escaping `assets`.
- [x] Change the catch-up and cloud-state rules with user-facing wording that does not imply provider verification.
- [x] Make preview-server asset resolution containment-safe and bind `127.0.0.1`.
- [x] Re-run tests and perform an HTTP smoke check against the local preview.

### Task 4: Release Guardrails

**Files:**
- Modify: `electron-builder.config.js`
- Modify: `.github/workflows/build-windows-installer.yml`
- Modify: `README.md`

**Interfaces:**
- Produces: uninstall preserves DataSafe recovery data unless a future explicit migration/removal flow changes it.
- Produces: CI runs tests before build/publish and records signing inputs as an enforced release prerequisite when configured.

- [x] Change NSIS uninstall behavior to preserve app data.
- [x] Add tests before packaging and publishing; build once and upload the published artifact.
- [x] Document the Windows certificate secret inputs and update verification requirements.
- [x] Validate workflow YAML and run local tests/parsers.
