// connectlog2.js — log outbound TCP connects; tolerant of late ws2_32 load.
'use strict';

function saToIpPort(sa) {
    try {
        const family = sa.readU16();
        if (family !== 2) return 'af' + family;
        const port = (sa.add(2).readU8() << 8) | sa.add(3).readU8();
        const b = [0, 1, 2, 3].map(function (i) { return sa.add(4 + i).readU8(); });
        return b[0] + '.' + b[1] + '.' + b[2] + '.' + b[3] + ':' + port;
    } catch (e) { return 'unreadable'; }
}

let installed = 0;
function tryInstall() {
    const mod = Process.findModuleByName('ws2_32.dll');
    if (!mod) return false;
    ['connect', 'WSAConnect'].forEach(function (fn) {
        const addr = mod.findExportByName(fn);
        if (!addr || installed & (fn === 'connect' ? 1 : 2)) return;
        installed |= (fn === 'connect' ? 1 : 2);
        Interceptor.attach(addr, {
            onEnter: function (args) { this.sa = args[2]; },
            onLeave: function (ret) {
                send({ api: fn, dst: saToIpPort(this.sa), pid: Process.id,
                       ret: ret.toInt32() });
            }
        });
    });
    return (installed & 3) === 3;
}

send({ api: 'ready', pid: Process.id });
if (!tryInstall()) {
    const iv = setInterval(function () {
        if (tryInstall()) {
            clearInterval(iv);
            send({ api: 'installed-late', pid: Process.id });
        }
    }, 500);
}
