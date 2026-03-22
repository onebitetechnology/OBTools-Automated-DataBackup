# Changelog

All notable changes to `OBTools Automated Backups` should be recorded in this file.

## 1.0.10-beta.21 - 2026-03-22

- Added an update-channel setting so installed apps can choose between stable-only releases and beta/test builds.
- Switched packaging to a dynamic Electron Builder config so `-beta` versions publish to the GitHub beta prerelease channel, while plain versions publish as stable releases.

## 1.0.10-beta.20 - 2026-03-20

- Reorganized the main dashboard so the visible setup steps now match the actual workflow.
- Moved backup destination selection into the main UI as Step 2 and turned the next panel into a Step 3 backup-plan review with a main-screen save action.
- Narrowed the Settings drawer to more advanced/admin options like retention, automation, updates, and logs.

## 1.0.10-beta.19 - 2026-03-20

- Made backup dates and snapshot timestamps more user-friendly with a 12-hour clock format.
- Improved Chrome, Edge, and Brave `ERROR 2` backup messaging so it explains that browser profile files changed during backup and the browser should be closed before retrying.

## 1.0.10-beta.18 - 2026-03-20

- Changed backup status handling so a run that created snapshots but finished with copy warnings is treated as `Completed With Warnings` instead of falling back to `Backup Needed`.
- Preserved the latest snapshot time on partial-success runs so the dashboard reflects that a backup did technically complete.

## 1.0.10-beta.17 - 2026-03-20

- Optimized Chromium browser backups by excluding disposable cache directories from Chrome, Edge, and Brave user-data copies.
- This reduces backup time for browser profiles while preserving bookmarks, profiles, extensions, and user settings.

## 1.0.10-beta.16 - 2026-03-19

- Added a background update check shortly after app startup in installed Windows builds.
- The app now shows an update-available popup automatically when a newer internal build is found, instead of requiring a manual trip into Settings first.

## 1.0.10-beta.15 - 2026-03-19

- Added a user-facing runtime log and a Settings button to open the local logs folder.
- Backup progress events are now written to `obtools-runtime.log` so long-running or stuck-feeling copies can be diagnosed after the fact.
- Smoothed backup progress percentages so non-final phases no longer sit at `100%` before the run is actually finished.

## 1.0.10-beta.14 - 2026-03-19

- Reconciled existing snapshot folders on startup so the dashboard no longer shows `Never` and `0` when backups already exist on the selected drive.
- Improved browser-profile lock messaging so Chrome, Edge, and Brave backup failures caused by open browser processes tell the user to close the browser and retry.

## 1.0.10-beta.13 - 2026-03-19

- Added live backup progress updates in the result modal so long-running copies show an active progress bar, current phase, and current item.
- The Windows backup script now emits structured progress markers during preparation, current-copy, and snapshot-copy phases.

## 1.0.10-beta.12 - 2026-03-19

- Fixed a retention-rotation PowerShell error when the destination had zero or one snapshot folder, which could surface as `The property 'Count' cannot be found`.

## 1.0.10-beta.11 - 2026-03-19

- Fixed snapshot history refresh so the app re-reads the destination `snapshots` folder after a backup attempt instead of only trusting the status file.
- This keeps the snapshot list in sync when a snapshot folder was created on disk but the backup later reported a warning or partial-copy error.

## 1.0.10-beta.10 - 2026-03-19

- Added estimated backup size and destination free-space analysis in Settings.
- Clarified retention behavior in the UI and changed snapshot handling so the oldest snapshot is removed before the next backup when the limit is reached.
- Improved destination guidance so the final backup location is shown more clearly in Settings.

## 1.0.10-beta.9 - 2026-03-19

- Fixed the cloud-health footer so a completed cloud review no longer shows as “not checked.”
- Added an in-progress backup modal so `Run Backup Now` gives immediate status feedback while files are copying.
- Improved destination guidance in Settings so the final backup location is spelled out more clearly.
- Cleaned backup failure messaging for disk-full and partial-copy cases so they read as user guidance instead of stack traces.

## 1.0.10-beta.8 - 2026-03-19

- Fixed the updater flow so `Install Update Now` no longer loses the downloaded-update state after a successful download.
- Stopped updater reconfiguration from resetting the current update status between check, download, and install steps.

## 1.0.10-beta.7 - 2026-03-19

- Added browser detection for common Windows browsers so their user-data folders can be added without browsing hidden AppData paths manually.
- Added a browser selection popup that lets users choose which detected browsers to include in backups.
- Added duplicate-safe browser backup job creation for Chrome, Edge, Brave, Firefox, and Opera when their profile folders are present.

## 1.0.10-beta.6 - 2026-03-19

