# DataSafe Functional Readiness Review

Review date: 2026-07-10
Safety implementation update: 2026-07-28

This review is based on the current Electron, JavaScript, and PowerShell implementation. The July 28 safety changes were parsed with PowerShell 7.6.4 on macOS, and the cross-platform identity, manifest, checksum, and tamper-detection functions were exercised with disposable data. Windows-only behavior involving Robocopy, drive letters, Scheduled Tasks, notifications, and live restores still requires the Windows pilot matrix before release.

## Executive assessment

DataSafe now has a substantially safer backup contract in code: staged snapshots, completion metadata, drive identity enforcement, capacity and media preflight, SHA-256 integrity records, post-commit retention, restore planning, rollback copies, and restore journals. It is not yet safe to market as a dependable backup product until those paths pass destructive Windows testing and the remaining VSS, recovery-browser, cloud-health, legal, reseller, and licensing work is completed.

| Capability | Current state | Release assessment |
| --- | --- | --- |
| Copy selected files and folders | Transactional staged snapshot with destination read-back checksums | Windows destructive testing required |
| Scheduled backups | Implemented with Windows Scheduled Tasks | Runs with an interactive user principal; Windows testing required |
| Missed backup and missing-drive warnings | Implemented | Useful, but health coverage is incomplete |
| Full or corrupt destination detection | Preflight free-space reserve, write/read probe, per-file checksums, weekly scrub | Does not replace filesystem diagnostics; Windows testing required |
| Cloud backup detection | OneDrive presence, account, process, roots, and known-folder location only | Partial and currently overstates confidence |
| Dropbox, Google Drive, Backblaze | Not implemented | Provider adapters required |
| Browse backup contents | Snapshot and job selection only | No safe file browser yet |
| Restore to alternate folder | Checksum verified and always restored to a new unique folder | Windows testing required |
| Restore to original location | Dry-run conflict report, verified safety copy, journal, automatic rollback | Windows testing and per-file policy work remain |
| Terms acceptance | Version and acceptance timestamp stored locally | Text and acceptance evidence need legal hardening |
| Terms review in Settings | Implemented in this review | Uses the same source text as the opening gate |
| Reseller branding | Customer-editable local settings | Must move to a signed deployment profile |
| Licensing | UI scaffolding exists but normalization forces it off | No enforcement or license service exists |

## Priority findings

### P0 addressed in code: Failed or incomplete snapshots can be presented as usable

Prior risk: files were copied directly into a timestamp-named snapshot directory. There was no staging name, completion marker, manifest, or atomic commit, and any timestamp directory was treated as a snapshot.

The Electron handler also treated a failed run as a partial success whenever any older snapshot existed. That could overwrite the PowerShell error state and display an earlier snapshot as the latest outcome.

Implemented July 28:

1. Backups write to a hidden `.incomplete-...` staging folder.
2. Copied files are read back and recorded in `.datasafe-integrity.jsonl` with size, timestamp, and SHA-256.
3. `.datasafe-manifest.json` records the snapshot, jobs, totals, machine, install, and destination.
4. `.datasafe-complete.json` records hashes of the manifest and integrity index.
5. The staging folder is renamed to its final timestamp only after metadata is complete.
6. Electron, retention, integrity checks, and restore list only snapshots with valid completion metadata.
7. The Electron `partialSuccess` fallback was removed; an older snapshot can no longer downgrade a failed run.

Existing pre-hardening timestamp folders do not have completion metadata. They are excluded from current backup and restore lists and surfaced as unverified rather than silently certified.

### P0 addressed in code: Scheduled backups bypass destination continuity protection

Prior risk: the app checked destination markers before a manual backup, but Windows Scheduled Tasks invoked `backup-engine.ps1` directly. The PowerShell script could resolve a drive letter and begin copying before writing a marker.

A different drive reusing the expected letter can therefore receive a scheduled backup without the app's confirmation flow.

Implemented July 28: `windows/DataSafe.Safety.ps1` now validates the install and destination IDs before any backup write. Scheduled and catch-up runs cannot initialize a markerless drive. A new destination must be confirmed and initialized by a manual app backup, and mismatched or corrupt markers are never overwritten automatically.

