const { app, BrowserWindow, screen, ipcMain } = require('electron');
const path = require('path');
const { startServer } = require('./server');

let mainWindow = null;

const defaultSettings = {
  hooksInstalled: true,
  configuredIntegrations: ["integration_claude"],
  showMiniBots: true,
  soundVolume: 0.8,
  compactPillWidth: 292
};

function createWindow() {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width } = primaryDisplay.workAreaSize;

  const winW = 720;
  const winH = 360;
  const x = Math.round((width - winW) / 2);
  const y = 0;

  mainWindow = new BrowserWindow({
    width: winW,
    height: winH,
    x: x,
    y: y,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    resizable: false,
    title: "HermesCoucouIsland",
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));

  // Wire IPC handlers
  ipcMain.handle('boot', () => {
    return {
      settings: defaultSettings,
      screen: { x: 0, y: 0, width: primaryDisplay.size.width, height: primaryDisplay.size.height, scale: 1 },
      version: "1.0.0-linux",
      hookPath: "/tmp/hermes-hook"
    };
  });

  ipcMain.handle('set_collapsed', (_e, { collapsed }) => {
    // When collapsed, we can ignore or minimize window click-through area
  });

  ipcMain.handle('set_island_rect', (_e, { x, y, width, height }) => {
    // Island position update
  });

  ipcMain.handle('approval_decision', (_e, { requestId, decision }) => {
    console.log(`[Coucou Linux] Approval decision: ${decision} for ${requestId}`);
  });

  ipcMain.handle('approval_ack', (_e, { requestId }) => {
    console.log(`[Coucou Linux] Approval ack: ${requestId}`);
  });

  // Start internal HTTP bridge for Hermes / CLI
  startServer((eventPayload) => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('hook', eventPayload);
    }
  });
}

// Track mouse cursor and pass to webview for Mochi's eye movement
setInterval(() => {
  if (mainWindow && !mainWindow.isDestroyed()) {
    const point = screen.getCursorScreenPoint();
    const bounds = mainWindow.getBounds();
    const localX = point.x - bounds.x;
    const localY = point.y - bounds.y;
    mainWindow.webContents.send('cursor', { x: localX, y: localY });
  }
}, 33); // ~30 fps tracking

app.whenReady().then(() => {
  createWindow();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
