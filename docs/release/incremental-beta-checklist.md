# Incremental beta release qualification

## Current disposition (2026-10-19)

**Dependency-maintained candidate `1.0.10-beta.70` passed nonpublishing CI at exact source `5bde080556d986ee2378e1e0f5c66ffc2f05035a`, run `39367832253` attempt 1; the new immutable artifact bytes are independently verified and unsigned. It supersedes the older Electron 43.2.0 artifact only as the verification candidate. Residual security/signing/publication gates remain open. This is not overall Task 7 release readiness, Task 8 acceptance or publication authorization.**

- Task 7 originally started at `03de22512da190919f8ce9aa965016e9918cfa64` on the existing `codex/browseable-incremental-core` worktree. Independent Task 7 and final whole-branch review findings were fixed and reviewed through `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101`, the base for the version-only continuation. The subsequent evidence-only commit `a378400` changed documentation, not dependencies or implementation behavior; the bounded dependency maintenance below follows that commit without changing storage primitives, schemas or app identity.
- Controller's fresh read-only remote refs preflight on 2026-10-19 returned main and `v1.0.10-beta.69` at `e7815bd6742c0eb706d28e90192676837216562c`, with tags only through beta.69. Remote package version is `1.0.10-beta.69`, and remote main is already an ancestor of the reviewed local source. Controller's authenticated releases GET (`per_page=100`) returned 22 total entries, all at or below beta.69, with no beta.70 release/draft. No tag or release was created/reserved by the version continuation.
- **Operator evidence, 2026-10-19:** Jeff confirms all Mac changes are pushed to GitHub; there are no Mac-only/unpushed changes to reconcile. The Mac checkout's exact SHA/version was not directly inspected, and no direct-inspection claim is made. Combined with remote ancestry, this clears the source-reconciliation gate without resetting or editing Mac/local work.
- Candidate `1.0.10-beta.70` is selected as the unused higher beta. `package.json`, lockfile root version and lockfile root package version are updated together; dependency resolutions are unchanged. Old beta.69 handoff artifacts remain frozen at reviewed `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101` and are not overwritten.
- Candidate metadata commit `7f327d14d7a6fa6c7b02a477172d7db42773e881` was independently reviewed. The controller performed the explicitly authorized feature-branch push and nonpublishing Windows `verify-build`; successful run `39358364026` (#87, attempt 1) built exact source `5f9edf360a6786cf6a7a81fa9466d964c828a8a1`. `publish-qualified` was skipped and actual publication remains separately unapproved.
- Local release-policy/config/workflow and synthetic real-Electron checker tests are recorded in the Task 7 report. Synthetic ASAR fixtures are tests of the checker, not electron-builder output qualification or installed-app smoke.
- Historical beta.69 local development build command was `node node_modules/electron-builder/out/cli/cli.js --config electron-builder.config.js --win nsis --publish never --config.directories.output=C:\Users\baker\AppData\Local\Temp\datasafe-task7-dev-35ef38e347b948bd840c27e9f00ca1c3`. It failed during dependency enumeration: `No JSON content found in output`. npm is absent on PATH. Electron 43.2.0 was extracted into that owned output; **no installer was produced**. This is preserved historical failure evidence, not a beta.70 build result. No dependency installation, local rebuild or alternate package-manager mutation was attempted in the version continuation.
- Historical CI run `39355592461` at `7f327d1` failed at the cleanup fixture's short/long TEMP identity oracle; run `39356431145` at `8a61f87` failed at the actual-worker fixture's TEMP parent guard. Neither produced a qualified artifact. Independently reviewed test-only fixes `8a61f87` and `5f9edf3` corrected those fixture identity boundaries without a production engine change.
- Run `39358364026` passed both harnesses' seven suites, the actual builder package audits and packaged-worker smoke, then sealed/uploaded the immutable bundle recorded below. The later documentation-only evidence commit is **not** the built/tested source; do not relabel its HEAD as artifact provenance or require a rebuild solely for this evidence update.
- Bounded dependency maintenance `5bde080556d986ee2378e1e0f5c66ffc2f05035a` was independently approved for spec compliance and quality. Controller pushed that feature source and completed new nonpublishing run `39367832253` (#88), then independently checked the downloaded artifact. This later checklist-only commit is **not** the built/tested source. The older source/run/artifact record remains frozen below.
- No push, workflow dispatch, tag/release creation, upload, signing-secret change or other-chat coordination was performed by this implementer.
- The earlier controller-approved script-only change made `release:win` exit nonzero with guidance to `publish-qualified`, closing the old manual publishing bypass. That guard and `dist:win --publish never` remain unchanged.

## Candidate source/version gates

- [x] Obtain explicit operator evidence that all Mac changes are pushed (Jeff, 2026-10-19); exact Mac checkout SHA/version was not directly read.
- [x] Controller repeats remote main/tag/package and authenticated release/draft preflight; reviewed local source already contains remote main and no reconciliation edit is needed.
- [x] Select unused higher beta `1.0.10-beta.70`; align all three package/lock version fields without reusing beta.69 or a published tag.
- [x] Complete independent Task 7 and final whole-branch review/fixes through `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101`, including final source findings.
- [x] Jeff explicitly authorizes feature-branch push and nonpublishing Windows verification; this authorization does not include publication.
- [x] Controller reviews scoped candidate metadata and test-only CI fixes, then performs the authorized feature-branch push and `verify-build`; exact-source run `39358364026` succeeds. Publication is not included.
- [x] Controller reviews bounded dependency maintenance `5bde080`, pushes that feature source and completes new exact-source `verify-build` run `39367832253` plus independent artifact verification. Publication and residual security acceptance are not included.

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

### Historical qualification: run 39358364026 / Electron 43.2.0

This record is retained without rewriting its source or bytes; the later qualification candidate is recorded separately below.

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

### Historical run 39358364026 commands and results

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

### Dependency security maintenance (2026-10-20 UTC / October 19 local)

Historical CI reported **15 npm vulnerabilities (9 moderate, 6 high)** and action Node.js 20 deprecation. A fresh full local `npm audit --json` reproduced those counts before this change; the older read-only `dependency-advisories-5f9edf3.json` remains a separate semver-filtered bulk report, not an audit aggregate or proof of an app exploit.

The bounded maintenance updates Electron `43.2.0` → `43.8.1`, electron-updater `6.8.9` → `6.8.10` and electron-builder `26.15.3` → `26.17.0`. It removes the unsupported global js-yaml 5.x override: all YAML consumers declare `^4.1.0`, and npm now resolves supported `4.3.2`. No override remains and no independent test-only parser dependency is added. Supporting vulnerable copies refresh through their existing supported ranges:

| Resolved package / path | Before → after | Reachability classification |
| --- | --- | --- |
| `electron` | `43.2.0` → `43.8.1` | Shipped desktop runtime despite devDependency classification |
| `electron-updater` / `js-yaml` | `6.8.9` → `6.8.10` / `5.2.2` → `4.3.2` | Shipped updater / downloaded update metadata parser; YAML also serves build tooling |
| `@xmldom/xmldom` | `0.8.13` → `0.8.15` | Builder XML/plist tooling, not the app dependency closure |
| `brace-expansion` (all six copies) | `1.1.18` / `2.1.4` / `5.0.9` → `1.1.21` / `2.1.7` / `5.0.12` | Builder glob/matching tooling |
| `fast-uri` / `http-cache-semantics` | `3.1.5` → `3.1.9` / `4.2.0` → `4.3.0` | Builder validation / download-cache tooling |
| `node-gyp/node_modules/undici` / hoisted `undici` | `6.28.0` → `6.29.1` / `7.29.0` → `7.30.1` | Build/rebuild / optional tooling, not the app dependency closure |

Electron `43.2.0` matches four high advisories: GHSA-gr2m-v5gq-v685, GHSA-j84w-jfhq-vhvj, GHSA-qmv3-fv6v-rmhq and GHSA-9qh4-3jw8-366w. The [official preload advisory](https://github.com/electron/electron/security/advisories/GHSA-qmv3-fv6v-rmhq) currently lists `43.4.2` as fixed while the npm advisory range uses `<43.5.0`; `43.8.1` exceeds both. The historical CI artifact still contains `43.2.0` and is not remediated by changing source. The app loads packaged `index.html`; no actual-app exploit is demonstrated, nor are runtime advisories dismissed as build-only.

After a clean `npm ci --ignore-scripts`, full audit reports **8 moderate, 0 high, 0 critical** (exit 1). These are eight affected package entries propagated from one [no-published-fix sprintf-js advisory GHSA-hp3w-g68c-fv3c](https://github.com/advisories/GHSA-hp3w-g68c-fv3c), not eight distinct proven exploits. Exact retained chain: dev `electron-builder@26.17.0` → `app-builder-lib@26.17.0` → nested `@electron/get@3.1.0` → optional `global-agent@3.0.0` → `roarr@2.15.4` → `sprintf-js@1.1.3`. `dmg-builder` and `electron-builder-squirrel-windows` also participate in builder dependency/peer paths. Legitimate lock regeneration retains these dependencies; they are not orphan entries. npm's suggested builder `26.5.0` downgrade/force operation was not applied, nor were optional dependencies omitted or incompatible proxy/logger majors forced.

The vulnerable primitive accepts attacker-controlled high-precision format strings. In the installed global-agent use sites, log message templates are literals and URL/proxy/header/error values are structured context; no attacker-controlled format-string route was identified. This is a bounded source inspection, not proof that every possible build invocation is safe. Proxy bootstrap can execute when `ELECTRON_GET_USE_PROXY` is set or explicitly initialized. The chain remains a build-process risk to track, not a shipped app dependency. `npm audit --omit=dev` reports zero but excludes the shipped Electron runtime too, so it is not the overall security result.

Local pre-CI regression evidence: before dependency changes the offline known-range checks and actual updater/parser compatibility check failed (8 failures, 3 passes); after changes all 11 pass. Tests use the updater-resolved parser for valid beta metadata, file/hash/size resolution, malformed/duplicate-key/executable-tag feeds, and missing files/checksums. Local full `npm test`: **120 total, 119 pass, 0 fail, 1 intentional skip** (actual worker requires its PowerShell wrapper). The local synthetic real-Electron ASAR checker passed using the existing `43.2.0` fixture; that fixture was not qualification of new `43.8.1` package bytes. `npm ls --all --json` exited 0 with no dependency problems. Clean local install emitted upstream deprecation notices for rimraf, inflight, lodash.isequal, glob and boolean; no suppression or claim of pristine install output is made.

Raw pre/post audit, tree and local test logs are `task-7-security-*` evidence beside the task brief. Install scripts were deliberately not run locally. The controller subsequently completed independent maintenance review, the feature push and an ordinary CI `npm ci` / nonpublishing Windows build with package audits and smoke, recorded next. The older run `39358364026` remains historical, not evidence for the updated dependency source. Residual security acceptance, action warning triage, an explicit signing/unsigned-release decision and all publication controls remain open.

### Current qualification: run 39367832253 / Electron 43.8.1

The controller's supplied exact-byte verification JSON and full CI log establish the following. These are recorded completed results, not new network checks or test runs by this documentation implementer. Built source remains `5bde080556d986ee2378e1e0f5c66ffc2f05035a`; the forthcoming documentation-only commit is not artifact provenance and does not require another build solely for these prose changes.

| Evidence | Verified value |
| --- | --- |
| CI verification run / attempt / source | [39367832253](https://github.com/onebitetechnology/OBTools-Automated-DataBackup/actions/runs/39367832253), #88, attempt 1; source `5bde080556d986ee2378e1e0f5c66ffc2f05035a`; 2026-10-20 04:06:53Z–04:50:25Z (October 19 local), 43m32s |
| Job outcomes | Verification job `118448620437` and all its steps succeeded; publisher job `118448623173` skipped |
| Ordinary install and build | Node `22.23.3`, npm `10.9.9`; ordinary `npm ci` succeeded, 288 packages added / 289 audited; 8 moderate findings, 0 high; `npm run dist:win` succeeded with `--publish never`, builder `26.17.0`, packaged Electron `43.8.1` |
| Immutable artifact / ID | `qualified-beta-39367832253-1-5bde080556d986ee2378e1e0f5c66ffc2f05035a`; ID `12241468171`; 119485669 bytes; expires 2026-11-19 04:50:14Z |
| ZIP digest | SHA-256 `0de7206b980bc129ad79c57c36fbdf8c6146b87c5341c09ffc03fa6cbfabd41c`; independently downloaded bytes match GitHub's API/upload digest |
| Installer | `OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe`; version `1.0.10-beta.70`; 119350019 bytes; SHA-256 `8c81a81be0c3cab97dddfa4fe84dc8514f7dfef39df6ea6b7a256c9076aa140a` |
| Source/resource and packaged-worker checks | Both package audits passed strict CI-source/package byte equality for 36 hashes with actual `43.8.1` `packaged-electron-asar` resolution; packaged worker 15/15, 0 failures, 0 skips in each native runtime |
| Signing | Independent Authenticode `NotSigned`; signer subject/thumbprint null. CI explicitly reports no signing certificate configured. No installer execution or installation occurred. |

`qualification.json` validates schema/version and exact run/attempt/source binding plus all four payload SHA-256 values. The ZIP has exactly five allowed entries: installer, its blockmap, `beta.yml`, `package-audit.json`, `qualification.json`; no `latest.yml`. Additional independently verified file hashes:

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe.blockmap` | 123515 | `e5806bddcb9212ff0ea4f99aeeb380de9f9f7bef9563fb06c5c7b84baf88474d` |
| `beta.yml` | 406 | `0f9e98e334c26003e16f52d75108a2fe49b11ae6b5cdf8ee6120b5dd173cf043` |
| `package-audit.json` | 4151 | `3e220f83bab96159cb603ec50bac3a00413e3d8d2681cf3d8369c1467e12feaa` |
| `qualification.json` (independent own-file checksum, not a self-hash in its payload list) | Not recorded in verification JSON | `ba16e717b1ef89f6cafd03da47569ae2c484b2655e4ed16f3305e7fe14bdc620` |

Both `beta.yml` SHA-512 fields independently match the installer: `sVVRQt99tyEnJI55ljxMQPfJIPCFW1r7Naa1w44axekWTqjY1h55C54UIs7kiVrtkPvpA98IwSzdnz+4wb+Frg==`. Version, installer URL/path and size `119350019` also match; metadata releaseDate is `2026-10-20T04:45:02.224Z`.

CI `npm test` reported **120 total, 118 pass, 0 fail, 2 explicit skips**, distinct from the local 119-pass/1-skip result. The skips were the actual-worker test requiring its PowerShell wrapper and the optional prepack synthetic Electron fixture. Actual workers and actual built-package audits ran separately later; the skips are not relabeled as passes. Both seven-suite harnesses ran the same commands listed in the historical command section above with these new results in each:

| Suite | Windows PowerShell harness | PowerShell 7 harness |
| --- | --- | --- |
| App format policy | 18/18 | 18/18 |
| Backup catalog | 38/38, 0 skips | 38/38, 0 skips |
| Beta automation | 21/21 | 21/21 |
| Actual app worker | 15/15, 0 skips | 15/15, 0 skips |
| Incremental engine integration | 20/20 | 20/20 |
| Recovery regression | 11/11 | 11/11 |
| Final regression | 8/8 | 8/8 |

All suites had zero failures. Native actual-worker children and actual packaged-worker smoke used Windows PowerShell `5.1.26100.33438` and PowerShell `7.6.6`. Older engine/recovery/final subprocesses may invoke Windows PowerShell internally; PowerShell 7 harness coverage is not a claim that all their children ran natively in PowerShell 7. The exact `Test-AppPackage.ps1 -PackagedRoot dist/win-unpacked -SourceRoot .` and `Run-AppIntegrationTests.ps1 -WorkerRoot dist/win-unpacked/resources/windows` invocations above also succeeded in both runtimes for this run.

Independent controller source reconciliation distinguishes CI's strict 36-file source-to-package equality from a separate cross-machine comparison: 25 artifact hashes equal raw local bytes, and the other 11 equal the exact committed Git blobs after Windows LF→CRLF checkout conversion (`core.autocrlf=true`). There is no remaining content difference and no file/artifact was changed. The initial strict raw-local check stopped at `backup-format.js`; an explanatory Git-blob probe hit Node's default child-process buffer limit on `assets/BG.jpg`. The corrected check examined only mismatches with a bounded larger buffer and exited 0. Those diagnostic limitations were not product/CI failures and do not justify claiming all 36 matched raw local bytes.

Retained warnings: the same eight-moderate unpatched sprintf-js build chain (no new security acceptance), npm dependency deprecations (rimraf, inflight, lodash.isequal, glob, boolean), action Node.js 20 deprecation/forced Node 24 runtime, `DEP0040` punycode and `DEP0169` url.parse warnings in action setup/upload/post-node tooling. No warning is hidden or treated as proof of an app exploit. Signing/unsigned-release decision and explicit publication approval remain open.

Exact evidence is retained in `.superpowers/sdd/2026-10-19-incremental-beta-app-integration-plan/ci-39367832253-artifact-verification.json` and `ci-39367832253-job-118448620437.log`; the controller's separate new local handoff is `DataSafe-Verification-39367832253/HANDOFF.txt`, not an overwrite of the older handoff. Controller's supplied post-verification remote state remains main `e7815bd6742c0eb706d28e90192676837216562c`, feature `5bde080`, latest release beta.69, no beta.70 tag/release. No main merge or publication occurred.

## Separately approved exact-artifact publication

- [ ] Repository owner configures the `incremental-beta-release` environment with required reviewers, prevent-self-review and appropriate branch restrictions. An environment name in YAML alone is **not proof of approval protection**. Do not dispatch until protection is confirmed.
- [ ] Obtain explicit release approval for exact source `5bde080556d986ee2378e1e0f5c66ffc2f05035a`, run `39367832253` attempt 1 and its verified immutable artifact, after security/signing decisions. Do not substitute the historical artifact. Credentials/permission availability remains an external gate.
- [ ] Only after those gates, dispatch `publish-qualified` with that verified run ID and exact 40-character built source SHA, not the later documentation commit; do not run `release:win` manually.

The publish job verifies successful run provenance, workflow/job identity, run attempt and immutable artifact name, downloads the existing bundle and verifies its exact file allowlist, hashes, audit/version/source binding. It refuses beta.69 and any existing tag/release instead of reusing or overwriting it. Only this approved path creates a draft prerelease, uploads the verified bytes and makes it visible. It does not rebuild; the legacy `release:win` command is fail-closed. An interrupted upload can leave a draft; stop for operator reconciliation rather than deleting/reusing/replacing assets automatically.

## Explicit limitations still pending

- [ ] Real exFAT qualification.
- [ ] Physical in-flight interruption on real media.
- [ ] Production performance qualification.
- [ ] Installed UI/update-path manual acceptance.
- [ ] Mac reproduction; source reconciliation is cleared by operator evidence and remote ancestry, not direct Mac checkout inspection.
- [x] Current nonpublishing CI-qualified exact artifact and independent byte/provenance verification, limited to built source `5bde080556d986ee2378e1e0f5c66ffc2f05035a` and run `39367832253` attempt 1. Historical source `5f9edf3` / run `39358364026` stays frozen separately.
- [ ] Signing/unsigned-release decision; verified installer is `NotSigned`.
- [ ] Obtain security acceptance for residual eight-moderate build-chain findings and triage retained npm/action deprecations (`Node.js 20`, `DEP0040`, `DEP0169`). Exact-source build qualification is complete, not security acceptance; actual app exploitability is not proven or exhaustively assessed.

Manual-only v2 enrollment, preserved legacy operation and ordinary-file browsing do not qualify full point-in-time restore, retention/pruning, migration/deletion approval or merged-Public mapping. A single-tester beta does not close the original Phase-1 consumer gate. Preserve historical evidence separately.
