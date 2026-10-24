#!/bin/bash
# folval — push a host file into the guest via qemu-ga guest-file-* commands
# (works with NO guest network at all). Usage: guest-push-ga.sh <local> <guest-path>
set -euo pipefail
cd "$(dirname "$0")/../.."
local="${1:?local file}"; guest="${2:?guest dest path}"
dom=$(virsh -c qemu+unix:///system list --name 2>/dev/null | grep -m1 -v '^\s*$')

open_resp=$(virsh -c qemu+unix:///system qemu-agent-command "$dom" --timeout 30 \
  "$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-file-open","arguments":{"path":sys.argv[1],"mode":"w"}}))' "$guest")")
handle=$(printf '%s' "$open_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"])')
export HANDLE="$handle"
trap 'virsh -c qemu+unix:///system qemu-agent-command "$dom" --timeout 15 "$(python3 -c "import json,os; print(json.dumps({\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":int(os.environ[\"HANDLE\"])}}))")" >/dev/null 2>&1 || true' EXIT

# write in ~3KB raw-byte chunks (-> ~4KB b64, under QMP limits)
chunk_cmds=$(python3 - "$local" <<'EOF'
import base64, json, os, sys
data = open(sys.argv[1], 'rb').read()
CH = 3072
for off in range(0, len(data), CH):
    chunk = base64.b64encode(data[off:off+CH]).decode()
    print(json.dumps({"execute": "guest-file-write",
                      "arguments": {"handle": int(os.environ["HANDLE"]), "buf-b64": chunk}}))
EOF
)
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  resp=$(virsh -c qemu+unix:///system qemu-agent-command "$dom" --timeout 15 "$cmd" 2>&1)
  printf '%s' "$resp" | grep -q '"count"' || { echo "push failed: $resp" >&2; exit 1; }
done <<< "$chunk_cmds"
echo "pushed $local -> $guest (handle $handle)"
