const state = {
  config: null,
  status: null,
  meta: null,
  storage: null,
  backupProgress: null,
  backupTiming: null,
  notifiedUpdateVersion: null,
  pendingUpdateVersion: null,
  actionInFlight: false,
  termsBypassedForSession: false,
  detectedBrowsers: []
};

let backupProgressTimer = null;

const el = {
  backupStatusCard: document.getElementById("backup-status-card"),
  protectionState: document.getElementById("protection-state"),
  protectionMessage: document.getElementById("protection-message"),
  lastBackup: document.getElementById("last-backup"),
  lastBackupDetail: document.getElementById("last-backup-detail"),
  lastBackupMessage: document.getElementById("last-backup-message"),
  snapshotCount: document.getElementById("snapshot-count"),
  cloudSummary: document.getElementById("cloud-summary"),
  cloudHealthIndicator: document.getElementById("cloud-health-indicator"),
  cloudHealthLabel: document.getElementById("cloud-health-label"),
  cloudRecommendations: document.getElementById("cloud-recommendations"),
  buildVersion: document.getElementById("build-version"),
  snapshotList: document.getElementById("snapshot-list"),
  jobsList: document.getElementById("jobs-list"),
  destinationMode: document.getElementById("destination-mode"),
  destinationDriveLetter: document.getElementById("destination-drive-letter"),
  destinationLabel: document.getElementById("destination-label"),
  destinationBaseFolder: document.getElementById("destination-base-folder"),
  destinationPickedSummary: document.getElementById("destination-picked-summary"),
  destinationFinalSummary: document.getElementById("destination-final-summary"),
  backupSizeEstimate: document.getElementById("backup-size-estimate"),
  destinationFreeSpace: document.getElementById("destination-free-space"),
  retentionBehaviorSummary: document.getElementById("retention-behavior-summary"),
  destinationModeSummary: document.getElementById("destination-mode-summary"),
  retentionCount: document.getElementById("retention-count"),
  scheduleEnabled: document.getElementById("schedule-enabled"),
  scheduleFrequency: document.getElementById("schedule-frequency"),
  scheduleTime: document.getElementById("schedule-time"),
  remindersEnabled: document.getElementById("reminders-enabled"),
  reminderDays: document.getElementById("reminder-days"),
  cloudCheckEnabled: document.getElementById("cloud-check-enabled"),
  receiveBetaUpdates: document.getElementById("receive-beta-updates"),
  saveConfig: document.getElementById("save-config"),
  runBackup: document.getElementById("run-backup"),
  runCloudCheck: document.getElementById("run-cloud-check"),
  installAutomation: document.getElementById("install-automation"),
  browseDestination: document.getElementById("browse-destination"),
  useManagedFolder: document.getElementById("use-managed-folder"),
  useExistingFolder: document.getElementById("use-existing-folder"),
  saveMainSetup: document.getElementById("save-main-setup"),
  openSettings: document.getElementById("open-settings"),
  openAdvancedSettings: document.getElementById("open-advanced-settings"),
  closeSettings: document.getElementById("close-settings"),
  settingsDrawer: document.getElementById("settings-drawer"),
  settingsRetentionSummary: document.getElementById("settings-retention-summary"),
  settingsScheduleSummary: document.getElementById("settings-schedule-summary"),
  appVersion: document.getElementById("app-version"),
  settingsVersionCopy: document.getElementById("settings-version-copy"),
  updateLatestVersion: document.getElementById("update-latest-version"),
  updateStatus: document.getElementById("update-status"),
  checkUpdates: document.getElementById("check-updates"),
  downloadUpdate: document.getElementById("download-update"),
  installUpdate: document.getElementById("install-update"),
  reportIssue: document.getElementById("report-issue"),
  openLogsFolder: document.getElementById("open-logs-folder"),
  updateProgressShell: document.getElementById("update-progress-shell"),
  updateProgressBar: document.getElementById("update-progress-bar"),
  updateProgressLabel: document.getElementById("update-progress-label"),
  resultModal: document.getElementById("result-modal"),
  resultModalTitle: document.getElementById("result-modal-title"),
  resultModalMessage: document.getElementById("result-modal-message"),
  resultProgressShell: document.getElementById("result-progress-shell"),
  resultProgressBar: document.getElementById("result-progress-bar"),
  resultProgressLabel: document.getElementById("result-progress-label"),
  resultProgressDetail: document.getElementById("result-progress-detail"),
  resultProgressElapsed: document.getElementById("result-progress-elapsed"),
  resultProgressEta: document.getElementById("result-progress-eta"),
  resultModalList: document.getElementById("result-modal-list"),
  resultModalSecondary: document.getElementById("result-modal-secondary"),
  resultModalClose: document.getElementById("result-modal-close"),
  addJob: document.getElementById("add-job"),
  detectBrowsers: document.getElementById("detect-browsers"),
  jobTemplate: document.getElementById("job-template"),
  browserModal: document.getElementById("browser-modal"),
  browserModalMessage: document.getElementById("browser-modal-message"),
  browserModalList: document.getElementById("browser-modal-list"),
  browserModalClose: document.getElementById("browser-modal-close"),
  browserModalApply: document.getElementById("browser-modal-apply"),
  termsGate: document.getElementById("terms-gate"),
  termsConfirm: document.getElementById("terms-confirm"),
  termsAccept: document.getElementById("terms-accept"),
  termsSkip: document.getElementById("terms-skip")
};

async function request(url, options = {}) {
  if (window.onebiteDesktop) {
    return desktopRequest(url, options);
  }

  const response = await fetch(url, {
    headers: {
      "Content-Type": "application/json"
    },
    ...options
  });

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "Request failed.");
  }

  return payload;
}

