// re/frida/phase5/watch_node.js — correlate the GameplaySettings node
// constructor with the Bloomberg walk (2026-10-23). Static finding: the
// ctor at RVA 0x506D30 zeroes +0x64 on [this+0x1c50] (a sub-object), while
// the walked node's own +0x64 may never be initialized. Hooks (armed at
// first Direct3DCreate9 = post anti-tamper CRC):
//   ctor 0x506D30 : log this, [this+0x1c50], and this+0x60..0x6c at leave
//   walk 0x508680 : log arg0 (&node->field), node base, node head, field val
"use strict";
(function () {
    var RVA_CTOR = 0x506D30, RVA_WALK = 0x508680;

    function gameModule() {
        var mods = Process.enumerateModules();
        for (var i = 0; i < mods.length; i++) if (/\.exe$/i.test(mods[i].name)) return mods[i];
        return null;
    }

    var walkCount = 0;

    function arm(base) {
        send({ t: "watch_node", ev: "armed", base: "" + base });

        Interceptor.attach(base.add(RVA_CTOR), {
            onEnter: function (args) { this.thiz = this.context.ecx; },
            onLeave: function () {
                try {
                    var t = ptr(this.thiz);
                    var sub = t.add(0x1c50).readPointer();
                    send({
                        t: "watch_node", ev: "ctor", this: "" + t,
                        sub_1c50: "" + sub,
                        this_60_6c: [t.add(0x60).readU32(), t.add(0x64).readU32(), t.add(0x68).readU32(), t.add(0x6c).readU32()],
                        sub_60_6c: sub.isNull() ? null : [sub.add(0x60).readU32(), sub.add(0x64).readU32(), sub.add(0x68).readU32(), sub.add(0x6c).readU32()],
                        vt: "0x" + t.readU32().toString(16)
                    });
                } catch (e) { send({ t: "watch_node", ev: "ctor_err", err: "" + e }); }
            }
        });

        Interceptor.attach(base.add(RVA_WALK), {
            onEnter: function (args) {
                walkCount++;
                if (walkCount > 12) return;
                try {
                    var fieldAddr = args[0];            // &node->field
                    var node = fieldAddr.sub(0x64);     // assumption: field offset 0x64
                    send({
                        t: "watch_node", ev: "walk", n: walkCount,
                        fieldOff: "0x" + fieldAddr.sub(node).toString(16),
                        node: "" + node,
                        nodeHead: [node.readU32(), node.add(4).readU32(), node.add(8).readU32()],
                        fieldVal: "0x" + fieldAddr.readU32().toString(16)
                    });
                } catch (e) { send({ t: "watch_node", ev: "walk_err", err: "" + e }); }
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
                if (m) arm(m.base); else send({ t: "watch_node", ev: "no_exe" });
            }
        });
        send({ t: "watch_node", ev: "waiting_d3d9" });
    } else send({ t: "watch_node", ev: "no_d3d9" });
})();
