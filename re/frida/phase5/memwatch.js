// re/frida/phase5/memwatch.js — sample process memory + VA free-block census.
//
// 2026-10-24 stall diagnosis: at the post-quest transition (+~2:28 engine
// time) CreateRenderTarget fails 0x8007000e at EVERY size (2048²→256²) —
// a device-level failure. Two suspects: 32-bit VA exhaustion (frida agent +
// resurrect pages + unpacked engine + textures) vs WARP device budget/lost.
// This script needs no D3D internals: GetProcessMemoryInfo on a timer plus a
// VirtualQuery census (largest contiguous free VA block, count of free MB).
// If the largest free block collapses before the RT failure → VA story.
//
// Env: {"memwatch":{"intervalMs":10000}}
(function () {
    var CFG = {};
    try { CFG = (typeof FOLVAL_SCRIPT_ENV !== "undefined" && FOLVAL_SCRIPT_ENV && FOLVAL_SCRIPT_ENV.memwatch) || (JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}")).memwatch || {}; } catch (e) {}
    var INTERVAL = CFG.intervalMs || 10000;
    var MAX_SAMPLES = CFG.maxSamples || 120; // ~20min at 10s

    var k32 = Process.getModuleByName("kernel32.dll");
    var psapi = null;
    try { psapi = Process.getModuleByName("psapi.dll"); } catch (e) {}
    // K32GetProcessMemoryInfo on newer, psapi on older
    var gpmi = null;
    if (psapi) { gpmi = psapi.findExportByName("GetProcessMemoryInfo"); }
    if (!gpmi) { gpmi = k32.findExportByName("K32GetProcessMemoryInfo"); }
    var GetCurrentProcess = new NativeFunction(k32.findExportByName("GetCurrentProcess"), "pointer", []);

    function memInfo() {
        if (!gpmi) return null;
        // PROCESS_MEMORY_COUNTERS: cb(4) PageFaultCount(4) PeakWS(4) WS(4) QuotaPeakP(4) QuotaP(4) QuotaPeakNP(4) QuotaNP(4) Pagefile(4) PeakPagefile(4) = 40 bytes
        var buf = Memory.alloc(44);
        buf.writeU32(44);
        var fn = new NativeFunction(gpmi, "int", ["pointer", "pointer", "uint32"]);
        if (!fn(GetCurrentProcess(), buf, 44)) return null;
        return {
            ws: buf.add(12).readU32(),          // WorkingSetSize
            peakWs: buf.add(8).readU32(),
            pagefile: buf.add(32).readU32(),     // CommitCharge
            peakPagefile: buf.add(36).readU32()
        };
    }

    function vaCensus() {
        var VQ = new NativeFunction(k32.findExportByName("VirtualQuery"), "uint32", ["pointer", "pointer", "uint32"]);
        var MB = 1024 * 1024;
        // MEMORY_BASIC_INFORMATION32: BaseAddress(4) AllocationBase(4) AllocationProtect(4) RegionSize(4) State(4) Protect(4) Type(4) = 28
        var mbi = Memory.alloc(28);
        var addr = 0x10000, freeTotal = 0, freeLargest = 0, freeBlocks = 0;
        var reservedTotal = 0, imgTotal = 0, privTotal = 0;
        while (addr < 0x7FFEFFFF) {
            var n = VQ(ptr(addr), mbi, 28);
            if (n.toInt ? n.toInt() === 0 : n === 0) break;
            var regionSize = mbi.add(12).readU32();
            var state = mbi.add(16).readU32();    // 0x1000=MEM_COMMIT 0x10000=MEM_FREE 0x2000=MEM_RESERVE
            var type = mbi.add(24).readU32();      // 0x1000000=IMAGE 0x20000=PRIVATE 0x40000=MAPPED
            if (state === 0x10000) { // free
                freeTotal += regionSize; freeBlocks++;
                if (regionSize > freeLargest) freeLargest = regionSize;
            } else if (state === 0x2000) {
                reservedTotal += regionSize;
            }
            if (state === 0x1000) {
                if (type === 0x1000000) imgTotal += regionSize;
                else if (type === 0x20000) privTotal += regionSize;
            }
            addr += regionSize;
            if (regionSize === 0) break;
        }
        return {
            freeMB: Math.round(freeTotal / MB),
            largestFreeMB: Math.round(freeLargest / MB),
            freeBlocks: freeBlocks,
            reservedMB: Math.round(reservedTotal / MB),
            committedImgMB: Math.round(imgTotal / MB),
            committedPrivMB: Math.round(privTotal / MB)
        };
    }

    var n = 0;
    function sample() {
        try {
            var m = memInfo(), v = vaCensus();
            var p = { t: "memwatch", ev: "sample", n: n };
            if (m) { p.wsMB = Math.round(m.ws / 1048576); p.commitMB = Math.round(m.pagefile / 1048576); p.peakWsMB = Math.round(m.peakWs / 1048576); }
            if (v) { p.freeMB = v.freeMB; p.largestFreeMB = v.largestFreeMB; p.freeBlocks = v.freeBlocks; p.reservedMB = v.reservedMB; p.imgMB = v.committedImgMB; p.privMB = v.committedPrivMB; }
            send(p);
        } catch (e) {
            send({ t: "memwatch", ev: "error", err: String(e) });
        }
        n++;
        if (n < MAX_SAMPLES) setTimeout(sample, INTERVAL);
    }

    send({ t: "memwatch", ev: "armed", intervalMs: INTERVAL });
    setTimeout(sample, 2000);
})();