async function desktopRequest(url, options = {}) {
  const body = options.body ? JSON.parse(options.body) : null;

  if (url === "/api/state") {
    return window.onebiteDesktop.getState();
  }

  if (url === "/api/config" && options.method === "POST") {
    return window.onebiteDesktop.saveConfig(body);
  }

  if (url === "/api/run-backup" && options.method === "POST") {
    return window.onebiteDesktop.runBackup();
  }

  if (url === "/api/check-cloud" && options.method === "POST") {
    return window.onebiteDesktop.checkCloud();
  }

  if (url === "/api/install-automation" && options.method === "POST") {
    return window.onebiteDesktop.installAutomation();
  }

  if (url === "/api/check-updates" && options.method === "POST") {
    return window.onebiteDesktop.checkForUpdates();
  }

  if (url === "/api/detect-browsers") {
    return window.onebiteDesktop.detectBrowsers();
  }

  if (url === "/api/storage-analysis") {
    return window.onebiteDesktop.analyzeStorage();
  }

  throw new Error(`Unsupported desktop request: ${url}`);
}

function normalizeConfig(config) {
  const existingDestination = config.destination || {};
  const normalizedBaseFolder = existingDestination.baseFolder === "One Bite Backups" || !existingDestination.baseFolder
    ? "OB Tools Backup"
    : existingDestination.baseFolder;

  return {
    ...config,
    destination: {
      mode: "driveLetter",
      driveLetter: "",
      label: "",
      baseFolder: normalizedBaseFolder,
      folderMode: "managed",
      selectedPath: "",
      ...existingDestination,
      folderMode: "managed",
      baseFolder: normalizedBaseFolder
    },
    cloudCheck: {
      enabled: true,
      ...(config.cloudCheck || {})
    },
    updates: {
      channel: "beta",
      ...(config.updates || {})
    },
    terms: {
      version: "2026-03-16",
      acceptedAt: null,
      acceptedVersion: null,
      ...(config.terms || {})
    }
  };
}

function normalizeStatus(status) {
  const shouldResetPreviewStatus =
    (typeof status.lastBackupMessage === "string" &&
      status.lastBackupMessage.startsWith("Preview mode:")) ||
    status.destinationStatus === "Preview Mode" ||
    (typeof status.cloud?.summary === "string" && status.cloud.summary.startsWith("Preview mode:")) ||
    (typeof status.automation?.message === "string" && status.automation.message.startsWith("Preview mode:"));

  return {
    ...(shouldResetPreviewStatus
      ? {
          lastBackupAt: null,
          lastBackupResult: null,
          lastBackupMessage: "No backups have been run yet.",
          destinationStatus: "Unknown",
          recentSnapshots: []
        }
      : status),
    recentSnapshots: shouldResetPreviewStatus ? [] : status.recentSnapshots || [],
    cloud: {
      checkedAt: null,
      summary: "Cloud check has not been run yet.",
      level: "info",
      recommendations: [],
      ...(shouldResetPreviewStatus ? {} : status.cloud || {})
    },
    automation: {
      installedAt: null,
      message: "Windows automation has not been installed yet.",
      ...(shouldResetPreviewStatus ? {} : status.automation || {})
    }
  };
}

function formatDate(value) {
  if (!value) {
    return "Never";
  }

  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return String(value);
  }

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hour12: true
  }).format(parsed);
}

function formatSnapshotLabel(snapshotName) {
  const match = String(snapshotName || "").match(/^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$/);
  if (!match) {
    return String(snapshotName || "");
  }

  const [, year, month, day, hour, minute, second] = match;
  const parsed = new Date(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second));
  if (Number.isNaN(parsed.getTime())) {
    return String(snapshotName || "");
  }

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hour12: true
  }).format(parsed);
}

function formatDuration(ms) {
  const totalSeconds = Math.max(0, Math.round(Number(ms || 0) / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }

  if (minutes > 0) {
    return `${minutes}m ${seconds}s`;
  }

  return `${seconds}s`;
}

function buildBackupTiming(progress = null) {
  if (!state.backupTiming?.startedAt) {
    return null;
  }

  const elapsedMs = Math.max(0, Date.now() - state.backupTiming.startedAt);
  const percent = Math.max(0, Math.min(100, Number(progress?.percent ?? state.backupProgress?.percent ?? 0)));
  const phase = progress?.phase || state.backupProgress?.phase || "starting";
  let etaText = "Estimated remaining: Calculating...";

  if (phase === "complete" || percent >= 100) {
    etaText = "Estimated remaining: Finishing up...";
  } else if (elapsedMs >= 10000 && percent >= 10) {
    const estimatedTotalMs = elapsedMs / (percent / 100);
    const remainingMs = Math.max(0, estimatedTotalMs - elapsedMs);
    etaText = `Estimated remaining: About ${formatDuration(remainingMs)}`;
  }

  return {
    elapsedText: `Elapsed: ${formatDuration(elapsedMs)}`,
    etaText
  };
}

function getBackupProgressView(progress = state.backupProgress) {
  if (!progress) {
    return null;
  }

  const detail = progress?.jobName
    ? `${progress.detail || "Copying files"} ${progress.jobName}`
    : (progress?.detail || "Processing backup files...");

  return {
    percent: progress?.percent || 0,
    detail,
    indeterminate: progress?.phase === "starting",
    timing: buildBackupTiming(progress)
  };
}

function stopBackupProgressTimer() {
  if (backupProgressTimer) {
    clearInterval(backupProgressTimer);
    backupProgressTimer = null;
  }
}

function refreshBackupProgressModal() {
  if (el.resultModal.hidden || el.resultModalTitle.textContent !== "Backup In Progress") {
    return;
  }

  const progressView = getBackupProgressView();
  if (!progressView) {
    return;
  }

  renderResultProgress(progressView);
  el.resultModalMessage.textContent = progressView.detail;
}

function ensureBackupProgressTimer() {
  if (backupProgressTimer || !state.backupTiming?.startedAt) {
    return;
  }

  backupProgressTimer = setInterval(() => {
    refreshBackupProgressModal();
  }, 1000);
}

function formatBytes(bytes) {
  const size = Number(bytes || 0);
  if (!Number.isFinite(size) || size <= 0) {
    return "0 B";
  }

  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = size;
  let index = 0;

  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }

  const rounded = value >= 10 || index === 0 ? value.toFixed(0) : value.toFixed(1);
  return `${rounded} ${units[index]}`;
}

