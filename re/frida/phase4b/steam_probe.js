// re/frida/phase4b/steam_probe.js — Steam handshake observer (Phase 4b).
//
// Post-D3D9-fix (2026-10-19) the game initializes GPU resources then stalls
// in an active poll loop (Sleep(10) main loop + WaitForSingleObject(-1) on
// an init handle + a 3 s retry loop; wait_hunter evidence). No window, no
// child processes, no network, no logs. steam_api.dll IS loaded and the
// lab's Steam client is in OFFLINE mode (hermetic since D5) — this probe
// watches the Steamworks handshake live: which steam_api entry points the
// engine calls, what they return, and the steamipc pipe traffic shape.
//
// Composable: spawn with gpu_shim.js,steam_probe.js (frida-run.sh
// concatenates comma-separated scripts).
"use strict";

(function () {
    var api = Process.findModuleByName("steam_api.dll");
    if (!api) {
        send({ t: "steam", note: "steam_api.dll not loaded (observer waits)" });
        Process.attachModuleObserver({
            onAdded: function (m) {
                if (m.name.toLowerCase() === "steam_api.dll") arm(m);
            }
        });
    } else arm(api);

    function arm(mod) {
        send({ t: "steam", note: "steam_api.dll armed", base: "" + mod.base });
        var counts = {};
        var watch = [ "SteamAPI_Init", "SteamAPI_InitSafe", "SteamAPI_Shutdown",
                      "SteamAPI_RestartAppIfNecessary", "SteamAPI_RunCallbacks",
                      "SteamAPI_IsSteamRunning", "SteamAPI_GetHSteamPipe",
                      "SteamAPI_GetHSteamUser", "SteamAPI_SetMiniDumpComment",
                      "SteamAPI_WriteMiniDump", "SteamAPI_RegisterCallResult",
                      "SteamAPI_RegisterCallback", "SteamAPI_UnregisterCallResult",
                      "SteamAPI_UnregisterCallback", "SteamInternal_CreateInterface",
                      "SteamInternal_ContextInit", "SteamInternal_GameServer_Init" ];
        watch.forEach(function (n) {
            var p = mod.findExportByName(n);
            if (!p) return;
            Interceptor.attach(p, {
                onEnter: function (args) {
                    this.args = [args[0].toInt32(), args[1].toInt32()];
                    counts[n] = (counts[n] || 0) + 1;
                    if (counts[n] <= 3 || n.indexOf("RunCallbacks") < 0) {
                        send({ t: "steam", api: n, n: counts[n], args: this.args });
                        console.log("[steam] " + n + " #" + counts[n]);
                    }
                },
                onLeave: function (retval) {
                    if (n.indexOf("Init") >= 0 || n.indexOf("Restart") >= 0 ||
                        n.indexOf("Running") >= 0) {
                        send({ t: "steam", api: n + ".ret", hr: retval.toInt32() >>> 0 });
                        console.log("[steam] " + n + " -> " + (retval.toInt32() >>> 0));
                    }
                }
            });
            send({ t: "steam", note: "hooked", api: n });
        });

        // steamipc pipe + interesting file opens (loader-side handshake)
        var k32 = Process.getModuleByName("kernel32");
        var cf = k32.findExportByName("CreateFileW");
        if (cf) Interceptor.attach(cf, {
            onEnter: function (args) {
                try {
                    if (args[0].isNull()) return;
                    var path = args[0].readUtf16String();
                    if (path && (path.toLowerCase().indexOf("steam") >= 0 ||
                                 path.toLowerCase().indexOf("pipe") >= 0)) {
                        this.path = path;
                    }
                } catch (e) {}
            },
            onLeave: function (retval) {
                if (this.path) {
                    send({ t: "steam", api: "CreateFileW", path: this.path,
                           ok: retval.toInt32() !== -1 });
                    console.log("[steam] CreateFileW '" + this.path + "'");
                }
            }
        });

        setInterval(function () {
            var s = Object.keys(counts).map(function (k) { return k + " x" + counts[k]; }).join(" | ");
            send({ t: "steam", note: "agg", top: s });
            console.log("[steam] agg: " + s);
        }, 10000);
    }
})();
