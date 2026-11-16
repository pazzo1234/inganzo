@echo off
setlocal
cd /d "%~dp0"

echo.
echo ============================================================
echo   Inganzo Website Launcher
echo ============================================================
echo.

where node >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Node.js 18 or later is required.
    echo         Install it from https://nodejs.org/
    pause
    exit /b 1
)

if not exist "node_modules\" (
    echo [INFO] Installing project dependencies...
    call npm.cmd ci
    if errorlevel 1 (
        echo [ERROR] Dependency installation failed.
        pause
        exit /b 1
    )
)

if not defined PORT set "PORT=3000"
if not defined HOST set "HOST=127.0.0.1"
echo [INFO] Starting Inganzo on http://%HOST%:%PORT%
echo [INFO] Press Ctrl+C to stop.
start "" "http://%HOST%:%PORT%"
node server.js
pause
