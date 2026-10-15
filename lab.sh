#!/bin/bash
# folval lab orchestrator — single entrypoint for the whole pipeline.
#
# VM (libvirt/vagrant/packer):
#   ./lab.sh vm:build            Packer build of the box (writes logs/build.log)
#   ./lab.sh vm:add              Import the built .box into vagrant
#   ./lab.sh vm:up               Start the isolated VM (vagrant up; logs/up.log)
#   ./lab.sh vm:down             Shut the VM down (vagrant halt)
#   ./lab.sh vm:destroy          vagrant destroy (box stays imported)
#   ./lab.sh vm:verify           Phase 1 gate: domain up + WinRM round-trip
#   ./lab.sh vm:license          Show Windows activation state (slmgr /dli)
#   ./lab.sh vm:snapshot [name]  Internal qcow2 snapshot (default: folval-<ts>)
#   ./lab.sh vm:snapshot-rollback [name]  Revert to a snapshot (default: newest)
#   ./lab.sh vm:provision        Phase 3: run vm/debloat.ps1 in the guest
#                                (via qemu-ga; vagrant upload path is broken on
#                                this host), after a pre-debloat snapshot
#   ./lab.sh vm:rebuild [--force]  packer build -> box import -> up -> verify
#
# Gateway (folval-gw mock gateway, server/):
#   ./lab.sh gateway:build       go build + go test (binary: server/folval-gw)
#   ./lab.sh gateway:run         Start folval-gw in the background
#                                (events -> logs/gateway.jsonl, pid -> logs/folval-gw.pid)
#   ./lab.sh gateway:status      Is folval-gw running?
#   ./lab.sh gateway:stop        Stop the background folval-gw
#
#   (re)build needs a 1Password approval popup for the license key read.
#   The .box contains the keyed Windows image: it is gitignored and must
#   never leave this machine.
set -euo pipefail
cd "$(dirname "$0")"

BOX_NAME="folval/win10-ltsc-2021"
BOX_FILE="packer/output/folval-win10-ltsc-2021.box"
BUILD_LOG="logs/build.log"
DOMAIN="folly-n-valor_default"
VIRSH="virsh -c qemu:///system"

GW_BIN="server/folval-gw"
GW_PID="logs/folval-gw.pid"
GW_OUT="logs/gateway.jsonl"

# Run a command, prefixing every output line with a timestamp and appending
# to $BUILD_LOG. Returns the command's own exit status (pipefail propagates
# packer's failure even though tee/while succeed).
ts_run() {
  local rc=0 log="$1"
  shift
  "$@" 2>&1 | while IFS= read -r line; do
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" | tee -a "$log"
  done || rc=$?
  return $rc
}

