# Staging — securepath.dev (this VPS)

Prod-like environment. Cutover to af-south-1 later = same compose + `deploy-web.sh` pattern, fresh secrets, DNS flip.

## Pieces

- **Supabase (lean)**: `docker-compose.yml` — postgres:55432, GoTrue:55321, PostgREST:55322, all loopback-only. Secrets in `.env` (chmod 600, fresh JWT secret — NOT the CLI demo keys). No Kong: Caddy path-routes `/auth/v1/*` and `/rest/v1/*` on securepath.dev.
- **Web**: Next.js from `../web`, built by `./deploy-web.sh` → `/opt/securepath/web-dist`, systemd `securepath-web`, 127.0.0.1:3200. Runtime env `/opt/securepath/web.env`.
- **Caddy**: `/etc/caddy/Caddyfile` — TLS, path routing, noindex header.
- **Firewall**: raw PREROUTING eth0 drops for 54321/54322 (dev) + 3100/3200 (web). Verify from a real external host, not the VPS itself (self-tests loop via lo and lie).

## Deploy a web change

```bash
/root/securepath-privacy/staging/deploy-web.sh
```

## Apply a new migration

```bash
cd /root/securepath-privacy/staging
PW=$(grep POSTGRES_PASSWORD .env | cut -d= -f2)
docker exec -i -e PGPASSWORD=$PW securepath-staging-db-1 \
  psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < ../app/supabase/migrations/NEW.sql
```

(supabase_admin, not postgres — postgres can't alter reserved roles in this image.)

## Open items / gotchas

- **Resend key missing**: RESOLVED 2026-07-29: key wired, domain verified at mail.securepathconsulting.co.za subdomain — from-address must use @mail.
- **Billing alerts**: ntfy topic `securepath-ops-d2e6906f` (+ email once Resend live). Ledger = `billing_events` table (append-only, invisible to app users; read via psql as supabase_admin).
- Dev stack (`supabase start` in ../app) is unrelated to staging; `supabase db reset` currently broken in CLI 2.110 (LegacyDbBootstrapError) — apply migrations incrementally via psql on 54322.

## Auth features (2026-07-29 pm)
- Forgot password (`/forgot` → recovery mail → `/reset`), magic-link sign-in (login page), compulsory TOTP 2FA (GoTrue MFA enabled in compose; middleware forces `/mfa/enroll` on first sign-in, `/mfa` verify thereafter; aal2 required for app pages).
- MFA enforcement is middleware-level only for now — add aal2 checks in RLS when API-direct access must be locked too.
- Resend refuses fake recipient domains (example.com → GoTrue 500 "Error sending confirmation email"); use delivered@resend.dev for tests. Per-email rate limit ~60s between auth mails.
- Self-hosted GoTrue default mail links use `?token=` (GET /verify flow) — app expects `?token_hash=` (verifyOtp). Fixed with custom templates at web/public/mail-templates/*.html (GOTRUE_MAILER_TEMPLATES_* fetch them from securepath.dev at send time; /mail-templates is middleware-exempt). If mail links break again, check template fetch + this format mismatch first.
