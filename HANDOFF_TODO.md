# SecurePath — Handoff TODO

Complete list of what remains, including shortcuts taken during the pipeline build. Honest and specific. Grouped by area; each item has enough context + file paths + acceptance criteria to action without the original author.

Context: staging is LIVE at securepath.dev. Apply migrations as `supabase_admin` (see `staging/README.md`). All work from this build sits on branch `fix/assessment-rpc-authz` (PR #3). Every SECURITY DEFINER RPC touching tenant data MUST guard `allowed_client_orgs()` / `current_practice()` — no exceptions.

---

## A. Git / PR hygiene (do first)

- [x] **Split the security fix out of PR #3.** Commit `6faf6c3` (fix: assessment RPC authz) is a live cross-tenant hole fix tangled into an 18-commit feature PR. Cherry-pick it onto its own branch, open a small PR, merge immediately, rebase PR #3 on top. Acceptance: security fix mergeable independently of the pipeline features.
  - ✅ DONE (2026-08-12): commit cherry-picked to `fix/assessment-rpc-authz-hotfix`, PR #4 open (merge blocked from agent session — one click needed), PR #3 branch rebased on top locally.
- [ ] **Review + merge or close the two Devin branches on GitHub:** `devin/1786138517-chat-assessment` (AI chat-assessment mode, ~1,100 lines, uses **OpenAI** — see item D) and `devin/update-skills-1786274420` (testing skill). The chat branch was reviewed as safe *pending the base security fix*; re-verify after A.1 merges.
- [x] **No CI.** Wire GitHub Actions (or equivalent) to run `app/tests/e2e_isolation.py` (22/22) + `app/tests/e2e_pipeline.py` (36/36) against an ephemeral or staging stack on every PR/migration. Acceptance: red build blocks merge.
  - ✅ DONE pending first push (2026-08-12): `.github/workflows/e2e.yml` — ephemeral compose stack + all migrations + Next + Caddy, runs both suites per PR. Branch protection (red blocks merge) still needs a repo-settings click.

---

## B. Track / stage model gaps (correctness — these are real shortcuts)

- [x] **Privacy track is created lazily at Gate 1 sign-off**, so the first stage transition logs `0→2` instead of `1→2`. The track should be created at **Stage 0** (client creation, in `create_client_org`) or at assessment start, initialised at stage 1. Files: `app/supabase/migrations/20260729000003...` (`create_client_org`), `20260811000002...` (`sign_off_assessment`). Acceptance: a new client has a privacy track at stage 0/1 before assessment; Gate 1 logs `1→2`.
  - ✅ DONE (2026-08-12): `20260812000003` — both tracks created in `create_client_org` (+backfill); `create_assessment` advances 0→1; Gate 1 logs 1→2. e2e-verified on staging.
- [x] **Cyber track cannot complete Gate 1.** `sign_off_assessment` (migration `20260811000002`) hardcodes the **privacy** track (`track_kind='privacy'`). A `cyber_essentials`/`iso27701` assessment can be created and scored but cannot be signed off or advanced. Make sign-off resolve the track from the assessment's framework → track_kind. Acceptance: a cyber assessment signs off and advances a cyber track.
  - ✅ DONE (2026-08-12): `sign_off_assessment` resolves track from `frameworks.track_kind`. Cyber sign-off verified.
- [x] **New-assessment page only offers POPIA/GDPR.** `web/app/assessments/new/page.tsx` framework `<select>` has `popia`/`gdpr` only — cannot start a `cyber_essentials`, `iso27701`, or `paia` assessment from the UI. Populate the dropdown from the `frameworks` table. Acceptance: any registered framework is selectable.
  - ✅ DONE (2026-08-12): dropdown fed by `list_assessable_frameworks()` RPC via `/api/frameworks` (only frameworks with questions).
- [x] **track_kind is derived by a hardcoded array** in each Stage 2–6 page (`['cyber_essentials','iso27701'].includes(framework) ? 'cyber' : 'privacy'`). Source it from `frameworks.track_kind` instead (single source of truth). Files: `web/app/clients/[id]/{documents,policies,manual,tasks}/page.tsx`.
  - ✅ DONE (2026-08-12): `web/lib/track.ts` `trackKindFor()` reads `frameworks.track_kind`; all 4 pages updated.
- [x] **Baseline is read live, not snapshotted.** The monthly report reads the Stage 1 score at compile time; if the assessment is edited after sign-off, the "baseline" drifts. Snapshot `baseline_pct`/`rating` onto the track (or a baselines table) at Gate 1 sign-off and read that everywhere. Acceptance: baseline is immutable after sign-off.
  - ✅ DONE (2026-08-12): `tracks.baseline_*` snapshotted at first sign-off (immutable), report compile reads the snapshot; existing sign-offs backfilled.

---

## C. Content depth (all current seeds are thin/starter — need the real libraries)

Sources are in `docs/extracted/` (salvaged prototypes) and `docs/`.

- [x] **Policy templates: only 5 skeletons** (`20260811000003`). Extract the full POPIA policy library from the **PIM Generator** prototype (`docs/extracted/PIM Generator/PIM_Generator_Offline.html`, the `STEPS` wizard + document assembly). All INSERTs into `policy_templates`.
  - ✅ DONE (2026-08-12): `20260813000001` — 21 new templates from the PIM Generator (26 POPIA total), all mapped to checklist slots.
- [x] **Task library: 18 tasks** (`20260811000006`). Extract the full **~100-task tiered (Tier 1/2/3) remediation programme** from `docs/extracted/Implementation App/PrivacyFramework.html` (`PHASES` array — id/task/responsible/timeframe/output/priority/tier). Note: tasks need a **tier** dimension not yet modelled (`task_templates` has no tier column). Add it + filter by company headcount.
  - ✅ DONE (2026-08-12): `20260813000002` — 90 new tasks from PrivacyFramework.html (108 total), `tier` column added (tier = min company size band; headcount filter in UI still TODO).
- [x] **Cyber Essentials: 10-question focused seed** (`20260812000001`). Extract the full **87-question CE bank** (with `ceRef` + SA `saNote` overlays) from `docs/extracted/CE-SA-App/`. Plus fuller CE checklist/policies/tasks.
  - ✅ DONE (2026-08-12): `20260813000003` — 78 new CE questions (88 total, CE v3.2 bank incl. saNote overlays). Editorial pass on inverted-polarity questions + Critical flags suggested.
- [ ] **POPIA checklist (31 items)** is from the real framework but **William should confirm/refine** the authoritative list. It's content — one migration.
- [x] **GDPR: only 3 orphan questions exist** (pre-existing). Either build a real GDPR pack from `docs/assessment-sheets/Audit_GDPR_DUAA_ISO27701_Section_*.xlsx` (6 sheets) or remove the stub. The GDPR Assessment App (`docs/extracted/GDPR Assessment App/`) has 77 questions + scoring.
  - ✅ DONE (2026-08-12): `20260813000004` — 77-question GDPR pack from GDPR_Audit_Tool_v4. The 3 orphans are inactive rows on staging only (never render); optional manual delete documented.
- [ ] **PAIA and ISO 27701 frameworks are registered but have no content packs** (no questions/checklist/templates/outline/tasks). Build or remove.
- [ ] **The missing POPIA prototype** (`Popi and PIA app/src/app.html` + `POPI Self Assessment/` folder) was never in the salvaged zip — it's still in the OneDrive source. Bruce to re-download; may contain the authoritative POPIA question bank/checklist to reconcile against Devin's 86.
- [ ] **Verify scoring parity against the real spreadsheets.** Devin claimed exact parity with the desktop/Excel scoring; no test proves it against the actual `.xlsx`. Add a test that scores a known filled sheet and asserts the platform matches.

---

## D. AI features (deferred — need an API key; use CLAUDE, not OpenAI)

Platform guidance: default to Claude (Anthropic API) for new AI features. Devin's branch uses the OpenAI adapter — do **not** adopt that; port to Claude.

- [ ] **Stage 1 AI exec summary + remediation roadmap** from scored results, through the approval gate (spec §3 Stage 1). Currently absent.
- [ ] **Stage 3 AI policy drafting** — replace template-fill with a real Claude draft per gap (Draft(AI) status → human approval). `policies.approval_status` already supports `draft_ai`.
- [ ] **Stage 6 AI report narrative** — replace the templated narrative in `web/app/api/clients/[id]/report/compile/route.ts` with a Claude-generated, section-by-section, editable/regenerable narrative showing movement vs baseline (spec §6 report studio).
- [ ] **Document classification** — currently a filename token-match heuristic (`web/lib/classify.ts`). Upgrade to a Claude content-classifier that reads the uploaded document body when accuracy warrants it.

---

## E. Stage-specific spec items not built

- [ ] **Stage 2 "conversion run" (spec §3 Stage 2 trigger).** Signing off the assessment should **seed** candidate ROPA entries, the expected-document checklist state, and initial tasks from the assessment answers. Currently everything is manual after sign-off. Wire it into `sign_off_assessment` or a follow-on RPC.
- [ ] **Stage 5 magic-link task pages for client staff** (spec §3 Stage 5). Token like invites, no full login; per-task evidence upload. `tasks.evidence_document_id` column exists but there is no UI/flow. Build `/task/[token]` pages + a task-token table + evidence upload.
- [ ] **Stage 5 gap-vs-baseline progress.** Spec wants "every closed gap links back to the assessment question it answers" and progress like "14 of 23 gaps closed" against the Stage 1 baseline. Current board shows tasks-done, not gaps-closed-vs-baseline. Add task↔assessment_question linkage + baseline-relative progress.
- [ ] **Registers UI (spec §5 item 11): ROPA, DSAR cases, document library management.** These domain tables **don't exist yet** (only `documents`/`document_links`). Build `ropa`, `dsar_cases` (with statutory clock) tables + RLS + screens. DSAR case management with the statutory response clock is a whole spec feature (F6) not started.
- [ ] **Stage 6 cross-client practice console** (spec §3 Stage 6 frontend): month-status-per-client overview, overdue flags, report pipeline. Not built.
- [ ] **Stage 6 per-client monthly view:** this month's tasks, DSAR cases, incidents, register changes. Not built (report studio exists, this dashboard doesn't).
- [ ] **Annual reassessment loop (Stage 6 → Stage 1).** Delta report vs baseline feeding renewal. Not built.
- [ ] **Two experience levels (spec §6).** Client-side users (`client_admin`/`client_contributor`) should get a simplified read: where they are in the journey, what's needed from them, their documents. No tailored client UI exists — they'd see the advisor console.

