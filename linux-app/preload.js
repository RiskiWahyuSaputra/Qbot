// Preload script to inject Linux Bridge for Coucou UI
const { ipcRenderer } = require('electron');

window.__LINUX_BRIDGE__ = {
  send: (channel, data) => ipcRenderer.send(channel, data),
  invoke: (channel, data) => ipcRenderer.invoke(channel, data),
  on: (channel, callback) => {
    const sub = (_event, val) => callback(val);
    ipcRenderer.on(channel, sub);
    return () => ipcRenderer.removeListener(channel, sub);
  }
};
