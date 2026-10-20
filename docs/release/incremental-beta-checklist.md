# Incremental beta release qualification

## Current disposition (2026-10-19)

**Candidate `1.0.10-beta.70` selected for authorized nonpublishing verification. Not a qualified installer or publication authorization.**

- Task 7 originally started at `03de22512da190919f8ce9aa965016e9918cfa64` on the existing `codex/browseable-incremental-core` worktree. Independent Task 7 and final whole-branch review findings are now fixed and reviewed through `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101`, the base for this version-only continuation. No storage primitives, schemas, app identity, dependencies or implementation behavior change in this continuation.
- Controller's fresh read-only remote refs preflight on 2026-10-19 returned main and `v1.0.10-beta.69` at `e7815bd6742c0eb706d28e90192676837216562c`, with tags only through beta.69. Remote package version is `1.0.10-beta.69`, and remote main is already an ancestor of the reviewed local source. Controller's authenticated releases GET (`per_page=100`) returned 22 total entries, all at or below beta.69, with no beta.70 release/draft. No tag or release was created/reserved by the version continuation.
- **Operator evidence, 2026-10-19:** Jeff confirms all Mac changes are pushed to GitHub; there are no Mac-only/unpushed changes to reconcile. The Mac checkout's exact SHA/version was not directly inspected, and no direct-inspection claim is made. Combined with remote ancestry, this clears the source-reconciliation gate without resetting or editing Mac/local work.
- Candidate `1.0.10-beta.70` is selected as the unused higher beta. `package.json`, lockfile root version and lockfile root package version are updated together; dependency resolutions are unchanged. Old beta.69 handoff artifacts remain frozen at reviewed `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101` and are not overwritten.
- Jeff explicitly authorizes the feature-branch push and nonpublishing Windows `verify-build`. The controller will perform those actions after scoped metadata review; this implementer performs neither. `publish-qualified` and actual publication remain separately unapproved.
- Local release-policy/config/workflow and synthetic real-Electron checker tests are recorded in the Task 7 report. Synthetic ASAR fixtures are tests of the checker, not electron-builder output qualification or installed-app smoke.
- Historical beta.69 local development build command was `node node_modules/electron-builder/out/cli/cli.js --config electron-builder.config.js --win nsis --publish never --config.directories.output=C:\Users\baker\AppData\Local\Temp\datasafe-task7-dev-35ef38e347b948bd840c27e9f00ca1c3`. It failed during dependency enumeration: `No JSON content found in output`. npm is absent on PATH. Electron 43.2.0 was extracted into that owned output; **no installer was produced**. This is preserved historical failure evidence, not a beta.70 build result. No dependency installation, local rebuild or alternate package-manager mutation was attempted in the version continuation.
- Required app/PowerShell integration gates previously ran in Task 6; Task 7 embeds them in both Windows PowerShell and PowerShell 7 before the build. They have **not run in CI for this candidate**.
- **CI run ID, final source SHA, installer filename/version/SHA-256, actual builder bundle equality, packaged-worker smoke: pending.** Do not fill these from a local fixture or previous October 17–18 artifact.
- No push, workflow dispatch, tag/release creation, upload, signing-secret change or other-chat coordination was performed by this implementer.
- The earlier controller-approved script-only change made `release:win` exit nonzero with guidance to `publish-qualified`, closing the old manual publishing bypass. That guard and `dist:win --publish never` remain unchanged.

## Candidate source/version gates

- [x] Obtain explicit operator evidence that all Mac changes are pushed (Jeff, 2026-10-19); exact Mac checkout SHA/version was not directly read.
- [x] Controller repeats remote main/tag/package and authenticated release/draft preflight; reviewed local source already contains remote main and no reconciliation edit is needed.
- [x] Select unused higher beta `1.0.10-beta.70`; align all three package/lock version fields without reusing beta.69 or a published tag.
- [x] Complete independent Task 7 and final whole-branch review/fixes through `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101`, including final source findings.
- [x] Jeff explicitly authorizes feature-branch push and nonpublishing Windows verification; this authorization does not include publication.
- [ ] Controller reviews the scoped version/checklist diff, then performs the authorized feature-branch push and `verify-build` dispatch. This checklist does not record those actions as completed.

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
| Reviewed source and Mac evidence | Base `7ac30bf4cbdd9efa2d8e5b79747b76efc2ae3101`; Jeff confirms all Mac changes pushed, 2026-10-19; final beta.70 CI source SHA pending |
| CI verification run ID / attempt / URL | Pending |
| Exact commands and per-suite results in both runtimes | Pending |
| Immutable artifact name / ID / digest | Pending |
| Installer filename / version / SHA-256 | Pending |
| Source-resource audit and packaged-worker smoke results | Pending |
| Signing status and certificate identity | Pending; no credentials verified locally |

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
- [ ] Release signing and CI-qualified exact artifact.

Manual-only v2 enrollment, preserved legacy operation and ordinary-file browsing do not qualify full point-in-time restore, retention/pruning, migration/deletion approval or merged-Public mapping. A single-tester beta does not close the original Phase-1 consumer gate. Preserve historical evidence separately.
