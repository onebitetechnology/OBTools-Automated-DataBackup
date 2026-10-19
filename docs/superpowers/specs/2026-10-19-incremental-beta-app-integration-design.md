# Incremental Beta App Integration

Date: 2026-10-19 (America/Edmonton)

Status: Approved by Jeff on 2026-10-19. Implementation-plan review is the next gate; this document alone does not authorize publishing.

## Intended outcome

Jeff is the only tester and DataSafe has no other deployed users. The next Windows beta should arrive through the normal installed app/update process, without a separate private installer or second installed test app. Jeff should be able to select sample files, click **Backup Now**, see truthful progress/results, browse the complete latest backup and earlier/deleted ordinary files, and repeat a backup without recopying unchanged content.

The installed app must not silently change the format, source selections, schedule, or history of an existing backup set. A new-format beta test is an explicit action on a fresh repository, not an automatic migration. Initial acceptance uses generated sample data and an explicitly selected test USB destination.

This is an architectural app-integration slice of the broader browseable-backup design, not completion of all four original implementation plans. It does not redesign the qualified storage format or weaken the transaction safety gates.

## Baseline and evidence

- Source baseline: `61f1634aa91bbe38b12ee5943502e9b2f321a087`; production core: `6bfe6e7b2b7598d5258e81dfe3429450f6cb7037`.
- Existing package version is `1.0.10-beta.69`, not a reservation of the next release number.
- `docs/superpowers/specs/2026-10-16-browseable-incremental-backups-design.md` is the broader product design; this spec narrows the next beta's acceptance scope.
- Fresh assisted verification passed 42 focused checks, including a real FAT32 USB matrix. A subsequent physical FAT32 removal/reconnect **between runs** passed in a 20-pass/0-failure matrix. Detailed evidence is retained in the October 17 handoff folder, supplemented on October 18.
- Historical default fault runs remain honestly attributed: 119 passing unchanged cases and five obsolete-fixture failures per runtime, followed by the reviewed five-fixture correction and 15/15 focused passes per runtime. This spec does not reinterpret that as a fresh full-suite pass.
- Real exFAT, in-flight physical interruption, installed-app acceptance, representative large-data performance and Mac-host reproduction are not qualified. The original Phase-1 external gate remains open; this is a single-operator beta test, not a consumer rollout.

## Approaches considered

1. **Recommended: normal beta, explicit incremental test enrollment.** Integrate manual backup, status and browseable history now; preserve legacy behavior and clearly disclose unfinished new-format features. This reaches meaningful app testing without adding a second installer/channel.
2. **Complete the whole consumer feature before the next beta.** Add automatic retention, point-in-time restore, migration and deletion approval first. This is a much larger project and postpones feedback on the app-to-engine connection.
3. **Ship the current core-only build.** This can test legacy app behavior but cannot validate incremental app history/status; it is not the requested end-to-end incremental test.

Selected proposal: approach 1. Publishing through beta does not itself enable or migrate a backup format.

## First-beta boundaries

Included:

- Explicit new-format enrollment for a new PC repository on the selected test destination.
- Real **Backup Now** calls to the qualified engine, format-aware destination continuity, truthful progress, results and reconnection status.
- Read-only discovery of both legacy and incremental backups; separate labels and capabilities.
- Buttons to open validated latest/earlier/deleted file locations in File Explorer.
- Preservation of legacy snapshot discovery and legacy Restore behavior.
- Clear beta limitations, support diagnostics, automated integration tests and normal beta packaging/update verification.

Not included:

- Automatic migration or rewriting/deleting any existing legacy snapshot or incremental history.
- Automatic incremental retention/pruning or a claim that existing snapshot retention settings manage incremental history.
- New-format point-in-time reconstruction, restore-to-original, or **Restore everything**. The v2 UI explicitly offers browse/copy recovery and explains that assisted restore is not included yet.
- A new bypass for deletion review, corrupt journals, identity/capacity checks, unknown filesystem objects, reparse protection or unsupported merged-Public jobs.
- A consumer-wide default-format switch, production readiness claim, unrelated UI redesign, or separate private release channel.

This limited beta is an explicit exception to the broader design's complete-reader/assisted-restore-before-consumer-rollout ordering. It is acceptable only for the disclosed single-tester beta; approval of this spec must include that boundary. Existing legacy Restore remains functional.

## 1. Format selection and destination safety