---

## F. Output format

- [ ] **Issued docs are markdown, spec wants branded DOCX/PDF.** Policies, manuals, and monthly reports are rendered to `.md` in storage (`issue_policy`, `sign_off_manual`, `issue_monthly_report` + their API routes). Render branded DOCX/PDF (practice logo/accent from `practices`) instead. The PIM Generator prototype already does docx.js — reuse.

---

## G. Prod hardening / infra (deliberately deferred)

- [ ] **aal2 enforcement is app-layer only.** Middleware forces 2FA for pages/API, but a direct PostgREST call with an aal1 JWT still passes RLS. Add `aal2` checks in RLS policies before prod. Files: RLS policies across migrations; `web/middleware.ts`.
- [ ] **Provision af-south-1 production** (runbook `app/README.md`). Same compose, fresh secrets, DNS flip. Point `S3_*` at real AWS S3 af-south-1 (storage is already portable — no code change).
- [ ] **Stripe billing** against the `billing_events` ledger (manual billing now).
- [ ] **Backups:** WAL-G / pgBackRest → S3 af-south-1 (never cross-region).
- [ ] **Rotate staging secrets** as policy (JWT secret + DB password were briefly in an early local commit, rewritten before push — local-only, but rotate at prod cutover).
- [ ] **Entra ID SSO** via WorkOS (spec F1.4, "should").
- [ ] **Real product name → domain** (SecurePath is a placeholder).

