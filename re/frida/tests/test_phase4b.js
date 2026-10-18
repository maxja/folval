// re/frida/tests/test_phase4b.js — environment self-check for the Phase 4b
// probe family. Run against any harmless target (session-0 probe is fine):
//   bash host/tools/frida-run.sh --spawn C:\Windows\System32\notepad.exe re/frida/tests/test_phase4b.js
//
// Asserts the preconditions recon.js / tls_plain.js rely on: ws2_32 exports
// resolvable, module enumeration sane, send() routing live. Prints PASS/FAIL
// per check; any FAIL means the probe family must not be pointed at the game.

"use strict";

var checks = 0, fails = 0;

function check(name, ok, detail) {
    checks++;
    if (!ok) fails++;
    var line = (ok ? "PASS" : "FAIL") + " " + name + (detail ? " — " + detail : "");
    console.log("[test] " + line);
    send({ t: "test", name: name, ok: !!ok, detail: detail || "" });
}

var mods = Process.enumerateModules();
check("modules.enumerate", mods.length > 10, mods.length + " modules");

var ws2 = Process.findModuleByName("ws2_32.dll");
check("ws2_32.present", !!ws2, ws2 ? "" + ws2.base : "absent");

// Frida 17: static Module.findExportByName is gone — instance methods only.
var ws2Inst = ws2;
["connect", "send", "WSASend", "getaddrinfo", "GetAddrInfoW"].forEach(function (name) {
    var p = ws2Inst ? ws2Inst.findExportByName(name) : null;
    check("ws2_32." + name, !!p, p ? "" + p : "not exported");
});

// Path-A preconditions for tls_plain.js (launcher): informational only.
var leay = Process.findModuleByName("libeay32.dll");
var seay = Process.findModuleByName("ssleay32.dll");
check("openssl.dlls", true, "libeay32=" + !!leay + " ssleay32=" + !!seay +
    " (expected only in the launcher process)");

check("arch", Process.arch === "x64", Process.arch);
check("platform", Process.platform === "windows", Process.platform);

console.log("[test] " + (checks - fails) + "/" + checks + " checks passed" +
    (fails ? " — " + fails + " FAILED" : ""));
send({ t: "test.summary", passed: checks - fails, total: checks, ok: fails === 0 });
