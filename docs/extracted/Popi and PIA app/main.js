const { app, BrowserWindow, Menu, dialog, ipcMain, shell, nativeTheme } = require('electron');
const path = require('path');
const fs = require('fs');

// ── Keep single instance ───────────────────────────────────────────────────
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) { app.quit(); process.exit(0); }

let win = null;

// ── Create main window ─────────────────────────────────────────────────────
function createWindow() {
  win = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 900,
    minHeight: 600,
    title: 'POPIA & PAIA Compliance Suite',
    backgroundColor: '#0f2744',
    show: false, // show after ready-to-show for smooth launch
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
    },
    // macOS traffic light style titlebar
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    icon: path.join(__dirname, 'assets', 'icon.png'),
  });

  win.loadFile(path.join(__dirname, 'src', 'app.html'));

  win.once('ready-to-show', () => { win.show(); });

  win.on('closed', () => { win = null; });

  // Open external links in system browser
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url);
    return { action: 'deny' };
  });
}

// ── Native menu ────────────────────────────────────────────────────────────
function buildMenu() {
  const isMac = process.platform === 'darwin';

  const template = [
    ...(isMac ? [{ label: app.name, submenu: [
      { role: 'about' },
      { type: 'separator' },
      { role: 'services' },
      { type: 'separator' },
      { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' },
      { type: 'separator' },
      { role: 'quit' }
    ]}] : []),

    {
      label: 'File',
      submenu: [
        {
          label: 'Export POPIA Report (PDF)…',
          accelerator: 'CmdOrCtrl+P',
          click: () => win?.webContents.send('menu-action', 'export-popia-pdf'),
        },
        {
          label: 'Export PAIA Report (Word)…',
          accelerator: 'CmdOrCtrl+Shift+W',
          click: () => win?.webContents.send('menu-action', 'export-paia-word'),
        },
        { type: 'separator' },
        {
          label: 'Save Assessment Data…',
          accelerator: 'CmdOrCtrl+S',
          click: async () => {
            const data = await win?.webContents.executeJavaScript('JSON.stringify({popia: {a: ANS, o: ST.org}, paia: {a: PANS, o: PST.org}})');
            const { filePath } = await dialog.showSaveDialog(win, {
              title: 'Save Assessment Data',
              defaultPath: `compliance-assessment-${new Date().toISOString().slice(0,10)}.json`,
              filters: [{ name: 'Assessment Data', extensions: ['json'] }],
            });
            if (filePath) { fs.writeFileSync(filePath, data, 'utf8'); }
          },
        },
        {
          label: 'Load Assessment Data…',
          accelerator: 'CmdOrCtrl+O',
          click: async () => {
            const { filePaths } = await dialog.showOpenDialog(win, {
              title: 'Load Assessment Data',
              filters: [{ name: 'Assessment Data', extensions: ['json'] }],
              properties: ['openFile'],
            });
            if (filePaths?.[0]) {
              const data = fs.readFileSync(filePaths[0], 'utf8');
              win?.webContents.executeJavaScript(`
                try {
                  const d = JSON.parse(${JSON.stringify(data)});
                  if(d.popia){ ANS = d.popia.a || {}; ST.org = d.popia.o || ST.org; persist(); }
                  if(d.paia){ PANS = d.paia.a || {}; PST.org = d.paia.o || PST.org; paiaPersist(); }
                  if(ACTIVE_TOOL==='popia') render(); else paiaRender();
                } catch(e){ console.error(e); }
              `);
            }
          },
        },
        {
          label: 'Reset All Assessment Data…',
          click: async () => {
            const { response } = await dialog.showMessageBox(win, {
              type: 'warning',
              title: 'Reset Assessment Data',
              message: 'Reset all POPIA and PAIA assessment data?',
              detail: 'This will permanently clear all answers, notes and scores. This cannot be undone.',
              buttons: ['Cancel', 'Reset Everything'],
              defaultId: 0,
              cancelId: 0,
            });
            if (response === 1) {
              win?.webContents.executeJavaScript(`
                ANS={}; PANS={};
                persist(); paiaPersist();
                if(ACTIVE_TOOL==='popia') render(); else paiaRender();
              `);
            }
          },
        },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit' },
      ],
    },

    {
      label: 'Assessment',
      submenu: [
        {
          label: 'Switch to POPIA & ISO 27701',
          accelerator: 'CmdOrCtrl+1',
          click: () => win?.webContents.executeJavaScript("switchTool('popia')"),
        },
        {
          label: 'Switch to PAIA',
          accelerator: 'CmdOrCtrl+2',
          click: () => win?.webContents.executeJavaScript("switchTool('paia')"),
        },
        { type: 'separator' },
        {
          label: 'POPIA Dashboard',
          click: () => win?.webContents.executeJavaScript("if(ACTIVE_TOOL!=='popia')switchTool('popia'); go('dash')"),
        },
        {
          label: 'PAIA Dashboard',
          click: () => win?.webContents.executeJavaScript("if(ACTIVE_TOOL!=='paia')switchTool('paia'); paiaGo('dash')"),
        },
        { type: 'separator' },
        {
          label: 'View POPIA Findings',
          click: () => win?.webContents.executeJavaScript("if(ACTIVE_TOOL!=='popia')switchTool('popia'); go('find')"),
        },
        {
          label: 'View PAIA Findings',
          click: () => win?.webContents.executeJavaScript("if(ACTIVE_TOOL!=='paia')switchTool('paia'); paiaGo('find')"),
        },
      ],
    },

    {
      label: 'Reports',
      submenu: [
        {
          label: 'Generate POPIA Report (Preview)',
          click: () => win?.webContents.executeJavaScript("if(ACTIVE_TOOL!=='popia')switchTool('popia'); setTimeout(openReport,300)"),
        },
        {
          label: 'Generate PAIA Report (Preview)',
          click: () => win?.webContents.executeJavaScript("if(ACTIVE_TOOL!=='paia')switchTool('paia'); setTimeout(paiaOpenReport,300)"),
        },
        { type: 'separator' },
        {
          label: 'Download PAIA Word Report',
          click: () => win?.webContents.executeJavaScript("if(ACTIVE_TOOL!=='paia')switchTool('paia'); setTimeout(paiaExportWord,300)"),
        },
      ],
    },

    { role: 'editMenu' },

    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'forceReload' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
        { type: 'separator' },
        {
          label: 'Toggle Developer Tools',
          accelerator: isMac ? 'Alt+Cmd+I' : 'Ctrl+Shift+I',
          click: () => win?.webContents.toggleDevTools(),
        },
      ],
    },

    { role: 'windowMenu' },

    {
      label: 'Help',
      submenu: [
        {
          label: 'About POPIA & PAIA Compliance Suite',
          click: () => dialog.showMessageBox(win, {
            type: 'info',
            title: 'About',
            message: 'POPIA & PAIA Compliance Suite',
            detail: `Version 1.0.0\n\nA comprehensive compliance assessment tool for:\n• Protection of Personal Information Act (POPIA) — Act 4 of 2013\n• ISO/IEC 27701:2019 Privacy Information Management\n• Protection of Access to Information Act (PAIA) — Act 2 of 2000\n\n76 POPIA questions · 40 PAIA questions\n\nDeveloped for South African compliance professionals.`,
            buttons: ['OK'],
          }),
        },
        { type: 'separator' },
        {
          label: 'Open SAHRC Website',
          click: () => shell.openExternal('https://www.sahrc.org.za'),
        },
        {
          label: 'Open Information Regulator Website',
          click: () => shell.openExternal('https://inforegulator.org.za'),
        },
      ],
    },
  ];

  const menu = Menu.buildFromTemplate(template);
  Menu.setApplicationMenu(menu);
}

// ── IPC handlers ───────────────────────────────────────────────────────────
ipcMain.handle('save-docx', async (event, { buffer, filename }) => {
  const { filePath } = await dialog.showSaveDialog(win, {
    title: 'Save Word Report',
    defaultPath: filename,
    filters: [{ name: 'Word Document', extensions: ['docx'] }],
  });
  if (filePath) {
    fs.writeFileSync(filePath, Buffer.from(buffer));
    return { success: true, path: filePath };
  }
  return { success: false };
});

ipcMain.handle('get-app-version', () => app.getVersion());

// ── App lifecycle ──────────────────────────────────────────────────────────
app.whenReady().then(() => {
  buildMenu();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('second-instance', () => {
  if (win) { if (win.isMinimized()) win.restore(); win.focus(); }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
