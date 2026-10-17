$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# D5 online window: disable the isolated-NET adapter (192.168.100.10) so the
# guest has exactly one egress path (the temp NAT NIC). Windows route/DNS
# preference between two default routes is unreliable; the sinkhole DNS on the
# isolated side breaks the Steam updater ("needs to be online to update").
# Re-enabled by d5-net-window-off.ps1 before the Phase 2 gate re-run.

$ip = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq '192.168.100.10' }
if (-not $ip) { throw 'isolated adapter not found by IP 192.168.100.10' }
'target adapter: ' + $ip.InterfaceAlias
Disable-NetAdapter -Name $ip.InterfaceAlias -Confirm:$false
Start-Sleep -Seconds 3
if ((Get-NetAdapter -Name $ip.InterfaceAlias).Status -eq 'Disabled') {
  'ISOLATED NIC DISABLED'
} else {
  throw 'disable failed - adapter still up'
}
