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
#   ./lab.sh firewall:deploy     install host/firewall/folval.nft to /etc + restart service
#   ./lab.sh gateway:build       go build + go test (binary: server/folval-gw)
#   ./lab.sh gateway:run         Start folval-gw in the background
#                                (events -> logs/gateway.jsonl, pid -> logs/folval-gw.pid)
#   ./lab.sh gateway:oracle      Same, plus -forward 8443->guest:8443 (D9 oracle:
#                                tlsprobe replaced by a TCP relay to the in-guest
#                                reference server; pcap ring records the conversation)
#   ./lab.sh gateway:gameserver  Phase 5: serve the observed .hqs routes ourselves
#                                over TLS (stable PEM + captured account JSON from
#                                tmp/ when staged; replaces the oracle forward)
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
#                                    (gitignored; holds STEAM_USER and/or
#                                    op:// refs STEAM_USER_FILE / STEAM_PASS_FILE,
#                                    resolved via the 1Password CLI — needs an
#                                    active op session, as in the (re)build flow;
#                                    2FA/Steam Guard codes are still typed)
#
# Evidence hygiene (raw captures/logs/probe-output are DISPOSABLE; distilled
# knowledge lives in re/docs + out/EVIDENCE.md — see that file for the track
# & clean workflow):
#   ./lab.sh evidence:status        Inventory captures/pcap, logs/, out/:
#                                    sizes, per-ring pcap coverage windows
#                                    (first/last packet, via capinfos), ring
#                                    liveness, and what evidence:clean would
#                                    keep vs remove. Read-only.
#   ./lab.sh evidence:clean [--force]
#                                   DRY-RUN by default. Removes:
#                                     - logs/*         (except .gitkeep)
#                                     - captures/pcap stale-era rings (bases
#                                       still being written are kept; a base
#                                       with any member touched <15 min ago
#                                       counts as live)
#                                     - out/*          (except .keep list +
#                                       EVIDENCE.md + keepers themselves)
#   ./lab.sh capture:install       (Re)deploy host/capture/folval-capture.service
#                                   as root — run from a HOST shell:
#                                   sudo ./host/capture/install.sh (this
#                                   wrapper just execs it; agent shell has
#                                   no sudo)
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

# Evidence hygiene (see the header docs + out/EVIDENCE.md)
PCAP_DIR="captures/pcap"
PCAP_STALE_MIN=15 # ring base with a member touched this recently = LIVE
OUT_KEEP="out/.keep"

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

# Resolve Steam auth from op:// references in the env file (D4 pattern: only
# the non-secret reference is stored; the value is fetched at run time).
# Needs an active 1Password session, same as the (re)build license flow.
resolve_steam_auth() {
  if [ -n "${STEAM_USER_FILE:-}" ]; then
    STEAM_USER=$(op read "$STEAM_USER_FILE") || {
      echo "op read failed for STEAM_USER_FILE — check your 1Password session ('op account list')" >&2
      exit 1
    }
  fi
  if [ -n "${STEAM_PASS_FILE:-}" ]; then
    STEAM_PASS=$(op read "$STEAM_PASS_FILE") || {
      echo "op read failed for STEAM_PASS_FILE — check your 1Password session ('op account list')" >&2
      exit 1
    }
  fi
}

# Ring base of a tcpdump ring member: strip the trailing 2-digit index
# (folval-20261019-101500.pcap07 -> folval-20261019-101500.pcap; legacy
# pre-2026-10-19 folval.pcap03 -> folval.pcap).
pcap_base() {
  printf '%s' "$1" | sed -E 's/[0-9]{2}$//'
}

