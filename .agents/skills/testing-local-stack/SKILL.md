---
name: testing-local-stack
description: Stand up a local Postgres/GoTrue/PostgREST stack plus Next.js to runtime-test SecurePath features (assessments, chat assessment, auth/TOTP, RLS/tenancy) without running `supabase start`. Use when testing anything in securepath-chat / securepath-privacy that needs a real database, real auth, or real RLS.
---

# Local runtime testing for SecurePath

`supabase start` is **blocked** on these hosts (wrapper exits 99, see `AGENTS.md`). Do not override it.
Instead run a lean Docker stack modelled on `staging/docker-compose.yml`. Full working copy lives at
`/home/ubuntu/testing/` (`docker-compose.yml`, `Caddyfile`, `.env` chmod 600, `seed.sql`, `q.sh`).
Reuse it rather than rebuilding — the setup is the expensive part.

## Stack layout

| Service | Image | Port (loopback) |
|---|---|---|
| Postgres | `supabase/postgres:15.8.1.049` | 55432 |
| GoTrue | `supabase/gotrue:v2.176.1` | 55321 |
| PostgREST | `postgrest/postgrest:v12.2.12` | 55322 |
| Caddy gateway | `caddy:2-alpine` | 55400 |
| Next.js dev | — | 3100 |

A **single-origin gateway is required**: `@supabase/ssr` takes one base URL, so Caddy path-routes
`/auth/v1/*` → GoTrue and `/rest/v1/*` → PostgREST. Point `NEXT_PUBLIC_SUPABASE_URL` at the gateway.

`.env` holds `POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_KEY`. Mint the anon/service JWTs
with HS256 over `JWT_SECRET` (`{"role":"anon"|"service_role","exp":...}`).

## Gotchas that cost real time

- **GoTrue/PostgREST crash-loop on a fresh volume** with `failed SASL auth ... supabase_auth_admin`.
  Fix: `ALTER ROLE supabase_auth_admin WITH LOGIN PASSWORD '<POSTGRES_PASSWORD>';` and the same for
  `authenticator`, then restart both services. While they crash-loop, Caddy logs a *misleading*
  `lookup auth on 127.0.0.11:53: server misbehaving` DNS error — chase the SASL error, not the DNS one.
- **Apply migrations as `supabase_admin`**, in filename order, from `app/supabase/migrations`.
  `postgres` cannot alter reserved roles in the supabase image.
- **If a migration file changes on the branch under test, recreate the DB volume and re-apply the whole
  chain.** Patching incrementally leaves the old function body in place and you will test the wrong code.
- `assessment_sessions` has no `response_count` column; `assessment_documents` columns are
  `original_filename, mime, size, sha256, storage_path` (not `size_bytes`/`mime_type`).

Handy query helper (`/home/ubuntu/testing/q.sh`):

```bash
#!/bin/bash
. /home/ubuntu/testing/.env
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD securepath-chat-test-db-1 \
  psql -h 127.0.0.1 -U supabase_admin -d postgres -qAt -c "$1"
```

## Seeding tenancy

`seed.sql` creates: `public.users`, two `practices` (A/B), two `client_orgs`, `memberships`
(`practice_owner` in A, `read_only` in A, `practice_owner` in B), a small 4-question GDPR question set,
and several `assessment_sessions`. Having **both a second practice and a read-only user** is what makes
tenancy/permission testing possible — seed them up front.

Create auth users via the GoTrue admin API with the service key; set/reset a password with
`PUT /admin/users/<id>` and `{"password":"...","email_confirm":true}`.

## Getting past compulsory TOTP 2FA

Middleware forces `/mfa/enroll` then `/mfa`. Enrol once through the UI, **save the base32 secret**, then
generate codes yourself (`pyotp` may not be installed — hand-roll it):

```python
import hmac, hashlib, base64, struct, time
k = base64.b32decode('<SECRET>'); c = int(time.time()) // 30
h = hmac.new(k, struct.pack('>Q', c), hashlib.sha1).digest(); o = h[19] & 15
print(str((struct.unpack('>I', h[o:o+4])[0] & 0x7fffffff) % 1000000).zfill(6))
```

## Starting Next.js

```bash
cd web && setsid nohup env AI_PROVIDER=none npm run dev > /tmp/next-dev.log 2>&1 < /dev/null & disown
```

Use `setsid ... & disown` — a plain `nohup ... &` from the exec tool can die with the shell and the log
file never appears. `/tmp/next-dev*.log` is the best evidence source: it shows the real server-side error
(and stack) behind any UI failure, plus `[assessment-ai]` lines with model/latency/usage.

For OpenAI-backed runs bind the key via the exec `env` parameter; repo-scoped refs do not resolve in
shells. Keep `AI_PROVIDER=auto` in `.env.local` and override to `none` on the command line to exercise the
deterministic path. Verify which path actually ran by counting `[assessment-ai]` lines and
`assessment_chat_turns` rows with `kind='proposal'` — do not trust the UI alone.

### Devin Secrets Needed

- `OPENAI_API_KEY` — session-scoped; required only for the model-backed conversational path.

## Testing the chat assessment specifically

- The core invariant is that **the model can never write a score**. Assert it in the DB, not the UI:
  `select count(*) from assessment_responses where session_id='…'` must stay 0 while a proposal is
  pending, and a confirmation must write exactly the proposed token.
- Snapshot/diff the whole response table around adversarial steps
  (`select q.question_number, r.response, r.status, md5(...) ... order by 1` into a file, then `diff`) —
  that catches silent overwrites a spot-check misses.
- Chips post the bare canonical tokens `fully_compliant|partial|non_compliant|na` as ordinary messages,
  so a chip clicked during a `gap_details`/`owner`/`target_date` follow-up is stored as that field's free
  text. Watch for `responsible_party = 'non_compliant'` style corruption.
- There is no UI affordance to revisit an already-answered question, so "re-answer and check staleness"
  may be untestable through the chat alone; use the grid editor at `/assessments/[id]` to compare or amend.
- Upload rejections (bad MIME, oversize) are enforced server-side but may surface **no UI error at all**;
  confirm outcomes via `/tmp/next-dev.log` status codes plus `assessment_documents` / evidence dir counts.
- Requests larger than ~10 MB hit Next's default body limit and 500 before route validation runs, so a
  25 MB cap may be effectively unreachable; `middlewareClientMaxBodySize` is the likely fix to check.
- Set `ASSESSMENT_EVIDENCE_DIR` to a writable local dir (e.g. `/home/ubuntu/testing/evidence`); the
  default `/opt/securepath/evidence` is not writable here.
- Score parity between chat and grid: compare `score_pct` **and** `rating` on `assessment_sessions`.
  Note the grid may leave `status='not_started'` on rows it writes while chat sets `complete` — the score
  can match even when `status` does not.

## Authorization testing

Call RPCs directly through PostgREST under a hand-minted user JWT (`{"sub":"<user uuid>",
"role":"authenticated","aud":"authenticated"}` signed with `JWT_SECRET`) to attack tenancy without a
browser. `ensure_assessment_chat_opening` should raise `Assessment session not found or access denied`
for another practice's session and for `read_only`, while the owner gets HTTP 204.

A read-only user must still be able to **load** a conversation (the GET path skips the opening RPC).
Test the write side too: the UI leaves chips and the composer enabled for read-only users, so sending a
message 500s from the DB check with no visible error — verify turn/response counts are unchanged.
