#!/bin/bash
# folval — run PowerShell in the guest via qemu-ga (primary path).
# Falls back to WinRM (guest-winrm.sh) automatically when the guest agent
# is wedged (exec failure / exec-status errors / timeout).
#
# Usage:
#   bash host/tools/guest-run.sh <script.ps1>   # run a local script file
#   bash host/tools/guest-run.sh -c '<ps>'      # run an inline command
set -uo pipefail
cd "$(dirname "$0")/../.."

# Discover the lab domain: exactly one running domain on this libvirt instance
# (the RE guest). A fixed name breaks when vagrant-libvirt names it after the
# project dir.
domain=$(virsh -c qemu+unix:///system list --name 2>/dev/null | grep -v '^\s*$')
n=$(printf '%s' "$domain" | grep -c . || true)
if [[ "$n" -ne 1 ]]; then
    echo "guest-run: expected exactly one running domain, found $n" >&2
    exit 1
fi

if [[ "${1:-}" == "-c" ]]; then
    psargs=(-NoProfile -ExecutionPolicy Bypass -Command "${2:?usage: guest-run.sh -c '<powershell>'}")
else
    psargs=(-NoProfile -ExecutionPolicy Bypass -File "${1:?usage: guest-run.sh <script.ps1> | -c '<powershell>'}")
fi

# libvirt 12.x qemu-agent-command takes the command as a raw JSON string
# (bare command names fail with "failed to parse JSON"); QGA guest-exec wants
# path + arg[] (not a single cmd string).
exec_json=$(printf '%s\n' "${psargs[@]}" | python3 -c 'import json,sys
args=[l.rstrip("\n") for l in sys.stdin]
print(json.dumps({"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe","arg":args,"capture-output":True}}))')
resp=$(virsh -c qemu+unix:///system qemu-agent-command "$domain" --timeout 30 "$exec_json" 2>&1)
pid=$(printf '%s' "$resp" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["return"]["pid"])
except Exception:
    pass' 2>/dev/null)
if [[ -z "$pid" ]]; then
    echo "guest-run: qemu-ga unavailable, falling back to WinRM" >&2
    echo "guest-run: agent said: ${resp:0:200}" >&2
    exec bash "$(dirname "$0")/guest-winrm.sh" "$@"
fi

deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    status_json=$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec-status","arguments":{"pid":int(sys.argv[1])}}))' "$pid")
    resp=$(virsh -c qemu+unix:///system qemu-agent-command "$domain" --timeout 10 "$status_json" 2>&1)
    if echo "$resp" | grep -q 'does not exist'; then
        # qemu-ga already reaped the process without retaining its output;
        # re-run over WinRM (guest scripts are written idempotent).
        echo "guest-run: exec status lost (PID reaped), re-running over WinRM" >&2
        exec bash "$(dirname "$0")/guest-winrm.sh" "$@"
    fi
    # An "exitcode" key only appears once the process has exited. Its value
    # is base64 out-data/err-data (there is NO "stdout" key — decoding
    # nothing was the silent-empty-output bug).
    if echo "$resp" | grep -q '"exitcode":'; then
        echo "$resp" | python3 -c 'import base64,json,sys
d=json.load(sys.stdin)["return"]
sys.stdout.buffer.write(base64.b64decode(d.get("out-data","")))
sys.stdout.buffer.flush()
sys.stderr.buffer.write(base64.b64decode(d.get("err-data","")))
sys.stderr.buffer.flush()
sys.exit(d.get("exitcode",0))' || exit $?
        exit 0
    fi
    sleep 1
done
echo "error: guest command timed out" >&2
exit 124
