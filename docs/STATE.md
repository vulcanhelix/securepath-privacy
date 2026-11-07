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

## In-flight / last update (2026-11-07c)
- MERGED: everything through #101 + #96..#100. #107 int/wave2 (=#102 suspension+000021, #103 regions+000020, #104 PDF, #105 console, #106 exec 000022) — all approved, combined CI green once; updated to main at 61d60f6, rerun in flight → MERGE ON GREEN, five PRs auto-close.
- APPROVED, awaiting wave-3 integration: #108 field audit (000026), #109 exports (000027), #110 snapshot consolidation (000023), #111 malware scan (000025 — FIXED its own CI break: clamd sidecar now profile-gated [scanner] so compose up skips it; head 0764871), #112 import framework (000024).
- EXECUTING NOW: #107 int/wave2 grown to ALL TEN approved PRs (#102/#103/#104/#105/#106/#108/#109/#110/#111/#112, migrations 000020-000027), head 4879afe pushed, ONE combined CI armed → merge on green, all ten PRs auto-close. #105's solo FAILURE is stale — ignore.
- After #107: nothing building → next wave = W2-02 onboarding, W2-03 branding, W2-15 brand consumption, W2-17 team/licence, W4-04 client exit, W4-07 AT suite, W4-02?, W4-09 evidence storage. W3-02 still blocked on William's tracker; W5 = William's tooling.
- BUILDING: nothing right now — next wave after wave-3: W2-02 onboarding wizard, W2-03 branding settings, W2-15 brand consumption, W2-17 partner team/licence, W4-04 client exit, W4-07 AT suite, W4-02?, #95-closed-by-#110. W3-02 still blocked on William's tracker.
- Next free migration: 000028.
- HOURLY TICK: background subagent `sleep 3300` — re-arm on each completion (agent just fired at this update; re-arming now).
- Gotchas: STATE.md pushes stale open PRs (branch-protection up-to-date); Devin verdicts may land on PRs not in session log — check gh pr view comments.
## Lessons (do not repeat)
- CI: a suite step that only checks `! grep FAIL` passes on an empty log. My conflict-resolution script once dropped the cadence suite and emptied the notifications step while CI stayed green. Now `app/tests/check_ci_workflow.py` runs first in CI and enforces one suite per step plus FAIL and PASS assertions. Resolve e2e.yml conflicts by hand-merging step bodies, then run the checker.
- UI screens: writes ONLY through RPCs. No direct-table fallback when an RPC is missing, because it skips RPC-side validation (caught on #75). Put this rule in every screen prompt.
- Before re-spawning a rate-limited agent, confirm it is actually dead (read_subagent). I once ran two W2-06 agents in one worktree.
- Orchestrator migrations go through a PR and Devin review like everything else, not straight to main.
- `gh issue view` is broken on this repo (Projects-classic GraphQL). Use `gh api repos/vulcanhelix/securepath-privacy/issues/N`.
- Check issue numbers against titles before writing a prompt (I once gave W2-11 #35 instead of #36).

