const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const APP_ROOT = __dirname;
const RESOURCE_ROOT = app.isPackaged ? process.resourcesPath : APP_ROOT;
const DEFAULT_DATA_DIR = path.join(RESOURCE_ROOT, "data");
const WINDOWS_DIR = path.join(RESOURCE_ROOT, "windows");
const SHELL_WORK_DIR = RESOURCE_ROOT;
let updateStatus = {
  supported: app.isPackaged && process.platform === "win32",
  checkedAt: null,
  message: app.isPackaged && process.platform === "win32"
    ? "Check for updates to look for new internal beta releases."
    : "Update checks are only available in the installed Windows app.",
  updateAvailable: false,
  availableVersion: null,
  downloading: false,
  downloaded: false,
  downloadProgress: null
};
let autoUpdater = null;
let autoUpdaterConfigured = false;

function publishUpdateStatus() {
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.isDestroyed()) {
      window.webContents.send("updates:status", updateStatus);
    }
  }
}

function writeLauncherLog(message) {
  try {
    const logRoot = app.isReady() ? app.getPath("userData") : os.tmpdir();
    const logPath = path.join(logRoot, "obtools-launcher.log");
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, `[${new Date().toISOString()}] ${message}\n`, "utf8");
  } catch (_error) {
    // Logging should never crash the app.
  }
}

app.disableHardwareAcceleration();
writeLauncherLog("Process starting. Hardware acceleration disabled.");

let readyLogged = false;

