const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("onebiteDesktop", {
  getState: () => ipcRenderer.invoke("state:get"),
  saveConfig: (config) => ipcRenderer.invoke("config:save", config),
  runBackup: () => ipcRenderer.invoke("backup:run"),
  checkCloud: () => ipcRenderer.invoke("cloud:check"),
  installAutomation: () => ipcRenderer.invoke("automation:install"),
  checkForUpdates: () => ipcRenderer.invoke("updates:check"),
  pickPath: (type) => ipcRenderer.invoke("job:pick-path", type),
  pickDestinationFolder: () => ipcRenderer.invoke("destination:pick-folder")
});
