// re/frida/phase5/dump_text.js — exfiltrate the UNPACKED .text of the packed
// game exe at runtime (2026-10-23). The on-disk exe is UBX-packed (.text has
// no file backing); crash minidumps capture only the packed .UBX sections.
// Timing: dump at the first Direct3DCreate9 call — post anti-tamper CRC
// (+3.4s), code fully unpacked, engine still alive pre-Bloomberg-crash.
// Transport: base64 chunks via send() (JSONL-safe); host reassembles.
"use strict";
(function () {
    var TEXT_RVA = 0x1000, TEXT_END = 0x9EC000; // .text VA range (PE headers)
    var CHUNK = 0x18000; // 96KB raw -> 128KB base64 per send

    function gameModule() {
        var mods = Process.enumerateModules();
        for (var i = 0; i < mods.length; i++) {
            if (/\.exe$/i.test(mods[i].name)) return mods[i];
        }
        return null;
    }

    function dump(m) {
        var lo = m.base.add(TEXT_RVA), hi = m.base.add(TEXT_END);
        var total = hi.sub(lo).toInt32();
        var n = Math.ceil(total / CHUNK);
        send({ t: "dump_text", ev: "begin", base: "" + m.base, rva: "0x" + TEXT_RVA.toString(16), total: total, chunks: n });
        for (var i = 0; i < n; i++) {
            var off = i * CHUNK;
            var len = Math.min(CHUNK, total - off);
            var b;
            try { b = lo.add(off).readByteArray(len); }
            catch (e) { send({ t: "dump_text", ev: "chunk_err", i: i, err: "" + e }); continue; }
            // base64 without pulling in a lib: use Frida's built-in
            var b64 = arrayBufferToBase64(b);
            send({ t: "dump_text", ev: "chunk", i: i, len: len, b64: b64 });
        }
        send({ t: "dump_text", ev: "end", chunks: n });
    }

    function arrayBufferToBase64(buf) {
        var u8 = new Uint8Array(buf), s = "";
        var CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (var i = 0; i < u8.length; i += 3) {
            var b0 = u8[i], b1 = i + 1 < u8.length ? u8[i + 1] : 0, b2 = i + 2 < u8.length ? u8[i + 2] : 0;
            s += CHARS[b0 >> 2] + CHARS[((b0 & 3) << 4) | (b1 >> 4)]
               + (i + 1 < u8.length ? CHARS[((b1 & 15) << 2) | (b2 >> 6)] : "=")
               + (i + 2 < u8.length ? CHARS[b2 & 63] : "=");
        }
        return s;
    }

    var d3d9 = Process.findModuleByName("d3d9.dll");
    var exp = d3d9 ? d3d9.findExportByName("Direct3DCreate9") : null;
    if (exp) {
        var fired = false;
        Interceptor.attach(exp, {
            onEnter: function () {
                if (fired) return;
                fired = true;
                var m = gameModule();
                if (m) dump(m); else send({ t: "dump_text", ev: "no_exe" });
            }
        });
        send({ t: "dump_text", ev: "waiting_d3d9" });
    } else {
        send({ t: "dump_text", ev: "no_d3d9" });
    }
})();
