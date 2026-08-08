# Optional: install the API as a Windows service using NSSM.
# 1. Download NSSM from https://nssm.cc/download
# 2. Run this script as Administrator after editing $ServicePath below.

param(
  [string]$ServicePath = (Resolve-Path (Join-Path $PSScriptRoot ".")).Path
)

$exePath = Join-Path $ServicePath "salesman-api.exe"
$nssm = "C:\tools\nssm\nssm.exe"

if (-not (Test-Path $exePath)) {
  Write-Error "salesman-api.exe not found at $exePath"
  exit 1
}

if (-not (Test-Path $nssm)) {
  Write-Host "NSSM not found at $nssm"
  Write-Host "Download NSSM, extract it, then run:"
  Write-Host "  nssm install SalesManAPI `"$exePath`""
  Write-Host "  nssm set SalesManAPI AppDirectory `"$ServicePath`""
  Write-Host "  nssm start SalesManAPI"
  exit 0
}

& $nssm install SalesManAPI $exePath
& $nssm set SalesManAPI AppDirectory $ServicePath
& $nssm set SalesManAPI Start SERVICE_AUTO_START
& $nssm start SalesManAPI

Write-Host "Service installed and started: SalesManAPI"
