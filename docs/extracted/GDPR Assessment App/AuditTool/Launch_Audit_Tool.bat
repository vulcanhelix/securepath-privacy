@echo off
title GDPR Compliance Audit Tool
cd /d "%~dp0"

echo ============================================================
echo  GDPR ^| DUAA 2025 ^| ISO 27701  Compliance Audit Tool
echo ============================================================
echo.

REM Check Python is available
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python is not installed or not in PATH.
    echo Please install Python 3.9+ from https://python.org
    echo Make sure to check "Add Python to PATH" during installation.
    pause
    exit /b 1
)

REM Install/upgrade dependencies silently
echo Checking dependencies...
python -m pip install openpyxl reportlab pillow --quiet --upgrade

echo Starting application...
echo.
python audit_app.py

if errorlevel 1 (
    echo.
    echo Application exited with an error. See above for details.
    pause
)
