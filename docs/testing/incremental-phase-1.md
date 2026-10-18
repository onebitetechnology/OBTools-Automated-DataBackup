# Browseable incremental backup: Phase 1 qualification

Status: **PENDING external qualification; development-only, not consumer-ready.**
This gate cannot close with an incomplete real-media matrix or unobserved desktop UI.
No consumer UI enables `incrementalFormatVersion: 2`; absent that internal field,
the default remains the existing version-1 snapshot engine. No migration, restore,
retention, installed-app execution or real backup-drive change is authorized here.

## Reproduction identity

- Exact production worker/core source commit: `6bfe6e7b2b7598d5258e81dfe3429450f6cb7037`
  (`fix: close incremental final-review safety and recovery gaps`).
- Package: `1.0.10-beta.69`, Electron `43.2.0`, electron-builder `26.15.3`, x64;
  actual build Node `v24.19.0`, npm `10.9.4`.
- Actual build/qualification host: Windows `10.0.26200`; Windows PowerShell
  `5.1.26100.9711`. Mac reproduction has **not** been performed.
- Build: `npm run dist:win` (`--publish never`); output
  `dist/OBTools-Automated-Backups-Setup-1.0.10-beta.69.exe`.
- Media harness revision: obtain its last-changing commit identity with
  `git log -1 --format=%H -- tests/windows/Run-IncrementalMediaMatrix.ps1`.
- Final installer SHA-256:
  `548367BBE43F4FAEB35AB2D7E1D6C38FB5F4E14D9939E580B22627096F381F9A`.

All seven packaged source comparisons matched after this build:

| File | SHA-256 |
| --- | --- |
| backup-engine.ps1 | `9644225EC42533717F10FA417D2052158F0182F590D1958BA3A0423309440861` |
| DataSafe.Safety.ps1 | `88BF10672DC9F4249A979F1D978C0420067B06A3F97997C1F8BD9799C2D39D79` |
| DataSafe.Repository.ps1 | `00254A9BCEBB1A943DE20EF4442FA18B08A0E40EF98F2410F8A89522343D0C07` |
| DataSafe.Manifest.ps1 | `01498136BE1C6012613411576BA3DEAD1162605B26E58E300C204AB65E9503B0` |
| DataSafe.IncrementalPlan.ps1 | `879AE875C26005F6C0796FCFE6CB9F2C664187D796937A88B1900C8B2393790F` |
| DataSafe.Transaction.ps1 | `70075FD29B52C89F1BB9EA97FAE5BF2017DEFA7A36462DE3486420BD993FBE5B` |
| DataSafeTaskRunner.vbs | `77BDF3AEF577B5BB7491EF827BC691FEDB0507F8FF51B92143D22267C1139A42` |

## Safe packaged-worker matrix

Run from a clean source checkout after building; do not rebuild the shared package
while fixture snapshots are being created. Use only authorized disposable
parents, never an installed configuration, installed AppData, customer content or
an existing backup repository. The runner creates unique `datasafe-media-<GUID>`
children and deletes only those exact absolute children. Parents must exist and
their real filesystem must match the parameter. A supplied wrong/unavailable
filesystem is a failure; an omitted filesystem is `NOT RUN`. It never formats,
partitions, mounts, registers tasks, installs, publishes or opens the app.

```powershell
# Available NTFS smoke/matrix; Temp defaults to a unique disposable fixture parent.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalMediaMatrix.ps1

# Once authorized disposable media is actually available (replace example paths).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalMediaMatrix.ps1 -NtfsRoot 'C:\DisposableTests' -ExFatRoot 'E:\DisposableTests' -Fat32Root 'G:\DisposableTests' -KeepArtifacts -ResultPath '.\media-evidence-new.json'
```

