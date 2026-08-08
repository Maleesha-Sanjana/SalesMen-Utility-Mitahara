@echo off
setlocal
cd /d "%~dp0"

if not exist node_modules (
  echo Installing Node.js dependencies...
  call npm ci --omit=dev
  if errorlevel 1 (
    echo npm install failed.
    pause
    exit /b 1
  )
) else (
  echo Using existing node_modules
)

echo.
echo Starting Sales Man Utility API with Node.js...
echo Test from a phone browser:
echo   http://123.231.62.96:3000/api/health
echo.

node server.js
pause
