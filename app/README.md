# SecurePath Privacy Platform — foundation

Multi-tenant core: MSP practice → client organisations, 5 fixed roles, RLS-enforced isolation.

## Architecture decisions (2026-07-23)

- **Self-hosted Supabase**, prod region **AWS af-south-1 (Cape Town)** — hosted Supabase has no SA region; SA data residency is non-negotiable (spec F1.7).
- One Postgres, shared schema, row-level security. No schema-per-tenant.
- Identity: GoTrue (Supabase auth) — email+password, TOTP MFA. No Clerk (US residency weakens compliance pitch). WorkOS considered later only for Entra ID SSO (spec F1.4, "should").
- Authorization lives entirely in Postgres RLS keyed on `auth.uid()`. Tenant id never accepted from the client.
- Roles (spec F1.2): `practice_owner`, `practice_consultant` (sees only assigned clients), `client_admin`, `client_contributor` (pinned to one client org), `read_only`. One practice per user (MVP).
- Onboarding writes cross RLS only via two SECURITY DEFINER RPCs: `create_practice`, `add_member`.
- `audit_log` append-only: RLS + REVOKE UPDATE/DELETE (spec F1.5).

## Layout

- `supabase/migrations/` — schema + RLS. Every future domain table copies the `assessments` pattern: `client_org_id` column + 2 policies via `allowed_client_orgs()`.
- `tests/e2e_isolation.py` — real-stack proof: GoTrue users → JWTs → PostgREST → RLS. CI gate (spec F1: "tenant isolation verified by test").
- `../poc/` — SQL-level isolation suite (predecessor, kept as reference).

## Local dev

```bash
supabase start -x studio,realtime,storage-api,imgproxy,edge-runtime,logflare,vector,supavisor,mailpit
supabase status   # prints API URL + anon/service keys
SUPABASE_URL=... ANON_KEY=... SERVICE_KEY=... python3 tests/e2e_isolation.py
```

`supabase db reset` reapplies migrations from scratch.

## Prod deploy (af-south-1) — when ready

1. EC2 in af-south-1, docker compose from supabase/supabase `docker/` dir (same services minus studio exposure).
2. Generate fresh JWT secret + anon/service keys; SMTP for auth mails; enforce MFA (GoTrue `MFA_ENABLED`).
3. Apply `supabase/migrations/` via `supabase db push` (or psql in order).
4. Run `tests/e2e_isolation.py` against prod URL before first tenant.
5. Backups: WAL-G/pgBackRest to S3 af-south-1 bucket — never cross-region.