`-PackagedWindowsRoot` defaults to `dist/win-unpacked/resources/windows`;
`-SourceWindowsRoot` defaults to `windows`. All six worker/library hashes plus
`DataSafeTaskRunner.vbs` must match source before fixture creation. The worker and
libraries are copied from the package; only `Resolve-DataSafeDestination` is
overridden at the end of a **disposable copy** of Safety to select a directory
without touching root-level drive markers/backup content. The unmodified packaged
VBS copy invokes the copied packaged worker. Each copied file is rehashed before
the disposable Safety shim is added; subsequent invocations use that frozen copy,
not a shared `dist` path that a concurrent build can remove. Actual filesystem capability/free-space
queries, UUID identities, scan/hash/copy, transactions, history and recovery are real.
This is a packaged-worker/launcher test, not an installed Electron UI test.

Each available filesystem runs independently: first complete ordinary-file Latest;
unchanged `copyBytes=0`; changed file with its old ordinary previous version;
one deletion below the review threshold with ordinary Deleted Files history;
logical destination-unavailable/reconnect with preserved pointer; long source,
Latest and history paths over 260 characters and another zero-copy run; same-name
PCs with distinct UUIDs remain isolated. A targeted harness regression also requires
the frozen launcher to work while the shared-package path is unavailable. Every
successful checkpoint verifies every expected user file's literal content, exact
file count, no repository/status lock and no per-transaction staging. Journals and
manifests intentionally remain metadata, not user-file copies.

FAT32 small files must run successfully with actual `CompatibilityMode=true`.
Its oversize case is a **validated manifest/preflight candidate**, length
`4294967297` (4 GiB + 1), not an allocated/sparse source file and not a 4-GiB copy.
The schema-valid candidate is passed to the real planner with actual destination
capabilities/free bytes; it must produce the filesystem-limit error, zero
executable operations, transaction-creation refusal and unchanged pointer/Latest
hashes. A separate NTFS-hosted test uses the pure FAT32 capability mapping and is
explicitly `schema only / not FAT32 media`. That test cannot qualify physical
FAT32. Source filesystem and destination filesystem are distinct; no claim is made
that FAT32 can create such a source file. A small FAT32 volume may also fail the
real space reserve (`max(5 GiB, 10% total capacity)`); do not lower the reserve to
make a qualification pass.

`-KeepArtifacts` retains only successful disposable fixture roots for browsing
ordinary `Latest Backup` and `Earlier Versions` files. It does not retain locks or
transaction staging. Failed runs are cleaned only after owned launch completion is
proven. If termination cannot be confirmed, the matrix stops immediately and keeps
all exact `OwnedRoots` regardless of `KeepArtifacts`, with `CleanupBlocked=true`,
`UnresolvedLaunch` PID/fixture/destination/reason evidence and a manual-handling
warning. Do not delete those roots or their locks/staging until that launch tree is
confirmed stopped; this safety preservation is not successful qualification.
JSON evidence uses create-new and
will never overwrite a prior result; choose a fresh `-ResultPath` with an existing
parent. Evidence can contain local fixture paths, so sanitize it before sharing.
Clean retained fixtures only by the exact `OwnedRoots` list after review; never
delete their parent directories or use wildcard recursive removal.

## Remaining physical and visible-window checks

Logical directory renaming is **not** physical disconnection, and normal native
WScript execution/static hidden flags are **not** an observed zero-window test.

For a consenting operator with a disposable removable medium, add
`-ManualDisconnect` (omit `-NonInteractive`). Only removable-volume fixtures prompt.
Disconnect when prompted, run the unavailable attempt, reconnect the same medium
at the same letter, and continue. Expect unchanged authority/content while absent,
then successful reconnect with `copyBytes=0`, no locks or staging. Do not disconnect
a system disk, working disk, installed-app backup, or a drive containing live jobs.
This verifies absence **between** runs, not interruption of an in-flight write.
Physical mid-stage/mid-apply interruption remains a separate destructive-risk
qualification; deterministic crash/recovery tests are not a substitute for it.

While the packaged VBS runs all matrix phases on an interactive Windows desktop,
an operator must observe/record whether **any** visible PowerShell/console window
appears (including flashes). Record package hash, OS/session, observer, time, runs,
and result; zero is the required count. The runner deliberately reports this row
`NOT RUN` because it cannot establish desktop observation. Static hidden-launcher
tests and successful WScript marker/worker execution remain useful separate evidence.
If testing the installed app later, obtain separate authorization and use a clean
test machine; this task did not install or launch it.

