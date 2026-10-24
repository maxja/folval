// re/frida/phase5/session_inject.js — run inject.exe FROM a session-1 process.
// Attach to steam.exe via the session-1 frida-server (:27043); after DELAY ms
// CreateProcessW(C:\re\inject.exe <target> <dll>) — child inherits session 1,
// so OpenProcess/VirtualAllocEx on desktop-session targets succeed (session-0
// WinRM inject fails err 5). Env: {"session_inject":{"delayMs":12000,"target":"<game-exe>","dll":"certpatch.dll"}}
"use strict";
(function () {
    var env = {};
    try { env = JSON.parse((Process.env && Process.env.FOLVAL_SCRIPT_ENV) || "{}"); } catch (e) {}
    var CFG = env.session_inject || {};
    var DELAY = CFG.delayMs || 12000;
    var TARGET = CFG.target || ""; // REQUIRED via env (identity stays out of the repo)
    var DLL = CFG.dll || "certpatch.dll";
    if (!TARGET) { send({ t: "session_inject", ev: "no_target" }); return; }

    var k32 = Process.getModuleByName("kernel32.dll");
    var CreateProcessW = new NativeFunction(k32.findExportByName("CreateProcessW"), "int",
        ["pointer", "pointer", "pointer", "pointer", "uint32", "uint32", "pointer", "pointer", "pointer", "pointer"]);

    var si = Memory.alloc(72); si.writeU32(68);        // STARTUPINFOW cb
    var pi = Memory.alloc(16);                          // PROCESS_INFORMATION
    var cmd = Memory.allocUtf16String('C:\\re\\inject.exe ' + TARGET + ' "' + DLL + '"');
    var cwd = Memory.allocUtf16String("C:\\re");

    send({ t: "session_inject", ev: "armed", delayMs: DELAY, target: TARGET });
    setTimeout(function () {
        var ok = CreateProcessW(ptr(0), cmd, ptr(0), ptr(0), 0, 0x00000200 /*CREATE_NEW_CONSOLE*/, ptr(0), cwd, si, pi);
        send({ t: "session_inject", ev: ok ? "launched" : "create_fail", err: ok ? 0 : 1, pid: pi.readU32() });
    }, DELAY);
})();
