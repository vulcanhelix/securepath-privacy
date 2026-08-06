#!/usr/bin/env bash
# ISO/IEC 27701:2019 PIMS Assessment Suite — Setup & Launch
set -e

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   ISO/IEC 27701:2019 PIMS Assessment Suite — Desktop Setup       ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Check Node.js
if ! command -v node &> /dev/null; then
  echo "❌  Node.js not found."
  echo "    Please install Node.js 18+ from: https://nodejs.org"
  echo "    Then run this script again."
  exit 1
fi

NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VER" -lt 18 ]; then
  echo "❌  Node.js 18+ required. You have: $(node --version)"
  echo "    Upgrade at: https://nodejs.org"
  exit 1
fi

echo "✅  Node.js $(node --version)"
echo ""

if [ ! -d "node_modules" ]; then
  echo "📦  Installing dependencies (first run — ~1-2 minutes)…"
  npm install
  echo ""
fi

echo "🚀  Launching PIMS Assessment Suite…"
echo ""
npm start