## Current evidence and gate

Task-7 read-only inventory: C: and D: ready NTFS; F: removable not ready. No F: content was
read/written. No exFAT/FAT32 volume was available within the authorized disposable
roots. Actual source and destination for the automatic matrix were local NTFS Temp.

| Qualification | Evidence classification | Result |
| --- | --- | --- |
| NTFS complete initial/unchanged/changed/deleted/long-path, UUID isolation | Real disposable filesystem; packaged worker | PASS |
| Logical disconnect/reconnect | Real directory absence, not physical media removal | PASS |
| FAT32 oversize candidate on NTFS | Schema-level only, no large file | PASS |
| exFAT real matrix | No authorized ready medium | NOT RUN |
| FAT32 real small-file/oversize matrix | No authorized ready medium | NOT RUN |
| Physical disconnect/reconnect / in-flight interruption | No authorized removable medium | NOT RUN |
| Zero visible PowerShell windows | No interactive desktop observer | NOT RUN |
| Mac-host package reproduction | No Mac execution | NOT RUN |

Final review-fix source above has fresh focused 8/0 and recovery 11/0 on WinPS 5.1
and Core 7.6.5; Repository 46, Manifest 274, Plan 42 and Transaction 76 on both; actual
worker integration 19/0, hotfix 64/0, and Node 19/0 with no skips. The final Windows
build exited 0, all seven packaged hashes match source, packaged matrix 10/0/4 NOT RUN
and harness-failure 6/0 passed. Package evidence `final-packaged-media.json` reports
`CleanupBlocked=false`, `UnresolvedLaunch=null`, `ArtifactsRetained=false`, empty
`OwnedRoots`, and `Phase1Complete=false`. Logs/report use the `final-*` prefix in
the ignored SDD evidence directory.

Full 124-case fault traversals at the frozen source commit each completed with
**119 passed / 5 failed, native exit 1**: WinPS 4771.3795119 seconds, Core
8308.8287163 seconds. The five failures were obsolete always-mutate assumptions in
rollback tests. Four restored relocation archives with already-correct metadata,
so expected injected setter faults were never reached; the fifth incorrectly
required mutation of every old entry. The approved test-only
correction makes those cases reach a real `b.txt` metadata-only mutation and keeps
all four rollback substep faults, strict tree/recovery checks and durable completion
proof. No production or shared fixture/helper changed for this correction.

The five corrected cases plus ten adjacent metadata cases passed **15/15, exit 0**
on WinPS (227.3073724 seconds) and Core (297.9126297 seconds). They ran from an
ignored copy with explicit frozen `WindowsRoot` and disjoint GUID fixtures while
the original Core traversal continued unchanged. After both originals exited,
the tracked test was verified byte-identical to that reviewed, tested copy:
SHA-256 `00BB777E1FE3FD6F616108710DC98EEC2DEF19C0B147EE7716BB55080C4C7D35`.
This is composite evidence: 119 unchanged cases passed in each original traversal,
and the five corrected cases plus ten adjacent cases passed in each focused run.
The original failures remain preserved; **no fresh full-124/native-exit-0 claim or
new repeat campaign** is made. Both original full runs passed the 47-boundary
forward sweep and 10-boundary rollback journal-write sweep. The production and
test-only continuation scoped reviews found no new Critical/Important findings.

Historical Task-7 verification (before the final review fixes): packaged matrix **10 passed / 0 failed / 4 NOT RUN**
(package equality1, NTFS behavior8 including logical disconnect/UUID isolation/
frozen-launcher regression, FAT32 schema-only1). NTFS is the only actual filesystem
qualified here; the four skipped rows are physical removal, desktop observation,
exFAT and FAT32. Additional focused launch-race probe3/0 and harness guards2/0
verify missing-launcher behavior, omitted-media reporting, wrong-filesystem failure
and cleanup. Integration10/0, recovery11/0 on WinPS and Core, hotfix64/0,
`npm test`19/0 (no skips), `npm run dist:win`exit0, all seven packaged hashes equal
source. Evidence names: `task-7-media-frozen-launcher`, `task-7-media-final-current`,
`task-7-launcher-race-probe`, `task-7-harness-guards-fixed`, integration/recovery/
hotfix logs, `task-7-node.log`, `task-7-build.log` in the plan's ignored SDD directory.
The final-current run covers the extended-path fixture-call spelling; the final
empty-`OwnedRoots` JSON-array correction is separately covered by the two guards.

