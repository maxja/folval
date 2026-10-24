// re/frida/phase5/vaclamp.js — under-report physical RAM to the engine.
//
// 2026-10-24 stall root cause: at +22..32s the engine sizes and commits a
// ~1.65GB private VA pool (free VA 2404→17MB, largest block →1MB; LAA exe,
// 4GB user VA). At the post-quest world-load (+~165s) CreateRenderTarget
// fails 0x8007000e at every size — no contiguous VA. Engines commonly size
// that pool from GlobalMemoryStatusEx/GlobalMemoryStatus; clamping
// ullTotalPhys/dwTotalPhys makes the pool smaller, leaving VA for D3D.
//
// Env: {"vaclamp":{"totalPhysMB":1024,"log":true}}
(function () {
    var CFG = {};
    try { CFG = (typeof FOLVAL_SCRIPT_ENV !== "undefined" && FOLVAL_SCRIPT_ENV && FOLVAL_SCRIPT_ENV.vaclamp) || (JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}")).vaclamp || {}; } catch (e) {}
    var CLAMP_MB = CFG.totalPhysMB || 1024;
    var PAGEFILE_MB = (CFG.pagefileMB !== undefined) ? CFG.pagefileMB : 512; // TotalPageFile = phys + pagefile-extra
    var LOG = (CFG.log !== undefined) ? CFG.log : true;

    var k32 = Process.getModuleByName("kernel32.dll");

    function report(ev, extra) {
        if (!LOG) return;
        var p = { t: "vaclamp", ev: ev };
        if (extra) { for (var k in extra) { p[k] = extra[k]; } }
        send(p);
    }

    // BOOL GlobalMemoryStatusEx(MEMORYSTATUSEX*) — ullTotalPhys @0x08, ullAvailPhys @0x10,
    // ullTotalPageFile @0x18, ullAvailPageFile @0x20, ullTotalVirtual @0x28, ullAvailVirtual @0x30
    var gmsx = k32.findExportByName("GlobalMemoryStatusEx");
    if (gmsx) {
        Interceptor.attach(gmsx, {
            onEnter: function (a) { this.buf = a[0]; },
            onLeave: function (r) {
                if (!r.toInt() || !this.buf) return;
                var orig = this.buf.add(8).readU64();
                var clamp = uint64(CLAMP_MB * 1024 * 1024);
                try {
                    this.buf.add(8).writeU64(clamp);                      // ullTotalPhys
                    var avail = this.buf.add(0x10).readU64();
                    if (avail.compare(clamp) > 0) this.buf.add(0x10).writeU64(clamp); // ullAvailPhys <= total
                    // commit-limit clamp: pagefile fields (engine pools often sized from these)
                    var pf = this.buf.add(0x18).readU64();                 // ullTotalPageFile
                    var pfClamp = clamp.add(uint64(PAGEFILE_MB * 1024 * 1024));
                    if (pf.compare(pfClamp) > 0) {
                        this.buf.add(0x18).writeU64(pfClamp);               // ullTotalPageFile
                        this.buf.add(0x20).writeU64(clamp);                 // ullAvailPageFile
                    }
                    report("gmsx", { origMB: Math.round(orig.toNumber() / 1048576), clampedMB: CLAMP_MB, origPfMB: Math.round(pf.toNumber() / 1048576) });
                } catch (e) { report("gmsx_err", { err: String(e) }); }
            }
        });
    }

    // VOID GlobalMemoryStatus(MEMORYSTATUS*) — dwTotalPhys @0x08 (32-bit)
    var gms = k32.findExportByName("GlobalMemoryStatus");
    if (gms) {
        Interceptor.attach(gms, {
            onEnter: function (a) { this.buf = a[0]; },
            onLeave: function (r) {
                if (!this.buf) return;
                var orig = this.buf.add(8).readU32();
                var clampMB = Math.min(CLAMP_MB, 2047); // 32-bit field, keep under 2GB
                this.buf.add(8).writeU32(clampMB * 1024 * 1024);
                var avail = this.buf.add(0x0c).readU32();
                if (avail > clampMB * 1024 * 1024) this.buf.add(0x0c).writeU32(clampMB * 1024 * 1024);
                report("gms", { origMB: Math.round(orig / 1048576), clampedMB: clampMB });
            }
        });
    }

    // BOOL GetPhysicallyInstalledSystemMemory(PULONGLONG) — total KB
    var gpism = k32.findExportByName("GetPhysicallyInstalledSystemMemory");
    if (gpism) {
        Interceptor.attach(gpism, {
            onEnter: function (a) { this.out = a[0]; },
            onLeave: function (r) {
                if (!this.out || !r.toInt()) return;
                try {
                    this.out.writeU64(uint64(CLAMP_MB * 1024)); // KB
                    report("gpism", { clampedMB: CLAMP_MB });
                } catch (e) {}
            }
        });
    }

    report("armed", { totalPhysMB: CLAMP_MB });
})();
