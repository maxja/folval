
const WS2 = Process.getModuleByName("ws2_32.dll");
const getaddrinfoPtr = WS2.getExportByName("getaddrinfo");

if (getaddrinfoPtr) {
    Interceptor.attach(getaddrinfoPtr, {
        onEnter: function (args) {
            this.hostname = args[0].readUtf8String();
            this.service = args[1].readUtf8String();
            console.log(`[getaddrinfo] hostname: ${this.hostname}, service: ${this.service}`);
        }
    });
} else {
    console.log("getaddrinfo not found in ws2_32.dll");
}