- Hid the updater progress bar until an update is actively downloading.
- Added a clearer cloud-health badge with green healthy and red attention states.
- Upgraded OneDrive health checks to report a `success` state when installed, running, and protecting known folders.

## 1.0.10-beta.5 - 2026-03-19

- Fixed updater initialization so the Settings update controls are active immediately in the installed Windows app.
- Changed backup failures from raw `Robocopy exit code 8` errors into friendlier guidance for locked or inaccessible files.
- Added `/XJ` to folder copy operations to avoid common junction-related backup failures.

## 1.0.10-beta.4 - 2026-03-19

- Reworked the Settings updater section to match the `PC AutoSpec` pattern more closely.
- Added a dedicated updates card with current version, latest version, status text, progress bar, and action buttons.
- Added live updater status pushes from the Electron main process so download progress updates inside Settings instead of only after the download finishes.

## 1.0.10-beta.3 - 2026-03-19

- Added an in-app `Download Update` action when a newer beta build is found.
- Added an in-app `Install Now` action after the update package finishes downloading.
- Surfaced updater download progress and install-ready state through the existing update status messaging.

## 1.0.10-beta.2 - 2026-03-19

- Fixed destination selection so browsing for a backup drive updates the saved backup target correctly.
- Cleaned up backup error messages so unresolved-drive failures read as user guidance instead of raw PowerShell traces.
- Added an update-check result popup with a shortcut to the GitHub releases page.
- Added stronger cloud warning presentation when the cloud sync check reports issues.
- Restyled the Settings drawer to match the structure and footer pattern used in the other One Bite dashboard apps.

## 1.0.10-beta.1 - 2026-03-19

- Switched the internal updater flow to a real beta channel using a prerelease semver version.
- Explicitly configured the GitHub publish channel as `beta`.
- Configured the app updater to request the `beta` channel during update checks.
- Expanded the Windows installer artifact upload to include all generated update channel metadata files.

## 1.0.9 - 2026-03-18

- Switched GitHub publishing from draft releases to prereleases for internal update testing.
- Configured the in-app updater to allow prerelease updates so `Check For Updates` can see internal test builds.
- Renamed the manual GitHub Actions release job to reflect the internal prerelease flow.

## 1.0.8 - 2026-03-18

- Added a result popup for cloud checks and backup runs so users get immediate feedback.
- Added a OneDrive launcher button to the cloud-check result popup when the desktop app can open it.

## 1.0.7 - 2026-03-18

- Fixed packaged startup failures caused by BOM-prefixed JSON config/status files.
- Updated the desktop app to strip UTF-8 BOM markers before parsing JSON.
- Updated Windows backup and cloud-health scripts to write JSON without a BOM.

## 1.0.6 - 2026-03-18

- Moved `electron-updater` loading out of normal startup and into the manual update-check path.
- Reduced packaged startup work so the app reaches `ready` with fewer pre-window dependencies.

## 1.0.5 - 2026-03-18

- Added earlier Electron lifecycle logging for `will-finish-launching`, `ready`, `whenReady`, and child-process exits.
- Added a startup watchdog entry so hidden stalls before `ready` are captured in the temp log.

## 1.0.4 - 2026-03-18

- Disabled hardware acceleration for packaged startup to reduce hidden-window and GPU-related launch failures.
- Changed startup logging to write to the system temp directory before Electron is fully ready.
- Changed the main window to show immediately so launch issues are easier to diagnose on affected PCs.

## 1.0.3 - 2026-03-18

- Added window and renderer startup diagnostics for packaged Windows builds.
- Added explicit logging for preload failures, load failures, renderer exits, and startup visibility issues.
- Added a fallback that forces the main window to show if startup stalls before `ready-to-show`.

## 1.0.2 - 2026-03-18

- Added stronger action feedback so backup and cloud-check buttons show a working state and clearer failures.
- Added more detailed Windows launcher logging around backup, cloud-check, and automation actions.
- Configured the Windows uninstaller to offer removal of app data during uninstall.

## 1.0.1 - 2026-03-17

- Added visible in-app version information in the main screen and Settings drawer.
- Added a manual `Check For Updates` action and surfaced update status in Settings.
- Added launcher logging to help diagnose packaged Windows startup failures.
- Changed backup status handling so a missing destination is shown as `Backup Drive Missing`.
- Changed destination setup to focus on browsing for a backup folder instead of entering drive details.
- Fixed GitHub Actions packaging so standard CI builds do not try to auto-publish releases.
- Fixed packaged Windows shell launching so backup and cloud-check actions run from a real working directory instead of the app archive path.

## 1.0.0 - 2026-03-17

- Initial branded Electron installer build for customer testing.
- Added Windows backup engine, snapshot retention, cloud health checks, and scheduled task support.
- Added customer terms gate with internal-use bypass.
- Added GitHub Actions workflow for Windows installer builds.
