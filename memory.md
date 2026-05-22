# DataSafe Project Memory

- 2026-05-22: After beta55 scheduler validation, `automationSettingsChanged` now treats `reminders.staleDays` as an automation setting so saving the reminder threshold refreshes Windows scheduled tasks and shows the same update result path as other automation changes.
- 2026-05-22: A beta56 screenshot showed `Register-ScheduledTask` access denied on `OneBiteBackupCatchUp` while creating the startup/logon catch-up task. Beta57 keeps sign-in catch-up for normal users and only adds the startup trigger when running elevated.
- 2026-05-22: Beta58 made update discovery proactive: DataSafe now checks for updates at startup and every 6 hours while running, then shows one in-app update prompt per available version with Download Update and Later actions.
