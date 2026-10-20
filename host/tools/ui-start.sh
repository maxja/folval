#!/bin/bash
# ui-start — start a command in the vagrant DESKTOP session (session 1).
#
# Interactive scheduled tasks (LogonType Interactive) registered from the
# SYSTEM context (qemu-ga/WinRM) refuse to start: 0x800710E0, "operator or
# administrator has refused your request" — even notepad. Proven alternative:
# a per-run dispatcher script (C:\re\ui-dispatch.cmd) wired into the vagrant
# user's HKCU Run key; `logoff 1` then cycles the session and autologon
# (ForceAutoLogon=1) re-logs-in and executes the dispatcher natively in the
# desktop session. Steam (if not itself the target) is started first and
# given its offline-update-check window before the target fires.
#
# Usage:
#   bash host/tools/ui-start.sh <image> [args...]   # args are passed raw
#   bash host/tools/ui-start.sh 'C:\...\PublicLauncher.exe'
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ $# -lt 1 ]]; then
    echo "usage: ui-start.sh <image> [args...]" >&2
    exit 2
fi
img="$1"; shift || true
args="$*"

steam='C:\Program Files (x86)\Steam\steam.exe'
# Bare 'steam.exe' (or any name without a path) would stage a dispatcher
# whose `start "" steam.exe` fails at every autologon ("Windows cannot
# find 'steam.exe'" alert — observed 2026-10-20). Auto-resolve the one
# known bare alias; anything else must be a full backslash path.
[[ "$img" == 'steam.exe' ]] && img="$steam"

windir="${img%\\*}"   # guest dir of the target (caller passes backslash paths)

# Dispatcher body (cmd). One array element per line.
lines=('@echo off' 'rem staged by folval ui-start.sh (overlay corrupt after steam settle)'
      # user-session frida-server: SYSTEM/session-0 frida-server cannot inject
      # into desktop-session processes (verified live); same-user instance on
      # :27043 attaches to launcher/game/UI. Idempotent via netstat guard.
      'netstat -an | find "0.0.0.0:27043" | find "LISTENING" >nul || start "" /MIN C:\frida\frida-server.exe -l 0.0.0.0:27043'
      # overlay dir-block BEFORE Steam starts: Steam's startup validation
      # restores the overlay DLLs (breaking Reset); block+armor first.
      'powershell -NoProfile -ExecutionPolicy Bypass -File C:\re\overlayblock.ps1')
if [[ "$img" != "$steam" ]]; then
    lines+=("tasklist /FI \"IMAGENAME eq steam.exe\" | find /I \"steam.exe\" >nul || start \"\" \"$steam\""
            'timeout /t 75 /nobreak >nul')
else
    lines+=("start \"\" \"$steam\""
            'timeout /t 75 /nobreak >nul')
fi
# Steam's startup validation is done by now (75s settle): corrupt the
# overlay DLLs in-place so later game launches fail LoadLibrary (Reset OK).
lines+=('powershell -NoProfile -ExecutionPolicy Bypass -File C:\re\overlaycorrupt.ps1')
lines+=("pushd \"$windir\""
        "start \"\" \"$img\"${args:+ $args}"
        'popd')

# Render as a PowerShell single-quoted array literal (embedded ' doubled).
psarr=''
for l in "${lines[@]}"; do
    esc=${l//\'/\'\'}
    psarr+=$'\t'"'$esc'"$'\n'
done

tmp=$(mktemp --suffix=.ps1)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
\$ProgressPreference = 'SilentlyContinue'
\$body = @(
$psarr
)
New-Item -ItemType Directory -Force -Path C:\re | Out-Null
Set-Content -Path C:\re\ui-dispatch.cmd -Value \$body -Encoding ASCII

\$sid = \$null
Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | ForEach-Object {
    if (\$_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+\$') {
        \$u = (Get-ItemProperty ('Registry::' + \$_.Name + '\Volatile Environment') -ErrorAction SilentlyContinue).USERNAME
        if (\$u -eq 'vagrant') { \$sid = \$_.Name }
    }
}
if (-not \$sid) { Write-Output 'ui-start: vagrant hive not found (is the desktop session up?)'; exit 1 }
\$runKey = 'Registry::' + \$sid + '\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path \$runKey -Force | Out-Null
New-ItemProperty -Path \$runKey -Name 'FolvalUI' -Value 'C:\re\ui-dispatch.cmd' -PropertyType String -Force | Out-Null
# 3. Cycle the session: logoff + autologon re-fires the Run key in the
# desktop session. Console session id is NOT stable across cycles (1 -> 2
# -> ...), so resolve it from explorer's SessionId.
\$exp = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
\$sess = if (\$exp) { \$exp.SessionId } else { 1 }
logoff \$sess
Write-Output ('ui-start: staged target + cycled session ' + \$sess + ' (logoff -> autologon fires dispatcher)')
EOF
bash "$(dirname "$0")/guest-run.sh" "$tmp"
