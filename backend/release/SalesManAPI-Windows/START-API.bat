@echo off
setlocal
cd /d "%~dp0"

echo Starting Sales Man Utility API...
echo Test URL: http://123.231.62.96:3000/api/health
echo.

".\node\runtime\node.exe" server.js
pause
