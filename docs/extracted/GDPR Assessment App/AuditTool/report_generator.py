"""
report_generator.py  –  Generates formal PDF reports (detailed & executive).
Uses ReportLab Platypus for professional layout.
"""

import os
from datetime import datetime
from typing import List, Optional

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm, mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_RIGHT, TA_JUSTIFY
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    PageBreak, HRFlowable, KeepTogether
)
from reportlab.platypus import BaseDocTemplate, Frame, PageTemplate
from reportlab.lib.units import inch

# ── Brand colours ──────────────────────────────────────────────────────────
NAVY      = colors.HexColor("#1F3864")
MIDBLUE   = colors.HexColor("#2E5FA3")
TEAL      = colors.HexColor("#1F6B75")
LIGHTBLUE = colors.HexColor("#DEEAF1")
RED       = colors.HexColor("#C00000")
ORANGE    = colors.HexColor("#E26B0A")
AMBER     = colors.HexColor("#FFBF00")
GREEN     = colors.HexColor("#375623")
LTGREEN   = colors.HexColor("#E2EFDA")
LTRED     = colors.HexColor("#FCE4E4")
LTAMBER   = colors.HexColor("#FFF3CD")
GREY10    = colors.HexColor("#F2F2F2")
GREY40    = colors.HexColor("#595959")
WHITE     = colors.white
BLACK     = colors.black

RISK_COLOR = {
    "Critical": RED,
    "High":     ORANGE,
    "Medium":   AMBER,
    "Low":      colors.HexColor("#70AD47"),
}
RISK_TEXT_COLOR = {
    "Critical": WHITE,
    "High":     WHITE,
    "Medium":   BLACK,
    "Low":      WHITE,
}
RISK_BG = {
    "Critical": colors.HexColor("#FCE4E4"),
    "High":     colors.HexColor("#FEF0E7"),
    "Medium":   colors.HexColor("#FFF9E6"),
    "Low":      colors.HexColor("#EDF7E5"),
}

PAGE_W, PAGE_H = A4
MARGIN = 2*cm

# ── Style factory ──────────────────────────────────────────────────────────
def make_styles():
    base = getSampleStyleSheet()
    s = {}

    s['cover_org'] = ParagraphStyle('cover_org', fontName='Helvetica-Bold',
        fontSize=22, textColor=WHITE, alignment=TA_LEFT, leading=28)
    s['cover_title'] = ParagraphStyle('cover_title', fontName='Helvetica',
        fontSize=14, textColor=colors.HexColor("#BDD7EE"), alignment=TA_LEFT, leading=20)
    s['cover_meta'] = ParagraphStyle('cover_meta', fontName='Helvetica',
        fontSize=10, textColor=WHITE, alignment=TA_LEFT, leading=16, spaceBefore=4)

    s['h1'] = ParagraphStyle('h1', fontName='Helvetica-Bold',
        fontSize=16, textColor=NAVY, spaceAfter=6, spaceBefore=14,
        borderPad=(0,0,4,0))
    s['h2'] = ParagraphStyle('h2', fontName='Helvetica-Bold',
        fontSize=12, textColor=MIDBLUE, spaceAfter=4, spaceBefore=10)
    s['h3'] = ParagraphStyle('h3', fontName='Helvetica-Bold',
        fontSize=10, textColor=NAVY, spaceAfter=3, spaceBefore=8)
    s['body'] = ParagraphStyle('body', fontName='Helvetica',
        fontSize=9, textColor=BLACK, leading=13, spaceAfter=4, alignment=TA_JUSTIFY)
    s['body_small'] = ParagraphStyle('body_small', fontName='Helvetica',
        fontSize=8, textColor=GREY40, leading=11, spaceAfter=3)
    s['bullet'] = ParagraphStyle('bullet', fontName='Helvetica',
        fontSize=9, textColor=BLACK, leading=13, spaceAfter=2,
        leftIndent=14, bulletIndent=4)
    s['label'] = ParagraphStyle('label', fontName='Helvetica-Bold',
        fontSize=8, textColor=GREY40, spaceAfter=1)
    s['value'] = ParagraphStyle('value', fontName='Helvetica',
        fontSize=9, textColor=BLACK, leading=12, spaceAfter=6)
    s['toc_section'] = ParagraphStyle('toc_section', fontName='Helvetica-Bold',
        fontSize=10, textColor=NAVY, spaceAfter=2, spaceBefore=4)
    s['toc_item'] = ParagraphStyle('toc_item', fontName='Helvetica',
        fontSize=9, textColor=BLACK, spaceAfter=1, leftIndent=12)
    s['footer'] = ParagraphStyle('footer', fontName='Helvetica',
        fontSize=7, textColor=colors.HexColor("#999999"), alignment=TA_CENTER)
    s['remediation_hdr'] = ParagraphStyle('remediation_hdr', fontName='Helvetica-Bold',
        fontSize=9, textColor=TEAL, spaceAfter=2)
    s['finding_q'] = ParagraphStyle('finding_q', fontName='Helvetica-Bold',
        fontSize=9, textColor=NAVY, spaceAfter=3, leading=13)
    s['risk_badge'] = ParagraphStyle('risk_badge', fontName='Helvetica-Bold',
        fontSize=8, textColor=WHITE, alignment=TA_CENTER)
    s['exec_stat_label'] = ParagraphStyle('exec_stat_label', fontName='Helvetica',
        fontSize=9, textColor=GREY40, alignment=TA_CENTER, spaceAfter=2)
    s['exec_stat_val'] = ParagraphStyle('exec_stat_val', fontName='Helvetica-Bold',
        fontSize=26, textColor=NAVY, alignment=TA_CENTER)
    return s


# ── Page templates ──────────────────────────────────────────────────────────
class HeaderFooterDocTemplate(BaseDocTemplate):
    def __init__(self, filename, org_name="", report_type="", audit_ref="", **kwargs):
        self.org_name    = org_name
        self.report_type = report_type
        self.audit_ref   = audit_ref
        super().__init__(filename, **kwargs)
        frame = Frame(MARGIN, MARGIN + 1.2*cm, PAGE_W - 2*MARGIN,
                      PAGE_H - 2*MARGIN - 2.4*cm, id='main')
        template = PageTemplate(id='main', frames=[frame],
                                onPage=self._draw_header_footer)
        self.addPageTemplates([template])

    def _draw_header_footer(self, canvas, doc):
        canvas.saveState()
        # Header bar
        canvas.setFillColor(NAVY)
        canvas.rect(0, PAGE_H - 1.4*cm, PAGE_W, 1.4*cm, fill=1, stroke=0)
        canvas.setFont("Helvetica-Bold", 8)
        canvas.setFillColor(WHITE)
        canvas.drawString(MARGIN, PAGE_H - 0.85*cm, self.org_name)
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(colors.HexColor("#BDD7EE"))
        canvas.drawRightString(PAGE_W - MARGIN, PAGE_H - 0.85*cm,
                               f"GDPR · DUAA 2025 · ISO 27701:2019  |  {self.report_type}")
        # Footer bar
        canvas.setFillColor(GREY10)
        canvas.rect(0, 0, PAGE_W, 1.2*cm, fill=1, stroke=0)
        canvas.setFillColor(MIDBLUE)
        canvas.rect(0, 1.1*cm, PAGE_W, 0.1*cm, fill=1, stroke=0)
        canvas.setFont("Helvetica", 7)
        canvas.setFillColor(GREY40)
        canvas.drawString(MARGIN, 0.42*cm,
                          f"Ref: {self.audit_ref}  |  CONFIDENTIAL – PRIVILEGED LEGAL DOCUMENT")
        canvas.drawRightString(PAGE_W - MARGIN, 0.42*cm,
                               f"Page {doc.page}")
        canvas.restoreState()


