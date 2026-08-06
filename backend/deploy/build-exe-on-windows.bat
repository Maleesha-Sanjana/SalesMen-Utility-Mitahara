@echo off
setlocal
cd /d "%~dp0"

echo Building salesman-api.exe...
echo Folder: %CD%
echo.

for /f "tokens=1 delims=." %%a in ('node -p "process.versions.node.split('.')[0]"') do set NODE_MAJOR=%%a
echo Node version:
node -v
if %NODE_MAJOR% GTR 22 (
  echo.
  echo WARNING: Node.js 22 LTS is recommended for building the exe.
  echo Node 24 may fail. Install from https://nodejs.org/en/download
  echo.
)

if exist "C:\Program Files\Git\usr\bin\patch.exe" (
  set "PATH=C:\Program Files\Git\usr\bin;%PATH%"
)

if not defined PKG_CACHE_PATH set "PKG_CACHE_PATH=%CD%\.pkg-cache"
if not exist "%PKG_CACHE_PATH%" mkdir "%PKG_CACHE_PATH%"

echo Installing build dependencies...
call npm install --include=dev
if errorlevel 1 (
  echo npm install failed.
  pause
  exit /b 1
)

if exist prefetch-pkg-base.js (
  echo Downloading pkg base binary...
  node prefetch-pkg-base.js
  if errorlevel 1 (
    echo Prefetch failed. Check internet connection and try again.
    pause
    exit /b 1
  )
) else (
  echo prefetch-pkg-base.js not found - pkg may try to download the base binary itself.
)

call npm run build:exe:here
if errorlevel 1 (
  echo.
  echo Build failed.
  echo Try:
  echo   1. Install Node.js 22 LTS from https://nodejs.org/
  echo   2. Install Git for Windows from https://git-scm.com/download/win
  echo   3. Re-run build-exe-on-windows.bat
  pause
  exit /b 1
)

echo.
echo Build complete:
echo   %CD%\salesman-api.exe
echo.
echo Next: double-click start-api.bat
pause
