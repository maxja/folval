$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

# Install the redistributables the target needs from Steamworks Shared
# (pulled in as a dependency of any Steam title install). Idempotent:
# installers are quiet-mode and re-runnable; verification at the end checks
# the actual DLLs. The _CommonRedist root is located under ANY Steam library
# root (the client picks the library at install time - primary or an extra
# one - so hardcoding a single path is not robust).
# Delivery: bash host/tools/guest-run.sh host/d5/d5-redist-install.ps1

$roots = @(
  (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\Steamworks Shared\_CommonRedist'),
  'C:\SteamLibrary\steamapps\common\Steamworks Shared\_CommonRedist'
)
$cr = $null
foreach ($r in $roots) { if (Test-Path $r) { $cr = $r; break } }
if (-not $cr) {
  throw 'Steamworks Shared _CommonRedist not found under any library root - install the title in the Steam client first (it pulls the dependency)'
}
'redist root: ' + $cr

function Run-Installer([string]$exe, [string[]]$arglist) {
  if (-not (Test-Path $exe)) { '  MISSING: ' + $exe; return -1 }
  $p = Start-Process -FilePath $exe -ArgumentList $arglist -Wait -PassThru
  return $p.ExitCode
}

'=== VC++ 2010 SP1 x86 (msvcr100/msvcp100) ==='
'  exit: ' + (Run-Installer "$cr\vcredist\2010\vcredist_x86.exe" @('/q','/norestart')) + ' (0=ok, 3010=ok+reboot-pending)'

'=== VC++ 2012 x86 (msvcr110/msvcp110) ==='
'  exit: ' + (Run-Installer "$cr\vcredist\2012\vcredist_x86.exe" @('/q','/norestart')) + ' (0=ok, 3010=ok+reboot-pending)'

'=== DirectX Jun2010 (d3dx9_*/xinput*) ==='
'  exit: ' + (Run-Installer "$cr\DirectX\Jun2010\DXSETUP.exe" @('/silent')) + ' (0=ok)'

'=== verify SysWOW64 dlls ==='
'vcredist and DirectX runtimes are x86: the game is 32-bit, so SysWOW64 is the check target'
'msvcr100','msvcp100','msvcr110','msvcp110','d3dx9_43','xinput1_3' | ForEach-Object {
  '{0}: {1}' -f $_, (Test-Path "C:\Windows\SysWOW64\$_.dll")
}
'REDIST-INSTALL DONE'