function readJson(filePath) {
  const raw = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
  return JSON.parse(raw);
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function defaultStatus() {
  return {
    lastBackupAt: null,
    lastBackupResult: null,
    lastBackupMessage: "No backups have been run yet.",
    destinationStatus: "Unknown",
    recentSnapshots: [],
    cloud: {
      checkedAt: null,
      summary: "Cloud check has not been run yet.",
      level: "info",
      recommendations: []
    },
    automation: {
      installedAt: null,
      message: "Windows automation has not been installed yet."
    }
  };
}

function dataPaths() {
  const userDataDir = app.getPath("userData");
  return {
    userDataDir,
    configPath: path.join(userDataDir, "config.json"),
    statusPath: path.join(userDataDir, "status.json")
  };
}

function ensureDataFiles() {
  const { userDataDir, configPath, statusPath } = dataPaths();
  fs.mkdirSync(userDataDir, { recursive: true });

  if (!fs.existsSync(configPath)) {
    fs.copyFileSync(path.join(DEFAULT_DATA_DIR, "config.json"), configPath);
  }

  if (!fs.existsSync(statusPath)) {
    fs.copyFileSync(path.join(DEFAULT_DATA_DIR, "status.json"), statusPath);
  }

  const status = readJson(statusPath);
  if (
    (typeof status.lastBackupMessage === "string" && status.lastBackupMessage.startsWith("Preview mode:")) ||
    status.destinationStatus === "Preview Mode" ||
    (typeof status.cloud?.summary === "string" && status.cloud.summary.startsWith("Preview mode:")) ||
    (typeof status.automation?.message === "string" && status.automation.message.startsWith("Preview mode:"))
  ) {
    writeJson(statusPath, defaultStatus());
  }
}

function mergeStatus(patch) {
  const { statusPath } = dataPaths();
  const next = {
    ...readJson(statusPath),
    ...patch
  };
  writeJson(statusPath, next);
  return next;
}

function appMeta() {
  return {
    version: app.getVersion(),
    updateStatus
  };
}

function deriveDestinationStatus(message, ok) {
  if (ok) {
    return "Connected";
  }

  if (!message) {
    return "Unknown";
  }

  if (/destination drive is not available/i.test(message) || /no destination drive could be resolved/i.test(message)) {
    return "Drive Not Connected";
  }

  return "Issue Detected";
}

function envValue(name) {
  const exact = process.env[name];
  if (exact) {
    return exact;
  }

  const foundKey = Object.keys(process.env).find((key) => key.toLowerCase() === String(name).toLowerCase());
  return foundKey ? process.env[foundKey] : undefined;
}

function expandEnvironmentVariables(value) {
  return String(value || "").replace(/%([^%]+)%/g, (_match, name) => envValue(name) || `%${name}%`);
}

function resolveDestinationRoot(destination) {
  if (!destination) {
    return null;
  }

  if (destination.selectedPath) {
    return path.parse(destination.selectedPath).root || null;
  }

  if (destination.driveLetter) {
    return `${String(destination.driveLetter).replace(":", "")}:\\`;
  }

  return null;
}

function calculatePathSize(targetPath) {
  if (!targetPath || !fs.existsSync(targetPath)) {
    return 0;
  }

  const stack = [targetPath];
  let total = 0;

  while (stack.length) {
    const current = stack.pop();
    let stats;

    try {
      stats = fs.lstatSync(current);
    } catch (_error) {
      continue;
    }

    if (stats.isSymbolicLink()) {
      continue;
    }

    if (stats.isFile()) {
      total += stats.size;
      continue;
    }

    if (!stats.isDirectory()) {
      continue;
    }

    let entries = [];
    try {
      entries = fs.readdirSync(current);
    } catch (_error) {
      continue;
    }

    for (const entry of entries) {
      stack.push(path.join(current, entry));
    }
  }

  return total;
}

function analyzeStorage(config) {
  const destinationRoot = resolveDestinationRoot(config?.destination);
  const enabledJobs = (config?.jobs || []).filter((job) => job.enabled);
  const missingPaths = [];
  let estimatedBytes = 0;

  for (const job of enabledJobs) {
    const resolvedPath = expandEnvironmentVariables(job.path);
    if (!resolvedPath || !fs.existsSync(resolvedPath)) {
      missingPaths.push(resolvedPath || job.path || "(empty path)");
      continue;
    }
    estimatedBytes += calculatePathSize(resolvedPath);
  }

  let freeBytes = null;
  if (destinationRoot && fs.existsSync(destinationRoot) && typeof fs.statfsSync === "function") {
    try {
      const stats = fs.statfsSync(destinationRoot);
      freeBytes = Number(stats.bavail) * Number(stats.bsize);
    } catch (_error) {
      freeBytes = null;
    }
  }

  return {
    estimatedBytes,
    freeBytes,
    destinationRoot,
    missingPaths,
    retentionCount: Math.max(Number(config?.retentionCount || 1), 1)
  };
}

function detectInstalledBrowsers() {
  if (process.platform !== "win32") {
    return [];
  }

  const localAppData = process.env.LOCALAPPDATA || "";
  const roamingAppData = process.env.APPDATA || "";
  const checks = [
    {
      id: "chrome-user-data",
      name: "Google Chrome",
      path: path.join(localAppData, "Google", "Chrome", "User Data"),
      detail: "Chrome profiles, bookmarks, extensions, and browser settings"
    },
    {
      id: "edge-user-data",
      name: "Microsoft Edge",
      path: path.join(localAppData, "Microsoft", "Edge", "User Data"),
      detail: "Edge profiles, bookmarks, extensions, and browser settings"
    },
    {
      id: "brave-user-data",
      name: "Brave",
      path: path.join(localAppData, "BraveSoftware", "Brave-Browser", "User Data"),
      detail: "Brave profiles, bookmarks, extensions, and browser settings"
    },
    {
      id: "firefox-profiles",
      name: "Mozilla Firefox",
      path: path.join(roamingAppData, "Mozilla", "Firefox"),
      detail: "Firefox profiles, bookmarks, and browser settings"
    },
    {
      id: "opera-stable",
      name: "Opera",
      path: path.join(roamingAppData, "Opera Software"),
      detail: "Opera profiles and browser settings"
    }
  ];

  return checks
    .filter((entry) => entry.path && fs.existsSync(entry.path))
    .map((entry) => ({
      ...entry,
      type: "folder"
    }));
}

function simulateAction(scriptName) {
  const { statusPath } = dataPaths();
  const status = readJson(statusPath);
  const now = new Date();

  if (scriptName === "backup-engine.ps1") {
    const timestamp = now.toISOString().replace(/[:.]/g, "-");
    status.lastBackupAt = now.toISOString();
    status.lastBackupResult = "success";
    status.lastBackupMessage = "Preview mode: simulated backup completed on this device.";
    status.destinationStatus = "Preview Mode";
    status.recentSnapshots = [timestamp, ...(status.recentSnapshots || [])].slice(0, 5);
    writeJson(statusPath, status);
    return { ok: true, message: status.lastBackupMessage };
  }

  if (scriptName === "check-cloud-health.ps1") {
    status.cloud = {
      checkedAt: now.toISOString(),
      summary: "Preview mode: cloud sync review completed.",
      level: "info",
      recommendations: [
        "Confirm OneDrive or another cloud sync tool is signed in on the customer PC.",
        "Keep local USB backups enabled even when cloud sync appears healthy."
      ]
    };
    writeJson(statusPath, status);
    return { ok: true, message: status.cloud.summary };
  }

  if (scriptName === "install-scheduled-backup.ps1") {
    status.automation = {
      installedAt: now.toISOString(),
      message: "Preview mode: Windows automation simulated."
    };
    writeJson(statusPath, status);
    return { ok: true, message: status.automation.message };
  }

  return { ok: true, message: `Preview mode: simulated ${scriptName}.` };
}

function runPowerShell(scriptName) {
  return new Promise((resolve) => {
    if (process.platform !== "win32") {
      resolve({
        ...simulateAction(scriptName),
        code: 0
      });
      return;
    }

    const { configPath, statusPath } = dataPaths();
    const scriptPath = path.join(WINDOWS_DIR, scriptName);
    writeLauncherLog(`Running ${scriptName} with script path ${scriptPath}`);
    const args = [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptPath,
      "-ConfigPath",
      configPath,
      "-StatusPath",
      statusPath
    ];

    if (scriptName === "install-scheduled-backup.ps1") {
      args.push("-ScriptRoot", WINDOWS_DIR);
    }

    const shellCandidates = [
      path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
      path.join(process.env.SystemRoot || "C:\\Windows", "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe"),
      path.join(process.env.ProgramFiles || "C:\\Program Files", "PowerShell", "7", "pwsh.exe"),
      "powershell.exe",
      "pwsh.exe"
    ];

    const resolvedShellCandidates = shellCandidates.filter((candidate) => {
      if (!candidate.includes("\\") && !candidate.includes("/")) {
        return true;
      }

      return fs.existsSync(candidate);
    });

    const tryShell = (index) => {
      if (index >= resolvedShellCandidates.length) {
        const cmdCandidates = [
          process.env.ComSpec,
          path.join(process.env.SystemRoot || "C:\\Windows", "System32", "cmd.exe")
        ].filter(Boolean);
        const cmdPath = cmdCandidates.find((candidate) => fs.existsSync(candidate)) || "cmd.exe";
        writeLauncherLog(`No direct PowerShell candidate succeeded for ${scriptName}. Falling back to ${cmdPath}.`);
        const commandLine = `"powershell.exe" ${args.map((value) => `"${value}"`).join(" ")}`;
        const child = spawn(cmdPath, ["/d", "/s", "/c", commandLine], {
          cwd: SHELL_WORK_DIR,
          windowsHide: true
        });

        let stdout = "";
        let stderr = "";
        let settled = false;

        child.on("error", (error) => {
          if (settled) {
            return;
          }

          settled = true;
          writeLauncherLog(`Fallback shell launch failed for ${scriptName}: ${error.message}`);
          resolve({
            ok: false,
            code: -1,
            message: `PowerShell could not be found on this Windows system. ${error.message}`
          });
        });

        child.stdout.on("data", (chunk) => {
          stdout += chunk.toString();
        });

        child.stderr.on("data", (chunk) => {
          stderr += chunk.toString();
        });

        child.on("close", (code) => {
          if (settled) {
            return;
          }

          settled = true;
          writeLauncherLog(`Fallback shell exited for ${scriptName} with code ${code}. stderr=${stderr.trim()} stdout=${stdout.trim()}`);
          resolve({
            ok: code === 0,
            code,
            message: stderr.trim() || stdout.trim() || `Exited with code ${code}.`
          });
        });
        return;
      }

      const shellPath = resolvedShellCandidates[index];
      writeLauncherLog(`Trying shell ${shellPath} for ${scriptName}`);
      const child = spawn(shellPath, args, {
        cwd: SHELL_WORK_DIR,
        windowsHide: true
      });

      let stdout = "";
      let stderr = "";
      let settled = false;

      child.on("error", (error) => {
        if (settled) {
          return;
        }

        settled = true;
        if (error.code === "ENOENT") {
          writeLauncherLog(`Shell not found for ${scriptName}: ${shellPath}`);
          tryShell(index + 1);
          return;
        }

        writeLauncherLog(`Shell launch error for ${scriptName}: ${error.message}`);
        resolve({
          ok: false,
          code: -1,
          message: `Failed to launch PowerShell: ${error.message}`
        });
      });

      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
      });

      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });

      child.on("close", (code) => {
        if (settled) {
          return;
        }

        settled = true;
        writeLauncherLog(`Shell exited for ${scriptName} with code ${code}. stderr=${stderr.trim()} stdout=${stdout.trim()}`);
        resolve({
          ok: code === 0,
          code,
          message: stderr.trim() || stdout.trim() || `Exited with code ${code}.`
        });
      });
    };

    tryShell(0);
  });
}

