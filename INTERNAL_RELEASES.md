# Internal Releases

## Current State

The app is prepared for local Electron development and Windows installer builds.

Desktop shortcut name:

```text
OBTools Automated Backups
```

Build command:

```bash
npm run dist:win
```

## Internal GitHub Testing Flow

Repository:

```text
https://github.com/onebitetechnology/OBTools-Automated-DataBackup
```

1. Install dependencies locally:

```bash
npm install
```

2. Build a Windows installer:

```bash
npm run dist:win
```

3. Publish a draft GitHub release with the installer and update metadata:

```bash
GH_TOKEN=your_github_token npm run release:win
```

4. For manual internal testing, you can still upload the generated installer from `dist/` or share it directly.

## Internet Updates

The app is now partially wired for GitHub-based update checks.

Still needed before this is production-ready:

- a release channel decision for internal testing vs production
- Windows code-signing strategy for smoother installs and updates
- dependency installation via `npm install`
- initial release publishing from a machine with GitHub token access

Implemented now:

- `electron-updater`
- GitHub publish configuration in `package.json`
- packaged-app update checks in `main.js`