function protectionSummary(status) {
  const staleDays = state.config?.reminders?.staleDays || 7;
  const backupMessage = summarizeActionMessage(status.lastBackupMessage || "The latest backup needs review.");

  if (status.destinationStatus === "Drive Not Connected") {
    return {
      tone: "warning",
      title: "Backup Drive Missing",
      message: "Reconnect the selected backup drive, then run the backup again."
    };
  }

  if (!status.lastBackupAt) {
    return {
      tone: "warning",
      title: "Backup Needed",
      message: "Pick a drive, save the config, and run the first sync."
    };
  }

  if (status.lastBackupResult === "warning") {
    return {
      tone: "warning",
      title: "Completed With Warnings",
      message: backupMessage
    };
  }

  if (status.lastBackupResult && status.lastBackupResult !== "success") {
    return {
      tone: "error",
      title: "Issue Detected",
      message: backupMessage
    };
  }

  const ageInDays = (Date.now() - new Date(status.lastBackupAt).getTime()) / (1000 * 60 * 60 * 24);
  if (ageInDays > staleDays) {
    return {
      tone: "warning",
      title: "Backup Overdue",
      message: `Last backup is older than ${staleDays} day${staleDays === 1 ? "" : "s"}.`
    };
  }

  return {
    tone: "good",
    title: "Up To Date",
    message: backupMessage || "The latest backup looks healthy."
  };
}

function friendlyBackupMessage(status) {
  if (status.destinationStatus === "Drive Not Connected") {
    return "The selected backup drive is not connected. Plug it in and run the backup again.";
  }

  return summarizeActionMessage(status.lastBackupMessage || "No backup history yet.");
}

function renderMeta() {
  const version = state.meta?.version || "Unknown";
  const updateInfo = state.meta?.updateStatus || {};
  const updateMessage = updateInfo.message || "Update checks are not ready yet.";
  const latestVersion = updateInfo.availableVersion || "Not checked yet";
  const showProgress = Boolean(updateInfo.downloading);
  const progressValue = updateInfo.downloaded
    ? 100
    : Math.max(0, Math.min(100, Number(updateInfo.downloadProgress || 0)));
  const updateSupported = Boolean(window.onebiteDesktop && updateInfo.supported);

  el.buildVersion.textContent = `Version ${version}`;
  el.appVersion.textContent = version;
  el.settingsVersionCopy.textContent = version;
  el.updateLatestVersion.textContent = latestVersion;
  el.updateStatus.textContent = updateMessage;
  if (el.receiveBetaUpdates) {
    el.receiveBetaUpdates.checked = (state.config?.updates?.channel || "beta") === "beta";
  }
  el.updateStatus.classList.toggle("warning-copy", Boolean(updateInfo.updateAvailable && !updateInfo.downloaded) && !/failed/i.test(updateMessage));
  el.updateStatus.classList.toggle("error-copy", /failed/i.test(updateMessage));

  el.updateProgressShell.hidden = !showProgress;
  el.updateProgressBar.style.width = `${progressValue}%`;
  el.updateProgressLabel.textContent = `${progressValue}%`;

  el.checkUpdates.disabled = state.actionInFlight || !updateSupported || Boolean(updateInfo.downloading);
  el.downloadUpdate.disabled = state.actionInFlight || !updateSupported || !updateInfo.updateAvailable || Boolean(updateInfo.downloading) || Boolean(updateInfo.downloaded);
  el.installUpdate.disabled = state.actionInFlight || !updateSupported || !updateInfo.downloaded;
}

function summarizeActionMessage(message) {
  const raw = String(message || "").replace(/\r/g, "").trim();
  if (!raw) {
    return "The action finished, but no details were returned.";
  }

  if (/No destination drive could be resolved/i.test(raw)) {
    return "Choose a backup drive in Settings before running the first backup.";
  }

  if (/Destination drive is not available/i.test(raw)) {
    return "The selected backup drive is not connected. Reconnect it and try again.";
  }

  if (/Backup source missing:/i.test(raw)) {
    const match = raw.match(/Backup source missing:\s*(.+)/i);
    return match ? `One of the backup items could not be found: ${match[1].trim()}` : "One of the backup items could not be found.";
  }

  if (/ERROR 112|not enough space on the disk/i.test(raw)) {
    return "The backup drive ran out of space while copying files. Free up space or use a larger drive, then run the backup again.";
  }

  if ((/ERROR 32|used by another process|cannot access the file/i.test(raw)) && /Google\\Chrome\\User Data/i.test(raw)) {
    return "Chrome was open while its profile data was being backed up. Close Chrome completely, wait a moment, and run the backup again.";
  }

  if ((/ERROR 32|used by another process|cannot access the file/i.test(raw)) && /Microsoft\\Edge\\User Data/i.test(raw)) {
    return "Edge was open while its profile data was being backed up. Close Edge completely, wait a moment, and run the backup again.";
  }

  if ((/ERROR 32|used by another process|cannot access the file/i.test(raw)) && /BraveSoftware\\Brave-Browser\\User Data/i.test(raw)) {
    return "Brave was open while its profile data was being backed up. Close Brave completely, wait a moment, and run the backup again.";
  }

  if ((/ERROR 2|The system cannot find the file specified/i.test(raw)) && /Google\\Chrome\\User Data/i.test(raw)) {
    return "Chrome changed some profile files while the backup was running. Close Chrome fully, wait a moment, and run the backup again.";
  }

  if ((/ERROR 2|The system cannot find the file specified/i.test(raw)) && /Microsoft\\Edge\\User Data/i.test(raw)) {
    return "Edge changed some profile files while the backup was running. Close Edge fully, wait a moment, and run the backup again.";
  }

  if ((/ERROR 2|The system cannot find the file specified/i.test(raw)) && /BraveSoftware\\Brave-Browser\\User Data/i.test(raw)) {
    return "Brave changed some profile files while the backup was running. Close Brave fully, wait a moment, and run the backup again.";
  }

  if (/Some files in .* could not be copied/i.test(raw)) {
    const firstSentence = raw.match(/Some files in .*? could not be copied\.[^\n]*/i);
    return firstSentence ? firstSentence[0].trim() : "Some files could not be copied. Close open files or sync apps, then try the backup again.";
  }

  if (/Robocopy failed for /i.test(raw)) {
    return "Some files could not be copied. Close open files or cloud-sync apps, then try the backup again.";
  }

  const primaryLine = raw
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line && !/^(at |CategoryInfo:|FullyQualifiedErrorId:|\+|~)/.test(line));

  return primaryLine || raw;
}

