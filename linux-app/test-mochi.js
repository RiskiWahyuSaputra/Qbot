const { app, BrowserWindow, screen } = require('electron');
const path = require('path');

app.whenReady().then(() => {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width } = primaryDisplay.workAreaSize;

  const win = new BrowserWindow({
    width: 700,
    height: 400,
    x: Math.round((width - 700) / 2),
    y: 0,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    title: "HermesCoucouIsland",
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  win.loadFile(path.join(__dirname, '../dist/index.html'));

  setTimeout(() => {
    app.quit();
  }, 4000);
});
