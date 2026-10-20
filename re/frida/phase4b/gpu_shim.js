// re/frida/phase4b/gpu_shim.js — D3D9 capability liar + CreateDevice bisect (Phase 4b).
//
// The exe is SteamStub-packed: d3d9.dll is a static import (loaded at
// process init before our script), so hooks arm immediately at load.
//
// DECISIVE BASELINE (out/EVIDENCE.md ledger, 2026-10-18): the game's
// CreateDevice(HAL, flags=0x52, PP 1280x720/count=2) returns
// D3DERR_INVALIDCALL while an in-process control CreateDevice(HAL,
// flags=0x20, 640x480/count=1) returned S_OK — the wall is the game's ARGS,
// not the runtime/driver. Lying to Check*/GetDeviceCaps does NOT help (the
// runtime validates against the real driver) and NULLREF is refused.
//
// HOOK-ONLY DESIGN (2026-10-19): the old load-time selftest (native
// Direct3DCreate9/GetDeviceCaps/CreateDevice calls from the script's
// synchronous init) proved flaky in the packed process — one run died with
// an access violation at 0x3f800018, the next hung inside script.load()
// (loader-lock deadlock territory; the S_OK control is already in the
// ledger, run 170923). We now make NO native calls at load time: the game's
// own enumeration feeds every hook, including the labeled caps dump.
//
// BISECT MODE: default = PURE LOGGING of every CreateDevice field; per-run
// overrides arrive via FOLVAL_SCRIPT_ENV (frida-run.sh injects it as a
// global), one changed variable per spawn:
//   FOLVAL_SCRIPT_ENV='{"gpu":{"flags":32}}'                        # force BehaviorFlags
//   FOLVAL_SCRIPT_ENV='{"gpu":{"pp":{"count":1,"w":640,"h":480}}}' # patch PP fields
//   {"pp":{"hwnd":"desktop"}} patches BackBufferhwnd via GetDesktopWindow().
//   {"rt":{"maxw":640,"maxh":480}} clamps any device texture/RT/depth
//        creation larger than max (post-CreateDevice wall: the game's
//        1280x720 rendertarget -> E_OUTOFMEMORY under vga+Basic Display).
//   {"deptex": 21} swaps usage=DEPTHSTENCIL texture formats (INTZ-class
//        FOURCCs — the stack's d3d9 has NO depth-texture support:
//        native CheckDeviceFormat NOTAVAILABLE, creation fails) for a plain
//        RENDERTARGET texture in fmt 21 (A8R8G8B8). Visuals lie; the game
//        runs — which is all the RE goal needs.
//   {"fmtswap": 21} replaces texture/surface FOURCC formats this stack's
//        d3d9 rejects (e.g. 843666497 after DXT1 works — compressed-format
//        coverage is partial) with the given standard format. Known-good
//        DXT1 (827611204) is left alone. fmt <= 200 (standard D3DFMT enum)
//        is never swapped.
// The ledger in out/EVIDENCE.md tracks dead variants — do not re-run them.
//
// SM-caps (min-spec = SM 3.0): the GetDeviceCaps hook dumps labeled fields
// from the game's own query. D3DCAPS9 offsets verified against
// any-windows-any/d3d9caps.h (all-DWORD struct): DevCaps 0x18,
// TextureCaps 0x38, MaxTextureWidth/Height 0x54/0x58, MaxStreams 0x9c,
// VertexShaderVersion 0xa4, MaxVertexShaderConst 0xa8, PixelShaderVersion
// 0xac, DevCaps2 0xb0. sizeof(D3DCAPS9) = 0xd4.
//
// Run (user-session server so the game stays on the desktop):
//   FOLVAL_FRIDA_PORT=27043 FOLVAL_SPAWN_ARGS='<argline>' \
//     bash host/tools/frida-run.sh --spawn '<game exe>' re/frida/phase4b/gpu_shim.js [wait_s]

"use strict";