function showResultModal({ title, message, list = [], secondaryAction = null, hideClose = false, closeLabel = "Close", progress = null }) {
  el.resultModalTitle.textContent = title;
  el.resultModalMessage.textContent = message;
  renderResultProgress(progress);
  el.resultModalList.innerHTML = "";

  if (!list.length) {
    el.resultModalList.hidden = true;
  } else {
    el.resultModalList.hidden = false;
    list.forEach((entry) => {
      const item = document.createElement("li");
      item.textContent = entry;
      el.resultModalList.appendChild(item);
    });
  }

  if (secondaryAction) {
    el.resultModalSecondary.hidden = false;
    el.resultModalSecondary.textContent = secondaryAction.label;
    el.resultModalSecondary.onclick = () => {
      secondaryAction.onClick().catch((error) => {
        el.resultModalMessage.textContent = error.message;
      });
    };
  } else {
    el.resultModalSecondary.hidden = true;
    el.resultModalSecondary.onclick = null;
  }

  el.resultModalClose.hidden = hideClose;
  el.resultModalClose.textContent = closeLabel;
  el.resultModal.hidden = false;
}

function closeResultModal() {
  el.resultModal.hidden = true;
  renderResultProgress(null);
}

function renderResultProgress(progress = null) {
  if (!progress) {
    el.resultProgressShell.hidden = true;
    el.resultProgressBar.classList.remove("indeterminate");
    el.resultProgressBar.style.width = "0%";
    el.resultProgressLabel.textContent = "0%";
    el.resultProgressDetail.textContent = "";
    el.resultProgressElapsed.textContent = "Elapsed: 0s";
    el.resultProgressEta.textContent = "Estimated remaining: Calculating...";
    return;
  }

  const percent = Math.max(0, Math.min(100, Number(progress.percent || 0)));
  const indeterminate = Boolean(progress.indeterminate);
  el.resultProgressShell.hidden = false;
  el.resultProgressBar.classList.toggle("indeterminate", indeterminate);
  el.resultProgressBar.style.width = indeterminate ? "45%" : `${percent}%`;
  el.resultProgressLabel.textContent = indeterminate ? "Working..." : `${percent}%`;
  el.resultProgressDetail.textContent = progress.detail || "Processing backup files...";
  el.resultProgressElapsed.textContent = progress.timing?.elapsedText || "Elapsed: Calculating...";
  el.resultProgressEta.textContent = progress.timing?.etaText || "Estimated remaining: Calculating...";
}

function renderBrowserModal() {
  el.browserModalList.innerHTML = "";

  if (!state.detectedBrowsers.length) {
    el.browserModalMessage.textContent = "No supported browsers were found on this PC.";
    el.browserModalApply.disabled = true;
    return;
  }

  el.browserModalMessage.textContent = "Check the browsers you want to include in backups.";
  el.browserModalApply.disabled = false;

  state.detectedBrowsers.forEach((browser) => {
    const row = document.createElement("label");
    row.className = "browser-option";

    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = true;
    input.value = browser.id;

    const copy = document.createElement("div");
    copy.className = "browser-option-copy";

    const title = document.createElement("div");
    title.className = "browser-option-title";
    title.textContent = browser.name;

    const detail = document.createElement("div");
    detail.className = "browser-option-detail";
    detail.textContent = `${browser.detail} | ${browser.path}`;

    copy.append(title, detail);
    row.append(input, copy);
    el.browserModalList.appendChild(row);
  });
}

function openBrowserModal() {
  renderBrowserModal();
  el.browserModal.hidden = false;
}

function closeBrowserModal() {
  el.browserModal.hidden = true;
}

function addDetectedBrowserJobs() {
  const selectedIds = Array.from(el.browserModalList.querySelectorAll("input[type='checkbox']:checked"))
    .map((input) => input.value);

  if (!selectedIds.length) {
    closeBrowserModal();
    return;
  }

  const existingPaths = new Set(state.config.jobs.map((job) => String(job.path || "").toLowerCase()));
  const toAdd = state.detectedBrowsers.filter((browser) => selectedIds.includes(browser.id));

  toAdd.forEach((browser) => {
    if (existingPaths.has(browser.path.toLowerCase())) {
      return;
    }

    state.config.jobs.push({
      id: `job-${Date.now()}-${browser.id}`,
      name: `${browser.name} User Data`,
      path: browser.path,
      type: "folder",
      sourceKind: "browser",
      enabled: true
    });
  });

  renderJobs();
  refreshStorageAnalysis().catch(() => {
    state.storage = null;
    renderStorageAnalysis();
  });
  closeBrowserModal();
}

async function detectBrowsers() {
  const payload = await request("/api/detect-browsers");
  state.detectedBrowsers = payload.browsers || [];
  openBrowserModal();
}

function updateModalSecondaryAction() {
  const updateInfo = state.meta?.updateStatus || {};

  if (window.onebiteDesktop?.installUpdate && updateInfo.downloaded) {
    return {
      label: "Install Now",
      onClick: async () => {
        const result = await window.onebiteDesktop.installUpdate();
        state.meta = result.meta || state.meta;
        renderMeta();
        if (!result.ok) {
          throw new Error(result.message);
        }
        el.resultModalMessage.textContent = result.message;
        el.resultModalSecondary.hidden = true;
      }
    };
  }

  if (window.onebiteDesktop?.downloadUpdate && updateInfo.updateAvailable) {
    return {
      label: "Download Update",
      onClick: async () => {
        el.resultModalMessage.textContent = "Downloading update...";
        const result = await window.onebiteDesktop.downloadUpdate();
        state.meta = result.meta || state.meta;
        renderMeta();

        if (state.meta?.updateStatus?.downloaded) {
          showResultModal({
            title: "Update Ready",
            message: state.meta.updateStatus.message,
            secondaryAction: updateModalSecondaryAction()
          });
          return;
        }

        el.resultModalMessage.textContent = state.meta?.updateStatus?.message || "Update download finished.";
      }
    };
  }

  if (window.onebiteDesktop?.openReleasesPage && updateInfo.updateAvailable) {
    return {
      label: "Open Releases",
      onClick: async () => {
        const result = await window.onebiteDesktop.openReleasesPage();
        if (!result.ok) {
          throw new Error(result.message);
        }
        el.resultModalMessage.textContent = result.message;
      }
    };
  }

  return null;
}

