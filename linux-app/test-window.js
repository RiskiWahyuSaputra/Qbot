const { app, BrowserWindow, screen } = require('electron');

app.whenReady().then(() => {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width } = primaryDisplay.workAreaSize;

  const win = new BrowserWindow({
    width: 600,
    height: 80,
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

  win.loadURL('data:text/html,<body style="margin:0;display:flex;justify-content:center;"><div style="background:%23111;color:white;padding:10px 30px;border-radius:20px;border:1px solid %23333;font-family:sans-serif;">🐾 Hermes Island Alive!</div></body>');

  setTimeout(() => {
    app.quit();
  }, 3000);
});
