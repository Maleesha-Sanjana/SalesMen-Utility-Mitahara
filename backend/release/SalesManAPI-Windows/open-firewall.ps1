# Run as Administrator on the Windows server.
$ruleName = "Sales Man Utility API"

Write-Host "Opening Windows Firewall for TCP port 3000..."

$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Host "Firewall rule already exists: $ruleName"
} else {
  New-NetFirewallRule `
    -DisplayName $ruleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 3000 | Out-Null
  Write-Host "Firewall rule created: $ruleName"
}

Write-Host ""
Write-Host "Test from mobile data:"
Write-Host "  http://123.231.62.96:3000/api/health"
