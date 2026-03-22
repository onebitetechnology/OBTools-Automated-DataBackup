const packageJson = require("./package.json");

const inferredChannel = /-beta/i.test(packageJson.version) ? "beta" : "latest";
const releaseChannel = process.env.OBTOOLS_RELEASE_CHANNEL || inferredChannel;
const releaseType = process.env.OBTOOLS_RELEASE_TYPE || (releaseChannel === "beta" ? "prerelease" : "release");

module.exports = {
  appId: "ca.onebitetechnology.backupcompanion",
  productName: "OBTools Automated Backups",
  generateUpdatesFilesForAllChannels: true,
  files: [
    "app.js",
    "assets/**/*",
    "index.html",
    "main.js",
    "preload.js",
    "server.js",
    "styles.css"
  ],
  extraResources: [
    {
      from: "data",
      to: "data"
    },
    {
      from: "windows",
      to: "windows"
    }
  ],
  asar: true,
  win: {
    target: [
      {
        target: "nsis",
        arch: ["x64"]
      }
    ],
    artifactName: "OBTools-Automated-Backups-Setup-${version}.${ext}",
    publish: [
      {
        provider: "github",
        owner: "onebitetechnology",
        repo: "OBTools-Automated-DataBackup",
        channel: releaseChannel,
        releaseType
      }
    ]
  },
  nsis: {
    oneClick: false,
    allowToChangeInstallationDirectory: true,
    createDesktopShortcut: true,
    createStartMenuShortcut: true,
    deleteAppDataOnUninstall: true,
    shortcutName: "OBTools Automated Backups"
  }
};
