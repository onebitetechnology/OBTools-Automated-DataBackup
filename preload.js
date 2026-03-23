const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("onebiteDesktop", {
  getState: () => ipcRenderer.invoke("state:get"),
  saveConfig: (config) => ipcRenderer.invoke("config:save", config),
  runBackup: () => ipcRenderer.invoke("backup:run"),
  checkCloud: () => ipcRenderer.invoke("cloud:check"),
  openOneDrive: () => ipcRenderer.invoke("cloud:open-onedrive"),
  installAutomation: () => ipcRenderer.invoke("automation:install"),
  checkForUpdates: (configOverride) => ipcRenderer.invoke("updates:check", configOverride),
  downloadUpdate: () => ipcRenderer.invoke("updates:download"),
  installUpdate: () => ipcRenderer.invoke("updates:install"),
  openReleasesPage: () => ipcRenderer.invoke("updates:open-releases"),
  openSupportEmail: () => ipcRenderer.invoke("support:open-email"),
  openLogsFolder: () => ipcRenderer.invoke("logs:open-folder"),
  onUpdateStatus: (callback) => {
    const listener = (_event, status) => callback(status);
    ipcRenderer.on("updates:status", listener);
    return () => ipcRenderer.removeListener("updates:status", listener);
  },
  onBackupProgress: (callback) => {
    const listener = (_event, progress) => callback(progress);
    ipcRenderer.on("backup:progress", listener);
    return () => ipcRenderer.removeListener("backup:progress", listener);
  },
  detectBrowsers: () => ipcRenderer.invoke("browsers:detect"),
  analyzeStorage: () => ipcRenderer.invoke("storage:analyze"),
  pickPath: (type) => ipcRenderer.invoke("job:pick-path", type),
  pickDestinationFolder: () => ipcRenderer.invoke("destination:pick-folder")
});