var CFG = (typeof FOLVAL_SCRIPT_ENV !== "undefined" && FOLVAL_SCRIPT_ENV && FOLVAL_SCRIPT_ENV.gpu) || {};

var VT = { // IDirect3D9 vtable indices (verified against any-windows-any/d3d9.h)
    GetAdapterCount: 4,
    CheckDeviceType: 9,
    CheckDeviceFormat: 10,
    CheckDeviceMultiSampleType: 11,
    CheckDepthStencilMatch: 12,
    CheckDeviceFormatConversion: 13,
    GetDeviceCaps: 14,
    CreateDevice: 16
};

function emit(obj) { send(Object.assign({ t: "gpu" }, obj)); }

function hexStr(p, n) { // byte array -> hex string (jsonl-safe, unlike ArrayBuffer)
    var u = new Uint8Array(p.readByteArray(n)), s = "";
    for (var i = 0; i < u.length; i++) s += ("0" + u[i].toString(16)).slice(-2);
    return s;
}

var abBuf = null; // cached 0xAB-filled ArrayBuffer for the caps canary
function cachedAb(n) {
    if (!abBuf || abBuf.byteLength !== n) {
        abBuf = new ArrayBuffer(n);
        new Uint8Array(abBuf).fill(0xab);
    }
    return abBuf;
}

// D3DPRESENT_PARAMETERS field offsets (32-bit) — read/log/patch one struct
var PP_OFFSETS = { w: 0x00, h: 0x04, fmt: 0x08, count: 0x0c, ms: 0x10, msq: 0x14,
                   swap: 0x18, windowed: 0x20, depth: 0x24, depthfmt: 0x28,
                   flags: 0x2c, rate: 0x30, interval: 0x34 }; // hwnd 0x1c handled specially

function readPP(pp) {
    if (pp.isNull()) return null;
    try {
        var o = { hwnd: pp.add(0x1c).readU32() >>> 0 };
        Object.keys(PP_OFFSETS).forEach(function (k) { o[k] = pp.add(PP_OFFSETS[k]).readU32() >>> 0; });
        return o;
    } catch (e) { return { err: "" + e }; }
}

var patched = false; // d3d9.dll has ONE static vtable — patch exactly once
var devicePatched = false; // same for the IDirect3DDevice9 vtable

// clamp w/h per CFG.rt for texture/surface creation (mutates args, logs)
function clampRT(args, wIdx, hIdx, log) {
    if (!CFG.rt) return;
    if (typeof CFG.rt.maxw === "number" && args[wIdx].toInt32() >>> 0 > CFG.rt.maxw) {
        args[wIdx] = ptr(CFG.rt.maxw); log.wForced = CFG.rt.maxw;
    }
    if (typeof CFG.rt.maxh === "number" && args[hIdx].toInt32() >>> 0 > CFG.rt.maxh) {
        args[hIdx] = ptr(CFG.rt.maxh); log.hForced = CFG.rt.maxh;
    }
}

var FMT_DXT1 = 827611204; // 'DXT1' LE — works on this stack (run 12)
function maybeSwapFmt(log, args, fmtIdx) {
    if (typeof CFG.fmtswap !== "number") return;
    var f = log.fmt;
    if (f > 200 && f !== FMT_DXT1) {
        log.fmtWas = f;
        args[fmtIdx] = ptr(CFG.fmtswap);
        log.fmt = CFG.fmtswap;
    }
}

