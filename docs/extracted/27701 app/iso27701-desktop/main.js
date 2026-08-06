const { app, BrowserWindow, Menu, dialog, ipcMain, shell } = require('electron');
const path = require('path');
const fs   = require('fs');

// ── Single instance ────────────────────────────────────────────────────────
if (!app.requestSingleInstanceLock()) { app.quit(); process.exit(0); }

let win = null;

// ── Window ─────────────────────────────────────────────────────────────────
function createWindow() {
  win = new BrowserWindow({
    width:  1440,
    height: 900,
    minWidth:  960,
    minHeight: 640,
    title: 'ISO/IEC 27701:2019 — PIMS Compliance Assessment',
    backgroundColor: '#0a1628',
    show: false,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    icon: path.join(__dirname, 'assets', 'icon.png'),
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  win.loadFile(path.join(__dirname, 'src', 'app.html'));
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { win = null; });

  // External links → system browser
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url);
    return { action: 'deny' };
  });
}

// ── Menu ───────────────────────────────────────────────────────────────────
function buildMenu() {
  const isMac = process.platform === 'darwin';
  const send  = (action) => () => win?.webContents.send('menu-action', action);
  const js    = (code)   => () => win?.webContents.executeJavaScript(code);

  const template = [
    ...(isMac ? [{
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    }] : []),

    {
      label: 'File',
      submenu: [
        {
          label: 'Save Assessment Data…',
          accelerator: 'CmdOrCtrl+S',
          click: async () => {
            const raw = await win?.webContents.executeJavaScript(
              'JSON.stringify({ a: ANS, n: NOTES, o: ORG, v: 1, date: new Date().toISOString() })'
            );
            if (!raw) return;
            const org = JSON.parse(raw).o || 'Organisation';
            const date = new Date().toISOString().slice(0, 10);
            const { filePath } = await dialog.showSaveDialog(win, {
              title: 'Save Assessment Data',
              defaultPath: `ISO27701_Assessment_${org.replace(/[^a-z0-9]/gi,'_')}_${date}.json`,
              filters: [{ name: 'Assessment JSON', extensions: ['json'] }],
            });
            if (filePath) {
              fs.writeFileSync(filePath, raw, 'utf8');
              win?.webContents.send('menu-action', 'save-feedback');
            }
          },
        },
        {
          label: 'Load Assessment Data…',
          accelerator: 'CmdOrCtrl+O',
          click: async () => {
            const { filePaths } = await dialog.showOpenDialog(win, {
              title: 'Load Assessment Data',
              filters: [{ name: 'Assessment JSON', extensions: ['json'] }],
              properties: ['openFile'],
            });
            if (!filePaths?.[0]) return;
            const raw = fs.readFileSync(filePaths[0], 'utf8');
            // Pass to renderer safely via IPC
            win?.webContents.send('load-data', raw);
          },
        },
        { type: 'separator' },
        {
          label: 'Export Report as PDF…',
          accelerator: 'CmdOrCtrl+P',
          click: async () => {
            // Navigate to report first, then print
            win?.webContents.executeJavaScript("navTo('report')");
            await new Promise(r => setTimeout(r, 700));
            const { filePath } = await dialog.showSaveDialog(win, {
              title: 'Export Report PDF',
              defaultPath: `ISO27701_Report_${new Date().toISOString().slice(0,10)}.pdf`,
              filters: [{ name: 'PDF Document', extensions: ['pdf'] }],
            });
            if (filePath) {
              const data = await win?.webContents.printToPDF({
                pageSize: 'A4',
                printBackground: true,
                margins: { top: 0.5, bottom: 0.5, left: 0.5, right: 0.5 },
              });
              fs.writeFileSync(filePath, data);
              shell.openPath(filePath); // open in system PDF viewer
              win?.webContents.send('menu-action', 'save-feedback');
            }
          },
        },
        { type: 'separator' },
        {
          label: 'Reset All Data…',
          click: async () => {
            const { response } = await dialog.showMessageBox(win, {
              type: 'warning',
              title: 'Reset Assessment',
              message: 'Reset all assessment data?',
              detail: 'All answers, notes and scores will be permanently cleared. This cannot be undone.',
              buttons: ['Cancel', 'Reset Everything'],
              defaultId: 0,
              cancelId: 0,
            });
            if (response === 1) {
              win?.webContents.executeJavaScript(
                "ANS={}; NOTES={}; persist(); updateProgress(); updateSidebarScores(); renderDashboard(); navTo('dashboard');"
              );
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
          label: 'Dashboard',
          accelerator: 'CmdOrCtrl+1',
          click: js("navTo('dashboard')"),
        },
        {
          label: 'Findings Register',
          accelerator: 'CmdOrCtrl+2',
          click: js("navTo('findings')"),
        },
        {
          label: 'Formal Report',
          accelerator: 'CmdOrCtrl+3',
          click: js("navTo('report')"),
        },
        { type: 'separator' },
        { label: 'Section 1 — Context (§5)',          click: js("navTo('section','S1 \u2013 Context (S.5)')") },
        { label: 'Section 2 — Leadership (§6)',       click: js("navTo('section','S2 \u2013 Leadership (S.6)')") },
        { label: 'Section 3 — Planning (§7)',         click: js("navTo('section','S3 \u2013 Planning (S.7)')") },
        { label: 'Section 4 — Support (§8)',          click: js("navTo('section','S4 \u2013 Support (S.8)')") },
        { label: 'Section 5 — Operation (§9)',        click: js("navTo('section','S5 \u2013 Operation (S.9)')") },
        { label: 'Section 6 — Performance (§10)',     click: js("navTo('section','S6 \u2013 Performance (S.10)')") },
        { label: 'Section 7 — Improvement (§11)',     click: js("navTo('section','S7 \u2013 Improvement (S.11)')") },
        { type: 'separator' },
        { label: 'Annex A — Conditions (A.7.2)',      click: js("navTo('section','S8 \u2013 A.Conditions (A.7.2)')") },
        { label: 'Annex A — Obligations (A.7.3)',     click: js("navTo('section','S9 \u2013 A.Obligations (A.7.3)')") },
        { label: 'Annex A — Privacy by Design (A.7.4)',click: js("navTo('section','S10 \u2013 A.PbD (A.7.4)')") },
        { label: 'Annex A — Transfers (A.7.5)',       click: js("navTo('section','S11 \u2013 A.Transfers (A.7.5)')") },
        { label: 'Annex A — DSR Rights (A.7.6)',      click: js("navTo('section','S12 \u2013 A.DSRs (A.7.6)')") },
        { label: 'Annex A — Breach (A.7.7-8)',        click: js("navTo('section','S13 \u2013 A.Breach (A.7.7-8)')") },
        { type: 'separator' },
        { label: 'Annex B — Processor (B.8)',         click: js("navTo('section','S14 \u2013 B.Processor (B.8)')") },
        { label: 'IS Controls — Access & Crypto',     click: js("navTo('section','S15 \u2013 IS Access & Crypto')") },
        { label: 'IS Controls — Logging & Vuln',      click: js("navTo('section','S16 \u2013 IS Logging & Vuln')") },
        { label: 'IS Controls — Network & SDLC',      click: js("navTo('section','S17 \u2013 IS Network & SDLC')") },
      ],
    },

    {
      label: 'Report',
      submenu: [
        {
          label: 'View Formal Report',
          accelerator: 'CmdOrCtrl+Shift+R',
          click: js("navTo('report')"),
        },
        {
          label: 'Export PDF…',
          accelerator: 'CmdOrCtrl+Shift+P',
          click: async () => {
            win?.webContents.executeJavaScript("navTo('report')");
            await new Promise(r => setTimeout(r, 700));
            const { filePath } = await dialog.showSaveDialog(win, {
              title: 'Save Report PDF',
              defaultPath: `ISO27701_PIMS_Report_${new Date().toISOString().slice(0,10)}.pdf`,
              filters: [{ name: 'PDF', extensions: ['pdf'] }],
            });
            if (filePath) {
              const data = await win?.webContents.printToPDF({ pageSize:'A4', printBackground:true });
              fs.writeFileSync(filePath, data);
              shell.openPath(filePath);
            }
          },
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
        { role: 'zoomIn', accelerator: 'CmdOrCtrl+=' },
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
          label: 'About PIMS Assessment Suite',
          click: () => dialog.showMessageBox(win, {
            type: 'info',
            title: 'About',
            message: 'ISO/IEC 27701:2019 PIMS Assessment Suite',
            detail: [
              `Version ${app.getVersion()}`,
              '',
              '77 controls across 17 sections covering:',
              '  • PIMS Core Management Clauses (§5–§11)',
              '  • Annex A: PII Controller Obligations (A.7.2–A.7.8)',
              '  • Annex B: PII Processor Obligations (B.8)',
              '  • Information Security Controls',
              '',
              'Generates a formal compliance report with:',
              '  • Executive summary & score ring',
              '  • Section scorecard & radar chart',
              '  • Consolidated gap register',
              '  • Prioritised recommendations',
              '  • Full control appendix',
              '',
              'Data stored locally. Fully offline.',
            ].join('\n'),
            buttons: ['OK'],
          }),
        },
        { type: 'separator' },
        { label: 'ISO/IEC 27701 Overview', click: () => shell.openExternal('https://www.iso.org/standard/71670.html') },
        { label: 'Information Regulator (SA)', click: () => shell.openExternal('https://inforegulator.org.za') },
        { label: 'IAPP Privacy Resource Centre', click: () => shell.openExternal('https://iapp.org/resources/') },
      ],
    },
  ];

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ── IPC handlers ───────────────────────────────────────────────────────────
ipcMain.handle('get-app-version', () => app.getVersion());

ipcMain.handle('save-text-file', async (event, { content, filename }) => {
  const { filePath } = await dialog.showSaveDialog(win, {
    defaultPath: filename,
    filters: [{ name: 'JSON', extensions: ['json'] }],
  });
  if (filePath) { fs.writeFileSync(filePath, content, 'utf8'); return { success: true, filename: path.basename(filePath) }; }
  return { success: false };
});

// App lifecycle ──────────────────────────────────────────────────────────────
app.whenReady().then(() => {
  buildMenu();
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('second-instance', () => {
  if (win) { if (win.isMinimized()) win.restore(); win.focus(); }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