function createWindow() {
  writeLauncherLog("Creating main window.");
  const window = new BrowserWindow({
    width: 1360,
    height: 920,
    minWidth: 1080,
    minHeight: 760,
    backgroundColor: "#f4efe7",
    title: "One Bite Technology Backup Companion",
    show: true,
    webPreferences: {
      preload: path.join(APP_ROOT, "preload.js")
    }
  });

  const indexPath = path.join(APP_ROOT, "index.html");
  writeLauncherLog(`Window preload path: ${path.join(APP_ROOT, "preload.js")}`);
  writeLauncherLog(`Window index path: ${indexPath}`);

  window.once("ready-to-show", () => {
    writeLauncherLog("Main window ready-to-show.");
    window.show();
    window.focus();
  });

  window.on("show", () => {
    writeLauncherLog("Main window shown.");
  });

  window.on("closed", () => {
    writeLauncherLog("Main window closed.");
  });

  window.on("unresponsive", () => {
    writeLauncherLog("Main window became unresponsive.");
  });

  window.webContents.on("did-start-loading", () => {
    writeLauncherLog("Renderer started loading.");
  });

  window.webContents.on("did-finish-load", () => {
    writeLauncherLog("Renderer finished loading.");
  });

  window.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL) => {
    writeLauncherLog(`Renderer failed to load. code=${errorCode} description=${errorDescription} url=${validatedURL}`);
    dialog.showErrorBox(
      "OBTools Automated Backups",
      `The app window failed to load.\n\n${errorDescription} (${errorCode})`
    );
  });

  window.webContents.on("render-process-gone", (_event, details) => {
    writeLauncherLog(`Renderer process gone. reason=${details.reason} exitCode=${details.exitCode}`);
  });

  window.webContents.on("preload-error", (_event, preloadPath, error) => {
    writeLauncherLog(`Preload error at ${preloadPath}: ${error.message}`);
    dialog.showErrorBox("OBTools Automated Backups", `Preload failed: ${error.message}`);
  });

  window.webContents.on("console-message", (_event, level, message, line, sourceId) => {
    if (level >= 2) {
      writeLauncherLog(`Renderer console level=${level} ${sourceId}:${line} ${message}`);
    }
  });

  setTimeout(() => {
    if (!window.isDestroyed() && !window.isVisible()) {
      writeLauncherLog("Window was not visible after startup timeout. Forcing show.");
      window.show();
      window.focus();
    }
  }, 2500);

  window.loadFile(indexPath).catch((error) => {
    writeLauncherLog(`loadFile failed: ${error.stack || error.message}`);
    dialog.showErrorBox("OBTools Automated Backups", error.message);
  });
}

