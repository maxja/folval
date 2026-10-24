// re/frida/phase5/d3d9dev.js — IDirect3DDevice9 surface probes + texture-mem clamp.
//
// 2026-10-24 stall: post-quest CreateRenderTarget fails 0x8007000e after the
// engine commits a 1.65GB pool at +22..27s (free VA 2404→17MB). Pool is
// insensitive to GlobalMemoryStatusEx/pagefile clamps → suspect it's sized
// from the D3D device's GetAvailableTextureMem (WARP report). This script
// wraps the device vtable (indices verified against mingw d3d9.h):
//   vtable[3]=TestCooperativeLevel  [4]=GetAvailableTextureMem
//   [23]=CreateTexture  [28]=CreateRenderTarget  [29]=CreateDepthStencilSurface
//
// Env: {"d3d9dev":{"fakeAvailMB":0,"logRT":true,"logTCL":true}}
//   fakeAvailMB>0 → GetAvailableTextureMem returns the fake (UINT bytes).
(function () {
    var CFG = {};
    try { CFG = (typeof FOLVAL_SCRIPT_ENV !== "undefined" && FOLVAL_SCRIPT_ENV && FOLVAL_SCRIPT_ENV.d3d9dev) || (JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}")).d3d9dev || {}; } catch (e) {}
    var FAKE_AVAIL_B = (CFG.fakeAvailMB || 0) * 1024 * 1024;
    var LOG_RT = (CFG.logRT !== undefined) ? CFG.logRT : true;
    var LOG_TCL = (CFG.logTCL !== undefined) ? CFG.logTCL : true;

    // IDirect3DDevice9 vtable indices (mingw d3d9.h, IUnknown included)
    var VT_TCL = 3, VT_GATM = 4, VT_CREATE_TEX = 23, VT_CRT = 28, VT_CDS = 29;
    // IDirect3D9 vtable: CreateDevice index computed below from header order
    var VT_D3D9_CREATEDEVICE = 16;

    var k32 = Process.getModuleByName("kernel32.dll");
    var wrapped = {};

    function report(ev, extra) {
        var p = { t: "d3d9dev", ev: ev };
        if (extra) { for (var k in extra) { p[k] = extra[k]; } }
        send(p);
    }

    function wrapDevice(devPtr) {
        var key = devPtr.toString();
        if (wrapped[key]) return;
        wrapped[key] = true;
        var vt = devPtr.readPointer();
        report("device", { dev: key, vtable: vt.toString() });

        // GetAvailableTextureMem — log original, optionally fake
        Interceptor.attach(vt.add(VT_GATM * 4).readPointer(), {
            onLeave: function (r) {
                var orig = r.toUInt32();
                if (FAKE_AVAIL_B > 0) {
                    r.replace(ptr(FAKE_AVAIL_B));
                    report("gatm", { origMB: Math.round(orig / 1048576), fakeMB: Math.round(FAKE_AVAIL_B / 1048576) });
                } else {
                    report("gatm", { origMB: Math.round(orig / 1048576) });
                }
            }
        });

        // TestCooperativeLevel — log non-zero (device lost = D3DERR_DEVICELOST 0x88760868 / NOTRESET 0x8876086A)
        Interceptor.attach(vt.add(VT_TCL * 4).readPointer(), {
            onLeave: function (r) {
                var hr = r.toInt32();
                if (LOG_TCL && hr !== 0) report("tcl", { hr: "0x" + (hr >>> 0).toString(16) });
            }
        });

        // CreateRenderTarget(Width, Height, Format, MS, MSQuality, Lockable, ppSurface, pShared)
        if (LOG_RT) {
            Interceptor.attach(vt.add(VT_CRT * 4).readPointer(), {
                onEnter: function (a) {
                    this.w = a[1].toInt32(); this.h = a[2].toInt32(); this.fmt = a[3].toInt32();
                },
                onLeave: function (r) {
                    var hr = r.toInt32();
                    if (hr !== 0) report("rt_fail", { w: this.w, h: this.h, fmt: this.fmt, hr: "0x" + (hr >>> 0).toString(16) });
                }
            });
            Interceptor.attach(vt.add(VT_CDS * 4).readPointer(), {
                onEnter: function (a) { this.w = a[1].toInt32(); this.h = a[2].toInt32(); },
                onLeave: function (r) {
                    var hr = r.toInt32();
                    if (hr !== 0) report("ds_fail", { w: this.w, h: this.h, hr: "0x" + (hr >>> 0).toString(16) });
                }
            });
        }
    }

    // Direct3DCreate9 → IDirect3D9*; wrap its CreateDevice to catch the out-param
    function findCreate9() {
        try { return Process.getModuleByName("d3d9.dll").findExportByName("Direct3DCreate9"); } catch (e) { return null; }
    }
    var d3dc9 = findCreate9();
    if (!d3dc9) {
        report("no_d3d9_wait"); // d3d9.dll loads later (engine init ~+4s)
        Interceptor.attach(k32.findExportByName("LoadLibraryW"), {
            onLeave: function (r) {
                if (!d3dc9) {
                    d3dc9 = findCreate9();
                    if (d3dc9) hookCreate9();
                }
            }
        });
    } else {
        hookCreate9();
    }

    function hookCreate9() {
        var fn = findCreate9();
        if (!fn) { report("no_create9"); return; }
        Interceptor.attach(fn, {
            onLeave: function (r) {
                if (r.isNull()) return;
                var d3d = r;
                var vt = d3d.readPointer();
                var createDevice = vt.add(VT_D3D9_CREATEDEVICE * 4).readPointer();
                report("d3d9", { obj: d3d.toString(), createDevice: createDevice.toString() });
                Interceptor.attach(createDevice, {
                    // CreateDevice(this, Adapter, DeviceType, hFocusWindow, BehaviorFlags, pPP, ppDevice)
                    onEnter: function (a) { this.ppDev = a[6]; },
                    onLeave: function (r) {
                        if (r.toInt32() !== 0 || !this.ppDev) return;
                        var dev;
                        try { dev = this.ppDev.readPointer(); } catch (e) { return; }
                        if (!dev.isNull()) wrapDevice(dev);
                    }
                });
            }
        });
    }

    report("armed", { fakeAvailMB: CFG.fakeAvailMB || 0, logRT: LOG_RT });
})();
