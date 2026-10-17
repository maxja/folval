#!/bin/bash
# folval — run a PowerShell script in the guest via qemu-ga (same delivery
# as vm:provision). Usage: bash host/tools/guest-run.sh <script.ps1>
#
# WARNING: scripts MUST set "$ProgressPreference = 'SilentlyContinue'" before
# any Invoke-WebRequest/copy loops. PowerShell renders progress bars to
# stdout when captured; qemu-ga returns them as guest-exec-status out-data
# and a single >10 MB status response exceeds virsh's read buffer
# (EOVERFLOW "No complete agent response found") — after which the agent
# channel deadlocks permanently (qemu-ga keeps offering the response
# libvirt refuses to read). Recovery: virsh destroy + start (ACPI reboot is
# swallowed; observed 2026-10-17 — the guest itself keeps running fine).
set -euo pipefail
cd "$(dirname "$0")/../.."

DOMAIN="folly-n-valor_default"
VIRSH="virsh -c qemu:///system"

script_b64=$(iconv -f UTF-8 -t UTF-16LE "$1" | base64 -w0)
exec_json=$(printf '{"execute":"guest-exec","arguments":{"path":"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe","arg":["-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand","%s"],"capture-output":true}}' "$script_b64")
pid_json=$($VIRSH qemu-agent-command "$DOMAIN" "$exec_json")
pid=$(printf '%s' "$pid_json" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
if [ -z "$pid" ]; then
  echo "guest-exec failed: $pid_json" >&2; exit 1
fi
while :; do
  st=$($VIRSH qemu-agent-command "$DOMAIN" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")
  printf '%s' "$st" | grep -q '\"exited\":true' && break
  sleep 2
done
printf '%s' "$st" | sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p' | base64 -d
printf '%s' "$st" | sed -n 's/.*"err-data":"\([^"]*\)".*/\1/p' | base64 -d >&2 || true
printf '%s' "$st" | grep -q '\"exitcode\":0' && echo "GUEST-RUN: ok" || { echo "GUEST-RUN: FAILED" >&2; exit 1; }
