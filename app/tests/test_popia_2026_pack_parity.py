#!/usr/bin/env python3
"""Deterministic completeness check: golden zip vs generated migration SQL.

Parses docs/assessment-sheets/assessment_popi_2026_1.zip and asserts the
VALUES/metadata between the PACK and LEGEND markers in
app/supabase/migrations/20260827000001_popia_2026_pack.sql were emitted by the
same parser. No database.

    python3 app/tests/test_popia_2026_pack_parity.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from popia_2026_pack import (  # noqa: E402
    FIXTURE_ZIP,
    LEGEND_BEGIN,
    LEGEND_END,
    PACK_ROWS_BEGIN,
    PACK_ROWS_END,
    legend_sql,
    pack_rows_sql,
    parse_pack,
)

MIGRATION = (
    Path(__file__).resolve().parents[1]
    / "supabase"
    / "migrations"
    / "20260827000001_popia_2026_pack.sql"
)

passed = failed = 0


def check(name: str, cond, detail: str = "") -> bool:
    global passed, failed
    ok = bool(cond)
    passed += ok
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not ok else ""))
    return ok


def slice_between(text: str, begin: str, end: str) -> str:
    i = text.find(begin)
    j = text.find(end)
    if i < 0 or j < 0 or j <= i:
        raise ValueError(f"markers {begin!r} .. {end!r} not found")
    return text[i + len(begin) : j].strip("\n")


def main() -> int:
    print("POPIA 2026 pack parity")
    check("golden zip exists", FIXTURE_ZIP.is_file(), str(FIXTURE_ZIP))
    check("migration exists", MIGRATION.is_file(), str(MIGRATION))

    pack = parse_pack()
    advisor, s1a = pack["advisor"], pack["s1a"]
    sql = MIGRATION.read_text()

    check("100 advisor questions", len(advisor) == 100, str(len(advisor)))
    check("15 S1A questions", len(s1a) == 15, str(len(s1a)))
    check("9 framework legend rows", len(pack["legend"]) == 9, str(len(pack["legend"])))
    check(
        "summary counts match main sheets",
        pack["summary_counts"] == {1: 13, 2: 13, 3: 10, 4: 42, 5: 10, 6: 12},
        str(pack["summary_counts"]),
    )

    sme_set = set(pack["sme_texts"])
    s4 = [r for r in advisor if r["section_id"] == 4]
    s4_all = [r for r in s4 if r["applies_to"] == "all"]
    s4_large = [r for r in s4 if r["applies_to"] == "large"]
    check("S4 is 42 questions", len(s4) == 42)
    check("25 S4 rows are SME+large (applies_to=all)", len(s4_all) == 25)
    check("17 S4 rows are large-only", len(s4_large) == 17)
    check("SME External texts ⊆ S4", sme_set <= {r["question"] for r in s4})
    check("SME v2 texts ⊆ S4", {r["question"] for r in pack["sme_v2"]} <= {r["question"] for r in s4})
    check("SME External == SME v2 texts", {r["question"] for r in pack["sme_ext"]} == {r["question"] for r in pack["sme_v2"]})
    check(
        "shared S4 rows use SME-v2 regulatory_ref",
        all(r["regulatory_ref"] == next(v["ref"] for v in pack["sme_v2"] if v["question"] == r["question"]) for r in s4_all),
    )
    check(
        "large-only S4 rows are not in SME texts",
        all(r["question"] not in sme_set for r in s4_large),
    )
    check("S1A texts are not in the 100", {r["question"] for r in s1a}.isdisjoint({r["question"] for r in advisor}))
    check("all advisor uids unique", len({r["uid"] for r in advisor + s1a}) == 115)
    check(
        "advisor sections 1-6 counts",
        {s: sum(1 for r in advisor if r["section_id"] == s) for s in range(1, 7)}
        == {1: 13, 2: 13, 3: 10, 4: 42, 5: 10, 6: 12},
    )
    check("every advisor question has risk/evidence/remediation",
          all(r["risk"] in ("Critical", "High", "Medium", "Low") and r["evidence_req"] and r["remediation"] for r in advisor))
    check("S1A mappings present", all(r.get("maps_to") and "Maps to Section 1 questions:" in r["why_matters"] for r in s1a))

    generated_rows = pack_rows_sql(pack)
    generated_legend = legend_sql(pack)
    file_rows = slice_between(sql, PACK_ROWS_BEGIN, PACK_ROWS_END)
    file_legend = slice_between(sql, LEGEND_BEGIN, LEGEND_END)
    check("migration PACK rows == parser output", file_rows == generated_rows)
    check("migration LEGEND json == parser output", file_legend == generated_legend)

    missing = [r["uid"] for r in advisor + s1a if r["uid"] not in sql or r["question"] not in sql]
    check("all 115 uids and question texts in migration", not missing, str(missing[:5]))

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
