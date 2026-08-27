"""Parse assessment_popi_2026_1.zip into the Stage 1 POPIA v2 pack records.

Used by the migration generator and by test_popia_2026_pack_parity.py so ingest
and assertion share one parser. Stdlib only.
"""
from __future__ import annotations

import io
import json
import re
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"

FIXTURE_ZIP = (
    Path(__file__).resolve().parents[2]
    / "docs"
    / "assessment-sheets"
    / "assessment_popi_2026_1.zip"
)

CANON_FILES = {
    1: "Audit_Section_1_Procedural_Issues.xlsx",
    2: "Audit_Section_2.xlsx",
    3: "Audit_Section_3.xlsx",
    4: "Audit_Section_4.xlsx",
    5: "Audit_Section_5.xlsx",
    6: "Audit_Section_6.xlsx",
}
SME_EXT = "Audit_Section_4_SME_External.xlsx"
SME_V2 = "Audit_Section_4_SME_v2 Frameworks open.xlsx"
S1A = "Audit_Section_1A_Staff_Awareness_Check.xlsx"

PACK_ROWS_BEGIN = "-- POPIA_2026_PACK_ROWS_BEGIN"
PACK_ROWS_END = "-- POPIA_2026_PACK_ROWS_END"
LEGEND_BEGIN = "-- POPIA_2026_LEGEND_BEGIN"
LEGEND_END = "-- POPIA_2026_LEGEND_END"


def _col_row(ref: str) -> tuple[int, int]:
    m = re.match(r"([A-Z]+)(\d+)", ref)
    assert m, ref
    n = 0
    for ch in m.group(1):
        n = n * 26 + (ord(ch) - 64)
    return n, int(m.group(2))


def _cell_text(cell, shared: list[str]) -> str | None:
    t = cell.attrib.get("t")
    v = cell.find("m:v", NS)
    is_el = cell.find("m:is", NS)
    if t == "s" and v is not None and v.text is not None:
        return shared[int(v.text)]
    if t == "inlineStr" and is_el is not None:
        texts = [
            tt.text or ""
            for tt in is_el.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t")
        ]
        return "".join(texts)
    if v is not None and v.text is not None:
        return v.text
    return None


def load_xlsx_sheets(data: bytes) -> list[tuple[str, int, int, dict[tuple[int, int], str]]]:
    xz = zipfile.ZipFile(io.BytesIO(data))
    names = xz.namelist()
    shared: list[str] = []
    if "xl/sharedStrings.xml" in names:
        root = ET.fromstring(xz.read("xl/sharedStrings.xml"))
        for si in root.findall("m:si", NS):
            texts = [
                t.text or ""
                for t in si.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t")
            ]
            shared.append("".join(texts))
    wb = ET.fromstring(xz.read("xl/workbook.xml"))
    sheets_meta = []
    for sh in wb.find("m:sheets", NS).findall("m:sheet", NS):
        sheets_meta.append((sh.attrib["name"], sh.attrib[REL_NS]))
    rels = ET.fromstring(xz.read("xl/_rels/workbook.xml.rels"))
    rid_to_target = {rel.attrib["Id"]: rel.attrib["Target"] for rel in rels}
    out = []
    for name, rid in sheets_meta:
        target = rid_to_target[rid]
        if target.startswith("/"):
            target = target.lstrip("/")
        elif not target.startswith("xl/"):
            target = "xl/" + target
        root = ET.fromstring(xz.read(target))
        grid: dict[tuple[int, int], str] = {}
        max_r = max_c = 0
        for c in root.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c"):
            ref = c.attrib.get("r")
            if not ref:
                continue
            col, row = _col_row(ref)
            val = _cell_text(c, shared)
            if val is None:
                continue
            grid[(row, col)] = val
            max_r = max(max_r, row)
            max_c = max(max_c, col)
        out.append((name, max_r, max_c, grid))
    return out


def extract_numbered(grid, max_r: int) -> list[dict[str, str]]:
    sub = ""
    rows = []
    for r in range(1, max_r + 1):
        a_raw = str(grid.get((r, 1)) or "")
        a = a_raw.strip()
        b = str(grid.get((r, 2)) or "").strip()
        if a_raw.startswith("  ") and not b:
            sub = a
            continue
        try:
            num = int(float(a))
        except (TypeError, ValueError):
            continue
        if not b:
            continue
        rows.append(
            {
                "num": num,
                "subsection": sub,
                "question": b,
                "ref": str(grid.get((r, 3)) or "").strip(),
                "risk": str(grid.get((r, 5)) or "").strip(),
                "evidence": str(grid.get((r, 7)) or "").strip(),
                "remediation": str(grid.get((r, 8)) or "").strip(),
            }
        )
    return rows


def section_name_from_title(title: str) -> str:
    m = re.search(r"SECTION\s+\d+[A-Z]?:\s*(.+)$", title, re.I)
    if not m:
        return title.strip()
    name = m.group(1).strip()
    # Drop edition suffixes like "| SME EDITION..."
    name = name.split("|")[0].strip()
    if name.isupper() or name == name.upper():
        small = {"of", "and", "&", "the", "for", "to"}
        words = name.lower().split()
        out = []
        for i, w in enumerate(words):
            if w in small and i != 0:
                out.append(w)
            else:
                out.append(w[:1].upper() + w[1:] if w not in {"&"} else w)
        return " ".join(out)
    return name


