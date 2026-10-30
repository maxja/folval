#!/usr/bin/env bash
# Run a command inside folval3 as SYSTEM via the QEMU guest agent (API-only).
# Usage: qga-exec.sh "command line"   (long output trimmed to ~64KB by PVE)
set -euo pipefail
cd "$(dirname "$0")"
exec op run --env-file=.env.secrets -- bash -c '
  set -uo pipefail
  EP="$PROXMOX_VE_ENDPOINT"
  H="Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN"
  CMD="$1"
  RESP=$(curl -sk -X POST -H "$H" --data-urlencode "command=$CMD" "$EP/api2/json/nodes/pve/qemu/300/agent/exec")
  PID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"data\"][\"pid\"])" 2>/dev/null) \
    || { echo "EXEC-START-FAILED: $RESP"; exit 1; }
  for i in $(seq 1 90); do
    sleep 2
    R=$(curl -sk -H "$H" "$EP/api2/json/nodes/pve/qemu/300/agent/exec/$PID")
    EX=$(echo "$R" | python3 -c "import json,sys; d=(json.load(sys.stdin)[\"data\"] or {}); print(d.get(\"exited\",\"\"))" 2>/dev/null)
    if [ "$EX" = "1" ]; then
      echo "$R" | python3 -c "
import json,sys,base64
d=json.load(sys.stdin)[\"data\"]
out=base64.b64decode(d.get(\"out-data\",\"\")).decode(errors=\"replace\")
err=base64.b64decode(d.get(\"err-data\",\"\")).decode(errors=\"replace\")
print(out)
if err.strip(): print(err, file=sys.stderr)
"
      exit 0
    fi
  done
  echo "TIMEOUT waiting for guest command"
  exit 1
' _ "$1"