function patchDeviceVtable(device, tag) {
    if (devicePatched) return;
    devicePatched = true;
    var vt = device.readPointer();
    emit({ note: "IDirect3DDevice9 vtable", from: tag, vtable: "" + vt });
    function at(i) { return vt.add(i * Process.pointerSize).readPointer(); }

    // GetAvailableTextureMem(4): UINT bytes — the E_OUTOFMEMORY suspect
    Interceptor.attach(at(4), {
        onLeave: function (retval) {
            emit({ api: "GetAvailableTextureMem", bytes: retval.toInt32() >>> 0 });
        }
    });

    // Reset(16): log PP; cfg {"reset":{...}} patches PP fields on the fly
    // (run 13: game's mode-switch Reset — fullscreen 1024x768 rate=64 then
    // windowed 1280x720 — fails INVALIDCALL with interval=0x80000000; the
    // original PP normalization lesson applies)
    Interceptor.attach(at(16), {
        onEnter: function (args) {
            this.pp = readPP(args[1]);
            if (CFG.reset && args[1] && !args[1].isNull()) {
                var pp = args[1], touched = {};
                Object.keys(PP_OFFSETS).forEach(function (k) {
                    if (typeof CFG.reset[k] === "number") {
                        pp.add(PP_OFFSETS[k]).writeU32(CFG.reset[k]);
                        touched[k] = CFG.reset[k];
                    }
                });
                this.ppForced = touched;
            }
        },
        onLeave: function (retval) {
            emit({ api: "Reset", pp: this.pp, ppForced: this.ppForced, hr: retval.toInt32() >>> 0 });
            console.log("[gpu] Reset -> 0x" + (retval.toInt32() >>> 0).toString(16));
        }
    });

    // CreateTexture(23)(w,h,levels,usage,fmt,pool,ppTex,shared)
    var D3DUSAGE_RENDERTARGET = 0x1, D3DUSAGE_DEPTHSTENCIL = 0x2;
    Interceptor.attach(at(23), {
        onEnter: function (args) {
            this.log = { api: "CreateTexture", w: args[1].toInt32() >>> 0, h: args[2].toInt32() >>> 0,
                         levels: args[3].toInt32() >>> 0, usage: args[4].toInt32() >>> 0,
                         fmt: args[5].toInt32() >>> 0, pool: args[6].toInt32() >>> 0 };
            if (typeof CFG.deptex === "number" && (this.log.usage & D3DUSAGE_DEPTHSTENCIL)) {
                this.log.fmtWas = this.log.fmt;
                var newUsage = (this.log.usage & ~D3DUSAGE_DEPTHSTENCIL) | D3DUSAGE_RENDERTARGET;
                args[5] = ptr(CFG.deptex);
                args[4] = ptr(newUsage);
                this.log.fmt = CFG.deptex;
                this.log.usageForced = newUsage;
            }
            maybeSwapFmt(this.log, args, 5);
            clampRT(args, 1, 2, this.log);
            emit(this.log);
        },
        onLeave: function (retval) {
            emit({ api: "CreateTexture.ret", hr: retval.toInt32() >>> 0 });
        }
    });

    // CreateCubeTexture(25)(edge,levels,usage,fmt,pool,ppTex,shared)
    Interceptor.attach(at(25), {
        onEnter: function (args) {
            this.log = { api: "CreateCubeTexture", edge: args[1].toInt32() >>> 0,
                         levels: args[2].toInt32() >>> 0, usage: args[3].toInt32() >>> 0,
                         fmt: args[4].toInt32() >>> 0, pool: args[5].toInt32() >>> 0 };
            maybeSwapFmt(this.log, args, 4);
            clampRT(args, 1, 1, this.log);
            emit(this.log);
        },
        onLeave: function (retval) {
            emit({ api: "CreateCubeTexture.ret", hr: retval.toInt32() >>> 0 });
        }
    });

    // CreateVertexBuffer(26)(length,usage,fvf,pool,ppVB,shared)
    Interceptor.attach(at(26), {
        onEnter: function (args) {
            emit({ api: "CreateVertexBuffer", length: args[1].toInt32() >>> 0,
                   usage: args[2].toInt32() >>> 0, fvf: args[3].toInt32() >>> 0,
                   pool: args[4].toInt32() >>> 0 });
        },
        onLeave: function (retval) {
            emit({ api: "CreateVertexBuffer.ret", hr: retval.toInt32() >>> 0 });
        }
    });

    // CreateIndexBuffer(27)(length,usage,fmt,pool,ppIB,shared)
    Interceptor.attach(at(27), {
        onEnter: function (args) {
            emit({ api: "CreateIndexBuffer", length: args[1].toInt32() >>> 0,
                   usage: args[2].toInt32() >>> 0, fmt: args[3].toInt32() >>> 0,
                   pool: args[4].toInt32() >>> 0 });
        },
        onLeave: function (retval) {
            emit({ api: "CreateIndexBuffer.ret", hr: retval.toInt32() >>> 0 });
        }
    });

    // CreateRenderTarget(28)(w,h,fmt,ms,msq,lockable,ppSurf,shared)
    Interceptor.attach(at(28), {
        onEnter: function (args) {
            this.log = { api: "CreateRenderTarget", w: args[1].toInt32() >>> 0, h: args[2].toInt32() >>> 0,
                         fmt: args[3].toInt32() >>> 0, ms: args[4].toInt32() >>> 0,
                         msq: args[5].toInt32() >>> 0, lockable: args[6].toInt32() >>> 0 };
            maybeSwapFmt(this.log, args, 3);
            clampRT(args, 1, 2, this.log);
            emit(this.log);
        },
        onLeave: function (retval) {
            emit({ api: "CreateRenderTarget.ret", hr: retval.toInt32() >>> 0 });
        }
    });

    // CreateDepthStencilSurface(29)(w,h,fmt,ms,msq,discard,ppSurf,shared)
    Interceptor.attach(at(29), {
        onEnter: function (args) {
            this.log = { api: "CreateDepthStencilSurface", w: args[1].toInt32() >>> 0, h: args[2].toInt32() >>> 0,
                         fmt: args[3].toInt32() >>> 0, ms: args[4].toInt32() >>> 0,
                         msq: args[5].toInt32() >>> 0, discard: args[6].toInt32() >>> 0 };
            maybeSwapFmt(this.log, args, 3);
            clampRT(args, 1, 2, this.log);
            emit(this.log);
        },
        onLeave: function (retval) {
            emit({ api: "CreateDepthStencilSurface.ret", hr: retval.toInt32() >>> 0 });
        }
    });

    emit({ note: "device vtable patched (hooks armed)", from: tag });
}

