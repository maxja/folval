$ProgressPreference = 'SilentlyContinue'
# mqelserver health
$p = Get-Process mqelserver -ErrorAction SilentlyContinue
Write-Output ("mqelserver alive: " + [bool]$p + $(if ($p) { " pid " + $p.Id }))

# inbound 8443 for the gateway forward (host->guest path was dropped)
$rule = Get-NetFirewallRule -DisplayName 'folval-oracle-8443' -ErrorAction SilentlyContinue
if (-not $rule) {
  New-NetFirewallRule -DisplayName 'folval-oracle-8443' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 8443 | Out-Null
  Write-Output 'firewall rule added: folval-oracle-8443'
} else { Write-Output 'firewall rule already present' }

# quick verify: local listen + a local connect
$l = netstat -an | Select-String ':8443.*LISTENING'
Write-Output ("listen8443: " + [bool]$l)
