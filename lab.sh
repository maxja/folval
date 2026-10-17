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
# Tools (host-side, D5 acquisition):
#   ./lab.sh tools:steamcmd [--force]  Install steamcmd into host/steamcmd/
#                                      (gitignored; first run self-updates and
#                                      needs host internet)
#
# Steam (D5 acquisition via the host steamcmd above):
#   ./lab.sh steam:login             Interactive steamcmd login (password/2FA
#                                    typed at the prompt; session cached in
#                                    ~/.local/share/Steam for later commands)
#   ./lab.sh steam:download [appid]  +app_update <appid> validate — download or
#                                    re-verify the title; appid from the argument
#                                    or STEAM_APP_ID in host/steamcmd/steam.env
#                                    (gitignored; also holds STEAM_USER)
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

STEAMCMD_DIR="host/steamcmd"
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
# Local baseline (verified 2026-10-17); Valve publishes no official checksum.
STEAMCMD_SHA256="cebf0046bfd08cf45da6bc094ae47aa39ebf4155e5ede41373b579b8f1071e7c"
STEAM_ENV="host/steamcmd/steam.env" # gitignored: STEAM_USER, STEAM_APP_ID

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

# D5 helpers: steamcmd must be installed first; optional gitignored env file
# carries the Steam account name and app id (secrets stay out of the repo).
require_steamcmd() {
  if [ ! -x "$STEAMCMD_DIR/linux32/steamcmd" ]; then
    echo "steamcmd not installed — run './lab.sh tools:steamcmd' first." >&2
    exit 1
  fi
}

load_steam_env() {
  if [ -f "$STEAM_ENV" ]; then
    . "$STEAM_ENV"
  fi
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
  tools:steamcmd)
    force="${2:-}"
    if [ -x "$STEAMCMD_DIR/linux32/steamcmd" ] && [ "$force" != "--force" ]; then
      echo "steamcmd: already installed at $STEAMCMD_DIR (pass --force to reinstall)"
      exit 0
    fi
    if [ "$force" = "--force" ]; then
      rm -rf "$STEAMCMD_DIR"
    fi
    mkdir -p "$STEAMCMD_DIR"
    tgz="$STEAMCMD_DIR/.steamcmd_linux.tar.gz"
    echo "== downloading steamcmd ($STEAMCMD_URL) =="
    if command -v aria2c >/dev/null 2>&1; then
      aria2c -x 16 -s 16 --allow-overwrite=true -d "$STEAMCMD_DIR" -o .steamcmd_linux.tar.gz "$STEAMCMD_URL"
    else
      curl -fsSL --retry 3 -o "$tgz" "$STEAMCMD_URL"
    fi
    actual=$(sha256sum "$tgz" | cut -d' ' -f1)
    if [ "$actual" != "$STEAMCMD_SHA256" ]; then
      echo "steamcmd: SHA-256 mismatch: got $actual, want $STEAMCMD_SHA256 — not installing" >&2
      exit 1
    fi
    echo "== extracting to $STEAMCMD_DIR =="
    tar xzf "$tgz" -C "$STEAMCMD_DIR"
    rm -f "$tgz"
    echo "steamcmd: installed at $STEAMCMD_DIR/steamcmd.sh"
    echo "Next: ./lab.sh steam:login  (then ./lab.sh steam:download <appid>)"
    ;;
  steam:login)
    require_steamcmd
    load_steam_env
    if [ -n "${STEAM_USER:-}" ]; then
      echo "== steamcmd login (account pre-filled from $STEAM_ENV) =="
      echo "== type the password (and any 2FA code) when prompted; session caches in ~/.local/share/Steam =="
      exec "$STEAMCMD_DIR/steamcmd.sh" "+login" "$STEAM_USER"
    fi
    echo "== steamcmd console: type 'login' at the prompt, then account/password/2FA =="
    echo "== (tip: put STEAM_USER=... in $STEAM_ENV to pre-fill the account) =="
    exec "$STEAMCMD_DIR/steamcmd.sh"
    ;;
  steam:download)
    require_steamcmd
    load_steam_env
    appid="${2:-${STEAM_APP_ID:-}}"
    if [ -z "$appid" ]; then
      echo "usage: ./lab.sh steam:download <appid>" >&2
      echo "       (or set STEAM_APP_ID in $STEAM_ENV)" >&2
      exit 1
    fi
    if [ -n "${STEAM_USER:-}" ]; then
      echo "== steamcmd: app_update $appid validate (login: $STEAM_USER; may prompt for password/2FA if the session expired) =="
      exec "$STEAMCMD_DIR/steamcmd.sh" "+login" "$STEAM_USER" "+app_update" "$appid" "validate" "+quit"
    fi
    echo "== steamcmd: app_update $appid validate (using cached session if any; console may prompt for login) =="
    exec "$STEAMCMD_DIR/steamcmd.sh" "+app_update" "$appid" "validate" "+quit"
    ;;
  *)
    sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
