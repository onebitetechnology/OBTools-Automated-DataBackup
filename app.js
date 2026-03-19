const state = {
  config: null,
  status: null,
  meta: null,
  actionInFlight: false,
  termsBypassedForSession: false
};

const el = {
  backupStatusCard: document.getElementById("backup-status-card"),
  protectionState: document.getElementById("protection-state"),
  protectionMessage: document.getElementById("protection-message"),
  lastBackup: document.getElementById("last-backup"),
  lastBackupDetail: document.getElementById("last-backup-detail"),
  lastBackupMessage: document.getElementById("last-backup-message"),
  snapshotCount: document.getElementById("snapshot-count"),
  cloudSummary: document.getElementById("cloud-summary"),
  cloudRecommendations: document.getElementById("cloud-recommendations"),
  buildVersion: document.getElementById("build-version"),
  snapshotList: document.getElementById("snapshot-list"),
  jobsList: document.getElementById("jobs-list"),
  destinationMode: document.getElementById("destination-mode"),
  destinationDriveLetter: document.getElementById("destination-drive-letter"),
  destinationLabel: document.getElementById("destination-label"),
  destinationBaseFolder: document.getElementById("destination-base-folder"),
  destinationPickedSummary: document.getElementById("destination-picked-summary"),
  destinationModeSummary: document.getElementById("destination-mode-summary"),
  retentionCount: document.getElementById("retention-count"),
  scheduleEnabled: document.getElementById("schedule-enabled"),
  scheduleFrequency: document.getElementById("schedule-frequency"),
  scheduleTime: document.getElementById("schedule-time"),
  remindersEnabled: document.getElementById("reminders-enabled"),
  reminderDays: document.getElementById("reminder-days"),
  cloudCheckEnabled: document.getElementById("cloud-check-enabled"),
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
  settingsDestinationSummary: document.getElementById("settings-destination-summary"),
  settingsRetentionSummary: document.getElementById("settings-retention-summary"),
  settingsScheduleSummary: document.getElementById("settings-schedule-summary"),
  appVersion: document.getElementById("app-version"),
  settingsVersionCopy: document.getElementById("settings-version-copy"),
  updateStatus: document.getElementById("update-status"),
  checkUpdates: document.getElementById("check-updates"),
  resultModal: document.getElementById("result-modal"),
  resultModalTitle: document.getElementById("result-modal-title"),
  resultModalMessage: document.getElementById("result-modal-message"),
  resultModalList: document.getElementById("result-modal-list"),
  resultModalSecondary: document.getElementById("result-modal-secondary"),
  resultModalClose: document.getElementById("result-modal-close"),
  addJob: document.getElementById("add-job"),
  jobTemplate: document.getElementById("job-template"),
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

  throw new Error(`Unsupported desktop request: ${url}`);
}

