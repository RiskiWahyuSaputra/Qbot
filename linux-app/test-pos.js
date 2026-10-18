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
    title: "HermesCoucouIsland",
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  win.loadURL('data:text/html,<body style="margin:0;display:flex;justify-content:center;background:transparent;"><div style="background:%23111;color:white;padding:12px 24px;border-radius:24px;border:1px solid %23333;font-family:sans-serif;box-shadow:0 8px 24px rgba(0,0,0,0.5);">✨ Mochi Hermes Notch Ready ✨</div></body>');

  setTimeout(() => {
    app.quit();
  }, 3000);
});
