# Internal Releases

## Current State

The app is prepared for local Electron development and Windows installer builds.

Current app version:

```text
1.0.10-beta.29
```

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

3. GitHub Actions now builds the Windows installer and publishes automatically on pushes to `main`.

Release channel behavior:

- Versions with `-beta` in the version string publish as GitHub prereleases on the `beta` channel.
- Plain versions like `1.1.0` publish as stable GitHub releases on the default `latest` channel.
- Installed apps can choose between stable-only updates and beta/test builds from Settings.

Workflow file:

```text
.github/workflows/build-windows-installer.yml
```

4. You can still publish manually if needed from a machine with GitHub token access:

```bash
GH_TOKEN=your_github_token npm run release:win
```

5. For manual internal testing, you can still upload the generated installer from `dist/` or share it directly.

## Versioning Discipline

Before shipping a new internal installer:

1. Update the version in `package.json`
2. Add the matching release notes to `CHANGELOG.md`
3. Push to `main` so GitHub Actions builds an installer with the new version in its filename and app metadata

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
- prerelease-aware internal update channel for GitHub release testing
- explicit `beta` channel configuration for GitHub prerelease updates
- automatic prerelease publishing from GitHub Actions on pushes to `main`
