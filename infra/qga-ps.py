#!/usr/bin/env python3
"""Run a PowerShell script inside folval3 as SYSTEM: spawn bare powershell.exe
(single token — qemu-ga Windows spawn takes no args) and pipe the script to its
stdin via agent/exec input-data."""
import base64, json, os, sys, time, urllib.parse, urllib.request, ssl

EP = os.environ["PROXMOX_VE_ENDPOINT"].rstrip("/")
H = {"Authorization": "PVEAPIToken=" + os.environ["PROXMOX_VE_API_TOKEN"]}
VM = "300"
PS = "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

def api(method, path, data=None):
    if data and method == "GET":
        path = path + "?" + urllib.parse.urlencode(data)
        data = None
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(EP + f"/api2/json/{path}", data=body, headers=H, method=method)
    r = json.load(urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=30))
    return r["data"]

script = sys.stdin.read()
pid = api("POST", f"nodes/pve/qemu/{VM}/agent/exec",
          {"command": PS, "input-data": script})["pid"]
t0 = time.time()
while time.time() - t0 < 300:
    d = api("GET", f"nodes/pve/qemu/{VM}/agent/exec-status", {"pid": pid})
    if d and d.get("exited"):
        out = d.get("out-data", "") or ""
        if "\x00" in out:
            out = out.encode("latin-1", errors="replace").decode("utf-16-le", errors="replace")
        print(out)
        err = d.get("err-data", "") or ""
        if err.strip():
            print("STDERR:", err, file=sys.stderr)
        sys.exit(d.get("exitcode") or 0)
    time.sleep(3)
print("TIMEOUT", file=sys.stderr)
sys.exit(124)
