// re/frida/phase5/node_census.js — census of the GameplaySettings node class.
// Static: ctor 0x506D30 writes vtable 0xB33124(RVA) but never ran in-flow
// (2026-10-23) → the walked node is likely a memcpy clone from package
// template data. Scan the heap for instances (first dword == vtable RVA),
// dump +0x60..+0x70 of each, at two moments: d3d9 trigger and first walk.
"use strict";
(function () {
    var RVA_VT = 0xB33124, RVA_WALK = 0x508680;

    function gameModule() {
        var mods = Process.enumerateModules();
        for (var i = 0; i < mods.length; i++) if (/\.exe$/i.test(mods[i].name)) return mods[i];
        return null;
    }

    function census(base, tag) {
        var vt = base.add(RVA_VT);
        var found = [];
        var v = vt.toUInt32();
        var pat = "24 31 " + ("0" + ((v >> 16) & 0xff).toString(16)).slice(-2) + " " + ("0" + ((v >> 24) & 0xff).toString(16)).slice(-2);
        var ranges = Process.enumerateRanges({ protection: "rw-", coalesce: true });
        for (var i = 0; i < ranges.length && found.length < 24; i++) {
            var r = ranges[i];
            if (r.size > 0x2000000) continue;
            try {
                Memory.scan(r.base, r.size, pat, {
                    onMatch: function (a) {
                        if (found.length < 24) found.push(a);
                    },
                    onComplete: function () {}
                });
            } catch (e) { /* unreadable range — skip */ }
        }
        var out = found.map(function (a) {
            try {
                return {
                    at: "" + a,
                    f60: a.add(0x60).readU32(), f64: a.add(0x64).readU32(),
                    f68: a.add(0x68).readU32(), f6c: a.add(0x6c).readU32(),
                    f20: a.add(0x20).readU32()
                };
            } catch (e) { return { at: "" + a, err: "" + e }; }
        });
        send({ t: "node_census", ev: "census", tag: tag, vt: "" + vt, count: out.length, nodes: out });
    }

    function arm(base) {
        send({ t: "node_census", ev: "armed", base: "" + base });
        census(base, "d3d9");

        var n = 0;
        Interceptor.attach(base.add(RVA_WALK), {
            onEnter: function (args) {
                n++;
                if (n > 6) return;
                var a0 = args[0].toUInt32();
                if (a0 > 0x10000 && a0 < 0x80000000) {
                    var fv = null;
                    try { fv = "0x" + args[0].readU32().toString(16); } catch (e) { fv = "<unreadable>"; }
                    send({ t: "node_census", ev: "walk", n: n, arg: "0x" + a0.toString(16), deref: fv });
                } else {
                    send({ t: "node_census", ev: "walk_raw_arg", n: n, arg: "0x" + a0.toString(16) });
                }
                if (n === 1) census(base, "walk1");
            }
        });
    }

    var d3d9 = Process.findModuleByName("d3d9.dll");
    var exp = d3d9 ? d3d9.findExportByName("Direct3DCreate9") : null;
    if (exp) {
        var fired = false;
        Interceptor.attach(exp, {
            onEnter: function () {
                if (fired) return;
                fired = true;
                var m = gameModule();
                if (m) arm(m.base);
            }
        });
        send({ t: "node_census", ev: "waiting" });
    }
})();
