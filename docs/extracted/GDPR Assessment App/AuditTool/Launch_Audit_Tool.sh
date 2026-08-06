#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  GDPR | DUAA 2025 | ISO 27701  Compliance Audit Tool
#  macOS / Linux Launcher
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================================"
echo " GDPR | DUAA 2025 | ISO 27701  Compliance Audit Tool"
echo "============================================================"
echo ""

# Find Python 3
if command -v python3 &>/dev/null; then
    PYTHON=python3
elif command -v python &>/dev/null; then
    VER=$(python --version 2>&1 | grep -oP '(?<=Python )\d')
    if [ "$VER" = "3" ]; then
        PYTHON=python
    else
        echo "ERROR: Python 3.9+ is required. Please install from https://python.org"
        exit 1
    fi
else
    echo "ERROR: Python 3 not found. Please install Python 3.9+ from https://python.org"
    exit 1
fi

echo "Using: $($PYTHON --version)"

# Install dependencies
echo "Checking dependencies..."
$PYTHON -m pip install openpyxl reportlab pillow --quiet --upgrade 2>/dev/null || \
$PYTHON -m pip install openpyxl reportlab pillow --quiet --upgrade --break-system-packages 2>/dev/null

# macOS: ensure tkinter is available
if [[ "$OSTYPE" == "darwin"* ]]; then
    $PYTHON -c "import tkinter" 2>/dev/null || {
        echo ""
        echo "NOTE: tkinter is not installed."
        echo "On macOS, install via: brew install python-tk"
        echo "Or reinstall Python from https://python.org (includes tkinter)"
        exit 1
    }
fi

echo "Starting application..."
echo ""
$PYTHON audit_app.py

if [ $? -ne 0 ]; then
    echo ""
    echo "Application exited with an error. See above for details."
    read -p "Press Enter to close..."
fi
