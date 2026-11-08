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

## In-flight / last update (2026-11-07e)
- MERGED: ~46/51 — everything through #112 (ten-PR integration) + earlier waves. Board: https://github.com/vulcanhelix/securepath-privacy/milestone/1
- MERGED #113 W2-17 team+licence (000028) at 675c8ba after ~6 staleness reruns — lesson: no main commits between update and merge.
- IN REVIEW: #114 W2-03 branding (000029 + 000031 practices UPDATE-revoke fix) re-check sent; #115 W2-02 onboarding wizard (000030 rebased onto merged 000020, 14-param create_client_org) sent for first review.
- BUILDING: none this instant — next wave: W2-15 brand consumption, W4-04 client exit, W4-07 AT suite, W4-02?, W4-09 storage signed links. W3-02 blocked on William's tracker; W5 = William's tooling.
- OPEN INVESTIGATION: 4 pre-existing date-sensitive FAILs in e2e_rules_engine(3) + e2e_scheduler(1) — real issue, needs an agent (not a rerun).
- Next free migration: 000032 (000028=#113, 000029=#114 branding, 000030=#115, 000031=#114's write-close fix).
- Devin review session: a81e22c41da44e05b7b640c546d54de9 via ~/.claude/skills/devin-chat/scripts/devin.py; gate = CI green + Devin APPROVE.
- Wakes: watcher subagents poll runs and report (real). Hourly tick = sleep-3300 subagent, re-arm each completion. Treadmill: up-to-date-heads protection stales PRs on every main commit → fold approved heads into int/waveN branches and merge once.
## Lessons (do not repeat)
- CI: a suite step that only checks `! grep FAIL` passes on an empty log. My conflict-resolution script once dropped the cadence suite and emptied the notifications step while CI stayed green. Now `app/tests/check_ci_workflow.py` runs first in CI and enforces one suite per step plus FAIL and PASS assertions. Resolve e2e.yml conflicts by hand-merging step bodies, then run the checker.
- UI screens: writes ONLY through RPCs. No direct-table fallback when an RPC is missing, because it skips RPC-side validation (caught on #75). Put this rule in every screen prompt.
- Before re-spawning a rate-limited agent, confirm it is actually dead (read_subagent). I once ran two W2-06 agents in one worktree.
- Orchestrator migrations go through a PR and Devin review like everything else, not straight to main.
- `gh issue view` is broken on this repo (Projects-classic GraphQL). Use `gh api repos/vulcanhelix/securepath-privacy/issues/N`.
- Check issue numbers against titles before writing a prompt (I once gave W2-11 #35 instead of #36).


## In-flight / last update (2026-11-07h — wave-3 landed)
- MERGED #119 int/wave3 at 04e2404 — auto-closed #115 #116 #117 #118.
  Board: onboarding wizard + brand consumption + client exit + AT suite all
  on main. 29 CI suites. ~52/51 — the planned board is COMPLETE.
- LANDED ALONG THE WAY: fixture-wipe hardening (runtime-created non-cascade
  rows: billing_events/invites/notifications/approvals + guarded W4-04
  exits/certs with immutable-trigger suspension); middleware Host-header
  redirect fix; suite-order decoupling (licence tiles, template count).
- IN REVIEW/CI: #120 tick-isolation (ALTER DATABASE GUC before first suite;
  scoped claimed-count; txn-local snapshot deletes). Proven failure mode.
- DIAGNOSIS VALIDATED: 'date-sensitive' FAILs were real-clock pg_cron ticks
  mutating TESTFIX mid-suite — harness bug, no product defect.
- REMAINING (post-board): W4-09 storage signed links (queued), W3-02 blocked
  on William's tracker file, W5 = William's own tools. Launch blockers are
  now content+ops: POPIA template, first client, hosting decision, pen test.
## In-flight / last update (2026-11-07f — post-restart recovery)
- RESTART: user restarted Devin; subagent fleet died. Recovered from this file +
  live gh/Devin state. Watcher/tick subagents re-armed same session.
- MERGED #114 W2-03 branding settings at cc8b09f (Devin APPROVE incl. the
  000031 practices UPDATE-revoke fix — direct branding writes now impossible).
- #115 W2-02 onboarding: Devin APPROVE; first CI red was suite-order coupling,
  not app code — lifecycle suite publishes TESTFIX v1.1 (immutable → wizard
  offers 2 versions) and the onboarded client bumps licence tiles to n/2.
  Specs fixed at f0fb736 (select v1 by id; tile asserts `n / 2`); CI armed.
- STATE.md REGRESSION FOUND: merging branches that carry an old STATE.md
  reverted main's copy (main showed the 2026-11-05 version). Fix landed via
  THIS branch — refreshed handover rides in with #115. Rule: feature branches
  must merge origin/main's STATE.md before push, or drop their STATE.md edit.
- Board: ~48/51 after #114; #115 → ~49/51. Remaining queued: W2-15 brand
  consumption, W4-04 client exit (000032), W4-07 AT suite (000033), then the
  OPEN date-sensitive suite FAILs (rules_engine x3, scheduler x1).
- Next free migration: 000032.

## In-flight / last update (2026-11-07g — wave-3 integration)
- RESTART-RECOVERY COMPLETE: fleet rebuilt after Devin restart; all work resumed.
- #115 suite-order fixes: onboarding.spec bumps Partner A licence caps to 10 +
  creates a 3rd client early in the browser run — every later spec sees 3/10
  not 2/2, and the lifecycle suite's published v1.1 means the wizard offers 2
  template versions. Three spec fixes (deterministic template id, usage/cap
  regexes, cap-pin for the W1-07 warning leg) + a PARTNER_A local-const fix.
- #116 middleware bug found by its own CI: req.nextUrl behind Caddy carries
  the internal upstream host → deep links lost the partner host. Fixed by
  reading Host/x-forwarded-proto headers directly (c737460).
- #118 writes.spec accept-leg timeout was a flake — rerun green.
- #117 trigger-suspension completeness verified by Devin independently.
- PR #119 int/wave3 = all four heads; merges on green → ~52/51 done.
- REMAINING: date-sensitive FAIL diagnosis (agent out); W3-02 blocked on
  William's tracker; W4-09 storage signed links queued; W5 = William's tools.
- Next free migration: 000035.

## In-flight / last update (2026-11-07j — W4-09 delivered)
- #121 W4-09 signed links in review+CI: presigned GET (60s) + PUT (300s,
  checksum-enforced) for documents/evidence; scan-quarantine 403; no
  migration needed; byte-parity + tamper + cross-tenant legs proven.
