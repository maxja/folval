$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# D5 online window END: re-enable the isolated-NET adapter that
# d5-net-window-on.ps1 disabled. Identified as the (only) disabled adapter;
# the NAT NIC is up, so Status -eq 'Disabled' selects the right one.

$ad = Get-NetAdapter | Where-Object { $_.Status -eq 'Disabled' }
if (-not $ad) { throw 'no disabled adapter found' }
're-enabling: ' + ($ad.InterfaceAlias -join ', ')
Enable-NetAdapter -Name $ad.InterfaceAlias -Confirm:$false
Start-Sleep -Seconds 8
$ok = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '192.168.100.10' }
if ($ok) {
  'ISOLATED NIC BACK: 192.168.100.10'
} else {
  throw '192.168.100.10 not back yet (DHCP may be slow - check again)'
}
