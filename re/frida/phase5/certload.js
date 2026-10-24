// re/frida/phase5/certload.js — load certpatch.dll INTO the spawned game.
//
// Replaces the inject.exe dance (session-1 steam.exe → CreateProcessW →
// OpenProcess/VirtualAllocEx/CreateRemoteThread): inject.exe stopped landing
// certpatch after the 2026-10-24 Steam re-download (silent failure — "launched
// err=0" but zero mqel-certpatch.log sessions; worked 5x that morning).
// In-spawn LoadLibraryA is strictly simpler: same process, no cross-session
// OpenProcess, no path parsing. Timing mirrors the proven window: certpatch
// must land AFTER the packed exe unpacks (D3D9-create ~+4s) and BEFORE the
// first gameserver dial (~+30s); +12s post-load is the proven delay.
//
// Env (via FOLVAL_SCRIPT_ENV spawn composition):
//   {"certload":{"delayMs":12000,"dll":"C:\\re\\certpatch.dll"}}
(function () {
    var CFG = {};
    try { CFG = (typeof FOLVAL_SCRIPT_ENV !== "undefined" && FOLVAL_SCRIPT_ENV && FOLVAL_SCRIPT_ENV.certload) || (JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}")).certload || {}; } catch (e) {}
    var DELAY = CFG.delayMs || 12000;
    var DLL = CFG.dll || "certpatch.dll"; // relative resolves via the game's search path; absolute is safer

    var armed = false;
    function report(ev, extra) {
        var p = { t: "certload", ev: ev, dll: DLL, delayMs: DELAY };
        if (extra) { for (var k in extra) { p[k] = extra[k]; } }
        send(p);
    }

    function load() {
        if (armed) return; armed = true;
        try {
            var k32 = Process.getModuleByName("kernel32.dll");
            var LoadLibraryA = new NativeFunction(k32.findExportByName("LoadLibraryA"), "pointer", ["pointer"]);
            var pDll = Memory.allocAnsiString(DLL);
            var h = LoadLibraryA(pDll);
            if (h.isNull()) {
                var GetLastError = new NativeFunction(k32.findExportByName("GetLastError"), "uint32", []);
                report("load_fail", { err: GetLastError() });
            } else {
                report("loaded", { base: h.toString() });
            }
        } catch (e) {
            report("error", { err: String(e) });
        }
    }

    report("armed");
    setTimeout(load, DELAY);
})();