function configureAutoUpdates() {
  if (!app.isPackaged || process.platform !== "win32") {
    updateStatus = {
      supported: false,
      checkedAt: null,
      message: "Update checks are only available in the installed Windows app.",
      updateAvailable: false,
      availableVersion: null,
      downloading: false,
      downloaded: false,
      downloadProgress: null
    };
    publishUpdateStatus();
    return;
  }

  if (autoUpdaterConfigured) {
    return;
  }

  updateStatus = {
    supported: true,
    checkedAt: null,
    message: "Check for updates to look for new internal beta releases.",
    updateAvailable: false,
    availableVersion: null,
    downloading: false,
    downloaded: false,
    downloadProgress: null
  };
  publishUpdateStatus();

  try {
    ({ autoUpdater } = require("electron-updater"));
  } catch (error) {
    writeLauncherLog(`electron-updater could not be loaded: ${error.message}`);
    updateStatus = {
      supported: false,
      checkedAt: null,
      message: `Update checks are unavailable: ${error.message}`,
      updateAvailable: false,
      availableVersion: null,
      downloading: false,
      downloaded: false,
      downloadProgress: null
    };
    publishUpdateStatus();
    return;
  }

  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.channel = "beta";
  autoUpdater.allowPrerelease = true;
  autoUpdaterConfigured = true;
  writeLauncherLog("Auto updater configured for internal beta channel.");

  autoUpdater.on("checking-for-update", () => {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: "Checking for updates...",
      updateAvailable: false,
      availableVersion: null,
      downloading: false,
      downloaded: false,
      downloadProgress: null
    };
    publishUpdateStatus();
  });

  autoUpdater.on("update-available", (info) => {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: `Update ${info?.version || "available"} is available to download.`,
      updateAvailable: true,
      availableVersion: info?.version || null,
      downloading: false,
      downloaded: false,
      downloadProgress: null
    };
    publishUpdateStatus();
  });

  autoUpdater.on("update-not-available", () => {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: "This machine is already on the latest published build.",
      updateAvailable: false,
      availableVersion: app.getVersion(),
      downloading: false,
      downloaded: false,
      downloadProgress: null
    };
    publishUpdateStatus();
  });

  autoUpdater.on("download-progress", (progress) => {
    const percent = Math.round(progress?.percent || 0);
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: `Downloading update${updateStatus.availableVersion ? ` ${updateStatus.availableVersion}` : ""}... ${percent}%`,
      downloading: true,
      downloaded: false,
      downloadProgress: percent
    };
    publishUpdateStatus();
  });

  autoUpdater.on("update-downloaded", (info) => {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: `Update ${info?.version || updateStatus.availableVersion || ""} downloaded and ready to install.`.trim(),
      updateAvailable: true,
      availableVersion: info?.version || updateStatus.availableVersion || null,
      downloading: false,
      downloaded: true,
      downloadProgress: 100
    };
    publishUpdateStatus();
  });

  autoUpdater.on("error", (error) => {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: `Update check failed: ${error.message}`,
      downloading: false
    };
    publishUpdateStatus();
  });
}

