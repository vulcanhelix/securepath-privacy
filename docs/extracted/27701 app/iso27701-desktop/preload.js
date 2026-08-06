const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  // App info
  getAppVersion: () => ipcRenderer.invoke('get-app-version'),
  platform: process.platform,

  // File operations
  saveTextFile: (content, filename) =>
    ipcRenderer.invoke('save-text-file', { content, filename }),

  // Menu → renderer communication
  onMenuAction: (callback) =>
    ipcRenderer.on('menu-action', (_event, action) => callback(action)),

  // Main → renderer: load data
  onLoadData: (callback) =>
    ipcRenderer.on('load-data', (_event, json) => callback(json)),
});
