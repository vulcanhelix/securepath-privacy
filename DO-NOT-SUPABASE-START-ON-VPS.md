# Do not run `supabase start` on this VPS

**Live SecurePath (securepath.dev)** uses the **lean** stack only:

```bash
cd /root/securepath-privacy/staging
docker compose up -d
```

- Ports: 55432 (db), 55321 (auth), 55322 (rest) on 127.0.0.1
- Web: systemd `securepath-web`
- Caddy: `/etc/caddy/Caddyfile`

## Hard block

`/usr/local/bin/supabase` is a **wrapper**. Plain:

```bash
supabase start
```

**exits with code 99** and prints a warning. It does not start containers.

Intentional override (debug only):

```bash
SUPABASE_ALLOW_START=1 supabase start
# … work …
supabase stop
```

Real binary: `/usr/local/bin/supabase.real`

`vps-guardian` will also stop `supabase_*` containers under memory/load pressure.

If you need the full stack for local debugging, prefer your **laptop**, not this VPS.