app.on("will-finish-launching", () => {
  writeLauncherLog("App will-finish-launching fired.");
});

app.on("ready", () => {
  readyLogged = true;
  writeLauncherLog("App ready event fired.");
});

app.on("browser-window-created", () => {
  writeLauncherLog("Browser window created event fired.");
});

app.on("child-process-gone", (_event, details) => {
  writeLauncherLog(`Child process gone. type=${details.type} reason=${details.reason} exitCode=${details.exitCode}`);
});

app.whenReady().then(() => {
  writeLauncherLog("App whenReady resolved. Initializing data and window.");
  ensureDataFiles();
  createWindow();

  app.on("activate", () => {
    writeLauncherLog("App activate event fired.");
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
}).catch((error) => {
  writeLauncherLog(`App whenReady rejected: ${error.stack || error.message}`);
});

setTimeout(() => {
  if (!readyLogged) {
    writeLauncherLog("Startup watchdog: app ready was not reached within 10 seconds.");
  }
}, 10000);

process.on("uncaughtException", (error) => {
  writeLauncherLog(`Uncaught exception: ${error.stack || error.message}`);
  if (app.isReady()) {
    dialog.showErrorBox("OBTools Automated Backups", error.message);
  }
});

process.on("unhandledRejection", (error) => {
  const message = error && typeof error === "object" && "stack" in error ? error.stack : String(error);
  writeLauncherLog(`Unhandled rejection: ${message}`);
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

ipcMain.handle("state:get", () => {
  configureAutoUpdates();
  const { configPath, statusPath } = dataPaths();
  return {
    config: readJson(configPath),
    status: readJson(statusPath),
    meta: appMeta()
  };
});

ipcMain.handle("config:save", (_event, config) => {
  const { configPath, statusPath } = dataPaths();
  writeJson(configPath, config);
  return {
    config,
    status: readJson(statusPath),
    meta: appMeta()
  };
});

ipcMain.handle("job:pick-path", async (_event, type) => {
  const properties = type === "file" ? ["openFile"] : ["openDirectory"];
  const result = await dialog.showOpenDialog({
    properties
  });

  if (result.canceled || !result.filePaths.length) {
    return null;
  }

  return result.filePaths[0];
});

ipcMain.handle("destination:pick-folder", async () => {
  const result = await dialog.showOpenDialog({
    properties: ["openDirectory"]
  });

  if (result.canceled || !result.filePaths.length) {
    return null;
  }

  const selectedPath = result.filePaths[0];
  const rootPath = path.parse(selectedPath).root;
  const driveLetter = rootPath.replace(/\\+$/, "").replace(":", "");
  const relativeFolder = path.relative(rootPath, selectedPath);

  return {
    driveLetter,
    baseFolder: relativeFolder === "" ? "" : relativeFolder,
    displayPath: selectedPath
  };
});

ipcMain.handle("browsers:detect", async () => {
  return {
    browsers: detectInstalledBrowsers()
  };
});

ipcMain.handle("storage:analyze", async () => {
  const { configPath } = dataPaths();
  const config = readJson(configPath);
  return {
    storage: analyzeStorage(config)
  };
});

ipcMain.handle("backup:run", async () => {
  writeLauncherLog("IPC backup:run received.");
  const result = await runPowerShell("backup-engine.ps1");
  writeLauncherLog(`IPC backup:run completed. ok=${result.ok} message=${result.message}`);
  return {
    status: mergeStatus({
      destinationStatus: deriveDestinationStatus(result.message, result.ok),
      lastBackupResult: result.ok ? "success" : "error",
      lastBackupMessage: result.message
    }),
    meta: appMeta()
  };
});

ipcMain.handle("cloud:check", async () => {
  writeLauncherLog("IPC cloud:check received.");
  const result = await runPowerShell("check-cloud-health.ps1");
  writeLauncherLog(`IPC cloud:check completed. ok=${result.ok} message=${result.message}`);
  const { statusPath } = dataPaths();
  return {
    status: mergeStatus({
      cloud: {
        ...readJson(statusPath).cloud,
        checkedAt: new Date().toISOString(),
        summary: result.message || "Cloud check completed."
      }
    }),
    meta: appMeta()
  };
});

ipcMain.handle("automation:install", async () => {
  writeLauncherLog("IPC automation:install received.");
  const result = await runPowerShell("install-scheduled-backup.ps1");
  writeLauncherLog(`IPC automation:install completed. ok=${result.ok} message=${result.message}`);
  return {
    status: mergeStatus({
      lastBackupMessage: result.message
    }),
    meta: appMeta()
  };
});

ipcMain.handle("updates:check", async () => {
  configureAutoUpdates();

  if (!updateStatus.supported || !autoUpdater) {
    return {
      meta: appMeta()
    };
  }

  try {
    await autoUpdater.checkForUpdates();
  } catch (error) {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: `Update check failed: ${error.message}`,
      updateAvailable: false
    };
    publishUpdateStatus();
  }

  return {
    meta: appMeta()
  };
});

ipcMain.handle("updates:download", async () => {
  configureAutoUpdates();

  if (!updateStatus.supported || !autoUpdater) {
    return {
      meta: appMeta()
    };
  }

  if (updateStatus.downloaded) {
    return {
      meta: appMeta()
    };
  }

  try {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: `Downloading update${updateStatus.availableVersion ? ` ${updateStatus.availableVersion}` : ""}...`,
      downloading: true,
      downloaded: false,
      downloadProgress: updateStatus.downloadProgress || 0
    };
    publishUpdateStatus();
    await autoUpdater.downloadUpdate();
  } catch (error) {
    updateStatus = {
      ...updateStatus,
      checkedAt: new Date().toISOString(),
      message: `Update download failed: ${error.message}`,
      downloading: false,
      downloaded: false
    };
    publishUpdateStatus();
  }

  return {
    meta: appMeta()
  };
});

ipcMain.handle("updates:install", async () => {
  configureAutoUpdates();

  if (!updateStatus.supported || !autoUpdater || !updateStatus.downloaded) {
    return {
      ok: false,
      meta: appMeta(),
      message: "No downloaded update is ready to install yet."
    };
  }

  updateStatus = {
    ...updateStatus,
    checkedAt: new Date().toISOString(),
    message: "Installing update and restarting the app..."
  };
  publishUpdateStatus();

  setTimeout(() => {
    autoUpdater.quitAndInstall(false, true);
  }, 200);

  return {
    ok: true,
    meta: appMeta(),
    message: "Installing update and restarting the app..."
  };
});

ipcMain.handle("updates:open-releases", async () => {
  try {
    await shell.openExternal("https://github.com/onebitetechnology/OBTools-Automated-DataBackup/releases");
    return {
      ok: true,
      message: "Opened the GitHub releases page."
    };
  } catch (error) {
    return {
      ok: false,
      message: error.message
    };
  }
});

ipcMain.handle("cloud:open-onedrive", async () => {
  const oneDriveExe = path.join(process.env.LOCALAPPDATA || "", "Microsoft", "OneDrive", "OneDrive.exe");
  const oneDriveFolder = path.join(process.env.USERPROFILE || "", "OneDrive");

  if (oneDriveExe && fs.existsSync(oneDriveExe)) {
    const result = await shell.openPath(oneDriveExe);
    return {
      ok: result === "",
      message: result || "OneDrive opened."
    };
  }

  if (oneDriveFolder && fs.existsSync(oneDriveFolder)) {
    const result = await shell.openPath(oneDriveFolder);
    return {
      ok: result === "",
      message: result || "Opened the OneDrive folder."
    };
  }

  return {
    ok: false,
    message: "OneDrive is not installed or no local OneDrive folder was found."
  };
});
