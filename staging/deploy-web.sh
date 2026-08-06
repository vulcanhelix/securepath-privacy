#!/bin/bash
# Build the Next app with staging env and (re)start the systemd service.
set -euo pipefail
cd /root/securepath-privacy/web
rm -f .env.local   # must not override .env.production at build time
npm run build
DEST=/opt/securepath/web-dist
rm -rf "$DEST"
cp -r .next/standalone "$DEST"
mkdir -p "$DEST/.next"
cp -r .next/static "$DEST/.next/static"
[ -d public ] && cp -r public "$DEST/public" || true
systemctl restart securepath-web
systemctl --no-pager -l status securepath-web | head -5