- Persist an explicit numeric `backupFormatVersion` of 1 or 2 on each destination, including its known-destination record. Absent values retain legacy version 1; unsupported values fail closed before backup writes.
- Update does not enroll any destination. **Start incremental beta test** is an explicit user action that shows the actual drive and future `DataSafe Backups/<PC>/Latest Backup` location, sample-data guidance and the beta limitations.
- Enrollment creates a distinct destination-record ID for the v2 set instead of rewriting a legacy record. Known-destination normalization/deduplication preserves both formats, and the picker labels them explicitly even when they share a physical drive. There is at most one enrolled v2 target for this computer UUID on a given volume; changing the legacy base-folder text does not create another v2 repository.
- A normal app-enrolled v2 record also persists the selected Windows volume's `volumeUniqueId`. Main-process browse/backup checks and the worker compare it with the resolved actual volume before accepting the record or creating repository metadata. A missing/mismatched binding blocks normal enrollment/resume and asks for explicit review; drive letter, label and PC repository UUID alone are insufficient. This is local configuration, not a new repository schema. Existing explicit internal-flag test configurations remain a separate compatibility path and do not silently enroll the installed app.
- The existing internal root `incrementalFormatVersion: 2` remains supported for existing engine fixtures/development configurations when no destination format is present. An explicit destination format takes precedence. The normal app writes explicit destination values so an old root-level flag cannot leak into newly selected destinations.
- The worker resolves the same effective format as the main process. It does not accept a format-specific command from an untrusted renderer as a substitute for saved, validated configuration.
- The new-format layout remains the qualified drive-root `DataSafe Backups/<PC>/...`, not the legacy `<baseFolder>/snapshots` tree. Do not redirect it under the legacy base folder or move legacy directories to make the UI agree.
- Enrollment may create a new UUID-owned repository alongside untouched legacy content. It may resume an existing strictly validated repository for the same locally stored computer UUID. It must never adopt another PC's repository by friendly name, reinterpret legacy content, or overwrite an unknown occupied path.
- Validate a selected destination before enabling the action, then revalidate in the main process and worker immediately before mutation. Switching drives with the same drive letter must not be accepted from stale status. Missing/mismatched history cannot be bypassed by a generic confirmation intended for creating a new set.
- Existing source choices are not silently changed. The beta UI identifies enabled merged-Public jobs as unsupported and asks the operator to use a compatible custom sample selection or remain in legacy mode. The engine's existing refusal stays authoritative.
- Existing space reserve, FAT32 individual-file limit, transaction locks and recovery-before-new-backup requirements remain in force. No drive formatting or repair action is added.

## 2. Read-only catalog and main-process adapter

Create a focused read-only catalog boundary instead of teaching each screen to parse storage metadata independently:

- Legacy discovery continues to use the existing completed-snapshot validation.
- Incremental discovery uses a PowerShell read-only entry point that reuses the existing repository/schema/current-pointer/manifest validators. Internals may be wrapped in a new supported summary function; Node must not implement a looser alternative validator.
- Discovery never calls repository initialization, creates a computer identity, acquires a mutation lease, repairs transactions or writes backup metadata. Missing local identity is a readable state, not permission to create or adopt a repository.
- Typed catalog records identify destination, format, computer UUID, friendly display name, committed manifest/transaction identity and current committed time. Supported actions are explicit capabilities, not inferred from names or folder presence.
- Distinguish disconnected, checking, empty, valid committed, recovery-required, unknown/corrupt and legacy states. A readable status JSON alone is not proof of committed backup content. Cached information while disconnected is labelled as last-known, not a fresh integrity pass.
- A validated current pointer proves which manifest is authoritative. Catalog validation is not a full user-content scrub; do not label every byte freshly verified merely because metadata parsed successfully.
- Discover other PC repositories read-only and keep ownership separate. No mutation action is offered for another UUID. Duplicate identities or invalid relevant metadata are surfaced for review, not resolved by selecting the newest-looking folder.
- Cache read-only summaries and refresh on startup, destination change, explicit refresh and operation completion. Coalesce refreshes; do not spawn PowerShell or hash all user files on every renderer/status polling tick. Stale responses cannot replace the current destination's view.

Main-process status reconciliation branches by the validated selected format. It must not overwrite a v2 result/catalog using an empty legacy snapshot list, import another destination's success, or use a folder modification time as a committed backup date.

## 3. Operation status and progress

