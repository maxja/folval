// re/frida/phase4b/tls_plain.js — TLS plaintext capture (Phase 4b).
//
// Two paths, one script:
//   A. Launcher (PublicLauncher.exe): ships its own OpenSSL DLLs
//      (libeay32.dll / ssleay32.dll) with exported SSL_write/SSL_read —
//      hook the exports directly. This path is complete.
//   B. Game exe (SteamStub-packed per reference): reference claims statically-linked libCURL
//      inside the SteamStub-packed exe (no exports). At attach time the
//      unpacked image is live in memory, so this path SCANS the main
//      module for OpenSSL/libcurl markers and reports offsets only —
//      hook targets are pinned after recon.js tells us the shape. This
//      path is intentionally read-only for now.
//
// Run:  bash host/tools/frida-run.sh <pid|name> re/frida/phase4b/tls_plain.js [wait_s]

"use strict";

var CONFIG = {
    HEAD_MAX: 512,      // bytes of each TLS buffer to capture
    MAX_EVENTS: 2000,
    SCAN_MARKERS: ["OpenSSL", "libcurl", "curl_easy"],  // in-memory markers for path B
    SCAN_MATCH_CAP: 8   // per marker
};

var events = 0;
function emit(obj) {
    if (events++ < CONFIG.MAX_EVENTS) send(obj);
    else if (events === CONFIG.MAX_EVENTS) console.log("[tls] event cap reached");
}

function capture(bufPtr, len, dir) {
    var n = Math.min(len, CONFIG.HEAD_MAX);
    try {
        var bytes = new Uint8Array(bufPtr.readByteArray(n));
        var hex = "", ascii = "";
        for (var i = 0; i < bytes.length; i++) {
            var b = bytes[i];
            hex += (b < 16 ? "0" : "") + b.toString(16);
            ascii += (b >= 0x20 && b <= 0x7e) ? String.fromCharCode(b) : ".";
        }
        emit({ t: "tls", dir: dir, len: len, head: n, hex: hex, ascii: ascii });
    } catch (e) {
        emit({ t: "tls", dir: dir, len: len, err: "" + e });
    }
}

// ---- path A: exported OpenSSL (launcher) ----------------------------------

// Frida 17: static Module.findExportByName is gone — instance methods only.
function sslExport(dll, name) {
    var m = Process.findModuleByName(dll);
    return m ? m.findExportByName(name) : null;
}

var sslWrite = sslExport("libeay32.dll", "SSL_write") ||
               sslExport("ssleay32.dll", "SSL_write");
var sslRead = sslExport("libeay32.dll", "SSL_read") ||
              sslExport("ssleay32.dll", "SSL_read");

if (sslWrite) {
    Interceptor.attach(sslWrite, {
        onEnter: function (args) { capture(args[1], args[2].toInt32(), "out"); }
    });
    console.log("[tls] path A: hooked SSL_write @ " + sslWrite);
} else {
    console.log("[tls] path A: no exported SSL_write (libeay32/ssleay32 absent?)");
}

if (sslRead) {
    Interceptor.attach(sslRead, {
        onEnter: function (args) { this.buf = args[1]; },
        onLeave: function (retval) {
            var n = retval.toInt32();
            if (n > 0) capture(this.buf, n, "in");
        }
    });
    console.log("[tls] path A: hooked SSL_read @ " + sslRead);
} else {
    console.log("[tls] path A: no exported SSL_read");
}

// ---- path B: static TLS inside the main module (game) ---------------------

if (!sslWrite && !sslRead) {
    var main = Process.mainModule; // enumerateModules()[0] is NOT the exe in Frida 17
    console.log("[tls] path B: scanning main module " + main.name +
        " [" + main.base + " +0x" + main.size.toString(16) + "] for TLS markers");
    emit({ t: "tls.scan.start", module: main.name, base: "" + main.base, size: main.size });

    CONFIG.SCAN_MARKERS.forEach(function (marker) {
        var pattern = "";
        for (var i = 0; i < marker.length; i++) {
            if (i > 0) pattern += " ";
            pattern += ("0" + marker.charCodeAt(i).toString(16)).slice(-2);
        }
        try {
            Memory.scan(main.base, main.size, pattern, {
                onMatch: function (address, index) {
                    if (index < CONFIG.SCAN_MATCH_CAP) {
                        emit({ t: "tls.scan.hit", marker: marker,
                            offset: "0x" + address.sub(main.base).toString(16),
                            address: "" + address });
                    }
                },
                onComplete: function () {
                    console.log("[tls] scan '" + marker + "' complete");
                    emit({ t: "tls.scan.done", marker: marker });
                }
            });
        } catch (e) {
            emit({ t: "tls.scan.err", marker: marker, err: "" + e });
        }
    });
    console.log("[tls] path B: scan dispatched (read-only; hook targets pinned after recon)");
}

emit({ t: "tls", note: "tls_plain.js loaded", pid: Process.id });
