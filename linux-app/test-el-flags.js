const { app, BrowserWindow } = require('electron');

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 400,
    height: 150,
    frame: true,
    title: "TestElectronFlags"
  });
  win.loadURL('data:text/html,<body style="background:black;color:white;display:flex;align-items:center;justify-content:center;height:100vh;"><h1>Electron Window OK</h1></body>');
  setTimeout(() => app.quit(), 3000);
});
