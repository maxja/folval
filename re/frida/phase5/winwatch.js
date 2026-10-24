// re/frida/phase5/winwatch.js — window & exit lifecycle watcher.
// Composes into the game spawn (IIFE scope). DLL-only hooks (CRC-safe).
// Answers: when is the game window created, when/how does it die, who calls it.
//
// Tracks every window the process creates; logs Destroy/Hide/Quit/Exit with
// backtraces. Env: {"winwatch":{"titleRe":"...","dumpUntracked":false}}
"use strict";
(function () {
    var env = {};
    try { env = JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}"); } catch (e) {}
    var CFG = env.winwatch || {};

    function u32(name) {
        var p = Process.findModuleByName("user32.dll").findExportByName(name);
        return p;
    }
    function ntdll(name) {
        var m = Process.findModuleByName("ntdll.dll");
        return m ? m.findExportByName(name) : null;
    }
    function clsOf(hwnd) {
        try {
            var GCNW = new NativeFunction(u32("GetClassNameW"), "int", ["pointer", "pointer", "int"]);
            var b = Memory.alloc(256);
            return GCNW(hwnd, b, 128) > 0 ? (b.readUtf16String() || "?") : "?";
        } catch (e) { return "?"; }
    }
    function titleOf(hwnd) {
        try {
            var GTW = new NativeFunction(u32("GetWindowTextW"), "int", ["pointer", "pointer", "int"]);
            var b = Memory.alloc(512);
            return GTW(hwnd, b, 256) > 0 ? (b.readUtf16String() || "") : "";
        } catch (e) { return ""; }
    }
    function bt(ctx) {
        try {
            return Thread.backtrace(ctx, Backtracer.ACCURATE).slice(0, 10).map(function (a) {
                var m = Process.findModuleByAddress(a);
                return m ? (m.name + "+0x" + a.sub(m.base).toString(16)) : ("" + a);
            });
        } catch (e) { return ["?"]; }
    }

    var tracked = {};   // hwnd -> {cls,title}
    function key(h) { return h.toString(); }

    // CreateWindowExW
    try {
        Interceptor.attach(u32("CreateWindowExW"), {
            onEnter: function (a) { this.cls = a[1].readPointer ? safeClsPtr(a[1]) : "?"; },
            onLeave: function (rv) {
                if (rv.isNull()) return;
                var c = clsOf(rv), t = titleOf(rv);
                tracked[key(rv)] = { cls: c, title: t };
                send({ t: "winwatch", ev: "create", hwnd: key(rv), cls: c, title: t });
            }
        });
    } catch (e) { send({ t: "winwatch", ev: "hook_err", which: "CreateWindowExW", err: "" + e }); }

    function safeClsPtr(p) {
        try { return p.readUtf16String() || "ATOM:" + p.toString(16); } catch (e) { return "ATOM:" + p.toString(16); }
    }

    // DestroyWindow — tracked windows only
    try {
        Interceptor.attach(u32("DestroyWindow"), {
            onEnter: function (a) {
                var k = key(a[0]);
                if (!tracked[k]) return;
                send({ t: "winwatch", ev: "destroy", hwnd: k, cls: tracked[k].cls, bt: bt(this.context) });
                delete tracked[k];
            }
        });
    } catch (e) { send({ t: "winwatch", ev: "hook_err", which: "DestroyWindow", err: "" + e }); }

    // ShowWindow — tracked windows only, interesting cmds (0=hide, 5/9=show variants)
    try {
        Interceptor.attach(u32("ShowWindow"), {
            onEnter: function (a) {
                var k = key(a[0]);
                if (!tracked[k]) return;
                var cmd = a[1].toInt32();
                send({ t: "winwatch", ev: "show", hwnd: k, cls: tracked[k].cls, cmd: cmd, bt: cmd === 0 ? bt(this.context) : undefined });
            }
        });
    } catch (e) { send({ t: "winwatch", ev: "hook_err", which: "ShowWindow", err: "" + e }); }

    // PostQuitMessage
    try {
        var pqm = u32("PostQuitMessage");
        if (pqm) Interceptor.attach(pqm, {
            onEnter: function (a) {
                send({ t: "winwatch", ev: "quit_msg", code: a[0].toInt32(), bt: bt(this.context) });
            }
        });
    } catch (e) { send({ t: "winwatch", ev: "hook_err", which: "PostQuitMessage", err: "" + e }); }

    // RtlExitUserProcess — the path CRT exit() takes (ExitProcess wraps it)
    try {
        var rup = ntdll("RtlExitUserProcess");
        if (rup) Interceptor.attach(rup, {
            onEnter: function (a) {
                send({ t: "winwatch", ev: "exit_proc", code: a[0].toInt32(), bt: bt(this.context) });
            }
        });
    } catch (e) { send({ t: "winwatch", ev: "hook_err", which: "RtlExitUserProcess", err: "" + e }); }

    // NtTerminateProcess (self-terminate)
    try {
        var ntp = ntdll("NtTerminateProcess");
        if (ntp) Interceptor.attach(ntp, {
            onEnter: function (a) {
                send({ t: "winwatch", ev: "nt_term", h: a[0].toString(), code: a[1].toInt32(), bt: bt(this.context) });
            }
        });
    } catch (e) { send({ t: "winwatch", ev: "hook_err", which: "NtTerminateProcess", err: "" + e }); }

    send({ t: "winwatch", ev: "armed" });
})();
