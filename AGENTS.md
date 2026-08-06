# Agent notes (VulcanVPS-ZA)

## Do not run `supabase start` here

`supabase start` is **blocked** by a wrapper (exit 99). Live SecurePath = lean stack:

```bash
cd /root/securepath-privacy/staging && docker compose up -d
```

Override only if you truly need the full CLI stack:

```bash
SUPABASE_ALLOW_START=1 supabase start
# then: supabase stop
```

See `/root/securepath-privacy/DO-NOT-SUPABASE-START-ON-VPS.md`.