function maybeShowAutoUpdatePrompt() {
  const updateInfo = state.meta?.updateStatus || {};
  const availableVersion = updateInfo.availableVersion || null;

  if (!availableVersion || !updateInfo.updateAvailable || updateInfo.downloaded) {
    return;
  }

  if (state.notifiedUpdateVersion === availableVersion) {
    return;
  }

  if (state.actionInFlight) {
    state.pendingUpdateVersion = availableVersion;
    return;
  }

  state.notifiedUpdateVersion = availableVersion;
  state.pendingUpdateVersion = null;
  showResultModal({
    title: "Update Available",
    message: updateInfo.message || `Update ${availableVersion} is available to download.`,
    secondaryAction: updateModalSecondaryAction()
  });
}

function setActionButtonsDisabled(disabled) {
  state.actionInFlight = disabled;
  el.runBackup.disabled = disabled;
  el.runCloudCheck.disabled = disabled;
  el.installAutomation.disabled = disabled;
  renderMeta();
}

function renderJobs() {
  el.jobsList.innerHTML = "";

  state.config.jobs.forEach((job) => {
    const fragment = el.jobTemplate.content.cloneNode(true);
    const card = fragment.querySelector(".job-card");
    const typeInput = card.querySelector("[data-field='type']");

    for (const input of card.querySelectorAll("[data-field]")) {
      const field = input.dataset.field;
      if (input.type === "checkbox") {
        input.checked = Boolean(job[field]);
      } else {
        input.value = job[field] || "";
      }

      input.addEventListener("input", (event) => {
        job[field] = input.type === "checkbox" ? event.target.checked : event.target.value;
      });
    }

    if (job.sourceKind === "browser" && typeInput) {
      typeInput.innerHTML = '<option value="folder">Browser Data</option>';
      typeInput.value = "folder";
      typeInput.disabled = true;
    } else if (typeInput) {
      typeInput.disabled = false;
      typeInput.value = job.type || "folder";
    }

    const browseButton = card.querySelector("[data-action='browse']");
    if (job.sourceKind === "browser") {
      browseButton.textContent = "View Path";
    }

    browseButton.addEventListener("click", async () => {
      if (job.sourceKind === "browser") {
        showResultModal({
          title: `${job.name || "Browser Data"} Path`,
          message: job.path || "No browser path is configured yet."
        });
        return;
      }

      if (!window.onebiteDesktop) {
        return;
      }

      const selected = await window.onebiteDesktop.pickPath(job.type);
      if (!selected) {
        return;
      }

      job.path = selected;
      card.querySelector("[data-field='path']").value = selected;
    });

    card.querySelector("[data-action='remove']").addEventListener("click", () => {
      state.config.jobs = state.config.jobs.filter((candidate) => candidate.id !== job.id);
      renderJobs();
    });

    el.jobsList.appendChild(fragment);
  });
}

function renderStatus() {
  const summary = protectionSummary(state.status);
  const cloudLevel = state.status.cloud?.level || "info";
  const cloudChecked = Boolean(state.status.cloud?.checkedAt);
  const cloudSummary = state.status.cloud?.summary || "";
  const cloudHealthy = cloudLevel === "success" || (cloudChecked && cloudLevel === "info" && /OneDrive is installed/i.test(cloudSummary) && /running/i.test(cloudSummary));
  const cloudProblem = cloudChecked && (cloudLevel === "warning" || cloudLevel === "error");

  el.backupStatusCard.classList.remove("status-good", "status-warning", "status-error");
  el.backupStatusCard.classList.add(`status-${summary.tone}`);
  el.protectionState.textContent = summary.title;
  el.protectionMessage.textContent = summary.message;
  el.lastBackup.textContent = formatDate(state.status.lastBackupAt);
  el.lastBackupDetail.textContent = formatDate(state.status.lastBackupAt);
  el.lastBackupMessage.textContent = friendlyBackupMessage(state.status);
  el.cloudSummary.textContent = state.status.cloud?.summary || "Cloud check has not been run yet.";
  el.cloudSummary.classList.toggle("warning-copy", state.status.cloud?.level === "warning");
  el.cloudSummary.classList.toggle("error-copy", state.status.cloud?.level === "error");
  el.cloudHealthIndicator.classList.remove("health-indicator-neutral", "health-indicator-success", "health-indicator-error");
  el.cloudHealthIndicator.classList.add(
    cloudHealthy ? "health-indicator-success" : cloudProblem ? "health-indicator-error" : "health-indicator-neutral"
  );
  el.cloudHealthLabel.textContent = cloudHealthy
    ? "OneDrive backup looks healthy"
    : cloudProblem
      ? "Cloud backup needs attention"
      : cloudChecked
        ? "Cloud sync reviewed"
        : "Cloud health not checked yet";

  el.snapshotList.innerHTML = "";
  const snapshots = state.status.recentSnapshots || [];
  el.snapshotCount.textContent = String(snapshots.length);
  if (!snapshots.length) {
    const item = document.createElement("li");
    item.textContent = "No snapshots yet.";
    el.snapshotList.appendChild(item);
  } else {
    snapshots.forEach((snapshot) => {
      const item = document.createElement("li");
      item.textContent = formatSnapshotLabel(snapshot);
      el.snapshotList.appendChild(item);
    });
  }

  el.cloudRecommendations.innerHTML = "";
  const recommendations = state.status.cloud?.recommendations || [];
  if (!recommendations.length) {
    const item = document.createElement("li");
    item.textContent = "No recommendations right now.";
    el.cloudRecommendations.appendChild(item);
  } else {
    recommendations.forEach((entry) => {
      const item = document.createElement("li");
      item.textContent = entry;
      el.cloudRecommendations.appendChild(item);
    });
  }
}