def parse_pack(zip_path: Path | None = None) -> dict[str, Any]:
    path = zip_path or FIXTURE_ZIP
    zf = zipfile.ZipFile(path)

    def first_sheet(fname: str):
        sheets = load_xlsx_sheets(zf.read(fname))
        return sheets[0]

    def sheet_named(fname: str, want: str):
        for sname, max_r, max_c, grid in load_xlsx_sheets(zf.read(fname)):
            if sname == want:
                return sname, max_r, max_c, grid
        raise KeyError(want)

    canon = {}
    summary_counts = {}
    for sec, fname in CANON_FILES.items():
        sheets = load_xlsx_sheets(zf.read(fname))
        sname, max_r, max_c, grid = sheets[0]
        title = str(grid.get((1, 1)) or "")
        questions = extract_numbered(grid, max_r)
        canon[sec] = {
            "file": fname,
            "sheet": sname,
            "section_name": section_name_from_title(title),
            "questions": questions,
        }
        summary_counts[sec] = len(extract_numbered(sheets[1][3], sheets[1][1]))

    sme_ext_sheet = load_xlsx_sheets(zf.read(SME_EXT))[0]
    sme_ext_qs = extract_numbered(sme_ext_sheet[3], sme_ext_sheet[1])
    sme_v2_sheet = load_xlsx_sheets(zf.read(SME_V2))[0]
    sme_v2_qs = extract_numbered(sme_v2_sheet[3], sme_v2_sheet[1])
    sme_texts = {r["question"] for r in sme_ext_qs}
    v2_ref = {r["question"]: r["ref"] for r in sme_v2_qs}

    advisor = []
    for sec in range(1, 7):
        block = canon[sec]
        for r in block["questions"]:
            applies = "all"
            ref = r["ref"]
            if sec == 4:
                if r["question"] in sme_texts:
                    applies = "all"
                    ref = v2_ref[r["question"]]
                else:
                    applies = "large"
            advisor.append(
                {
                    "section_id": sec,
                    "section_name": block["section_name"],
                    "subsection": r["subsection"],
                    "question_number": r["num"],
                    "question": r["question"],
                    "regulatory_ref": ref,
                    "risk": r["risk"],
                    "evidence_req": r["evidence"],
                    "remediation": r["remediation"],
                    "applies_to": applies,
                    "uid": f"popia.s{sec}.q{r['num']:02d}",
                }
            )

    staff_sheet = sheet_named(S1A, "Staff Check")
    map_sheet = sheet_named(S1A, "Auditor mapping")
    staff_qs = extract_numbered(staff_sheet[3], staff_sheet[1])
    # mapping: col2 question, col3 S1 targets, col4 POPIA ref (extract_numbered puts col3 in ref)
    map_rows = []
    grid, max_r = map_sheet[3], map_sheet[1]
    for r in range(1, max_r + 1):
        a = str(grid.get((r, 1)) or "").strip()
        try:
            num = int(float(a))
        except (TypeError, ValueError):
            continue
        map_rows.append(
            {
                "num": num,
                "question": str(grid.get((r, 2)) or "").strip(),
                "maps_to": str(grid.get((r, 3)) or "").strip(),
                "popia_ref": str(grid.get((r, 4)) or "").strip(),
            }
        )
    map_by_num = {m["num"]: m for m in map_rows}

    s1a = []
    for r in staff_qs:
        m = map_by_num[r["num"]]
        why = f"Maps to Section 1 questions: {m['maps_to']}\nPOPIA reference: {m['popia_ref']}"
        s1a.append(
            {
                "section_id": 11,
                "section_name": "Staff awareness check",
                "subsection": r["subsection"],
                "question_number": r["num"],
                "question": r["question"],
                "why_matters": why,
                "regulatory_ref": m["popia_ref"],
                "risk": "Low",
                "evidence_req": "",
                "remediation": "",
                "applies_to": "all",
                "uid": f"popia.s11.q{r['num']:02d}",
                "maps_to": m["maps_to"],
            }
        )

    legend_sheet = sheet_named(SME_V2, "Framework Legend")
    legend = []
    lg, lmax = legend_sheet[3], legend_sheet[1]
    for r in range(2, lmax + 1):
        fw = str(lg.get((r, 1)) or "").strip()
        if not fw:
            continue
        legend.append(
            {
                "framework": fw,
                "applicability": str(lg.get((r, 2)) or "").strip(),
                "description": str(lg.get((r, 3)) or "").strip(),
            }
        )

    return {
        "advisor": advisor,
        "s1a": s1a,
        "legend": legend,
        "sme_texts": sorted(sme_texts),
        "sme_ext": sme_ext_qs,
        "sme_v2": sme_v2_qs,
        "canon": canon,
        "summary_counts": summary_counts,
    }


def sql_literal(value: str | None) -> str:
    if value is None:
        return "NULL"
    tag = "p"
    n = 0
    while f"${tag}$" in value:
        n += 1
        tag = f"p{n}"
    return f"${tag}${value}${tag}$"


def pack_rows_sql(pack: dict[str, Any]) -> str:
    lines = []
    for row in pack["advisor"] + pack["s1a"]:
        why = row.get("why_matters") or ""
        lines.append(
            "  ({section_id}, {section_name}, {subsection}, {qn}, {question}, {why}, "
            "{ref}, {risk}, {evidence}, {remediation}, {applies}, {uid})".format(
                section_id=row["section_id"],
                section_name=sql_literal(row["section_name"]),
                subsection=sql_literal(row["subsection"]),
                qn=row["question_number"],
                question=sql_literal(row["question"]),
                why=sql_literal(why),
                ref=sql_literal(row["regulatory_ref"]),
                risk=sql_literal(row["risk"]),
                evidence=sql_literal(row["evidence_req"]),
                remediation=sql_literal(row["remediation"]),
                applies=sql_literal(row["applies_to"]),
                uid=sql_literal(row["uid"]),
            )
        )
    return ",\n".join(lines)


def legend_sql(pack: dict[str, Any]) -> str:
    payload = json.dumps({"framework_legend": pack["legend"]}, ensure_ascii=False, indent=2)
    return sql_literal(payload)

