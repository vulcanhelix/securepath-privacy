# SecurePath R1 — Orchestrated Build Plan (v2)

> **Purpose.** End-to-end execution plan for spec SP-SPC-PLT-001 v0.2
> (`docs/spec/`) built on the existing platform, run by one orchestrator session
> driving sub-agent sessions on two model tiers.
> Spec source of truth: `docs/spec/SP-SPC-PLT-001_v0_2.docx` (+ extracted `.txt`).
>
> **v2 changes** — after adversarial review against the spec. Key corrections:
> (1) the spec's role model cannot be expressed by `memberships` — W0-00 is now an
> authz remodel, the gate for everything; (2) scheduler substrate didn't exist —
> pg_cron 1.6 confirmed available in the staging image, W1-09 builds the runner;
> (3) ~15 schema gaps added to W0; (4) browser-harness item added (no Playwright
> exists today); (5) fixture pack added — most ATs are unrunnable without it;
> (6) model re-tiering: auth/deletion/audit/suspension items moved to MAX;
> (7) tracking upgraded — derived statuses, conflict map, review lint rules.

## 0. Operating model

- **Orchestrator** (this session): owns the backlog, writes ALL migrations,
  spawns sub-agents, reviews every diff, runs every acceptance check, merges serially.
- **Sub-agents**: stateless. Everything they need goes in the prompt packet (§7).
  They get a worktree + branch + a runnable acceptance check. Never touch `main`,
  never write migrations, never edit shared files (§5 conflict map).
- **Model tiers**:
  - **[MAX] SWE-2 Max** — schema, business-rule engines, anything touching
    authorization, evidence chain, deletion, audit integrity, imports/
    reconciliation, scheduler, template engine, AT suite.
  - **[FLASH] SWE-2 Flash Max** — CRUD screens, straightforward RPCs, exports,
    content tooling. Volume work on proven patterns.
- **The check is the task.** Every item carries a runnable acceptance: e2e scenario,
  psql assertion, or API/UI verification. CI green (`e2e_isolation.py`,
  `e2e_pipeline.py`) after every merge — never sacrifice it.
- **VERIFIED means**: merged to main AND its acceptance green against staging.
- **Hard rules for every agent** (in every prompt):
  - Every SECURITY DEFINER RPC touching tenant data MUST call the role predicate
    helpers in its body (definer bypasses RLS).
  - Append-only ledgers: no UPDATE/DELETE paths.
  - Server-side URLs always via `BASE_URL`.
  - `supabase start` blocked on this host. Dev DB :54322; staging via `staging/`
    compose; migrations applied as `supabase_admin`.
  - No legal period/deadline/statutory reference hard-coded (FR-TPL-08) — all from
    `jurisdiction_packs`/templates. Enforced by lint (§8).
  - No wording anywhere implying certification or compliance-by-use (§5.5) —
    enforced by review.
  - All rule functions take `p_now` (clock-injectable) so the AT suite can test
    past-due/overdue/month-boundary behaviour deterministically.
  - Timestamps stored UTC, displayed in the client's time zone (NFR-10).

## 1. What already exists — honest version

| Existing | Reality vs v0.2 |
|---|---|
| `practices`, `client_orgs`, invites, RLS, TOTP MFA | Skeleton reuse: partner/client shells, branded invites, MFA (FR-ACC-06). `memberships` does NOT survive — see W0-00. |
| `practices.name/logo_url/accent_hex` | Branding seed; needs ~10 more fields (W0-01). |
| `billing_events` | Event log only (`instance.created/deleted`, no policies). FR-LIC-02 needs a usage roll-up + monthly job — a seed, not a ledger. |
| `frameworks` + `content_packs` | Registry pattern reused for `programme_templates`; content shape is different (§5.1). |
| `tracks`, `stage_transitions` | Programme lineage — mapping decided in W0-04 pending William's answer. |
| `documents` + S3 (`storage.ts`, `/api/documents`) | Evidence file store. Streams through server; NFR-02 signed-link/direct-upload path is W4-09. |
| `assessment_*`, `assessment_reports` | Findings source for FR-IMP-02; outside R1 core. |
| `awareness_*` | FR-TRN-02/NFR-15/AT-22 — DONE as spec'd. |
| `monthly_reports` | Rewrite: no snapshot FK, sections, signatures, AO review, due/late fields. `programme_reports` replaces it (W0-02); do not claim reuse. |
| `notifications` + Resend | Practice-broadcast table — no per-user rows, prefs, or email state. Rebuild (W0-02 + W1-08). |
| `e2e_isolation.py` 22/22 | Proves isolation of the OLD role model. Will break under W0-00 — port, don't extend. |
| `/team` page | Exists but bound to old role CHECKs — rebuilt in W2-17. |

