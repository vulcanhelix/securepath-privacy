@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  Cyber Essentials SA — Desktop Launcher
::  Opens as a standalone app window (no browser chrome)
:: ============================================================

set "APPDIR=%~dp0"
set "HTMLFILE=%APPDIR%CyberEssentialsSA.html"

:: Build file:// URL (replace backslashes with forward slashes)
set "FILEURL=%HTMLFILE:\=/%"
set "FILEURL=file:///%FILEURL%"

:: ── Try Chrome (--app mode = standalone window) ──────────────
for %%P in (
  "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
  "%PROGRAMFILES%\Google\Chrome\Application\chrome.exe"
  "%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe"
) do (
  if exist %%P (
    start "" %%P --app="%FILEURL%" --window-size=1380,880 --disable-extensions --no-first-run
    goto :done
  )
)

:: ── Try Edge (--app mode = standalone window) ────────────────
for %%P in (
  "%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe"
  "%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe"
  "%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe"
) do (
  if exist %%P (
    start "" %%P --app="%FILEURL%" --window-size=1380,880 --disable-extensions --no-first-run
    goto :done
  )
)

:: ── Fallback: open in default browser ────────────────────────
echo Neither Chrome nor Edge found in standard locations.
echo Opening in your default browser instead...
start "" "%FILEURL%"

:done
endlocal
