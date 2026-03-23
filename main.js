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
let currentUpdateChannel = null;
let updateStatus = {
  supported: app.isPackaged && process.platform === "win32",
  channel: "beta",
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

function publishBackupProgress(progress) {
  writeRuntimeLog(`Backup progress: phase=${progress?.phase || "unknown"} percent=${progress?.percent ?? "?"} job=${progress?.jobName || ""} detail=${progress?.detail || ""}`);
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.isDestroyed()) {
      window.webContents.send("backup:progress", progress);
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

function runtimeLogPath() {
  const logRoot = app.isReady() ? app.getPath("userData") : os.tmpdir();
  return path.join(logRoot, "obtools-runtime.log");
}

function launcherLogPath() {
  const logRoot = app.isReady() ? app.getPath("userData") : os.tmpdir();
  return path.join(logRoot, "obtools-launcher.log");
}

function writeRuntimeLog(message) {
  try {
    const logPath = runtimeLogPath();
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, `[${new Date().toISOString()}] ${message}\n`, "utf8");
  } catch (_error) {
    // Logging should never crash the app.
  }
}

function readLogTail(filePath, maxLines = 80) {
  if (!fs.existsSync(filePath)) {
    return "File not found.";
  }

  try {
    const lines = fs.readFileSync(filePath, "utf8").replace(/\r/g, "").split("\n").filter(Boolean);
    return lines.slice(-maxLines).join("\n") || "File is empty.";
  } catch (error) {
    return `Could not read log: ${error.message}`;
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

function defaultUpdateChannelForVersion(version = app.getVersion()) {
  return /-beta/i.test(String(version || "")) ? "beta" : "latest";
}

function sanitizeUpdateChannel(value, fallbackVersion = app.getVersion()) {
  if (value === "latest") {
    return "latest";
  }

  if (value === "beta") {
    return "beta";
  }

  return defaultUpdateChannelForVersion(fallbackVersion);
}

function normalizeConfigForMain(config) {
  const existingDestination = config?.destination || {};
  const normalizedBaseFolder = existingDestination.baseFolder === "One Bite Backups" || !existingDestination.baseFolder
    ? "OB Tools Backup"
    : existingDestination.baseFolder;
  const retentionSource = config?.retention || {};
  const legacyCount = Number(config?.retentionCount || 0);
  const normalizedRetention = {
    days: Math.max(Number(retentionSource.days ?? legacyCount ?? 3) || 0, 0),
    months: Math.max(Number(retentionSource.months ?? 0) || 0, 0),
    years: Math.max(Number(retentionSource.years ?? 0) || 0, 0)
  };

  if ((normalizedRetention.days + normalizedRetention.months + normalizedRetention.years) <= 0) {
    normalizedRetention.days = 1;
  }

  return {
    ...config,
    destination: {
      ...existingDestination,
      folderMode: "managed",
      baseFolder: normalizedBaseFolder
    },
    retention: normalizedRetention,
    retentionCount: undefined,
    updates: {
      channel: sanitizeUpdateChannel(config?.updates?.channel)
    }
  };
}

function retentionSummary(retention = { days: 1, months: 0, years: 0 }) {
  const parts = [];

  if (retention.days > 0) {
    parts.push(`${retention.days} ${retention.days === 1 ? "day" : "days"}`);
  }

  if (retention.months > 0) {
    parts.push(`${retention.months} ${retention.months === 1 ? "month" : "months"}`);
  }

  if (retention.years > 0) {
    parts.push(`${retention.years} ${retention.years === 1 ? "year" : "years"}`);
  }

  return parts.length ? parts.join(" / ") : "1 day";
}

function summarizeUpdateError(error, channel = currentUpdateChannel || "beta") {
  const raw = String(error?.message || error || "").trim();

  if (/unable to find latest version on github/i.test(raw) || /cannot parse releases feed/i.test(raw)) {
    return channel === "beta"
      ? "No published beta release could be found right now. Try again after the next beta build is published."
      : "No public release is available yet. Turn beta updates back on if you want to receive internal test builds.";
  }

  if (/net::|network|timed out|econn|enotfound/i.test(raw)) {
    return "The app could not reach the update server. Check the internet connection and try again.";
  }

  return `Update check failed: ${raw}`;
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

function supportEmailAddress() {
  return "jeff@onebitetechnology.ca";
}

function buildSupportBundle(config, status) {
  const { userDataDir } = dataPaths();
  const bundlePath = path.join(userDataDir, "obtools-support-request.txt");
  const runtimePath = runtimeLogPath();
  const launcherPath = launcherLogPath();
  const osLabel = `${os.type()} ${os.release()} (${os.arch()})`;
  const channel = sanitizeUpdateChannel(config?.updates?.channel, app.getVersion());
  const destinationRoot = resolveDestinationBasePath(config?.destination) || "Not configured";
  const enabledJobs = (config?.jobs || []).filter((job) => job.enabled).map((job) => `${job.name || "Unnamed"} :: ${job.path || "(empty path)"}`);
  const recentSnapshots = (status?.recentSnapshots || []).slice(0, 5);

  const bundle = [
    "OBTools Automated Backups Support Request",
    "=======================================",
    "",
    `Generated: ${new Date().toISOString()}`,
    `App version: ${app.getVersion()}`,
    `Update channel: ${channel}`,
    `Platform: ${process.platform}`,
    `OS: ${osLabel}`,
    "",
    "Current backup status",
    "---------------------",
    `Last backup at: ${status?.lastBackupAt || "Never"}`,
    `Last backup result: ${status?.lastBackupResult || "unknown"}`,
    `Last backup message: ${status?.lastBackupMessage || "None"}`,
    `Destination status: ${status?.destinationStatus || "Unknown"}`,
    `Cloud summary: ${status?.cloud?.summary || "Not checked"}`,
    "",
    "Configured backup destination",
    "-----------------------------",
    `Resolved destination: ${destinationRoot}`,
    `Folder mode: ${config?.destination?.folderMode || "managed"}`,
    `Retention plan: ${retentionSummary(config?.retention)}`,
    "",
    "Enabled backup items",
    "--------------------",
    ...(enabledJobs.length ? enabledJobs : ["None"]),
    "",
    "Recent snapshots",
    "----------------",
    ...(recentSnapshots.length ? recentSnapshots : ["None"]),
    "",
    `Logs folder: ${userDataDir}`,
    `Runtime log: ${runtimePath}`,
    `Launcher log: ${launcherPath}`,
    "",
    "Recent runtime log lines",
    "------------------------",
    readLogTail(runtimePath, 80),
    "",
    "Recent launcher log lines",
    "-------------------------",
    readLogTail(launcherPath, 80),
    ""
  ].join("\n");

  fs.writeFileSync(bundlePath, bundle, "utf8");
  return {
    bundlePath,
    userDataDir,
    runtimePath,
    launcherPath
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

function resolveDestinationBasePath(destination) {
  const destinationRoot = resolveDestinationRoot(destination);
  if (!destinationRoot) {
    return null;
  }

  const baseFolder = String(destination?.baseFolder || "").trim();
  return baseFolder ? path.join(destinationRoot, baseFolder) : destinationRoot;
}

function inspectSnapshots(config) {
  const baseRoot = resolveDestinationBasePath(config?.destination);
  if (!baseRoot) {
    return {
      baseRoot: null,
      snapshots: []
    };
  }

  const snapshotsRoot = path.join(baseRoot, "snapshots");
  if (!fs.existsSync(snapshotsRoot)) {
    return {
      baseRoot,
      snapshots: []
    };
  }

  try {
    const snapshots = fs.readdirSync(snapshotsRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const fullPath = path.join(snapshotsRoot, entry.name);
        let createdAt = 0;
        try {
          createdAt = fs.statSync(fullPath).birthtimeMs || fs.statSync(fullPath).ctimeMs || 0;
        } catch (_error) {
          createdAt = 0;
        }

        return {
          name: entry.name,
          createdAt
        };
      })
      .sort((left, right) => right.createdAt - left.createdAt);

    return {
      baseRoot,
      snapshots
    };
  } catch (_error) {
    return {
      baseRoot,
      snapshots: []
    };
  }
}

function listRecentSnapshots(config) {
  return inspectSnapshots(config).snapshots.map((entry) => entry.name);
}

function reconcileStatusWithDisk(config, status) {
  const snapshotInfo = inspectSnapshots(config);
  const snapshotNames = snapshotInfo.snapshots.map((entry) => entry.name);
  const nextStatus = {
    ...status
  };

  if (snapshotNames.length) {
    nextStatus.recentSnapshots = snapshotNames;

    if (!nextStatus.lastBackupAt) {
      const newestSnapshot = snapshotInfo.snapshots[0];
      if (newestSnapshot?.createdAt) {
        nextStatus.lastBackupAt = new Date(newestSnapshot.createdAt).toISOString();
      }
    }

    if (!nextStatus.lastBackupResult) {
      nextStatus.lastBackupResult = "success";
    }

    if (
      !nextStatus.lastBackupMessage ||
      nextStatus.lastBackupMessage === "No backups have been run yet."
    ) {
      nextStatus.lastBackupMessage = snapshotInfo.baseRoot
        ? `Backup snapshots were found on ${snapshotInfo.baseRoot}`
        : "Backup snapshots were found on the selected drive.";
    }
  }

  return nextStatus;
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
    retention: config?.retention || { days: 1, months: 0, years: 0 }
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
    publishBackupProgress({
      phase: "preparing",
      jobName: "",
      step: 1,
      totalSteps: 3,
      percent: 20,
      detail: "Preparing the backup destination."
    });
    publishBackupProgress({
      phase: "copying-current",
      jobName: "Preview Files",
      step: 2,
      totalSteps: 3,
      percent: 65,
      detail: "Copying to the current backup set."
    });
    const timestamp = now.toISOString().replace(/[:.]/g, "-");
    status.lastBackupAt = now.toISOString();
    status.lastBackupResult = "success";
    status.lastBackupMessage = "Preview mode: simulated backup completed on this device.";
    status.destinationStatus = "Preview Mode";
    status.recentSnapshots = [timestamp, ...(status.recentSnapshots || [])].slice(0, 5);
    writeJson(statusPath, status);
    publishBackupProgress({
      phase: "complete",
      jobName: "",
      step: 3,
      totalSteps: 3,
      percent: 100,
      detail: "Backup completed successfully."
    });
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

    const progressPrefix = "__OB_PROGRESS__:";

    const handleOutputChunk = (chunk, state, scriptForLog) => {
      state.buffer += chunk.toString();
      const lines = state.buffer.split(/\r?\n/);
      state.buffer = lines.pop() || "";

      for (const rawLine of lines) {
        const line = rawLine.trim();
        if (!line) {
          continue;
        }

        if (line.startsWith(progressPrefix)) {
          const rawPayload = line.slice(progressPrefix.length);
          try {
            const progress = JSON.parse(rawPayload);
            publishBackupProgress(progress);
            writeLauncherLog(`Backup progress from ${scriptForLog}: ${rawPayload}`);
          } catch (error) {
            writeLauncherLog(`Failed to parse backup progress from ${scriptForLog}: ${error.message}`);
          }
          continue;
        }

        state.stdout += `${line}\n`;
      }
    };

    const flushOutputBuffer = (state) => {
      const line = state.buffer.trim();
      if (!line) {
        return;
      }

      if (line.startsWith(progressPrefix)) {
        const rawPayload = line.slice(progressPrefix.length);
        try {
          publishBackupProgress(JSON.parse(rawPayload));
        } catch (_error) {
          // Ignore malformed trailing progress lines.
        }
        return;
      }

      state.stdout += `${line}\n`;
    };

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

        const outputState = {
          stdout: "",
          buffer: ""
        };
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
          handleOutputChunk(chunk, outputState, scriptName);
        });

        child.stderr.on("data", (chunk) => {
          stderr += chunk.toString();
        });

        child.on("close", (code) => {
          if (settled) {
            return;
          }

          settled = true;
          flushOutputBuffer(outputState);
          writeLauncherLog(`Fallback shell exited for ${scriptName} with code ${code}. stderr=${stderr.trim()} stdout=${outputState.stdout.trim()}`);
          resolve({
            ok: code === 0,
            code,
            message: stderr.trim() || outputState.stdout.trim() || `Exited with code ${code}.`
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

      const outputState = {
        stdout: "",
        buffer: ""
      };
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
        handleOutputChunk(chunk, outputState, scriptName);
      });

      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });

      child.on("close", (code) => {
        if (settled) {
          return;
        }

        settled = true;
        flushOutputBuffer(outputState);
        writeLauncherLog(`Shell exited for ${scriptName} with code ${code}. stderr=${stderr.trim()} stdout=${outputState.stdout.trim()}`);
        resolve({
          ok: code === 0,
          code,
          message: stderr.trim() || outputState.stdout.trim() || `Exited with code ${code}.`
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

function configureAutoUpdates(configOverride = null) {
  if (!app.isPackaged || process.platform !== "win32") {
    updateStatus = {
      supported: false,
      channel: "latest",
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

  const desiredChannel = sanitizeUpdateChannel(
    configOverride?.updates?.channel || (() => {
      try {
        const { configPath } = dataPaths();
        const config = readJson(configPath);
        return config?.updates?.channel;
      } catch (_error) {
        return null;
      }
    })()
  );

  try {
    if (!autoUpdaterConfigured) {
      ({ autoUpdater } = require("electron-updater"));
    }
  } catch (error) {
    writeLauncherLog(`electron-updater could not be loaded: ${error.message}`);
    updateStatus = {
      supported: false,
      channel: desiredChannel,
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

  if (!autoUpdaterConfigured) {
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdaterConfigured = true;
  }

  const channelChanged = currentUpdateChannel !== desiredChannel;
  currentUpdateChannel = desiredChannel;
  autoUpdater.channel = desiredChannel;
  autoUpdater.allowPrerelease = desiredChannel === "beta";

  if (channelChanged || !updateStatus.supported) {
    updateStatus = {
      supported: true,
      channel: desiredChannel,
      checkedAt: null,
      message: desiredChannel === "beta"
        ? "Check for updates to look for new beta and test releases."
        : "Check for updates to look for new stable releases.",
      updateAvailable: false,
      availableVersion: null,
      downloading: false,
      downloaded: false,
      downloadProgress: null
    };
    publishUpdateStatus();
  }

  writeLauncherLog(`Auto updater configured for ${desiredChannel} channel.`);

  if (autoUpdater.__obtoolsListenersBound) {
    return;
  }

  autoUpdater.__obtoolsListenersBound = true;

  autoUpdater.on("checking-for-update", () => {
    updateStatus = {
      ...updateStatus,
      channel: currentUpdateChannel,
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
      channel: currentUpdateChannel,
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
      channel: currentUpdateChannel,
      checkedAt: new Date().toISOString(),
      message: currentUpdateChannel === "beta"
        ? "This machine is already on the latest published beta build."
        : "This machine is already on the latest published stable build.",
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
      channel: currentUpdateChannel,
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
      channel: currentUpdateChannel,
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
      channel: currentUpdateChannel,
      checkedAt: new Date().toISOString(),
      message: summarizeUpdateError(error, currentUpdateChannel),
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
  const { configPath, statusPath } = dataPaths();
  const rawConfig = readJson(configPath);
  const config = normalizeConfigForMain(rawConfig);
  if (JSON.stringify(rawConfig) !== JSON.stringify(config)) {
    writeJson(configPath, config);
  }
  configureAutoUpdates(config);
  const status = reconcileStatusWithDisk(config, readJson(statusPath));
  writeJson(statusPath, status);
  return {
    config,
    status,
    meta: appMeta()
  };
});

ipcMain.handle("config:save", (_event, config) => {
  const { configPath, statusPath } = dataPaths();
  const normalizedConfig = normalizeConfigForMain(config);
  writeJson(configPath, normalizedConfig);
  configureAutoUpdates(normalizedConfig);
  return {
    config: normalizedConfig,
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
  writeRuntimeLog("Backup run requested.");
  publishBackupProgress({
    phase: "starting",
    jobName: "",
    step: 0,
    totalSteps: 1,
    percent: 2,
    detail: "Starting the backup process."
  });
  const { configPath } = dataPaths();
  const config = readJson(configPath);
  const result = await runPowerShell("backup-engine.ps1");
  const snapshotInfo = inspectSnapshots(config);
  const recentSnapshots = snapshotInfo.snapshots.map((entry) => entry.name);
  const newestSnapshot = snapshotInfo.snapshots[0] || null;
  const partialSuccess = !result.ok && recentSnapshots.length > 0;
  writeLauncherLog(`IPC backup:run completed. ok=${result.ok} message=${result.message}`);
  writeRuntimeLog(`Backup run completed. ok=${result.ok} message=${result.message}`);
  publishBackupProgress({
    phase: result.ok ? "complete" : "finished-with-issue",
    jobName: "",
    step: 1,
    totalSteps: 1,
    percent: result.ok ? 100 : 100,
    detail: result.ok ? "Backup completed." : "Backup finished with an issue."
  });
  const statusPatch = {
    destinationStatus: deriveDestinationStatus(result.message, result.ok),
    lastBackupResult: result.ok ? "success" : partialSuccess ? "warning" : "error",
    lastBackupMessage: result.message,
    recentSnapshots
  };

  if (result.ok || partialSuccess) {
    statusPatch.lastBackupAt = new Date(newestSnapshot?.createdAt || Date.now()).toISOString();
  }

  return {
    status: mergeStatus(statusPatch),
    meta: appMeta()
  };
});

ipcMain.handle("cloud:check", async () => {
  writeLauncherLog("IPC cloud:check received.");
  writeRuntimeLog("Cloud sync check requested.");
  const result = await runPowerShell("check-cloud-health.ps1");
  writeLauncherLog(`IPC cloud:check completed. ok=${result.ok} message=${result.message}`);
  writeRuntimeLog(`Cloud sync check completed. ok=${result.ok} message=${result.message}`);
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
  writeRuntimeLog("Automation install requested.");
  const result = await runPowerShell("install-scheduled-backup.ps1");
  writeLauncherLog(`IPC automation:install completed. ok=${result.ok} message=${result.message}`);
  writeRuntimeLog(`Automation install completed. ok=${result.ok} message=${result.message}`);
  return {
    ok: result.ok,
    message: result.message,
    status: mergeStatus({
      automation: {
        installedAt: result.ok ? new Date().toISOString() : null,
        message: result.message
      }
    }),
    meta: appMeta()
  };
});

ipcMain.handle("updates:check", async (_event, configOverride = null) => {
  configureAutoUpdates(configOverride);

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
      message: summarizeUpdateError(error, currentUpdateChannel),
      updateAvailable: false,
      availableVersion: null,
      downloaded: false,
      downloadProgress: null
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

ipcMain.handle("support:open-email", async () => {
  try {
    const { configPath, statusPath, userDataDir } = dataPaths();
    const config = normalizeConfigForMain(readJson(configPath));
    const status = reconcileStatusWithDisk(config, readJson(statusPath));
    const supportBundle = buildSupportBundle(config, status);

    const subject = encodeURIComponent(`OBTools Automated Backups Feature Request / Bug Report (${app.getVersion()})`);
    const body = encodeURIComponent([
      "Hi One Bite Technology,",
      "",
      "Please describe the feature request or bug below:",
      "",
      "What happened:",
      "",
      "What you expected:",
      "",
      "Steps to reproduce (if applicable):",
      "",
      "Please attach these files from the logs folder if possible:",
      `- ${path.basename(supportBundle.bundlePath)}`,
      `- ${path.basename(supportBundle.runtimePath)}`,
      `- ${path.basename(supportBundle.launcherPath)}`,
      "",
      `App version: ${app.getVersion()}`,
      `Update channel: ${sanitizeUpdateChannel(config?.updates?.channel, app.getVersion())}`,
      `Logs folder: ${userDataDir}`,
      "",
      "The app has already created a support summary file in that folder to make this easier.",
      ""
    ].join("\n"));

    await shell.openExternal(`mailto:${supportEmailAddress()}?subject=${subject}&body=${body}`);
    await shell.openPath(userDataDir);

    return {
      ok: true,
      message: `Opened your email app and the logs folder. Please attach ${path.basename(supportBundle.bundlePath)} plus any relevant log files from ${userDataDir}.`
    };
  } catch (error) {
    return {
      ok: false,
      message: `Could not prepare the support email automatically. Please email ${supportEmailAddress()} and include your app version plus the files from the logs folder. ${error.message}`
    };
  }
});

ipcMain.handle("logs:open-folder", async () => {
  const { userDataDir } = dataPaths();

  if (!fs.existsSync(runtimeLogPath())) {
    writeRuntimeLog("Runtime log initialized.");
  }

  const result = await shell.openPath(userDataDir);
  if (result) {
    return {
      ok: false,
      message: `Could not open the logs folder. ${result}`
    };
  }

  return {
    ok: true,
    message: `Opened the logs folder: ${userDataDir}`
  };
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
