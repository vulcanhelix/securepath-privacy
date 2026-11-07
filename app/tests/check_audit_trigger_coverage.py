#!/usr/bin/env python3
"""W4-06 drift guard: every public tenant table must carry the audit trigger.

The field-level audit (migration 20261106000026_audit_events.sql) is only as
good as its coverage: a NEW tenant table added by a later migration would
silently escape the audit net unless it also attaches the trigger. This check
is what stops that.

Rule: every public table ever created by the migrations must be exactly one of
  COVERED  — named in an attach_audit_trigger('<table>', ...) call (the
             helper from the audit migration; required spelling so this can
             stay a static grep), or a CREATE TRIGGER using audit_capture;
  EXCLUDED — listed below with the reason the spec does not require field
             capture on it;
  DROPPED  — a later migration dropped it (retired objects).

Failures: an unclassified table (new table, no trigger, no documented
exclusion), an attach call naming a table that does not exist, a table that
is BOTH attached and excluded (contradiction — pick one side deliberately),
and an exclusion entry naming a table the migrations never create (stale
entry / typo).

Run: python3 app/tests/check_audit_trigger_coverage.py   (no DB needed)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = sorted((ROOT / "app/supabase/migrations").glob("*.sql"))

# Tables the spec does not require field-level audit on, and why. Keep this
# honest: if a future table genuinely should not be audited, add it here WITH
# a reason — that is the documented-exclusion half of the contract.
EXCLUDED = {
    # audit ledgers themselves (self-reference / recursion)
    "audit_events": "the audit table itself",
    "audit_log": "W0 action ledger — already append-only audit",
    # notification fan-out / delivery bookkeeping (high churn; the originating
    # events already land in audit_log / billing_events)
    "notifications": "fan-out/read-flag churn; origin events already ledgered",
    "notification_events": "notification dispatch pipeline bookkeeping",
    "notification_recipients": "per-user delivery fan-out rows",
    # platform scheduler bookkeeping (high churn, not tenant content)
    "scheduled_jobs": "platform scheduler registry",
    "job_runs": "scheduler run bookkeeping, high churn",
    # bulk staging
    "import_rows": "bulk-import staging rows; the import_runs row is audited",
    # NFR-15: awareness results stored/reported as averages only — field-level
    # old/new would retain a second identifiable copy of individual answers
    "awareness_respondents": "NFR-15 averages-only responses",
    "awareness_responses": "NFR-15 averages-only responses",
    # platform/global content packs + registries (not tenant records)
    "frameworks": "platform registry",
    "jurisdiction_packs": "platform registry",
    "assessment_questions": "content pack, not a tenant record",
    "awareness_questions": "content pack, not a tenant record",
    "document_checklists": "content pack, not a tenant record",
    "manual_outlines": "content pack, not a tenant record",
    "policy_templates": "content pack, not a tenant record",
    "task_templates": "content pack, not a tenant record",
    "requirement_mappings": "template-version content, not a tenant record",
    # retired/derived objects (kept for documentation; also caught by DROP scan)
    "memberships": "dropped by W0-00; now a view over role_assignments",
    "assessments": "legacy stub; dropped by 20260807000004 when empty",
}

CREATE_RE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?([A-Za-z_]\w*)",
    re.IGNORECASE)
DROP_RE = re.compile(
    r"DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:public\.)?([A-Za-z_]\w*)",
    re.IGNORECASE)
ATTACH_RE = re.compile(r"attach_audit_trigger\(\s*'([A-Za-z_]\w*)'")
TRIGGER_RE = re.compile(
    r"CREATE\s+TRIGGER\s+\w+[^;]*?ON\s+(?:public\.)?([A-Za-z_]\w*)\s[^;]*?"
    r"audit_capture", re.IGNORECASE | re.DOTALL)


def main() -> int:
    created, dropped, covered = set(), set(), set()
    for f in MIGRATIONS:
        sql = f.read_text()
        created.update(m.lower() for m in CREATE_RE.findall(sql))
        dropped.update(m.lower() for m in DROP_RE.findall(sql))
        covered.update(m.lower() for m in ATTACH_RE.findall(sql))
        covered.update(m.lower() for m in TRIGGER_RE.findall(sql))

    excluded = set(EXCLUDED)
    live = created - dropped
    errors = []

    # every live public table must be attached or a documented exclusion
    for t in sorted(live - covered - excluded):
        errors.append(
            f"table '{t}' has no audit trigger and no documented exclusion — "
            f"add attach_audit_trigger('{t}', ...) in its migration, or a "
            f"reasoned entry in EXCLUDED")

    # contradictions and stale references
    for t in sorted(covered & excluded):
        errors.append(
            f"table '{t}' is BOTH audit-attached and excluded — choose one "
            f"(remove the attach call or the EXCLUDED entry)")
    for t in sorted(covered - created):
        errors.append(f"attach_audit_trigger('{t}') names a table that is "
                      f"never created by the migrations")
    for t in sorted(excluded - created):
        errors.append(f"EXCLUDED entry '{t}' names a table the migrations "
                      f"never create — stale entry or typo")

    for e in errors:
        print("FAIL", e)
    print(f"{len(live)} live public tables: {len(covered & live)} attached, "
          f"{len(excluded & live)} excluded, {len(live - covered - excluded)} "
          f"unclassified; {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
