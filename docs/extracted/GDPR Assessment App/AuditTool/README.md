# GDPR · DUAA 2025 · ISO 27701:2019
# Data Protection Compliance Audit Tool
## User Guide & Reference Manual

---

## OVERVIEW

This desktop application is a professional compliance audit tool mapped to three regulatory frameworks:

| Framework | Full Name | Scope |
|-----------|-----------|-------|
| **GDPR** | General Data Protection Regulation (EU) 2016/679 / UK GDPR | Data protection law |
| **DUAA 2025** | Data (Use and Access) Act 2025 | UK smart data, intermediaries, recognised LI |
| **ISO 27701:2019** | Privacy Information Management Systems | International privacy standard |

The tool covers **77 audit questions** across **6 sections**, generating two professional PDF reports:
- **Executive Summary Report** — board/senior management briefing
- **Detailed Findings & Remediation Report** — full audit workbook with control-level detail

---

## SYSTEM REQUIREMENTS

| Component | Minimum | Notes |
|-----------|---------|-------|
| Python | 3.9+ | Download from python.org |
| Operating System | Windows 10+, macOS 11+, Ubuntu 20.04+ | |
| RAM | 512 MB | |
| Disk | 50 MB | |
| Display | 1280×768 | 1440×900 or wider recommended |

**Python packages** (auto-installed on first launch):
- `openpyxl` — reads the audit question XLSX files
- `reportlab` — generates professional PDF reports
- `pillow` — image support

---

## INSTALLATION & LAUNCH

### Windows
1. Extract the `AuditTool` folder anywhere on your computer
2. Double-click **`Launch_Audit_Tool.bat`**
3. Python packages install automatically on first run (~30 seconds)

### macOS
1. Extract the `AuditTool` folder
2. Double-click **`Launch_Audit_Tool.command`**
   - If blocked by Gatekeeper: right-click → Open → Open
3. Or open Terminal and run: `bash Launch_Audit_Tool.sh`

### Linux
```bash
bash Launch_Audit_Tool.sh
```

---

## FOLDER STRUCTURE

```
AuditTool/
├── audit_app.py              ← Main application (do not move)
├── data_engine.py            ← Data loading and state management
├── report_generator.py       ← PDF report generation engine
├── audit_data/               ← Audit question source files (do not delete)
│   ├── Audit_GDPR_DUAA_ISO27701_Section_1.xlsx
│   ├── Audit_GDPR_DUAA_ISO27701_Section_2.xlsx
│   ├── Audit_GDPR_DUAA_ISO27701_Section_3.xlsx
│   ├── Audit_GDPR_DUAA_ISO27701_Section_4.xlsx
│   ├── Audit_GDPR_DUAA_ISO27701_Section_5.xlsx
│   └── Audit_GDPR_DUAA_ISO27701_Section_6.xlsx
├── saved_audits/             ← Your saved audit progress (.json files)
├── Launch_Audit_Tool.bat     ← Windows launcher
├── Launch_Audit_Tool.sh      ← Linux/macOS terminal launcher
├── Launch_Audit_Tool.command ← macOS double-click launcher
└── README.md                 ← This file
```

---

## USING THE APPLICATION

### Step 1 — Configure Audit Settings
Click **⚙ Settings** (top right) and enter:
- Organisation Name
- Lead Auditor name and credentials
- Audit Date
- Audit Reference number (e.g. DPA-2026-001)

These details appear on all generated reports.

### Step 2 — Navigate Questions
- **Left panel**: question list — click any question to open it
- **Section tabs** (top): filter by section (S1–S6) or view All
- **Search box**: filter questions by keyword
- **Status filter**: show only Non-Compliant, Partial, Not Answered, etc.

### Step 3 — Complete Each Question
For each audit question:

1. **Read the question** — displayed prominently at the top
2. **Read "Why This Matters"** — explains the regulatory significance
3. **Review the references** — GDPR/DUAA 2025 and ISO 27701 clauses
4. **Select a response**:
   - ✓ Yes – Fully Compliant
   - ◑ Yes – Partially Compliant
   - ✗ No – Non-Compliant
   - – N/A – Not Applicable
5. **Enter findings** — document your specific observations
6. **Assign tracking** — responsible party, target date, status
7. Click **✓ Save Response & Next** to proceed

