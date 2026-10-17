#!/bin/bash
# folval — start a command in the guest, detached from any WinRM/qemu-ga session.
# WinRM sessions reap their child processes on teardown, so daemons and long
# runs (the notepad gate, the game itself) are launched through a triggerless
# SYSTEM scheduled task: created, started, and left in place (idempotent
# re-run via -Force). The started process outlives the task and the session.
#
# Usage:
#   bash host/tools/guest-start.sh <image> [args...]
#   bash host/tools/guest-start.sh C:\Windows\System32\notepad.exe
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ $# -lt 1 ]]; then
    echo "usage: guest-start.sh <image> [args...]" >&2
    exit 2
fi
img="$1"; shift || true
args="$*"

# PS1 single-quoted strings: double any embedded single quotes.
psq() { local s="$1"; s="${s//\'/\'\'}"; printf "'%s'" "$s"; }

tmp=$(mktemp --suffix=.ps1)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$Img  = $(psq "$img")
\$Args = $(psq "$args")
\$Task = 'FolvalStart'
\$action = if (\$Args -ne '') { New-ScheduledTaskAction -Execute \$Img -Argument \$Args } else { New-ScheduledTaskAction -Execute \$Img }
\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
\$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName \$Task -Action \$action -Settings \$settings -Principal \$principal -Force | Out-Null
Start-ScheduledTask -TaskName \$Task
Write-Output ('started ' + \$Img + ' via task ' + \$Task)
EOF
bash "$(dirname "$0")/guest-winrm.sh" "$tmp"