---

## H. Bugs / polish observed

- [x] **Auto-classify proposal doesn't pre-select in the UI.** On upload the API returns a proposed slot and writes a `proposed` `document_link`, but the intake dropdown showed "unassigned" on first render (observed in browser). The `initial()` value in `web/app/clients/[id]/documents/intake.tsx` may not reflect the freshly-written proposal after `router.refresh()`. Investigate + fix so the suggestion pre-fills.
  - ✅ DONE (2026-08-12): `intake.tsx` — selection now derives from fresh props after router.refresh(); state keeps only explicit user choices. Root cause: `sel` state was seeded once at mount, so rows added by refresh fell back to ''.
- [x] **e2e_pipeline.py leaves test data.** Cleanup is a documented psql snippet (`app/tests/E2E_PIPELINE.md`), not automated teardown. Add a teardown step (needs a delete path or admin cleanup).
  - ✅ DONE (2026-08-12): `app/tests/cleanup_e2e.sh` (automated teardown, handles the tracks↔sessions FK cycle, also catches isolation-suite practices).
- [ ] **Leftover test tenant** `Acme MSP 557feb` on staging from an early e2e run — harmless, delete when convenient.
- [ ] **Assessment answering is one-by-one, 89 questions.** No bulk/keyboard entry; tedious for real use. Consider section-level bulk actions.

---

## Priority order (suggested)

1. **A** (split security PR, CI) — hygiene + safety.
2. **B** (track/stage correctness) — small, fixes real bugs, unblocks the cyber track properly.
3. **C** (content depth) — mostly INSERTs, high product value, low risk.
4. **D** (AI, needs key) + **F** (DOCX/PDF) — the "real deliverable" polish.
5. **E** (missing spec features: DSAR/ROPA registers, magic-link tasks, cross-client console, annual loop) — the remaining product surface.
6. **G** (prod hardening) — when moving off staging.
