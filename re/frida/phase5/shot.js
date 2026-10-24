// re/frida/phase5/shot.js — capture the game window's pixels via PrintWindow.
// Composes into the game run (all state is inside the IIFE — no scope
// collisions) OR attaches to steam.exe standalone. Captures repeatedly
// (the game window may only exist briefly, e.g. during the intro).
//
// Emits: shot/captured {n,cls,w,h} + shot/chunk {n,i,b64} (raw BGRA, ~60KB).
// Env: FOLVAL_SCRIPT_ENV='{"shot":{"firstDelayMs":4000,"intervalMs":8000,"maxShots":24}}'
"use strict";
(function () {
    var env = {};
    try { env = JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}"); } catch (e) {}
    var CFG = env.shot || {};
    var classRe = CFG.classRe ? new RegExp(CFG.classRe) : /Runtime|Mighty/i;
    var INTERVAL = CFG.intervalMs || 8000, MAXSHOTS = CFG.maxShots || 24;
    var shotNo = 0;

    var u32 = Process.getModuleByName("user32.dll");
    var g32 = Process.getModuleByName("gdi32.dll");
    function F(mod, name, ret, args) {
        var p = mod.findExportByName(name);
        if (!p) throw new Error("missing export " + name);
        return new NativeFunction(p, ret, args);
    }
    var EnumWindows = F(u32, "EnumWindows", "int", ["pointer", "pointer"]);
    var IsWindowVisible = F(u32, "IsWindowVisible", "int", ["pointer"]);
    var GetClassNameW = F(u32, "GetClassNameW", "int", ["pointer", "pointer", "int"]);
    var GetWindowTextW = F(u32, "GetWindowTextW", "int", ["pointer", "pointer", "int"]);
    var GetWindowRect = F(u32, "GetWindowRect", "int", ["pointer", "pointer"]);
    var GetDC = F(u32, "GetDC", "pointer", ["pointer"]);
    var ReleaseDC = F(u32, "ReleaseDC", "int", ["pointer", "pointer"]);
    var PrintWindow = F(u32, "PrintWindow", "int", ["pointer", "pointer", "uint32"]);
    var CreateCompatibleDC = F(g32, "CreateCompatibleDC", "pointer", ["pointer"]);
    var CreateCompatibleBitmap = F(g32, "CreateCompatibleBitmap", "pointer", ["pointer", "int", "int"]);
    var SelectObject = F(g32, "SelectObject", "pointer", ["pointer", "pointer"]);
    var GetDIBits = F(g32, "GetDIBits", "int", ["pointer", "pointer", "uint32", "uint32", "pointer", "pointer", "uint32"]);
    var DeleteObject = F(g32, "DeleteObject", "int", ["pointer"]);
    var DeleteDC = F(g32, "DeleteDC", "int", ["pointer"]);

    function base64(p, len) {
        var bytes = new Uint8Array(p.readByteArray(len));
        var s = "";
        var tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (var i = 0; i < bytes.length; i += 3) {
            var a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
            s += tbl[a >> 2] + tbl[((a & 3) << 4) | (b >> 4)] + (i + 1 < bytes.length ? tbl[((b & 15) << 2) | (c >> 6)] : "=") + (i + 2 < bytes.length ? tbl[c & 63] : "=");
        }
        return s;
    }

    function capture(n) {
        var target = ptr(0), tclass = "", ttext = "", tarea = 0;
        var cb = new NativeCallback(function (hwnd, lp) {
            try {
                var b = Memory.alloc(256);
                GetClassNameW(hwnd, b, 128);
                var cn = b.readUtf16String();
                if (cn && classRe.test(cn)) {
                    var r = Memory.alloc(16);
                    GetWindowRect(hwnd, r);
                    var rw = r.add(8).readS32() - r.add(0).readS32();
                    var rh = r.add(12).readS32() - r.add(4).readS32();
                    if (rw > 0 && rh > 0 && rw * rh > tarea) {
                        var tb = Memory.alloc(512);
                        GetWindowTextW(hwnd, tb, 256);
                        target = hwnd; tarea = rw * rh; tclass = cn; ttext = tb.readUtf16String() || "";
                    }
                }
            } catch (e) {}
            return 1;
        }, "int", ["pointer", "pointer"]);
        EnumWindows(cb, ptr(0));

        if (target.isNull()) { send({ t: "shot", ev: "no_window", n: n }); return; }
        var rect = Memory.alloc(16);
        GetWindowRect(target, rect);
        var w = rect.add(8).readS32() - rect.add(0).readS32();
        var h = rect.add(12).readS32() - rect.add(4).readS32();
        if (w <= 0 || h <= 0 || w > 4096 || h > 4096) { send({ t: "shot", ev: "bad_rect", n: n, w: w, h: h, cls: tclass }); return; }

        var hdc = GetDC(target);
        var mem = CreateCompatibleDC(hdc);
        var bmp = CreateCompatibleBitmap(hdc, w, h);
        SelectObject(mem, bmp);
        var ok = PrintWindow(target, mem, 2); // PW_RENDERFULLCONTENT
        var bih = Memory.alloc(40);
        bih.writeU32(40); bih.add(4).writeS32(w); bih.add(8).writeS32(-h); // top-down
        bih.add(12).writeU16(1); bih.add(14).writeU16(32);
        var px = Memory.alloc(w * h * 4);
        var got = GetDIBits(mem, bmp, 0, h, px, bih, 0);
        DeleteObject(bmp); DeleteDC(mem); ReleaseDC(target, hdc);

        send({ t: "shot", ev: "captured", n: n, cls: tclass, title: ttext, w: w, h: h, printOk: ok, rows: got });
        if (got > 0) {
            var CH = 0xF000, total = w * h * 4, cnt = Math.ceil(total / CH);
            for (var i = 0; i < cnt; i++) {
                var off = i * CH, len = Math.min(CH, total - off);
                send({ t: "shot", ev: "chunk", n: n, i: i, b64: base64(px.add(off), len) });
            }
        }
    }

    function attempt() {
        shotNo++;
        try { capture(shotNo); } catch (e) { send({ t: "shot", ev: "err", n: shotNo, err: "" + e }); }
        if (shotNo < MAXSHOTS) setTimeout(attempt, INTERVAL);
    }
    setTimeout(attempt, CFG.firstDelayMs || 4000);
    send({ t: "shot", ev: "scheduled", firstMs: CFG.firstDelayMs || 4000, intervalMs: INTERVAL });
})();