# ── Helpers ────────────────────────────────────────────────────────────────
def risk_pill(risk: str, styles: dict) -> Table:
    rc = RISK_COLOR.get(risk, colors.grey)
    rtc = RISK_TEXT_COLOR.get(risk, WHITE)
    t = Table([[Paragraph(risk or "—", ParagraphStyle('rp',
               fontName='Helvetica-Bold', fontSize=7.5,
               textColor=rtc, alignment=TA_CENTER))]],
              colWidths=[2.2*cm], rowHeights=[0.5*cm])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), rc),
        ('ROUNDEDCORNERS', [3]),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ]))
    return t


def hr(color=MIDBLUE, thickness=0.5):
    return HRFlowable(width="100%", thickness=thickness,
                      color=color, spaceAfter=6, spaceBefore=2)


def section_bar(title: str) -> Table:
    t = Table([[Paragraph(title, ParagraphStyle('sb', fontName='Helvetica-Bold',
               fontSize=11, textColor=WHITE))]],
              colWidths=[PAGE_W - 2*MARGIN], rowHeights=[0.75*cm])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), MIDBLUE),
        ('LEFTPADDING', (0,0), (-1,-1), 10),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ]))
    return t


def score_color(pct: int) -> colors.Color:
    if pct >= 75: return GREEN
    if pct >= 50: return ORANGE
    return RED


def score_label(pct: int) -> str:
    if pct >= 75: return "SATISFACTORY"
    if pct >= 50: return "REQUIRES IMPROVEMENT"
    return "SIGNIFICANT GAPS IDENTIFIED"


