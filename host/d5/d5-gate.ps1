$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

# Hermeticity gate. Prints evidence and emits per-check verdicts plus an
# overall GATE: PASS/FAIL line. Exit code is always 0 (qemu-ga ignores it);
# parse the GATE: line from the captured output.
$verdicts = @()

'=== adapters ==='
$up = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
Get-NetAdapter | ForEach-Object { '  ' + $_.Name + ' | ' + $_.InterfaceDescription + ' | mac=' + $_.MacAddress + ' | ' + $_.Status }
if ($up.Count -eq 1) {
  $verdicts += 'PASS adapters: exactly one Up adapter'
} else {
  $verdicts += 'FAIL adapters: ' + $up.Count + ' Up adapters (expect exactly 1 - NAT NIC still attached?)'
}

'=== ipv4 addresses (info) ==='
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*' } |
  ForEach-Object { '  ' + $_.IPAddress + '  (' + $_.InterfaceAlias + ')' }

# NOTE on ping semantics: when the host boundary drops a probe, Windows
# counts the host-generated ICMP error ("Reply from 192.168.100.1:
# Destination ... unreachable") as a Received packet, so the "0% loss"
# summary line is MEANINGLESS for blocked pings. A real echo reply is a
# line matching "Reply from <target>: bytes=".
'=== ping 8.8.8.8 (expect BLOCKED) ==='
$p1 = ping -n 4 -w 2000 8.8.8.8
$p1 | Select-String 'Reply from|loss' | ForEach-Object { '  ' + $_.Line }
$real1 = @($p1 | Select-String '^Reply from 8\.8\.8\.8: bytes=').Count
if ($real1 -eq 0) {
  $verdicts += 'PASS internet ping: 0 real echo replies from 8.8.8.8 (ICMP-error replies do not count)'
} else {
  $verdicts += 'FAIL internet ping: ' + $real1 + '/4 real echo replies from 8.8.8.8'
}

'=== ping 192.168.100.1 (expect reachable) ==='
$p2 = ping -n 4 -w 2000 192.168.100.1
$p2 | Select-String 'Reply from|loss' | ForEach-Object { '  ' + $_.Line }
$real2 = @($p2 | Select-String '^Reply from 192\.168\.100\.1: bytes=').Count
if ($real2 -ge 1) {
  $verdicts += 'PASS gateway ping: ' + $real2 + '/4 real echo replies from 192.168.100.1'
} else {
  $verdicts += 'FAIL gateway ping: no real echo replies from 192.168.100.1'
}

'=== dns example.com via 192.168.100.1 (expect sinkhole 192.168.100.1) ==='
try {
  $r = Resolve-DnsName example.com -Server 192.168.100.1 -Type A -NoHostsFile -ErrorAction Stop
  $r | ForEach-Object { '  ' + $_.Name + ' -> ' + $_.IPAddress }
  if (@($r | Where-Object { $_.IPAddress -eq '192.168.100.1' }).Count -ge 1) {
    $verdicts += 'PASS dns: example.com resolves to 192.168.100.1 (sinkhole)'
  } else {
    $verdicts += 'FAIL dns: example.com resolved to a non-sinkhole answer'
  }
} catch {
  '  FAIL: ' + $_.Exception.Message
  $verdicts += 'FAIL dns: Resolve-DnsName error'
}

'=== dns www.msftconnecttest.com via 192.168.100.1 (info: NCSI liveness) ==='
try {
  $r2 = Resolve-DnsName www.msftconnecttest.com -Server 192.168.100.1 -Type A -NoHostsFile -ErrorAction Stop
  $r2 | ForEach-Object { '  ' + $_.Name + ' -> ' + $_.IPAddress }
} catch {
  '  (no answer: ' + $_.Exception.Message + ')'
}

''
'=== verdicts ==='
$verdicts | ForEach-Object { '  ' + $_ }
$fails = @($verdicts | Where-Object { $_ -like 'FAIL*' })
if ($fails.Count -eq 0) {
  'GATE: PASS'
} else {
  'GATE: FAIL (' + $fails.Count + ' failed checks)'
}
