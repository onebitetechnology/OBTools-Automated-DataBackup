# Incremental beta release qualification

## Current disposition (2026-10-19)

**Source handoff only. Not a qualified installer or release authorization.**

- Task 7 started at `03de22512da190919f8ce9aa965016e9918cfa64` on the existing `codex/browseable-incremental-core` worktree. No storage primitives, schemas, app identity, package version or lockfile were changed.
- Read-only `git ls-remote origin refs/heads/main 'refs/tags/v*'` returned main and `v1.0.10-beta.69` at `e7815bd6742c0eb706d28e90192676837216562c`. This commit is already an ancestor of the local source (`git merge-base --is-ancestor ... HEAD`, exit 0). `git show <remote-main-sha>:package.json` reports `1.0.10-beta.69`. No higher version tag appeared in that read-only listing.
- **Mac current commit, dirty/unpushed changes and version: pending operator evidence.** Remote main does not establish Mac synchronization. No new release version has been selected. Package/lock remain beta.69; no existing artifact was overwritten.
- Local release-policy/config/workflow and synthetic real-Electron checker tests are recorded in the Task 7 report. Synthetic ASAR fixtures are tests of the checker, not electron-builder output qualification or installed-app smoke.
- Local development build command was `node node_modules/electron-builder/out/cli/cli.js --config electron-builder.config.js --win nsis --publish never --config.directories.output=C:\Users\baker\AppData\Local\Temp\datasafe-task7-dev-35ef38e347b948bd840c27e9f00ca1c3`. It failed during dependency enumeration: `No JSON content found in output`. npm is absent on PATH. Electron 43.2.0 was extracted into that owned output; **no installer was produced**. No dependency installation or alternate package-manager mutation was attempted.
- Required app/PowerShell integration gates previously ran in Task 6; Task 7 embeds them in both Windows PowerShell and PowerShell 7 before the build. They have **not run in CI for this candidate**.
- **CI run ID, final source SHA, installer filename/version/SHA-256, actual builder bundle equality, packaged-worker smoke: pending.** Do not fill these from a local fixture or previous October 17–18 artifact.
- No push, workflow dispatch, tag/release creation, upload, signing-secret change or other-chat coordination was performed.
- A narrow controller-approved exception permits a script-only `package.json` edit before version choice: `release:win` now exits nonzero with guidance to `publish-qualified`, closing the old manual publishing bypass. Version/dependencies and the lockfile remain unchanged.

## Before choosing a release version

- [ ] Obtain the Mac project's actual current source SHA, package version and dirty/unpushed status from its checkout or explicit operator evidence. Record the evidence and timestamp; do not assume it matches GitHub.
- [ ] Repeat read-only remote main/tag preflight and inspect the remote package version. Reconcile any newer Mac/remote changes on the feature branch without resetting local/Mac work.
- [ ] Choose an unused higher beta version only after reconciliation. Update `package.json` and root/package entry in `package-lock.json` consistently. Never reuse beta.69 or a published tag.
- [ ] Complete independent Task 7 and whole-branch review. Include the previously deferred history-label finding in final review triage.
- [ ] Obtain explicit permission for the shared push and CI verification dispatch. Push is not authorized by this checklist.

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
| Source SHA and reconciled Mac evidence | Pending |
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
- [ ] Mac reproduction and source reconciliation.
- [ ] Release signing and CI-qualified exact artifact.

Manual-only v2 enrollment, preserved legacy operation and ordinary-file browsing do not qualify full point-in-time restore, retention/pruning, migration/deletion approval or merged-Public mapping. A single-tester beta does not close the original Phase-1 consumer gate. Preserve historical evidence separately.