# Ring bases presumed LIVE (clean must not touch them):
#   (a) the base in a running tcpdump -w argument, if pgrep can see it —
#       NOTE: from the agent/zed container the host PID namespace is
#       invisible, so this check alone is NOT trustworthy;
#   (b) any base with a member modified < PCAP_STALE_MIN minutes ago — the
#       sealed guest's NCSI retries keep a live ring's mtimes fresh, so
#       recency is the namespace-proof liveness signal.
pcap_live_bases() {
  local f b age bases=""
  local w=""
  w=$(pgrep -af tcpdump 2>/dev/null | grep -oE ' -w [^ ]+' | head -1 | awk '{print $2}') || true
  if [ -n "$w" ]; then
    bases=" $(basename "$(pcap_base "$w")") "
  fi
  for f in "$PCAP_DIR"/*; do
    if [ -f "$f" ]; then
      b=$(basename "$f")
      if [ "$b" != ".gitkeep" ]; then
        b=$(pcap_base "$b")
        case "$bases" in
          *" $b "*) ;;
          *)
            age=$(( $(date +%s) - $(stat -c %Y "$f") ))
            if [ "$age" -lt $((PCAP_STALE_MIN * 60)) ]; then
              bases="$bases $b "
            fi
            ;;
        esac
      fi
    fi
  done
  printf '%s' "$bases"
}

# Keep-list membership for out/: special files plus anything listed verbatim
# (one filename per line) in out/.keep.
out_keep() {
  case "$1" in
    .keep|EVIDENCE.md|.gitkeep) return 0 ;;
  esac
  if [ -f "$OUT_KEEP" ] && grep -qxF -- "$1" "$OUT_KEEP"; then
    return 0
  fi
  return 1
}

# Start folval-gw in the background with optional extra flags (shared by
# gateway:run and gateway:oracle).
gw_start() {
  if [ -f "$GW_PID" ] && kill -0 "$(cat "$GW_PID")" 2>/dev/null; then
    echo "gateway: already running (pid $(cat "$GW_PID"))" >&2
    exit 1
  fi
  # /push/ serves host/push (staging dir for guest-bound files, e.g. the
  # D5 game tarball); created on demand, gitignored except .gitkeep.
  mkdir -p host/push
  nohup "$GW_BIN" -out "$GW_OUT" -pushdir host/push "$@" >/dev/null 2>&1 &
  echo $! > "$GW_PID"
  sleep 1
  if kill -0 "$(cat "$GW_PID")" 2>/dev/null; then
    echo "gateway: running (pid $(cat "$GW_PID")), events -> $GW_OUT"
  else
    echo "gateway: failed to start — try './lab.sh gateway:build' or run $GW_BIN in the foreground" >&2
    rm -f "$GW_PID"
    exit 1
  fi
}

case "${1:-}" in
  firewall:deploy)
    # The live ruleset is /etc/folval/folval.nft (loaded by folval-firewall
    # at boot); the repo copy is source-of-truth but does NOT auto-apply.
    # Editing host/firewall/folval.nft MUST be followed by this deploy or a
    # host reboot silently reverts to the stale ruleset (2026-10-21 lesson).
    sudo install -m 644 host/firewall/folval.nft /etc/folval/folval.nft
    sudo systemctl restart folval-firewall
    systemctl is-active folval-firewall
    ;;
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
    gw_start
    ;;
  gateway:oracle)
    # D9 oracle mode: the tlsprobe listener becomes a TCP relay to the
    # in-guest reference server (:8443), so the game's TLS gets ANSWERED
    # while the pcap ring records the full conversation on the wire.
    gw_start -forward "192.168.100.1:8443->192.168.100.10:8443"
    ;;
  gateway:gameserver)
    # Phase 5: folval-gw serves the .hqs routes ITSELF over TLS (the two
    # routes observed in the D9 decrypt) instead of relaying to the
    # in-guest reference server. Uses the oracle's stable PEM when staged
    # (guest-pull re-server-key.pem -> tmp/gateway/) so guest trust and keylog
    # decryption carry over; account JSON from the captured convo
    # (tmp/gateway/account.json). Stage once:
    #   bash host/tools/guest-pull.sh 'C:\re\server\re-server-key.pem' tmp/gateway/re-server-key.pem
    #   grep '^{"Result"' tmp/d9/decrypted/convo387.txt > tmp/gateway/account.json
    GW_CERT=tmp/gateway/re-server-key.pem
    GW_ACC=tmp/gateway/account.json
    GW_KEYLOG=tmp/gateway/sslkeys-gw.log
    GW_ARGS=(-gameserver 192.168.100.1:8443 -gameserver-keylog "$GW_KEYLOG")
    [ -f "$GW_CERT" ] && GW_ARGS+=(-gameserver-cert "$GW_CERT")
    [ -f "$GW_ACC" ] && GW_ARGS+=(-gameserver-account "$GW_ACC")
    gw_start "${GW_ARGS[@]}"
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
    resolve_steam_auth
    if [ -n "${STEAM_USER:-}" ] && [ -n "${STEAM_PASS:-}" ]; then
      echo "== steamcmd login (account + password resolved from 1Password via $STEAM_ENV) =="
      echo "== if Steam asks for a 2FA / Steam Guard code, type it at the prompt =="
      exec "$STEAMCMD_DIR/steamcmd.sh" "+login" "$STEAM_USER" "$STEAM_PASS"
    elif [ -n "${STEAM_USER:-}" ]; then
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
    resolve_steam_auth
    appid="${2:-${STEAM_APP_ID:-}}"
    if [ -z "$appid" ]; then
      echo "usage: ./lab.sh steam:download <appid>" >&2
      echo "       (or set STEAM_APP_ID in $STEAM_ENV)" >&2
      exit 1
    fi
    if [ -n "${STEAM_PASS:-}" ] && [ -z "${STEAM_USER:-}" ]; then
      echo "a password was resolved but no account — set STEAM_USER (or STEAM_USER_FILE) in $STEAM_ENV" >&2
      exit 1
    fi
    if [ -n "${STEAM_USER:-}" ] && [ -n "${STEAM_PASS:-}" ]; then
      echo "== steamcmd: app_update $appid validate (login $STEAM_USER via 1Password; type a 2FA/Steam Guard code if prompted) =="
      exec "$STEAMCMD_DIR/steamcmd.sh" "+login" "$STEAM_USER" "$STEAM_PASS" "+app_update" "$appid" "validate" "+quit"
    elif [ -n "${STEAM_USER:-}" ]; then
      echo "== steamcmd: app_update $appid validate (login: $STEAM_USER; may prompt for password/2FA if the session expired) =="
      exec "$STEAMCMD_DIR/steamcmd.sh" "+login" "$STEAM_USER" "+app_update" "$appid" "validate" "+quit"
    fi
    echo "== steamcmd: app_update $appid validate (using cached session if any; console may prompt for login) =="
    exec "$STEAMCMD_DIR/steamcmd.sh" "+app_update" "$appid" "validate" "+quit"
    ;;
  evidence:status)
    echo "== tcpdump (may be hidden by the container PID namespace) =="
    pgrep -af tcpdump || echo "(not visible from this shell)"
    echo
    live=$(pcap_live_bases)
    echo "== $PCAP_DIR ($(du -sh "$PCAP_DIR" | cut -f1)) — live bases:${live:- none} =="
    for f in "$PCAP_DIR"/*; do
      [ -f "$f" ] || continue
      b=$(basename "$f")
      [ "$b" = ".gitkeep" ] && continue
      cov=""
      if command -v capinfos >/dev/null 2>&1; then
        cov=$(capinfos -a -e "$f" 2>/dev/null | awk -F': ' '
          / packet time:/ {n++; if (n==1) f=$2; else l=$2}
          END {if (f!="") printf "  %s .. %s", f, l}')
      fi
      [ -z "$cov" ] && cov="  (mtimes) $(stat -c %y "$f" | cut -d. -f1)"
      state=STALE
      case "$live" in *" $(pcap_base "$b") "*) state=LIVE;; esac
      printf '  %-6s %-42s %10s%s\n' "$state" "$b" "$(du -h "$f" | cut -f1)" "$cov"
    done | sort -k2
    echo
    echo "== logs/ ($(du -sh logs | cut -f1)) — all contents are cleanable =="
    find logs -mindepth 1 ! -name '.gitkeep' -printf '  %10s  %p\n' | sort -k2 || true
    echo
    echo "== out/ ($(du -sh out | cut -f1)) — keepers per out/.keep =="
    for f in out/*; do
      [ -e "$f" ] || continue
      b=$(basename "$f")
      if out_keep "$b"; then state=KEEP; else state=CLEAN; fi
      printf '  %-6s %10s  %s\n' "$state" "$(du -h "$f" | cut -f1)" "$b"
    done | sort -k4
    echo
    echo "next: ./lab.sh evidence:clean          (dry run)"
    echo "      ./lab.sh evidence:clean --force   (delete)"
    ;;
  evidence:clean)
    force="${2:-}"
    if [ "$force" != "--force" ] && [ -n "$force" ]; then
      echo "usage: ./lab.sh evidence:clean [--force]" >&2
      exit 1
    fi
    live=$(pcap_live_bases)
    echo "live ring bases (kept):${live:- none}"
    echo
    # --- logs/ ---
    echo "== logs/ (all except .gitkeep) =="
    for f in logs/*; do
      if [ -e "$f" ] && [ "$(basename "$f")" != ".gitkeep" ]; then
        s=$(stat -c %s "$f")
        echo "  rm $f ($s bytes)"
        if [ "$force" = "--force" ]; then rm -f "$f"; fi
      fi
    done
    # --- captures/pcap ---
    echo "== $PCAP_DIR (stale-era rings) =="
    for f in "$PCAP_DIR"/*; do
      if [ -f "$f" ] && [ "$(basename "$f")" != ".gitkeep" ]; then
        case "$live" in
          *" $(pcap_base "$(basename "$f")") "*) ;;
          *)
            s=$(stat -c %s "$f")
            echo "  rm $f ($s bytes)"
            if [ "$force" = "--force" ]; then rm -f "$f"; fi
            ;;
        esac
      fi
    done
    # --- out/ ---
    echo "== out/ (everything not in .keep) =="
    for f in out/*; do
      if [ -e "$f" ] && ! out_keep "$(basename "$f")"; then
        s=$(stat -c %s "$f")
        echo "  rm $f ($s bytes)"
        if [ "$force" = "--force" ]; then rm -f "$f"; fi
      fi
    done
    echo
    if [ "$force" = "--force" ]; then
      echo "clean: done (live rings and keepers preserved)"
    else
      echo "clean: DRY RUN — pass --force to delete the files above"
    fi
    ;;
  capture:install)
    exec bash host/capture/install.sh
    ;;
  *)
    sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
