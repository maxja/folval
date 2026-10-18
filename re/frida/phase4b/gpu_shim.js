// re/frida/phase4b/gpu_shim.js — D3D9 capability liar (Phase 4b).
//
// The game hard-exits under emulated video ("Can not found DerectX device
// with minimum requirements!") because the adapter lacks the D3D9 formats
// it demands (launcher dialog named NULL render targets, INTZ, RAWZ). This
// shim hooks Direct3DCreate9 and patches the returned IDirect3D9 vtable's
// capability checks to report success, so the game proceeds past device
// enumeration to its network init (the RE goal — not rendering quality).
//
// The exe is SteamStub-packed: d3d9.dll is not loaded at spawn time, so a
// module observer arms the hooks when d3d9.dll appears.
//
// Run (user-session server so the game stays on the desktop):
//   FOLVAL_FRIDA_PORT=27043 FOLVAL_SPAWN_ARGS='<argline>' \
//     bash host/tools/frida-run.sh --spawn '<game exe>' re/frida/phase4b/gpu_shim.js [wait_s]

"use strict";

var VT = { // IDirect3D9 vtable indices (after IUnknown QueryInterface/AddRef/Release = 0..2)
    CheckDeviceType: 9,
    CheckDeviceFormat: 10,
    CheckDeviceMultiSampleType: 11,
    CheckDepthStencilMatch: 12,
    CheckDeviceFormatConversion: 13,
    GetDeviceCaps: 14,
    CreateDevice: 16
};

function emit(obj) { send(Object.assign({ t: "gpu" }, obj)); }

var patched = false; // d3d9.dll has ONE static vtable — patch exactly once

function patchVtable(d3d9, tag) {
    if (patched) { emit({ note: "vtable already patched (skip)", from: tag }); return; }
    patched = true;
    var vtable = d3d9.readPointer();
    emit({ note: "IDirect3D9 vtable", from: tag, vtable: "" + vtable });

    // Pure liars: force S_OK on capability probes (attach+onLeave keeps the
    // real stdcall frame intact — no stack-cleanup responsibility).
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

    // GetDeviceCaps: log what the game asks for, keep real caps (patch later
    // only if the game still refuses — evidence first).
    var capsFn = vtable.add(VT.GetDeviceCaps * Process.pointerSize).readPointer();
    Interceptor.attach(capsFn, {
        onEnter: function (args) { this.pCaps = args[3]; this.adapter = args[1].toInt32(); },
        onLeave: function (retval) {
            emit({ api: "GetDeviceCaps", adapter: this.adapter, hr: retval.toInt32() >>> 0,
                   capsHead: this.pCaps.isNull() ? "" : this.pCaps.readByteArray(16) });
        }
    });

    // CreateDevice: soften the ask — windowed-mode PresentationParameters
    // (exclusive fullscreen fails on emulated video), software vertex
    // processing, no PUREDEVICE. NOTE arg layout for stdcall COM vtables:
    // args[0]=this, [1]=Adapter, [2]=DeviceType, [3]=hFocusWindow,
    // [4]=BehaviorFlags, [5]=pPresentationParameters, [6]=ppDevice.
    var createFn = vtable.add(VT.CreateDevice * Process.pointerSize).readPointer();
    Interceptor.attach(createFn, {
        onEnter: function (args) {
            var flags = args[4].toInt32() >>> 0;
            // DeviceType: keep the app's choice (HAL). NOTE: inbox Win10
            // d3d9 REFUSES D3DDEVTYPE_NULLREF creation (INVALIDCALL) — dead end.
            var D3DCREATE_PUREDEVICE = 0x00004000;
            var D3DCREATE_FPU_PRESERVE = 0x00000002;
            var D3DCREATE_SOFTWARE_VERTEXPROCESSING = 0x00000020;
            var D3DCREATE_MIXED_VERTEXPROCESSING = 0x00000200;
            var D3DCREATE_HARDWARE_VERTEXPROCESSING = 0x00000040;
            var newFlags = (flags & ~(D3DCREATE_PUREDEVICE | D3DCREATE_FPU_PRESERVE |
                                      D3DCREATE_MIXED_VERTEXPROCESSING | D3DCREATE_HARDWARE_VERTEXPROCESSING)) |
                           D3DCREATE_SOFTWARE_VERTEXPROCESSING;
            args[4] = ptr(newFlags);
            emit({ api: "CreateDevice", behaviorFlags: flags, patchedFlags: newFlags });

            // D3DPRESENT_PARAMETERS (32-bit offsets)
            var pp = args[5];
            if (!pp.isNull()) {
                try {
                    var oldW = pp.readU32(), oldH = pp.add(4).readU32();
                    var oldFmt = pp.add(8).readU32(), oldCount = pp.add(0x0c).readU32();
                    var oldMs = pp.add(0x10).readU32();
                    var oldSwap = pp.add(0x18).readU32();
                    var oldHwnd = pp.add(0x1c).readU32(), oldWin = pp.add(0x20).readU32();
                    var oldDepth = pp.add(0x24).readU32(), oldDepthFmt = pp.add(0x28).readU32();
                    var oldFlags = pp.add(0x2c).readU32(), oldRate = pp.add(0x30).readU32();
                    // Vanilla to the bone: the d3d9 runtime validates PP
                    // against REAL driver caps — our Check* lies don't help
                    // here, so ask for the most universally valid setup.
                    pp.writeU32(640); pp.add(4).writeU32(480);        // 640x480
                    pp.add(8).writeU32(22);                            // X8R8G8B8
                    pp.add(0x0c).writeU32(1);                           // count 1
                    pp.add(0x10).writeU32(0);                           // MS NONE
                    pp.add(0x14).writeU32(0);                           // MS quality 0
                    pp.add(0x18).writeU32(1);                           // DISCARD
                    if (oldHwnd === 0) {
                        var desk = Process.getModuleByName("user32.dll").findExportByName("GetDesktopWindow");
                        pp.add(0x1c).writePointer(new NativeFunction(desk, "pointer", [])(  ));
                    }
                    pp.add(0x20).writeU32(1);                           // windowed
                    pp.add(0x24).writeU32(0);                           // no autodepth
                    pp.add(0x28).writeU32(0);
                    pp.add(0x2c).writeU32(0);                           // flags
                    pp.add(0x30).writeU32(0);                           // rate
                    pp.add(0x34).writeU32(0);                           // interval default
                    emit({ api: "CreateDevice.pp", was: { w: oldW, h: oldH, fmt: oldFmt,
                        count: oldCount, ms: oldMs, swap: oldSwap, hwnd: oldHwnd,
                        windowed: oldWin, depth: oldDepth, depthFmt: oldDepthFmt,
                        flags: oldFlags, rate: oldRate } });
                } catch (e) {
                    emit({ api: "CreateDevice.pp", err: "" + e });
                }
            }
        },
        onLeave: function (retval) {
            emit({ api: "CreateDevice.ret", hr: retval.toInt32() >>> 0 });
            console.log("[gpu] CreateDevice -> 0x" + (retval.toInt32() >>> 0).toString(16));
        }
    });
}