function patchVtable(d3d9, tag) {
    if (patched) { emit({ note: "vtable already patched (skip)", from: tag }); return; }
    patched = true;
    var vtable = d3d9.readPointer();
    emit({ note: "IDirect3D9 vtable", from: tag, vtable: "" + vtable });

    // GetAdapterCount: log-only census (if the game later passes an ordinal
    // >= count to CreateDevice, that alone is INVALIDCALL).
    Interceptor.attach(vtable.add(VT.GetAdapterCount * Process.pointerSize).readPointer(), {
        onLeave: function (retval) {
            emit({ api: "GetAdapterCount", count: retval.toInt32() >>> 0 });
        }
    });

    // Log-only liars: force S_OK on capability probes (evidence shows the
    // runtime ignores these for CreateDevice validation — kept as logging).
    [ "CheckDeviceType", "CheckDeviceFormat", "CheckDeviceMultiSampleType",
      "CheckDepthStencilMatch", "CheckDeviceFormatConversion" ].forEach(function (name) {
        var fn = vtable.add(VT[name] * Process.pointerSize).readPointer();
        Interceptor.attach(fn, {
            onEnter: function (args) {
                this.args = [];
                for (var i = 1; i <= 5; i++) this.args.push(args[i].toInt32());
            },
            onLeave: function (retval) {
                emit({ api: name, args: this.args, was: retval.toInt32() >>> 0 });
                retval.replace(0); // S_OK
            }
        });
        emit({ note: "liar armed", api: name, at: "" + fn });
    });

    // GetDeviceCaps: keep real caps, dump labeled fields (SM answer) from
    // the game's own query. The buffer is only valid in onLeave. CANARY:
    // onEnter prefills 0xAB — surviving 0xABs mean the runtime returned
    // S_OK WITHOUT writing (2026-10-19 suspicion: the game's buffer held
    // garbage — AdapterOrdinal=1, MaxTexW=63, VS "0.8" — while dxdiag from
    // a pristine process shows a healthy stack: FL 9_3 = SM3.0, 4 GB shared).
    Interceptor.attach(vtable.add(VT.GetDeviceCaps * Process.pointerSize).readPointer(), {
        onEnter: function (args) {
            this.pCaps = args[3]; this.adapter = args[1].toInt32(); this.devType = args[2].toInt32() >>> 0;
            if (!this.pCaps.isNull()) {
                try { this.pCaps.writeByteArray(cachedAb(0xd4)); } catch (e) {}
            }
        },
        onLeave: function (retval) {
            var caps = null, canary = null;
            try {
                var c = this.pCaps;
                if (!c.isNull()) {
                    var u = new Uint8Array(c.readByteArray(0xd4));
                    var ab = 0;
                    for (var i = 0; i < u.length; i++) if (u[i] === 0xab) ab++;
                    canary = ab;
                    function u32(o) { return c.add(o).readU32() >>> 0; }
                    function sm(v) { return v ? ((v >>> 8) & 0xff) + "." + (v & 0xff) : "0.0"; }
                    caps = { devCaps: "0x" + u32(0x18).toString(16),
                             textureCaps: "0x" + u32(0x38).toString(16),
                             maxTexW: u32(0x54), maxTexH: u32(0x58),
                             maxStreams: u32(0x9c), maxStreamStride: u32(0xa0),
                             vertexShader: sm(u32(0xa4)), maxVSConst: u32(0xa8),
                             pixelShader: sm(u32(0xac)),
                             devCaps2: "0x" + u32(0xb0).toString(16),
                             rawHex: hexStr(c, 0xd4) };
                    console.log("[gpu] caps@" + this.adapter + ": VS " + caps.vertexShader +
                                " / PS " + caps.pixelShader + " canary=" + canary);
                }
            } catch (e) { caps = { err: "" + e }; }
            emit({ api: "GetDeviceCaps", adapter: this.adapter, devType: this.devType,
                   hr: retval.toInt32() >>> 0, canary: canary, caps: caps });
        }
    });

    // CreateDevice — BISECT SEAM. stdcall COM vtable arg layout:
    // args[0]=this, [1]=Adapter, [2]=DeviceType, [3]=hFocusWindow,
    // [4]=BehaviorFlags, [5]=pPresentationParameters, [6]=ppDevice.
    Interceptor.attach(vtable.add(VT.CreateDevice * Process.pointerSize).readPointer(), {
        onEnter: function (args) {
            this.ppDevice = args[6];
            var log = { api: "CreateDevice", adapter: args[1].toInt32(),
                        devType: args[2].toInt32() >>> 0, hFocus: "" + args[3],
                        flags: args[4].toInt32() >>> 0, pp: readPP(args[5]) };
            if (typeof CFG.flags === "number") {
                args[4] = ptr(CFG.flags);
                log.flagsForced = CFG.flags;
            }
            var pp = args[5];
            if (CFG.pp && !pp.isNull()) {
                var touched = {};
                Object.keys(PP_OFFSETS).forEach(function (k) {
                    if (typeof CFG.pp[k] === "number") {
                        pp.add(PP_OFFSETS[k]).writeU32(CFG.pp[k]);
                        touched[k] = CFG.pp[k];
                    }
                });
                if (CFG.pp.hwnd === "desktop") {
                    var desk = new NativeFunction(
                        Process.getModuleByName("user32.dll").findExportByName("GetDesktopWindow"),
                        "pointer", [])();
                    pp.add(0x1c).writePointer(desk);
                    touched.hwnd = "desktop";
                }
                log.ppForced = touched;
            }
            emit(log);
        },
        onLeave: function (retval) {
            emit({ api: "CreateDevice.ret", hr: retval.toInt32() >>> 0 });
            console.log("[gpu] CreateDevice -> 0x" + (retval.toInt32() >>> 0).toString(16));
            if (retval.toInt32() === 0 && this.ppDevice && !this.ppDevice.isNull()) {
                try { patchDeviceVtable(this.ppDevice.readPointer(), "CreateDevice"); } catch (e) {
                    emit({ note: "device vtable patch failed", err: "" + e });
                }
            }
        }
    });
    emit({ note: "vtable patched (hooks armed)", from: tag });
}

