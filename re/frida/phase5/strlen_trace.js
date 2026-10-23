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
    // skipav: redirect known walk-crash sites to their graceful-skip paths
    // (found via .text dump: 0x508680's NULL-string branch is 0x5086D9).
    // Used to boot past the registration-vs-walk race (2026-10-23).
    var SKIP_PATHS = {
        // entry: { to: <rva>, esp: <adjust> }
        "0x508690": { to: 0x5086D9, esp: 0 },  // mov ecx,[esi] fault -> empty-string path
        "0x5086f7": { to: 0x50872E, esp: 0 },  // mov eax,[esi] (esi garbage) -> fn epilogue
        "0x498ab5": { to: 0x498AC3, esp: 4 },  // mov ecx,[esi+0x14] (this==NULL) -> pop esi;ret (drop pushed arg)
        "0x50851e": { to: 0x5085A0, esp: 0 },  // mov esi,[ebx+0x1cd4] (next-slot race) -> walk fn epilogue
        "0x508248": { to: 0x508260, esp: 0 },  // mov [edi+0x1d00],eax (edi==0 mgr) -> 0x5080E0 epilogue
        "0x5788a0": { to: 0x5788A8, esp: 0 },  // mov edx,[eax] (release-ctx lookup miss) -> pop esi;pop ebp;ret
        "0x11da36c": { skip: 10 },             // mov [esi+0x14c],0 in free() tail — freed hdr; skip store (10-byte insn)
        "0x4d2580": { to: 0x4d25EB, esp: 4 },  // hashmap-destroy on freed obj — drop pushed edi, jump to epilogue
        "0x578907": { to: 0x57890F, esp: 0 },  // mov edx,[eax] (same lookup-miss as 0x5788a0, sibling fn)
        "0x5278d3": { to: 0x5278D9, esp: 0 },  // getter: garbage sub-obj vcall -> return out-param untouched
        "0x527873": { to: 0x527879, esp: 0 },  // float variant of same getter (fn 0x527860)
        "0x2a2ea3": { to: 0x2A2EDD, esp: 0 },  // map-clear unlink on garbage node -> fn epilogue (leaks nodes, fine)
        "0x4942dc": { to: 0x494306, esp: 4 }   // map find-by-key, this==garbage -> "not found" path (al=0)
    };
    // 0x5080E0 = Bloomberg report-population fn (reg-loop 0x507880 + walk
    // 0x508440 + final lookups). Called at least twice (init + telemetry chain
    // +0x4814e3); one invocation has this==NULL. Guard: emulate ret 8.
    var RVA_POPULATE = 0x5080E0;
    function armPopulateGuard(base) {
        Interceptor.attach(base.add(RVA_POPULATE), {
            onEnter: function (args) {
                var self = this.context.ecx;
                if (!plausibleHeap(self)) {
                    send({ t: "strlen_trace", ev: "populate_guard_skip", this: "" + self });
                    this.context.eip = this.context.esp.readPointer(); // return addr
                    this.context.esp = this.context.esp.add(0xC);      // ret 8
                }
            }
        });
    }
    // walk-entry guard: if [this+0x1c50] isn't a plausible heap pointer, the
    // registration race lost for this slot — skip the whole walk (ret 4 after
    // dropping the pushed arg). 0x508440 is the walk fn (this=ecx, arg=field).
    var RVA_WALK = 0x508440;
    function plausibleHeap(v) { var u = v.toUInt32(); return u >= 0x10000 && u < 0x7FFE0000 && (u & 3) === 0; }
    function armWalkGuard(base) {
        Interceptor.attach(base.add(RVA_WALK), {
            onEnter: function (args) {
                try {
                    var sub = this.context.ecx.add(0x1c50).readPointer();
                    if (!plausibleHeap(sub)) {
                        send({ t: "strlen_trace", ev: "walk_guard_skip", sub: "" + sub });
                        this.context.esp = this.context.esp.add(4); // drop pushed arg
                        this.context.eip = base.add(0x5085A0);      // fn epilogue
                    }
                } catch (e) {}
            }
        });
    }
    // resurrect: on AV touching an uncommitted heap-range page, commit a fresh
    // zeroed RWX page there and retry the faulting instruction. Garbage-pointer
    // reads then see NULL (loops terminate); scribbles land in a page nothing
    // else owns. Bounded by RESURRECT_CAP.
    var RESURRECT_CAP = 16;
    var resurrected = {};
    var VirtualAlloc = null, GetLastError = null;
    try {
        var k32 = Process.findModuleByName("kernel32.dll");
        var va = k32 ? k32.findExportByName("VirtualAlloc") : null;
        if (va) VirtualAlloc = new NativeFunction(va, "pointer", ["pointer", "uint32", "uint32", "uint32"], "stdcall");
        var gle = k32 ? k32.findExportByName("GetLastError") : null;
        if (gle) GetLastError = new NativeFunction(gle, "uint32", [], "stdcall");
    } catch (e) {}
    function tryResurrect(addr) {
        if (!VirtualAlloc) return false;
        var a = addr.toUInt32();
        if (a < 0x1000000 || a >= 0x7FFE0000) return false;
        var page = a & ~0xFFF;
        if (resurrected[page]) return false;
        if (Object.keys(resurrected).length >= RESURRECT_CAP) return false;
        var r = VirtualAlloc(ptr(page), 0x1000, 0x3000, 0x40); // MEM_COMMIT|MEM_RESERVE, RWX
        if (r.isNull()) r = VirtualAlloc(ptr(page), 0x1000, 0x1000, 0x40); // MEM_COMMIT only (region still reserved)
        if (r.isNull()) {
            try { Memory.protect(ptr(page), 0x1000, "rwx"); r = ptr(page); } catch (e) {}
        }
        if (r.isNull()) { send({ t: "strlen_trace", ev: "resurrect_fail", page: "0x" + page.toString(16), gle: GetLastError ? GetLastError() : -1 }); return false; }
        resurrected[page] = 1;
        send({ t: "strlen_trace", ev: "resurrect", page: "0x" + page.toString(16) });
        return true;
    }

    Process.setExceptionHandler(function (d) {
        if (d.type === "access-violation" && STRLEN_CFG.skipav) {
            var off = "0x" + d.context.pc.sub(gameModule().base).toString(16);
            var sp = SKIP_PATHS[off];
            if (sp) {
                if (sp.skip) {
                    d.context.eip = d.context.pc.add(sp.skip);
                    send({ t: "strlen_trace", ev: "skipav", from: off, skip: sp.skip, mem: d.memory ? "" + d.memory.address : null });
                } else {
                    var m = gameModule();
                    d.context.eip = m.base.add(sp.to);
                    if (sp.esp) d.context.esp = d.context.esp.add(sp.esp);
                    send({ t: "strlen_trace", ev: "skipav", from: off, to: "0x" + sp.to.toString(16), esp: sp.esp, mem: d.memory ? "" + d.memory.address : null });
                }
                return true; // handled — continue at the skip path
            }
        }
        if (d.type === "access-violation" && STRLEN_CFG.skipav && d.memory) {
            if (tryResurrect(d.memory.address)) return true; // page committed — retry insn
        }
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
        if (STRLEN_CFG.skipav) { armWalkGuard(m.base); armPopulateGuard(m.base); }
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
                var delay = STRLEN_CFG.armDelayMs || 0;
                if (delay > 0) setTimeout(triggerArm, delay);
                else triggerArm();
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
