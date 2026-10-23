// re/frida/phase5/strlen_trace.js — bogus-strlen tracer (Phase 5, 2026-10-23).
//
// The engine crashes ~1.1 s into Bloomberg telemetry init calling
// strlen((char*)0x1B) — a string pointer holding small int 27 (crash-run
// backtrace: telemetry init chain -> wrapper (+0x36A883) -> strlen RVA
// 0x5CD440; the faulting scan loop is at +0x5CD450; dump evidence in
// tmp/crash/). The exe is UBX-packed, so the hook target only exists after
// runtime unpacking: we poll for the function's known byte signature
// (from the minidump's captured EIP window) and attach the moment it
// appears. On the first bogus argument (< 0x10000) we snapshot everything
// (registers, stack words, backtrace, register-pointed memory, caller
// code) and emit ONE payload — frida-run.sh tees it to out/*.jsonl.
//
// Composable with gpu_shim.js,steam_probe.js. Config via FOLVAL_SCRIPT_ENV:
//   {"strlen_trace":{"neutralize":true}}  — replace the bogus pointer with
//   a dummy empty string and let the engine live (run #2 experiment).
"use strict";

var STRLEN_CFG = (typeof FOLVAL_SCRIPT_ENV !== "undefined" && FOLVAL_SCRIPT_ENV.strlen_trace) || {};

