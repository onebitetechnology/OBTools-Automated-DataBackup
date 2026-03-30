const state = {
  config: null,
  status: null,
  meta: null,
  storage: null,
  backupProgress: null,
  backupTiming: null,
  notifiedUpdateVersion: null,
  pendingUpdateVersion: null,
  updateChannelDraft: null,
  appearanceDraftLogoDataUrl: null,
  actionInFlight: false,
  termsBypassedForSession: false,
  detectedBrowsers: [],
  detectedUserFolders: [],
  pendingAddItem: null
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
  versionStatusPill: document.getElementById("version-status-pill"),
  versionStatusLight: document.getElementById("version-status-light"),
  snapshotList: document.getElementById("snapshot-list"),
  jobsList: document.getElementById("jobs-list"),
  destinationMode: document.getElementById("destination-mode"),
  destinationDriveLetter: document.getElementById("destination-drive-letter"),
  destinationLabel: document.getElementById("destination-label"),
  destinationBaseFolder: document.getElementById("destination-base-folder"),
  destinationPickedSummary: document.getElementById("destination-picked-summary"),
  destinationFinalSummary: document.getElementById("destination-final-summary"),
  headerCustomerLogo: document.getElementById("header-customer-logo"),
  backupSizeEstimate: document.getElementById("backup-size-estimate"),
  destinationFreeSpace: document.getElementById("destination-free-space"),
  retentionBehaviorSummary: document.getElementById("retention-behavior-summary"),
  destinationModeSummary: document.getElementById("destination-mode-summary"),
  retentionDays: document.getElementById("retention-days"),
  retentionMonths: document.getElementById("retention-months"),
  retentionYears: document.getElementById("retention-years"),
  scheduleEnabled: document.getElementById("schedule-enabled"),
  scheduleFrequency: document.getElementById("schedule-frequency"),
  scheduleTime: document.getElementById("schedule-time"),
  timeFormat: document.getElementById("time-format"),
  remindersEnabled: document.getElementById("reminders-enabled"),
  reminderDays: document.getElementById("reminder-days"),
  cloudCheckEnabled: document.getElementById("cloud-check-enabled"),
  supportName: document.getElementById("support-name"),
  supportPhone: document.getElementById("support-phone"),
  supportEmail: document.getElementById("support-email"),
  supportUrl: document.getElementById("support-url"),
  appearanceLogoPreviewShell: document.getElementById("appearance-logo-preview-shell"),
  appearanceLogoPreview: document.getElementById("appearance-logo-preview"),
  appearanceLogoEmpty: document.getElementById("appearance-logo-empty"),
  appearanceUploadLogo: document.getElementById("appearance-upload-logo"),
  appearanceClearLogo: document.getElementById("appearance-clear-logo"),
  licensingServiceUrl: document.getElementById("licensing-service-url"),
  licensingCustomerRef: document.getElementById("licensing-customer-ref"),
  licensingWarningDays: document.getElementById("licensing-warning-days"),
  licensingGraceDays: document.getElementById("licensing-grace-days"),
  licensingStatusCopy: document.getElementById("licensing-status-copy"),
  receiveBetaUpdates: document.getElementById("receive-beta-updates"),
  saveConfig: document.getElementById("save-config"),
  runBackup: document.getElementById("run-backup"),
  runCloudCheck: document.getElementById("run-cloud-check"),
  installAutomation: document.getElementById("install-automation"),
  browseDestination: document.getElementById("browse-destination"),
  useManagedFolder: document.getElementById("use-managed-folder"),
  useExistingFolder: document.getElementById("use-existing-folder"),
  openSettings: document.getElementById("open-settings"),
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
  detectUserFolders: document.getElementById("detect-user-folders"),
  detectBrowsers: document.getElementById("detect-browsers"),
  jobTemplate: document.getElementById("job-template"),
  browserModal: document.getElementById("browser-modal"),
  browserModalMessage: document.getElementById("browser-modal-message"),
  browserModalList: document.getElementById("browser-modal-list"),
  browserModalClose: document.getElementById("browser-modal-close"),
  browserModalApply: document.getElementById("browser-modal-apply"),
  userFolderModal: document.getElementById("user-folder-modal"),
  userFolderModalMessage: document.getElementById("user-folder-modal-message"),
  userFolderModalList: document.getElementById("user-folder-modal-list"),
  userFolderModalClose: document.getElementById("user-folder-modal-close"),
  userFolderModalApply: document.getElementById("user-folder-modal-apply"),
  addItemModal: document.getElementById("add-item-modal"),
  addItemChooseFolder: document.getElementById("add-item-choose-folder"),
  addItemChooseFile: document.getElementById("add-item-choose-file"),
  addItemSelectionName: document.getElementById("add-item-selection-name"),
  addItemSelectionPath: document.getElementById("add-item-selection-path"),
  addItemModalClose: document.getElementById("add-item-modal-close"),
  addItemModalApply: document.getElementById("add-item-modal-apply"),
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
    return window.onebiteDesktop.checkForUpdates(body);
  }

  if (url === "/api/detect-browsers") {
    return window.onebiteDesktop.detectBrowsers();
  }

  if (url === "/api/detect-user-folders") {
    return window.onebiteDesktop.detectUserFolders();
  }

  if (url === "/api/storage-analysis") {
    return window.onebiteDesktop.analyzeStorage();
  }

  throw new Error(`Unsupported desktop request: ${url}`);
}

