// re/frida/phase4b/wait_hunter.js — find what a stalled process waits on.
//
// The game (post D3D9 fix, 2026-10-19) initializes its GPU resources, then
// goes silent: no window, no child processes, no network, no crash. This
// probe aggregates blocking calls (Wait*, Sleep) by caller module and
// watches process/window creation — the stall's signature falls out.
//
// Run: FOLVAL_FRIDA_PORT=27043 bash host/tools/frida-run.sh <gameexe> \
//        re/frida/phase4b/wait_hunter.js [wait_s]

"use strict";

var agg = {};   // key -> count
var seen = {};  // CreateProcess/Window one-shots

function callerModule(retAddr) {
    var m = Process.findModuleByAddress(retAddr);
    return m ? m.name : "?";
}

function bump(kind, mod, extra) {
    var key = kind + " @" + mod + (extra ? " " + extra : "");
    if (!agg[key]) {
        agg[key] = 1;
        send({ t: "wait", api: kind, module: mod, extra: extra || "", first: true });
    } else agg[key]++;
}

function hookWait(mod, name, isEx) {
    var p = Process.findModuleByName(mod);
    if (!p) return;
    var fn = p.findExportByName(name);
    if (!fn) return;
    // NtQueryObject(handle, 2=ObjectTypeInformation) — resolve what the
    // engine's INFINITE waits actually wait on (type only; name queries can
    // deadlock on synchronous pipe handles).
    var ntq = null;
    try {
        ntq = new NativeFunction(Process.getModuleByName("ntdll").findExportByName("NtQueryObject"),
            "uint32", ["pointer", "uint32", "pointer", "uint32", "pointer"], "stdcall");
    } catch (e) {}
    function objType(h) {
        if (!ntq) return "?";
        try {
            var buf = Memory.alloc(0x100), ret = Memory.alloc(4);
            var st = ntq(h, 2, buf, 0x100, ret);
            if (st !== 0) return "err" + st;
            var len = ret.readU16 ? ret.readU16() : 0; // TypeName UNICODE_STRING (len, maxlen, ptr)
            var us = buf.readU16(), ptr32 = buf.add(4).readU32();
            if (us === 0) return "";
            return ptr(ptr32).readUtf16String(us / 2);
        } catch (e) { return "?"; }
    }
    Interceptor.attach(fn, {
        onEnter: function (args) {
            var ret = this.returnAddress;
            var timeout = "";
            if (name.indexOf("Multiple") >= 0) {
                timeout = "timeout=" + args[3].toInt32();     // nCount, lpHandles, bWaitAll, dwMilliseconds
            } else if (name.indexOf("Sleep") === 0) {
                timeout = "ms=" + args[0].toInt32();          // plain call: no this-ptr
            } else {
                timeout = "timeout=" + args[1].toInt32();
            }
            // resolve object types for INFINITE single-object waits from the exe
            var extra = "";
            if (name === "WaitForSingleObject" && args[1].toInt32() === -1 &&
                callerModule(ret) === Process.mainModule.name && !args[0].isNull()) {
                extra = " [" + objType(args[0]) + " h=" + args[0] + "]";
            }
            bump(name, callerModule(ret), timeout + extra);
        }
    });
}

[ "WaitForSingleObject", "WaitForSingleObjectEx",
  "WaitForMultipleObjects", "WaitForMultipleObjectsEx",
  "Sleep", "SleepEx" ].forEach(function (n) { hookWait("kernel32", n); });
hookWait("ntdll", "NtWaitForSingleObject");
hookWait("ntdll", "NtWaitForMultipleObjects");

[ "CreateProcessW", "CreateProcessA" ].forEach(function (name) {
    var p = Process.findModuleByName("kernel32").findExportByName(name);
    Interceptor.attach(p, {
        onEnter: function (args) {
            var app = "";
            try {
                app = (name === "CreateProcessW") ? args[0].readUtf16String() : args[0].readAnsiString();
                if (!app && !args[1].isNull()) {
                    var cl = (name === "CreateProcessW") ? args[1].readUtf16String() : args[1].readAnsiString();
                    if (cl) app = "(cmdline) " + cl.substring(0, 200);
                }
            } catch (e) { app = "<err>"; }
            this.app = app;
        },
        onLeave: function (retval) {
            send({ t: "wait", api: name, app: this.app, ok: retval.toInt32() !== 0 });
            console.log("[wait] " + name + " '" + this.app + "' -> " + (retval.toInt32() !== 0));
        }
    });
});

[ "CreateWindowExW", "CreateWindowExA" ].forEach(function (name) {
    var p = Process.findModuleByName("user32").findExportByName(name);
    if (!p) return;
    Interceptor.attach(p, {
        onEnter: function (args) {
            var cls = "", title = "";
            try { if (!args[1].isNull()) cls = (name === "CreateWindowExW") ? args[1].readUtf16String() : args[1].readAnsiString(); } catch (e) {}
            try { if (!args[2].isNull()) title = (name === "CreateWindowExW") ? args[2].readUtf16String() : args[2].readAnsiString(); } catch (e) {}
            var key = cls + "|" + title;
            if (!seen[key]) {
                seen[key] = 1;
                send({ t: "wait", api: name, cls: cls, title: title });
                console.log("[wait] window " + cls + " '" + title + "'");
            }
        }
    });
});

// periodic aggregate flush
var ticks = 0;
var timer = setInterval(function () {
    ticks++;
    var top = Object.keys(agg).sort(function (a, b) { return agg[b] - agg[a]; }).slice(0, 12)
        .map(function (k) { return k + " x" + agg[k]; });
    send({ t: "wait", note: "agg", tick: ticks, top: top });
    console.log("[wait] agg#" + ticks + ": " + top.join(" | "));
}, 10000);

send({ t: "wait", note: "wait_hunter loaded", pid: Process.id });
console.log("[wait] wait_hunter loaded into pid " + Process.id);
