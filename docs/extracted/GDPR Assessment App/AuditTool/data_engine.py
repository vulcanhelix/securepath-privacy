"""
data_engine.py  –  Loads audit questions from XLSX files and manages audit state.
"""

import os, json, re
from dataclasses import dataclass, field, asdict
from typing import List, Optional, Dict
import openpyxl

RESPONSE_OPTIONS = [
    "Yes – Fully Compliant",
    "Yes – Partially Compliant",
    "No – Non-Compliant",
    "N/A – Not Applicable",
]

RISK_ORDER = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3, "": 4}

@dataclass
class AuditQuestion:
    section_id:   int
    section_name: str          # e.g. "Section 1"
    subsection:   str          # e.g. "GOVERNANCE & ACCOUNTABILITY"
    number:       int
    question:     str
    why:          str
    gdpr_ref:     str
    iso_ref:      str
    risk:         str
    evidence_req: str
    remediation:  str
    # --- editable by user ---
    response:           str = ""
    findings:           str = ""
    responsible_party:  str = ""
    target_date:        str = ""
    status:             str = "Not Started"

    @property
    def uid(self) -> str:
        return f"S{self.section_id}_Q{self.number}"

    @property
    def is_compliant(self) -> bool:
        return self.response == "Yes – Fully Compliant"

    @property
    def is_partial(self) -> bool:
        return self.response == "Yes – Partially Compliant"

    @property
    def is_non_compliant(self) -> bool:
        return self.response == "No – Non-Compliant"

    @property
    def is_na(self) -> bool:
        return self.response == "N/A – Not Applicable"


def _clean(val) -> str:
    if val is None:
        return ""
    return str(val).strip()


def load_section_xlsx(filepath: str, section_id: int) -> List[AuditQuestion]:
    """Parse one audit XLSX and return list of AuditQuestion objects."""
    wb = openpyxl.load_workbook(filepath, data_only=True)
    ws = wb.active
    questions = []
    current_subsection = ""
    q_number = 0

    for row in ws.iter_rows(min_row=5, values_only=True):
        # Detect subsection header rows (col A empty, col B has heading text, no ISO ref)
        num_val = _clean(row[0])
        q_val   = _clean(row[1])
        iso_val = _clean(row[4]) if len(row) > 4 else ""

        if not num_val and q_val and not iso_val:
            current_subsection = q_val.strip()
            continue

        try:
            num = int(float(num_val))
        except (ValueError, TypeError):
            continue

        q_number += 1
        questions.append(AuditQuestion(
            section_id   = section_id,
            section_name = f"Section {section_id}",
            subsection   = current_subsection,
            number       = num,
            question     = _clean(row[1]),
            why          = _clean(row[2]) if len(row) > 2 else "",
            gdpr_ref     = _clean(row[3]) if len(row) > 3 else "",
            iso_ref      = _clean(row[4]) if len(row) > 4 else "",
            risk         = _clean(row[6]) if len(row) > 6 else "",
            findings     = _clean(row[7]) if len(row) > 7 else "",
            evidence_req = _clean(row[8]) if len(row) > 8 else "",
            remediation  = _clean(row[9]) if len(row) > 9 else "",
            response     = _clean(row[5]) if len(row) > 5 else "",
            responsible_party = _clean(row[10]) if len(row) > 10 else "",
            target_date       = _clean(row[11]) if len(row) > 11 else "",
            status            = _clean(row[12]) if len(row) > 12 else "Not Started",
        ))
    return questions


class AuditState:
    """Central state manager for the entire audit."""

    SECTION_TITLES = {
        1: "Procedural Issues & Awareness",
        2: "Lawful Processing of Personal Data",
        3: "Record Retention",
        4: "Security of Personal Data",
        5: "Data Subject Rights & Requests",
        6: "Direct Marketing",
    }

    def __init__(self, data_dir: str):
        self.data_dir   = data_dir
        self.questions:  List[AuditQuestion] = []
        self.org_name   = ""
        self.auditor    = ""
        self.audit_date = ""
        self.audit_ref  = ""
        self._load_all()

    def _load_all(self):
        self.questions = []
        for sid in range(1, 7):
            path = os.path.join(
                self.data_dir,
                f"Audit_GDPR_DUAA_ISO27701_Section_{sid}.xlsx"
            )
            if os.path.exists(path):
                self.questions.extend(load_section_xlsx(path, sid))

    # ── persistence ───────────────────────────────────────────────────────────
    def save(self, filepath: str):
        data = {
            "org_name":   self.org_name,
            "auditor":    self.auditor,
            "audit_date": self.audit_date,
            "audit_ref":  self.audit_ref,
            "responses":  {q.uid: {
                "response":          q.response,
                "findings":          q.findings,
                "responsible_party": q.responsible_party,
                "target_date":       q.target_date,
                "status":            q.status,
            } for q in self.questions},
        }
        with open(filepath, "w") as f:
            json.dump(data, f, indent=2)

    def load(self, filepath: str):
        with open(filepath) as f:
            data = json.load(f)
        self.org_name   = data.get("org_name", "")
        self.auditor    = data.get("auditor", "")
        self.audit_date = data.get("audit_date", "")
        self.audit_ref  = data.get("audit_ref", "")
        responses = data.get("responses", {})
        for q in self.questions:
            if q.uid in responses:
                r = responses[q.uid]
                q.response          = r.get("response", "")
                q.findings          = r.get("findings", "")
                q.responsible_party = r.get("responsible_party", "")
                q.target_date       = r.get("target_date", "")
                q.status            = r.get("status", "Not Started")

    # ── analytics ─────────────────────────────────────────────────────────────
    def answered(self) -> List[AuditQuestion]:
        return [q for q in self.questions if q.response]

    def by_section(self, sid: int) -> List[AuditQuestion]:
        return [q for q in self.questions if q.section_id == sid]

    def non_compliant(self) -> List[AuditQuestion]:
        return [q for q in self.questions if q.is_non_compliant]

    def partial(self) -> List[AuditQuestion]:
        return [q for q in self.questions if q.is_partial]

    def critical_gaps(self) -> List[AuditQuestion]:
        return [q for q in self.questions
                if q.is_non_compliant and q.risk == "Critical"]

    def score_section(self, sid: int) -> dict:
        qs = [q for q in self.by_section(sid) if q.response and not q.is_na]
        if not qs:
            return {"score": 0, "total": 0, "pct": 0}
        score = sum(2 if q.is_compliant else 1 if q.is_partial else 0 for q in qs)
        total = len(qs) * 2
        return {"score": score, "total": total, "pct": round(score / total * 100)}

    def overall_score(self) -> dict:
        qs = [q for q in self.questions if q.response and not q.is_na]
        if not qs:
            return {"score": 0, "total": 0, "pct": 0}
        score = sum(2 if q.is_compliant else 1 if q.is_partial else 0 for q in qs)
        total = len(qs) * 2
        return {"score": score, "total": total, "pct": round(score / total * 100)}

    def completion_pct(self) -> int:
        answered = len([q for q in self.questions if q.response])
        return round(answered / len(self.questions) * 100) if self.questions else 0

    def risk_summary(self) -> dict:
        out = {"Critical": 0, "High": 0, "Medium": 0, "Low": 0}
        for q in self.non_compliant():
            if q.risk in out:
                out[q.risk] += 1
        return out