function normalizeConfig(config) {
  const existingDestination = config.destination || {};
  const normalizedBaseFolder = existingDestination.baseFolder === "One Bite Backups" || existingDestination.baseFolder === "OB Tools Backup" || !existingDestination.baseFolder
    ? "DataSafe Backup"
    : existingDestination.baseFolder;
  const retentionSource = config.retention || {};
  const legacyCount = Number(config.retentionCount || 0);
  const normalizedRetention = {
    days: Math.max(Number(retentionSource.days ?? legacyCount ?? 3) || 0, 0),
    months: Math.max(Number(retentionSource.months ?? 0) || 0, 0),
    years: Math.max(Number(retentionSource.years ?? 0) || 0, 0)
  };

  if ((normalizedRetention.days + normalizedRetention.months + normalizedRetention.years) <= 0) {
    normalizedRetention.days = 1;
  }

  const normalizedSupport = {
    name: String(config.support?.name || config.businessName || "One Bite Technology").trim(),
    phone: String(config.support?.phone || "").trim(),
    email: String(config.support?.email || "jeff@onebitetechnology.ca").trim(),
    contactUrl: String(config.support?.contactUrl || "").trim()
  };

  const normalizedAppearance = {
    headerLogoDataUrl: String(config.appearance?.headerLogoDataUrl || "").trim()
  };

  const normalizedLicensing = {
    enabled: false,
    planName: String(config.licensing?.planName || "Annual License").trim(),
    serviceUrl: String(config.licensing?.serviceUrl || "").trim(),
    customerReference: String(config.licensing?.customerReference || "").trim(),
    renewalWarningDays: Math.max(Number(config.licensing?.renewalWarningDays ?? 30) || 30, 1),
    graceDays: Math.max(Number(config.licensing?.graceDays ?? 14) || 14, 1)
  };

  return {
    ...config,
    businessName: config.businessName || "One Bite Technology",
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
    schedule: {
      enabled: true,
      frequency: "weekly",
      time: "18:30",
      ...(config.schedule || {})
    },
    reminders: {
      enabled: true,
      staleDays: 7,
      ...(config.reminders || {})
    },
    retention: normalizedRetention,
    support: normalizedSupport,
    appearance: normalizedAppearance,
    licensing: normalizedLicensing,
    preferences: {
      timeFormat: "12h",
      ...(config.preferences || {})
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
    },
    licensing: {
      enabled: false,
      state: "disabled",
      message: "Licensing is disabled while backup testing continues.",
      renewalDate: null,
      lastCheckedAt: null,
      ...(shouldResetPreviewStatus ? {} : status.licensing || {})
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

function formatTimeOfDay(timeValue, timeFormat = state.config?.preferences?.timeFormat || "12h") {
  const match = String(timeValue || "").match(/^(\d{1,2}):(\d{2})$/);
  if (!match) {
    return String(timeValue || "");
  }

  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  if (!Number.isFinite(hours) || !Number.isFinite(minutes)) {
    return String(timeValue || "");
  }

  if (timeFormat === "24h") {
    return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
  }

  const suffix = hours >= 12 ? "PM" : "AM";
  const hour12 = hours % 12 || 12;
  return `${hour12}:${String(minutes).padStart(2, "0")} ${suffix}`;
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

function retentionSummary(retention = state.config?.retention || { days: 1, months: 0, years: 0 }) {
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
    const selectedChannel = state.updateChannelDraft || updateInfo.channel || state.config?.updates?.channel || "beta";
    el.receiveBetaUpdates.checked = selectedChannel === "beta";
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

function confirmRemoveJob(job) {
  showResultModal({
    title: "Remove Backup Item?",
    message: `Remove ${job.name || "this backup item"} from the backup list? This does not delete any files from the backup drive, but it will stop future backups for this item.`,
    secondaryAction: {
      label: "Remove",
      onClick: async () => {
        state.config.jobs = state.config.jobs.filter((candidate) => candidate.id !== job.id);
        renderJobs();
        closeResultModal();
        try {
          await refreshStorageAnalysis();
        } catch (_error) {
          state.storage = null;
          renderStorageAnalysis();
        }
      }
    },
    closeLabel: "Cancel"
  });
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

function renderUserFolderModal() {
  el.userFolderModalList.innerHTML = "";

  if (!state.detectedUserFolders.length) {
    el.userFolderModalMessage.textContent = "No common user folders were found on this PC.";
    el.userFolderModalApply.disabled = true;
    return;
  }

  el.userFolderModalMessage.textContent = "Check the user folders you want to include in backups.";
  el.userFolderModalApply.disabled = false;

  const groupedFolders = state.detectedUserFolders.reduce((groups, folder) => {
    const key = folder.userName || "Current User";
    if (!groups.has(key)) {
      groups.set(key, []);
    }
    groups.get(key).push(folder);
    return groups;
  }, new Map());

  groupedFolders.forEach((folders, userName) => {
    const group = document.createElement("section");
    group.className = "folder-group";

    const heading = document.createElement("div");
    heading.className = "folder-group-title";
    heading.textContent = userName;
    group.appendChild(heading);

    folders.forEach((folder) => {
      const row = document.createElement("label");
      row.className = "browser-option";

      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = true;
      input.value = folder.id;

      const copy = document.createElement("div");
      copy.className = "browser-option-copy";

      const title = document.createElement("div");
      title.className = "browser-option-title";
      title.textContent = folder.name;

      const detail = document.createElement("div");
      detail.className = "browser-option-detail";
      detail.textContent = `${folder.detail} | ${folder.path}`;

      copy.append(title, detail);
      row.append(input, copy);
      group.appendChild(row);
    });

    el.userFolderModalList.appendChild(group);
  });
}

function openBrowserModal() {
  renderBrowserModal();
  el.browserModal.hidden = false;
}

function closeBrowserModal() {
  el.browserModal.hidden = true;
}

function openUserFolderModal() {
  renderUserFolderModal();
  el.userFolderModal.hidden = false;
}

function closeUserFolderModal() {
  el.userFolderModal.hidden = true;
}

function renderAddItemModal() {
  const pending = state.pendingAddItem;
  if (!pending) {
    el.addItemSelectionName.textContent = "Nothing selected yet";
    el.addItemSelectionPath.textContent = "Choose a file or folder to continue.";
    el.addItemModalApply.disabled = true;
    return;
  }

  el.addItemSelectionName.textContent = pending.name || "Selected Item";
  el.addItemSelectionPath.textContent = pending.path || "";
  el.addItemModalApply.disabled = !pending.path;
}

function openAddItemModal() {
  state.pendingAddItem = null;
  renderAddItemModal();
  el.addItemModal.hidden = false;
}

function closeAddItemModal() {
  el.addItemModal.hidden = true;
}

async function chooseItemForAdd(type) {
  if (!window.onebiteDesktop) {
    return;
  }

  const selected = await window.onebiteDesktop.pickPath(type);
  if (!selected) {
    return;
  }

  const selectedPath = typeof selected === "string" ? selected : selected.path || "";
  const selectedType = typeof selected === "string" ? type : (selected.type || type);
  const normalizedName = selectedPath
    ? selectedPath.split(/[\\/]/).filter(Boolean).pop()
    : "New Backup Item";

  state.pendingAddItem = {
    name: normalizedName || "New Backup Item",
    path: selectedPath,
    type: selectedType === "file" ? "file" : "folder",
    enabled: true
  };

  renderAddItemModal();
}

function addSelectedItemFromModal() {
  if (!state.pendingAddItem?.path) {
    return;
  }

  state.config.jobs.push({
    id: `job-${Date.now()}`,
    name: state.pendingAddItem.name || "New Backup Item",
    path: state.pendingAddItem.path,
    type: state.pendingAddItem.type || "folder",
    enabled: true
  });

  renderJobs();
  refreshStorageAnalysis().catch(() => {
    state.storage = null;
    renderStorageAnalysis();
  });
  closeAddItemModal();
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

function addDetectedUserFolderJobs() {
  const selectedIds = Array.from(el.userFolderModalList.querySelectorAll("input[type='checkbox']:checked"))
    .map((input) => input.value);

  if (!selectedIds.length) {
    closeUserFolderModal();
    return;
  }

  const existingPaths = new Set(state.config.jobs.map((job) => String(job.path || "").toLowerCase()));
  const toAdd = state.detectedUserFolders.filter((folder) => selectedIds.includes(folder.id));

  toAdd.forEach((folder) => {
    if (existingPaths.has(folder.path.toLowerCase())) {
      return;
    }

    state.config.jobs.push({
      id: `job-${Date.now()}-${folder.id}`,
      name: folder.userName ? `${folder.userName} ${folder.name}` : folder.name,
      path: folder.path,
      type: "folder",
      sourceKind: "user-folder",
      userName: folder.userName || "",
      relativeDestination: ["Users", folder.userName || "Current User", folder.name],
      enabled: true
    });
  });

  renderJobs();
  refreshStorageAnalysis().catch(() => {
    state.storage = null;
    renderStorageAnalysis();
  });
  closeUserFolderModal();
}

async function detectBrowsers() {
  const payload = await request("/api/detect-browsers");
  state.detectedBrowsers = payload.browsers || [];
  openBrowserModal();
}

async function detectUserFolders() {
  const payload = await request("/api/detect-user-folders");
  state.detectedUserFolders = payload.folders || [];
  openUserFolderModal();
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

  state.notifiedUpdateVersion = availableVersion;
}

function setActionButtonsDisabled(disabled) {
  state.actionInFlight = disabled;
  el.runBackup.disabled = disabled;
  el.runCloudCheck.disabled = disabled;
  el.installAutomation.disabled = disabled;
  renderMeta();
}

function displayJobType(job) {
  if (job.sourceKind === "browser") {
    return "Browser Data";
  }

  if (job.type === "file") {
    return "File";
  }

  return "Folder";
}

async function syncJobTypeFromPath(job, typeDisplayInput) {
  if (job.sourceKind === "browser") {
    job.type = "folder";
    if (typeDisplayInput) {
      typeDisplayInput.value = displayJobType(job);
    }
    return;
  }

  if (!job.path || !window.onebiteDesktop?.inspectPath) {
    if (typeDisplayInput) {
      typeDisplayInput.value = displayJobType(job);
    }
    return;
  }

  try {
    const inspection = await window.onebiteDesktop.inspectPath(job.path);
    if (inspection?.type === "file" || inspection?.type === "folder") {
      job.type = inspection.type;
    }
  } catch (_error) {
    // Keep the existing inferred type when the path can't be inspected.
  }

  if (typeDisplayInput) {
    typeDisplayInput.value = displayJobType(job);
  }
}

function renderJobs() {
  el.jobsList.innerHTML = "";

  state.config.jobs.forEach((job) => {
    const fragment = el.jobTemplate.content.cloneNode(true);
    const card = fragment.querySelector(".job-card");
    const typeDisplayInput = card.querySelector("[data-field='type-display']");

    for (const input of card.querySelectorAll("[data-field]")) {
      const field = input.dataset.field;
      if (field === "type-display") {
        input.value = displayJobType(job);
        continue;
      }

      if (input.type === "checkbox") {
        input.checked = Boolean(job[field]);
      } else {
        input.value = job[field] || "";
      }

      input.addEventListener("input", (event) => {
        job[field] = input.type === "checkbox" ? event.target.checked : event.target.value;
      });
    }

    if (typeDisplayInput) {
      typeDisplayInput.value = displayJobType(job);
    }

    const browseButton = card.querySelector("[data-action='browse']");
    const pathInput = card.querySelector("[data-field='path']");
    if (job.sourceKind === "browser") {
      browseButton.textContent = "View Path";
    }

    if (pathInput && job.sourceKind !== "browser") {
      pathInput.addEventListener("blur", () => {
        syncJobTypeFromPath(job, typeDisplayInput).catch(() => {
          if (typeDisplayInput) {
            typeDisplayInput.value = displayJobType(job);
          }
        });
      });
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

      if (typeof selected === "string") {
        job.path = selected;
      } else {
        job.path = selected.path || "";
        if (selected.type === "file" || selected.type === "folder") {
          job.type = selected.type;
        }
      }

      pathInput.value = job.path;
      await syncJobTypeFromPath(job, typeDisplayInput);
    });

    card.querySelector("[data-action='remove']").addEventListener("click", () => {
      confirmRemoveJob(job);
    });

    el.jobsList.appendChild(fragment);
    syncJobTypeFromPath(job, typeDisplayInput).catch(() => {
      if (typeDisplayInput) {
        typeDisplayInput.value = displayJobType(job);
      }
    });
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
  if (el.versionStatusPill) {
    el.versionStatusPill.classList.remove("status-good", "status-warning", "status-error", "status-flashing");
    el.versionStatusPill.classList.add(`status-${summary.tone}`);
    if (summary.tone !== "good") {
      el.versionStatusPill.classList.add("status-flashing");
    }
  }
  if (el.versionStatusLight) {
    el.versionStatusLight.classList.remove("status-good", "status-warning", "status-error", "status-flashing");
    el.versionStatusLight.classList.add(`status-${summary.tone}`);
    if (summary.tone !== "good") {
      el.versionStatusLight.classList.add("status-flashing");
    }
  }
  el.protectionState.textContent = summary.title;
  el.protectionMessage.textContent = summary.message;
  el.lastBackup.textContent = formatDate(state.status.lastBackupAt);
  el.lastBackupDetail.textContent = formatDate(state.status.lastBackupAt);
  const backupDetailMessage = friendlyBackupMessage(state.status);
  el.lastBackupMessage.textContent = backupDetailMessage;
  el.lastBackupMessage.hidden = !backupDetailMessage || backupDetailMessage === summary.message;
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
  el.cloudRecommendations.hidden = !recommendations.length;
  if (recommendations.length) {
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
  state.updateChannelDraft = state.config?.updates?.channel || "beta";
  state.appearanceDraftLogoDataUrl = state.config?.appearance?.headerLogoDataUrl || "";
  renderMeta();
  renderHeaderBranding();
  el.settingsDrawer.hidden = true;
  document.body.classList.remove("settings-open");
}

function initializeSettingsSections() {
  document.querySelectorAll(".settings-section").forEach((section) => {
    const toggle = section.querySelector(":scope > .settings-section-toggle");
    const toggleText = section.querySelector(":scope > .settings-section-toggle .settings-section-toggle-text");

    if (!toggle || !toggleText) {
      return;
    }

    const syncSectionState = () => {
      const expanded = !section.classList.contains("collapsed");
      toggle.setAttribute("aria-expanded", expanded ? "true" : "false");
      toggleText.textContent = expanded ? "Hide Details" : "Show Details";
    };

    if (section.classList.contains("settings-section-open")) {
      section.classList.remove("collapsed");
    } else if (!section.classList.contains("collapsed")) {
      section.classList.add("collapsed");
    }

    syncSectionState();

    toggle.addEventListener("click", () => {
      section.classList.toggle("collapsed");
      syncSectionState();
    });
  });
}

function renderSettingsSummary() {
  const { retention, schedule, preferences } = state.config;
  el.settingsRetentionSummary.textContent = retentionSummary(retention);

  if (!schedule.enabled) {
    el.settingsScheduleSummary.textContent = "Manual only";
    return;
  }

  el.settingsScheduleSummary.textContent = `${schedule.frequency} at ${formatTimeOfDay(schedule.time, preferences?.timeFormat)}`;
}

function renderStorageAnalysis() {
  if (!state.storage) {
    el.backupSizeEstimate.textContent = "Waiting for analysis";
    el.destinationFreeSpace.textContent = "Waiting for analysis";
    el.retentionBehaviorSummary.textContent = "Daily, monthly, and yearly snapshots are kept according to your retention plan. Older snapshots outside that plan are removed automatically.";
    return;
  }

  el.backupSizeEstimate.textContent = formatBytes(state.storage.estimatedBytes);
  el.destinationFreeSpace.textContent = state.storage.freeBytes == null ? "Unavailable" : formatBytes(state.storage.freeBytes);
  el.retentionBehaviorSummary.textContent = `The app keeps ${retentionSummary(state.storage.retention)} of history. Daily, monthly, and yearly snapshots outside that plan are removed automatically.`;
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

function renderHeaderBranding() {
  const logoDataUrl = (state.appearanceDraftLogoDataUrl ?? state.config?.appearance?.headerLogoDataUrl) || "";
  const hasLogo = Boolean(logoDataUrl);

  if (el.headerCustomerLogo) {
    el.headerCustomerLogo.hidden = !hasLogo;
    if (hasLogo) {
      el.headerCustomerLogo.src = logoDataUrl;
    } else {
      el.headerCustomerLogo.removeAttribute("src");
    }
  }

  if (el.appearanceLogoPreview) {
    el.appearanceLogoPreview.hidden = !hasLogo;
    if (hasLogo) {
      el.appearanceLogoPreview.src = logoDataUrl;
    } else {
      el.appearanceLogoPreview.removeAttribute("src");
    }
  }

  if (el.appearanceLogoEmpty) {
    el.appearanceLogoEmpty.hidden = hasLogo;
  }

  if (el.appearanceLogoPreviewShell) {
    el.appearanceLogoPreviewShell.classList.toggle("is-empty", !hasLogo);
  }
}

function renderConfig() {
  const { destination, retention, schedule, reminders, cloudCheck, updates, preferences, support, licensing } = state.config;
  state.updateChannelDraft = updates?.channel || "beta";
  state.appearanceDraftLogoDataUrl = state.config?.appearance?.headerLogoDataUrl || "";
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

  const managedFolderName = destination.baseFolder || "DataSafe Backup";
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
  el.retentionDays.value = retention?.days ?? 1;
  el.retentionMonths.value = retention?.months ?? 0;
  el.retentionYears.value = retention?.years ?? 0;
  el.scheduleEnabled.checked = Boolean(schedule.enabled);
  el.scheduleFrequency.value = schedule.frequency;
  el.scheduleTime.value = schedule.time;
  if (el.timeFormat) {
    el.timeFormat.value = preferences?.timeFormat || "12h";
  }
  el.remindersEnabled.checked = Boolean(reminders.enabled);
  el.reminderDays.value = reminders.staleDays;
  el.cloudCheckEnabled.checked = Boolean(cloudCheck.enabled);
  if (el.supportName) {
    el.supportName.value = support?.name || "";
  }
  if (el.supportPhone) {
    el.supportPhone.value = support?.phone || "";
  }
  if (el.supportEmail) {
    el.supportEmail.value = support?.email || "";
  }
  if (el.supportUrl) {
    el.supportUrl.value = support?.contactUrl || "";
  }
  if (el.licensingServiceUrl) {
    el.licensingServiceUrl.value = licensing?.serviceUrl || "";
  }
  if (el.licensingCustomerRef) {
    el.licensingCustomerRef.value = licensing?.customerReference || "";
  }
  if (el.licensingWarningDays) {
    el.licensingWarningDays.value = licensing?.renewalWarningDays ?? 30;
  }
  if (el.licensingGraceDays) {
    el.licensingGraceDays.value = licensing?.graceDays ?? 14;
  }
  if (el.licensingStatusCopy) {
    el.licensingStatusCopy.textContent = state.status?.licensing?.message || "Licensing is disabled while backup testing continues.";
  }
  renderHeaderBranding();
  if (el.receiveBetaUpdates) {
    el.receiveBetaUpdates.checked = (state.updateChannelDraft || "beta") === "beta";
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
    retention: (() => {
      const days = Math.max(Number(el.retentionDays.value || 0), 0);
      const months = Math.max(Number(el.retentionMonths.value || 0), 0);
      const years = Math.max(Number(el.retentionYears.value || 0), 0);
      return (days + months + years) > 0
        ? { days, months, years }
        : { days: 1, months: 0, years: 0 };
    })(),
    retentionCount: undefined,
    schedule: {
      enabled: el.scheduleEnabled.checked,
      frequency: el.scheduleFrequency.value,
      time: el.scheduleTime.value
    },
    preferences: {
      ...(state.config.preferences || {}),
      timeFormat: el.timeFormat?.value || "12h"
    },
    reminders: {
      enabled: el.remindersEnabled.checked,
      staleDays: Number(el.reminderDays.value || 7)
    },
    cloudCheck: {
      enabled: el.cloudCheckEnabled.checked
    },
    support: {
      name: el.supportName?.value.trim() || state.config.support?.name || state.config.businessName || "One Bite Technology",
      phone: el.supportPhone?.value.trim() || "",
      email: el.supportEmail?.value.trim() || "",
      contactUrl: el.supportUrl?.value.trim() || ""
    },
    appearance: {
      headerLogoDataUrl: state.appearanceDraftLogoDataUrl || ""
    },
    licensing: {
      enabled: false,
      planName: state.config.licensing?.planName || "Annual License",
      serviceUrl: el.licensingServiceUrl?.value.trim() || "",
      customerReference: el.licensingCustomerRef?.value.trim() || "",
      renewalWarningDays: Math.max(Number(el.licensingWarningDays?.value || 30) || 30, 1),
      graceDays: Math.max(Number(el.licensingGraceDays?.value || 14) || 14, 1)
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
  state.updateChannelDraft = state.config?.updates?.channel || state.meta?.updateStatus?.channel || "beta";
  if (window.onebiteDesktop?.onUpdateStatus) {
    window.onebiteDesktop.onUpdateStatus((updateStatus) => {
      state.updateChannelDraft = updateStatus?.channel || state.updateChannelDraft;
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

function buildAutomationPrompt(config) {
  const parts = [];
  if (config?.schedule?.enabled) {
    const cadence = config.schedule.frequency === "weekly" ? "weekly backups" : "daily backups";
    parts.push(cadence);
  }
  if (config?.reminders?.enabled) {
    parts.push(`backup reminders after ${config.reminders.staleDays} day(s)`);
  }

  const summary = parts.length
    ? `Install Windows Tasks so this PC can run ${parts.join(" and ")} automatically.`
    : "Install Windows Tasks so this PC can run backups and reminders automatically.";

  return {
    title: "Install Windows Tasks?",
    message: summary,
    list: [
      "Manual backups work without Windows Tasks.",
      "Windows Tasks are needed for scheduled backups and reminder notifications."
    ],
    secondaryAction: {
      label: "Install Now",
      onClick: async () => {
        closeResultModal();
        await invokeAction("/api/install-automation", { skipSave: true });
      }
    },
    closeLabel: "Later"
  };
}

function maybeHandleAutomationSaveResult(payload, showAutomationPrompt = true) {
  const automation = payload.automation || null;
  if (!showAutomationPrompt || !automation) {
    return;
  }

  if (automation.type === "offer-install") {
    showResultModal(buildAutomationPrompt(state.config));
    return;
  }

  if (automation.type === "updated") {
    showResultModal({
      title: "Windows Tasks Updated",
      message: automation.message || "Windows Tasks were refreshed to match the new schedule settings."
    });
    return;
  }

  if (automation.type === "failed") {
    showResultModal({
      title: "Windows Tasks Need Attention",
      message: automation.message || "The saved schedule changed, but Windows Tasks could not be updated automatically."
    });
  }
}

async function saveConfig(showAutomationPrompt = true) {
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
  maybeHandleAutomationSaveResult(payload, showAutomationPrompt);
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

async function invokeAction(path, options = {}) {
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
    if (!options.skipSave) {
      await saveConfig(false);
    }
    const payload = await request(path, {
      method: "POST"
    });
    if (path === "/api/install-automation" && payload.ok === false) {
      throw new Error(payload.message || "The Windows tasks could not be installed.");
    }
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

    if (path === "/api/install-automation") {
      showResultModal({
        title: "Windows Tasks Ready",
        message: state.status.automation?.message || "Windows scheduled tasks were installed successfully.",
        list: [
          "Scheduled backups can now run automatically using the saved schedule.",
          "Backup reminder checks can notify the user when backups have not run recently."
        ]
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

    if (path === "/api/install-automation") {
      showResultModal({
        title: "Windows Tasks Need Attention",
        message: summarizeActionMessage(error.message || "The Windows tasks could not be installed.")
      });
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
  const desiredChannel = el.receiveBetaUpdates?.checked ? "beta" : "latest";
  state.updateChannelDraft = desiredChannel;
  el.updateStatus.textContent = "Checking for updates...";
  const payload = await request("/api/check-updates", {
    method: "POST",
    body: JSON.stringify({
      updates: {
        channel: desiredChannel
      }
    })
  });
  state.meta = payload.meta || state.meta;
  renderMeta();
}

async function downloadUpdate() {
  if (!window.onebiteDesktop?.downloadUpdate) {
    return;
  }

  el.updateStatus.textContent = "Downloading update...";
  const payload = await window.onebiteDesktop.downloadUpdate();
  state.meta = payload.meta || state.meta;
  renderMeta();
}

async function installUpdate() {
  if (!window.onebiteDesktop?.installUpdate) {
    return;
  }

  el.updateStatus.textContent = "Installing update and restarting...";
  const payload = await window.onebiteDesktop.installUpdate();
  state.meta = payload.meta || state.meta;
  renderMeta();
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
  state.config.destination.baseFolder = "DataSafe Backup";
  el.destinationBaseFolder.value = "DataSafe Backup";
  renderConfig();
}

async function uploadHeaderLogo() {
  if (!window.onebiteDesktop?.pickBrandingLogo) {
    showResultModal({
      title: "Logo Upload",
      message: "Logo upload is available in the installed desktop app."
    });
    return;
  }

  const result = await window.onebiteDesktop.pickBrandingLogo();
  if (!result) {
    return;
  }

  state.appearanceDraftLogoDataUrl = result.dataUrl || "";
  renderHeaderBranding();
}

function clearHeaderLogo() {
  state.appearanceDraftLogoDataUrl = "";
  renderHeaderBranding();
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
if (el.receiveBetaUpdates) {
  el.receiveBetaUpdates.addEventListener("change", () => {
    const desiredChannel = el.receiveBetaUpdates.checked ? "beta" : "latest";
    state.updateChannelDraft = desiredChannel;
    state.notifiedUpdateVersion = null;
    state.pendingUpdateVersion = null;
    state.meta = {
      ...(state.meta || {}),
      updateStatus: {
        ...(state.meta?.updateStatus || {}),
        supported: Boolean(window.onebiteDesktop && state.meta?.updateStatus?.supported),
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
      }
    };
    renderMeta();
  });
}
el.openLogsFolder.addEventListener("click", () => {
  openLogsFolder().catch((error) => {
    showResultModal({
      title: "Logs Folder",
      message: error.message
    });
  });
});
if (el.appearanceUploadLogo) {
  el.appearanceUploadLogo.addEventListener("click", () => {
    uploadHeaderLogo().catch((error) => {
      showResultModal({
        title: "Logo Upload",
        message: error.message
      });
    });
  });
}
if (el.appearanceClearLogo) {
  el.appearanceClearLogo.addEventListener("click", clearHeaderLogo);
}
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
el.openSettings.addEventListener("click", openSettingsDrawer);
el.closeSettings.addEventListener("click", closeSettingsDrawer);
el.addJob.addEventListener("click", openAddItemModal);
el.detectUserFolders.addEventListener("click", () => {
  detectUserFolders().catch((error) => {
    showResultModal({
      title: "User Folder Detection",
      message: error.message
    });
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
el.userFolderModalClose.addEventListener("click", closeUserFolderModal);
el.userFolderModalApply.addEventListener("click", addDetectedUserFolderJobs);
el.addItemChooseFolder.addEventListener("click", () => {
  chooseItemForAdd("folder").catch((error) => {
    showResultModal({
      title: "Choose Folder",
      message: error.message
    });
  });
});
el.addItemChooseFile.addEventListener("click", () => {
  chooseItemForAdd("file").catch((error) => {
    showResultModal({
      title: "Choose File",
      message: error.message
    });
  });
});
el.addItemModalClose.addEventListener("click", closeAddItemModal);
el.addItemModalApply.addEventListener("click", addSelectedItemFromModal);
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

initializeSettingsSections();

load().catch((error) => {
  el.protectionState.textContent = "Unavailable";
  el.protectionMessage.textContent = error.message;
});
