const { app, BrowserWindow, dialog, ipcMain } = require("electron");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

let autoUpdater = null;
try {
  ({ autoUpdater } = require("electron-updater"));
} catch (_error) {
  autoUpdater = null;
}

const APP_ROOT = __dirname;
const RESOURCE_ROOT = app.isPackaged ? process.resourcesPath : APP_ROOT;
const DEFAULT_DATA_DIR = path.join(RESOURCE_ROOT, "data");
const WINDOWS_DIR = path.join(RESOURCE_ROOT, "windows");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
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

    const tryShell = (index) => {
      if (index >= shellCandidates.length) {
        const cmdPath = process.env.ComSpec || path.join(process.env.SystemRoot || "C:\\Windows", "System32", "cmd.exe");
        const commandLine = `"powershell.exe" ${args.map((value) => `"${value}"`).join(" ")}`;
        const child = spawn(cmdPath, ["/d", "/s", "/c", commandLine], {
          cwd: APP_ROOT
        });

        let stdout = "";
        let stderr = "";
        let settled = false;

        child.on("error", (error) => {
          if (settled) {
            return;
          }

          settled = true;
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
          resolve({
            ok: code === 0,
            code,
            message: stderr.trim() || stdout.trim() || `Exited with code ${code}.`
          });
        });
        return;
      }

      const child = spawn(shellCandidates[index], args, {
        cwd: APP_ROOT
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
          tryShell(index + 1);
          return;
        }

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
  const window = new BrowserWindow({
    width: 1360,
    height: 920,
    minWidth: 1080,
    minHeight: 760,
    backgroundColor: "#f4efe7",
    title: "One Bite Technology Backup Companion",
    webPreferences: {
      preload: path.join(APP_ROOT, "preload.js")
    }
  });

  window.loadFile(path.join(APP_ROOT, "index.html"));
}

function configureAutoUpdates() {
  if (!autoUpdater || !app.isPackaged || process.platform !== "win32") {
    return;
  }

  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.checkForUpdatesAndNotify().catch(() => {});
}

app.whenReady().then(() => {
  ensureDataFiles();
  createWindow();
  configureAutoUpdates();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

ipcMain.handle("state:get", () => {
  const { configPath, statusPath } = dataPaths();
  return {
    config: readJson(configPath),
    status: readJson(statusPath)
  };
});

ipcMain.handle("config:save", (_event, config) => {
  const { configPath, statusPath } = dataPaths();
  writeJson(configPath, config);
  return {
    config,
    status: readJson(statusPath)
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

ipcMain.handle("backup:run", async () => {
  const result = await runPowerShell("backup-engine.ps1");
  return {
    status: mergeStatus({
      lastBackupResult: result.ok ? "success" : "error",
      lastBackupMessage: result.message
    })
  };
});

ipcMain.handle("cloud:check", async () => {
  const result = await runPowerShell("check-cloud-health.ps1");
  const { statusPath } = dataPaths();
  return {
    status: mergeStatus({
      cloud: {
        ...readJson(statusPath).cloud,
        checkedAt: new Date().toISOString(),
        summary: result.message || "Cloud check completed."
      }
    })
  };
});

ipcMain.handle("automation:install", async () => {
  const result = await runPowerShell("install-scheduled-backup.ps1");
  return {
    status: mergeStatus({
      lastBackupMessage: result.message
    })
  };
});