# ══════════════════════════════════════════════════════════════════════════════
# EXECUTIVE REPORT
# ══════════════════════════════════════════════════════════════════════════════
def build_executive_report(state, output_path: str):
    styles = make_styles()
    doc = HeaderFooterDocTemplate(
        output_path,
        org_name   = state.org_name or "Organisation",
        report_type= "EXECUTIVE SUMMARY",
        audit_ref  = state.audit_ref or "AUDIT-001",
        pagesize   = A4,
        topMargin  = MARGIN + 1.4*cm,
        bottomMargin = MARGIN + 1.2*cm,
        leftMargin = MARGIN, rightMargin = MARGIN,
    )
    story = []
    overall = state.overall_score()
    rs      = state.risk_summary()
    compl   = state.completion_pct()

    # ── COVER PAGE ────────────────────────────────────────────────────────
    story.append(Spacer(1, 1.5*cm))
    # Blue title block
    cover_data = [[
        Paragraph(f"{state.org_name or 'Organisation'}", styles['cover_org']),
    ],[
        Paragraph("DATA PROTECTION COMPLIANCE AUDIT", styles['cover_title']),
    ],[
        Paragraph("EXECUTIVE SUMMARY REPORT", ParagraphStyle('cs2',
            fontName='Helvetica', fontSize=11,
            textColor=colors.HexColor("#BDD7EE"), alignment=TA_LEFT)),
    ]]
    ct = Table(cover_data, colWidths=[PAGE_W - 2*MARGIN])
    ct.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), NAVY),
        ('TOPPADDING', (0,0), (-1,-1), 10),
        ('BOTTOMPADDING', (0,0), (-1,-1), 10),
        ('LEFTPADDING', (0,0), (-1,-1), 16),
    ]))
    story.append(ct)
    story.append(Spacer(1, 0.4*cm))

    meta = [
        ["Audit Reference:", state.audit_ref or "—",  "Audit Date:", state.audit_date or "—"],
        ["Auditor / Lead:",  state.auditor or "—",     "Framework:",  "GDPR · DUAA 2025 · ISO 27701:2019"],
        ["Completion:",      f"{compl}% of questions answered", "Classification:", "CONFIDENTIAL"],
    ]
    mt = Table(meta, colWidths=[3.5*cm, 6.5*cm, 3.5*cm, 5.5*cm])
    mt.setStyle(TableStyle([
        ('FONTNAME', (0,0), (0,-1), 'Helvetica-Bold'),
        ('FONTNAME', (2,0), (2,-1), 'Helvetica-Bold'),
        ('FONTSIZE', (0,0), (-1,-1), 8.5),
        ('TEXTCOLOR', (0,0), (0,-1), GREY40),
        ('TEXTCOLOR', (2,0), (2,-1), GREY40),
        ('GRID', (0,0), (-1,-1), 0.3, colors.HexColor("#CCCCCC")),
        ('BACKGROUND', (0,0), (0,-1), GREY10),
        ('BACKGROUND', (2,0), (2,-1), GREY10),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('TOPPADDING', (0,0), (-1,-1), 5),
        ('BOTTOMPADDING', (0,0), (-1,-1), 5),
        ('LEFTPADDING', (0,0), (-1,-1), 8),
    ]))
    story.append(mt)
    story.append(Spacer(1, 0.6*cm))

    # ── OVERALL COMPLIANCE SCORE ──────────────────────────────────────────
    story.append(Paragraph("1.  OVERALL COMPLIANCE SCORE", styles['h1']))
    story.append(hr())

    sc = overall['pct']
    sc_color = score_color(sc)
    sc_label = score_label(sc)

    score_row = [
        [Paragraph(f"{sc}%", ParagraphStyle('pct', fontName='Helvetica-Bold',
                   fontSize=48, textColor=sc_color, alignment=TA_CENTER)),
         Paragraph(sc_label, ParagraphStyle('lbl', fontName='Helvetica-Bold',
                   fontSize=13, textColor=sc_color, alignment=TA_LEFT,
                   leading=18))],
    ]
    st = Table(score_row, colWidths=[5*cm, 13.5*cm], rowHeights=[2.5*cm])
    st.setStyle(TableStyle([
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('BACKGROUND', (0,0), (-1,-1), GREY10),
        ('BOX', (0,0), (-1,-1), 0.5, MIDBLUE),
        ('LINEAFTER', (0,0), (0,-1), 1, MIDBLUE),
    ]))
    story.append(st)
    story.append(Spacer(1, 0.3*cm))
    story.append(Paragraph(
        f"This score is calculated across {len([q for q in state.questions if q.response and not q.is_na])} "
        f"answered questions out of {len(state.questions)} total audit questions. A score of 100% "
        f"indicates full compliance across all assessed controls. Partially compliant responses "
        f"contribute 50% of the available points for that control.",
        styles['body']))

    # ── RISK SUMMARY ──────────────────────────────────────────────────────
    story.append(Spacer(1, 0.5*cm))
    story.append(Paragraph("2.  NON-COMPLIANCE RISK SUMMARY", styles['h1']))
    story.append(hr())

    risk_header = [
        Paragraph("Risk Level", ParagraphStyle('rh', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Non-Compliant\nFindings", ParagraphStyle('rh', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Description", ParagraphStyle('rh', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Required Action", ParagraphStyle('rh', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
    ]
    risk_desc = {
        "Critical": ("Requires IMMEDIATE action. Represents a direct and material breach of GDPR, "
                     "DUAA 2025, or ISO 27701 obligations, exposing the organisation to regulatory "
                     "sanction, significant fines, and reputational damage.", "Immediate — within 5 business days"),
        "High":     ("Represents a serious compliance gap requiring urgent remediation. "
                     "Failure to address within 30 days materially increases regulatory risk.", "Within 30 days"),
        "Medium":   ("Represents a compliance weakness that should be addressed as part of a "
                     "structured remediation programme.", "Within 90 days"),
        "Low":      ("Represents a best-practice improvement opportunity. "
                     "Should be addressed in the next scheduled review cycle.", "Within 6 months"),
    }
    risk_rows = [risk_header]
    for level in ("Critical", "High", "Medium", "Low"):
        count = rs.get(level, 0)
        desc, action = risk_desc[level]
        risk_rows.append([
            Paragraph(level, ParagraphStyle('rl', fontName='Helvetica-Bold',
                      fontSize=9, textColor=RISK_TEXT_COLOR.get(level, WHITE), alignment=TA_CENTER)),
            Paragraph(str(count), ParagraphStyle('rc', fontName='Helvetica-Bold',
                      fontSize=18, textColor=RISK_COLOR.get(level, BLACK), alignment=TA_CENTER)),
            Paragraph(desc, styles['body_small']),
            Paragraph(action, ParagraphStyle('ra', fontName='Helvetica-Bold',
                      fontSize=8.5, textColor=RISK_COLOR.get(level, BLACK))),
        ])
    rt = Table(risk_rows, colWidths=[2.5*cm, 2.5*cm, 10*cm, 3.5*cm])
    rt.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,0), NAVY),
        ('BACKGROUND', (0,1), (1,1), RISK_BG.get("Critical", WHITE)),
        ('BACKGROUND', (0,2), (1,2), RISK_BG.get("High", WHITE)),
        ('BACKGROUND', (0,3), (1,3), RISK_BG.get("Medium", WHITE)),
        ('BACKGROUND', (0,4), (1,4), RISK_BG.get("Low", WHITE)),
        ('BACKGROUND', (0,1), (0,1), RISK_COLOR.get("Critical", RED)),
        ('BACKGROUND', (0,2), (0,2), RISK_COLOR.get("High", ORANGE)),
        ('BACKGROUND', (0,3), (0,3), RISK_COLOR.get("Medium", AMBER)),
        ('BACKGROUND', (0,4), (0,4), RISK_COLOR.get("Low", GREEN)),
        ('GRID', (0,0), (-1,-1), 0.4, colors.HexColor("#CCCCCC")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('ALIGN', (0,0), (1,-1), 'CENTER'),
        ('TOPPADDING', (0,0), (-1,-1), 7),
        ('BOTTOMPADDING', (0,0), (-1,-1), 7),
        ('LEFTPADDING', (2,0), (2,-1), 8),
    ]))
    story.append(rt)

    # ── SECTION SCORECARD ────────────────────────────────────────────────
    story.append(Spacer(1, 0.5*cm))
    story.append(Paragraph("3.  SECTION-BY-SECTION SCORECARD", styles['h1']))
    story.append(hr())

    sc_header = [
        Paragraph("Section", ParagraphStyle('sch', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE)),
        Paragraph("Score", ParagraphStyle('sch', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Rating", ParagraphStyle('sch', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Critical Gaps", ParagraphStyle('sch', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Status", ParagraphStyle('sch', fontName='Helvetica-Bold',
                  fontSize=9, textColor=WHITE, alignment=TA_CENTER)),
    ]
    sc_rows = [sc_header]
    tss = TableStyle([
        ('BACKGROUND', (0,0), (-1,0), NAVY),
        ('GRID', (0,0), (-1,-1), 0.4, colors.HexColor("#CCCCCC")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('TOPPADDING', (0,0), (-1,-1), 6),
        ('BOTTOMPADDING', (0,0), (-1,-1), 6),
    ])
    for sid in range(1, 7):
        title = state.SECTION_TITLES.get(sid, f"Section {sid}")
        sc_s  = state.score_section(sid)
        pct   = sc_s['pct']
        crits = len([q for q in state.by_section(sid)
                     if q.is_non_compliant and q.risk == "Critical"])
        row_bg = GREY10 if sid % 2 == 0 else WHITE
        lbl = score_label(pct)
        lbl_color = score_color(pct)
        sc_rows.append([
            Paragraph(f"Section {sid}: {title}", styles['body']),
            Paragraph(f"{pct}%", ParagraphStyle('pct', fontName='Helvetica-Bold',
                      fontSize=11, textColor=score_color(pct), alignment=TA_CENTER)),
            Paragraph(lbl, ParagraphStyle('lbl2', fontName='Helvetica',
                      fontSize=8, textColor=lbl_color, alignment=TA_CENTER)),
            Paragraph(str(crits) if crits else "—",
                      ParagraphStyle('cg', fontName='Helvetica-Bold', fontSize=10,
                      textColor=RED if crits else GREEN, alignment=TA_CENTER)),
            Paragraph("Complete" if sc_s['total'] > 0 else "Pending",
                      ParagraphStyle('st', fontName='Helvetica', fontSize=8,
                      textColor=GREY40, alignment=TA_CENTER)),
        ])
        tss.add('BACKGROUND', (0, sid), (-1, sid), row_bg)

    sct = Table(sc_rows, colWidths=[7.5*cm, 2*cm, 5*cm, 2.5*cm, 1.5*cm])
    sct.setStyle(tss)
    story.append(sct)

    # ── CRITICAL FINDINGS ─────────────────────────────────────────────────
    crits = state.critical_gaps()
    story.append(PageBreak())
    story.append(Paragraph("4.  CRITICAL FINDINGS REQUIRING IMMEDIATE ACTION", styles['h1']))
    story.append(hr(RED))
    if not crits:
        story.append(Paragraph(
            "No Critical non-compliance findings were identified during this audit. "
            "This is a positive outcome; however, High-risk gaps identified in subsequent sections "
            "must be addressed within the required timeframes.",
            styles['body']))
    else:
        story.append(Paragraph(
            f"The following {len(crits)} Critical findings require IMMEDIATE attention. "
            "Each represents a direct and material breach risk under GDPR, the Data (Use and Access) "
            "Act 2025, or ISO/IEC 27701:2019. The organisation's senior leadership must be briefed "
            "on these findings and a remediation plan must be initiated without delay.",
            styles['body']))
        story.append(Spacer(1, 0.3*cm))
        for i, q in enumerate(crits, 1):
            block = [
                [Paragraph(f"CRITICAL FINDING #{i}", ParagraphStyle('cff', fontName='Helvetica-Bold',
                           fontSize=9, textColor=WHITE)),
                 Paragraph(f"S{q.section_id} / Q{q.number}  |  {state.SECTION_TITLES.get(q.section_id,'')}",
                           ParagraphStyle('cfs', fontName='Helvetica', fontSize=8, textColor=colors.HexColor("#BDD7EE")))],
            ]
            bt = Table(block, colWidths=[5*cm, PAGE_W - 2*MARGIN - 5*cm])
            bt.setStyle(TableStyle([
                ('BACKGROUND', (0,0), (-1,-1), RED),
                ('TOPPADDING', (0,0), (-1,-1), 6),
                ('BOTTOMPADDING', (0,0), (-1,-1), 6),
                ('LEFTPADDING', (0,0), (-1,-1), 10),
                ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
            ]))
            detail_rows = [
                [Paragraph("Audit Question:", styles['label']),
                 Paragraph(q.question, styles['finding_q'])],
                [Paragraph("Regulatory Exposure:", styles['label']),
                 Paragraph(q.gdpr_ref, styles['body_small'])],
                [Paragraph("ISO 27701 Clause:", styles['label']),
                 Paragraph(q.iso_ref, styles['body_small'])],
                [Paragraph("Required Remediation:", styles['label']),
                 Paragraph(q.remediation, ParagraphStyle('rem', fontName='Helvetica',
                           fontSize=9, textColor=BLACK, leading=13))],
            ]
            if q.findings:
                detail_rows.insert(2, [Paragraph("Auditor Findings:", styles['label']),
                                        Paragraph(q.findings, styles['body'])])
            dt = Table(detail_rows, colWidths=[3.5*cm, PAGE_W - 2*MARGIN - 3.5*cm])
            dt.setStyle(TableStyle([
                ('BACKGROUND', (0,0), (-1,-1), LTRED),
                ('TOPPADDING', (0,0), (-1,-1), 5),
                ('BOTTOMPADDING', (0,0), (-1,-1), 5),
                ('LEFTPADDING', (0,0), (-1,-1), 8),
                ('VALIGN', (0,0), (-1,-1), 'TOP'),
                ('LINEBELOW', (0,0), (-1,-2), 0.3, colors.HexColor("#F5BBBB")),
            ]))
            story.append(KeepTogether([bt, dt, Spacer(1, 0.3*cm)]))

    # ── EXEC RECOMMENDATIONS ──────────────────────────────────────────────
    story.append(Spacer(1, 0.3*cm))
    story.append(Paragraph("5.  BOARD-LEVEL RECOMMENDATIONS", styles['h1']))
    story.append(hr())
    recs = [
        ("Establish a Data Protection Governance Board",
         "Appoint a senior responsible officer (SRO) with direct board accountability for data protection "
         "compliance. Ensure the DPO has direct access to and reports to the board on a quarterly basis."),
        ("Initiate an Immediate Remediation Programme",
         "Develop a formal Remediation Plan addressing all Critical and High-risk findings within the "
         "required timeframes. Assign named owners and report progress at each board meeting."),
        ("Commission a DPIA Review",
         "Ensure all high-risk processing activities have current, DPO-approved Data Protection "
         "Impact Assessments. This is a legal requirement under GDPR Article 35."),
        ("Invest in Staff Training and Awareness",
         "Implement role-based data protection training covering GDPR, the Data (Use and Access) Act 2025, "
         "and ISO 27701 obligations. Ensure 100% completion within 60 days and annually thereafter."),
        ("Achieve ISO/IEC 27701 Certification Readiness",
         "Engage a specialist to conduct an ISO 27701 gap assessment and develop a certification "
         "roadmap. Certification demonstrates to regulators, customers, and partners that the organisation "
         "takes privacy seriously."),
        ("Review and Update All Processor Agreements",
         "Ensure all Data Processing Agreements with processors and sub-processors contain the mandatory "
         "GDPR Article 28 terms and reflect DUAA 2025 obligations for data intermediaries."),
    ]
    for i, (title, body) in enumerate(recs, 1):
        story.append(KeepTogether([
            Paragraph(f"{i}.  {title}", styles['h2']),
            Paragraph(body, styles['body']),
            Spacer(1, 0.15*cm),
        ]))

    # ── SIGN-OFF ──────────────────────────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("6.  AUDIT SIGN-OFF", styles['h1']))
    story.append(hr())
    story.append(Paragraph(
        "This Executive Summary has been prepared based on evidence gathered during the data protection "
        "compliance audit conducted against the requirements of GDPR (EU/UK) 2016/679, the Data (Use and "
        "Access) Act 2025, and ISO/IEC 27701:2019. The findings and recommendations represent the "
        "professional judgement of the audit team based on information provided by the organisation at the "
        "date of this report. This document is CONFIDENTIAL and subject to legal privilege.",
        styles['body']))
    story.append(Spacer(1, 1*cm))
    sign_rows = [
        ["Auditor / Lead:", state.auditor or "________________________",
         "Date:", state.audit_date or "________________________"],
        ["Organisation:", state.org_name or "________________________",
         "Ref:", state.audit_ref or "________________________"],
    ]
    sigt = Table(sign_rows, colWidths=[3.5*cm, 8*cm, 2*cm, 5*cm])
    sigt.setStyle(TableStyle([
        ('FONTNAME', (0,0), (0,-1), 'Helvetica-Bold'),
        ('FONTNAME', (2,0), (2,-1), 'Helvetica-Bold'),
        ('FONTSIZE', (0,0), (-1,-1), 9),
        ('TOPPADDING', (0,0), (-1,-1), 8),
        ('BOTTOMPADDING', (0,0), (-1,-1), 8),
        ('LINEBELOW', (1,0), (1,-1), 0.5, GREY40),
        ('LINEBELOW', (3,0), (3,-1), 0.5, GREY40),
        ('TEXTCOLOR', (0,0), (0,-1), GREY40),
        ('TEXTCOLOR', (2,0), (2,-1), GREY40),
    ]))
    story.append(sigt)

    doc.build(story)


# ══════════════════════════════════════════════════════════════════════════════
# DETAILED REPORT
# ══════════════════════════════════════════════════════════════════════════════
def build_detailed_report(state, output_path: str):
    styles = make_styles()
    doc = HeaderFooterDocTemplate(
        output_path,
        org_name   = state.org_name or "Organisation",
        report_type= "DETAILED AUDIT REPORT",
        audit_ref  = state.audit_ref or "AUDIT-001",
        pagesize   = A4,
        topMargin  = MARGIN + 1.4*cm,
        bottomMargin = MARGIN + 1.2*cm,
        leftMargin = MARGIN, rightMargin = MARGIN,
    )
    story = []
    overall = state.overall_score()

    # ── COVER ─────────────────────────────────────────────────────────────
    story.append(Spacer(1, 1*cm))
    cover_data = [
        [Paragraph(state.org_name or "Organisation", styles['cover_org'])],
        [Paragraph("DATA PROTECTION COMPLIANCE AUDIT", styles['cover_title'])],
        [Paragraph("DETAILED FINDINGS & REMEDIATION REPORT", ParagraphStyle('cs2',
            fontName='Helvetica', fontSize=11,
            textColor=colors.HexColor("#BDD7EE"), alignment=TA_LEFT))],
        [Paragraph("GDPR (EU/UK) 2016/679  ·  Data (Use and Access) Act 2025  ·  ISO/IEC 27701:2019",
            ParagraphStyle('cs3', fontName='Helvetica', fontSize=9,
            textColor=colors.HexColor("#8FAADC"), alignment=TA_LEFT))],
    ]
    ct = Table(cover_data, colWidths=[PAGE_W - 2*MARGIN])
    ct.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), NAVY),
        ('TOPPADDING', (0,0), (-1,-1), 9),
        ('BOTTOMPADDING', (0,0), (-1,-1), 9),
        ('LEFTPADDING', (0,0), (-1,-1), 16),
    ]))
    story.append(ct)
    story.append(Spacer(1, 0.4*cm))

    meta = [
        ["Audit Reference:", state.audit_ref or "—", "Audit Date:", state.audit_date or "—"],
        ["Auditor / Lead:",  state.auditor or "—",    "Framework:", "GDPR · DUAA 2025 · ISO 27701:2019"],
        ["Overall Score:",   f"{overall['pct']}%  –  {score_label(overall['pct'])}",
         "Classification:", "CONFIDENTIAL – LEGALLY PRIVILEGED"],
    ]
    mt = Table(meta, colWidths=[3.5*cm, 7*cm, 3.5*cm, 5*cm])
    mt.setStyle(TableStyle([
        ('FONTNAME', (0,0), (0,-1), 'Helvetica-Bold'),
        ('FONTNAME', (2,0), (2,-1), 'Helvetica-Bold'),
        ('FONTSIZE', (0,0), (-1,-1), 8.5),
        ('TEXTCOLOR', (0,0), (0,-1), GREY40),
        ('TEXTCOLOR', (2,0), (2,-1), GREY40),
        ('GRID', (0,0), (-1,-1), 0.3, colors.HexColor("#CCCCCC")),
        ('BACKGROUND', (0,0), (0,-1), GREY10),
        ('BACKGROUND', (2,0), (2,-1), GREY10),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('TOPPADDING', (0,0), (-1,-1), 5),
        ('BOTTOMPADDING', (0,0), (-1,-1), 5),
        ('LEFTPADDING', (0,0), (-1,-1), 8),
    ]))
    story.append(mt)

    # ── TABLE OF CONTENTS ─────────────────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("TABLE OF CONTENTS", styles['h1']))
    story.append(hr())
    toc_items = [
        ("1.", "Executive Overview & Compliance Score", ""),
        ("2.", "Risk Summary & Prioritisation Matrix", ""),
        ("3.", "Detailed Section Findings & Remediation", ""),
    ]
    for i in range(1, 7):
        title = state.SECTION_TITLES.get(i, f"Section {i}")
        sc_s  = state.score_section(i)
        toc_items.append((f"  3.{i}.", f"Section {i}: {title}", f"Score: {sc_s['pct']}%"))
    toc_items += [
        ("4.", "Consolidated Remediation Action Plan", ""),
        ("5.", "Methodology & Framework Reference", ""),
        ("6.", "Audit Sign-Off", ""),
    ]
    for num, title, note in toc_items:
        row = f"<b>{num}</b>  {title}"
        if note:
            row += f"  <font color='#595959' size='8'>({note})</font>"
        story.append(Paragraph(row, styles['toc_section'] if not num.startswith("  ") else styles['toc_item']))

    # ── SECTION 1: OVERVIEW ───────────────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("1.  EXECUTIVE OVERVIEW & COMPLIANCE SCORE", styles['h1']))
    story.append(hr())
    story.append(Paragraph(
        f"This report presents the detailed findings of a data protection compliance audit conducted "
        f"for <b>{state.org_name or 'the organisation'}</b>. The audit assessed compliance across "
        f"six domains covering {len(state.questions)} individual controls mapped to the requirements "
        f"of the UK/EU General Data Protection Regulation (GDPR), the Data (Use and Access) Act 2025 "
        f"(DUAA 2025), and the ISO/IEC 27701:2019 Privacy Information Management System standard.",
        styles['body']))
    story.append(Spacer(1, 0.3*cm))

    sc = overall['pct']
    score_table = [
        [Paragraph(f"{sc}%", ParagraphStyle('big', fontName='Helvetica-Bold',
                   fontSize=42, textColor=score_color(sc), alignment=TA_CENTER)),
         Paragraph(
            f"<b>Overall Compliance Rating: {score_label(sc)}</b><br/><br/>"
            f"The organisation achieved an overall compliance score of {sc}% across "
            f"{len([q for q in state.questions if q.response and not q.is_na])} assessed controls. "
            f"This rating reflects the proportion of controls assessed as fully or partially compliant "
            f"against the three applicable frameworks.",
            styles['body'])],
    ]
    st = Table(score_table, colWidths=[4.5*cm, PAGE_W - 2*MARGIN - 4.5*cm], rowHeights=[3*cm])
    st.setStyle(TableStyle([
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('BACKGROUND', (0,0), (-1,-1), GREY10),
        ('BOX', (0,0), (-1,-1), 0.5, MIDBLUE),
        ('LINEAFTER', (0,0), (0,-1), 1, MIDBLUE),
        ('LEFTPADDING', (0,0), (-1,-1), 12),
    ]))
    story.append(st)

    # Section scorecard table
    story.append(Spacer(1, 0.5*cm))
    story.append(Paragraph("Section-by-Section Summary", styles['h2']))
    sc_hdr = [
        Paragraph("Section", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE)),
        Paragraph("Total Qs", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Compliant", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Partial", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Non-Compliant", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("N/A", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Score", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
    ]
    sc_rows = [sc_hdr]
    for sid in range(1, 7):
        qs    = state.by_section(sid)
        title = state.SECTION_TITLES.get(sid, f"Section {sid}")
        compl = len([q for q in qs if q.is_compliant])
        part  = len([q for q in qs if q.is_partial])
        nc    = len([q for q in qs if q.is_non_compliant])
        na    = len([q for q in qs if q.is_na])
        sc_s  = state.score_section(sid)
        pct   = sc_s['pct']
        bg    = GREY10 if sid % 2 == 0 else WHITE
        sc_rows.append([
            Paragraph(f"S{sid}: {title}", styles['body_small']),
            Paragraph(str(len(qs)), ParagraphStyle('c', fontName='Helvetica', fontSize=9, alignment=TA_CENTER)),
            Paragraph(str(compl), ParagraphStyle('c', fontName='Helvetica-Bold', fontSize=9, textColor=GREEN, alignment=TA_CENTER)),
            Paragraph(str(part), ParagraphStyle('c', fontName='Helvetica-Bold', fontSize=9, textColor=ORANGE, alignment=TA_CENTER)),
            Paragraph(str(nc), ParagraphStyle('c', fontName='Helvetica-Bold', fontSize=9, textColor=RED, alignment=TA_CENTER)),
            Paragraph(str(na), ParagraphStyle('c', fontName='Helvetica', fontSize=9, textColor=GREY40, alignment=TA_CENTER)),
            Paragraph(f"{pct}%", ParagraphStyle('c', fontName='Helvetica-Bold', fontSize=9,
                      textColor=score_color(pct), alignment=TA_CENTER)),
        ])
    sct = Table(sc_rows, colWidths=[5.5*cm, 1.8*cm, 2*cm, 1.8*cm, 2.5*cm, 1.2*cm, 1.7*cm])
    tss2 = TableStyle([
        ('BACKGROUND', (0,0), (-1,0), NAVY),
        ('GRID', (0,0), (-1,-1), 0.4, colors.HexColor("#CCCCCC")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('TOPPADDING', (0,0), (-1,-1), 5),
        ('BOTTOMPADDING', (0,0), (-1,-1), 5),
        ('LEFTPADDING', (0,0), (-1,-1), 6),
    ])
    for i in range(1, 7):
        tss2.add('BACKGROUND', (0, i), (-1, i), GREY10 if i % 2 == 0 else WHITE)
    sct.setStyle(tss2)
    story.append(sct)

    # ── SECTION 2: RISK SUMMARY ───────────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("2.  RISK SUMMARY & PRIORITISATION MATRIX", styles['h1']))
    story.append(hr())
    rs = state.risk_summary()
    story.append(Paragraph(
        "The following table summarises all non-compliant and partially compliant findings by risk level. "
        "Controls are prioritised for remediation in the order: Critical → High → Medium → Low. "
        "Partially compliant controls are included where they represent a material gap.",
        styles['body']))
    story.append(Spacer(1, 0.3*cm))

    risk_matrix_hdr = [
        Paragraph("Risk", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Ref", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Section", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE)),
        Paragraph("Control / Question (abbreviated)", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE)),
        Paragraph("Response", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8.5, textColor=WHITE, alignment=TA_CENTER)),
    ]
    matrix_rows = [risk_matrix_hdr]
    nc_and_partial = sorted(
        [q for q in state.questions if q.is_non_compliant or q.is_partial],
        key=lambda q: ({"Critical":0,"High":1,"Medium":2,"Low":3}.get(q.risk, 4), q.section_id, q.number)
    )
    for i, q in enumerate(nc_and_partial):
        short_q = (q.question[:85] + "…") if len(q.question) > 88 else q.question
        bg = LTRED if q.is_non_compliant else LTAMBER
        rc = RISK_COLOR.get(q.risk, GREY40)
        resp_color = RED if q.is_non_compliant else ORANGE
        matrix_rows.append([
            Paragraph(q.risk or "—", ParagraphStyle('rml', fontName='Helvetica-Bold', fontSize=8,
                      textColor=RISK_TEXT_COLOR.get(q.risk, BLACK), alignment=TA_CENTER)),
            Paragraph(f"S{q.section_id}/Q{q.number}", styles['body_small']),
            Paragraph(state.SECTION_TITLES.get(q.section_id, ""), styles['body_small']),
            Paragraph(short_q, styles['body_small']),
            Paragraph("Non-Compliant" if q.is_non_compliant else "Partial",
                      ParagraphStyle('rr', fontName='Helvetica-Bold', fontSize=8,
                      textColor=resp_color, alignment=TA_CENTER)),
        ])
    mt2 = Table(matrix_rows, colWidths=[1.8*cm, 1.5*cm, 3.5*cm, 8.5*cm, 2.2*cm])
    tss3 = TableStyle([
        ('BACKGROUND', (0,0), (-1,0), NAVY),
        ('GRID', (0,0), (-1,-1), 0.4, colors.HexColor("#CCCCCC")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('TOPPADDING', (0,0), (-1,-1), 5),
        ('BOTTOMPADDING', (0,0), (-1,-1), 5),
        ('LEFTPADDING', (0,0), (-1,-1), 5),
    ])
    for i, q in enumerate(nc_and_partial, 1):
        if q.risk:
            tss3.add('BACKGROUND', (0, i), (0, i), RISK_COLOR.get(q.risk, GREY40))
        tss3.add('BACKGROUND', (1, i), (-1, i), LTRED if q.is_non_compliant else LTAMBER)
    mt2.setStyle(tss3)
    story.append(mt2)

    # ── SECTION 3: DETAILED FINDINGS ──────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("3.  DETAILED SECTION FINDINGS & REMEDIATION", styles['h1']))
    story.append(hr())

    for sid in range(1, 7):
        title = state.SECTION_TITLES.get(sid, f"Section {sid}")
        qs    = state.by_section(sid)
        sc_s  = state.score_section(sid)

        story.append(PageBreak())
        # Section header
        hdr_data = [[
            Paragraph(f"Section {sid}:  {title}", ParagraphStyle('shr', fontName='Helvetica-Bold',
                      fontSize=12, textColor=WHITE)),
            Paragraph(f"Score: {sc_s['pct']}%", ParagraphStyle('ssc', fontName='Helvetica-Bold',
                      fontSize=12, textColor=score_color(sc_s['pct']), alignment=TA_RIGHT)),
        ]]
        ht = Table(hdr_data, colWidths=[PAGE_W - 2*MARGIN - 4*cm, 4*cm], rowHeights=[1*cm])
        ht.setStyle(TableStyle([
            ('BACKGROUND', (0,0), (-1,-1), NAVY),
            ('LEFTPADDING', (0,0), (-1,-1), 12),
            ('RIGHTPADDING', (0,0), (-1,-1), 12),
            ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ]))
        story.append(ht)
        story.append(Spacer(1, 0.3*cm))

        # Group by subsection
        subsections: dict = {}
        for q in qs:
            subsections.setdefault(q.subsection, []).append(q)

        for sub, sub_qs in subsections.items():
            if sub:
                story.append(Spacer(1, 0.2*cm))
                story.append(section_bar(sub))
                story.append(Spacer(1, 0.2*cm))

            for q in sub_qs:
                # Determine styling
                if q.is_compliant:
                    border_color = GREEN
                    bg_color = LTGREEN
                    status_txt = "COMPLIANT"
                    status_color = GREEN
                elif q.is_partial:
                    border_color = ORANGE
                    bg_color = LTAMBER
                    status_txt = "PARTIALLY COMPLIANT"
                    status_color = ORANGE
                elif q.is_non_compliant:
                    border_color = RED
                    bg_color = LTRED
                    status_txt = "NON-COMPLIANT"
                    status_color = RED
                elif q.is_na:
                    border_color = GREY40
                    bg_color = GREY10
                    status_txt = "NOT APPLICABLE"
                    status_color = GREY40
                else:
                    border_color = GREY40
                    bg_color = WHITE
                    status_txt = "NOT ASSESSED"
                    status_color = GREY40

                # Question header row
                q_hdr = [[
                    Paragraph(f"Q{q.number}  |  Risk: {q.risk or '—'}", ParagraphStyle('qn',
                               fontName='Helvetica-Bold', fontSize=8, textColor=GREY40)),
                    Paragraph(status_txt, ParagraphStyle('qs', fontName='Helvetica-Bold',
                               fontSize=8, textColor=status_color, alignment=TA_RIGHT)),
                ]]
                qt = Table(q_hdr, colWidths=[10*cm, PAGE_W - 2*MARGIN - 10*cm], rowHeights=[0.45*cm])
                qt.setStyle(TableStyle([
                    ('BACKGROUND', (0,0), (-1,-1), GREY10),
                    ('LEFTPADDING', (0,0), (-1,-1), 8),
                    ('RIGHTPADDING', (0,0), (-1,-1), 8),
                    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
                    ('LINEBELOW', (0,0), (-1,-1), 0.5, border_color),
                ]))

                # Detail rows
                detail = []
                detail.append([Paragraph("Audit Question:", styles['label']),
                                Paragraph(q.question, styles['finding_q'])])
                detail.append([Paragraph("Why This Matters:", styles['label']),
                                Paragraph(q.why, styles['body_small'])])
                detail.append([Paragraph("GDPR / DUAA 2025:", styles['label']),
                                Paragraph(q.gdpr_ref, ParagraphStyle('ref', fontName='Helvetica',
                                           fontSize=8, textColor=MIDBLUE))])
                detail.append([Paragraph("ISO 27701 Clause:", styles['label']),
                                Paragraph(q.iso_ref, ParagraphStyle('iref', fontName='Helvetica',
                                           fontSize=8, textColor=TEAL))])
                if q.findings:
                    detail.append([Paragraph("Auditor Findings:", styles['label']),
                                    Paragraph(q.findings, styles['body'])])
                if q.response:
                    detail.append([Paragraph("Response:", styles['label']),
                                    Paragraph(q.response, ParagraphStyle('resp', fontName='Helvetica-Bold',
                                               fontSize=8.5, textColor=status_color))])
                detail.append([Paragraph("Evidence Required:", styles['label']),
                                Paragraph(q.evidence_req, styles['body_small'])])

                # Remediation block (highlighted)
                rem_hdr = [[
                    Paragraph("REMEDIATION STEPS", ParagraphStyle('remh', fontName='Helvetica-Bold',
                              fontSize=8, textColor=WHITE)),
                ]]
                rht = Table(rem_hdr, colWidths=[PAGE_W - 2*MARGIN], rowHeights=[0.4*cm])
                rht.setStyle(TableStyle([
                    ('BACKGROUND', (0,0), (-1,-1), TEAL),
                    ('LEFTPADDING', (0,0), (-1,-1), 8),
                    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
                ]))

                rem_body = [[Paragraph(q.remediation, styles['body'])]]
                rbt = Table(rem_body, colWidths=[PAGE_W - 2*MARGIN])
                rbt.setStyle(TableStyle([
                    ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#EBF5F5")),
                    ('LEFTPADDING', (0,0), (-1,-1), 8),
                    ('TOPPADDING', (0,0), (-1,-1), 5),
                    ('BOTTOMPADDING', (0,0), (-1,-1), 5),
                    ('BOX', (0,0), (-1,-1), 0.5, TEAL),
                ]))

                # Responsible / Date / Status row
                tracking = [[
                    Paragraph("Responsible Party:", styles['label']),
                    Paragraph(q.responsible_party or "To be assigned", styles['value']),
                    Paragraph("Target Date:", styles['label']),
                    Paragraph(q.target_date or "To be set", styles['value']),
                    Paragraph("Status:", styles['label']),
                    Paragraph(q.status or "Not Started", styles['value']),
                ]]
                trt = Table(tracking, colWidths=[3*cm, 4*cm, 2.2*cm, 3.3*cm, 1.8*cm, 4.2*cm])
                trt.setStyle(TableStyle([
                    ('BACKGROUND', (0,0), (-1,-1), GREY10),
                    ('TOPPADDING', (0,0), (-1,-1), 4),
                    ('BOTTOMPADDING', (0,0), (-1,-1), 4),
                    ('LEFTPADDING', (0,0), (-1,-1), 6),
                    ('BOX', (0,0), (-1,-1), 0.3, colors.HexColor("#CCCCCC")),
                ]))

                dt = Table(detail, colWidths=[3.5*cm, PAGE_W - 2*MARGIN - 3.5*cm])
                dt.setStyle(TableStyle([
                    ('BACKGROUND', (0,0), (-1,-1), bg_color),
                    ('TOPPADDING', (0,0), (-1,-1), 4),
                    ('BOTTOMPADDING', (0,0), (-1,-1), 4),
                    ('LEFTPADDING', (0,0), (-1,-1), 8),
                    ('VALIGN', (0,0), (-1,-1), 'TOP'),
                    ('LINEBELOW', (0,0), (-1,-2), 0.3, colors.HexColor("#CCCCCC")),
                ]))

                story.append(KeepTogether([
                    qt, dt, rht, rbt, trt,
                    Spacer(1, 0.4*cm),
                ]))

    # ── SECTION 4: CONSOLIDATED ACTION PLAN ──────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("4.  CONSOLIDATED REMEDIATION ACTION PLAN", styles['h1']))
    story.append(hr())
    story.append(Paragraph(
        "The following action plan consolidates all remediation steps across the audit, "
        "prioritised by risk level. Each action should be assigned to a named responsible "
        "party with a specific target completion date.",
        styles['body']))
    story.append(Spacer(1, 0.3*cm))

    ap_hdr = [
        Paragraph("Ref", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Risk", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8, textColor=WHITE, alignment=TA_CENTER)),
        Paragraph("Control / Finding", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8, textColor=WHITE)),
        Paragraph("Remediation Action", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8, textColor=WHITE)),
        Paragraph("Responsible", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8, textColor=WHITE)),
        Paragraph("Target Date", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8, textColor=WHITE)),
        Paragraph("Status", ParagraphStyle('h', fontName='Helvetica-Bold', fontSize=8, textColor=WHITE)),
    ]
    ap_rows = [ap_hdr]
    action_qs = sorted(
        [q for q in state.questions if q.is_non_compliant or q.is_partial],
        key=lambda q: ({"Critical":0,"High":1,"Medium":2,"Low":3}.get(q.risk,4), q.section_id, q.number)
    )
    for i, q in enumerate(action_qs):
        short_q   = (q.question[:55] + "…") if len(q.question) > 58 else q.question
        short_rem = (q.remediation[:120] + "…") if len(q.remediation) > 123 else q.remediation
        bg = LTRED if q.is_non_compliant else LTAMBER
        ap_rows.append([
            Paragraph(f"S{q.section_id}/Q{q.number}", styles['body_small']),
            Paragraph(q.risk or "—", ParagraphStyle('rl', fontName='Helvetica-Bold', fontSize=7.5,
                      textColor=RISK_TEXT_COLOR.get(q.risk, BLACK), alignment=TA_CENTER)),
            Paragraph(short_q, styles['body_small']),
            Paragraph(short_rem, styles['body_small']),
            Paragraph(q.responsible_party or "TBA", styles['body_small']),
            Paragraph(q.target_date or "TBA", styles['body_small']),
            Paragraph(q.status or "Not Started", styles['body_small']),
        ])
    apt = Table(ap_rows, colWidths=[1.5*cm, 1.5*cm, 4*cm, 5.5*cm, 2.5*cm, 1.8*cm, 1.7*cm])
    apss = TableStyle([
        ('BACKGROUND', (0,0), (-1,0), NAVY),
        ('GRID', (0,0), (-1,-1), 0.4, colors.HexColor("#CCCCCC")),
        ('VALIGN', (0,0), (-1,-1), 'TOP'),
        ('TOPPADDING', (0,0), (-1,-1), 4),
        ('BOTTOMPADDING', (0,0), (-1,-1), 4),
        ('LEFTPADDING', (0,0), (-1,-1), 5),
    ])
    for i, q in enumerate(action_qs, 1):
        apss.add('BACKGROUND', (0, i), (-1, i), LTRED if q.is_non_compliant else LTAMBER)
        if q.risk:
            apss.add('BACKGROUND', (1, i), (1, i), RISK_COLOR.get(q.risk, GREY40))
    apt.setStyle(apss)
    story.append(apt)

    # ── SECTION 5: METHODOLOGY ────────────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("5.  METHODOLOGY & FRAMEWORK REFERENCE", styles['h1']))
    story.append(hr())
    meth_paras = [
        ("Audit Scope and Approach",
         "This audit was conducted using a structured questionnaire methodology across six domains: "
         "(1) Procedural Issues & Awareness; (2) Lawful Processing; (3) Record Retention; "
         "(4) Security of Personal Data; (5) Data Subject Rights; and (6) Direct Marketing. "
         "Each domain was assessed through a series of detailed audit questions, each mapped to "
         "specific regulatory and standards requirements."),
        ("Regulatory Framework: GDPR (EU/UK) 2016/679",
         "The General Data Protection Regulation establishes the primary legal framework for personal "
         "data processing in the EU and, via the UK GDPR, in the United Kingdom. Key obligations include "
         "the six data protection principles (Article 5), six lawful bases for processing (Article 6), "
         "enhanced obligations for special category data (Article 9), data subject rights (Articles 12–23), "
         "international transfer restrictions (Chapter V), and mandatory breach notification (Articles 33–34)."),
        ("Regulatory Framework: Data (Use and Access) Act 2025",
         "The DUAA 2025 modernises the UK's data governance framework. It introduces a regime for "
         "recognised legitimate interests, enhanced data portability and smart data access rights, "
         "a framework for data intermediaries and data trustees, and new accountability obligations "
         "for senior responsible officers. The DUAA 2025 operates alongside — and does not replace — "
         "the UK GDPR."),
        ("Standards Framework: ISO/IEC 27701:2019",
         "ISO 27701 is the international standard for Privacy Information Management Systems (PIMS). "
         "It extends ISO 27001 (information security) with privacy-specific controls for both "
         "controllers (clause 7) and processors (clause 8). Certification to ISO 27701 provides "
         "independent assurance of privacy management maturity and supports demonstration of GDPR "
         "accountability."),
        ("Scoring Methodology",
         "Each control is assessed on a three-point scale: Fully Compliant (2 points), Partially "
         "Compliant (1 point), Non-Compliant (0 points). N/A responses are excluded from scoring. "
         "The overall score is calculated as: Total Points Achieved / Total Points Available × 100%. "
         "A score of 75% or above is rated Satisfactory; 50–74% Requires Improvement; below 50% "
         "Significant Gaps Identified."),
    ]
    for title, body in meth_paras:
        story.append(KeepTogether([
            Paragraph(title, styles['h2']),
            Paragraph(body, styles['body']),
            Spacer(1, 0.2*cm),
        ]))

    # ── SECTION 6: SIGN-OFF ───────────────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("6.  AUDIT SIGN-OFF", styles['h1']))
    story.append(hr())
    story.append(Paragraph(
        "This Detailed Findings & Remediation Report has been prepared based on evidence gathered "
        "and responses provided during the data protection compliance audit. The findings represent "
        "the professional assessment of the audit team at the date of this report. "
        "This document is CONFIDENTIAL and subject to legal privilege. It should not be disclosed "
        "to any third party without the express written consent of the organisation.",
        styles['body']))
    story.append(Spacer(1, 1.5*cm))
    sign_rows = [
        ["Lead Auditor:", state.auditor or "________________________",
         "Date:", state.audit_date or "________________________"],
        ["Organisation:", state.org_name or "________________________",
         "Audit Ref:", state.audit_ref or "________________________"],
        ["Report Generated:", datetime.now().strftime("%d %B %Y  %H:%M"),
         "Version:", "1.0 – FINAL"],
    ]
    sigt = Table(sign_rows, colWidths=[3.5*cm, 8*cm, 2.5*cm, 4.5*cm])
    sigt.setStyle(TableStyle([
        ('FONTNAME', (0,0), (0,-1), 'Helvetica-Bold'),
        ('FONTNAME', (2,0), (2,-1), 'Helvetica-Bold'),
        ('FONTSIZE', (0,0), (-1,-1), 9),
        ('TOPPADDING', (0,0), (-1,-1), 10),
        ('BOTTOMPADDING', (0,0), (-1,-1), 10),
        ('LINEBELOW', (1,0), (1,-1), 0.5, GREY40),
        ('LINEBELOW', (3,0), (3,-1), 0.5, GREY40),
        ('TEXTCOLOR', (0,0), (0,-1), GREY40),
        ('TEXTCOLOR', (2,0), (2,-1), GREY40),
        ('BACKGROUND', (0,0), (-1,-1), GREY10),
    ]))
    story.append(sigt)

    doc.build(story)
