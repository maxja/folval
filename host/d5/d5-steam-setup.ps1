$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# D5 window prep: install the Steam client silently inside the guest.
# - Installer is fetched through the mock gateway push dir (hermetic path:
#   guest still has ONLY the isolated NIC at this point).
# - NSIS silent switch /S; qemu-ga runs as SYSTEM so no UAC prompt.
# - The installer auto-starts a headless steam.exe which locks config files;
#   it is shut down and killed so later interactive use starts clean.
# - Single-library policy: libraryfolders.vdf is NOT edited here. A fresh
#   install defaults new games to the PRIMARY library, which is what we want
#   (the old steamcmd-staging flow that seeded C:\SteamLibrary is retired).
# Identity-free: knows nothing about any specific title.
# Prereq: SteamSetup.exe staged in host/push/ (gitignored) and the gateway
# running (./lab.sh gateway:run).
# Delivery: bash host/tools/guest-run.sh host/d5/d5-steam-setup.ps1

$steamDir = Join-Path ${env:ProgramFiles(x86)} 'Steam'
$steamExe = Join-Path $steamDir 'steam.exe'

'=== disk space ==='
'C free GB: {0:N1}' -f ((Get-PSDrive C).Free / 1GB)

'=== fetch installer via gateway push ==='
$dst = 'C:\Windows\Temp\SteamSetup.exe'
Invoke-WebRequest -Uri 'http://192.168.100.1/push/SteamSetup.exe' -OutFile $dst -UseBasicParsing
'setup: {0} bytes sha256={1}' -f (Get-Item $dst).Length, (Get-FileHash $dst -Algorithm SHA256).Hash

'=== silent install ==='
if (Test-Path $steamExe) {
  'steam.exe already present - skipping installer'
} else {
  $p = Start-Process -FilePath $dst -ArgumentList '/S' -PassThru -Wait
  'installer exit: {0}' -f $p.ExitCode
  if (-not (Test-Path $steamExe)) { throw 'steam.exe not found after install' }
}

'=== stop the auto-started headless instance ==='
$deadline = (Get-Date).AddSeconds(60)
while (-not (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 10
& $steamExe -shutdown 2>$null
Start-Sleep -Seconds 8
Get-Process -Name 'steam','steamwebhelper','steamservice' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
'steam stopped'

'=== library state (info) ==='
$vdf = Join-Path $steamDir 'config\libraryfolders.vdf'
if (Test-Path $vdf) { Get-Content $vdf } else { 'no libraryfolders.vdf yet (created on first client start)' }
if (Test-Path 'C:\SteamLibrary') { 'NOTE: C:\SteamLibrary exists (staging-era leftover); installs still default to the primary library' }
'STEAM-SETUP DONE'
