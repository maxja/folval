// re/frida/phase4b/recon.js — consolidated passive recon probe (Phase 4b).
//
// One script replaces the six former one-offs (find_dns, find_analytics,
// find_send, hook_all_send, combined_monitor, module_dump). Run it via:
//   bash host/tools/frida-run.sh <pid|name> re/frida/phase4b/recon.js [wait_s]
//
// What it does (all passive — no calls are made or modified):
//   1. Module census: interesting-module presence + main module geometry.
//   2. Export scan for modules named in CONFIG.scanExports (socket-ish names).
//   3. DNS:  getaddrinfo / GetAddrInfoW / GetHostByNameW hostnames.
//   4. Sockets: connect-family calls (fd -> ip:port map), then send-family
//      buffers with a hex+ascii HEAD of HEAD_MAX bytes.
//
// Events go out via send() as JSON objects {t: "...", ...} — the host runner
// tees them to out/<ts>-<target>-recon.jsonl. Human-readable summaries go to
// console.log. Event emission stops (with one final notice) after MAX_EVENTS.
//
// Known gaps (deliberate): ConnectEx (WSAIoctl extension pointer — needs
// per-process GUID lookup, add only if recon shows the game using it) and
// recv-family reads (enable via CONFIG.hookRecv once egress shape is known).

"use strict";

var CONFIG = {
    HEAD_MAX: 64,        // bytes of each send buffer to hex+ascii
    MAX_EVENTS: 2000,    // hard cap on send() events per run
    hookRecv: false,     // recv-family hooks (noisy; enable on demand)
    scanExports: [       // modules to scan for socket-ish exports (if present)
        "libcef.dll", "libeay32.dll", "ssleay32.dll"
    ],
    exportPatterns: [
        "socket", "connect", "send", "recv", "bind", "listen", "accept",
        "select", "poll", "getaddrinfo", "gethostbyname", "ssl"
    ]
};

var events = 0;
var stopped = false;

function emit(obj) {
    if (stopped) return;
    if (events >= CONFIG.MAX_EVENTS) {
        stopped = true;
        send({ t: "recon", note: "event cap reached (" + CONFIG.MAX_EVENTS + "); further events suppressed" });
        console.log("[recon] event cap reached; suppressing further events");
        return;
    }
    events++;
    send(obj);
}

// ---- buffer formatting ----------------------------------------------------

function headOf(buf, len) {
    var n = Math.min(len, CONFIG.HEAD_MAX);
    var bytes = new Uint8Array(buf, 0, n);
    var hex = "", ascii = "";
    for (var i = 0; i < bytes.length; i++) {
        var b = bytes[i];
        hex += (b < 16 ? "0" : "") + b.toString(16);
        ascii += (b >= 0x20 && b <= 0x7e) ? String.fromCharCode(b) : ".";
    }
    return { len: len, head: n, hex: hex, ascii: ascii };
}

function safeBytes(bufPtr, len) {
    try {
        return headOf(bufPtr.readByteArray(len), len);
    } catch (e) {
        return { len: len, head: 0, hex: "", ascii: "", err: "" + e };
    }
}

// ---- sockaddr parsing -----------------------------------------------------

function parseSockaddr(sa) {
    try {
        var family = sa.readU16();
        if (family !== 2) return { family: family }; // AF_INET only for now
        var portRaw = sa.add(2).readU16();           // network byte order
        var port = ((portRaw & 0xff) << 8) | ((portRaw >> 8) & 0xff);
        var ipRaw = sa.add(4).readU32();
        var ip = ((ipRaw & 0xff)) + "." + ((ipRaw >> 8) & 0xff) + "." +
                 ((ipRaw >> 16) & 0xff) + "." + ((ipRaw >> 24) & 0xff);
        return { family: family, ip: ip, port: port };
    } catch (e) {
        return { err: "" + e };
    }
}

// ---- module census --------------------------------------------------------

var INTERESTING = [
    "ws2_32.dll", "wsock32.dll", "libcef.dll", "libeay32.dll", "ssleay32.dll",
    "crypt32.dll", "bcrypt.dll", "ncrypt.dll", "schannel.dll",
    "wininet.dll", "winhttp.dll", "steam_api.dll"
];

function moduleCensus() {
    var mods = Process.enumerateModules();
    var main = Process.mainModule; // enumerateModules()[0] is NOT the exe in Frida 17
    emit({
        t: "modules",
        count: mods.length,
        main: { name: main.name, base: "" + main.base, size: main.size, path: main.path }
    });
    var found = [];
    mods.forEach(function (m) {
        if (INTERESTING.indexOf(m.name.toLowerCase()) !== -1) {
            found.push({ name: m.name, base: "" + m.base, size: m.size });
        }
    });
    emit({ t: "modules.interesting", found: found });
    console.log("[recon] " + mods.length + " modules; interesting: " +
        (found.map(function (m) { return m.name; }).join(", ") || "none"));

    CONFIG.scanExports.forEach(function (name) {
        var m = Process.findModuleByName(name);
        if (!m) return;
        var hits = [];
        m.enumerateExports().forEach(function (exp) {
            var lower = exp.name.toLowerCase();
            for (var i = 0; i < CONFIG.exportPatterns.length; i++) {
                if (lower.indexOf(CONFIG.exportPatterns[i]) !== -1) {
                    hits.push(exp.name);
                    break;
                }
            }
        });
        emit({ t: "exports.scan", module: name, matches: hits.slice(0, 40), total: hits.length });
        console.log("[recon] " + name + ": " + hits.length + " socket-ish exports" +
            (hits.length ? " (e.g. " + hits.slice(0, 5).join(", ") + ")" : ""));
    });
}

