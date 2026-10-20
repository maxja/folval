#!/bin/bash
# folval — run a Frida JS script in a guest process WITHOUT the frida REPL.
#
# The frida CLI drops into an interactive REPL after loading a script; -q
# only suppresses the banner. Redirecting stdin from /dev/null makes the
# CLI exit after the script loads, which works for one-shots but is fragile
# (output buffering, no message routing, no clean detach). This runner
# drives the Python API instead: deterministic load -> bounded wait (or
# Ctrl-C) -> clean detach; console.log and send() both land on stdout as
# they arrive.
#
# Usage:
#   bash host/tools/frida-run.sh <pid|name> <script.js> [wait_s]    # attach
#   bash host/tools/frida-run.sh --spawn <image> <script.js> [wait_s]
#
# FOLVAL_SCRIPT_ENV='<json>' (optional): injected into the script source as
# global `var FOLVAL_SCRIPT_ENV = <json>;` — per-run config WITHOUT editing
# the probe (e.g. gpu_shim.js bisect overrides: '{"gpu":{"flags":32}}').
#
# <script.js> may be a COMMA-SEPARATED LIST (a,b): sources are concatenated
# into one script — composable probes (e.g. gpu_shim.js,steam_probe.js).
#
# wait_s: seconds to stay attached (default 10); 0 = until Ctrl-C.
# Attach accepts a guest PID or an exact process name (case-insensitive).
# NB: --spawn launches under frida-server (SYSTEM, session 0) — right for
# headless probes; for the game attach to the desktop-launched process.
# Spawned processes are killed on exit (probes must not outlive the run).
set -euo pipefail
cd "$(dirname "$0")/../.."

GUEST="${FOLVAL_GUEST_IP:-192.168.100.10}"
FRIDA_PORT="${FOLVAL_FRIDA_PORT:-27042}"   # 27043 = user-session server (desktop attaches)

if [[ "${1:-}" == "--spawn" ]]; then
    mode=spawn
    image="${2:?--spawn needs an image path, e.g. C:\\Windows\\System32\\notepad.exe}"
    shift 2
    target="$image"
else
    mode=attach
    target="${1:?usage: frida-run.sh <pid|name> <script.js> [wait_s] | --spawn <image> <script.js> [wait_s]}"
    shift
fi
script="${1:?usage: frida-run.sh <pid|name> <script.js> [wait_s]}"
shift || true
wait_s="${1:-10}"

# Evidence tee: every send()/log/error line is appended as JSON to out/.
# Contents may embed title identity — out/ is gitignored except .gitkeep.
mkdir -p out
run_ts=$(date +%Y%m%d-%H%M%S)
run_tag=$(basename "$script" .js)
# tag: last path component of the target (pid, name, or image), sanitized
run_tgt=$(printf '%s' "${target##*\\}" | tr -c 'A-Za-z0-9._-' '_')
run_tgt="${run_tgt%%_*}"
: "${run_tgt:=spawn}"
export FOLVAL_RUN_OUT="out/${run_ts}-${run_tgt}-${run_tag}.jsonl"

echo "[frida-run] evidence -> $FOLVAL_RUN_OUT" >&2

exec host/frida-venv/bin/python - "$GUEST:$FRIDA_PORT" "$mode" "$target" "$script" "$wait_s" <<'PYEOF'
import frida, json, os, sys, time

guest, mode, target, script_path, wait_s = sys.argv[1:6]
wait_s = float(wait_s)

out_path = os.environ.get("FOLVAL_RUN_OUT")
out_file = open(out_path, "a", encoding="utf-8") if out_path else None

def rec(kind, **fields):
    if out_file:
        out_file.write(json.dumps({"ts": round(time.time(), 3), "kind": kind, **fields}) + "\n")
        out_file.flush()

dev = frida.get_device_manager().add_remote_device(guest)

if mode == "spawn":
    argv = [target]
    if os.environ.get("FOLVAL_SPAWN_ARGS"):
        import shlex
        argv += shlex.split(os.environ["FOLVAL_SPAWN_ARGS"])
    spawn_opts = {}
    if os.environ.get("FOLVAL_SPAWN_ENV"):
        spawn_opts["env"] = dict(item.split("=", 1) for item in
                                 os.environ["FOLVAL_SPAWN_ENV"].split(";"))
    if os.environ.get("FOLVAL_SPAWN_CWD"):
        spawn_opts["cwd"] = os.environ["FOLVAL_SPAWN_CWD"]
    pid = dev.spawn(argv, **spawn_opts)
    print(f"[frida-run] spawned {argv} as pid {pid}", file=sys.stderr, flush=True)
else:
    if target.isdigit():
        pid = int(target)
    else:
        matches = [p for p in dev.enumerate_processes() if p.name.lower() == target.lower()]
        if not matches:
            sys.exit(f"[frida-run] no guest process named {target!r}")
        pid = matches[0].pid
    print(f"[frida-run] attaching to {target} (pid {pid})", file=sys.stderr, flush=True)

session = dev.attach(pid)

def on_message(message, data):
    if message["type"] == "send":
        suffix = f" (+{len(data)}B binary)" if data else ""
        print(f"[send] {message['payload']}{suffix}", flush=True)
        rec("send", payload=message["payload"], bin=len(data) if data else 0)
    elif message["type"] == "error":
        print(f"[error] {message.get('stack') or message.get('description')}", flush=True)
        rec("error", text=message.get("description"), stack=message.get("stack"))
    else:
        print(f"[{message['type']}] {message}", flush=True)
        rec(message["type"], text=str(message))

def on_log(level, text):
    print(f"[{level}] {text}", flush=True)
    rec("log", level=level, text=text)

try:
    src = "".join(open(p, encoding="utf-8").read() + "\n\n" for p in script_path.split(","))
    env_cfg = os.environ.get("FOLVAL_SCRIPT_ENV")
    if env_cfg:
        env_cfg = json.dumps(json.loads(env_cfg))  # validate + canonical
        src = "var FOLVAL_SCRIPT_ENV = " + env_cfg + ";\n" + src
        print(f"[frida-run] FOLVAL_SCRIPT_ENV = {env_cfg}", file=sys.stderr, flush=True)
    script = session.create_script(src)
    script.on("message", on_message)
    script.set_log_handler(on_log)
    script.load()
    if mode == "spawn":
        dev.resume(pid)
    tail = f"waiting {wait_s:g}s" if wait_s > 0 else "Ctrl-C to detach"
    print(f"[frida-run] {script_path} loaded into pid {pid}; {tail}", file=sys.stderr, flush=True)
    try:
        if wait_s > 0:
            time.sleep(wait_s)
        else:
            while True:
                time.sleep(3600)
    except KeyboardInterrupt:
        pass
    session.detach()
    if mode == "spawn":
        try:
            dev.kill(pid)
            print(f"[frida-run] killed spawned pid {pid}", file=sys.stderr)
        except frida.InvalidOperationError:
            pass
    print("[frida-run] detached cleanly", file=sys.stderr)
    rec("meta", event="detach", target=target, script=script_path)
    if out_file:
        out_file.close()
finally:
    pass
PYEOF