(function () {
    var RVA_STRLEN = 0x5CD440;                       // function entry (NULL-safe strlen)
    // push ebp; mov ebp,esp; mov edx,[ebp+8]; mov eax,edx; test edx,edx;
    // jne +4; pop ebp; ret   — verified from the minidump EIP window
    var SIG = "55 8B EC 8B 55 08 8B C2 85 D2 75 04 5D C3";

    var armed = false;
    var captured = false;
    var calls = 0;
    var logged = 0;

    function hexdump16(addr, n) {
        try { return hexdump(addr, { length: n, ansi: false, header: false }); }
        catch (e) { return "<unreadable " + e.message + ">"; }
    }

    function memWords(addr, n) {
        var out = [];
        for (var i = 0; i < n; i++) {
            try { out.push(addr.add(i * 4).readU32()); } catch (e) { out.push(null); }
        }
        return out;
    }

    function arm(mod, at) {
        var target = at;
        send({ t: "strlen_trace", ev: "armed", module: mod.name, base: "" + mod.base, target: "" + target, rva: "0x" + target.sub(mod.base).toString(16) });
        Interceptor.attach(target, {
            onEnter: function (args) {
                calls++;
                var a = args[0].toUInt32();
                if (a !== 0 && a < 0x10000) {
                    // The first bogus call IS the crash call (an earlier one
                    // would have crashed the engine first).
                    var c = this.context;
                    var ret = null;
                    try { ret = c.esp.add(4).readPointer(); } catch (e) {}
                    var btA = [], btF = [];
                    try { btA = Thread.backtrace(c, Backtracer.ACCURATE); } catch (e) {}
                    if (!btA.length) { try { btF = Thread.backtrace(c, Backtracer.FUZZY); } catch (e) {} }
                    var bt = btA.length ? btA : btF;
                    var payload = {
                        t: "strlen_trace", ev: "bogus", arg: a,
                        callsBefore: calls - 1,
                        regs: {
                            eax: c.eax, ebx: c.ebx, ecx: c.ecx, edx: c.edx,
                            esi: c.esi, edi: c.edi, ebp: c.ebp, esp: c.esp
                        },
                        ret: "" + ret,
                        backtrace: bt.slice(0, 16).map(function (x) {
                            var m = Process.findModuleByAddress(x);
                            return "" + x + (m ? " " + m.name + "+0x" + x.sub(m.base).toString(16) : "");
                        }),
                        backtraceMode: btA.length ? "accurate" : "fuzzy",
                        stackWords: memWords(c.esp, 48).map(function (v) {
                            return v === null ? null : "0x" + v.toString(16);
                        }),
                        regMem: {}
                    };
                    var rp = { eax: c.eax, ebx: c.ebx, ecx: c.ecx, edx: c.edx, esi: c.esi, edi: c.edi };
                    for (var r in rp) {
                        var v = rp[r].toUInt32();
                        if (v > 0x10000 && v < 0x80000000) payload.regMem[r] = hexdump16(rp[r], 64);
                    }
                    if (ret !== null) payload.callerCode = hexdump16(ret.sub(16), 64);
                    send(payload);
                    captured = true;
                    if (STRLEN_CFG.neutralize) {
                        // Swap the bogus pointer for a dummy empty string and
                        // let the engine continue past the crash site.
                        try {
                            this.dummy = Memory.allocUtf8String("");
                            c.esp.add(4).writePointer(this.dummy);
                            send({ t: "strlen_trace", ev: "neutralized", arg: a });
                        } catch (e) {
                            send({ t: "strlen_trace", ev: "neutralize_failed", err: "" + e });
                        }
                    }
                    return;
                }
                // Calibration: log the first few ordinary calls (short preview).
                if (logged < 5) {
                    logged++;
                    var s = "";
                    try { s = args[0].readUtf8String(40); } catch (e) { s = "<unreadable>"; }
                    send({ t: "strlen_trace", ev: "call", n: calls, arg: "0x" + a.toString(16), preview: s });
                }
            }
        });
    }

    // NOTE: in this packed process Process.mainModule is WRONG (returns
    // bcrypt.dll, 2026-10-23 live evidence). Find the game exe as the first
    // module whose name ends in ".exe" (the only exe in its own process).
    function gameModule() {
        var mods = Process.enumerateModules();
        for (var i = 0; i < mods.length; i++) {
            if (/\.exe$/i.test(mods[i].name)) return mods[i];
        }
        return null;
    }

    // FIRST-CHANCE exception tracer: Bloomberg's crash reporter itself
    // crashes while collecting context from broken state, and ITS minidump
    // replaces the original exception record (verified 10-22 vs 10-23:
    // strlen(0x1B) vs read@0x60, same reporter chain, different leaf).
    // Log the ORIGINAL exception before any engine handler sees it.
    Process.setExceptionHandler(function (d) {
        var m = Process.findModuleByAddress(d.context.pc);
        var payload = {
            t: "strlen_trace", ev: "exception", type: d.type,
            pc: "" + d.context.pc,
            module: m ? (m.name + "+0x" + d.context.pc.sub(m.base).toString(16)) : "?",
            mem: d.memory ? { op: d.memory.operation, addr: "" + d.memory.address } : null
        };
        if (d.type === "access-violation") {
            var c = d.context;
            payload.regs = { eax: c.eax, ebx: c.ebx, ecx: c.ecx, edx: c.edx, esi: c.esi, edi: c.edi, ebp: c.ebp, esp: c.esp };
            payload.regMem = {};
            ["ebx", "ecx", "edi", "edx", "ebp"].forEach(function (r) {
                var v = c[r].toUInt32();
                if (v > 0x10000 && v < 0x80000000) {
                    try { payload.regMem[r] = hexdump16(c[r], 96); } catch (e) { payload.regMem[r] = "<unreadable>"; }
                }
            });
            try {
                payload.bt = Thread.backtrace(c, Backtracer.FUZZY).slice(0, 12).map(function (x) {
                    var mm = Process.findModuleByAddress(x);
                    return "" + x + (mm ? " " + mm.name + "+0x" + x.sub(mm.base).toString(16) : "");
                });
            } catch (e) { payload.bt_err = "" + e; }
        }
        send(payload);
        return false; // propagate — engine/Bloomberg handlers still run
    });

    // ANTI-TAMPER: the engine CRC-checks its own unpacked code at ~+3.4s
    // wall — an in-exe Interceptor trampoline installed before that trips
    // "file corruption" (verified live 2026-10-23: armed@+0.25s -> box@+3.44s).
    // DLL hooks are safe. So we wait for Direct3DCreate9 (d3d9.dll, fires
    // post-CRC at renderer init, BEFORE the Bloomberg telemetry init that
    // calls strlen) and only then scan+arm the in-exe hook.
    function triggerArm() {
        if (armed) return;
        var m = gameModule();
        if (!m) { send({ t: "strlen_trace", ev: "no_exe_module" }); return; }
        try {
            Memory.scan(m.base, m.size, SIG, {
                onMatch: function (a) {
                    if (armed) return;
                    armed = true;
                    arm(m, a);
                }
            });
        } catch (e) { send({ t: "strlen_trace", ev: "scan_err", err: "" + e }); }
    }

    var d3d9 = Process.findModuleByName("d3d9.dll");
    var d3dExports = d3d9 ? d3d9.findExportByName("Direct3DCreate9") : null;
    if (d3dExports) {
        var fired = false;
        Interceptor.attach(d3dExports, {
            onEnter: function () {
                if (fired) return;
                fired = true;
                send({ t: "strlen_trace", ev: "d3d9_trigger" });
                triggerArm();
            }
        });
    } else {
        send({ t: "strlen_trace", ev: "no_d3d9_yet", note: "fallback timer arm at +5s" });
        setTimeout(triggerArm, 5000);
    }
    // safety net if the game never calls Direct3DCreate9 (degraded boot)
    setTimeout(function () { if (!armed) triggerArm(); }, 30000);
    send({ t: "strlen_trace", ev: "waiting_d3d9_trigger" });
})();
