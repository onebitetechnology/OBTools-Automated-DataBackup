# One Bite Technology Backup Companion

Local Windows-focused backup app for One Bite Technology customers and staff. It provides:

- one-click backup and sync to USB/HDD targets
- configurable backup jobs for folders, files, and bookmark exports
- redundant snapshot retention
- automated scheduled backups through Windows Task Scheduler
- reminder warnings when backups go stale
- OneDrive/cloud health checks with recommendations

## Desktop App Build

Install dependencies:

```bash
npm install
```

Run the desktop app in development:

```bash
npm start
```

Build a Windows installer `.exe`:

```bash
npm run dist:win
```

The installer output will be created in `dist/` as:

```text
OneBiteBackupCompanion-Setup-<version>.exe
```

## Browser Preview

```bash
npm run start:web
```

Open:

```text
http://localhost:3200
```

## Customer Install Model

For customers, ship the generated NSIS installer. The installed Electron app stores customer config and status data under the Windows user profile, while the bundled PowerShell scripts handle:

- backup execution
- snapshot rotation
- scheduled task installation
- stale-backup reminders
- OneDrive health checks and recommendations

Main scripts:

- `windows/backup-engine.ps1`
- `windows/install-scheduled-backup.ps1`
- `windows/check-reminders.ps1`
- `windows/check-cloud-health.ps1`

## Files

- `server.js` - local HTTP server and API layer
- `index.html` - branded One Bite Technology interface
- `app.js` - frontend behavior
- `styles.css` - UI styling
- `data/config.json` - persisted backup configuration
- `data/status.json` - persisted backup/schedule/cloud status