function openSettingsDrawer() {
  el.settingsDrawer.hidden = false;
  document.body.classList.add("settings-open");
}

function closeSettingsDrawer() {
  el.settingsDrawer.hidden = true;
  document.body.classList.remove("settings-open");
}

function renderSettingsSummary() {
  const { retentionCount, schedule } = state.config;
  el.settingsRetentionSummary.textContent = `${retentionCount} ${retentionCount === 1 ? "copy" : "copies"}`;

  if (!schedule.enabled) {
    el.settingsScheduleSummary.textContent = "Manual only";
    return;
  }

  el.settingsScheduleSummary.textContent = `${schedule.frequency} at ${schedule.time}`;
}

function renderStorageAnalysis() {
  if (!state.storage) {
    el.backupSizeEstimate.textContent = "Waiting for analysis";
    el.destinationFreeSpace.textContent = "Waiting for analysis";
    el.retentionBehaviorSummary.textContent = "When the copy limit is reached, the oldest snapshot is removed before creating the next one.";
    return;
  }

  el.backupSizeEstimate.textContent = formatBytes(state.storage.estimatedBytes);
  el.destinationFreeSpace.textContent = state.storage.freeBytes == null ? "Unavailable" : formatBytes(state.storage.freeBytes);
  el.retentionBehaviorSummary.textContent = `The app keeps ${state.storage.retentionCount} snapshot${state.storage.retentionCount === 1 ? "" : "s"}. When that limit is reached, the oldest snapshot is removed before creating the next one.`;
}

async function refreshStorageAnalysis() {
  if (!window.onebiteDesktop?.analyzeStorage) {
    state.storage = null;
    renderStorageAnalysis();
    return;
  }

  el.backupSizeEstimate.textContent = "Calculating...";
  el.destinationFreeSpace.textContent = "Checking...";

  const payload = await request("/api/storage-analysis");
  state.storage = payload.storage || null;
  renderStorageAnalysis();
}

function isTermsAccepted(config) {
  return Boolean(
    config?.terms?.acceptedAt &&
    config?.terms?.acceptedVersion &&
    config?.terms?.acceptedVersion === config?.terms?.version
  );
}

function renderTermsGate() {
  const mustAccept = !isTermsAccepted(state.config) && !state.termsBypassedForSession;
  el.termsGate.hidden = !mustAccept;
  document.body.classList.toggle("terms-open", mustAccept);
  el.termsConfirm.checked = false;
  el.termsAccept.disabled = true;
}

function renderConfig() {
  const { destination, retentionCount, schedule, reminders, cloudCheck, updates } = state.config;
  el.destinationMode.value = destination.mode;
  el.destinationDriveLetter.value = destination.driveLetter;
  el.destinationLabel.value = destination.label;
  el.destinationBaseFolder.value = destination.baseFolder;
  if (destination.selectedPath) {
    el.destinationPickedSummary.textContent = `Selected: ${destination.selectedPath}`;
  } else if (destination.driveLetter) {
    el.destinationPickedSummary.textContent = `Selected drive: ${destination.driveLetter.replace(":", "")}:`;
  } else {
    el.destinationPickedSummary.textContent = "No backup drive or folder selected yet.";
  }

  const managedFolderName = destination.baseFolder || "OB Tools Backup";
  el.destinationModeSummary.textContent = `The app will create and maintain an ${managedFolderName} folder on the selected drive.`;

  if (el.useManagedFolder) {
    el.useManagedFolder.classList.add("choice-active");
  }
  if (el.useExistingFolder) {
    el.useExistingFolder.classList.remove("choice-active");
  }

  if (destination.driveLetter) {
    el.destinationFinalSummary.textContent = `Backups will be saved to: ${destination.driveLetter.replace(":", "")}:\\${managedFolderName}`;
  } else {
    el.destinationFinalSummary.textContent = "Backups will appear here once a destination is selected.";
  }
  el.retentionCount.value = retentionCount;
  el.scheduleEnabled.checked = Boolean(schedule.enabled);
  el.scheduleFrequency.value = schedule.frequency;
  el.scheduleTime.value = schedule.time;
  el.remindersEnabled.checked = Boolean(reminders.enabled);
  el.reminderDays.value = reminders.staleDays;
  el.cloudCheckEnabled.checked = Boolean(cloudCheck.enabled);
  if (el.receiveBetaUpdates) {
    el.receiveBetaUpdates.checked = (updates?.channel || "beta") === "beta";
  }
  renderJobs();
  renderSettingsSummary();
  renderStorageAnalysis();
  renderMeta();
  renderTermsGate();
}

function collectConfig() {
  return {
    ...state.config,
    destination: {
      ...state.config.destination,
      mode: el.destinationMode.value,
      driveLetter: el.destinationDriveLetter.value.trim(),
      label: el.destinationLabel.value.trim(),
      baseFolder: el.destinationBaseFolder.value.trim(),
      folderMode: "managed",
      selectedPath: state.config.destination.selectedPath || ""
    },
    retentionCount: Number(el.retentionCount.value || 3),
    schedule: {
      enabled: el.scheduleEnabled.checked,
      frequency: el.scheduleFrequency.value,
      time: el.scheduleTime.value
    },
    reminders: {
      enabled: el.remindersEnabled.checked,
      staleDays: Number(el.reminderDays.value || 7)
    },
    cloudCheck: {
      enabled: el.cloudCheckEnabled.checked
    },
    updates: {
      channel: el.receiveBetaUpdates?.checked ? "beta" : "latest"
    },
    terms: {
      ...state.config.terms
    },
    jobs: state.config.jobs.map((job, index) => ({
      ...job,
      id: job.id || `job-${index + 1}`
    }))
  };
}

