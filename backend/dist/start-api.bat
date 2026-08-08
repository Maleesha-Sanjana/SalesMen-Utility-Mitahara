@echo off
setlocal
cd /d "%~dp0"

echo Starting Sales Man Utility API...
echo Folder: %CD%
echo.
echo Test from a phone browser:
echo   http://123.231.62.96:3000/api/health
echo.

if exist salesman-api.exe (
  salesman-api.exe
) else (
  echo salesman-api.exe not found in this folder.
  echo On Windows, double-click build-exe-on-windows.bat first.
  echo Or use start-with-node.bat if Node.js is installed.
  pause
  exit /b 1
)

pause
