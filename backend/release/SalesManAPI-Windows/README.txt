Sales Man Utility - Windows Portable Package
==========================================

Built on Mac for Windows deployment.

1. Copy this entire folder to your Windows server
   Example: C:\SalesManAPI\

2. Edit config.js (database settings)

3. Open firewall (PowerShell as Admin):
   powershell -ExecutionPolicy Bypass -File open-firewall.ps1

4. Double-click START-API.bat

No separate Node.js install is required on Windows.
This package includes portable Node.js for Windows.

For a single salesman-api.exe file, build on Windows or use GitHub Actions.
