// connectlog.js — log every outbound TCP connect (pid + dst ip:port).
// Resolves which process owns the SNI-less :8443 TLS client.
'use strict';

function saToIpPort(sa) {
    try {
        const family = sa.readU16();
        if (family !== 2) return 'af' + family; // AF_INET only
        const port = (sa.add(2).readU8() << 8) | sa.add(3).readU8();
        const b0 = sa.add(4).readU8(), b1 = sa.add(5).readU8();
        const b2 = sa.add(6).readU8(), b3 = sa.add(7).readU8();
        return b0 + '.' + b1 + '.' + b2 + '.' + b3 + ':' + port;
    } catch (e) { return 'unreadable'; }
}

function log(api, ret, sa) {
    send({ api: api, dst: saToIpPort(sa), pid: Process.id,
           ret: ret.toInt32() });
}

['connect', 'WSAConnect'].forEach(function (fn) {
    const addr = Module.getExportByName('ws2_32.dll', fn);
    if (!addr) return;
    Interceptor.attach(addr, {
        onEnter: function (args) { this.sa = args[2]; },
        onLeave: function (ret) { log(fn, ret, this.sa); }
    });
});
send({ api: 'ready', pid: Process.id });
