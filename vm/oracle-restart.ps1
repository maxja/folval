$ProgressPreference = 'SilentlyContinue'
# Restart mqelserver with a fresh keylog (keeps re-server-key.pem so the
# self-signed cert identity is STABLE across restarts — clients and the
# guest Root store keep trusting it, and pcaps stay decryptable offline).
$dir = 'C:\re\server'
Get-Process mqelserver -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
# fresh log + keylog
Remove-Item "$dir\mqelserver.log","$dir\sslkeys.log","$dir\stdout.txt","$dir\stderr.txt" -Force -ErrorAction SilentlyContinue
$env:SSLKEYLOGFILE = "$dir\sslkeys.log"
Start-Process -FilePath "$dir\mqelserver.exe" -ArgumentList '8443' -WorkingDirectory $dir -WindowStyle Hidden `
  -RedirectStandardOutput "$dir\stdout.txt" -RedirectStandardError "$dir\stderr.txt"
Start-Sleep 3
$p = Get-Process mqelserver -ErrorAction SilentlyContinue
Write-Output ("alive: " + [bool]$p + " pid: " + $(if ($p) { $p.Id } else { '-' }))

# local TLS handshake against 127.0.0.1:8443 - validates our cross-build's TLS stack
try {
  $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 8443)
  $ssl = New-Object Net.Security.SslStream($c.GetStream(), $false, { $true })
  $ssl.AuthenticateAsClient('Gameserver')
  Write-Output ("tls-handshake: OK protocol=" + $ssl.SslProtocol + " cipher=" + $ssl.CipherAlgorithm)
  $ssl.Dispose(); $c.Close()
} catch { Write-Output ("tls-handshake: FAIL " + $_.Exception.Message) }
Start-Sleep 2
$p2 = Get-Process mqelserver -ErrorAction SilentlyContinue
Write-Output ("alive-after-handshake: " + [bool]$p2)
Get-Content "$dir\mqelserver.log" -ErrorAction SilentlyContinue | Select-Object -Last 3 | ForEach-Object { Write-Output $_ }
