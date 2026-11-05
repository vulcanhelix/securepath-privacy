# Release-1 backlog — live status (v2)

Legend: TODO → IN-FLIGHT(agent/branch) → REVIEW → MERGED → VERIFIED (green on staging).
BLOCKED-EXT = waiting on a William/external input. Derive state with `docs/status.sh`
before trusting this column. Plan detail: `BUILD_PLAN_R1.md` (v2).

| ID | Issue | Scope | Model | Wave | Deps | Acceptance | Status | Size |
|---|---|---|---|---|---|---|---|---|
| W0-00 | [#9] | Authz remodel: role_assignments, helpers, all policies/RPCs, invites, e2e re-baseline, policy template catalogue | ORCH/MAX | W0 | — | ported suite green; expiry denied | TODO | L |
| W0-01 | [#10] | Jurisdiction packs, licences, designations, support grants; ALTERs client_orgs/practices/users | ORCH/MAX | W0 | W0-00 | §6.1 field checklist | TODO | M |
| W0-02 | [#11] | Programme engine ~24 tables + notification/jobs infra tables | ORCH/MAX | W0 | W0-01 | policy template per table; calc protection | TODO | L |
| W0-03 | [#12] | Template versions, requirement mappings, import tables | ORCH/MAX | W0 | W0-02 | version immutability | TODO | M |
| W0-04 | [#13] | tracks→programmes, programme_reports, audit trigger design; suite green | ORCH/MAX | W0 | W0-02 | legacy readable | TODO | M |
| W0-05 | [#14] | Fixture pack: test jurisdiction values, POPIA seed, 2 partners/3 clients | MAX | W0 | W0-02 | AT suite runnable | TODO | M |
| W1-01 | [#15] | §9 rules engine (dates/weeks/RAG/closure/snapshots/licence count), p_now | MAX | W1 | W0-02 | unit tests; AT-11/12/17 | TODO | L |
| W1-02 | [#16] | Evidence verify→accept chain, EV refs, self-ban, alternate, cross-programme offers | MAX | W1 | W0-02 | AT-13/14 + offer test | TODO | L |
| W1-03 | [#17] | Cadence engine: monthly maintenance + quarterly/annual generation, providers, gating, history | MAX | W1 | W0-02, W1-01 | AT-15/16 + cadence test | TODO | L |
| W1-04 | [#18] | Operational registers + jurisdiction deadlines + breach route | MAX | W1 | W0-01, W0-02, W1-01 | AT-09/19 | TODO | M |
| W1-05 | [#19] | Programme lifecycle: instantiate, recalc, apply-version, in-programme edits, close | MAX | W1 | W0-03, W1-01 | AT-08; round trip | TODO | L |
| W1-06 | [#20] | KPI/RAID/weekly-log/training/doc-register RPCs + report ref minting | FLASH | W1 | W0-02 | per-entity tests | TODO | M |
| W1-07 | [#21] | Licences: counting consumption, onboarding block, usage roll-up | FLASH | W1 | W0-01, W1-01 | AT-07 | TODO | M |
| W1-08 | [#22] | Notification dispatch: outbox consumer, prefs/digest, branded mail, breach-immediate, agenda mail | MAX | W1 | W0-02 + emitters | breach immediate; digest batch | TODO | M |
| W1-09 | [#23] | Scheduler runner: pg_cron or timer→RPC, job_runs, TZ, catch-up | MAX | W1 | W0-02 | dry-run all jobs; catch-up test | TODO | M |
| W2-00 | [#24] | Shared shell: types regen, nav slots, brand context, breach mount, middleware hooks | FLASH | W2 | W0-x | shell compiles; mounts documented | TODO | M |
| W2-01 | [#25] | Partner console (screen 10) | MAX | W2 | W1-01, W1-03, W2-00 | AT-02; tiles match | TODO | L |
| W2-02 | [#26] | Client onboarding wizard (screen 11) | FLASH | W2 | W0-01, W1-05, W1-07 | e2e programme create | TODO | M |
| W2-03 | [#27] | Branding settings (screen 12) + preview + contrast + template upload | FLASH | W2 | W0-01 | AT-06 | TODO | M |
| W2-15 | [#28] | Brand consumption: sign-in/subdomain/email/report cover | MAX | W2 | W2-03, W1-08 | AT-05 | TODO | M |
| W2-04 | [#29] | Programme dashboard (screen 01) | FLASH | W2 | W1-01 | linked figures | TODO | M |
| W2-05 | [#30] | Activity schedule + Gantt (screen 02) | MAX | W2 | W1-01, W1-05 | AT-11/12; FR-SCH-04/05 | TODO | L |
| W2-06 | [#31] | Evidence review + presigned capture (screens 03/08) | FLASH | W2 | W1-02, W4-09 | AT-13/14 flow | TODO | M |
| W2-07 | [#32] | Weekly session agenda + log (screen 04) | FLASH | W2 | W1-01, W1-06 | FR-WKS-03 | TODO | M |
| W2-08 | [#33] | Monthly report builder (screen 05) | MAX | W2 | W1-01, W1-03 | AT-17 | TODO | L |
| W2-09 | [#34] | Operational registers (screen 06) + breach button | FLASH | W2 | W1-04 | AT-09/19 UI | TODO | M |
| W2-10 | [#35] | Monthly Maintenance (screen 09) + checklist surface | FLASH | W2 | W1-03 | AT-15/16 UI | TODO | M |
| W2-11 | [#36] | KPIs + RAID/decisions UI | FLASH | W2 | W1-06 | CRUD + confirm | TODO | S |
| W2-12 | [#37] | Doc register + training + designations UI | FLASH | W2 | W1-06 | CRUD | TODO | S |
| W2-13 | [#38] | Exec view + mobile 390px + camera capture | FLASH | W2 | W1-01, W1-02 | read-only; 390px | TODO | M |
| W2-14 | [#39] | Platform admin: partners CRUD + metrics + licence UI | FLASH | W2 | W0-01 | CRUD works | TODO | M |
| W2-16 | [#40] | Remediation register + programme item editor (FR-REG, FR-TPL-04) | FLASH | W2 | W1-01, W1-05 | closure blocked sans evidence | TODO | M |
| W2-17 | [#41] | Partner team + licence usage page (FR-TEAM, FR-LIC-01) | FLASH | W2 | W0-00, W1-07 | removal test; usage matches | TODO | M |
| W3-01 | [#42] | Import framework + findings/tracker/workbook loaders (FR-IMP-01/02/04/05) | MAX | W3 | W0-03, W1-05 | preview+rejects | TODO | L |
| W3-02 | [#43] | First-client migration + reconciliation + sign-off + parallel run | MAX | W3 | W3-01 | AT-10 | BLOCKED-EXT (tracker + POPIA content) | L |
| W3-03 | [#44] | Word/PDF partner-templated outputs (report, exec pack, checklist, annual) | MAX | W3 | W2-08, W2-03 | AT-18 | TODO | L |
| W3-04 | [#45] | Exports: evidence zip, Excel, history, portfolio, usage, audit CSV | FLASH | W3 | W1 done | admin-gated downloads | TODO | M |
| W3-05 | [#46] | Template import/export, publish, diff, apply, partner variants (FR-TPL-05) | MAX | W3 | W0-03, W1-05 | AT-08; round-trip | TODO | M |
| W4-00 | [#47] | Playwright harness + CI job | FLASH | W4 | W2-00 | 1 real UI test in CI | TODO | S |
| W4-01 | [#48] | Support access grant e2e | MAX | W4 | W0-01, W2-14 | AT-03/04 | TODO | M |
| W4-02 | [#49] | SSO (Entra/Google) + idle timeout | MAX | W4 | W0-00 | SSO login; timeout | TODO | M |
| W4-03 | [#50] | Malware scan on upload | FLASH | W4 | — | EICAR rejected | TODO | S |
| W4-04 | [#51] | Client exit export + timed deletion + certificate | MAX | W4 | W0-x | AT-20 | TODO | M |
| W4-05 | [#52] | Per-client data-region plumbing | MAX | W4 | W0-01 | region enforced | TODO | M |
| W4-06 | [#53] | Field-level audit triggers, all tenant tables + extract + drift check | MAX | W4 | all migrations final | AT-21 + drift zero | TODO | M |
| W4-07 | [#54] | AT-01..22 executable suite | MAX | W4 | all | 22/22 | TODO | L |
| W4-08 | [#55] | Partner suspension enforcement (FR-PLT-06) | MAX | W4 | W0-00, W0-01 | suspend→login fails→data intact | TODO | S |
| W4-09 | [#56] | Evidence storage NFR-02: per-client encryption + signed links + direct upload | MAX | W4 | W0-02 | presigned flow | TODO | M |
| W5-01 | [#57] | Template spreadsheet format + POPIA generalisation tooling | FLASH | W5 | W3-05 | round-trip | TODO | M |
| W5-02 | [#58] | Jurisdiction-pack editor + verification checklist | FLASH | W5 | W0-01 | packs editable | TODO | S |