- OPS FOLLOW-UP for staging: signed URLs need S3_BROWSER_ENDPOINT —
  staging MinIO is loopback-only today; needs a browser-reachable
  endpoint (Caddy → minio) + the env var before signed links work there.
- This is the last unblocked engineering item. After it lands, remaining
  work is William-side: POPIA template content, first-client tracker,
  hosting decision + s21 operator agreement, SSO decision, W5 tooling.
## In-flight / last update (2026-11-07i — board closed out)
- MERGED #120 tick-isolation at 5768cf3 — 'date-sensitive' FAILs fixed at the
  harness level (DB-level GUC before first suite; scoped claimed-counts;
  txn-local orphan-snapshot deletes). CI now 29 suites, all green.
- BOARD COMPLETE: every planned W-item through W4-07 is on main. Open PRs:
  none (only ancient #1/#2 unrelated).
- BUILDING: W4-09 evidence-storage signed links (agent out, migration 000035).
- WILLIAM-SIDE / external (not agent work): POPIA template content, first
  client tracker (W3-02 #43), SA production hosting decision + s21 operator
  agreement, SSO decision (#49 deferred), W5 tooling (#57/#58 his side),
  pen test + backup/restore before first real client.
- Next free migration: 000036 if W4-09 takes 000035.

## In-flight / last update (2026-11-07k — ALL engineering merged)
- MERGED #121 W4-09 signed links at 75adafd — presigned GET (60s) + PUT
  (300s, checksum-enforced, store-verified) for documents/evidence; scan
  quarantine 403; key = client_org/sha256; byte-parity proven.
- STATE: no engineering PRs remain open (only ancient #1/#2 unrelated).
  Every planned v0.2 work item + NFR gap items through W4-09 are on main.
- STAGING DEPLOYED 2026-11-08: all 34 pending migrations (20261105000001
  →20261106000034) applied via supabase_admin, pgrst schema reloaded,
  rest container restarted; web rebuilt+deployed (deploy-web.sh) after
  npm ci for @aws-sdk/s3-request-presigner. DB 33→82 tables, 354
  routines. Smoke: /login 200, /rest/v1 200, service active. Backup at
  /root/securepath-staging-backup-20261108-0602.dump. pg_cron tick armed.
- STAGING SIGNED LINKS LIVE 2026-11-08: S3_BROWSER_ENDPOINT=
  https://securepath.dev set in /opt/securepath/web.env; Caddyfile route
  `handle /securepath-documents/* -> 127.0.0.1:9000` (plain handle, NO
  rewrite — SigV4 signs the path; console 9001 stays loopback). Verified:
  unsigned probe reaches MinIO (403 + x-amz-request-id), /login 200.
  No DNS change needed — path-style bucket route on existing domain.
- WILLIAM-SIDE (the actual launch blockers now): POPIA programme template
  content, first-client tracker (W3-02 #43), SA production provider +
  s21 operator agreement, SSO decision (#49), W5 tooling (#57/#58),
  pen test + backup/restore before first real client.
- UAT PROCESS — LIVE 2026-11-08 (not just designed, built + verified):
  tools/uat/uat_watcher.py + systemd timer uat-watcher.timer (5min poll).
  Config: ~/.secrets/linear.env (LINEAR_API_KEY), workspace
  GrowthstrategyHQ, team GRO, label `uat` gates intake, "UAT report"
  issue template created (structured Qs). Flow: ticket w/ uat label →
  Devin triage (reject only w/ spec citation, else accept) → accept =
  GH issue uat-ticket+uat-confirmed → fix session (branch uat/N, tests,
  ~30s playwright video) → video uploaded to Linear (fileUpload→GCS PUT)
  → tester approval (is_approval: positive word + no negation; 48h
  nudge; `uat-trivial` skips gate) → "UAT APPROVED — open PR" → PR →
  merge on green CI+review. Pushback → gentle comment + ntfy to Bruce;
  tester reply re-triages once. Verified end-to-end on GRO-5 (pushback
  path: MFA-code report correctly declined citing NFR-03/FR-ONB-04).
  Accept path mechanics unit-verified (upload PUT 200, approval regex).
  MANUAL STEP: invite tester + William to the GRO Linear workspace
  (Settings → Members — invites are not API-exposed).
