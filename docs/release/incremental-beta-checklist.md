# Incremental beta release qualification

## Current disposition (2026-10-19)

**Candidate `1.0.10-beta.70` passed nonpublishing CI verification at source `5f9edf360a6786cf6a7a81fa9466d964c828a8a1`; the immutable artifact bytes are independently verified. The installer is unsigned. This is not overall Task 7 release readiness, Task 8 acceptance or publication authorization.**

- Task 7 originally started at `03de22512da190919f8ce9aa965016e9918cfa64` on the existing `codex/browseable-incremental-core` worktree. Independent Task 7 and final whole-branch review findings were fixed and reviewed through `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101`, the base for the version-only continuation. This later evidence update changes only documentation, not storage primitives, schemas, app identity, dependencies or implementation behavior.
- Controller's fresh read-only remote refs preflight on 2026-10-19 returned main and `v1.0.10-beta.69` at `e7815bd6742c0eb706d28e90192676837216562c`, with tags only through beta.69. Remote package version is `1.0.10-beta.69`, and remote main is already an ancestor of the reviewed local source. Controller's authenticated releases GET (`per_page=100`) returned 22 total entries, all at or below beta.69, with no beta.70 release/draft. No tag or release was created/reserved by the version continuation.
- **Operator evidence, 2026-10-19:** Jeff confirms all Mac changes are pushed to GitHub; there are no Mac-only/unpushed changes to reconcile. The Mac checkout's exact SHA/version was not directly inspected, and no direct-inspection claim is made. Combined with remote ancestry, this clears the source-reconciliation gate without resetting or editing Mac/local work.
- Candidate `1.0.10-beta.70` is selected as the unused higher beta. `package.json`, lockfile root version and lockfile root package version are updated together; dependency resolutions are unchanged. Old beta.69 handoff artifacts remain frozen at reviewed `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101` and are not overwritten.
- Candidate metadata commit `7f327d14d7a6fa6c7b02a477172d7db42773e881` was independently reviewed. The controller performed the explicitly authorized feature-branch push and nonpublishing Windows `verify-build`; successful run `39358364026` (#87, attempt 1) built exact source `5f9edf360a6786cf6a7a81fa9466d964c828a8a1`. `publish-qualified` was skipped and actual publication remains separately unapproved.
- Local release-policy/config/workflow and synthetic real-Electron checker tests are recorded in the Task 7 report. Synthetic ASAR fixtures are tests of the checker, not electron-builder output qualification or installed-app smoke.
- Historical beta.69 local development build command was `node node_modules/electron-builder/out/cli/cli.js --config electron-builder.config.js --win nsis --publish never --config.directories.output=C:\Users\baker\AppData\Local\Temp\datasafe-task7-dev-35ef38e347b948bd840c27e9f00ca1c3`. It failed during dependency enumeration: `No JSON content found in output`. npm is absent on PATH. Electron 43.2.0 was extracted into that owned output; **no installer was produced**. This is preserved historical failure evidence, not a beta.70 build result. No dependency installation, local rebuild or alternate package-manager mutation was attempted in the version continuation.
- Historical CI run `39355592461` at `7f327d1` failed at the cleanup fixture's short/long TEMP identity oracle; run `39356431145` at `8a61f87` failed at the actual-worker fixture's TEMP parent guard. Neither produced a qualified artifact. Independently reviewed test-only fixes `8a61f87` and `5f9edf3` corrected those fixture identity boundaries without a production engine change.
- Run `39358364026` passed both harnesses' seven suites, the actual builder package audits and packaged-worker smoke, then sealed/uploaded the immutable bundle recorded below. The later documentation-only evidence commit is **not** the built/tested source; do not relabel its HEAD as artifact provenance or require a rebuild solely for this evidence update.
- No push, workflow dispatch, tag/release creation, upload, signing-secret change or other-chat coordination was performed by this implementer.
- The earlier controller-approved script-only change made `release:win` exit nonzero with guidance to `publish-qualified`, closing the old manual publishing bypass. That guard and `dist:win --publish never` remain unchanged.

## Candidate source/version gates

- [x] Obtain explicit operator evidence that all Mac changes are pushed (Jeff, 2026-10-19); exact Mac checkout SHA/version was not directly read.
- [x] Controller repeats remote main/tag/package and authenticated release/draft preflight; reviewed local source already contains remote main and no reconciliation edit is needed.
- [x] Select unused higher beta `1.0.10-beta.70`; align all three package/lock version fields without reusing beta.69 or a published tag.
- [x] Complete independent Task 7 and final whole-branch review/fixes through `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101`, including final source findings.
- [x] Jeff explicitly authorizes feature-branch push and nonpublishing Windows verification; this authorization does not include publication.
- [x] Controller reviews scoped candidate metadata and test-only CI fixes, then performs the authorized feature-branch push and `verify-build`; exact-source run `39358364026` succeeds. Publication is not included.

## Nonpublishing CI qualification

Normal main pushes and the default `verify-build` dispatch have read-only repository permission. They run `npm ci`, `npm test`, then both PowerShell runtimes' format-policy, catalog, beta-automation, app-integration, incremental-engine, recovery and final-regression suites before `npm run dist:win` (`--publish never`). They cannot create releases or upload release assets.

After building, `Test-AppPackage.ps1 -PackagedRoot dist/win-unpacked -SourceRoot .`:

- uses the packaged Electron executable and ASAR module resolution;
- loads pure app policy/service/view modules and updater exports without accessing its lazy updater instance;
- prevents external Node preload/search paths and rejects module fallbacks outside the ASAR;
- compares source bytes for app scripts/UI and all Windows, data and asset resources, including every PS/VBS helper;
- compiles app entry points without executing them or reading installed-user configuration;
- emits a JSON hash/resource record. It never runs packaged workers itself.

Separate disposable NTFS `Run-AppIntegrationTests.ps1 -WorkerRoot dist/win-unpacked/resources/windows` runs in both PowerShell versions after equality checks. A successful job seals exactly the installer, its blockmap, `beta.yml`, `package-audit.json`, and `qualification.json`. Stable metadata is rejected; `builder-debug.yml` is diagnostic only and excluded. Upload-artifact v4 retains the run/attempt/SHA-specific immutable bundle for 30 days; no overwrite is enabled.

Record from the successful CI run, not from memory:

| Evidence | Required value |
| --- | --- |
| Reviewed source and Mac evidence | Built source `5f9edf360a6786cf6a7a81fa9466d964c828a8a1`; Jeff confirms all Mac changes pushed, 2026-10-19; exact Mac checkout not directly inspected. Later docs-only commit is not artifact source. |
| CI verification run ID / attempt / URL | [39358364026](https://github.com/onebitetechnology/OBTools-Automated-DataBackup/actions/runs/39358364026), #87, attempt 1, job `118418404771`; success; 2026-10-20 02:20:21Z–02:51:08Z (October 19 local), 30m47s; publisher skipped |
| Exact commands and per-suite results in both runtimes | Commands and counts below; `npm ci` and nonpublishing build succeeded |
| Immutable artifact name / ID / digest | `qualified-beta-39358364026-1-5f9edf360a6786cf6a7a81fa9466d964c828a8a1`; ID `12237686111`; ZIP SHA-256 `9282bf1bb89a239d5dc4685b960e4b4c4e8880fed27eb0e6c23a151388d89570` matches API digest; 106026707 bytes; expires 2026-11-19 02:50:57Z |
| Installer filename / version / SHA-256 | `OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe`; `1.0.10-beta.70`; SHA-256 `6e422ee60228cc204e60707d538a99ace40beb1d00c861181c064963cd32f900`; 105906665 bytes |
| Source-resource audit and packaged-worker smoke results | Both runtimes passed packaged Electron 43.2.0 ASAR resolution (`packaged-electron-asar`) and equality for 36 source/resource hashes; actual packaged-worker smoke 15/15, 0 failures, 0 skips in each native runtime |
| Signing status and certificate identity | Independent installer Authenticode result `NotSigned`; signer subject/thumbprint null. Generic builder “signing with signtool.exe” log lines are not signature proof. No installer execution or installation occurred. |

The controller downloaded the immutable ZIP into workspace `DataSafe-Verification-39358364026` and independently verified its explicit five-entry allowlist: installer, installer blockmap, `beta.yml`, `package-audit.json`, `qualification.json`; no `latest.yml` is present. The manifest binds the exact source/run/attempt/version and all four payload file hashes. Both `beta.yml` SHA-512 fields match the actual installer, as do version/path/URL and the 105906665-byte size; the bundled source/resource audit passed. Additional verified SHA-256 values:

| Payload | SHA-256 |
| --- | --- |
| `OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe.blockmap` | `fe44a7e0d975876f344e433edc1a19bbce023689d648f2d21ac7a75eb2d0e808` |
| `beta.yml` | `49e11bac15e71c81a6ae140c3632c6c57e4d654072fecd83769158857406a306` |
| `package-audit.json` | `4d61f2c2b4897f3d32d85099cf3f29966c87956cdc82e8ed107f97e61d541747` |

Evidence retained in `.superpowers/sdd/2026-10-19-incremental-beta-app-integration-plan/ci-39358364026-artifact-verification.json` and `ci-39358364026-job-118418404771.log`, with a human-readable workspace `DataSafe-Verification-39358364026/HANDOFF.txt`. The controller's fresh post-verification releases GET still returned 22 entries, no beta.70; all three beta.69 asset digests match baseline, and main remains `e7815bd6742c0eb706d28e90192676837216562c`. Old beta.69 handoff snapshots and failed-run evidence remain frozen.

### Recorded CI commands and results

`npm ci` succeeded. `npm test` (`node --test`) reported **109 total, 107 pass, 0 fail, 2 explicit skips**: the actual worker requires its PowerShell wrapper, and the optional synthetic Electron audit fixture was unavailable before packaging. Actual-worker and actual-package checks ran separately later; these skips are not relabeled as passes.

Both harnesses ran the same seven suites with these results in each:

| Suite | Windows PowerShell harness | PowerShell 7 harness |
| --- | --- | --- |
| App format policy | 18/18 | 18/18 |
| Backup catalog | 38/38, 0 skips | 38/38, 0 skips |
| Beta automation | 21/21 | 21/21 |
| Actual app worker | 15/15, 0 skips | 15/15, 0 skips |
| Incremental engine integration | 20/20 | 20/20 |
| Recovery regression | 11/11 | 11/11 |
| Final regression | 8/8 | 8/8 |

All suites reported zero failures. Actual app-worker child runtimes were explicitly logged as native Windows PowerShell `5.1.26100.33438` and PowerShell `7.6.6`, including packaged smoke. Existing engine/recovery/final subprocesses may use legacy Windows PowerShell internally; running their harness in PowerShell 7 does not claim all children ran natively in PowerShell 7.

Exact suite invocations from the workflow/log (each loop checks `$LASTEXITCODE`):

```powershell
$suites = @('Run-AppFormatPolicyTests', 'Run-BackupCatalogTests', 'Run-BetaAutomationTests', 'Run-AppIntegrationTests', 'Run-IncrementalEngineIntegrationTests', 'Run-IncrementalRecoveryRegressionTests', 'Run-IncrementalFinalRegressionTests')
foreach ($suite in $suites) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests/windows/$suite.ps1"
  if ($LASTEXITCODE -ne 0) { throw "$suite failed under Windows PowerShell" }
}
foreach ($suite in $suites) {
  & pwsh -NoProfile -File "tests/windows/$suite.ps1"
  if ($LASTEXITCODE -ne 0) { throw "$suite failed under PowerShell 7" }
}
```

`npm run dist:win` succeeded using `electron-builder --config electron-builder.config.js --win nsis --publish never`. Both audit commands succeeded, and each smoke command reported 15/15 with zero failures/skips:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows/Test-AppPackage.ps1 -PackagedRoot dist/win-unpacked -SourceRoot .
& pwsh -NoProfile -File tests/windows/Test-AppPackage.ps1 -PackagedRoot dist/win-unpacked -SourceRoot . | Set-Content -Encoding utf8 dist/package-audit.json
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows/Run-AppIntegrationTests.ps1 -WorkerRoot dist/win-unpacked/resources/windows
& pwsh -NoProfile -File tests/windows/Run-AppIntegrationTests.ps1 -WorkerRoot dist/win-unpacked/resources/windows
```

### Security and signing follow-up (open)

CI reported **15 npm vulnerabilities (9 moderate, 6 high)** and action Node.js 20 deprecation. The read-only `dependency-advisories-5f9edf3.json` is semver-filtered npm bulk advisory data, not an `npm audit` aggregate or an assessment of application exploitability. Electron `43.2.0` is the shipped runtime even though declared as a devDependency. The supplied official [Electron advisory GHSA-qmv3-fv6v-rmhq](https://github.com/electron/electron/security/advisories/GHSA-qmv3-fv6v-rmhq) includes that version range, identifies `43.5.0` as patched, and limits affected applications to those loading untrusted content. Actual app exploitability has not been assessed. No dependency changes or blind audit fixes were performed. Security triage and an explicit signing/unsigned-release decision are required before publication readiness.

## Separately approved exact-artifact publication

- [ ] Repository owner configures the `incremental-beta-release` environment with required reviewers, prevent-self-review and appropriate branch restrictions. An environment name in YAML alone is **not proof of approval protection**. Do not dispatch until protection is confirmed.
- [ ] Obtain explicit release approval for the exact source SHA and verification run/attempt/artifact above. Credentials/permission availability remains an external gate.
- [ ] Dispatch `publish-qualified` with that verified run ID and exact 40-character source SHA; do not run `release:win` manually.

The publish job verifies successful run provenance, workflow/job identity, run attempt and immutable artifact name, downloads the existing bundle and verifies its exact file allowlist, hashes, audit/version/source binding. It refuses beta.69 and any existing tag/release instead of reusing or overwriting it. Only this approved path creates a draft prerelease, uploads the verified bytes and makes it visible. It does not rebuild; the legacy `release:win` command is fail-closed. An interrupted upload can leave a draft; stop for operator reconciliation rather than deleting/reusing/replacing assets automatically.

## Explicit limitations still pending

- [ ] Real exFAT qualification.
- [ ] Physical in-flight interruption on real media.
- [ ] Production performance qualification.
- [ ] Installed UI/update-path manual acceptance.
- [ ] Mac reproduction; source reconciliation is cleared by operator evidence and remote ancestry, not direct Mac checkout inspection.
- [x] Nonpublishing CI-qualified exact artifact and independent byte/provenance verification, limited to built source `5f9edf360a6786cf6a7a81fa9466d964c828a8a1` and run `39358364026` attempt 1.
- [ ] Signing/unsigned-release decision; verified installer is `NotSigned`.
- [ ] Security advisory and CI warning triage; actual app exploitability unassessed.

Manual-only v2 enrollment, preserved legacy operation and ordinary-file browsing do not qualify full point-in-time restore, retention/pruning, migration/deletion approval or merged-Public mapping. A single-tester beta does not close the original Phase-1 consumer gate. Preserve historical evidence separately.
