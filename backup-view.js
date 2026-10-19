(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DataSafeBackupView = api;
})(typeof window !== "undefined" ? window : this, function () {
  function format(config) {
    return config?.destination?.backupFormatVersion ?? config?.incrementalFormatVersion ?? 1;
  }

  function projectBackupProgress({ operation, progress, now = Date.now() } = {}) {
    const started = new Date(operation?.startedAt).getTime();
    const elapsedSeconds = Number.isFinite(started) ? Math.max(0, Math.floor((new Date(now).getTime() - started) / 1000)) : 0;
    const labels = { starting: "Checking the backup drive", scanning: "Checking your files", staging: "Copying and checking changes", applying: "Saving the update", complete: "Confirming the saved update", "finished-with-issue": "Backup needs attention" };
    return { label: labels[progress?.phase || operation?.phase] || "Working on your backup", elapsedSeconds, indeterminate: true, percent: null, etaSeconds: null };
  }

  function projectBackupView({ config, catalog, lastAttempt, activeOperation } = {}) {
    const backupFormatVersion = format(config);
    const destinationId = config?.destination?.id;
    const valid = catalog?.schema === "datasafe.app-catalog" && catalog.formatVersion === 1 && catalog.destinationId === destinationId && catalog.backupFormatVersion === backupFormatVersion;
    const current = valid ? catalog : null;
    const v2 = backupFormatVersion === 2;
    const connected = current?.connection === "connected" && (!v2 || current.volumeMatch === true) && !current.lastKnown && current.state !== "invalid";
    const jobs = (config?.jobs || []).filter(job => job.enabled);
    const publicJobs = jobs.filter(job => (job.includePublicFolder && String(job.includePublicFolder).trim()) || job.includePublicDesktop);
    const enrollmentIssue = publicJobs.length
      ? "Merged Public-folder sources are unsupported. Choose compatible custom sample sources or remain in Legacy; your source choices have not been changed."
      : !jobs.length ? "Select at least one compatible custom sample source before enrollment." : !connected ? "Refresh and connect the selected drive before enrollment." : "";
    const repositories = v2 ? (current?.repositories || []).map(repository => ({
      computerId: repository.computerId,
      label: `${repository.computerName || repository.computerId} — ${repository.ownedByCurrentComputer ? "This PC" : "Other PC (read-only)"}`,
      readOnly: !repository.ownedByCurrentComputer,
      locations: (repository.locations || []).map(location => ({
        locationId: location.locationId,
        label: location.kind === "latest" ? "Latest Backup" : `Earlier Versions — ${location.kind === "deleted" ? "deleted files" : "changed files"}`,
        partial: location.kind !== "latest",
        explanation: location.kind === "latest" ? "Complete latest committed backup." : "Partial changed/deleted-file history, not a complete snapshot of that date.",
        canOpen: connected && Boolean(repository.capabilities?.browse)
      }))
    })) : [];
    const owned = (current?.repositories || []).filter(repository => repository.ownedByCurrentComputer && repository.computerId === current.currentComputerId);
    const own = owned.length === 1 ? owned[0] : null;
    const saved = Boolean(own?.currentTransactionId && own.currentManifestId);
    const attempt = lastAttempt?.destinationId === destinationId && lastAttempt.backupFormatVersion === backupFormatVersion ? lastAttempt : null;
    const operation = activeOperation?.destinationId === destinationId && activeOperation.backupFormatVersion === backupFormatVersion ? activeOperation : null;
    let title = saved ? "Latest Backup available" : "No confirmed incremental backup";
    let message = saved ? "Latest Backup is the complete committed tree. Earlier Versions contains partial file history." : "Run a manual sample backup after reviewing the selected drive.";
    let tone = saved ? "good" : "warning";
    if (attempt?.outcome === "committed" && saved) {
      title = "Your backup is up to date";
      message = attempt.message || message;
      if (attempt.copyBytes === 0) message += " No file content needed copying; checking files can still perform verification I/O.";
    } else if (attempt) {
      title = attempt.recoveryAction === "rolledBack" ? "Update rolled back" : attempt.outcome === "committed-with-warning" ? "Backup saved — attention needed" : attempt.outcome === "busy" ? "Backup already running" : "Backup needs attention";
      tone = attempt.outcome === "failed" ? "error" : "warning";
      message = [attempt.message, ...(attempt.warnings || []), saved ? "The last confirmed Latest Backup is retained." : "No new commit has been confirmed."].filter(Boolean).join(" ");
    }
    if (!connected) {
      title = current?.connection === "disconnected" || current?.lastKnown ? "Backup drive disconnected" : "Backup catalog needs attention";
      tone = "warning";
      message = current?.lastKnown ? "Last-known history only. Reconnect the selected drive and refresh before browsing or backing up." : "Refresh the selected drive. No connected, volume-matched catalog is confirmed.";
    } else if (["invalid", "recovery-required"].includes(current.state) && attempt?.outcome !== "committed-with-warning") {
      title = "Backup needs attention"; tone = "warning"; message = "The repository needs review or recovery. Only catalog-authorized actions are available.";
    }
    if (operation && connected) { title = "Backup in progress"; tone = "warning"; message = "Manual incremental backup. Elapsed time is shown; a copy ETA is not available."; }
    const backupTimeLabel = own?.committedAt ? `Committed at: ${own.committedAt}` : own?.backupCreatedAt ? `Backup created: ${own.backupCreatedAt} (not a completion time)` : "Completion time unavailable";
    return {
      backupFormatVersion, title, message, tone, backupTimeLabel, repositories,
      snapshotCount: v2 ? (saved ? 1 : 0) : (current?.legacySnapshots || []).length,
      canEnroll: !v2 && !enrollmentIssue,
      enrollmentIssue,
      canManualBackup: connected && (own ? Boolean(own.capabilities?.manualBackup) : ["empty", "identity-missing", "committed"].includes(current?.state) && (current.repositories || []).every(repository => repository.state === "committed" && !repository.ownedByCurrentComputer)),
      capabilities: { manualVerify: !v2, automaticRetention: !v2, legacyRestore: !v2 },
      storageEstimate: v2 ? "Incremental storage estimate not calculated" : "Legacy estimate",
      limitations: "Manual testing only. Verify, assisted restore and automatic retention are unavailable for incremental beta. Browse ordinary files to recover them; full point-in-time restore, migration and deletion approval are not included."
    };
  }
  return { projectBackupView, projectBackupProgress };
});
