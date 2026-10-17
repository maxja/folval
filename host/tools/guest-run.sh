#!/bin/bash
# folval — run a PowerShell script in the guest via qemu-ga (same delivery
# as vm:provision). Usage: bash host/tools/guest-run.sh <script.ps1>
#
# Uses ONE libvirt connection for exec + polling (virsh interactive mode on
# a coproc): at most a single polkit prompt per invocation. The previous
# one-virsh-per-poll design raised a desktop auth dialog every 2 s for the
# whole script runtime (user-visible prompt storm; libvirt group since
# added, but keep it single-connection regardless).
#
# WARNING: scripts MUST set "$ProgressPreference = 'SilentlyContinue'" before
# any Invoke-WebRequest/copy loops. PowerShell renders progress bars to
# stdout when captured; qemu-ga returns them as guest-exec-status out-data
# and a single >10 MB status response exceeds virsh's read buffer
# (EOVERFLOW "No complete agent response found") — after which the agent
# channel deadlocks permanently (qemu-ga keeps offering the response
# libvirt refuses to read). Recovery: virsh destroy + start (ACPI reboot is
# swallowed; observed 2026-10-17 — the guest itself keeps running fine).
#
# FOLVAL_GUEST_TIMEOUT_S (default 900) caps total wait for the guest script;
# set 0 to wait forever.
set -euo pipefail
cd "$(dirname "$0")/../.."

DOMAIN="folly-n-valor_default"
TIMEOUT_S="${FOLVAL_GUEST_TIMEOUT_S:-900}"

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: bash host/tools/guest-run.sh <script.ps1>" >&2
  exit 2
fi

script_b64=$(iconv -f UTF-8 -t UTF-16LE "$1" | base64 -w0)
exec_json=$(printf '{"execute":"guest-exec","arguments":{"path":"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe","arg":["-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand","%s"],"capture-output":true}}' "$script_b64")

coproc VSH { virsh -c qemu:///system; } || { echo "guest-run: cannot start virsh" >&2; exit 1; }

cleanup() {
  [ -n "${VSH_PID:-}" ] && kill "$VSH_PID" 2>/dev/null || true
  wait "${VSH_PID:-0}" 2>/dev/null || true
}
trap cleanup EXIT

# vsh <virsh command line> — send it, print output lines until the sentinel
# (virsh "echo" command) comes back. Base64 agent output can never contain
# the sentinel string (no underscores in the base64 alphabet).
vsh() {
  printf '%s\necho __VSH_OK__\n' "$1" >&"${VSH[1]}"
  local line
  while IFS= read -r line <&"${VSH[0]}"; do
    [ "$line" = "__VSH_OK__" ] && return 0
    printf '%s\n' "$line"
  done
  return 1
}

# Drain the interactive banner / auth errors, if any.
vsh 'version' >/dev/null

pid_json=$(vsh "qemu-agent-command $DOMAIN '$exec_json'")
pid=$(printf '%s' "$pid_json" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
if [ -z "$pid" ]; then
  echo "guest-run: guest-exec failed:" >&2
  printf '%s\n' "$pid_json" >&2
  exit 1
fi

status_cmd="qemu-agent-command $DOMAIN '{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}'"
st=''
deadline=$(( $(date +%s) + TIMEOUT_S ))
while :; do
  st=$(vsh "$status_cmd")
  printf '%s' "$st" | grep -q '"exited":true' && break
  if [ "$TIMEOUT_S" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
    echo "guest-run: timeout after ${TIMEOUT_S}s — guest pid $pid still running" >&2
    exit 2
  fi
  sleep 2
done

printf '%s' "$st" | sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p' | base64 -d
printf '%s' "$st" | sed -n 's/.*"err-data":"\([^"]*\)".*/\1/p' | base64 -d >&2 || true
printf '%s' "$st" | grep -q '"exitcode":0' && echo "GUEST-RUN: ok" || { echo "GUEST-RUN: FAILED" >&2; exit 1; }