async function load() {
  const payload = await request("/api/state");
  state.config = normalizeConfig(payload.config);
  state.status = normalizeStatus(payload.status);
  state.meta = payload.meta || null;
  if (window.onebiteDesktop?.onUpdateStatus) {
    window.onebiteDesktop.onUpdateStatus((updateStatus) => {
      state.meta = {
        ...(state.meta || {}),
        version: state.meta?.version || "Unknown",
        updateStatus
      };
      renderMeta();
      maybeShowAutoUpdatePrompt();
    });
  }
  if (window.onebiteDesktop?.onBackupProgress) {
    window.onebiteDesktop.onBackupProgress((progress) => {
      state.backupProgress = progress || null;

      if (progress && !state.backupTiming?.startedAt) {
        state.backupTiming = {
          startedAt: Date.now()
        };
      }

      if (progress?.phase === "complete") {
        stopBackupProgressTimer();
      } else if (progress) {
        ensureBackupProgressTimer();
      }

      refreshBackupProgressModal();
    });
  }
  renderConfig();
  renderStatus();
  refreshStorageAnalysis().catch(() => {
    state.storage = null;
    renderStorageAnalysis();
  });

  if (window.onebiteDesktop?.checkForUpdates) {
    setTimeout(() => {
      if (state.actionInFlight) {
        return;
      }

      window.onebiteDesktop.checkForUpdates().catch(() => {
        // Silent background check; the Settings UI still exposes manual retry.
      });
    }, 4000);
  }
}

async function saveConfig() {
  state.config = collectConfig();
  const payload = await request("/api/config", {
    method: "POST",
    body: JSON.stringify(state.config)
  });
  state.config = normalizeConfig(payload.config);
  state.status = normalizeStatus(payload.status);
  state.meta = payload.meta || state.meta;
  renderConfig();
  renderStatus();
  await refreshStorageAnalysis().catch(() => {
    state.storage = null;
    renderStorageAnalysis();
  });
  closeSettingsDrawer();
}

async function acceptTerms() {
  state.config = collectConfig();
  state.config.terms = {
    version: "2026-03-16",
    acceptedAt: null,
    acceptedVersion: null,
    ...(state.config.terms || {})
  };
  state.config.terms.acceptedAt = new Date().toISOString();
  state.config.terms.acceptedVersion = state.config.terms.version;
  const payload = await request("/api/config", {
    method: "POST",
    body: JSON.stringify(state.config)
  });
  state.config = normalizeConfig(payload.config);
  state.status = normalizeStatus(payload.status);
  state.meta = payload.meta || state.meta;
  renderConfig();
  renderStatus();
}

async function invokeAction(path) {
  if (state.actionInFlight) {
    return;
  }

  const originalTitle = el.protectionState.textContent;
  const originalMessage = el.protectionMessage.textContent;
  const pendingMessage = path === "/api/run-backup" ? "Running backup..." : "Checking...";

  setActionButtonsDisabled(true);
  el.protectionState.textContent = "Working";
  el.protectionMessage.textContent = pendingMessage;

  if (path === "/api/run-backup") {
    state.backupTiming = {
      startedAt: Date.now()
    };
    state.backupProgress = {
      phase: "starting",
      percent: 2,
      detail: "Starting the backup process."
    };
    ensureBackupProgressTimer();
    showResultModal({
      title: "Backup In Progress",
      message: "Copying files to the selected backup drive. This may take a while for large folders.",
      hideClose: true,
      progress: getBackupProgressView()
    });
  }

  try {
    await saveConfig();
    const payload = await request(path, {
      method: "POST"
    });
    state.status = normalizeStatus(payload.status);
    state.meta = payload.meta || state.meta;
    renderStatus();
    renderMeta();

    if (path === "/api/check-cloud") {
      showResultModal({
        title: state.status.cloud?.level === "warning" ? "Cloud Sync Needs Attention" : "Cloud Sync Review",
        message: summarizeActionMessage(state.status.cloud?.summary || "Cloud check completed."),
        list: state.status.cloud?.recommendations || [],
        secondaryAction: window.onebiteDesktop?.openOneDrive
          ? {
              label: "Open OneDrive",
              onClick: async () => {
                const result = await window.onebiteDesktop.openOneDrive();
                if (!result.ok) {
                  throw new Error(result.message);
                }
                el.resultModalMessage.textContent = result.message;
              }
            }
          : null
      });
      return;
    }

    if (path === "/api/run-backup") {
      stopBackupProgressTimer();
      state.backupProgress = null;
      state.backupTiming = null;
      const success = state.status.lastBackupResult === "success";
      showResultModal({
        title: success ? "Backup Complete" : "Backup Needs Attention",
        message: summarizeActionMessage(state.status.lastBackupMessage || "Backup finished."),
        list: (state.status.recentSnapshots || []).slice(0, 5).map((snapshot) => `Snapshot: ${snapshot}`)
      });
      return;
    }
  } catch (error) {
    el.backupStatusCard.classList.remove("status-good", "status-warning");
    el.backupStatusCard.classList.add("status-error");
    el.protectionState.textContent = "Action Failed";
    el.protectionMessage.textContent = error.message;
    el.lastBackupMessage.textContent = error.message;

    if (path === "/api/check-cloud") {
      el.cloudSummary.textContent = error.message;
    }

    if (path === "/api/run-backup") {
      stopBackupProgressTimer();
      state.backupProgress = null;
      state.backupTiming = null;
    }
  } finally {
    if (path !== "/api/run-backup") {
      stopBackupProgressTimer();
    }

    setActionButtonsDisabled(false);

    if (el.protectionState.textContent === "Working") {
      el.protectionState.textContent = originalTitle;
      el.protectionMessage.textContent = originalMessage;
    }

    if (state.pendingUpdateVersion) {
      maybeShowAutoUpdatePrompt();
    }
  }
}

async function checkForUpdates() {
  el.updateStatus.textContent = "Checking for updates...";
  const payload = await request("/api/check-updates", {
    method: "POST"
  });
  state.meta = payload.meta || state.meta;
  renderMeta();

  const updateMessage = state.meta?.updateStatus?.message || "Update check finished.";
  showResultModal({
    title: state.meta?.updateStatus?.updateAvailable ? "Update Available" : "Update Check Complete",
    message: updateMessage,
    secondaryAction: updateModalSecondaryAction()
  });
}

