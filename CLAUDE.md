# SecurePath Privacy Platform — Working Doc / Handover

> **What this is:** POPIA/GDPR compliance SaaS for MSP resellers and their SMB clients. MSPs (called **practices**) sign up, whitelabel their workspace, invite up to 5 team members, and create **client instances** — each instance creation is a **billable event** (manual billing for now, ledger + alerts). Staging is LIVE at **https://securepath.dev**.
>
> "SecurePath" is a **placeholder name** — final name undecided. Working domain securepath.dev (Cloudflare).

## Status (2026-08-10)

| Piece | State |
|---|---|
| Multi-tenant foundation (RLS, 5 roles, GoTrue) | ✅ built + e2e-proven (22/22, 18/18 suites) |
| Staging at securepath.dev | ✅ LIVE — Next.js + lean self-hosted Supabase on the VPS |
| Auth: signup+confirm, login, forgot, magic link, compulsory TOTP 2FA | ✅ live, Resend mail |
| **Stage 0** — client instances + billing ledger + 5-seat invites + whitelabel | ✅ live |
| **Stage 1** — POPIA assessment engine (89 Qs, scoring parity, RLS-hardened) | ✅ live, now on the spine |
| **Workflow spine** — tracks/stage state, content packs, approvals ledger | ✅ built + verified 2026-08-10 |
| **Stages 2–6** — intake → policy → manual → implement → monthly | 🔜 Stage 2 in build |
| Cyber track (ISO 27701, Cyber Essentials) | ⏸ content pack once privacy track proven |
| Production (AWS af-south-1), CI, product name | ⏸ pushed back deliberately |

> **The product is a pipeline, not a set of features** — see *Product workflow* below. What's built (Stages 0–1 + spine) is the front of that pipeline; Stages 2–6 are the rest of it.

## System architecture

```mermaid
flowchart LR
    subgraph Internet
        U[Browser<br/>MSP / client user]
        R[Resend API<br/>mail.securepathconsulting.co.za]
        N[ntfy.sh<br/>securepath-ops-d2e6906f]
    end
    subgraph VPS [VPS 91.107.216.190]
        C[Caddy :443<br/>auto-TLS securepath.dev]
        subgraph next [systemd securepath-web]
            W[Next.js 15<br/>127.0.0.1:3200]
        end
        subgraph compose [docker compose securepath-staging — loopback only]
            G[GoTrue :55321]
            P[PostgREST :55322]
            D[("Postgres :55432")]
        end
    end
    U -->|https| C
    C -->|"/auth/v1/*"| G
    C -->|"/rest/v1/*"| P
    C -->|everything else| W
    W -->|server-side RPC + alerts| P
    G --> D
    P --> D
    W -->|invite + billing mail| R
    G -->|auth mail via SMTP| R
    W -->|billing alert| N
```

Key decisions:
- **No Kong** — Caddy path-routes the Supabase API on the same domain (`securepath.dev/auth/v1`, `/rest/v1`). One domain, no extra DNS.
- **Authorization lives entirely in Postgres RLS** keyed on `auth.uid()`. Tenant id never accepted from the client. App server calls RPCs **under the caller's JWT**, so RLS always applies.
- **SA data residency** is the compliance pitch → self-hosted Supabase, prod later in AWS af-south-1 (hosted Supabase has no SA region). No Clerk (US residency weakens pitch).

## Environments

```mermaid
flowchart TB
    subgraph dev [Dev — local on VPS]
        A[supabase start in app/<br/>API :54321, DB :54322<br/>demo JWT secret — NEVER expose]
        B[next dev -p 3100<br/>web/.env.development]
    end
    subgraph staging [Staging — public, securepath.dev]
        S[staging/docker-compose.yml<br/>fresh secrets in staging/.env]
        T[systemd securepath-web :3200<br/>env /opt/securepath/web.env]
    end
    subgraph prod [Production — LATER]
        X[Same compose on EC2 af-south-1<br/>fresh secrets + DNS flip]
    end
    dev -->|"same migrations from app/supabase/migrations"| staging -->|cutover| prod
```

