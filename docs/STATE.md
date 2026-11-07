# Orchestrator state — session handover

Updated after every merge. Next session reads BUILD_PLAN_R1.md → BACKLOG.md → this file.

## Last update

2026-11-05 — plan v2 written after adversarial spec review. Gate RELAXED (same day):
William's answer only affects W0-04 (tracks→programmes = migration vs deprecation).
Everything else is identical under either answer — W0-00/01/02/03/05 unblocked NOW.
W0-04 stays pending his reply; even it can land mid-build (it's legacy-data seam,
not new-schema shape).

## In flight

(none)

## Done

- W0-00 MERGED 2026-11-05 (PR #59, CI green). role_assignments + predicate catalogue
  live; memberships is now a view; end_date exclusive; PostgREST needs a schema
  reload on staging after apply. NOTE: CI minio image moved to
  docker.io/bitnamilegacy/minio:2025.4.22 (upstream minio is login-gated everywhere)
  + http healthcheck + root user.

## Next unblocked

- W0-01 (#10) ALTERs + platform-tier tables; W0-05 (#14) fixtures can go in parallel.
- Deploy note: applying migration to staging requires PostgREST schema reload.

## Open questions for William

- v0.2 supersedes pipeline or sits underneath? (email sent 2026-11-05)
- NFR-11 deviation: single-region (SA) at launch + region plumbing, or UK residency
  required at launch? Needs written call.
- NFR-02 interim: stream-through-server today vs signed links in W4-09.
- External providers/assessors: login users (MFA + seats) or token links?
- "All staff report a breach" — authenticated or anonymous intake form?
- Deferred status (§15-#13): we build it into the status enum regardless — confirm.
- Licence/pricing model (§15-#3) — affects `licences` schema; needed before W0-01 final.
- First-client tracker file + POPIA template content — gates W3-02/AT-10 (BLOCKED-EXT).
- §15 decisions (15 items, his).

## Verified facts (from v2 review pass)

- `memberships` PK is `user_id` — one role per user, no platform level. Spec's role
  model needs the W0-00 remodel; it is NOT a view over memberships.
- pg_cron 1.6 present in staging postgres image (supabase/postgres:15.8.1.049) —
  enable via shared_preload_libraries, or fallback systemd-timer→RPC (W1-09 decides).
- No browser/Playwright test harness in repo — UI acceptances are API/manual until W4-00.
- `notifications` is practice-broadcast (no per-user rows) — rebuild, don't extend.
- `monthly_reports` lacks snapshot/signatures/workflow — `programme_reports` replaces it.


## William's answers (email Fri 06/11/2026) — DECIDED
- Mapping CONFIRMED: v0.2 sits under the existing build. Pipeline = implementation phase; assessment findings enter via §13 import routes; Stage 6 = Monthly Maintenance. Tenancy/auth/isolation/branding/audit/billing stay. -> W0-04 UNBLOCKED.
- Hosting: self-hosted, one deploy per region (af-south-1 SA, eu-west-2 UK) chosen at onboarding. HostAfrica = dev/staging only. OPEN (Bruce to answer): which provider for SA production? Before any client data: DC location, security + backup arrangements, uptime commitment, POPIA s21 operator agreement.
- NFR gap order: 1) support-access grants, 2) region per client at onboarding, 3) malware scan before real evidence, 4) exit export + deletion certificate (can follow launch, needed before any client leaves), 5) SSO = LATER RELEASE (MFA covers launch).
- Custom domains: later. Release 1 = subdomains only.
- Reports: HTML-rendered PDF in partner branding, NO Word. Partner report templates = brand settings on the HTML layout. -> W3-03 rescoped.
- Timeline: December, scope frozen at v0.2 as amended. LAUNCHED = v0.2 core on the existing platform + POPIA template + first client migrated. The other 5 templates are William's content, not launch blockers.
- Wants: a CI run of the cross-tenant isolation suite to show with the gap write-up; a fixed weekly feedback slot (Bruce picks a day); Linear with William added (he loads the §15 open decisions as issues); Levona brought in early.
- Non-project ask to Bruce: send William his BIO for the services offering.

## In-flight / last update (2026-11-07d)
- MERGED #107 int/wave2 = TEN PRs at once: #102 suspension(000021), #103 regions(000020), #104 PDF print route, #105 partner console, #106 exec view+my-actions(000022), #108 field-level audit(000026), #109 exports(000027), #110 snapshot consolidation(000023), #111 malware scan(000025 — clamd profile-gated), #112 import framework(000024). Main: tsc clean, 26 suites / 0 problems, audit-coverage 0 problems. Board ~46/51.
- BUILDING (2): W2-02 onboarding wizard (6f85a118), W2-03 branding settings (b54eab9f).
- #113 W2-17 (000028) APPROVED — watcher ba42008d armed on head 3ff8710 → MERGE ON GREEN. Do NOT push to main until merged.
- #114 W2-03 branding (000029) BLOCKED by Devin — fix agent 22a43f59 closing the practices direct-UPDATE path via new migration 000031 (column-scope the grant or close entirely; tighten practices_update RLS too if needed).
- #115 W2-02 onboarding — fix agent d59504ca rebasing onto merged 000020 + renumber 000030.
- Next free migration: 000032.
- BUILDING: nothing else this instant — next: W2-15, W4-04, W4-07, W4-02, W4-09.
- Next free migration: 000031 (000028=#113 merged, 000029=#114, 000030=#115).
- Next free migration: 000030.
- QUEUE next wave after those: W2-15 brand consumption, W4-04 client exit, W4-07 AT suite, W4-02?, W4-09 evidence storage signed links. W3-02 still blocked on William's tracker; W5 = William's tooling.
- Next free migration: 000028.
- WAKE PATTERN (works): every wait = a background subagent that polls/reports (completion notifies me). Hourly tick = sleep-3300 subagent, re-arm each completion. nohup scripts do NOT wake.
- Devin session a81e22c41da44e05b7b640c546d54de9; verdicts land on PRs — check comments if session silent. Gate = CI green + Devin APPROVE + Claude diff-check.
- Treadmill: branch protection requires up-to-date heads; each main commit stales open PRs → fold approved heads into ONE integration branch (int/wave2 pattern) and merge once.
## Lessons (do not repeat)
- CI: a suite step that only checks `! grep FAIL` passes on an empty log. My conflict-resolution script once dropped the cadence suite and emptied the notifications step while CI stayed green. Now `app/tests/check_ci_workflow.py` runs first in CI and enforces one suite per step plus FAIL and PASS assertions. Resolve e2e.yml conflicts by hand-merging step bodies, then run the checker.
- UI screens: writes ONLY through RPCs. No direct-table fallback when an RPC is missing, because it skips RPC-side validation (caught on #75). Put this rule in every screen prompt.
- Before re-spawning a rate-limited agent, confirm it is actually dead (read_subagent). I once ran two W2-06 agents in one worktree.
- Orchestrator migrations go through a PR and Devin review like everything else, not straight to main.
- `gh issue view` is broken on this repo (Projects-classic GraphQL). Use `gh api repos/vulcanhelix/securepath-privacy/issues/N`.
- Check issue numbers against titles before writing a prompt (I once gave W2-11 #35 instead of #36).

