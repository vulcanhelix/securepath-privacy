#!/usr/bin/env bash
# W1-09 scheduler — drive the DB job runner once per minute.
#
# Primary firing path is pg_cron (armed by 20261106000004_scheduler.sql — the
# staging image already has pg_cron in shared_preload_libraries, no compose
# change needed). This script is the FALLBACK for any environment where
# pg_cron cannot be created: install the two unit files next to it and the
# identical SELECT public.tick(now()) runs via systemd instead.
#
# Install on this VPS:
#   sudo cp staging/jobs-tick.sh /opt/securepath/jobs-tick.sh
#   sudo chmod +x /opt/securepath/jobs-tick.sh
#   sudo cp staging/jobs-tick.service staging/jobs-tick.timer /etc/systemd/system/
#   sudo systemctl daemon-reload && sudo systemctl enable --now jobs-tick.timer
#
set -euo pipefail
cd "$(dirname "$0")"
PW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker exec -i -e PGPASSWORD="$PW" securepath-staging-db-1 \
  psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
  -tAc "SELECT public.tick(now()) ->> 'claimed' || ' claimed'"