## 2. Wave map

```
W0  Schema + authz remodel + fixtures   [orchestrator, MAX, SERIAL]
W1  Domain engines + RPCs + runner      [10 sessions]
W2  Shared shell → screens              [17 sessions]
W3  Imports · reports · exports         [5 sessions]
W4  NFR hardening + AT suite            [9 sessions]
W5  Content tooling (William-facing)    [2 sessions, alongside W3/W4]
```

## 3. W0 — Schema foundation (orchestrator only, MAX, serial)

| ID | Scope | Spec refs | Acceptance |
|---|---|---|---|
| W0-00 | **Authz remodel.** New `role_assignments(user, level[platform/partner/client], role, scope[partner/client/programme/workstream], scope_id, start_date, end_date)`; rewrite `current_practice()`, `current_role_name()`, `allowed_client_orgs()` (+ new scope predicates); port EVERY RLS policy and role-checking RPC; rework `invites`; re-baseline `e2e_isolation.py` to the new roles. Define the **policy template catalogue**: client-scope / programme-scope / workstream-scope / item-scope / designation-gated — every later table names which template it uses. | §4, §6.1, FR-ACC-04/05 | All existing tests ported+green; multi-role user works; expired end_date denied (FR-ACC-05) |
| W0-01 | Platform tier + entity ALTERs: `jurisdiction_packs`(+SA/UK shells, incl. timezone + holiday calendar), `licences`(+plan, limits, term, **attribution-display flag set by SecurePath — FR-BRN-05**), `designations`(+named-alternate kind), `support_access_grants`. ALTER `client_orgs` (+jurisdiction, sites, headcount_in_scope, legal/trading name, reg no, sector, data_region, timezone). ALTER `practices` (+type incl. SecurePath Direct, country, status, primary_contact, subdomain, sender_name/domain, sign_in_text, support_contact, report_template_refs, attribution flag, region default, EV-ref format). ALTER `users` (+status, last_sign_in, org). | §4, §5.4, §6.1 | applies; field-by-field checklist vs §6.1 mapped to columns |
| W0-02 | Programme engine: `programmes`(+thresholds: red_days, report_due_bd, reduced_capacity_weeks; +programme_rag manual), `phases`, `workstreams`(+rag_override+reason), `activities`(+deps), `activity_status_history` (append-only), `register_items`(+activity m2m), `evidence_items`(+site), `evidence_reviews`(outcome enum: closes/partly-supports/kpi-evidence), `evidence_offers` (cross-programme), `weekly_logs`, `kpis`, `kpi_actuals`, `raid_items`, `decisions`, `maintenance_task_templates`, `maintenance_task_instances`, `checklist_instances` (quarterly/annual), `operational_records`, `external_providers` (named contacts + channel), `training_records`, `controlled_documents`, `monthly_snapshots`(**JSONB contract defined here**), `programme_reports`(+reference, snapshot_fk, sections, signatures, workflow, due/late), `notification_events`(outbox), `notification_preferences`, `scheduled_jobs`, `job_runs`. | §6.2, §9, §10 | applies; each table declares its policy template; calc fields write-protected (trigger/privilege); Deferred status included (§15-#13 — build it, flag to William) |
| W0-03 | Template engine: `programme_templates`, `programme_template_versions`(draft/published/retired, release notes, structured §5.1 content), `requirement_mappings`, `import_runs`, `import_rows`. | §5, §13 | applies; published version immutable |
| W0-04 | Evolution: `tracks`→`programmes` mapping/migration, `monthly_reports`→`programme_reports`, `audit_log`→`audit_events` field-level triggers (deployed later in W4-06, designed here), keep all current tests green. | §6 | legacy clients readable; suite green |
| W0-05 | **Fixture pack**: fixture jurisdiction values (clearly labelled test data — holiday calendar, DSR/breach periods), minimal POPIA template seed (subset of 59/24/13/19 for tests), 2 partners + 3 clients seed for AT suite. | §14 | AT suite can run without William's content |

## 4. W1–W5 — sessions

### W1 — Domain engines + RPCs

| ID | Model | Scope | Spec refs | Deps | Acceptance |
|---|---|---|---|---|---|
| W1-01 | MAX | §9 rules engine: 9.1 week/date/month/phase/business-day calcs, 9.2 activity RAG (incl. Deferred), 9.3 register status/overdue, 9.4 closure, 9.5 snapshot writer, 9.6 workstream/programme/partner RAG, 9.7 deadline resolution, 9.8 licence counting (pure function — W1-07 consumes). All `p_now`-injectable. | §9 | W0-02 | unit tests; AT-11/12/17 fixtures |
| W1-02 | MAX | Evidence chain: upload→verify(checklist)→accept/return, EV-ref minting per partner format, self-verify/self-accept ban (FR-ACC-01), AO-alternate routing (FR-EVD-07), **only AO/named-alternate may close a register item (FR-ACC-02)**, register closure on accept, cross-programme `evidence_offers` flow (separate acceptance per programme). Accepted evidence is versioned, never edited (NFR-09). | §8.4, §9.4, FR-ACC-02, FR-TPL-07, NFR-09 | W0-02 | AT-13/14 + offer flow test + closure restricted to AO/alternate |
| W1-03 | MAX | **Cadence engine**: monthly maintenance generation (timing rules, windows, active-from, provider input-requests with persisted providers, exception→RAID, report gating FR-MNT-07, 12-mo history) AND quarterly/annual checklist + annual-review-task generation (FR-QTR-01/02). | §8.9, §8.11, Annex A | W0-02, W1-01 | AT-15/16 + cadence generation test |
| W1-04 | MAX | Operational registers: DSR/breach/disclosure/opt-out (client-level, shared across programmes), jurisdiction deadline calc, breach route, any-screen report RPC, **breach notification decision restricted to AO/alternate (FR-ACC-02)**. | §8.10, §9.7, FR-ACC-02 | W0-01, W0-02, W1-01 | AT-09/19 + decision restricted |
| W1-05 | MAX | Programme lifecycle: create-from-template-version, start-date recalc (FR-SCH-06), apply-template-version (FR-TPL-03), **in-programme add/edit/retire of activities/findings/KPIs/tasks (FR-TPL-04)**, close. | §3, §5.3, §7.3 | W0-03, W1-01 | AT-08; instantiate→recalc→retire round trip |
| W1-06 | FLASH | KPI/RAID/decisions/weekly-log/training/controlled-document RPCs; programme report `reference` minting; monthly report counts feeds. | §8.5/7/8/12/13 | W0-02 | per-entity tests |
| W1-07 | FLASH | Licences: consume §9.8 counter, onboarding block (FR-ONB-02), usage roll-up + monthly usage report data (FR-LIC-02), near-limit flag (§10). | §7.5, §9.8 | W0-01, W1-01 | AT-07 |
| W1-08 | MAX | Notification dispatch: `notification_events` outbox consumer, per-user prefs+digest, partner-branded email, breach-always-immediate, agenda email (FR-WKS-05), trigger wiring FROM the W1 engines (engines emit events; this dispatches). | §10 | W0-02, W1 engines emitting | breach immediate test; digest batch test |
| W1-09 | MAX | **Scheduler runner**: enable pg_cron (v1.6 in image — enable via shared_preload_libraries in compose) OR systemd-timer→internal RPC; `job_runs` lease/idempotency, per-client-TZ resolution, catch-up after downtime. Jobs: daily 06:00 recalc+digest, 1st BD task+report gen, last BD snapshot, Mon agenda, quarterly/annual, usage reports. | §10 | W0-02 | dry-run each job; catch-up test |

### W2 — Screens (W2-00 first; each needs its W1 dep)

| ID | Model | Screen | Deps | Acceptance |
|---|---|---|---|---|
| W2-00 | FLASH | **Shared shell**: regenerated DB types per merge, nav slots for 15 modules, brand context, "report a breach" mount point (FR-OPS-04), middleware hook points. Before all other W2. | W0-x | shell compiles; mount points documented |
| W2-01 | MAX | Partner console (screen 10): programme rows, tiles, filters, one-click open, workload view | W1-01, W1-03, W2-00 | AT-02; tiles match API data |
| W2-02 | FLASH | Client onboarding wizard (screen 11): 7 steps, jurisdiction-filtered templates, licence block, designations, invites | W0-01, W1-05, W1-07 | wizard creates programme e2e |
| W2-03 | FLASH | Branding settings (screen 12): all fields, live preview, WCAG contrast check, report-template upload | W0-01 | AT-06; settings persist |
| W2-15 | MAX | **Brand consumption**: sign-in page resolves partner by host/subdomain and renders brand; emails branded (with W1-08); report cover; **SecurePath attribution line rendered per licence flag (FR-BRN-05)**; support contact surfaced. Sender-domain verification (FR-BRN-03) = Resend domain-verify ops flow, deferred. Custom domains/auto-TLS = manual-approval flag (domains rule), subdomain only in R1. | W2-03, W1-08 | AT-05 sign-in+email+report |
| W2-04 | FLASH | Programme dashboard (screen 01) | W1-01 | tiles link to lists |
| W2-05 | MAX | Activity schedule + Gantt (screen 02) | W1-01, W1-05 | AT-11/12 visible; FR-SCH-04/05 |
| W2-06 | FLASH | Evidence review + capture (screens 03/08): queues, checklist, decisions, EV refs, **presigned direct upload (FR-EVD-02)** | W1-02, W4-09 | AT-13/14 flow |
| W2-07 | FLASH | Weekly session agenda + log (screen 04) | W1-01, W1-06 | FR-WKS-03 enforced |
| W2-08 | MAX | Monthly report builder (screen 05): snapshot-locked sections, inputs-outstanding, Draft→inputs→AO review→Signed→Issued, late flag. Issued reports locked — corrections are new versions (NFR-09). | W1-01, W1-03 | AT-17 + locked-after-issue |
| W2-09 | FLASH | Operational registers (screen 06) + breach-report button wiring | W1-04 | AT-09/19 UI |
| W2-10 | FLASH | Monthly Maintenance (screen 09) + quarterly/annual checklist surface | W1-03 | AT-15/16 UI |
| W2-11 | FLASH | KPIs + RAID/decisions UI | W1-06 | CRUD + AO target confirm |
| W2-12 | FLASH | Doc register + training + designations UI | W1-06 | CRUD; designation evidence |
| W2-13 | FLASH | Executive view + mobile 390px my-actions + camera capture | W1-01, W1-02 | read-only; 390px (manual or W4-00) |
| W2-14 | FLASH | Platform admin: partners CRUD, platform metrics, licence/issue UI wiring | W0-01 | CRUD works (publish→W3-05, grants→W4-01, suspend→W4-08) |
| W2-16 | FLASH | **Remediation register + programme item editor** (FR-REG-01..04, FR-TPL-04): register screen, add-finding, link activities | W1-01, W1-05 | register CRUD; closure blocked without accepted evidence |
| W2-17 | FLASH | Partner team + licence usage (FR-TEAM-01/02, FR-LIC-01): invite/remove (removal ends all access, logged), assign to clients, licence/limits/usage page, **user notification-prefs UI (digest opt-in, §10)** | W0-00, W1-07 | removal test; usage page matches counts; digest pref persists |

### W3 — Imports, reports, exports

| ID | Model | Scope | Deps | Acceptance |
|---|---|---|---|---|
| W3-01 | MAX | Import framework: parse/preview/reject-with-reasons; FR-IMP-01 findings, FR-IMP-04 tracker layout, **FR-IMP-02 assessment workbook (Should)** | W0-03, W1-05 | preview+rejects dry run |
| W3-02 | MAX | First-client migration + reconciliation report + sign-off + parallel-run support | W3-01 | AT-10 — **BLOCKED-EXT** (needs real tracker + POPIA template content) |
| W3-03 | MAX | Word/PDF outputs in partner template: monthly report, exec pack, quarterly checklist, annual report | W2-08, W2-03 | AT-18 |
| W3-04 | FLASH | Exports: evidence zip+index, programme Excel, maintenance history, portfolio report, usage report, audit CSV (admin-only) | W1 done | downloads; admin-gated |
| W3-05 | MAX | Template authoring I/O: structured import/export, publish numbered version, partner-visible diff, apply-to-programme, **partner-private variants (FR-TPL-05)** | W0-03, W1-05 | AT-08; spreadsheet round-trip |

### W4 — NFR hardening + acceptance

| ID | Model | Scope | Deps | Acceptance |
|---|---|---|---|---|
| W4-00 | FLASH | Browser harness: Playwright + CI job (until then, orchestrator spot-checks UI via playwright MCP) | W2-00 | one real UI test in CI |
| W4-01 | MAX | Support access grant e2e: request→client/partner approve→time-boxed→all actions visible | W0-01, W2-14 | AT-03/04 |
| W4-02 | MAX | SSO (WorkOS Entra+Google) + configurable idle timeout (30m default) | W0-00 | SSO login; timeout enforced |
| W4-03 | FLASH | Malware scan on upload (ClamAV sidecar) | — | EICAR rejected |
| W4-04 | MAX | Client exit: full export + timed deletion + deletion certificate | W0-x | AT-20 |
| W4-05 | MAX | Per-client data-region plumbing: region field honoured end-to-end (single-region deploy in R1 — **deviation, see §6**) | W0-01 | region enforced through stack |
| W4-06 | MAX | Field-level `audit_events` triggers on EVERY tenant table + admin extract | all migrations final | AT-21 + drift check (every tenant table has trigger) |
| W4-07 | MAX | **AT suite** `e2e_acceptance_v02.py` — AT-01..22 | all | 22/22 green = R1 done |
| W4-08 | MAX | Partner suspension enforcement (FR-PLT-06): GoTrue ban + middleware block, sign-in denied, data intact | W0-01, W0-00 | suspend→sign-in fails→reinstate works |
| W4-09 | MAX | Evidence storage per NFR-02: per-client encryption/prefix, short-lived signed links after permission check, direct-upload path | W0-02 | presigned upload+download flow |

### W5 — Content tooling

| ID | Model | Scope | Deps | Acceptance |
|---|---|---|---|---|
| W5-01 | FLASH | Template spreadsheet format + POPIA generalisation tooling (William authors) | W3-05 | round-trips through importer |
| W5-02 | FLASH | Jurisdiction-pack editor + verification checklist (deduped from old W2-14) | W0-01 | packs editable+versioned |

## 5. Sequencing + conflict map

1. **W0-00 is the hard gate** — nothing W1+ starts until the authz remodel is
   green, because every new policy/RPC depends on its predicates.
2. W1-01 first inside W1 (unblocks W1-03/04/05 + W2-01/04/05/07/08).
3. `notification_events` schema lands in W0-02; W1 engines emit events as they go;
   W1-08 consumes — no retrofit.
4. **Orchestrator-owned conflict zones** (no agent edits): `web/middleware.ts`,
   `web/lib/*`, `web/app/layout.tsx`, `globals.css`, any existing migration,
   `docker-compose.yml`, CI files. Agents request changes via the prompt packet —
   orchestrator applies.
5. **Schema requests**: if a session needs a column, it files it back to the
   orchestrator (never writes its own migration). Serialization acknowledged.
6. Batch small FLASH items in one worktree where they share a dep (e.g. W2-11+W2-12)
   — separate acceptance rows still apply.
7. Max ~5 agents in flight — review throughput is the bottleneck.
8. W3-02 + AT-10 marked **BLOCKED-EXT** until the real tracker + POPIA content exist.

## 6. Deviations / flags to raise with William

- **NFR-11**: spec wants per-client SA/UK storage in R1; plan delivers
  single-region (SA) + region plumbing. If he insists on UK residency at launch,
  a second region deploy is ops work, not code — get the call in writing.
- **NFR-02**: we stream evidence through the server today; plan adds signed links
  (W4-09). Interim is defensible, flagged here.
- **FR-BRN-02 custom domains**: subdomains R1; custom domain auto-TLS deferred —
  touches the domains hard-rule, manual approval required when done.
- **Spec ambiguities for him**: external providers/assessors as login users (MFA,
  seats) vs token links; "all staff report a breach" channel (login users vs
  anonymous form?); Deferred status confirmation (§15-#13 — we build it in).

## 7. Sub-agent prompt packet (template)

```
TASK: <ID> <one-line goal>
REPO: /root/securepath-privacy (branch from origin/main into .claude/worktrees/<id>)
SPEC: docs/spec/SP-SPC-PLT-001_v0_2.txt sections <…> — read first
CONTEXT: <tables/files/RPCs + which existing file to mimic>
ROLE PREDICATE: <which W0-00 policy template this module uses>
MUST: allowed_client_orgs guards · append-only · BASE_URL · no supabase start ·
      jurisdiction params never hard-coded · p_now on rule functions ·
      no certification wording (§5.5)
DO NOT: migrations (file schema requests back) · shared files (middleware.ts,
        web/lib/*, layout.tsx) · main branch
SCHEMA REQUESTS: <columns needed — orchestrator applies>
ACCEPTANCE: <exact command(s) + expected output>
DELIVER: diff summary + test output, then open a PR titled "<id>: <scope>"
         with "Closes #N" in the body. Never merge, never push to main,
         never edit the issue or tracker — the PR is your only status update.
```

## 8. Review lint (run on every diff before merge)

- Every new `SECURITY DEFINER` contains `allowed_client_orgs()`/`current_practice()`
  or its declared role predicate — `grep -L` lint.
- No UPDATE/DELETE grants on append-only tables.
- No bare integer day/period literals in new SQL touching deadlines (FR-TPL-08).
- Server-side links use `BASE_URL`.
- No "certified"/"compliant with" wording in user-facing strings (§5.5).
- New tenant table → audit trigger present (W4-06 drift check enforces globally).
- CI: `e2e_isolation.py` + `e2e_pipeline.py` green.

## 9. Tracking

- `docs/BACKLOG.md` — single live table: Status (TODO/IN-FLIGHT/REVIEW/MERGED/
  VERIFIED/**BLOCKED-EXT**), owner-agent, branch, size. Update per merge.
- `docs/status.sh` — derives IN-FLIGHT from `git worktree list`, MERGED from
  `git log origin/main`, VERIFIED from last green CI on the merge commit.
  Run it before trusting the column.
- `docs/STATE.md` — handover: last merge, in-flight agents+worktrees, next
  unblocked, open questions (incl. §6 deviations), pending schema-request queue,
  last-green CI commit.

## 10. Non-code deliverables (outside the agent pipeline, tracked here)

- NFR-07 penetration test (external, pre-launch + yearly).
- NFR-12/13 contract chain (SecurePath↔partner↔client, sub-processor list).
- NFR-16 availability + NFR-17 backups & quarterly restore test (ops).
- NFR-18 planning load figure — William's §15-#4 input.
- NFR-19 browser matrix + NFR-20 WCAG AA audit.
- William-owned: template content (5 of 6), jurisdiction values, §15 decisions,
  first-client agreement + the actual tracker file, Annex A reconciliation,
  licence/pricing model (affects `licences` schema — needed before W0-01 final).

## 11. First moves (after William confirms v0.2-under-pipeline)

1. Commit plan v2 + spec + backlog + status.sh to main.
2. W0-00 authz remodel (orchestrator) — the long pole; start immediately.
3. W0-01→05 serial behind it; W0-05 fixtures in parallel by a MAX agent.
4. Spawn W1-01 + W1-09 + W1-08-schema-portion once W0 lands.
5. `e2e_acceptance_v02.py` skeleton with all 22 pending — day one.
```

## 12. Spec coverage map (mechanically verified 2026-11-05)

Every FR/NFR/AT ID in the spec, mapped to owning session(s). Re-verify by grep'ing
the spec for `FR-[A-Z]+-\d+|NFR-\d+|AT-\d+` — 155 IDs total.

| Spec items | Owning session(s) |
|---|---|
| FR-ACC-01 self-verify/accept ban; FR-ACC-02 AO/alternate-only closure & breach decision; FR-ACC-04 assigned-clients only | W0-00, W1-02, W1-04 |
| FR-ACC-03 statutory designations; FR-ACC-05 expiring access; FR-ACC-06 MFA | W0-01, W0-00 (enforcement), W2-12 |
| FR-BRN-01..07 branding | W0-01 (fields), W2-03 (settings+contrast), W2-15 (consumption), W3-03 (report templates), W1-08 (branded mail) |
| FR-DSH-01..06 dashboard | W2-04 (data from W1-01) |
| FR-SCH-01..07 schedule/Gantt | W2-05; SCH-07 export W3-04 |
| FR-REG-01..04 register | W2-16, W1-02 (closure), W1-01 (overdue calc) |
| FR-EVD-01..07 evidence | W1-02, W2-06 (+W4-09 storage, W2-13 mobile capture) |
| FR-WKS-01..05 weekly session | W2-07; WKS-05 agenda mail W1-08 |
| FR-RPT-01..06 report builder | W2-08; RPT-05 outputs W3-03 |
| FR-KPI-01..04 | W1-06, W2-11 |
| FR-RAI-01..03 RAID/decisions | W1-06, W2-11 (agenda surface W2-07) |
| FR-MNT-01..10 maintenance | W1-03, W2-10 (MNT-09 console: W2-01) |
| FR-OPS-01..05 registers | W1-04, W2-09 (mount: W2-00; counts feed: W1-06) |
| FR-QTR-01/02 quarterly+annual | W1-03 (generation), W2-10 (UI), W3-03 (outputs) |
| FR-TRN-01 training records; FR-TRN-02 awareness | W1-06, W2-12; TRN-02 = awareness engine (built) |
| FR-DOC-01 document register | W1-06, W2-12 |
| FR-EXE-01 exec view | W2-13 |
| FR-MOB-01/02 mobile | W2-13 (+W4-00 harness) |
| FR-PCN-01..06 partner console | W2-01 |
| FR-ONB-01..05 onboarding | W2-02 (+W1-05, W1-07, W1-02 offers for ONB-05) |
| FR-TEAM-01/02 | W2-17 (+W0-00 role model) |
| FR-LIC-01/02 usage | W1-07, W2-17; LIC-03 Could — excluded R1 |
| FR-PLT-01..06 platform admin | W2-14, W4-01 (grants), W4-08 (suspend), W0-01/W0-03 (data) |
| FR-TPL-01..08 templates | W0-03, W1-05 (apply/edits), W3-05 (authoring/variants), W1-02 (TPL-07 offers); TPL-08 = hard rule + lint |
| FR-IMP-01/02/04/05 imports | W3-01, W3-02 (BLOCKED-EXT); IMP-03 Could — excluded R1 |
| §9 business rules (all) | W1-01 (engine); consumed by W1-03/04/05/07, W2 screens |
| §10 notifications + jobs | W0-02 (outbox/jobs tables), W1-08 (dispatch), W1-09 (runner) |
| §11 outputs | W3-03 (Word/PDF), W3-04 (exports), W4-06 (audit extract) |
| NFR-01 isolation | W0-00 (port) + e2e suites + AT-01/02 |
| NFR-02 evidence store | W4-09 (signed links/encryption); interim stream-through = §6 deviation |
| NFR-03 SSO; NFR-05 idle timeout | W4-02 |
| NFR-04 support access | W4-01 (+W0-00 platform level) |
| NFR-06 malware scan | W4-03 |
| NFR-08 audit append-only | W4-06 (+ledger rules) |
| NFR-09 locked evidence/reports | W1-02, W2-08 (versioned, never edited) |
| NFR-10 UTC/client-TZ | hard rule (§0) + client timezone (W0-01) |
| NFR-11 residency | W4-05 plumbing; single-region launch = §6 deviation |
| NFR-14 exit export/deletion | W4-04 |
| NFR-15 awareness averages | awareness engine (built) |
| NFR-12/13 contracts; NFR-07 pen test; NFR-16 availability; NFR-17 backups; NFR-18 load; NFR-19 browsers; NFR-20 WCAG | §10 non-code deliverables |
| AT-01..22 | W4-07 suite; per-scenario owners in each session's Acceptance |

Non-requirement spec inputs: §6 data model → W0-01/02/03 schema; §15 decisions →
STATE.md open questions (William-owned); Annex A tasks → W0-05 fixture + W1-03
engine input; Annex B screens → W2 sessions.