### P0 addressed in code: Original-location restore can overwrite good data

Prior risk: the UI gave two confirmations, but folder and file restore could replace existing files without a per-file plan, integrity check, rollback set, or conflict report.

Implemented July 28:

1. Alternate-folder restore remains the default and always chooses a new unique folder.
2. A dry-run plan counts new, identical, conflicting, and newer-current files.
3. The selected snapshot and backup item are checksum verified before restore.
4. Original-location restore copies the existing target to `restore-safety`, verifies that copy, and records a journal before replacement.
5. A failed original restore automatically attempts rollback; a failed alternate restore removes its incomplete output.
6. Licensing remains separate and does not gate restore.

Remaining: whole-item restore currently offers safe alternate restore or full original replacement with rollback. Per-file `keep both`, `skip`, and selective-replace policies still belong in the future Recovery Browser.

### P1 addressed in code: Retention deletes history before the new snapshot succeeds

Prior risk: retention pruning ran before any backup item was copied and again afterward. A failed backup could delete older snapshots without producing a new valid one.

Implemented July 28: retention runs only after the staged snapshot is committed, only completion-validated snapshots are eligible for pruning, and the newest known-good snapshot is always retained.

### P1 partially addressed: The two backup copies are not guaranteed to match

The engine no longer writes both `current` and a dated snapshot. Each source is copied once into the staged snapshot, reducing source churn and destination capacity. Existing legacy `current` folders are left untouched rather than deleted automatically.

Remaining: Volume Shadow Copy Service is still needed for a consistent point-in-time view of open or rapidly changing files, especially PST files and application profiles.

### P1 addressed in code, Windows validation required: Capacity and corruption checks are incomplete

Prior risk: storage analysis reported one source-size estimate while the engine wrote both `current` and full dated snapshots. The displayed estimate could be materially lower than the real requirement.

The engine also recognized a full disk only after Robocopy failed and did not perform a write test, manifest verification, checksum scrub, or destination read-back.

Implemented July 28:

1. The UI and engine estimate one snapshot plus a 10% or 256 MB minimum reserve.
2. The engine blocks the run before copying when free space is insufficient.
3. A 64 KB random probe is written with write-through, flushed, read, byte-compared, and removed.
4. Every copied file receives a SHA-256 integrity record.
5. A weekly Sunday integrity task fully verifies the newest completed snapshot.
6. Integrity failures update app and tray health and generate a Windows warning.

Remaining: add explicit filesystem diagnostics and typed health incidents for low space, read-only media, and volume-level corruption. A successful probe and checksum scrub do not replace tools such as Windows filesystem diagnostics.

### P1: Cloud health is OneDrive-only and not authoritative

The current script checks whether OneDrive is installed, whether registry accounts and sync roots exist, whether the process is running, and whether Desktop and Documents live inside those roots (`windows/check-cloud-health.ps1:77-239`). It does not verify that files reached the cloud or that OneDrive reports no sync errors.

It currently ends with the statement that OneDrive appears to be protecting the folders. That should be softened to `Configured and running; cloud completion not independently verified` unless stronger evidence is available.

Provider plan:

| Provider | Safe local checks | Stronger verification |
| --- | --- | --- |
| OneDrive | Install, account, process, roots, Known Folder Move, recent local activity | Microsoft 365 Sync Health for managed tenants, or optional Microsoft Graph authorization |
| Backblaze | Install, service/process, selected drives, local state | `bzcli report --format json --exit-on-error` on current clients |
| Dropbox | Install, process, configured root, local activity, provider UI shortcut | Optional Dropbox OAuth metadata verification |
| Google Drive | Install, process, mounted/mirrored roots, local activity, provider UI shortcut | Optional Google OAuth metadata verification |

Cloud checks must distinguish `Detected`, `Configured`, `Running`, `Syncing`, `Error reported`, and `Cloud verified`. Do not collapse those into a single healthy state.

For privacy, show protected root names, total counts, total size, and recent activity by default. Do not upload or display full file-name inventories unless the customer explicitly opts in.

### P1: Cloud health checks are not scheduled

