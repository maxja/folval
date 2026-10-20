// re/frida/phase4b/audio_probe.js — audio + CEF init observer (Phase 4b).
//
// Post-Steam-fix stall (2026-10-19): SteamAPI_Init OK, CEF paks loaded, a
// few textures created, then a 1 Hz poll loop forever — SteamAPI_RunCallbacks
// NEVER called (engine never reaches its main loop; stuck inside an init
// sub-step). The domain has NO audio device (game min-spec: SOUND CARD: Yes)
// and no dsound/winmm hook has ever observed this process — this probe
// watches DirectSound/waveOut/midi + CefInitialize live.
"use strict";

(function () {
    var seen = {};
    function once(k) { if (seen[k]) return false; seen[k] = 1; return true; }

    function armDsound(mod) {
        [ "DirectSoundCreate", "DirectSoundCreate8",
          "DirectSoundEnumerateA", "DirectSoundEnumerateW",
          "DirectSoundCaptureCreate", "DirectSoundCaptureCreate8" ].forEach(function (n) {
            var p = mod.findExportByName(n);
            if (!p) return;
            Interceptor.attach(p, {
                onEnter: function (args) { this.n = n; },
                onLeave: function (retval) {
                    send({ t: "audio", api: this.n, hr: retval.toInt32() >>> 0 });
                    console.log("[audio] " + this.n + " -> 0x" + (retval.toInt32() >>> 0).toString(16));
                }
            });
            send({ t: "audio", note: "hooked", api: n });
        });
    }
    function armWinmm(mod) {
        [ "waveOutGetNumDevs", "waveInGetNumDevs", "midiOutGetNumDevs",
          "midiOutOpen", "waveOutOpen", "auxGetNumDevs" ].forEach(function (n) {
            var p = mod.findExportByName(n);
            if (!p) return;
            Interceptor.attach(p, {
                onLeave: function (retval) {
                    if (once(n + ":" + retval)) {
                        send({ t: "audio", api: n, ret: retval.toInt32() >>> 0 });
                        console.log("[audio] " + n + " -> " + (retval.toInt32() >>> 0));
                    }
                }
            });
            send({ t: "audio", note: "hooked", api: n });
        });
    }
    function armCef(mod) {
        [ "CefInitialize", "CefExecuteProcess", "CefShutdown",
          "CefDoMessageLoopWork", "CefRunMessageLoop" ].forEach(function (n) {
            var p = mod.findExportByName(n);
            if (!p) return;
            Interceptor.attach(p, {
                onEnter: function () {
                    send({ t: "audio", api: n });
                    console.log("[audio] " + n);
                },
                onLeave: function (retval) {
                    send({ t: "audio", api: n + ".ret", ret: retval.toInt32() });
                    console.log("[audio] " + n + " -> " + retval.toInt32());
                }
            });
            send({ t: "audio", note: "hooked", api: n, in: "libcef" });
        });
    }

    var ds = Process.findModuleByName("dsound.dll");
    if (ds) armDsound(ds);
    var wm = Process.findModuleByName("winmm.dll");
    if (wm) armWinmm(wm);
    var cef = Process.findModuleByName("libcef.dll");
    if (cef) armCef(cef);

    Process.attachModuleObserver({
        onAdded: function (m) {
            var n = m.name.toLowerCase();
            if (n === "dsound.dll") armDsound(m);
            else if (n === "winmm.dll") armWinmm(m);
            else if (n === "libcef.dll") armCef(m);
            else if (n === "xaudio2_7.dll" || n === "xactengine3_7.dll" || n === "xinput1_3.dll") {
                send({ t: "audio", note: "legacy DirectX DLL loaded", dll: m.name });
                console.log("[audio] loaded " + m.name);
            }
        }
    });

    send({ t: "audio", note: "audio_probe loaded", pid: Process.id });
    console.log("[audio] audio_probe loaded into pid " + Process.id);
})();
