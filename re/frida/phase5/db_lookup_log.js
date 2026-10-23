// re/frida/phase5/db_lookup_log.js — log every GameplaySettings DB lookup:
// 0x503050(this=ecx, edi=[ebp+8], section=[ebp+0xc], name=[ebp+0x10]) -> ptr | -4.
// Static findings (2026-10-23): registration table at 0x507A50 stores results
// into manager slots ([this+0x1c50] etc.); slot 0x1c50 = name at RVA 0xB3388
// ('VisualGamepadAttackSettings.json'); walk crashed on [mgr+0x1c50] == -4.
"use strict";
(function () {
    var RVA_LOOKUP = 0x503050;
    var STR_RVA = { 0xB3348: 1, 0xB336C: 1, 0xB3388: 1, 0xB33AC: 1, 0xB33C8: 1, 0xB33E4: 1 };

    function gameModule() {
        var mods = Process.enumerateModules();
        for (var i = 0; i < mods.length; i++) if (/\.exe$/i.test(mods[i].name)) return mods[i];
        return null;
    }

    function arm(base) {
        send({ t: "dblookup", ev: "armed", base: "" + base });
        var n = 0;
        Interceptor.attach(base.add(RVA_LOOKUP), {
            onEnter: function (args) {
                this.name = null; this.section = null;
                try {
                    this.section = args[1].readCString();
                    this.name = args[2].readCString();
                } catch (e) {}
            },
            onLeave: function (retval) {
                n++;
                if (n > 40) return;
                var v = retval.toUInt32();
                send({
                    t: "dblookup", ev: "lookup", n: n,
                    section: this.section, name: this.name,
                    ret: (v === 0xFFFFFFFC) ? "NOT_FOUND(-4)" : "0x" + v.toString(16)
                });
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
        send({ t: "dblookup", ev: "waiting" });
    }
})();