`cloudCheck.enabled` is saved, but `install-scheduled-backup.ps1` installs only backup, catch-up, and reminder tasks. Cloud health runs only when requested from the app.

Required fix: add a daily health task that updates a common health-event store and lets the tray app notify once per incident.

### P1 partially addressed: Automated coverage for the backup contract

Node tests now reject incomplete and tampered completion metadata and verify ordering of completed snapshots. Portable PowerShell checks exercise destination identity, media probing, completion metadata, checksum verification, and tamper detection with disposable macOS data.

Remaining: add Pester coverage, Node state-reconciliation tests, and destructive Robocopy, Scheduled Task, drive-removal, full-disk, and rollback scenarios against disposable Windows virtual disks in CI or a dedicated Windows test VM.

## Notification assessment

Implemented today:

- backup success and failure notifications
- missing destination warning
- first-backup reminder
- stale-backup reminder
- tray status for missing, unrecognized, overdue, warning, and failed states
- catch-up backup after user sign-in, and at startup when installation permissions allow
- pre-copy low-space and media write/read failures
- weekly checksum verification failure warning
- integrity health summary in the dashboard and tray

Gaps:

- cloud provider paused, signed out, quota full, or sync-error warning
- Scheduled Task disabled, deleted, or repeatedly failing warning
- notification history inside the app
- deduplication across the PowerShell balloon path and Electron notification path
- typed distinction between read-only media and broader media-health failure

Recommendation: create one health engine that emits typed incidents. The UI, tray, Scheduled Tasks, and support bundle should all consume the same incidents instead of independently interpreting status text.

## Safe backup browser and restore design

Add a read-only Recovery Browser as a first-class screen, not another dense Settings form.

Required workflow:

1. Choose a completed snapshot.
2. Browse a read-only tree with search, file size, modified date, and manifest verification state.
3. Select individual files, folders, or the whole backup item.
4. Restore to a new `DataSafe Restores/<date>` folder by default.
5. Show a comparison before any original-location restore.
6. Apply an explicit conflict policy.
7. Create a pre-restore safety snapshot and restore journal.
8. Show a final result with copied, skipped, renamed, failed, and verified counts.

The destination should never be browsed through a writable embedded file manager. Opening the destination in Windows Explorer can remain available as a clearly labelled advanced action.

## Terms and privacy review

The current terms are three short paragraphs (`index.html:570-572`). They set customer responsibilities and attempt a broad liability exclusion, but they do not define the licensed service, warranties, liability cap, exclusions that cannot legally be excluded, third-party cloud services, privacy, updates, subscription termination, governing law, or how customers retain a copy.

This is not legal advice. Before selling DataSafe, Alberta counsel should review both consumer and reseller versions. Alberta's consumer guidance states that Consumer Protection Act rights cannot be waived and ambiguous consumer terms are interpreted in the consumer's favour. A blanket `not liable` paragraph should not be treated as complete protection.

The final legal package should include:

- product and service description, with no promise that any backup is infallible
- customer responsibility to maintain multiple copies and test restores
- supported and unsupported sources, destinations, and cloud providers
- disclosure that local backup media is not encrypted unless encryption is added
- warranty disclaimer subject to non-waivable legal rights
- carefully drafted limitation of liability and liability cap
- third-party service dependency disclaimer
- privacy notice for diagnostics, licensing, provider metadata, and support bundles
- subscription, renewal, grace-period, suspension, and termination terms
- commitment that restore access to existing backups remains available
- update policy and ability to require security updates
- governing law, severability, contact information, and effective version
- a way to save or print the exact accepted terms

Acceptance evidence should store the exact terms version, SHA-256 text hash, acceptance timestamp, app version, installation ID, and whether acceptance was customer or authorized reseller acceptance. Keep an immutable copy outside ordinary uninstall cleanup when legally appropriate.

Relevant official guidance:

- Alberta unfair business practices: https://www.alberta.ca/unfair-business-practices
- Alberta PIPA use and consent: https://www.alberta.ca/using-personal-information.aspx
- Alberta PIPA safeguards: https://www.alberta.ca/protecting-personal-information
- Alberta OIPC breach notification: https://oipc.ab.ca/breach-notification/