async function downloadUpdate() {
  if (!window.onebiteDesktop?.downloadUpdate) {
    return;
  }

  const payload = await window.onebiteDesktop.downloadUpdate();
  state.meta = payload.meta || state.meta;
  renderMeta();

  if (state.meta?.updateStatus?.downloaded) {
    showResultModal({
      title: "Update Ready",
      message: state.meta.updateStatus.message || "The update has been downloaded and is ready to install.",
      secondaryAction: updateModalSecondaryAction()
    });
  }
}

async function installUpdate() {
  if (!window.onebiteDesktop?.installUpdate) {
    return;
  }

  const payload = await window.onebiteDesktop.installUpdate();
  state.meta = payload.meta || state.meta;
  renderMeta();

  showResultModal({
    title: payload.ok ? "Installing Update" : "Install Update",
    message: payload.message || "The update could not be installed."
  });
}

async function openLogsFolder() {
  if (!window.onebiteDesktop?.openLogsFolder) {
    showResultModal({
      title: "Logs Folder",
      message: "Log access is available in the installed desktop app."
    });
    return;
  }

  const payload = await window.onebiteDesktop.openLogsFolder();
  showResultModal({
    title: payload.ok ? "Logs Folder Opened" : "Logs Folder",
    message: payload.message || "The logs folder could not be opened."
  });
}

async function openSupportEmail() {
  if (!window.onebiteDesktop?.openSupportEmail) {
    showResultModal({
      title: "Support Request",
      message: "Support email is available in the installed desktop app. Include your app version, a description of the problem or request, and attach any relevant logs."
    });
    return;
  }

  const payload = await window.onebiteDesktop.openSupportEmail();
  showResultModal({
    title: payload.ok ? "Support Email Ready" : "Support Request",
    message: payload.message || "The support email could not be prepared."
  });
}

async function browseDestinationFolder() {
  if (!window.onebiteDesktop?.pickDestinationFolder) {
    el.destinationPickedSummary.textContent = "Destination browsing is available in the installed desktop app.";
    return;
  }

  const selected = await window.onebiteDesktop.pickDestinationFolder();
  if (!selected) {
    return;
  }

  state.config.destination.selectedPath = selected.displayPath;
  state.config.destination.mode = "driveLetter";
  state.config.destination.driveLetter = selected.driveLetter;
  state.config.destination.label = "";
  state.config.destination.folderMode = "managed";
  el.destinationMode.value = "driveLetter";
  el.destinationDriveLetter.value = selected.driveLetter;
  el.destinationLabel.value = "";
  state.config.destination.baseFolder = "OB Tools Backup";
  el.destinationBaseFolder.value = "OB Tools Backup";
  renderConfig();
}

el.saveConfig.addEventListener("click", saveConfig);
el.runBackup.addEventListener("click", () => {
  invokeAction("/api/run-backup").catch((error) => {
    el.protectionState.textContent = "Action Failed";
    el.protectionMessage.textContent = error.message;
  });
});
el.runCloudCheck.addEventListener("click", () => {
  invokeAction("/api/check-cloud").catch((error) => {
    el.protectionState.textContent = "Action Failed";
    el.protectionMessage.textContent = error.message;
    el.cloudSummary.textContent = error.message;
  });
});
el.installAutomation.addEventListener("click", () => {
  invokeAction("/api/install-automation").catch((error) => {
    el.protectionState.textContent = "Action Failed";
    el.protectionMessage.textContent = error.message;
  });
});
el.checkUpdates.addEventListener("click", () => {
  checkForUpdates().catch((error) => {
    el.updateStatus.textContent = error.message;
  });
});
el.openLogsFolder.addEventListener("click", () => {
  openLogsFolder().catch((error) => {
    showResultModal({
      title: "Logs Folder",
      message: error.message
    });
  });
});
el.downloadUpdate.addEventListener("click", () => {
  downloadUpdate().catch((error) => {
    el.updateStatus.textContent = error.message;
  });
});
el.installUpdate.addEventListener("click", () => {
  installUpdate().catch((error) => {
    el.updateStatus.textContent = error.message;
  });
});
el.reportIssue.addEventListener("click", () => {
  openSupportEmail().catch((error) => {
    showResultModal({
      title: "Support Request",
      message: error.message
    });
  });
});
el.resultModalClose.addEventListener("click", closeResultModal);
el.browseDestination.addEventListener("click", () => {
  browseDestinationFolder().catch((error) => {
    el.protectionState.textContent = "Unavailable";
    el.protectionMessage.textContent = error.message;
  });
});
el.saveMainSetup.addEventListener("click", () => {
  saveConfig().catch((error) => {
    showResultModal({
      title: "Save Setup",
      message: error.message
    });
  });
});
el.openSettings.addEventListener("click", openSettingsDrawer);
el.openAdvancedSettings.addEventListener("click", openSettingsDrawer);
el.closeSettings.addEventListener("click", closeSettingsDrawer);
el.addJob.addEventListener("click", () => {
  state.config.jobs.push({
    id: `job-${Date.now()}`,
    name: "New Backup Item",
    path: "",
    type: "folder",
    enabled: true
  });
  renderJobs();
  refreshStorageAnalysis().catch(() => {
    state.storage = null;
    renderStorageAnalysis();
  });
});
el.detectBrowsers.addEventListener("click", () => {
  detectBrowsers().catch((error) => {
    showResultModal({
      title: "Browser Detection",
      message: error.message
    });
  });
});
el.browserModalClose.addEventListener("click", closeBrowserModal);
el.browserModalApply.addEventListener("click", addDetectedBrowserJobs);
el.termsConfirm.addEventListener("change", () => {
  el.termsAccept.disabled = !el.termsConfirm.checked;
});
el.termsAccept.addEventListener("click", () => {
  acceptTerms().catch((error) => {
    el.protectionState.textContent = "Unavailable";
    el.protectionMessage.textContent = error.message;
  });
});
el.termsSkip.addEventListener("click", () => {
  state.termsBypassedForSession = true;
  renderTermsGate();
});

load().catch((error) => {
  el.protectionState.textContent = "Unavailable";
  el.protectionMessage.textContent = error.message;
});