function armD3D9(module) {
    ["Direct3DCreate9", "Direct3DCreate9Ex"].forEach(function (exp) {
        var p = module.findExportByName(exp);
        if (!p) return;
        if (exp === "Direct3DCreate9") {
            Interceptor.attach(p, {
                onEnter: function (args) { emit({ api: "Direct3DCreate9", sdk: args[0].toInt32() }); },
                onLeave: function (retval) {
                    if (!retval.isNull()) patchVtable(retval, "Direct3DCreate9");
                    else emit({ api: "Direct3DCreate9.ret", hr: 0 });
                }
            });
            emit({ note: "hooked", api: exp, at: "" + p });
        } else {
            // Direct3DCreate9Ex(SDKVersion, IDirect3D9Ex**): vtable layout is a
            // superset — the base indices hold, so patch through the out param.
            Interceptor.attach(p, {
                onEnter: function (args) { this.pp = args[1]; },
                onLeave: function (retval) {
                    emit({ api: "Direct3DCreate9Ex.ret", hr: retval.toInt32() >>> 0 });
                    if (retval.toInt32() === 0 && !this.pp.isNull()) {
                        patchVtable(this.pp.readPointer(), "Direct3DCreate9Ex");
                    }
                }
            });
            emit({ note: "hooked", api: exp, at: "" + p });
        }
    });
}

