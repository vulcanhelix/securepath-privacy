# E2E Pipeline Test Suite

`app/tests/e2e_pipeline.py` drives the **whole Assessment-to-Management pipeline** (Stages 0–6 + the four gates) against a running deployment, over real HTTP — the same paths the app uses: GoTrue auth (including compulsory TOTP 2FA), PostgREST RPCs under the caller's JWT, and the Next.js `/api` routes. It is the regression gate for the pipeline; the older `e2e_isolation.py` (22/22) covers the tenancy foundation.

## What it checks (36 assertions, 4 groups)

**1. Tenant-isolation guards** — the class of bug that started the hardening. Two practices; the attacker cannot create/update in the victim's client, cannot read it (RLS), and `anon` cannot execute a SECURITY DEFINER RPC (execute revoked). Every definer RPC must guard `allowed_client_orgs()` — this proves it.

**2. Full pipeline happy path (POPIA privacy track)** — one client walks the entire journey, asserting the state at each step:
- Stage 1: create assessment, answer questions, score cache populates.
- **Gate 1**: sign-off → track advances to Stage 2.
- Stage 2: upload a well-named doc → slot auto-proposed from the filename → confirm → gap closes.
- Stage 3: draft a policy from a template → approve → **issue** (becomes an immutable evidence document that closes its gap) → editing an issued policy is rejected.
- **Gate 2**: advance to Stage 4.
- Stage 4: compile the PIMS manual (27701-aligned, embeds the approved policy) → **Gate 3** sign-off → manual issued + PAIA s.51 published → track at Stage 5.
- Stage 5: generate remediation (idempotent) → complete critical+high → **Gate 4** → Stage 6.
- Stage 6: compile the monthly report (baseline + movement) → issue to the immutable archive → re-issue rejected.

**3. Acceptance test (content-driven architecture)** — a Cyber Essentials client: the same content queries + `generate_remediation_plan` return CE content across all five stages, CE tasks land on a parallel **cyber** track, and POPIA content is untouched. Proves a second framework flows through the same machinery.

**4. Evidence immutability** — an uploaded document rejects direct `UPDATE`/`DELETE` (append-only; corrections are new versions).

## Run

```bash
BASE_URL=https://securepath.dev \
ANON_KEY=$(grep ^ANON_KEY staging/.env | cut -d= -f2) \
SERVICE_ROLE_KEY=$(grep ^SERVICE_ROLE_KEY staging/.env | cut -d= -f2) \
python3 app/tests/e2e_pipeline.py
```

Exit code 0 on all-pass, 1 on any failure. No third-party dependencies (stdlib only: TOTP, multipart, and the `@supabase/ssr` session cookie are built inline).

| Env | Purpose |
|---|---|
| `BASE_URL` | deployment root (default `https://securepath.dev`) |
| `ANON_KEY` | Supabase anon JWT |
| `SERVICE_ROLE_KEY` | service_role JWT — used **only** to create pre-confirmed test users via the GoTrue admin API, so the suite needs no DB access and no mail delivery |

## Notes

- **2FA is real.** The suite enrolls a TOTP factor and computes codes, because the `/api` routes require an `aal2` session (compulsory 2FA). It builds the `@supabase/ssr` cookie the same way the browser does.
- **Test data is namespaced** with a per-run id and `@resend.dev` emails. There is no delete-practice RPC by design (append-only ledgers), so cleanup is a deliberate DB step.

## Cleanup

Test runs leave practices named `guard-* / pipe * / accept * / immut *` and `@resend.dev` users. Remove them as `supabase_admin` (staging):

```bash
cd staging && PW=$(grep POSTGRES_PASSWORD .env | cut -d= -f2)
docker exec -i -e PGPASSWORD=$PW securepath-staging-db-1 psql -h 127.0.0.1 -U supabase_admin -d postgres <<'SQL'
DO $$ DECLARE junk uuid[];
BEGIN
  SELECT array_agg(id) INTO junk FROM practices WHERE name ~ '^(guard-|pipe |accept |immut )';
  DELETE FROM document_links   WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM monthly_reports  WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM manuals          WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM policies         WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM tasks            WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM documents        WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM assessment_responses WHERE session_id IN (SELECT s.id FROM assessment_sessions s JOIN client_orgs c ON c.id=s.client_org_id WHERE c.practice_id=ANY(junk));
  DELETE FROM assessment_scores    WHERE session_id IN (SELECT s.id FROM assessment_sessions s JOIN client_orgs c ON c.id=s.client_org_id WHERE c.practice_id=ANY(junk));
  DELETE FROM assessment_sessions  WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM approvals        WHERE practice_id=ANY(junk);
  DELETE FROM stage_transitions WHERE track_id IN (SELECT t.id FROM tracks t JOIN client_orgs c ON c.id=t.client_org_id WHERE c.practice_id=ANY(junk));
  DELETE FROM tracks           WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM billing_events   WHERE practice_id=ANY(junk);
  DELETE FROM notifications    WHERE practice_id=ANY(junk);
  DELETE FROM audit_log        WHERE practice_id=ANY(junk);
  DELETE FROM memberships      WHERE practice_id=ANY(junk);
  DELETE FROM client_orgs      WHERE practice_id=ANY(junk);
  DELETE FROM practices        WHERE id=ANY(junk);
END $$;
DELETE FROM public.users WHERE email ~ '@resend.dev$';
DELETE FROM auth.users   WHERE email ~ '@resend.dev$';
SQL
```

(MinIO objects from uploads: `docker exec securepath-staging-minio-1 mc rm -r --force local/securepath-documents/` — staging only.)

## CI

Not yet wired. When CI lands (see roadmap), run this after each migration against an ephemeral stack, alongside `e2e_isolation.py`.
