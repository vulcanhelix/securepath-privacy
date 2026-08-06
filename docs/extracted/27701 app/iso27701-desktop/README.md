# 🛡️ ISO/IEC 27701:2019 PIMS Assessment Suite — Desktop App

A fully offline desktop compliance assessment application for **ISO/IEC 27701:2019** — Privacy Information Management System.

**77 controls · 17 sections · Formal graphical report · 100% offline**

---

## ✅ Prerequisites

**Node.js 18 or later** — download from [nodejs.org](https://nodejs.org) (choose LTS)

---

## 🚀 Quick Start

### macOS / Linux
```bash
chmod +x setup-and-run.sh
./setup-and-run.sh
```
After the first install, just run: `npm start`

### Windows
```
Double-click: setup-and-run.bat
```
After the first install, just run: `npm start` in this folder

---

## 📦 Build Installers

```bash
npm install            # install dependencies first

npm run build:mac      # → dist/  macOS .dmg (universal: Intel + Apple Silicon)
npm run build:win      # → dist/  Windows .exe installer + portable
npm run build:linux    # → dist/  Linux .AppImage + .deb
npm run build:all      # → all three platforms
```

---

## 📋 What's Assessed

| Group | Sections | Controls |
|---|---|---|
| PIMS Core (§5–§11) | 7 sections | 24 controls |
| Annex A — PII Controller (A.7.2–A.7.8) | 6 sections | 25 controls |
| Annex B — PII Processor (B.8) | 1 section | 8 controls |
| IS Controls (Access, Logging, Network) | 3 sections | 20 controls |

---

## 🖥️ Features

| Feature | Detail |
|---|---|
| Assessment tool | 77 controls, status buttons (Compliant / Partial / Non-Compliant / N/A) |
| Evidence guidance | Expected evidence listed for every control |
| Remediation actions | Recommended remediation for every control |
| Free-text notes | Record findings and evidence notes per control |
| Auto-save | All answers saved instantly to localStorage |
| Dashboard | Donut chart, bar chart, radar chart, section progress bars |
| Findings register | Filterable table of all assessed controls |
| Formal report | 7-section PDF-ready report with 4 charts + gap register + recommendations |
| Save/Load data | Export/import assessment JSON via native file dialogs |
| PDF export | Native `printToPDF` → opens in system PDF viewer |
| Keyboard shortcuts | Full native menu with shortcuts |
| Offline | Zero CDN dependencies — runs without internet |

---

## ⌨️ Keyboard Shortcuts

| Action | Mac | Windows/Linux |
|---|---|---|
| Save assessment data | `⌘S` | `Ctrl+S` |
| Load assessment data | `⌘O` | `Ctrl+O` |
| Export PDF report | `⌘⇧P` | `Ctrl+Shift+P` |
| Dashboard | `⌘1` | `Ctrl+1` |
| Findings register | `⌘2` | `Ctrl+2` |
| Formal report | `⌘3` | `Ctrl+3` |
| View report | `⌘⇧R` | `Ctrl+Shift+R` |
| Zoom in / out | `⌘+/-` | `Ctrl+=/- ` |
| Fullscreen | `⌘Ctrl+F` | `F11` |
| Dev tools | `⌥⌘I` | `Ctrl+Shift+I` |

---

## 💾 Data & Privacy

All data is stored **locally on your device** using browser localStorage. Nothing is transmitted to any server. The app works fully offline after installation.

Use **File → Save Assessment Data** to export your answers as a `.json` file for backup, sharing with colleagues, or loading on another device.

---

## 🗂️ Project Structure

```
iso27701-desktop/
├── main.js              ← Electron main process (window, menus, PDF export, IPC)
├── preload.js           ← Secure IPC bridge
├── package.json         ← App config and build settings
├── setup-and-run.sh     ← macOS/Linux launcher
├── setup-and-run.bat    ← Windows launcher
├── README.md
├── src/
│   └── app.html         ← Complete assessment app (150KB, zero CDN deps)
└── assets/
    ├── icon.png         ← App icon (512×512)
    ├── icon.icns        ← macOS icon
    └── icon.ico         ← Windows icon
```

---

## 📄 Report Structure

The formal report (File → Export Report as PDF) includes:

1. **Cover page** — Organisation, date, overall score, RAG status
2. **Executive Summary** — Score ring, stat cards, donut + stacked bar charts
3. **Scope & Methodology** — Assessment approach and scoring explanation
4. **Section Scorecard** — Radar chart + full table (17 sections, RAG per row)
5. **Domain Analysis** — Group-level scores (PIMS Core, Annex A/B, IS Controls)
6. **Gap Register** — All Non-Compliant and Partial controls with remediation
7. **Recommendations** — High priority (30 days) + Medium priority (90 days)
8. **Conclusion** — Summary and next steps
9. **Appendix A** — Full 77-control reference table

---

## 🔧 Technical Notes

- **Electron 29** — Chromium-based renderer, V8 JS engine
- **Charts** — Custom canvas chart engine (no Chart.js dependency)
- **PDF export** — Uses Electron's native `printToPDF` (Chromium rendering)
- **Node.js 18+** required for Electron 29
- **Platform support:** macOS 10.15+, Windows 10+, Linux (Ubuntu 18.04+)
