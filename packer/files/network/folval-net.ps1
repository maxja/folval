# folval guest network bootstrap - baked into the box (scheduled task
# folval-static-ip, ONSTART, SYSTEM). re-isolated-net deliberately has no
# DHCP, so on every boot the guest must self-assign its address before
# WinRM can answer the host. Idempotent: exits immediately when the target
# address is already present, so re-running on every boot is safe and also
# re-asserts the WinRM service config after adapter identity changes.
$ErrorActionPreference = 'Continue'
$log = "$env:windir\Temp\folval-net.log"
function Log([string]$m) { "$(Get-Date -Format o)  $m" | Out-File -Append -Encoding utf8 $log }

# 1. Wait for a connected adapter (new virtio NIC on first vagrant boot).
$nic = $null
for ($i = 0; $i -lt 60 -and -not $nic; $i++) {
  $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
         Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
  if (-not $nic) { Start-Sleep -Seconds 2 }
}
if (-not $nic) { Log 'ERROR: no connected adapter after 120s'; exit 1 }
Log "adapter: $($nic.Name) idx=$($nic.IfIndex)"

# 2. Idempotency gate.
if (Get-NetIPAddress -IPAddress 192.168.100.10 -ErrorAction SilentlyContinue) {
  Log '192.168.100.10 already configured - nothing to do'
  exit 0
}

# 3. Static config: 192.168.100.10/24, gw + DNS = host gateway 192.168.100.1.
#    Dhcp must be disabled on the interface before New-NetIPAddress accepts it.
Remove-NetIPAddress -InterfaceIndex $nic.IfIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceIndex $nic.IfIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $nic.IfIndex -IPAddress 192.168.100.10 -PrefixLength 24 -DefaultGateway 192.168.100.1
Set-DnsClientServerAddress -InterfaceIndex $nic.IfIndex -ServerAddresses 192.168.100.1

# 4. WinRM must survive the adapter identity change (new MAC -> Unidentified
#    network -> Public profile). The build-time firewall rule is profile=any,
#    but Private keeps `winrm set` usable (it refuses on Public, 0x80338169)
#    and matches the build-time state.
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
Log 'configured: 192.168.100.10/24 gw 192.168.100.1 dns 192.168.100.1'
