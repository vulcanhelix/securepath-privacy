# Assessment methodology — recovered from the legacy artefacts

Source of truth for F2. Reverse-engineered 2026-07-25 from the six audit spreadsheets and
the three prototype implementations, because the spreadsheets themselves contain **no formulas**.

## Content shape

Six sections, 77 questions, 31 category groups. Per-question fields carried from the sheets:

| Sheet column | Meaning |
|---|---|
| # | ordinal within section |
| Audit Question | the question text |
| Why This Matters | rationale shown to the advisor |
| GDPR / DUAA 2025 Reference | statutory citation |
| ISO 27701:2019 Clause | standard mapping |
| Response | the answer (4-point scale below) |
| Risk Priority | Critical / High / Medium / Low — fixed per question, not answer-derived |
| Findings / Auditor Notes | free text |
| Evidence Required | what proves compliance |
| Remediation Steps | prescribed fix |
| Responsible Party, Target Date, Status | remediation tracking |

Question counts: S1=13, S2=13, S3=10, S4=18, S5=11, S6=12.

## Response scale

`Yes – Fully Compliant` · `Yes – Partially Compliant` · `No – Non-Compliant` · `N/A – Not Applicable`

Remediation status scale: `Not Started` · `In Progress` · `Complete` · `N/A`

## Scoring

All three prototypes agree, so this is the methodology to reproduce:

```
points   = 2 (fully compliant) | 1 (partially) | 0 (non-compliant)
excluded = N/A answers and unanswered questions — dropped from BOTH numerator and denominator
max      = 2 * count(answered, non-N/A)
pct      = round(points / max * 100)      # 0 when max = 0
```

Section score and overall score use the identical formula over their respective question sets.
Scoring is **unweighted** — Risk Priority drives remediation urgency and gap reporting, not the score.

Rating bands (`scoreLabel` / `scoreColour` in the v4 tool):

| Percentage | Rating | Colour |
|---|---|---|
| >= 75 | Satisfactory | #15803d |
| 50–74 | Requires Improvement | #d97706 |
| < 50 | Significant Gaps Identified | #dc2626 |

Derived figures the report needs: completion % (answered / 77), non-compliant count by risk
priority, and "critical gaps" = non-compliant AND Risk Priority = Critical.

Corroborating sources: `data_engine.py:194-219` (desktop tool), `GDPR_Audit_Tool_v4.html`
(`overallScore()`, and `1 - sc.answered/77` confirming the 77-question total), and the free
basic assessment's own published wording: "Compliant = 2 pts, Partial = 1 pt, Gap = 0 pts,
N/A = excluded from denominator".

## Open gaps

1. **POPIA content does not exist yet.** These six sheets are GDPR / DUAA 2025 / ISO 27701 —
   a UK framework. The product scope makes POPIA the SA default and the front door, with
   GDPR as the parallel framework. The POPIA question set has to come from the practice.
2. **No completed reference assessment.** The MVP success criterion is "exact score
   reproduction on completed reference assessments" — every sheet we hold has an empty
   Response column, so there is no filled-in example to diff against. One completed
   client sheet (anonymised) would turn that criterion from untestable into a passing test.