Historical evidence is attributed, not rerun by implication: Task 5's frozen
`81faf9a4c439781be774ff0637317b816cf63b41` baseline passed full fault124 on both
runtimes and exactly twenty qualified Core repeats of36 (720/0). That does **not**
qualify later changes automatically. Task 5 correction commit
`94b3cf55e1dc7fdb41c1829239754ab95c41bdda` separately passed new11, selected33 and
dependency suites on both runtimes. Task 6 source commit
`eb65c7f321bcdc0dd7fea94bd825795a3f5acaee` separately passed
integration10, Repository46, Manifest274, Plan42, Transaction76, recovery11 on both
runtimes, Hotfix64, selected faults17 and Node19. Those reports/logs live in the
plan's ignored SDD evidence directory. Task 7 itself changed no production
dependency and did not run a new full/repeat fault campaign. Final-fix evidence
for the subsequently changed shared metadata helper is reported separately.

For fresh focused verification (all must exit0):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalEngineIntegrationTests.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalRecoveryRegressionTests.ps1
pwsh -NoProfile -NonInteractive -File tests/windows/Run-IncrementalRecoveryRegressionTests.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalFinalRegressionTests.ps1
pwsh -NoProfile -NonInteractive -File tests/windows/Run-IncrementalFinalRegressionTests.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalFaultInjectionTests.ps1 -CasePattern '^(internal metadata|metadata exposes|internal rollback metadata|metadata-only|rollback metadata entries)'
pwsh -NoProfile -NonInteractive -File tests/windows/Run-IncrementalFaultInjectionTests.ps1 -CasePattern '^(internal metadata|metadata exposes|internal rollback metadata|metadata-only|rollback metadata entries)'
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-HotfixRegressionTests.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalMediaMatrixFailureTests.ps1
npm test
npm run dist:win
git diff --check
```

Expected counts: integration 19/0, focused final 8/0, recovery 11/0 and selected metadata faults 15/0 each runtime, hotfix 64/0, Node 19/0
with no skips, build exit0; matrix counts explicitly separate PASS/FAIL/NOT RUN.
The focused matrix failure runner expects6/0: it controls the launcher/taskkill
boundary (never killing real processes), with real disposable filesystem cleanup
and four normally completed packaged prerequisites for the logical-offline case.
Sandbox atomic-rename/hidden-launch restrictions may require approved native
execution; a restricted-environment failure is not media qualification.

Intermediate harness failures are not hidden: an initial native attempt reported
`Packaged launcher exit 1` under the long-path case label at `23:26:09Z`. A concurrent
build had started at `23:26:03Z`; the shared packaged VBS was recreated only at
`23:26:10Z`. The old harness invoked that mutable shared path, despite already having
a fixture copy. A focused disposable three-case launcher probe reproduced present
shared launcher→exit0/worker marker, absent shared launcher→exit1/no worker start,
intact snapshot→exit0/marker. The fix uses the verified copied launcher; it changes
no production path. Original worker status was cleaned with the failed fixture,
so this evidence is a launch-race diagnosis, not a claim about a worker long-path
exception. A separate evidence-write failure was caused by applying backup reparse
rules to a OneDrive-hosted report path; evidence now uses create-new output while
backup source/destination reparse policy remains unchanged. Full failing logs and
focused diagnosis remain in the Task-7 ignored SDD evidence, separately from final
qualification. The restricted-sandbox attempt was aborted and is not counted.

Phase 1 closes only when current recovery evidence, zero-copy unchanged behavior,
unchanged default legacy behavior, complete package/source equality, complete real
Windows media matrix and visible-window observation all pass. The gate is open.
Two rollout limitations additionally remain: development v2 explicitly refuses
legacy merged-Public jobs (`includePublicFolder`/truthy `includePublicDesktop`)
before scan/repository mutation, never silently omitting Public data; a completely
empty selected source root has no root-entry representation (empty descendant
directories do). Resolve these before consumer rollout; do not add marker files,
unjournaled directory creation, retention or automatic migration as test workarounds.

## Frozen public API and property inventory (Tasks 1–6)

Dot-source the relevant library; scripts expose helper functions globally, but only
the following contracts are public next-plan interfaces. Persisted field spelling
and schema versions are exact; don't serialize live handles or invent private calls.

Task-1 shared Safety primitives (not an alternate transaction API):
`Write-DataSafeAtomicJson(Path:string,Value,CreateOnly:switch)` → void;
`Move-DataSafeSameVolume(SourcePath:string,DestinationPath:string)` → void,
non-overwriting; `Assert-DataSafeNoReparsePath(Path:string)` → void/reject.

| Public function | Parameters → result |
| --- | --- |
| `Get-DataSafeComputerId` | `StatePath:string` → stable UUID string |
| `Get-DataSafeDestinationCapabilities` | `DriveRoot:string` → capabilities object |
| `Initialize-DataSafeRepository` | `DriveRoot,ComputerName,ComputerId:string` → repository |
| `Read-DataSafeRepository` | `RepositoryRoot:string` → validated repository |
| `New-DataSafeSourceManifest` | `Jobs:object[]`, optional `PreviousManifest`, `HashProvider:scriptblock`, `ApplyWorkerExclusions:switch` (default off) → manifest |
| `Compare-DataSafeManifests` | nullable `Previous`, required `Current` → change set |
| `Write-DataSafeManifest` | `Repository,Manifest`, `TransactionId:string` → immutable manifest path (no pointer publication) |
| `Read-DataSafeManifest` | `Path:string` → validated manifest |
| `New-DataSafeIncrementalPlan` | `Repository,PreviousManifest,CurrentManifest,Capabilities`, `FreeBytes:long` → serializable diagnostic plan |
| `New-DataSafeTransaction` | `Repository,Plan` → journal object with live ownership retained privately |
| `Stage-DataSafeTransaction` | `Transaction`, optional `HashProvider:scriptblock` → prepared journal |
| `Read-DataSafeTransaction` | `Path:string` → detached validated journal, no live authority |
| `Set-DataSafeTransactionState` | `Transaction`, `State:prepared/applying/committed/rollingBack/rolledBack` → void; validates transitions, cannot directly prepare |
| `Invoke-DataSafeTransaction` | `Transaction`, optional `AfterOperation:scriptblock` → result |
| `Recover-DataSafeTransaction` | `Repository`, `TransactionPath:string` → result under reacquired ownership |
| `Undo-DataSafeTransaction` | `Transaction` → result; never undo an authoritative committed pointer |

Repository properties: `FormatVersion, ComputerId, ComputerName, Root, LatestRoot,
HistoryRoot, MetadataRoot, ManifestRoot, TransactionRoot, StagingRoot`.
Capabilities: `FileSystem, Supported, Recommended, CompatibilityMode, MaxFileBytes,
TimestampToleranceTicks, TotalBytes`. NTFS tolerance0, exFAT100000 ticks, FAT32
20000000 ticks; FAT32 maximum4294967295 bytes. The pure filesystem mapper is an
internal test seam, not a replacement for the actual destination provider.

Manifest: `schema='datasafe.manifest', formatVersion=2, createdUtc, sources,
entries, sourceErrors`. Source: `sourceId,path,relativeDestination`. Entry:
`sourceId,relativePath,entryType,length,modifiedUtc,attributes,sha256,versionLocation`.
Source error: `sourceId,path,message`. Directory length0/hash null; UTC round-trip
timestamps, portable integer attributes, slash-separated relative paths; sources
use real absolute selection paths. Jobs: required `id,path`, destination precedence
`relativeDestination`, then `backupDestinationKey`, then sanitized `name/id`.
Source errors discard partial entries and block apply, never infer deletion.

Change set groups: `Added,ContentChanged,MetadataChanged,Deleted,Unchanged`, each
with `<Group>Count,<Group>Bytes,<Group>FileCount`; plus `SourceErrors,TotalCount,
TotalFileCount,TotalBytes`. Identity: source UUID/id + ordinal-ignore-case relative
path; rename is delete/add. Unchanged size/time reuses hashes; staged bytes are
always reverified. No source reparse traversal.

Plan properties: `TransactionId,PreviousBackupTimestamp,DisplayHistoryFolder,
Operations,StageBytes,PeakRequiredBytes,DeletionReviewRequired,DeletionCountsBySource,
BlockingErrors,OperationSchemaVersion,MetadataOverheadBytes,ReserveBytes,
PreviousManifest,CurrentManifest,DestinationFileSystem,TimestampToleranceTicks`.
Deletion counts: `SourceId,PreviousFileCount,DeletedFileCount,ReviewRequired`.
Operation schema1: `sequence,kind,sourceId,relativePath,sourcePath,currentPath,
oldCurrentPath,historyPath,stagedPath,expectedOldSha256,expectedNewSha256,oldEntry,
newEntry,status`. Kinds: add/replace/metadata/delete. Blocked plans have no executable
operations; deletion-review plans omit executable deletes and worker refuses them.

Journal: `schema='datasafe.transaction',formatVersion=3,operationSchemaVersion=1,
transactionId,computerId,repositoryRoot,state,createdUtc,previousBackupTimestamp,
displayHistoryFolder,previousManifest,currentManifest,stageBytes,peakRequiredBytes,
metadataOverheadBytes,reserveBytes,operations,failure,destinationFileSystem,
timestampToleranceTicks,previousPointer,pointerCaptured,mutationIntent`.
Journal operations extend plan operations with `error,archiveState,promoteState,
metadataState`. States: staging→prepared→applying→committed or rollingBack→rolledBack;
illegal transitions and detached-object mutation reject. Older strict v1/v2 journals
are read/upgraded only through validated owned recovery, not ad hoc editing.
Mutation intent: `transactionId,sequence,sourceId,relativePath,targetPath,kind,
directories,before`; `directories` is a reserved absolute directory string array;
metadata `before` contains `entryType,attributes,modifiedUtc` (otherwise null).
Recovery owns its validation/replay.

Pointer: `.datasafe/current-manifest.json`, `schema='datasafe.current-manifest',
formatVersion=1,transactionId,manifestPath,sha256`. Sole durable commit point;
manifest is complete and Latest verified before publication. Identity state:
`formatVersion=1,computerId`; repository JSON: `formatVersion=2,computerId,computerName`.
Both UUIDs and strict schema validation are authoritative, not friendly folder names.
Result: `FinalState,RecoveredOperationCount,ManifestPath,Warnings` (warnings contain
`Code,Message`). Hook context: `TransactionId,Sequence,Phase,State`.
Committed `JournalFinalizationFailed`/cleanup warnings retain authority and evidence;
do not start a new transaction over unresolved evidence or report pristine success.

Worker script parameters: required `ConfigPath,StatusPath:string`, optional
`AllowNewDestination:switch`. Internal opt-in: `incrementalFormatVersion:2` only.
Structured status: `backupFormatVersion,scanCounts(files,directories,sourceErrors),
copyBytes,historyCounts(previousVersions,deletedFiles),transactionId,recoveryAction,
warnings`; recoveryAction none/recovering/committed/rolledBack. Existing status fields
include `lastBackupAt,lastBackupResult,lastBackupMessage,destinationStatus,recentSnapshots`.
`copyBytes` means successfully staged user-file bytes, not all I/O. Electron owns
notifications; workers emit status/logs without popups.

Transaction discovery accepts canonical UUID-D `.json` ordinary files and still
validates their complete schema/path/identity. Only exact writer-generated ordinary
file names `.transaction-<32 lowercase hex>.tmp` and `.datasafe-<32 lowercase hex>.tmp`
are treated as unpublished evidence. They are never parsed as authority, promoted,
or deleted; each produces an `UnpublishedJournalTemporary` warning containing its
path. Canonical recovery can proceed beside them, and warnings remain on subsequent
runs while the evidence remains. These non-authoritative temporary warnings alone
do not prevent starting subsequent backups. Unknown names, directories even with those exact
names, and reparses still block. Actual unresolved journal/staging/finalization
evidence retains the existing block-new-transaction behavior.

## Bounded metadata work and remaining performance measurements

Already-correct entries without an active mutation intent no longer require a
metadata mutation or per-entry journal save. Changed metadata and parent directory
times dirtied by child moves still use the existing durable intent, filesystem
substeps, verification and completion boundary. Existing active intents always
reconcile and durably finalize, even when the target metadata is already correct.
Full-tree content/hash/metadata validation is unchanged, and the skip check itself
uses the same strict object verification.

Controlled disposable NTFS apply-phase counters (not production benchmarks):

| Fixture | Entries / plan operations | Metadata mutations / intents / completions | Full transaction-journal writes |
| --- | --- | --- | --- |
| Unchanged 8 files + directory | 9 / 0 | 0 / 0 / 0 | 3 |
| Unchanged 32 files + directory | 33 / 0 | 0 / 0 / 0 | 3 |
| One changed file among 32 + directory | 33 / 1 | 2 / 2 / 2 | 11 |

Both Windows PowerShell 5.1 and bundled Core 7.6.5 produced these counts. The old
WinPS implementation measured 9/33 metadata mutations and 21/69 full-journal writes
on the corresponding unchanged trees. The changed-file case restores that file
and its child-dirtied parent. These tests count real setter/writer calls and retain
full content/history oracles; `copyBytes=0` alone is not performance evidence.
The ignored final-fix report records exact byte/write/hash/elapsed counters and
their measurement scope. Apply journal bytes still grow with manifest size;
source scan/staging are outside this apply-only measurement, and repeated manifest
hashes are included in its SHA-byte counter. Runtime serialization and concurrent
test load prevent interpreting the elapsed values as cross-runtime speed results.

Whole-tree Latest SHA passes, whole-journal rewrites for genuine large change sets,
rollback restoration-loop saves, and reparsing retained terminal journals remain
scaling costs. Measure hash bytes, journal bytes/writes, and per-phase time against
representative larger datasets before consumer use. No production-scale throughput
or elapsed-time benchmark has been run, and this fix does not claim production
speed or remove those validation gates.

Next plans must consume these public APIs for restore/retention/migration and preserve
UUID isolation, locks, strict schema, pointer authority, peak-space and deletion
gates. Never prune Latest, delete history automatically or infer ownership by name.

## Mac source/build handoff (pending reproduction)

Transfer the committed source/lockfile, not the ignored Windows `dist`, caches,
node_modules, private configs or SDD fixture paths. Verify the exact core commit
above is an ancestor, plus the Task-7 harness commit, with `git rev-parse HEAD` and
`git merge-base --is-ancestor <core-commit> HEAD`. Do not push merely to transfer.
On the Mac, use the project's supported Node/npm, `npm ci`, then `npm test` and
`npm run dist:win` (already `--publish never`). This is Windows cross-packaging,
not Mac backup support. NSIS/Wine/signing tooling may require a compatible Mac
builder or a Windows VM/CI worker; report tool versions/errors rather than claiming
reproduction. Do not run `release:win` or set publishing credentials. No installation
is needed. Do not reuse this machine's absolute npm/cache shim paths on the Mac.

On the Windows build host used here, prepend the ignored `build-tooling/bin` npm shim
and bundled Node directory to process PATH; keep npm/Electron caches in that ignored
tooling folder. Use a short authorized `ELECTRON_BUILDER_CACHE` path to avoid native
7za executable path limits and process-local `CSC_IDENTITY_AUTO_DISCOVERY=false`.
These are build-process settings, not Git/global configuration changes.

For any reproduction, hash the resulting installer with `Get-FileHash -Algorithm
SHA256` (Mac: `shasum -a 256`) and compare every `resources/windows` worker/launcher
against that checkout (`Get-FileHash` or `shasum`). Installer hashes can differ
across hosts/builds; matching bundled source bytes and independently recorded build
identity are required, not an invented reproducible-installer claim. Transfer to an
authorized Windows test machine for the real-media/desktop checks above. macOS
cannot qualify Windows PowerShell, Win32 long paths or Windows media recovery.
