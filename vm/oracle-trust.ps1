$ProgressPreference = 'SilentlyContinue'
# Import the reference server's cert into the guest Root store (schannel /
# CEF trust). The engine's static OpenSSL ignores the store; certpatch covers
# that side. Idempotent: skips if the thumbprint is already present.
#
# Usage: host/tools/guest-push.sh <cert.cer> server.cer   then:
#        vm/oracle-trust.ps1 (pulled from /push/ and run via -File)
param([string]$Cer = 'C:\re\server.cer', [string]$Push = 'http://192.168.100.1/push/server.cer')
try {
  Invoke-WebRequest -UseBasicParsing $Push -OutFile $Cer -TimeoutSec 60
} catch { Write-Output ('download failed: ' + $_.Exception.Message); exit 1 }
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Cer)
$existing = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $cert.Thumbprint
if ($existing) { Write-Output ('already trusted: ' + $cert.Thumbprint); exit 0 }
Import-Certificate -FilePath $Cer -CertStoreLocation Cert:\LocalMachine\Root |
  ForEach-Object { Write-Output ('imported: ' + $_.Thumbprint) }
