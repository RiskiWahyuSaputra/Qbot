const { app, BrowserWindow, screen } = require('electron');

app.whenReady().then(() => {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width } = primaryDisplay.workAreaSize;

  const win = new BrowserWindow({
    width: 500,
    height: 100,
    x: Math.round((width - 500) / 2),
    y: 0,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    focusable: true,
    skipTaskbar: true,
    hasShadow: false,
    title: "HermesCoucouIsland",
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  win.loadURL('data:text/html,<body style="margin:0;display:flex;justify-content:center;align-items:center;height:100vh;"><div style="background:%23ff0055;color:white;font-weight:bold;padding:16px 32px;border-radius:24px;font-family:sans-serif;box-shadow:0 10px 30px rgba(0,0,0,0.5);">TEST VISIBLE ISLAND</div></body>');

  setTimeout(() => {
    app.quit();
  }, 4000);
});
