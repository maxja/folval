
const WS2 = Process.getModuleByName("ws2_32.dll");
const connectPtr = WS2.getExportByName("connect");

Interceptor.attach(connectPtr, {
    onEnter: function (args) {
        const sockaddrPtr = args[1];
        const family = sockaddrPtr.readU16();

        // AF_INET is 2
        if (family === 2) {
            const portRaw = sockaddrPtr.add(2).readU16();
            // Convert from network byte order (big-endian) to host byte order
            const port = ((portRaw & 0xFF) << 8) | ((portRaw & 0xFF00) >> 8);

            const ipRaw = sockaddrPtr.add(4).readU32();
            const ip = [
                (ipRaw & 0xFF),
                (ipRaw >> 8) & 0xFF,
                (ipRaw >> 16) & 0xFF,
                (ipRaw >> 24) & 0xFF
            ].join('.');

            console.log(`[connect] IP: ${ip}, Port: ${port}`);

            if (port === 11234) {
                console.log("[!!!] Analytics connection detected to port 11234!");
                // We found it!
            }
        }
    }
});
