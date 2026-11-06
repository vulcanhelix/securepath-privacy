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

## In-flight / last update (2026-11-06b)
- MERGED: W0-00/01/02/03/05 (all of W0 except W0-04); W1-01 rules, W1-02 evidence, W1-03 cadence, W1-04 registers, W1-06 ops-crud, W1-08 notifications, W1-09 scheduler.
- PENDING CI: #69 (W1-07 licences, post-review-fix rerun), #72 (W1-05 lifecycle, conflict resolved + rerun). Then W1-10 app shell opens the W2 screen wave.
- STANDING RULE (Bruce, 2026-11-06): no PR merges without a Devin cloud review — session a81e22c41da44e05b7b640c546d54de9 is the reviewer; send each PR for APPROVE/BLOCKING before merge. Its first pass caught 3 real cross-PR bugs (emitter abuse path, token vocab, missing licence assert).
- Orchestrator fixes on main: 20261106000000 (designation probe kinds + end_date expiry).
- W1-09 note: pg_cron armed but dormant under securepath.test_fixtures=on; staging/prod need SUPABASE_SERVICE_ROLE_KEY in web.env for notify.ts.

- ORCHESTRATOR PROACTIVENESS (Bruce, 2026-11-06): never end a turn idle. Always leave a background watcher running for pending CI/PRs, keep at least one session in flight while the backlog is non-empty, and use agent-run gaps for orchestrator work (diff review, orchestrator migrations, packet prep, schema fixes, tracker hygiene). Idle = bug, not rest.

## William's answers (email Fri 06/11/2026) — DECIDED
- Mapping CONFIRMED: v0.2 sits under the existing build. Pipeline = implementation phase; assessment findings enter via §13 import routes; Stage 6 = Monthly Maintenance. Tenancy/auth/isolation/branding/audit/billing stay. -> W0-04 UNBLOCKED.
- Hosting: self-hosted, one deploy per region (af-south-1 SA, eu-west-2 UK) chosen at onboarding. HostAfrica = dev/staging only. OPEN (Bruce to answer): which provider for SA production? Before any client data: DC location, security + backup arrangements, uptime commitment, POPIA s21 operator agreement.
- NFR gap order: 1) support-access grants, 2) region per client at onboarding, 3) malware scan before real evidence, 4) exit export + deletion certificate (can follow launch, needed before any client leaves), 5) SSO = LATER RELEASE (MFA covers launch).
- Custom domains: later. Release 1 = subdomains only.
- Reports: HTML-rendered PDF in partner branding, NO Word. Partner report templates = brand settings on the HTML layout. -> W3-03 rescoped.
- Timeline: December, scope frozen at v0.2 as amended. LAUNCHED = v0.2 core on the existing platform + POPIA template + first client migrated. The other 5 templates are William's content, not launch blockers.
- Wants: a CI run of the cross-tenant isolation suite to show with the gap write-up; a fixed weekly feedback slot (Bruce picks a day); Linear with William added (he loads the §15 open decisions as issues); Levona brought in early.
- Non-project ask to Bruce: send William his BIO for the services offering.

