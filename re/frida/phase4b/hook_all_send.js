
const WS2 = Process.getModuleByName("ws2_32.dll");
const funcs = ["send", "sendto", "WSASend", "WSASendTo", "WSASendMsg"];

funcs.forEach(funcName => {
    const ptr = WS2.getExportByName(funcName);
    if (ptr) {
        console.log(`Hooking ${funcName} at ${ptr}`);
        Interceptor.attach(ptr, {
            onEnter: function (args) {
                console.log(`[${funcName}] called`);
                // For send, sendto, WSASend, WSASendTo, WSASendMsg, we want to see the buffer
                // But the arguments differ. 
                // send(s, buf, len, flags)
                // sendto(s, buf, len, flags, dest, addrlen)
                // WSASend(s, bufs, num, len, flags, overlapped)
                // WSASendTo(s, buf, len, flags, dest, addrlen)
                // WSASendMsg(s, msg, flags)
                
                // This is getting complicated. Let's just log the call for now.
            }
        });
    } else {
        console.log(`${funcName} not found in ws2_32.dll`);
    }
});
