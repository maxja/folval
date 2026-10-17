#!/bin/bash
# folval — one-shot qemu-ga script dispatch: send guest-exec and RETURN
# IMMEDIATELY without polling guest-exec-status. Use for quick fire-and-forget
# guest scripts where output doesn't matter: every guest-exec-status poll is a
# separate virsh connection (= a separate polkit prompt on hosts where the user
# is not in the libvirt group), so guest-run.sh's 2 s poll loop costs one auth
# dialog per poll. Here: exactly one connection per invocation.
# Output is not captured — verify effects host-side or with guest-run.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

DOMAIN="folly-n-valor_default"

script_b64=$(iconv -f UTF-8 -t UTF-16LE "$1" | base64 -w0)
exec_json=$(printf '{"execute":"guest-exec","arguments":{"path":"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe","arg":["-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand","%s"],"capture-output":true}}' "$script_b64")
virsh -c qemu:///system qemu-agent-command "$DOMAIN" "$exec_json"