## Reseller deployment architecture

Do not protect internal settings with a hidden button or a shared technician password. Both are easy to discover in a desktop app.

Split configuration into two files with different ownership:

### Customer configuration

Customer-editable and stored in the user profile:

- backup items
- destination
- schedule and reminders
- retention within reseller-approved limits
- restore preferences
- accepted terms record

### Signed deployment profile

Created by the reseller and treated as read-only by the customer app:

- reseller or shop ID
- product name and logo
- support name, phone, email, and URL
- stable or beta update policy
- licensing service URL and public verification key ID
- enabled providers and features
- default retention and permitted ranges
- terms document ID and version

Sign the deployment profile with an offline Ed25519 private key. The customer app should contain only the public verification key. Reject altered profiles and fall back to a safe unbranded state.

Build a separate `DataSafe Deployment Studio` for shops. It should create a shop profile, upload brand assets, select defaults, request a license tenant, sign the profile, and produce either a provisioning package or installer command. The customer DataSafe app should not expose these controls.

## Licensing plan

Use subscription-backed activation with a server-signed offline certificate.

Recommended flow:

1. The reseller creates a customer and seat in the licensing portal.
2. DataSafe activates with a short provisioning code.
3. The server binds the seat to the random installation ID, not a brittle hardware fingerprint.
4. The server returns a signed certificate containing tenant, license, installation, plan, features, issued date, expiry, and grace date.
5. DataSafe verifies the signature locally using an embedded public key and caches the certificate in protected local storage.
6. The app refreshes periodically and records the last successful validation.
7. Temporary outages use the grace period without interrupting backups.
8. After grace, DataSafe warns clearly and can pause new scheduled backups, but it must still permit restore and access to existing backup history.
9. Resellers can deactivate a lost PC and transfer the seat.

Never place a signing secret, master API key, or license-generation algorithm in the desktop app. Licensing status should be a separate module from backup integrity so licensing failures cannot corrupt or lock customer data.

## Windows pilot test matrix

Run each case on Windows 10 and Windows 11 with disposable source data and destination disks.

### Backup

- normal file and folder backup
- empty folders, hidden files, long paths, Unicode names, and denied ACLs
- browser and PST data while the related app is open
- source changes during backup
- destination removed before and during copy
- wrong drive with the expected letter
- mismatched, missing, and corrupt destination markers
- full disk before and during copy
- read-only destination
- power loss or process kill during each backup phase
- retention with daily, monthly, and yearly overlap
- two backups started simultaneously

### Scheduling and notifications

- user signed in, signed out, locked, sleeping, and waking
- missed schedule catch-up
- reminder task disabled or deleted
- backup task failure repeated across days
- Focus Assist and Windows notification settings
- app closed to tray and app fully quit

### Restore

- alternate-folder restore with no collisions
- collisions with older, newer, and same-content files
- original-location restore with rollback
- process-open checks for browsers and email apps
- partial or corrupt snapshot rejection
- interrupted restore and resume
- restore after app update and after configuration changes

### Cloud

- installed but signed out
- process stopped or paused
- quota full
- local sync error
- online-only and mirrored files
- multiple accounts and multiple providers
- Backblaze `bzcli report` healthy and error outputs

### Upgrade and licensing

- signed installer and update validation
- upgrade with existing config, snapshots, terms acceptance, and license
- offline activation grace and expired subscription
- seat transfer and reinstall
- uninstall without deleting legally required acceptance or license records

## Recommended delivery order

1. Complete the Windows pilot for the implemented transactional snapshots and failure state.
2. Complete the Windows pilot for shared destination preflight and Scheduled Tasks.
3. Complete the Windows pilot for restore planning, safety copies, journals, and rollback.
4. Add typed health incidents around the implemented capacity preflight and integrity scrub.
5. Add Windows automated tests and a destructive virtual-disk test harness.
6. Backblaze adapter and conservative OneDrive health wording.
7. Read-only Recovery Browser.
8. Signed deployment profiles and separate Deployment Studio.
9. Licensing service and offline certificate.
10. Counsel-approved terms, privacy notice, and acceptance evidence.