### Step 4 — Save Progress
Click **💾 Save** at any time to save to a `.json` file.
Click **📂 Load** to resume a previous audit session.

### Step 5 — Generate Reports

#### Executive Summary Report (📋 Exec Report)
- 4–6 pages, designed for board and senior leadership
- Overall compliance score with rating
- Non-compliance risk summary table (Critical / High / Medium / Low)
- Section-by-section scorecard
- Critical findings with required actions
- Six board-level recommendations
- Formal sign-off block
- Suitable for board packs, audit committee papers, regulatory submissions

#### Detailed Findings & Remediation Report (📄 Detailed Report)
- 30–60+ pages depending on audit scope
- Full question-by-question findings
- Colour-coded compliance status per control
- Complete remediation steps for every gap
- GDPR/DUAA 2025 and ISO 27701 references per question
- Consolidated Remediation Action Plan table
- Methodology and framework reference section
- Formal sign-off block

Both reports are formatted as CONFIDENTIAL, legally privileged documents.

---

## AUDIT SECTIONS

| # | Section | Questions | Key Frameworks |
|---|---------|-----------|----------------|
| 1 | Procedural Issues & Awareness | 13 | GDPR Art.5(2), 24, 37–39; ISO 27701 cl.5–6 |
| 2 | Lawful Processing of Personal Data | 13 | GDPR Art.6–10, 28, 44–49; ISO 27701 cl.7.2 |
| 3 | Record Retention | 10 | GDPR Art.5(1)(e), 17, 30; ISO 27701 cl.7.4 |
| 4 | Security of Personal Data | 18 | GDPR Art.32–34; ISO 27701 cl.6.9–6.13 |
| 5 | Data Subject Rights & Requests | 11 | GDPR Art.12–22; ISO 27701 cl.7.3 |
| 6 | Direct Marketing | 12 | GDPR Art.6–7; PECR; ISO 27701 cl.7.2–7.3 |

---

## SCORING METHODOLOGY

| Rating | Score | Description |
|--------|-------|-------------|
| ✓ Fully Compliant | 2 points | Control fully evidenced |
| ◑ Partially Compliant | 1 point | Material gap remains |
| ✗ Non-Compliant | 0 points | Control absent or failed |
| – Not Applicable | Excluded | Not scored |

**Overall Score** = Total Points ÷ Maximum Points × 100%

| Score Range | Rating |
|-------------|--------|
| 75–100% | Satisfactory |
| 50–74% | Requires Improvement |
| 0–49% | Significant Gaps Identified |

---

## RISK LEVELS

| Level | Action Required |
|-------|----------------|
| 🔴 Critical | Immediate action — within 5 business days |
| 🟠 High | Within 30 days |
| 🟡 Medium | Within 90 days |
| 🟢 Low | Within 6 months / next review cycle |

---

## DATA & PRIVACY

- All audit data is stored **locally only** — no internet connection required
- Saved audit files (`.json`) contain only your responses, findings, and tracking data
- No personal data about data subjects is collected or stored
- Reports are generated locally as PDF files

---

## TROUBLESHOOTING

| Issue | Solution |
|-------|----------|
| "Python not found" | Install Python 3.9+ from python.org, ensure "Add to PATH" is checked |
| "No module named tkinter" (macOS) | Run: `brew install python-tk` or reinstall Python from python.org |
| "No module named reportlab" | Run the launcher — it installs dependencies automatically |
| Questions not loading | Ensure the `audit_data` folder is in the same directory as `audit_app.py` |
| Report generation fails | Check you have write permission to the save location |
| App window too small | Resize the window or use 1440×900+ resolution |

---

## LEGAL NOTICE

This tool and its reports are provided for compliance audit purposes.  
Reports generated by this tool are intended to be CONFIDENTIAL and LEGALLY PRIVILEGED.  
This tool does not constitute legal advice. Organisations should seek qualified legal and  
data protection counsel in relation to their specific compliance obligations.

Framework references are current as of March 2026.

---

*GDPR · Data (Use and Access) Act 2025 · ISO/IEC 27701:2019 Compliance Audit Tool*  
*Version 2.0 — March 2026*
