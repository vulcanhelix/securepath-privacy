@echo off
setlocal

:: ============================================================
::  SA Privacy & Cybersecurity Framework
::  Windows Launcher - Opens as Desktop App
:: ============================================================

set "APPDIR=%~dp0"
set "HTMLFILE=%APPDIR%PrivacyFramework.html"

:: Convert to file:// URL
set "FILEURL=file:///%HTMLFILE:\=/%"

:: ---- Try Chrome first (app mode = no browser chrome) ----
set "CHROME64=C:\Program Files\Google\Chrome\Application\chrome.exe"
set "CHROME32=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
set "CHROMELOCAL=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"

if exist "%CHROME64%" (
    echo Launching with Chrome...
    start "" "%CHROME64%" --app="%FILEURL%" --window-size=1400,900 --disable-extensions
    goto :end
)
if exist "%CHROME32%" (
    echo Launching with Chrome...
    start "" "%CHROME32%" --app="%FILEURL%" --window-size=1400,900 --disable-extensions
    goto :end
)
if exist "%CHROMELOCAL%" (
    echo Launching with Chrome...
    start "" "%CHROMELOCAL%" --app="%FILEURL%" --window-size=1400,900 --disable-extensions
    goto :end
)

:: ---- Try Edge (app mode) ----
set "EDGE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
set "EDGE64=C:\Program Files\Microsoft\Edge\Application\msedge.exe"

if exist "%EDGE64%" (
    echo Launching with Edge...
    start "" "%EDGE64%" --app="%FILEURL%" --window-size=1400,900 --disable-extensions
    goto :end
)
if exist "%EDGE%" (
    echo Launching with Edge...
    start "" "%EDGE%" --app="%FILEURL%" --window-size=1400,900 --disable-extensions
    goto :end
)

:: ---- Fallback: open in default browser ----
echo No Chrome or Edge found. Opening in default browser...
start "" "%FILEURL%"

:end
endlocal
