"""
audit_app.py  –  GDPR · DUAA 2025 · ISO 27701 Compliance Audit Tool
Desktop application (Tkinter).
"""

import os, sys, json, tkinter as tk
from tkinter import ttk, messagebox, filedialog, simpledialog
from datetime import datetime
import threading

# ── path bootstrap ────────────────────────────────────────────────────────────
APP_DIR   = os.path.dirname(os.path.abspath(__file__))
DATA_DIR  = os.path.join(APP_DIR, "audit_data")
SAVES_DIR = os.path.join(APP_DIR, "saved_audits")
os.makedirs(SAVES_DIR, exist_ok=True)

sys.path.insert(0, APP_DIR)
from data_engine import AuditState, RESPONSE_OPTIONS
from report_generator import build_executive_report, build_detailed_report

# ── Brand colours (for Tk widgets) ───────────────────────────────────────────
C_NAVY      = "#1F3864"
C_MIDBLUE   = "#2E5FA3"
C_TEAL      = "#1F6B75"
C_LIGHTBLUE = "#DEEAF1"
C_WHITE     = "#FFFFFF"
C_GREY10    = "#F2F2F2"
C_GREY40    = "#595959"
C_RED       = "#C00000"
C_ORANGE    = "#E26B0A"
C_AMBER     = "#FFBF00"
C_GREEN     = "#375623"
C_LTGREEN   = "#E2EFDA"
C_LTRED     = "#FCE4E4"
C_LTAMBER   = "#FFF3CD"

RISK_BG = {
    "Critical": C_LTRED,
    "High":     C_LTAMBER,
    "Medium":   "#FFF9E6",
    "Low":      C_LTGREEN,
    "":         C_WHITE,
}
RISK_BADGE = {
    "Critical": (C_RED,   C_WHITE),
    "High":     (C_ORANGE, C_WHITE),
    "Medium":   (C_AMBER,  "#000000"),
    "Low":      (C_GREEN,  C_WHITE),
    "":         (C_GREY40, C_WHITE),
}
STATUS_COLORS = {
    "Yes – Fully Compliant":      C_LTGREEN,
    "Yes – Partially Compliant":  C_LTAMBER,
    "No – Non-Compliant":         C_LTRED,
    "N/A – Not Applicable":       C_GREY10,
}


def score_color(pct):
    if pct >= 75: return C_GREEN
    if pct >= 50: return C_ORANGE
    return C_RED


class AuditApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("GDPR · DUAA 2025 · ISO 27701  |  Compliance Audit Tool")
        self.geometry("1400x860")
        self.minsize(1100, 700)
        self.configure(bg=C_NAVY)

        self.state_obj = AuditState(DATA_DIR)
        self.current_q_idx = 0   # index into state_obj.questions
        self.filter_section = tk.IntVar(value=0)   # 0 = all
        self.filter_status  = tk.StringVar(value="All")
        self.search_var     = tk.StringVar()
        self.search_var.trace_add("write", self._on_search)

        self._build_ui()
        self._refresh_question_list()
        if self.state_obj.questions:
            self._select_question(0)
        self._update_dashboard()

    # ══════════════════════════════════════════════════════════════════════════
    # UI CONSTRUCTION
    # ══════════════════════════════════════════════════════════════════════════
    def _build_ui(self):
        self._build_topbar()
        main = tk.Frame(self, bg=C_NAVY)
        main.pack(fill=tk.BOTH, expand=True, padx=2, pady=2)
        main.columnconfigure(0, weight=0, minsize=310)
        main.columnconfigure(1, weight=1)
        main.rowconfigure(0, weight=1)

        self._build_left_panel(main)
        self._build_right_panel(main)

    # ── Top bar ───────────────────────────────────────────────────────────────
    def _build_topbar(self):
        bar = tk.Frame(self, bg=C_NAVY, height=56)
        bar.pack(fill=tk.X)
        bar.pack_propagate(False)

        tk.Label(bar, text="⚖", bg=C_NAVY, fg=C_LIGHTBLUE,
                 font=("Arial", 22)).pack(side=tk.LEFT, padx=(14,4), pady=8)
        title_frame = tk.Frame(bar, bg=C_NAVY)
        title_frame.pack(side=tk.LEFT, pady=6)
        tk.Label(title_frame, text="Data Protection Compliance Audit Tool",
                 bg=C_NAVY, fg=C_WHITE, font=("Arial", 14, "bold")).pack(anchor="w")
        tk.Label(title_frame, text="GDPR  ·  Data (Use and Access) Act 2025  ·  ISO/IEC 27701:2019",
                 bg=C_NAVY, fg=C_LIGHTBLUE, font=("Arial", 8)).pack(anchor="w")

        btn_frame = tk.Frame(bar, bg=C_NAVY)
        btn_frame.pack(side=tk.RIGHT, padx=12)
        for txt, cmd, bg in [
            ("💾 Save", self._save, C_MIDBLUE),
            ("📂 Load", self._load, C_MIDBLUE),
            ("📋 Exec Report", self._gen_exec, C_TEAL),
            ("📄 Detailed Report", self._gen_detail, C_TEAL),
            ("⚙ Settings", self._settings, C_GREY40),
        ]:
            tk.Button(btn_frame, text=txt, command=cmd, bg=bg, fg=C_WHITE,
                      font=("Arial", 9, "bold"), relief=tk.FLAT, padx=10, pady=5,
                      cursor="hand2", activebackground=C_MIDBLUE,
                      activeforeground=C_WHITE).pack(side=tk.LEFT, padx=3)

    # ── Left panel ────────────────────────────────────────────────────────────
    def _build_left_panel(self, parent):
        lf = tk.Frame(parent, bg=C_NAVY, width=310)
        lf.grid(row=0, column=0, sticky="nsew", padx=(0,2))
        lf.pack_propagate(False)

        # Dashboard card
        dash = tk.Frame(lf, bg=C_MIDBLUE, pady=8)
        dash.pack(fill=tk.X, pady=(0,2))
        self.lbl_org    = tk.Label(dash, text="Organisation: —", bg=C_MIDBLUE, fg=C_WHITE,
                                    font=("Arial", 9, "bold"), anchor="w")
        self.lbl_org.pack(fill=tk.X, padx=10)
        self.lbl_score  = tk.Label(dash, text="Overall Score: —", bg=C_MIDBLUE, fg=C_LIGHTBLUE,
                                    font=("Arial", 9), anchor="w")
        self.lbl_score.pack(fill=tk.X, padx=10)
        self.lbl_compl  = tk.Label(dash, text="Completion: 0%", bg=C_MIDBLUE, fg=C_LIGHTBLUE,
                                    font=("Arial", 9), anchor="w")
        self.lbl_compl.pack(fill=tk.X, padx=10)

        # Risk mini-badges
        rbf = tk.Frame(dash, bg=C_MIDBLUE)
        rbf.pack(fill=tk.X, padx=10, pady=(4,0))
        self.risk_badges = {}
        for risk, (bg, fg) in RISK_BADGE.items():
            if risk:
                f = tk.Frame(rbf, bg=bg, padx=4, pady=2)
                f.pack(side=tk.LEFT, padx=2)
                lbl = tk.Label(f, text=f"{risk}: 0", bg=bg, fg=fg, font=("Arial", 8, "bold"))
                lbl.pack()
                self.risk_badges[risk] = lbl

        # Filters
        ff = tk.Frame(lf, bg=C_NAVY, pady=4)
        ff.pack(fill=tk.X)
        tk.Label(ff, text="🔍 Search", bg=C_NAVY, fg=C_LIGHTBLUE,
                 font=("Arial", 8)).pack(anchor="w", padx=8)
        self.search_entry = tk.Entry(ff, textvariable=self.search_var, bg="#2A4070",
                                      fg=C_WHITE, insertbackground=C_WHITE,
                                      relief=tk.FLAT, font=("Arial", 9))
        self.search_entry.pack(fill=tk.X, padx=8, pady=(2,4))

        # Section filter
        sec_frame = tk.Frame(ff, bg=C_NAVY)
        sec_frame.pack(fill=tk.X, padx=8)
        tk.Label(sec_frame, text="Section:", bg=C_NAVY, fg=C_LIGHTBLUE,
                 font=("Arial", 8)).pack(side=tk.LEFT)
        sec_combo = ttk.Combobox(sec_frame, textvariable=self.filter_section,
                                  values=[0,1,2,3,4,5,6], width=4, state="readonly",
                                  font=("Arial", 9))
        sec_combo['values'] = ["All",1,2,3,4,5,6]
        sec_combo.set("All")
        sec_combo.pack(side=tk.LEFT, padx=4)
        sec_combo.bind("<<ComboboxSelected>>", lambda e: self._refresh_question_list())

        # Status filter
        tk.Label(sec_frame, text="Status:", bg=C_NAVY, fg=C_LIGHTBLUE,
                 font=("Arial", 8)).pack(side=tk.LEFT, padx=(8,0))
        self.status_combo = ttk.Combobox(sec_frame, textvariable=self.filter_status,
                                          values=["All","Not Answered","Non-Compliant",
                                                  "Partial","Compliant"], width=11,
                                          state="readonly", font=("Arial", 9))
        self.status_combo.set("All")
        self.status_combo.pack(side=tk.LEFT, padx=4)
        self.status_combo.bind("<<ComboboxSelected>>", lambda e: self._refresh_question_list())
        self.sec_combo_ref = sec_combo

        # Question listbox
        list_frame = tk.Frame(lf, bg=C_NAVY)
        list_frame.pack(fill=tk.BOTH, expand=True, padx=0)

        self.q_list = tk.Listbox(list_frame, bg="#1A3050", fg=C_WHITE,
                                   selectbackground=C_MIDBLUE,
                                   selectforeground=C_WHITE,
                                   font=("Arial", 8), relief=tk.FLAT,
                                   activestyle="none", bd=0,
                                   highlightthickness=0)
        sb = tk.Scrollbar(list_frame, orient=tk.VERTICAL, command=self.q_list.yview)
        self.q_list.configure(yscrollcommand=sb.set)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        self.q_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.q_list.bind("<<ListboxSelect>>", self._on_list_select)
        self._q_index_map = []  # maps listbox idx → question idx

    # ── Right panel ───────────────────────────────────────────────────────────
    def _build_right_panel(self, parent):
        rf = tk.Frame(parent, bg=C_GREY10)
        rf.grid(row=0, column=1, sticky="nsew")
        rf.rowconfigure(1, weight=1)
        rf.columnconfigure(0, weight=1)

        # Tab bar (Section tabs)
        tab_bar = tk.Frame(rf, bg=C_NAVY, height=36)
        tab_bar.grid(row=0, column=0, sticky="ew")
        tab_bar.pack_propagate(False)
        self.section_tabs = []
        tab_inner = tk.Frame(tab_bar, bg=C_NAVY)
        tab_inner.pack(side=tk.LEFT, padx=6, pady=4)
        for sid in range(0, 7):
            lbl = "All" if sid == 0 else f"S{sid}"
            btn = tk.Button(tab_inner, text=lbl, font=("Arial", 8, "bold"),
                            bg=C_NAVY if sid != 0 else C_MIDBLUE,
                            fg=C_LIGHTBLUE if sid != 0 else C_WHITE,
                            relief=tk.FLAT, padx=10, pady=4, cursor="hand2",
                            command=lambda s=sid: self._tab_click(s))
            btn.pack(side=tk.LEFT, padx=2)
            self.section_tabs.append(btn)

        # Main content area with notebook
        self.notebook = ttk.Notebook(rf)
        self.notebook.grid(row=1, column=0, sticky="nsew", padx=4, pady=4)
        style = ttk.Style()
        style.configure("TNotebook.Tab", font=("Arial", 9), padding=[10,4])

        # Tab 1: Question Detail
        self.q_frame = tk.Frame(self.notebook, bg=C_WHITE)
        self.notebook.add(self.q_frame, text="  Question Detail  ")
        self._build_question_detail(self.q_frame)

        # Tab 2: Dashboard
        self.dash_frame = tk.Frame(self.notebook, bg=C_WHITE)
        self.notebook.add(self.dash_frame, text="  Dashboard  ")
        self._build_dashboard(self.dash_frame)

    # ── Question detail tab ───────────────────────────────────────────────────
    def _build_question_detail(self, parent):
        parent.columnconfigure(0, weight=1)
        parent.rowconfigure(1, weight=1)

        # Header strip
        self.q_header = tk.Frame(parent, bg=C_NAVY, height=52)
        self.q_header.grid(row=0, column=0, sticky="ew")
        self.q_header.pack_propagate(False)
        self.lbl_q_num  = tk.Label(self.q_header, text="", bg=C_NAVY, fg=C_LIGHTBLUE,
                                    font=("Arial", 9, "bold"), anchor="w")
        self.lbl_q_num.pack(side=tk.LEFT, padx=12, pady=4)
        self.lbl_risk_badge = tk.Label(self.q_header, text="", bg=C_RED, fg=C_WHITE,
                                        font=("Arial", 8, "bold"), padx=8, pady=3)
        self.lbl_risk_badge.pack(side=tk.LEFT, padx=4)
        self.btn_prev = tk.Button(self.q_header, text="◀ Prev", command=self._prev_q,
                                   bg=C_MIDBLUE, fg=C_WHITE, font=("Arial", 8),
                                   relief=tk.FLAT, padx=8, cursor="hand2")
        self.btn_prev.pack(side=tk.RIGHT, padx=4, pady=8)
        self.btn_next = tk.Button(self.q_header, text="Next ▶", command=self._next_q,
                                   bg=C_MIDBLUE, fg=C_WHITE, font=("Arial", 8),
                                   relief=tk.FLAT, padx=8, cursor="hand2")
        self.btn_next.pack(side=tk.RIGHT, padx=4, pady=8)

        # Scrollable content
        canvas = tk.Canvas(parent, bg=C_WHITE, highlightthickness=0)
        canvas.grid(row=1, column=0, sticky="nsew")
        vsb = tk.Scrollbar(parent, orient=tk.VERTICAL, command=canvas.yview)
        vsb.grid(row=1, column=1, sticky="ns")
        canvas.configure(yscrollcommand=vsb.set)

        self.q_content = tk.Frame(canvas, bg=C_WHITE)
        self.q_content_id = canvas.create_window((0,0), window=self.q_content, anchor="nw")
        self.q_content.bind("<Configure>", lambda e: canvas.configure(
            scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda e: canvas.itemconfig(
            self.q_content_id, width=e.width))
        self._bind_mousewheel(canvas)
        self.q_canvas = canvas

        # Nav buttons
        nav = tk.Frame(parent, bg=C_GREY10, pady=6)
        nav.grid(row=2, column=0, columnspan=2, sticky="ew")
        tk.Button(nav, text="✓  Save Response & Next", command=self._save_and_next,
                   bg=C_GREEN, fg=C_WHITE, font=("Arial", 10, "bold"),
                   relief=tk.FLAT, padx=20, pady=6, cursor="hand2").pack(side=tk.LEFT, padx=12)
        tk.Button(nav, text="Clear Response", command=self._clear_response,
                   bg=C_GREY40, fg=C_WHITE, font=("Arial", 9),
                   relief=tk.FLAT, padx=12, pady=6, cursor="hand2").pack(side=tk.LEFT)
        self.lbl_saved = tk.Label(nav, text="", bg=C_GREY10, fg=C_GREEN,
                                   font=("Arial", 9, "bold"))
        self.lbl_saved.pack(side=tk.LEFT, padx=16)
        self.progress_lbl = tk.Label(nav, text="", bg=C_GREY10, fg=C_GREY40,
                                      font=("Arial", 9))
        self.progress_lbl.pack(side=tk.RIGHT, padx=16)

    def _bind_mousewheel(self, widget):
        def _on_mw(e):
            widget.yview_scroll(int(-1*(e.delta/120)), "units")
        widget.bind("<MouseWheel>", _on_mw)
        widget.bind("<Button-4>", lambda e: widget.yview_scroll(-1, "units"))
        widget.bind("<Button-5>", lambda e: widget.yview_scroll(1, "units"))

    def _build_field(self, parent, label, value, is_wide=True, bg=C_WHITE,
                     label_color=C_GREY40, value_font=("Arial", 9)):
        row = tk.Frame(parent, bg=bg)
        row.pack(fill=tk.X, pady=2, padx=12)
        tk.Label(row, text=label, bg=bg, fg=label_color,
                 font=("Arial", 8, "bold"), width=18, anchor="nw",
                 justify=tk.LEFT).pack(side=tk.LEFT, anchor="n", pady=2)
        vf = tk.Frame(row, bg=bg)
        vf.pack(side=tk.LEFT, fill=tk.X, expand=True)
        lbl = tk.Label(vf, text=value, bg=bg, fg="#111111",
                        font=value_font, wraplength=720, justify=tk.LEFT, anchor="nw")
        lbl.pack(anchor="nw")
        return row

    # ── Dashboard tab ─────────────────────────────────────────────────────────
    def _build_dashboard(self, parent):
        parent.columnconfigure(0, weight=1)
        parent.rowconfigure(1, weight=1)

        # Score row
        top = tk.Frame(parent, bg=C_GREY10, pady=10)
        top.pack(fill=tk.X)

        self.dash_score_lbl = tk.Label(top, text="—%", bg=C_GREY10, fg=C_NAVY,
                                        font=("Arial", 48, "bold"))
        self.dash_score_lbl.pack(side=tk.LEFT, padx=24)

        self.dash_rating_lbl = tk.Label(top, text="Overall Compliance Rating", bg=C_GREY10,
                                         fg=C_GREY40, font=("Arial", 13))
        self.dash_rating_lbl.pack(side=tk.LEFT)

        # Section scores
        sec_frame = tk.LabelFrame(parent, text="  Section Scores  ", bg=C_WHITE,
                                   fg=C_NAVY, font=("Arial", 10, "bold"), pady=8, padx=8)
        sec_frame.pack(fill=tk.X, padx=12, pady=8)
        self.dash_section_labels = {}
        for sid in range(1, 7):
            title = AuditState.SECTION_TITLES.get(sid, f"Section {sid}")
            row = tk.Frame(sec_frame, bg=C_WHITE)
            row.pack(fill=tk.X, pady=3)
            tk.Label(row, text=f"Section {sid}: {title}", bg=C_WHITE, fg=C_NAVY,
                     font=("Arial", 9), width=36, anchor="w").pack(side=tk.LEFT)
            bar_bg = tk.Frame(row, bg=C_GREY10, height=18, width=300)
            bar_bg.pack(side=tk.LEFT, padx=8)
            bar_bg.pack_propagate(False)
            bar_fill = tk.Frame(bar_bg, bg=C_GREY40, height=18)
            bar_fill.place(x=0, y=0, relheight=1, width=0)
            pct_lbl = tk.Label(row, text="0%", bg=C_WHITE, fg=C_GREY40,
                               font=("Arial", 9, "bold"), width=6)
            pct_lbl.pack(side=tk.LEFT)
            self.dash_section_labels[sid] = (bar_fill, pct_lbl, bar_bg)

        # Risk summary
        risk_frame = tk.LabelFrame(parent, text="  Non-Compliance by Risk Level  ",
                                    bg=C_WHITE, fg=C_NAVY, font=("Arial", 10, "bold"),
                                    pady=8, padx=8)
        risk_frame.pack(fill=tk.X, padx=12, pady=4)
        self.dash_risk_labels = {}
        risk_row = tk.Frame(risk_frame, bg=C_WHITE)
        risk_row.pack()
        for risk, (bg, fg) in [("Critical",(C_LTRED,C_RED)),
                                 ("High",(C_LTAMBER,C_ORANGE)),
                                 ("Medium",("#FFF9E6",C_AMBER)),
                                 ("Low",(C_LTGREEN,C_GREEN))]:
            card = tk.Frame(risk_row, bg=bg, padx=20, pady=12)
            card.pack(side=tk.LEFT, padx=8)
            tk.Label(card, text=risk, bg=bg, fg=fg,
                     font=("Arial", 9, "bold")).pack()
            num_lbl = tk.Label(card, text="0", bg=bg, fg=fg,
                               font=("Arial", 28, "bold"))
            num_lbl.pack()
            tk.Label(card, text="findings", bg=bg, fg=fg,
                     font=("Arial", 8)).pack()
            self.dash_risk_labels[risk] = num_lbl

    # ══════════════════════════════════════════════════════════════════════════
    # QUESTION DISPLAY
    # ══════════════════════════════════════════════════════════════════════════
    def _display_question(self, idx: int):
        q = self.state_obj.questions[idx]
        for w in self.q_content.winfo_children():
            w.destroy()

        bg = RISK_BG.get(q.risk, C_WHITE)

        # ── Question text block ───────────────────────────────────────────
        q_block = tk.Frame(self.q_content, bg=C_NAVY, pady=10)
        q_block.pack(fill=tk.X)
        tk.Label(q_block, text=f"S{q.section_id} / Q{q.number}  —  {q.subsection}",
                 bg=C_NAVY, fg=C_LIGHTBLUE, font=("Arial", 8)).pack(anchor="w", padx=14)
        tk.Label(q_block, text=q.question, bg=C_NAVY, fg=C_WHITE,
                 font=("Arial", 11, "bold"), wraplength=900, justify=tk.LEFT,
                 anchor="w").pack(anchor="w", padx=14, pady=(4,0))

        # ── Why this matters ─────────────────────────────────────────────
        if q.why:
            why_f = tk.Frame(self.q_content, bg=C_LIGHTBLUE, pady=8)
            why_f.pack(fill=tk.X)
            tk.Label(why_f, text="WHY THIS MATTERS", bg=C_LIGHTBLUE, fg=C_NAVY,
                     font=("Arial", 8, "bold")).pack(anchor="w", padx=14)
            tk.Label(why_f, text=q.why, bg=C_LIGHTBLUE, fg="#1F2F4F",
                     font=("Arial", 9), wraplength=900, justify=tk.LEFT,
                     anchor="w").pack(anchor="w", padx=14)

        # ── References ───────────────────────────────────────────────────
        ref_f = tk.Frame(self.q_content, bg=C_GREY10, pady=6)
        ref_f.pack(fill=tk.X)
        cols = tk.Frame(ref_f, bg=C_GREY10)
        cols.pack(fill=tk.X, padx=10)

        gdpr_f = tk.Frame(cols, bg=C_LIGHTBLUE, padx=8, pady=6)
        gdpr_f.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=4)
        tk.Label(gdpr_f, text="GDPR / DUAA 2025 Reference", bg=C_LIGHTBLUE,
                 fg=C_NAVY, font=("Arial", 8, "bold")).pack(anchor="w")
        tk.Label(gdpr_f, text=q.gdpr_ref, bg=C_LIGHTBLUE, fg=C_MIDBLUE,
                 font=("Arial", 8), wraplength=400, justify=tk.LEFT).pack(anchor="w")

        iso_f = tk.Frame(cols, bg="#E0F0F2", padx=8, pady=6)
        iso_f.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=4)
        tk.Label(iso_f, text="ISO 27701:2019 Clause", bg="#E0F0F2",
                 fg=C_TEAL, font=("Arial", 8, "bold")).pack(anchor="w")
        tk.Label(iso_f, text=q.iso_ref, bg="#E0F0F2", fg=C_TEAL,
                 font=("Arial", 8), wraplength=400, justify=tk.LEFT).pack(anchor="w")

        # ── Response ─────────────────────────────────────────────────────
        resp_f = tk.Frame(self.q_content, bg=C_WHITE, pady=12)
        resp_f.pack(fill=tk.X, padx=12)
        tk.Label(resp_f, text="COMPLIANCE RESPONSE", bg=C_WHITE, fg=C_NAVY,
                 font=("Arial", 9, "bold")).pack(anchor="w")

        self.response_var = tk.StringVar(value=q.response)
        rb_frame = tk.Frame(resp_f, bg=C_WHITE)
        rb_frame.pack(anchor="w", pady=4)
        resp_colors = {
            "Yes – Fully Compliant":     (C_LTGREEN, C_GREEN),
            "Yes – Partially Compliant": (C_LTAMBER, C_ORANGE),
            "No – Non-Compliant":        (C_LTRED,   C_RED),
            "N/A – Not Applicable":      (C_GREY10,  C_GREY40),
        }
        self._resp_radio_frames = {}
        for opt in RESPONSE_OPTIONS:
            ob, oc = resp_colors.get(opt, (C_WHITE, C_NAVY))
            rb_row = tk.Frame(rb_frame, bg=ob, padx=10, pady=6, cursor="hand2")
            rb_row.pack(fill=tk.X, pady=2)
            rb = tk.Radiobutton(rb_row, text=opt, variable=self.response_var,
                                 value=opt, bg=ob, fg=oc, activebackground=ob,
                                 activeforeground=oc, font=("Arial", 9, "bold"),
                                 selectcolor=ob, command=self._on_response_change)
            rb.pack(side=tk.LEFT)
            self._resp_radio_frames[opt] = rb_row

        # ── Findings ─────────────────────────────────────────────────────
        tk.Label(self.q_content, text="AUDITOR FINDINGS / NOTES",
                 bg=C_WHITE, fg=C_NAVY, font=("Arial", 9, "bold"),
                 anchor="w").pack(fill=tk.X, padx=12, pady=(8,2))
        self.findings_text = tk.Text(self.q_content, height=4, bg=C_GREY10,
                                      fg="#111111", font=("Arial", 9),
                                      relief=tk.FLAT, padx=8, pady=6,
                                      wrap=tk.WORD)
        self.findings_text.pack(fill=tk.X, padx=12)
        self.findings_text.insert("1.0", q.findings)

        # ── Evidence required ────────────────────────────────────────────
        ev_f = tk.LabelFrame(self.q_content, text="  Evidence Required  ",
                              bg=C_GREY10, fg=C_MIDBLUE, font=("Arial", 8, "bold"),
                              padx=10, pady=8)
        ev_f.pack(fill=tk.X, padx=12, pady=(8,4))
        tk.Label(ev_f, text=q.evidence_req, bg=C_GREY10, fg=C_GREY40,
                 font=("Arial", 8), wraplength=880, justify=tk.LEFT).pack(anchor="w")

        # ── Remediation ──────────────────────────────────────────────────
        rem_f = tk.LabelFrame(self.q_content, text="  Remediation Steps  ",
                               bg="#E0F0F2", fg=C_TEAL, font=("Arial", 8, "bold"),
                               padx=10, pady=8)
        rem_f.pack(fill=tk.X, padx=12, pady=(4,8))
        tk.Label(rem_f, text=q.remediation, bg="#E0F0F2", fg="#0A3840",
                 font=("Arial", 9), wraplength=880, justify=tk.LEFT).pack(anchor="w")

        # ── Tracking ─────────────────────────────────────────────────────
        track_f = tk.LabelFrame(self.q_content, text="  Tracking  ",
                                 bg=C_WHITE, fg=C_NAVY, font=("Arial", 8, "bold"),
                                 padx=10, pady=8)
        track_f.pack(fill=tk.X, padx=12, pady=(4,16))

        row1 = tk.Frame(track_f, bg=C_WHITE)
        row1.pack(fill=tk.X, pady=3)

        tk.Label(row1, text="Responsible Party:", bg=C_WHITE, fg=C_GREY40,
                 font=("Arial", 8, "bold"), width=18, anchor="w").pack(side=tk.LEFT)
        self.resp_party_var = tk.StringVar(value=q.responsible_party)
        tk.Entry(row1, textvariable=self.resp_party_var, bg=C_GREY10,
                 fg="#111111", font=("Arial", 9), relief=tk.FLAT,
                 width=30).pack(side=tk.LEFT, padx=4)

        tk.Label(row1, text="Target Date:", bg=C_WHITE, fg=C_GREY40,
                 font=("Arial", 8, "bold"), width=12, anchor="w").pack(side=tk.LEFT, padx=(20,0))
        self.target_date_var = tk.StringVar(value=q.target_date)
        tk.Entry(row1, textvariable=self.target_date_var, bg=C_GREY10,
                 fg="#111111", font=("Arial", 9), relief=tk.FLAT,
                 width=14).pack(side=tk.LEFT, padx=4)

        row2 = tk.Frame(track_f, bg=C_WHITE)
        row2.pack(fill=tk.X, pady=3)
        tk.Label(row2, text="Status:", bg=C_WHITE, fg=C_GREY40,
                 font=("Arial", 8, "bold"), width=18, anchor="w").pack(side=tk.LEFT)
        self.status_var = tk.StringVar(value=q.status or "Not Started")
        status_combo = ttk.Combobox(row2, textvariable=self.status_var,
                                     values=["Not Started","In Progress","Complete","N/A"],
                                     state="readonly", width=20, font=("Arial", 9))
        status_combo.pack(side=tk.LEFT, padx=4)

        # Update header
        self.lbl_q_num.configure(
            text=f"Section {q.section_id}  ·  Question {q.number}  ·  {q.subsection[:60]}")
        badge_bg, badge_fg = RISK_BADGE.get(q.risk, (C_GREY40, C_WHITE))
        self.lbl_risk_badge.configure(text=f"  {q.risk or '—'}  ", bg=badge_bg, fg=badge_fg)
        total = len(self.state_obj.questions)
        answered = len([x for x in self.state_obj.questions if x.response])
        self.progress_lbl.configure(
            text=f"Q {idx+1} of {total}  |  {answered}/{total} answered")
        self.q_canvas.yview_moveto(0)

    def _on_response_change(self):
        pass  # live update handled on save

    # ══════════════════════════════════════════════════════════════════════════
    # QUESTION LIST
    # ══════════════════════════════════════════════════════════════════════════
    def _get_filtered_indices(self):
        sec_val = self.sec_combo_ref.get()
        sec = None if sec_val == "All" else int(sec_val)
        status_f = self.status_combo.get()
        search = self.search_var.get().lower().strip()

        result = []
        for i, q in enumerate(self.state_obj.questions):
            if sec and q.section_id != sec:
                continue
            if status_f == "Not Answered" and q.response:
                continue
            if status_f == "Non-Compliant" and not q.is_non_compliant:
                continue
            if status_f == "Partial" and not q.is_partial:
                continue
            if status_f == "Compliant" and not q.is_compliant:
                continue
            if search and search not in q.question.lower() and search not in q.subsection.lower():
                continue
            result.append(i)
        return result

    def _refresh_question_list(self):
        self.q_list.delete(0, tk.END)
        self._q_index_map = []
        indices = self._get_filtered_indices()
        for i in indices:
            q = self.state_obj.questions[i]
            status_icon = {
                "Yes – Fully Compliant":     "✓",
                "Yes – Partially Compliant": "◑",
                "No – Non-Compliant":        "✗",
                "N/A – Not Applicable":      "–",
            }.get(q.response, "○")
            label = f" {status_icon} S{q.section_id}/Q{q.number:02d}  {q.question[:52]}"
            self.q_list.insert(tk.END, label)
            bg = STATUS_COLORS.get(q.response, "#1A3050")
            self.q_list.itemconfig(tk.END, {'bg': bg,
                                             'fg': "#000000" if q.response else C_WHITE})
            self._q_index_map.append(i)

    def _on_list_select(self, event):
        sel = self.q_list.curselection()
        if not sel:
            return
        li = sel[0]
        qi = self._q_index_map[li]
        self._save_current()
        self.current_q_idx = qi
        self._display_question(qi)
        self.notebook.select(0)

    def _select_question(self, qi: int):
        self.current_q_idx = qi
        self._display_question(qi)
        # highlight in list
        for li, mapped in enumerate(self._q_index_map):
            if mapped == qi:
                self.q_list.selection_clear(0, tk.END)
                self.q_list.selection_set(li)
                self.q_list.see(li)
                break

    def _tab_click(self, sid: int):
        self.sec_combo_ref.set("All" if sid == 0 else str(sid))
        for i, btn in enumerate(self.section_tabs):
            btn.configure(bg=C_MIDBLUE if i == sid else C_NAVY,
                          fg=C_WHITE if i == sid else C_LIGHTBLUE)
        self._refresh_question_list()

    def _on_search(self, *_):
        self._refresh_question_list()

    # ══════════════════════════════════════════════════════════════════════════
    # NAVIGATION & SAVE
    # ══════════════════════════════════════════════════════════════════════════
    def _save_current(self):
        if not self.state_obj.questions:
            return
        q = self.state_obj.questions[self.current_q_idx]
        try:
            q.response          = self.response_var.get()
            q.findings          = self.findings_text.get("1.0", tk.END).strip()
            q.responsible_party = self.resp_party_var.get().strip()
            q.target_date       = self.target_date_var.get().strip()
            q.status            = self.status_var.get()
        except Exception:
            pass

    def _save_and_next(self):
        self._save_current()
        self._refresh_question_list()
        self._update_dashboard()
        self.lbl_saved.configure(text="✓ Saved")
        self.after(1800, lambda: self.lbl_saved.configure(text=""))
        self._next_q()

    def _next_q(self):
        self._save_current()
        indices = self._get_filtered_indices()
        if not indices:
            return
        try:
            pos = indices.index(self.current_q_idx)
            new_pos = min(pos + 1, len(indices) - 1)
        except ValueError:
            new_pos = 0
        self._select_question(indices[new_pos])
        self._refresh_question_list()

    def _prev_q(self):
        self._save_current()
        indices = self._get_filtered_indices()
        if not indices:
            return
        try:
            pos = indices.index(self.current_q_idx)
            new_pos = max(pos - 1, 0)
        except ValueError:
            new_pos = 0
        self._select_question(indices[new_pos])
        self._refresh_question_list()

    def _clear_response(self):
        self.response_var.set("")
        self.findings_text.delete("1.0", tk.END)

    # ══════════════════════════════════════════════════════════════════════════
    # DASHBOARD
    # ══════════════════════════════════════════════════════════════════════════
    def _update_dashboard(self):
        self._save_current()
        overall = self.state_obj.overall_score()
        pct = overall['pct']
        sc  = score_color(pct)

        # Left panel
        self.lbl_org.configure(text=f"Organisation: {self.state_obj.org_name or '(not set)'}")
        self.lbl_score.configure(text=f"Overall Score: {pct}%  —  "
                                       f"{'Satisfactory' if pct>=75 else 'Requires Improvement' if pct>=50 else 'Significant Gaps'}")
        self.lbl_compl.configure(text=f"Completion: {self.state_obj.completion_pct()}%")

        rs = self.state_obj.risk_summary()
        for risk, lbl in self.risk_badges.items():
            lbl.configure(text=f"{risk}: {rs.get(risk,0)}")

        # Dashboard tab
        self.dash_score_lbl.configure(text=f"{pct}%", fg=sc)
        label = "Satisfactory" if pct>=75 else "Requires Improvement" if pct>=50 else "Significant Gaps"
        self.dash_rating_lbl.configure(text=f"Overall Compliance Rating  —  {label}", fg=sc)

        for sid in range(1, 7):
            sc_s = self.state_obj.score_section(sid)
            sp   = sc_s['pct']
            bar_fill, pct_lbl, bar_bg = self.dash_section_labels[sid]
            bar_bg.update_idletasks()
            bar_w = bar_bg.winfo_width() or 300
            fill_w = int(bar_w * sp / 100)
            bar_fill.place(x=0, y=0, relheight=1, width=fill_w)
            bar_fill.configure(bg=score_color(sp))
            pct_lbl.configure(text=f"{sp}%", fg=score_color(sp))

        for risk, num_lbl in self.dash_risk_labels.items():
            num_lbl.configure(text=str(rs.get(risk, 0)))

    # ══════════════════════════════════════════════════════════════════════════
    # FILE OPERATIONS
    # ══════════════════════════════════════════════════════════════════════════
    def _save(self):
        self._save_current()
        path = filedialog.asksaveasfilename(
            defaultextension=".json",
            filetypes=[("Audit files", "*.json"), ("All", "*.*")],
            initialdir=SAVES_DIR,
            title="Save Audit Progress")
        if path:
            self.state_obj.save(path)
            messagebox.showinfo("Saved", f"Audit saved to:\n{path}")

    def _load(self):
        path = filedialog.askopenfilename(
            filetypes=[("Audit files", "*.json"), ("All", "*.*")],
            initialdir=SAVES_DIR,
            title="Load Audit Progress")
        if path:
            self.state_obj.load(path)
            self._refresh_question_list()
            if self.state_obj.questions:
                self._select_question(0)
            self._update_dashboard()
            messagebox.showinfo("Loaded", "Audit progress loaded successfully.")

    # ══════════════════════════════════════════════════════════════════════════
    # SETTINGS
    # ══════════════════════════════════════════════════════════════════════════
    def _settings(self):
        win = tk.Toplevel(self)
        win.title("Audit Settings")
        win.geometry("480x320")
        win.configure(bg=C_WHITE)
        win.grab_set()

        tk.Label(win, text="Audit Settings", bg=C_WHITE, fg=C_NAVY,
                 font=("Arial", 13, "bold")).pack(pady=16)

        fields = [
            ("Organisation Name:", "org_name"),
            ("Lead Auditor:",      "auditor"),
            ("Audit Date:",        "audit_date"),
            ("Audit Reference:",   "audit_ref"),
        ]
        vars_ = {}
        for label, attr in fields:
            row = tk.Frame(win, bg=C_WHITE)
            row.pack(fill=tk.X, padx=30, pady=5)
            tk.Label(row, text=label, bg=C_WHITE, fg=C_GREY40,
                     font=("Arial", 9, "bold"), width=20, anchor="w").pack(side=tk.LEFT)
            var = tk.StringVar(value=getattr(self.state_obj, attr))
            tk.Entry(row, textvariable=var, bg=C_GREY10, fg="#111111",
                     font=("Arial", 9), relief=tk.FLAT, width=28).pack(side=tk.LEFT)
            vars_[attr] = var

        def apply():
            for attr, var in vars_.items():
                setattr(self.state_obj, attr, var.get().strip())
            self._update_dashboard()
            win.destroy()

        tk.Button(win, text="Apply & Close", command=apply, bg=C_MIDBLUE, fg=C_WHITE,
                   font=("Arial", 10, "bold"), relief=tk.FLAT, padx=20, pady=6).pack(pady=16)

    # ══════════════════════════════════════════════════════════════════════════
    # REPORT GENERATION
    # ══════════════════════════════════════════════════════════════════════════
    def _gen_exec(self):
        self._save_current()
        self._update_dashboard()
        if not self.state_obj.org_name:
            if not messagebox.askyesno("Settings",
                "Organisation name is not set. Generate report anyway?"):
                return
        path = filedialog.asksaveasfilename(
            defaultextension=".pdf",
            filetypes=[("PDF files", "*.pdf")],
            initialfile=f"Executive_Report_{datetime.now().strftime('%Y%m%d')}.pdf",
            title="Save Executive Report")
        if not path:
            return
        self._run_in_thread(build_executive_report, path, "Executive Report")

    def _gen_detail(self):
        self._save_current()
        self._update_dashboard()
        path = filedialog.asksaveasfilename(
            defaultextension=".pdf",
            filetypes=[("PDF files", "*.pdf")],
            initialfile=f"Detailed_Report_{datetime.now().strftime('%Y%m%d')}.pdf",
            title="Save Detailed Report")
        if not path:
            return
        self._run_in_thread(build_detailed_report, path, "Detailed Report")

    def _run_in_thread(self, build_fn, path, label):
        prog_win = tk.Toplevel(self)
        prog_win.title("Generating Report…")
        prog_win.geometry("360x100")
        prog_win.configure(bg=C_WHITE)
        prog_win.grab_set()
        tk.Label(prog_win, text=f"Generating {label}…",
                 bg=C_WHITE, fg=C_NAVY, font=("Arial", 10)).pack(pady=10)
        pb = ttk.Progressbar(prog_win, mode="indeterminate", length=300)
        pb.pack(pady=6)
        pb.start(12)

        def worker():
            try:
                build_fn(self.state_obj, path)
                self.after(0, lambda: [prog_win.destroy(),
                    messagebox.showinfo("Report Ready",
                        f"{label} saved to:\n{path}\n\nOpen the PDF to view it.")])
            except Exception as e:
                self.after(0, lambda: [prog_win.destroy(),
                    messagebox.showerror("Error", f"Report generation failed:\n{e}")])

        threading.Thread(target=worker, daemon=True).start()


if __name__ == "__main__":
    app = AuditApp()
    app.mainloop()