- Keep **last committed backup** separate from **last attempt**. A failed or unavailable-drive attempt must preserve the committed time and make the failure/next action visible.
- Associate asynchronous progress/results with the selected destination and operation; drop stale events after a destination switch or newer operation. Retain the worker's transaction ID when available.
- Preserve `backupFormatVersion`, `scanCounts`, `copyBytes`, `historyCounts`, `transactionId`, `recoveryAction` and structured warnings rather than replacing them with legacy snapshot defaults.
- Use plain phases such as **Checking your files**, **Copying and checking changes**, **Saving the update**, and **Your backup is up to date**. An unchanged run explicitly says no file content needed copying. Verification I/O is not falsely described as zero disk activity.
- For this beta, scanning and phase-only progress show elapsed time and an indeterminate/phase indicator. Disable the current ETA extrapolation from phase percentages for v2. Show a copy ETA only if genuine transferred-byte/rate measurements exist; adding fine-grained storage callbacks is not required by this slice.
- A process exit is not sufficient to announce success: require the worker's committed result and refreshed authoritative catalog. A committed backup with finalization warnings remains saved-with-attention, not pristine success or rollback.
- Rolling back an interrupted attempt is not a newly completed backup. Recovery-required and unavailable-source/deletion-review states explain what remains unchanged and what the operator must do.
- Failures do not emit a 100%-complete success animation. Background workers remain silent; Electron owns notifications and prompts.

## 4. History, browsing and legacy Restore

- Show **Latest Backup** for the current committed v2 tree and **Earlier Versions** as previous/deleted changed-file history. Explicitly explain that each history folder is partial history, not a complete snapshot of that date.
- An unchanged successful run does not invent another full snapshot or inflate the complete-backup count. Legacy snapshot counts and incremental history groups have separate labels.
- Introduce capability-checked browse actions. Renderer requests use validated destination/computer/location identifiers; the main process re-resolves and checks the path against the selected catalog before `shell.openPath`. Do not accept arbitrary renderer-supplied absolute paths or follow substituted reparses.
- A v2 history group is never passed to `restore-snapshot.ps1`. Enforce this in both UI and IPC, not only by disabling a button.
- Preserve legacy Restore's preview, verified safety-copy and destination safeguards. A view may offer legacy Restore for an explicitly selected validated legacy record while new-format records remain browse-only.
- Integrity/space widgets are format-aware. V2 space estimates use the actual planner/change set or remain explicitly uncalculated; the legacy whole-selection estimate and retention count must not masquerade as incremental staging/retention policy.
- Other-PC browsing is clearly labelled. Selection does not change the local computer identity or authorize writing to the other repository.

## 5. Manual beta testing and background helpers

This first v2 UI beta is manual-test-only. Legacy automation continues unchanged when the selected destination is legacy.

- Installation/update alone does not enable/disable schedules or register/remove tasks.
- Before v2 test enrollment, show the current automatic-backup/reminder/cloud-check choices and require an explicit **Use manual testing** confirmation. Apply any requested pause through the existing settings/task workflow and retain the prior choices for a later explicit return to legacy. Never resume them automatically after a destination switch.
- V2 cannot be enrolled while conflicting legacy automation remains active or task removal is unconfirmed. Explain the blocked setup instead of treating settings persistence as successful task removal.
- Existing scheduled backup, catch-up, reminder, integrity and cloud-health entry points must fail closed for this manual-only v2 enrollment, including already registered tasks that fire during a settings transition. They must not route to legacy restore/integrity/pruning assumptions, launch prompts or silently operate on old snapshot paths.
- A manual **Verify backup** action must not call legacy snapshot verification for v2. It is disabled with an honest explanation until a format-aware scrub exists. Existing transaction verification still runs on every v2 backup.
- No real task registration/deletion or installed configuration writes occur during automated development tests; mock these boundaries. Actual settings/task changes happen only through the operator's explicit beta setup action.

## 6. Implementation boundaries

- Keep transaction/manifests/repository schemas stable. No weaker validation or format fork to satisfy the renderer.
- Put catalog projection, effective-format and result classification in small testable units. Keep `main.js` orchestration thin; avoid duplicating storage logic in the renderer or enlarging unrelated subsystems.
- Expected touch points: `main.js`, `preload.js`, `app.js`, `index.html` and limited styles; a focused catalog/model adapter; a read-only PowerShell catalog script; effective-format/status boundaries in the worker; v2 guards in background helpers; Node/Windows tests; packaging allowlists and CI verification.
- The existing builder already includes all `windows` resources. Any new JavaScript runtime module must be explicitly included in its file allowlist.
- This does not implement new-format restore, migration, retention, deletion approval or merged-Public overlay mapping as incidental UI work. Keep their unsupported states explicit and safe.

## 7. Build and beta delivery

