$ProgressPreference = 'SilentlyContinue'
# Stage the cross-built reference server into the guest and start it on :8443
# with SSLKEYLOGFILE for pcap decryption (D9 oracle).
$dir = 'C:\re\server'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$base = 'http://192.168.100.1/push/'
foreach ($f in @('mqelserver.exe','libssl-3.dll','libcrypto-3.dll')) {
  try {
    Invoke-WebRequest -UseBasicParsing ($base + $f) -OutFile (Join-Path $dir $f) -TimeoutSec 120 -ErrorAction Stop
  } catch { Write-Output ("pull-failed: " + $f + " " + $_.Exception.Message) }
}
Write-Output 'staged:'
Get-ChildItem $dir | ForEach-Object { Write-Output ("  " + $_.Name + " " + $_.Length) }

# Stop any previous instance, then start fresh with the keylog env.
Get-Process mqelserver -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
$env:SSLKEYLOGFILE = "$dir\sslkeys.log"
if (Test-Path $env:SSLKEYLOGFILE) { Remove-Item $env:SSLKEYLOGFILE -Force }
Start-Process -FilePath "$dir\mqelserver.exe" -ArgumentList '8443' -WorkingDirectory $dir -WindowStyle Hidden
Start-Sleep 3
$p = Get-Process mqelserver -ErrorAction SilentlyContinue
if ($p) { Write-Output ("mqelserver running pid " + $p.Id) } else { Write-Output 'mqelserver NOT RUNNING' }
$netstat = netstat -an | Select-String ':8443.*LISTENING'
Write-Output ("listen8443: " + [bool]$netstat)
Get-Content "$dir\mqelserver.log" -ErrorAction SilentlyContinue | Select-Object -Last 3 | ForEach-Object { Write-Output $_ }
