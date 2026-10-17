# Browseable incremental backup: Phase 1 qualification

Status: **PENDING external qualification; development-only, not consumer-ready.**
This gate cannot close with an incomplete real-media matrix or unobserved desktop UI.
No consumer UI enables `incrementalFormatVersion: 2`; absent that internal field,
the default remains the existing version-1 snapshot engine. No migration, restore,
retention, installed-app execution or real backup-drive change is authorized here.

## Reproduction identity

- Exact production worker/core source commit: `eb65c7f321bcdc0dd7fea94bd825795a3f5acaee`
  (`feat: integrate incremental backup engine`). Task 7 changes only test/docs.
- Package: `1.0.10-beta.69`, Electron `43.2.0`, electron-builder `26.15.3`, x64;
  actual build Node `v24.19.0`, npm `10.9.4`.
- Actual build/qualification host: Windows `10.0.26200`; Windows PowerShell
  `5.1.26100.9711`. Mac reproduction has **not** been performed.
- Build: `npm run dist:win` (`--publish never`); output
  `dist/OBTools-Automated-Backups-Setup-1.0.10-beta.69.exe`.
- Harness revision: the commit adding this document; obtain its full identity with
  `git log -1 --format=%H -- tests/windows/Run-IncrementalMediaMatrix.ps1`.
- Final installer SHA-256:
  `1EEDB753F39CC38CFB9F295013DEC4100383166F6967E1FED6E79823AC532C8E`.

All seven packaged source comparisons matched after this build:

| File | SHA-256 |
| --- | --- |
| backup-engine.ps1 | `03F27C0542835A803CCBF5BEDD141056D0FE1DAC320532292A5ACD2589B8AFE0` |
| DataSafe.Safety.ps1 | `5FB3F32A4AE57AD0556863F522CF771CFAF27F23F7F28E6C1D25AF5AAF84EFE8` |
| DataSafe.Repository.ps1 | `00254A9BCEBB1A943DE20EF4442FA18B08A0E40EF98F2410F8A89522343D0C07` |
| DataSafe.Manifest.ps1 | `01498136BE1C6012613411576BA3DEAD1162605B26E58E300C204AB65E9503B0` |
| DataSafe.IncrementalPlan.ps1 | `879AE875C26005F6C0796FCFE6CB9F2C664187D796937A88B1900C8B2393790F` |
| DataSafe.Transaction.ps1 | `D21DEE8D6B6DF6B4A662E82987632BF019EC969AD910F3E98467490872EA059C` |
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
transaction staging. Failed runs are cleaned. JSON evidence uses create-new and
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

Read-only inventory: C: and D: ready NTFS; F: removable not ready. No F: content was
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

Fresh Task-7 verification: packaged matrix **10 passed / 0 failed / 4 NOT RUN**
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
dependency suites on both runtimes. Task 6 source commit above freshly passed
integration10, Repository46, Manifest274, Plan42, Transaction76, recovery11 on both
runtimes, Hotfix64, selected faults17 and Node19. Those reports/logs live in the
plan's ignored SDD evidence directory. Task 7 changes no production dependency,
so no new expensive full/repeat fault campaign is claimed or required by this scope.

For fresh focused verification (all must exit0):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalEngineIntegrationTests.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-IncrementalRecoveryRegressionTests.ps1
pwsh -NoProfile -NonInteractive -File tests/windows/Run-IncrementalRecoveryRegressionTests.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/windows/Run-HotfixRegressionTests.ps1
npm test
npm run dist:win
git diff --check
```

Expected counts: integration10/0, recovery11/0 each runtime, hotfix64/0, Node19/0
with no skips, build exit0; matrix counts explicitly separate PASS/FAIL/NOT RUN.
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