// ---- hooks ----------------------------------------------------------------

var ws2 = Process.findModuleByName("ws2_32.dll");
if (!ws2) {
    console.log("[recon] ws2_32.dll not present in target — nothing to hook");
} else {
    var fdDest = {}; // fd -> "ip:port" from connect-family calls

    function remember(fd, sa) {
        var p = parseSockaddr(sa);
        if (p.ip !== undefined) fdDest[fd] = p.ip + ":" + p.port;
        return p;
    }

    // Frida 17: static Module.findExportByName is gone — use the module
    // instance method (same pattern the Phase 4a scripts proved live).
    function hookExport(name, handlers) {
        var p = ws2.findExportByName(name);
        if (!p) { console.log("[recon] " + name + ": not exported"); return; }
        Interceptor.attach(p, handlers);
        console.log("[recon] hooked " + name);
    }

    // DNS
    hookExport("getaddrinfo", {
        onEnter: function (args) {
            var host = args[0].isNull() ? "(null)" : args[0].readUtf8String();
            emit({ t: "dns", api: "getaddrinfo", host: host });
        }
    });
    hookExport("GetAddrInfoW", {
        onEnter: function (args) {
            var host = args[0].isNull() ? "(null)" : args[0].readUtf16String();
            emit({ t: "dns", api: "GetAddrInfoW", host: host });
        }
    });
    hookExport("gethostbyname", {
        onEnter: function (args) {
            var host = args[0].isNull() ? "(null)" : args[0].readUtf8String();
            emit({ t: "dns", api: "gethostbyname", host: host });
        }
    });

    // connect family
    hookExport("connect", {
        onEnter: function (args) {
            var fd = args[0].toInt32();
            var p = remember(fd, args[1]);
            emit({ t: "conn", api: "connect", fd: fd, dst: p });
        }
    });
    hookExport("WSAConnect", {
        onEnter: function (args) {
            var fd = args[0].toInt32();
            var p = remember(fd, args[1]);
            emit({ t: "conn", api: "WSAConnect", fd: fd, dst: p });
        }
    });

    // send family
    hookExport("send", {
        onEnter: function (args) {
            emit(Object.assign({ t: "send", api: "send", fd: args[0].toInt32(),
                dst: fdDest[args[0].toInt32()] }, safeBytes(args[1], args[2].toInt32())));
        }
    });
    hookExport("sendto", {
        onEnter: function (args) {
            var fd = args[0].toInt32();
            emit(Object.assign({ t: "send", api: "sendto", fd: fd,
                dst: fdDest[fd] }, safeBytes(args[1], args[2].toInt32())));
        }
    });
    hookExport("WSASend", {
        onEnter: function (args) {
            wsabufEvents(args[1], args[2].toInt32(), "WSASend", args[0].toInt32());
        }
    });
    hookExport("WSASendTo", {
        onEnter: function (args) {
            wsabufEvents(args[1], args[2].toInt32(), "WSASendTo", args[0].toInt32());
        }
    });

    if (CONFIG.hookRecv) {
        hookExport("recv", {
            onLeave: function (retval) {
                var n = retval.toInt32();
                if (n > 0) emit(Object.assign({ t: "recv", api: "recv",
                    fd: this.fd, dst: fdDest[this.fd] }, safeBytes(this.buf, n)));
            },
            onEnter: function (args) { this.fd = args[0].toInt32(); this.buf = args[1]; }
        });
    }

    // WSABUF (x64): { ULONG len; 4B pad; CHAR* buf } — 16 bytes per element.
    function wsabufEvents(bufs, count, api, fd) {
        try {
            for (var i = 0; i < Math.min(count, 4); i++) {
                var wbuf = bufs.add(i * 16);
                var len = wbuf.readU32();
                var ptr = wbuf.add(8).readPointer();
                emit(Object.assign({ t: "send", api: api, fd: fd, bufIdx: i,
                    dst: fdDest[fd] }, safeBytes(ptr, len)));
            }
        } catch (e) {
            emit({ t: "send", api: api, fd: fd, err: "" + e });
        }
    }
}

moduleCensus();
emit({ t: "recon", note: "recon.js loaded and hooked", pid: Process.id });
console.log("[recon] loaded into pid " + Process.id + " — waiting for traffic");
