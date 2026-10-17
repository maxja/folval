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
# wait_s: seconds to stay attached (default 10); 0 = until Ctrl-C.
# Attach accepts a guest PID or an exact process name (case-insensitive).
# NB: --spawn launches under frida-server (SYSTEM, session 0) — right for
# headless probes; for the game attach to the desktop-launched process.
# Spawned processes are killed on exit (probes must not outlive the run).
set -euo pipefail
cd "$(dirname "$0")/../.."

GUEST="${FOLVAL_GUEST_IP:-192.168.100.10}"

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

exec host/frida-venv/bin/python - "$GUEST" "$mode" "$target" "$script" "$wait_s" <<'PYEOF'
import frida, sys, time

guest, mode, target, script_path, wait_s = sys.argv[1:6]
wait_s = float(wait_s)

dev = frida.get_device_manager().add_remote_device(guest)

if mode == "spawn":
    pid = dev.spawn([target])
    print(f"[frida-run] spawned {target} as pid {pid}", file=sys.stderr, flush=True)
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
    elif message["type"] == "error":
        print(f"[error] {message.get('stack') or message.get('description')}", flush=True)
    else:
        print(f"[{message['type']}] {message}", flush=True)

def on_log(level, text):
    print(f"[{level}] {text}", flush=True)

try:
    script = session.create_script(open(script_path, encoding="utf-8").read())
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
finally:
    pass
PYEOF
