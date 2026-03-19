const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("onebiteDesktop", {
  getState: () => ipcRenderer.invoke("state:get"),
  saveConfig: (config) => ipcRenderer.invoke("config:save", config),
  runBackup: () => ipcRenderer.invoke("backup:run"),
  checkCloud: () => ipcRenderer.invoke("cloud:check"),
  openOneDrive: () => ipcRenderer.invoke("cloud:open-onedrive"),
  installAutomation: () => ipcRenderer.invoke("automation:install"),
  checkForUpdates: () => ipcRenderer.invoke("updates:check"),
  downloadUpdate: () => ipcRenderer.invoke("updates:download"),
  installUpdate: () => ipcRenderer.invoke("updates:install"),
  openReleasesPage: () => ipcRenderer.invoke("updates:open-releases"),
  onUpdateStatus: (callback) => {
    const listener = (_event, status) => callback(status);
    ipcRenderer.on("updates:status", listener);
    return () => ipcRenderer.removeListener("updates:status", listener);
  },
  pickPath: (type) => ipcRenderer.invoke("job:pick-path", type),
  pickDestinationFolder: () => ipcRenderer.invoke("destination:pick-folder")
});
