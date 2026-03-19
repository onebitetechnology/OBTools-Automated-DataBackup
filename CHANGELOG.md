# Changelog

All notable changes to `OBTools Automated Backups` should be recorded in this file.

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
