#!/usr/bin/env python3
"""Static guardrails for the Puris report-parity migration."""

from __future__ import annotations

import sys
from pathlib import Path

MIGRATION = (
    Path(__file__).resolve().parents[1]
    / "supabase"
    / "migrations"
    / "20260901000001_puris_report_parity.sql"
)


def check(name: str, condition: bool) -> bool:
    print(f"  {'PASS' if condition else 'FAIL'}  {name}")
    return condition


def main() -> int:
    sql = MIGRATION.read_text()
    checks = [
        check("migration exists", MIGRATION.is_file()),
        check("override edits lock the report row", "WHERE id = p_report_id FOR UPDATE" in sql),
        check(
            "override edits invalidate compiled payload",
            "SET overrides = p_overrides,\n         compiled_at = NULL" in sql,
        ),
        check(
            "approval independently counts proposed classifications",
            "v_proposed_classifications > 0" in sql
            and "row->>'cls_source' = 'proposed'" not in sql
            and "item.value->>'cls_source' = 'proposed'" in sql,
        ),
        check(
            "successor reports do not inherit accuracy confirmation",
            "'accuracy_confirmed'" not in sql.split("CREATE OR REPLACE FUNCTION public.create_assessment_report", 1)[1]
            .split("CREATE OR REPLACE FUNCTION public.set_assessment_report_payload", 1)[0],
        ),
        check(
            "successor reports keep only narrative continuity",
            "'narratives', v_head.overrides->'narratives'" in sql
            and "'sections_excluded', v_head.overrides->'sections_excluded'" in sql
            and "'risk_register', v_head.overrides->'risk_register'" not in sql,
        ),
        check(
            "under review remains in risk summaries",
            "r.response IN ('non_compliant', 'under_review')" in sql,
        ),
        check(
            "database scoring respects report spec section scope",
            "metadata #> '{report_spec,assessment_scope,section_ids}'" in sql
            and "q.section_id = ANY(v_report_sections)" in sql,
        ),
        check(
            "database scoring retains unanswered controls in the denominator",
            "LEFT JOIN public.assessment_responses r" in sql
            and "r.response IS DISTINCT FROM 'na'" in sql,
        ),
    ]
    passed = sum(checks)
    failed = len(checks) - passed
    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
