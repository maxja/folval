// re/frida/phase4b/window_enum.js — desktop dialog reader (Phase 4b).
//
// Attaches to ANY session-1 process (e.g. steam.exe via the :27043
// user-session frida-server) and enumerates the interactive desktop's
// visible top-level windows: title text, class, owning pid. Polls and
// emits NEW windows as they appear (dialogs, error boxes, launcher UI) —
// the host sees every alert without anyone reading the VNC screen.
//
// Run:
//   FOLVAL_FRIDA_PORT=27043 bash host/tools/frida-run.sh steam.exe re/frida/phase4b/window_enum.js [wait_s]

"use strict";

var seen = {};   // key text|class -> first ts
var MAX_EVENTS = 400;

var u32 = Process.getModuleByName("user32.dll");
var pEnumWindows     = u32.findExportByName("EnumWindows");
var pIsWindowVisible = u32.findExportByName("IsWindowVisible");
var pGetWindowTextW  = u32.findExportByName("GetWindowTextW");
var pGetClassNameW   = u32.findExportByName("GetClassNameW");
var pGetWindowThreadProcessId = u32.findExportByName("GetWindowThreadProcessId");

var enumWindows     = new NativeFunction(pEnumWindows, "int", ["pointer", "pointer"]);
var isWindowVisible = new NativeFunction(pIsWindowVisible, "int", ["pointer"]);
var getWindowTextW  = new NativeFunction(pGetWindowTextW, "int", ["pointer", "pointer", "int"]);
var getClassNameW   = new NativeFunction(pGetClassNameW, "int", ["pointer", "pointer", "int"]);
var getWndTidPid    = new NativeFunction(pGetWindowThreadProcessId, "uint32", ["pointer", "pointer"]);

function emit(obj) { send(Object.assign({ t: "win" }, obj)); }

var pEnumChildWindows = u32.findExportByName("EnumChildWindows");
var enumChildWindows = new NativeFunction(pEnumChildWindows, "int", ["pointer", "pointer", "pointer"]);

function childTexts(hwnd) {
    var texts = [];
    var ccb = new NativeCallback(function (child, lparam) {
        try {
            var b = Memory.alloc(1024);
            getWindowTextW(child, b, 512);
            var s = b.readUtf16String() || "";
            if (s) texts.push(s);
        } catch (e) {}
        return 1;
    }, "int", ["pointer", "pointer"]);
    try { enumChildWindows(hwnd, ccb, ptr(0)); } catch (e) {}
    return texts;
}

var cb = new NativeCallback(function (hwnd, lparam) {
    try {
        if (!isWindowVisible(hwnd)) return 1;
        var tbuf = Memory.alloc(1024);
        var cbuf = Memory.alloc(512);
        getWindowTextW(hwnd, tbuf, 512);
        getClassNameW(hwnd, cbuf, 256);
        var text = tbuf.readUtf16String() || "";
        var cls = cbuf.readUtf16String() || "";
        if (!text && !cls) return 1;
        var pidBuf = Memory.alloc(4);
        getWndTidPid(hwnd, pidBuf);
        var key = text + "|" + cls;
        var kids = (cls === "#32770") ? childTexts(hwnd) : [];   // dialogs: read the body
        var kidKey = key + "|" + kids.join("\u0001");
        if (!seen[kidKey]) {
            seen[kidKey] = Date.now();
            if (Object.keys(seen).length <= MAX_EVENTS) {
                emit({ text: text, class: cls, pid: pidBuf.readU32(), children: kids });
                console.log("[win] pid=" + pidBuf.readU32() + " class=" + cls +
                    " text=" + text + (kids.length ? " body=[" + kids.join(" / ") + "]" : ""));
            }
        }
    } catch (e) { /* keep enumerating */ }
    return 1;
}, "int", ["pointer", "pointer"]);

function sweep() {
    try { enumWindows(cb, ptr(0)); } catch (e) { emit({ err: "" + e }); }
}

emit({ note: "window_enum attached", pid: Process.id });
sweep();
setInterval(sweep, 3000);
