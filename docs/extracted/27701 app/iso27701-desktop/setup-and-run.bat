@echo off
echo.
echo ╔══════════════════════════════════════════════════════════════════╗
echo ║   ISO/IEC 27701:2019 PIMS Assessment Suite — Desktop Setup       ║
echo ╚══════════════════════════════════════════════════════════════════╝
echo.

where node >nul 2>&1
if %errorlevel% neq 0 (
  echo ❌  Node.js not found.
  echo     Install from: https://nodejs.org  ^(choose LTS^)
  echo     Then run this script again.
  pause
  exit /b 1
)

echo ✅  Node.js detected

if not exist "node_modules" (
  echo.
  echo 📦  Installing dependencies ^(first run — ~1-2 minutes^)...
  call npm install
  if %errorlevel% neq 0 (
    echo ❌  Installation failed. Check your internet connection.
    pause
    exit /b 1
  )
)

echo.
echo 🚀  Launching PIMS Assessment Suite...
echo.
call npm start
