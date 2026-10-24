// re/frida/phase5/valifeboat.js — VA lifeboat: reserve early, release on RT failure.
//
// 2026-10-24 stall: the engine consumes ~4.06GB of its 4GB LAA VA at boot
// (~1.65GB fixed private pool + ~1.7GB mapped bigfiles); the post-quest
// world-load then fails CreateRenderTarget 0x8007000e down its whole retry
// ladder (2048²→256²) for lack of contiguous VA.
//
// Hot-path VirtualAlloc hooks proved unusable (per-call JS overhead crawls
// the movie/boot phases). This approach avoids them entirely:
//   1. EARLY (+armMs): VirtualAlloc(MEM_RESERVE, PAGE_NOACCESS, reserveMB)
//      — pure address-space claim, zero commit; the engine maps/pools around
//      it (may even shrink its pool if it sizes from free VA — win either way).
//   2. Rescue: hook the COLD device methods (CreateRenderTarget / DepthStencil
//      / CreateTexture via d3d9dev-style vtable wrap). On the FIRST failure,
//      VirtualFree the reserve → instant contiguous hole; the engine's own
//      retry ladder lands in it.
//
// Env: {"valifeboat":{"armMs":2000,"reserveMB":512}}
(function () {
    var CFG = {};
    try { CFG = (typeof FOLVAL_SCRIPT_ENV !== "undefined" && FOLVAL_SCRIPT_ENV && FOLVAL_SCRIPT_ENV.valifeboat) || (JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}")).valifeboat || {}; } catch (e) {}
    var ARM_MS = CFG.armMs || 2000;
    var RESERVE = (CFG.reserveMB || 512) * 1048576;

    var k32 = Process.getModuleByName("kernel32.dll");
    var VirtualAlloc = new NativeFunction(k32.findExportByName("VirtualAlloc"), "pointer", ["pointer", "uint32", "uint32", "uint32"]);
    var VirtualFree = new NativeFunction(k32.findExportByName("VirtualFree"), "int", ["pointer", "uint32", "uint32"]);
    var VA = null, released = false, rescued = false;

    // vtable indices (mingw d3d9.h): GetAvailableTextureMem=4 EvictManagedResources=5
    // CreateTexture=23 CreateRenderTarget=28 CreateDepthStencilSurface=29;
    // IDirect3D9::CreateDevice=16
    var wrapped = {};
    var devForProbes = null;
    var defTexBytes = 0, defTexCount = 0; // DEFAULT-pool textures created (bytes incl. RT)

    function callVt(dev, idx, retType) {
        try {
            var fn = new NativeFunction(dev.readPointer().add(idx * 4).readPointer(), retType || "uint32", ["pointer"]);
            return fn(dev);
        } catch (e) { return null; }
    }

    function report(ev, extra) {
        var p = { t: "valifeboat", ev: ev };
        if (extra) { for (var k in extra) { p[k] = extra[k]; } }
        send(p);
    }

    function rescue(what) {
        if (rescued || VA === null) return;
        rescued = true;
        var gatmBefore = devForProbes ? callVt(devForProbes, 4) : null;
        var evictOk = null;
        if (devForProbes) {
            try {
                var ev = new NativeFunction(devForProbes.readPointer().add(5 * 4).readPointer(), "int32", ["pointer"]);
                evictOk = ev(devForProbes);
            } catch (e) { evictOk = "err"; }
        }
        var gatmEvict = devForProbes ? callVt(devForProbes, 4) : null;
        var ok = VirtualFree(VA, 0, 0x8000 /*MEM_RELEASE*/);
        var gatmAfter = devForProbes ? callVt(devForProbes, 4) : null;
        report("rescue", { on: what, base: VA.toString(), freeOk: ok ? 1 : 0, reserveMB: RESERVE / 1048576,
                           gatmBeforeMB: gatmBefore === null ? null : Math.round(gatmBefore / 1048576),
                           evictHr: evictOk === null ? null : "0x" + (evictOk >>> 0).toString(16),
                           gatmEvictMB: gatmEvict === null ? null : Math.round(gatmEvict / 1048576),
                           gatmAfterMB: gatmAfter === null ? null : Math.round(gatmAfter / 1048576),
                           defTexMB: Math.round(defTexBytes / 1048576), defTexCount: defTexCount });
    }

    function reserve() {
        // MEM_TOP_DOWN=0x100000 | MEM_RESERVE=0x2000, PAGE_NOACCESS=0x01
        VA = VirtualAlloc(ptr(0), RESERVE, 0x100000 | 0x2000, 0x01);
        if (VA.isNull()) { report("reserve_fail"); VA = null; return; }
        report("reserved", { base: VA.toString(), reserveMB: RESERVE / 1048576 });
    }

    function wrapDevice(devPtr) {
        var key = devPtr.toString();
        if (wrapped[key]) return;
        wrapped[key] = true;
        devForProbes = devPtr;
        var vt = devPtr.readPointer();

        // CreateTexture(this, Width, Height, Levels, Usage, Format, Pool, ppTexture, pShared)
        // D3DUSAGE_RENDERTARGET = 0x1, D3DPOOL_DEFAULT = 0
        // FMT SWAP: the engine's world-load asks for FOURCC 'NULL' (0x4C4C554E)
        // RT textures — unsupported on WARP, d3d9 returns E_OUTOFMEMORY
        // (misleading). Swap to D3DFMT_A8R8G8B8 (21) like gpu_shim's fmtswap.
        Interceptor.attach(vt.add(23 * 4).readPointer(), {
            onEnter: function (a) {
                this.w = a[1].toInt32(); this.h = a[2].toInt32();
                this.levels = a[3].toInt32(); this.usage = a[4].toInt32();
                this.fmt = a[5].toInt32(); this.pool = a[6].toInt32();
                this.shared = a[8] && !a[8].isNull() ? 1 : 0;
                this.swapped = 0;
                if (this.fmt === 0x4C4C554E) { // 'NULL' FOURCC
                    a[5] = ptr(21); // D3DFMT_A8R8G8B8
                    this.swapped = 1;
                }
            },
            onLeave: function (r) {
                var hr = r.toInt32();
                if (this.swapped && hr === 0) {
                    report("fmt_swap_ok", { w: this.w, h: this.h, usage: "0x" + (this.usage >>> 0).toString(16) });
                }
                if (hr === 0 && this.pool === 0) {
                    defTexCount++;
                    defTexBytes += this.w * this.h * 4; // approx (fmt/mips ignored)
                }
                if (hr !== 0) {
                    report("tex_fail", { w: this.w, h: this.h, levels: this.levels, usage: "0x" + (this.usage >>> 0).toString(16), fmt: this.fmt, swapped: this.swapped, pool: this.pool, shared: this.shared, hr: "0x" + (hr >>> 0).toString(16), defTexMB: Math.round(defTexBytes / 1048576), defTexCount: defTexCount });
                    if (this.usage & 0x1 || this.pool === 0) rescue("CreateTexture");
                }
            }
        });
        Interceptor.attach(vt.add(28 * 4).readPointer(), {  // CreateRenderTarget
            onEnter: function (a) { this.w = a[1].toInt32(); this.h = a[2].toInt32(); },
            onLeave: function (r) {
                var hr = r.toInt32();
                if (hr !== 0) { report("rt_fail", { w: this.w, h: this.h, hr: "0x" + (hr >>> 0).toString(16) }); rescue("CreateRenderTarget"); }
            }
        });
        Interceptor.attach(vt.add(29 * 4).readPointer(), {  // CreateDepthStencilSurface
            onEnter: function (a) { this.w = a[1].toInt32(); this.h = a[2].toInt32(); },
            onLeave: function (r) {
                var hr = r.toInt32();
                if (hr !== 0) { report("ds_fail", { w: this.w, h: this.h, hr: "0x" + (hr >>> 0).toString(16) }); rescue("CreateDepthStencilSurface"); }
            }
        });
        report("device_wrapped", { dev: key });
    }

    function hookFactory(exportName) {
        var fn;
        try { fn = Process.getModuleByName("d3d9.dll").findExportByName(exportName); } catch (e) { fn = null; }
        if (!fn) { report("no_export", { api: exportName }); return; }
        Interceptor.attach(fn, {
            onLeave: function (r) {
                if (r.isNull()) return;
                var vt = r.readPointer();
                Interceptor.attach(vt.add(16 * 4).readPointer(), {  // CreateDevice (same idx for 9Ex)
                    onEnter: function (a) { this.ppDev = a[6]; },
                    onLeave: function (r2) {
                        if (r2.toInt32() !== 0 || !this.ppDev) return;
                        try { var dev = this.ppDev.readPointer(); if (!dev.isNull()) wrapDevice(dev); } catch (e) {}
                    }
                });
            }
        });
    }
    hookFactory("Direct3DCreate9");     // d3d9.dll loaded at spawn (observed)
    hookFactory("Direct3DCreate9Ex");   // second device may come via 9Ex
    report("armed", { armMs: ARM_MS, reserveMB: RESERVE / 1048576 });
    setTimeout(reserve, ARM_MS);
})();
