#!/usr/bin/env python3
"""Structural guard for .github/workflows/e2e.yml.

A SQL suite step passes on `! grep -q FAIL log` alone if the suite never ran
(empty log). This happened: a bad merge left the cadence suite unexecuted and
the notifications step empty while CI stayed green. This check fails CI unless:
  - every app/tests/e2e_*.sql suite is run by exactly one step,
  - each suite step runs exactly one suite,
  - that step asserts both no FAIL and at least one PASS on the suite's own log.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/e2e.yml"
SUITE_RE = re.compile(r"app/tests/(e2e_[a-z0-9_]+\.sql)")


def main() -> int:
    suites = sorted(p.name for p in (ROOT / "app/tests").glob("e2e_*.sql"))
    # stdlib only (the runner may lack PyYAML): split the job's step list
    # on its "      - " item markers and keep each step's name + text
    steps = []
    for chunk in re.split(r"\n      - ", "\n" + WORKFLOW.read_text())[1:]:
        m = re.match(r"name: (.+)", chunk)
        steps.append({"name": m.group(1).strip() if m else "(unnamed)", "run": chunk})
    errors, seen = [], {}
    for step in steps:
        run = step.get("run") or ""
        found = sorted(set(SUITE_RE.findall(run)))
        if not found:
            continue
        name = step.get("name", "(unnamed)")
        if len(found) > 1:
            errors.append(f"step '{name}' runs several suites: {found}")
        for suite in found:
            seen.setdefault(suite, []).append(name)
        m = re.search(r"tee (/tmp/\S+\.log)", run)
        if not m:
            errors.append(f"step '{name}': {found[0]} output is not tee'd to a log")
            continue
        log = re.escape(m.group(1))
        if not re.search(r'! grep -q "FAIL" ' + log, run):
            errors.append(f"step '{name}': no FAIL assertion on {m.group(1)}")
        if not re.search(r'(?<!! )grep -q "PASS" ' + log, run):
            errors.append(f"step '{name}': no PASS assertion on {m.group(1)}")
    for suite in suites:
        if suite not in seen:
            errors.append(f"suite {suite} is not run by any step")
        elif len(seen[suite]) > 1:
            errors.append(f"suite {suite} is run by several steps: {seen[suite]}")
    for e in errors:
        print("FAIL", e)
    print(f"{len(suites)} suites, {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