- Use the normal app identity and beta update channel, as requested. No separate private installer/feed is required. The user is currently the only tester.
- Integrate on a feature branch and preserve both this tested source and any newer Mac/project changes. Before release, inspect the actual remote main/tags and resolve differences deliberately; do not reset the Mac checkout or assume the old local version is current remotely.
- Choose a new, unused higher beta version after that remote check. Do not overwrite the `1.0.10-beta.69` artifact or reuse a published tag. Version, lockfile, release metadata and packaged source must agree.
- The checked-in `main` push/workflow-dispatch path publishes releases. During development use `dist:win` (`--publish never`) or a nonpublishing verification job. Do not push to main merely to transfer files or trigger an unfinished build.
- Expand release verification to include the new Node/PowerShell integration tests, not only the current `npm test` gate. Build the published installer once, record its hash and bundled worker/module equality, and retain that exact artifact.
- After approval and green pre-release gates, publish the beta through the existing Windows build workflow. Keep stable/latest update metadata unchanged and verify the release/feed assets; a beta label alone is not proof of feed isolation because the builder currently generates metadata for all channels.
- On this PC, use **Check for updates -> Download -> Install**, verify the installed version and run the sample-data acceptance below. Release notes disclose manual-only v2 enrollment, browse-only recovery and incomplete retention/migration support.
- A technical rollback uses a new beta release or explicit known installer after preserving settings. It never rewrites new-format backups as legacy or promises an old app can safely write them. No automatic downgrade is added.

## 8. Acceptance and review gates

Automated coverage before publishing:

1. Old configs remain legacy; format selection and volume binding round-trip through settings/destination switching without collapsing coexisting legacy/v2 records. Wrong-volume reuse of a drive letter, invalid versions and unsupported jobs fail before writes.
2. Read-only catalog fixtures cover legacy/v2 coexistence, missing identity, same-name PCs, duplicated IDs, missing/corrupt pointer/manifest, unknown/reparse entries, disconnect and stale asynchronous responses. Catalog reads leave a byte-level before/after tree unchanged.
3. IPC/model/renderer tests cover actual backup outcomes, committed-with-warning, rollback, failed attempts preserving committed time, no fake ETA/success, destination-specific history/capabilities, rejected forged restore/open requests and unchanged legacy Restore.
4. Disposable Windows worker-to-main integration covers initial, unchanged, changed and deleted files, recovery warnings, unavailable source/drive and deletion-review refusal. Actual `Latest Backup`/ordinary history and zero-copy assertions remain independent oracles.
5. Manual-only beta guards cover all task entry points, confirmed automation pause, rejected unconfirmed pause and unchanged legacy task actions. Test task APIs are mocked; no OS task is changed by the suite.
6. Existing affected Node/worker safety suites remain green on unchanged qualified core bytes. If implementation touches a storage primitive, explicitly expand covering recovery/fault checks based on that diff; do not silently reuse old results or automatically restart multi-hour repeat campaigns.
7. A nonpublishing Windows build contains every adapter/worker and passes packaged disposable NTFS smoke. Real FAT32 regression is run only against an operator-authorized disposable parent, as in the completed tests.

Operator acceptance after beta publication:

1. Update through the installed app; confirm version, retained legacy settings/history and no unrequested background task changes.
2. Explicitly enroll a fresh incremental test set with compatible sample jobs and confirmed manual-only operation.
3. Click Backup Now; inspect progress/results and open Latest from the app. Repeat unchanged and verify no user-file content copied.
4. Change/delete samples; browse prior/deleted copies from the app. Confirm they are labelled partial history and not offered to legacy Restore.
5. Disconnect between runs; confirm actionable missing-drive status, reconnect identity and a successful unchanged run. Observe extra-window flashes separately.
6. Switch back to a legacy set; confirm legacy history/Restore still work and v2 data are unchanged. Do not automatically resume schedules.

Passing this beta does not close the broader consumer rollout gate or authorize automatic migration/retention. Full point-in-time recovery, background/integrity automation and production-scale performance receive subsequent plans.

## Design review checklist

- Intent preserved: normal beta delivery, only current tester, no second installed app.
- Destructive effects excluded: no automatic migration, pruning, task changes on update or overwriting occupied destinations.
- Format, identity, status, restore and browse boundaries are checked outside the renderer.
- V2 browse-only/manual-only limitations are explicit, not hidden missing functionality.
- Storage-format contracts and previous verification attribution remain intact.
- Remote version/branch differences and feed isolation are checked before publishing, not guessed in the design.
- Approval of this written spec is required before creating its implementation plan; approval of that plan is required before product code changes.
