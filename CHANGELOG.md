# Changelog

All notable changes to `OBTools Automated Backups` should be recorded in this file.

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