function armD3D9(module) {
    ["Direct3DCreate9", "Direct3DCreate9Ex"].forEach(function (exp) {
        var p = module.findExportByName(exp);
        if (!p) return;
        if (exp === "Direct3DCreate9") {
            Interceptor.attach(p, {
                onEnter: function (args) { emit({ api: "Direct3DCreate9", sdk: args[0].toInt32() }); },
                onLeave: function (retval) {
                    var d3d9 = retval;
                    if (!d3d9.isNull()) patchVtable(d3d9, "Direct3DCreate9");
                    else emit({ api: "Direct3DCreate9.ret", hr: 0 });
                }
            });
            emit({ note: "hooked", api: exp, at: "" + p });
            selfTest(p);   // direct CreateDevice probe — splits hook-vs-runtime blame
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

// selfTest: call Direct3DCreate9 + CreateDevice ourselves with minimal
// params. If THIS fails with INVALIDCALL too, the d3d9 runtime/driver
// refuses device creation on this video stack — no amount of game-side
// patching fixes that (escalate: translation layer or GPU passthrough).
function selfTest(pCreate9) {
    try {
        var create9 = new NativeFunction(pCreate9, "pointer", ["uint32"]);
        var d3d9 = create9(32);
        if (d3d9.isNull()) { emit({ api: "selftest", err: "Direct3DCreate9 returned NULL" }); return; }
        var vt = d3d9.readPointer();
        var pCreateDevice = vt.add(VT.CreateDevice * Process.pointerSize).readPointer();
        var createDevice = new NativeFunction(pCreateDevice, "uint32",
            ["pointer", "uint32", "uint32", "pointer", "uint32", "pointer", "pointer"], "stdcall");
        var user32 = Process.getModuleByName("user32.dll");
        var desktop = new NativeFunction(user32.findExportByName("GetDesktopWindow"), "pointer", [])( );
        [1, 4].forEach(function (devType) {   // HAL, then NULLREF for the record
            var pp = Memory.alloc(0x38);
            pp.writeU32(640); pp.add(4).writeU32(480); pp.add(8).writeU32(22);
            pp.add(0x0c).writeU32(1); pp.add(0x18).writeU32(1); pp.add(0x20).writeU32(1);
            var out = Memory.alloc(Process.pointerSize);
            var hr = createDevice(d3d9, 0, devType, desktop, 0x20, pp, out);
            emit({ api: "selftest.CreateDevice", devType: devType, hr: hr >>> 0,
                   devPtr: "" + out.readPointer() });
            console.log("[gpu] selftest devType=" + devType + " hr=0x" + (hr >>> 0).toString(16));
        });
    } catch (e) {
        emit({ api: "selftest", err: "" + e });
    }
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
emit({ note: "gpu_shim.js loaded", pid: Process.id });
console.log("[gpu] shim loaded into pid " + Process.id);
