// folval Phase 4 gate: attach handshake + module-enumeration smoke test.
// Run:  host/frida-venv/bin/frida -H 192.168.100.10 -p <PID> -l re/frida/phase4_gate.js
// Exit: prints arch and a module sample; clean detach = gate passed.
console.log("arch:", Process.arch, "platform:", Process.platform);
var mods = Process.enumerateModules();
console.log("modules:", mods.length);
mods.slice(0, 5).forEach(function (m) {
    console.log("  " + m.name + "  size=0x" + m.size.toString(16) + "  base=" + m.base);
});