var d3d9mod = Process.findModuleByName("d3d9.dll");

// ---- exit-reason capture: see WHY the game quits ---------------------------
["user32!MessageBoxW", "user32!MessageBoxA"].forEach(function (sym) {
    var mod = sym.split("!")[0], fn = sym.split("!")[1];
    var m = Process.findModuleByName(mod);
    var p = m ? m.findExportByName(fn) : null;
    if (p) Interceptor.attach(p, {
        onEnter: function (args) {
            var title = "", text = "";
            try { if (!args[1].isNull()) title = (fn === "MessageBoxW") ? args[1].readUtf16String() : args[1].readUtf8String(); } catch (e) {}
            try { if (!args[2].isNull()) text = (fn === "MessageBoxW") ? args[2].readUtf16String() : args[2].readUtf8String(); } catch (e) {}
            emit({ api: fn, title: title, text: text });
            console.log("[gpu] MessageBox '" + title + "': " + text);
        }
    });
});
["ExitProcess", "TerminateProcess"].forEach(function (fn) {
    var p = Process.findModuleByName("kernel32").findExportByName(fn);
    if (p) Interceptor.attach(p, {
        onEnter: function (args) { emit({ api: fn, code: args[0].toInt32() >>> 0 }); console.log("[gpu] " + fn + "(" + (args[0].toInt32() >>> 0) + ")"); }
    });
});

if (d3d9mod) {
    emit({ note: "d3d9 already loaded", base: "" + d3d9mod.base });
    armD3D9(d3d9mod);
} else {
    emit({ note: "waiting for d3d9.dll (module observer)" });
    Process.attachModuleObserver({
        onAdded: function (module) {
            if (module.name.toLowerCase() === "d3d9.dll") {
                emit({ note: "d3d9.dll loaded", base: "" + module.base });
                armD3D9(module);
            }
        }
    });
}
emit({ note: "gpu_shim.js loaded", pid: Process.id, cfg: CFG });
console.log("[gpu] shim loaded into pid " + Process.id);
