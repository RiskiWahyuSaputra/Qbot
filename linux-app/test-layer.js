const { app, BrowserWindow, screen } = require('electron');

app.whenReady().then(() => {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width } = primaryDisplay.workAreaSize;

  const win = new BrowserWindow({
    width: 600,
    height: 120,
    x: Math.round((width - 600) / 2),
    y: 0,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  win.loadURL(`file://${__dirname}/../dist/index.html`);

  setTimeout(() => {
    app.quit();
  }, 4000);
});