function normalizeConfig(config) {
  return {
    ...config,
    destination: {
      mode: "driveLetter",
      driveLetter: "",
      label: "",
      baseFolder: "One Bite Backups",
      folderMode: "managed",
      selectedPath: "",
      ...(config.destination || {})
    },
    cloudCheck: {
      enabled: true,
      ...(config.cloudCheck || {})
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

  return new Date(value).toLocaleString();
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
  const updateMessage = state.meta?.updateStatus?.message || "Update checks are not ready yet.";
  el.buildVersion.textContent = `Version ${version}`;
  el.appVersion.textContent = version;
  el.settingsVersionCopy.textContent = version;
  el.updateStatus.textContent = updateMessage;
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

  const primaryLine = raw
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line && !/^(at |CategoryInfo:|FullyQualifiedErrorId:|\+|~)/.test(line));

  return primaryLine || raw;
}

function showResultModal({ title, message, list = [], secondaryAction = null }) {
  el.resultModalTitle.textContent = title;
  el.resultModalMessage.textContent = message;
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

  el.resultModal.hidden = false;
}

function closeResultModal() {
  el.resultModal.hidden = true;
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

function setActionButtonsDisabled(disabled) {
  state.actionInFlight = disabled;
  el.runBackup.disabled = disabled;
  el.runCloudCheck.disabled = disabled;
  el.installAutomation.disabled = disabled;
  el.checkUpdates.disabled = disabled;
}

function renderJobs() {
  el.jobsList.innerHTML = "";

  state.config.jobs.forEach((job) => {
    const fragment = el.jobTemplate.content.cloneNode(true);
    const card = fragment.querySelector(".job-card");

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

    card.querySelector("[data-action='browse']").addEventListener("click", async () => {
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
      item.textContent = snapshot;
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
  const { destination, retentionCount, schedule } = state.config;
  if (destination.selectedPath) {
    el.settingsDestinationSummary.textContent = destination.selectedPath;
  } else if (destination.driveLetter) {
    el.settingsDestinationSummary.textContent = `Drive ${destination.driveLetter.replace(":", "")}:`;
  } else {
    el.settingsDestinationSummary.textContent = "Not configured";
  }

  el.settingsRetentionSummary.textContent = `${retentionCount} ${retentionCount === 1 ? "copy" : "copies"}`;

  if (!schedule.enabled) {
    el.settingsScheduleSummary.textContent = "Manual only";
    return;
  }

  el.settingsScheduleSummary.textContent = `${schedule.frequency} at ${schedule.time}`;
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
  const { destination, retentionCount, schedule, reminders, cloudCheck } = state.config;
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

  if (destination.folderMode === "existing") {
    el.destinationModeSummary.textContent = "The app will store backups inside the folder you selected.";
    el.useExistingFolder.classList.add("choice-active");
    el.useManagedFolder.classList.remove("choice-active");
  } else {
    el.destinationModeSummary.textContent = 'The app will create and maintain a "One Bite Backups" folder on the selected drive.';
    el.useManagedFolder.classList.add("choice-active");
    el.useExistingFolder.classList.remove("choice-active");
  }
  el.retentionCount.value = retentionCount;
  el.scheduleEnabled.checked = Boolean(schedule.enabled);
  el.scheduleFrequency.value = schedule.frequency;
  el.scheduleTime.value = schedule.time;
  el.remindersEnabled.checked = Boolean(reminders.enabled);
  el.reminderDays.value = reminders.staleDays;
  el.cloudCheckEnabled.checked = Boolean(cloudCheck.enabled);
  renderJobs();
  renderSettingsSummary();
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
      folderMode: state.config.destination.folderMode || "managed",
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
  renderConfig();
  renderStatus();
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
  } finally {
    setActionButtonsDisabled(false);

    if (el.protectionState.textContent === "Working") {
      el.protectionState.textContent = originalTitle;
      el.protectionMessage.textContent = originalMessage;
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
  el.destinationMode.value = "driveLetter";
  el.destinationDriveLetter.value = selected.driveLetter;
  el.destinationLabel.value = "";
  if ((state.config.destination.folderMode || "managed") === "existing") {
    state.config.destination.baseFolder = selected.baseFolder;
    el.destinationBaseFolder.value = selected.baseFolder;
  } else {
    state.config.destination.baseFolder = "One Bite Backups";
    el.destinationBaseFolder.value = "One Bite Backups";
  }
  renderConfig();
}

function setDestinationFolderMode(folderMode) {
  state.config.destination.folderMode = folderMode;

  if (folderMode === "existing") {
    const selectedPath = state.config.destination.selectedPath || "";
    if (!selectedPath) {
      el.destinationModeSummary.textContent = "Choose a folder first, then use it as the existing backup folder.";
      return;
    }

    const rootPath = `${state.config.destination.driveLetter}:\\`;
    const relativeFolder = selectedPath.startsWith(rootPath)
      ? selectedPath.slice(rootPath.length).replaceAll("/", "\\")
      : el.destinationBaseFolder.value.trim();
    state.config.destination.baseFolder = relativeFolder;
    el.destinationBaseFolder.value = relativeFolder;
  } else {
    state.config.destination.baseFolder = "One Bite Backups";
    el.destinationBaseFolder.value = "One Bite Backups";
  }

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
el.resultModalClose.addEventListener("click", closeResultModal);
el.browseDestination.addEventListener("click", () => {
  browseDestinationFolder().catch((error) => {
    el.protectionState.textContent = "Unavailable";
    el.protectionMessage.textContent = error.message;
  });
});
el.useManagedFolder.addEventListener("click", () => {
  setDestinationFolderMode("managed");
});
el.useExistingFolder.addEventListener("click", () => {
  setDestinationFolderMode("existing");
});
el.openSettings.addEventListener("click", openSettingsDrawer);
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
});
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