- **Deploy web change:** `staging/deploy-web.sh` (builds `web/`, copies standalone to `/opt/securepath/web-dist`, restarts systemd).
- **Apply migration to staging:** psql as **supabase_admin** (not `postgres` — it can't alter reserved roles in the supabase image). Command in `staging/README.md`.
- `supabase db reset` broken in CLI 2.110 (LegacyDbBootstrapError) — apply dev migrations incrementally via psql :54322.

## Tenancy model

```mermaid
erDiagram
    practices ||--o{ client_orgs : "has (each creation = billable)"
    practices ||--o{ memberships : "max 5 team seats"
    practices ||--o{ invites : "issues"
    practices ||--o{ billing_events : "append-only, ops-only"
    practices ||--o{ notifications : "receives"
    practices ||--o{ audit_log : "append-only"
    users ||--o{ memberships : "one practice per user (MVP)"
    client_orgs ||--o{ consultant_assignments : "consultant scoping"
    client_orgs ||--o{ assessments : "pattern for all domain tables"
    practices {
        text name "whitelabel display name"
        text logo_url "whitelabel"
        text accent_hex "whitelabel accent"
    }
    memberships {
        text role "practice_owner, practice_consultant, client_admin, client_contributor, read_only"
        uuid client_org_id "set only for client_* roles"
    }
    billing_events {
        text event_type "instance.created, instance.deleted"
    }
```

Roles: `practice_owner` (everything), `practice_consultant` (only *assigned* clients), `client_admin`/`client_contributor` (pinned to one client org), `read_only`. Seat cap of 5 counts consultants + read_only (owner and client-side users excluded), including pending invites.

RLS pattern for every future domain table: `client_org_id` column + 2 policies via `allowed_client_orgs()` — copy the `assessments` table.

## Auth flows

### Signup + email confirm

```mermaid
sequenceDiagram
    participant B as Browser
    participant W as Next.js
    participant G as GoTrue
    participant R as Resend
    B->>G: POST /auth/v1/signup open signup
    G->>R: confirmation mail (custom template, token_hash link)
    R-->>B: email "Confirm my account"
    B->>W: GET /auth/confirm?token_hash&type=signup
    W->>G: verifyOtp(token_hash)
    G-->>W: session aal1
    W-->>B: redirect /dashboard, middleware forces /mfa/enroll
    Note over B,W: No practice yet: /onboarding calls create_practice RPC<br/>caller becomes practice_owner
```

**Gotcha that burned us:** self-hosted GoTrue default mail links use `?token=` (its own GET-verify flow); the app verifies `?token_hash=`. Fixed with custom templates in `web/public/mail-templates/*.html`, fetched by GoTrue at send time via `GOTRUE_MAILER_TEMPLATES_*` (path `/mail-templates` is middleware-exempt). If mail links ever break again, check this first.

### Sign-in with compulsory 2FA

```mermaid
flowchart TD
    L["Sign in: password, magic link, or forgot-password"] --> S["session aal1"]
    S --> M{"TOTP factor verified?"}
    M -->|no| E["/mfa/enroll — QR + manual key<br/>compulsory, cannot skip"]
    M -->|yes| V["/mfa — 6-digit code"]
    E -->|verify code| A["aal2 session"]
    V -->|verify code| A
    A --> D["/dashboard"]
    S -.->|middleware blocks every app page until aal2| M
```

- Middleware (`web/middleware.ts`): no session → `/login`; aal1 with verified factor → `/mfa`; aal1 without → `/mfa/enroll`. Exempt: public pages, `/mfa*`, `/reset`, `/mail-templates`.
- **Ceiling:** enforcement is app-layer only — a direct REST call with an aal1 JWT still passes RLS. Add aal2 checks in RLS when hardening for prod.

### Forgot password / magic link

```mermaid
sequenceDiagram
    participant B as Browser
    participant W as Next.js
    participant G as GoTrue
    B->>W: /forgot email or magic-link button on /login
    W->>G: resetPasswordForEmail / signInWithOtp
    G-->>B: mail with token_hash link
    B->>W: /auth/confirm?token_hash&type=recovery|magiclink
    W->>G: verifyOtp
    W-->>B: recovery to /reset, magiclink to /dashboard
```

**Hard rule learned:** every server-side redirect/link must use `BASE_URL` (`web/lib/base-url.ts`, env `APP_URL`) — `req.url` behind Caddy is the internal host and produced `localhost:3200` redirects three separate times (confirm route, API invite links, middleware).

## Client instance creation — the billable event

```mermaid
sequenceDiagram
    participant O as Owner browser
    participant W as NextJS api clients
    participant P as PostgREST callers JWT
    participant DB as Postgres
    participant Ops as Bruce email and ntfy
    O->>W: POST client details, optional invite contact as client_admin
    W->>P: rpc create_client_org(...)
    P->>DB: SECURITY DEFINER insert client_org<br/>+ billing_events(instance.created)<br/>+ notification "billable"<br/>+ audit_log
    DB-->>W: client_org id
    W->>Ops: opsAlert email bruce.m@securepathconsulting.co.za + ntfy securepath-ops-d2e6906f
    W->>P: rpc create_invite client_admin if requested
    W-->>O: done → dashboard
```

- **Ledger is authoritative**, written in the same transaction as the client org. Alerts are best-effort extras.
- `billing_events` has **no RLS policies** — invisible to all app users. Read it for invoicing: psql as supabase_admin.
- Manual billing model (decision 2026-07-29): no Stripe yet; wire it against the ledger later.

## Team invites (5-seat cap)

```mermaid
sequenceDiagram
    participant O as Owner
    participant W as Next.js
    participant DB as Postgres RPCs
    participant I as Invitee
    O->>W: /team → invite email + role
    W->>DB: rpc create_invite, rejects if seats incl pending >= 5
    W->>I: Resend mail with /invite/TOKEN link
    I->>W: /invite/TOKEN then sign up or sign in
    I->>DB: rpc accept_invite(token)
    Note over DB: checks email matches invite, not expired 7d,<br/>not already in a practice, seat cap again
    DB-->>I: membership created → forced into 2FA enrolment → dashboard
```

## Whitelabel

Practice owner sets display name, logo URL, accent color at `/settings/branding` (columns on `practices`). Layout reads them per-request: nav brand + `--accent` CSS var swap → whole workspace and client-facing pages render the MSP's brand. In-app only for now; custom domains per MSP = later (Caddy on-demand TLS when justified).

## Product workflow — Assessment to Management (spec v1.0, William)

The product is **one pipeline** a client travels once and then loops on monthly. Two tracks share it: **privacy** (POPIA & PAIA, built first) proves the pattern; **cyber** (ISO 27701, Cyber Essentials) reuses the *same machinery* with a different content pack. Seven stages, four human approval gates — nothing passes a gate automatically.

```mermaid
flowchart TD
    S0["Stage 0 — Client setup & engagement"] --> S1["Stage 1 — POPIA & PAIA assessment"]
    S1 --> G1{"Gate 1 — advisor review + client sign-off"}
    G1 -->|approved| S2["Stage 2 — Document intake & gap map"]
    G1 -->|rework| S1
    S2 --> S3["Stage 3 — Policy creation"]
    S3 --> G2{"Gate 2 — IO approves each policy"}
    G2 -->|suite approved| S4["Stage 4 — PIMS manual compile, 27701-aligned"]
    G2 -->|revise| S3
    S4 --> G3{"Gate 3 — IO sign-off + PAIA s.51 publish"}
    G3 --> S5["Stage 5 — Implementation via task engine"]
    S5 --> G4{"Gate 4 — remediation substantially done"}
    G4 --> S6["Stage 6 — Managed service, monthly report"]
    S6 -.->|annual reassessment vs baseline| S1
    CY["Cyber track — 27701 / Cyber Essentials<br/>same pipeline, different content pack"] -.->|upsell or parallel entry| S1
    CY -.->|controls fold into monthly report| S6
```

**The load-bearing rule — content-driven screens.** Question sets, document checklists, templates, manual outlines are **content packs**, versioned at practice level. The frontend *renders* content, it does not *encode* it. Acceptance test for every screen: *does it work unchanged when the framework changes?* If a new framework needs a code change, the architecture failed.

Other cross-cutting rules (all spec §6):
- **Explicit stage state** — every transition is explicit and logged; a stage never advances as a side effect.
- **Draft (AI) vs Approved** — nothing AI-drafted (summaries, policies, chapters, report narratives, letters) is client-visible or issuable without a *logged human approval*. The UI must distinguish Draft(AI) from Approved everywhere.
- **Evidence immutability** — uploads, task completions, sign-offs, issued docs are immutable; corrections are new versions, never edits.
- **The baseline runs through everything** — the Stage 1 score anchors the whole relationship: the implementation board closes gaps against it, the monthly report shows movement against it, the annual reassessment renews against it.

### The spine (what makes the above true)

Migration `app/supabase/migrations/20260810000002_workflow_spine.sql`. Three primitives every stage hangs off — build stages *on* these, never bespoke:

```mermaid
erDiagram
    client_orgs ||--o{ tracks : "privacy + cyber, parallel"
    tracks ||--o{ stage_transitions : "append-only, logged"
    frameworks ||--o{ content_packs : "versioned content"
    content_packs ||--o{ assessment_questions : "Stage 1 pack"
    practices ||--o{ approvals : "append-only gate ledger"
    tracks {
        text track_kind "privacy | cyber"
        int current_stage "0..6, moved only by advance_track_stage()"
    }
    frameworks {
        text key "popia,paia,gdpr,iso27701,cyber_essentials — add = one INSERT"
        text track_kind "privacy | cyber"
    }
    approvals {
        text subject_type "assessment,policy,manual_chapter,monthly_report,..."
        text action "drafted,approved,issued,rejected,superseded"
    }
```

- **(a) Tracks + stage state** — `tracks` (one privacy + one cyber per client, run in parallel), `current_stage` 0–6, moved **only** by `advance_track_stage()` which writes an append-only `stage_transitions` row. That RPC is the whole "explicit, logged, never a side effect" rule.
- **(b) Content packs** — `frameworks` registry + `content_packs` (versioned, practice-scopable) **replaced Devin's `CHECK(framework IN …)` enum**. Adding a framework is one `INSERT`, zero schema change (the acceptance test, in the DB). Scoring RPCs join on the framework text (now FK-backed) → unchanged, parity preserved. The 89 Stage-1 questions were migrated onto packs.
- **(c) Draft/Approved + evidence** — `approval_status` domain (`draft_ai|draft_human|approved|issued|superseded`) reused by every future artifact table; append-only `approvals` ledger via `record_approval()`. Stage 1's gate is the first consumer (`assessment_sessions.approval_status`).

Every spine RPC (`create_track`, `advance_track_stage`, `record_approval`) guards `allowed_client_orgs()` / `current_practice()` explicitly — a SECURITY DEFINER owned by a superuser bypasses RLS, so the check must be in the function body (learned the hard way, see below).

**Build order for Stages 2–6** (spec §5, each increment client-demoable): 2 document intake (bulk upload, AI classify, gap map) · 3 policy workbench (template picker, AI draft, per-doc approval) · 4 manual builder (compile-from-registers, s.51 publish) · 5 implementation board (task engine, magic-link task pages) · 6 monthly report studio. Every screen content-driven; prove it by activating a Cyber Essentials pack against the same screens.

## Mail

- Resend account: **verified domain is `mail.securepathconsulting.co.za`** (subdomain!). From = `noreply@mail.securepathconsulting.co.za` — root-domain from-address 403s.
- GoTrue auth mail via SMTP (`smtp.resend.com:587`, user `resend`, pass = API key, in `staging/.env`). App mail (invites, billing alerts) via Resend REST (`web/lib/mail.ts`, key in `/opt/securepath/web.env`).
- Resend refuses fake recipient domains (`example.com` → GoTrue 500 "Error sending confirmation email"). Tests: use `delivered@resend.dev`. Per-email rate limit ≈60s between auth mails.

## Security notes (verified, some the hard way)

- Staging containers + Next bind **127.0.0.1 only**; dev Supabase :54321/:54322 and web :3100/:3200 dropped at `iptables -t raw` on eth0. **Self-testing public ports from the VPS lies** (loops via `lo`, bypasses eth0 rules) — verify from a real external host.
- Dev CLI stack uses the **public demo JWT secret** — never expose :54321. Staging has fresh secrets (`staging/.env`, chmod 600).
- `audit_log`, `billing_events`, `stage_transitions`, `approvals` are append-only (REVOKE UPDATE/DELETE).
- SELinux (EL10): systemd can't read files `mv`-ed from `/root` — `restorecon -R` after moving anything into `/opt/securepath`.
- **SECURITY DEFINER owned by a superuser bypasses RLS** — the "RLS enforces access" comment is a lie inside a definer. Every such RPC touching tenant data MUST call `allowed_client_orgs()`/`current_practice()` in its body. Confirmed cross-tenant write on staging from Devin's assessment RPCs before this was fixed (`20260810000001_fix_assessment_rpc_authz.sql`).

## Repo map

```
/root/securepath-privacy/
├── CLAUDE.md            ← this doc (also published as the artifact)
├── roadmap.html         ← phase-0 roadmap page (historical)
├── app/                 ← supabase project: migrations = source of truth for schema
│   ├── supabase/migrations/   1 tenancy+RLS · 2 grants · 3 billing/invites/onboarding
│   │                    · 20260806* assessment engine + 8 POPIA modules (Stage 1, Devin)
│   │                    · 20260807* scoring parity / batch / validation fixes (Devin)
│   │                    · 20260810000001 assessment RPC authz fix (cross-tenant hole)
│   │                    · 20260810000002 workflow spine (tracks, content packs, approvals)
│   └── tests/e2e_isolation.py (22/22 CI gate)
├── web/                 ← Next.js 15 app (App Router, @supabase/ssr)
│   ├── app/             login, signup, forgot, reset, mfa(+enroll), onboarding, dashboard,
│   │                    clients/new, team, notifications, settings/branding, invite/[token],
│   │                    assessments (Stage 1 runner) · api: clients, invites, assessments · auth
│   ├── lib/             supabase(-browser).ts, base-url.ts, mail.ts
│   └── public/mail-templates/  GoTrue mail templates (token_hash links)
├── staging/             ← compose + secrets + deploy-web.sh + README (runbook)
├── poc/                 ← original SQL isolation suite (18/18, reference)
└── docs/                ← product scope, MVP spec, data model, source xlsx sheets
```

## Roadmap — what's next

**Primary track — build the pipeline (spec v1.0).** Stages 0–1 + spine done. In order, each client-demoable:
1. **Stage 2 — document intake & gap map** (in build): bulk upload, AI classification against an expected-document checklist, gap map. Checklist is content (per framework).
2. **Stage 3 — policy workbench**: template picker, AI draft (Draft(AI) → per-doc approval via `record_approval`), edit.
3. **Stage 4 — manual builder**: chapter outline (content), compile-from-registers, IO sign-off + PAIA s.51 publish.
4. **Stage 5 — implementation board**: remediation as kanban on the task engine, magic-link task pages, gaps close against the Stage 1 baseline.
5. **Stage 6 — monthly report studio**: AI narrative showing movement vs baseline, approve-and-issue, immutable archive.
6. **Cyber content pack** (ISO 27701 → Cyber Essentials): prove the acceptance test — same screens, new pack, no code.

**Deferred (pushed back deliberately):** real product name → domain; af-south-1 prod (runbook `app/README.md`); CI running both isolation suites per migration; Entra ID SSO (WorkOS); prod hardening (aal2 in RLS, Stripe against `billing_events`, WAL-G backups → S3 af-south-1); two unmerged Devin branches on GitHub (AI chat-assessment mode reviewed & safe pending base fix + 2 nits; testing skill).

North star: client-ready, evidence-linked monthly compliance report in <60 min advisor time. Goal for this phase: 3–5 design-partner clients under 1–2 advisor tenants.

## VPS: do not supabase start
On this host, `supabase start` is blocked (exit 99). Live SecurePath uses `/root/securepath-privacy/staging` docker compose only. Override only with `SUPABASE_ALLOW_START=1`. See DO-NOT-SUPABASE-START-ON-VPS.md.