case "${1:-}" in
  vm:build)
    echo "==== folval build started $(date '+%Y-%m-%d %H:%M:%S') on $(hostname) ====" > "$BUILD_LOG"
    ts_run "$BUILD_LOG" bash packer/build.sh build
    ;;
  vm:add)
    if [ ! -f "$BOX_FILE" ]; then
      echo "No box at $BOX_FILE — run './lab.sh vm:build' first." >&2
      exit 1
    fi
    vagrant box add --force "$BOX_NAME" "$BOX_FILE"
    ;;
  vm:up)
    echo "==== folval up started $(date '+%Y-%m-%d %H:%M:%S') on $(hostname) ====" > logs/up.log
    ts_run logs/up.log vagrant up
    ;;
  vm:verify)
    echo "== libvirt domains =="
    virsh -c qemu+unix:///system list --all | grep -E "Name|folly" || true
    echo "== WinRM round-trip =="
    if vagrant winrm -c "echo ok"; then
      echo "GATE: Phase 1 verification PASSED"
    else
      echo "GATE: Phase 1 verification FAILED" >&2
      exit 1
    fi
    ;;
  vm:rebuild)
    if [ "${2:-}" = "--force" ]; then
      echo "== Cleaning up old assets (FORCE mode) =="
      rm -rf packer/output-win-ltsc
    fi
    bash "$0" vm:build
    bash "$0" vm:add
    bash "$0" vm:up
    bash "$0" vm:verify
    ;;
  vm:license)
    # NB: vagrant winrm -c runs via PowerShell — %windir% is NOT expanded
    # there (it arrived as a literal Documents-relative path once).
    vagrant winrm -c "cscript //nologo C:\\Windows\\System32\\slmgr.vbs /dli"
    ;;
  vm:snapshot)
    name="${2:-folval-$(date '+%Y%m%d-%H%M%S')}"
    echo "== creating snapshot $name on $DOMAIN =="
    $VIRSH snapshot-create-as --domain "$DOMAIN" --name "$name"
    $VIRSH snapshot-list "$DOMAIN"
    ;;
  vm:snapshot-rollback)
    if [ -n "${2:-}" ]; then
      echo "== reverting $DOMAIN to snapshot $2 =="
      $VIRSH snapshot-revert --domain "$DOMAIN" --snapshotname "$2" --running
    else
      echo "== reverting $DOMAIN to current snapshot =="
      $VIRSH snapshot-revert --domain "$DOMAIN" --current --running
    fi
    ;;
  vm:provision)
    # Deliver vm/debloat.ps1 without any guest-side upload path: encode as
    # UTF-16LE base64 (PowerShell -EncodedCommand) and run via qemu-ga.
    script_b64=$(iconv -f UTF-8 -t UTF-16LE vm/debloat.ps1 | base64 -w0)
    echo "== taking pre-provision snapshot =="
    bash "$0" vm:snapshot pre-provision-"$(date '+%Y%m%d-%H%M%S')"
    echo "== provisioning quiet guest (vm/debloat.ps1) =="
    exec_json=$(printf '{"execute":"guest-exec","arguments":{"path":"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe","arg":["-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand","%s"],"capture-output":true}}' "$script_b64")
    pid_json=$($VIRSH qemu-agent-command "$DOMAIN" "$exec_json")
    pid=$(printf '%s' "$pid_json" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
    if [ -z "$pid" ]; then
      echo "guest-exec failed: $pid_json" >&2; exit 1
    fi
    # Poll for completion (script takes seconds to a minute).
    while :; do
      st=$($VIRSH qemu-agent-command "$DOMAIN" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")
      printf '%s' "$st" | grep -q '\"exited\":true' && break
      sleep 2
    done
    printf '%s' "$st" | sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p' | base64 -d
    printf '%s' "$st" | sed -n 's/.*"err-data":"\([^"]*\)".*/\1/p' | base64 -d >&2 || true
    if printf '%s' "$st" | grep -q '\"exitcode\":0'; then
      echo "PROVISION: ok"
    else
      echo "PROVISION: FAILED" >&2; exit 1
    fi
    ;;
  vm:down)
    vagrant halt
    ;;
  vm:destroy)
    vagrant destroy
    ;;
  gateway:build)
    (cd server && go build ./cmd/folval-gw && go vet ./... && go test ./...)
    echo "gateway: built $GW_BIN (vet + tests green)"
    ;;
  gateway:run)
    if [ -f "$GW_PID" ] && kill -0 "$(cat "$GW_PID")" 2>/dev/null; then
      echo "gateway: already running (pid $(cat "$GW_PID"))" >&2
      exit 1
    fi
    nohup "$GW_BIN" -out "$GW_OUT" >/dev/null 2>&1 &
    echo $! > "$GW_PID"
    sleep 1
    if kill -0 "$(cat "$GW_PID")" 2>/dev/null; then
      echo "gateway: running (pid $(cat "$GW_PID")), events -> $GW_OUT"
    else
      echo "gateway: failed to start — try './lab.sh gateway:build' or run $GW_BIN in the foreground" >&2
      rm -f "$GW_PID"
      exit 1
    fi
    ;;
  gateway:status)
    if [ -f "$GW_PID" ] && kill -0 "$(cat "$GW_PID")" 2>/dev/null; then
      echo "gateway: running (pid $(cat "$GW_PID"))"
    else
      echo "gateway: not running"
    fi
    ;;
  gateway:stop)
    if [ -f "$GW_PID" ] && kill -0 "$(cat "$GW_PID")" 2>/dev/null; then
      kill "$(cat "$GW_PID")"
      rm -f "$GW_PID"
      echo "gateway: stopped"
    else
      echo "gateway: not running"
      rm -f "$GW_PID"
    fi
    ;;
  *)
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
