
const WS2 = Process.getModuleByName("ws2_32.dll");
const connectPtr = WS2.getExportByName("connect");
const sendPtr = WS2.getExportByName("send");
const WSASendPtr = WS2.getExportByName("WSASend");
const getaddrinfoPtr = WS2.getExportByName("getaddrinfo");

// 1. Monitor DNS
if (getaddrinfoPtr) {
    Interceptor.attach(getaddrinfoPtr, {
        onEnter: function (args) {
            this.hostname = args[0].readUtf8String();
            this.service = args[1].readUtf8String();
            console.log(`[DNS] getaddrinfo: hostname=${this.hostname}, service=${this.service}`);
        }
    });
}

// 2. Monitor Connections
if (connectPtr) {
    Interceptor.attach(connectPtr, {
        onEnter: function (args) {
            const sockaddrPtr = args[1];
            const family = sockaddrPtr.readU16();

            if (family === 2) { // AF_INET
                const portRaw = sockaddrPtr.add(2).readU16();
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
                }
            }
        }
    });
}

// 3. Monitor Sends
function logSend(buf, len) {
    try {
        const data = buf.readByteArray(len);
        console.log(`[send] len: ${len}, data: ${data}`);
    } catch (e) {
        console.log(`[send] error reading buffer: ${e}`);
    }
}

if (sendPtr) {
    Interceptor.attach(sendPtr, {
        onEnter: function (args) {
            const sockfd = args[0].toInt32();
            const buf = args[1];
            const len = args[2].toInt32();
            console.log(`[send] fd: ${sockfd}, len: ${len}`);
            logSend(buf, len);
        }
    });
}

if (WSASendPtr) {
    Interceptor.attach(WSASendPtr, {
        onEnter: function (args) {
            const sockfd = args[0].toInt32();
            const buf = args[2]; // WSABUF is at args[2]
            const len = buf.readU32(); // len is at offset 0 of WSABUF
            const actualBuf = buf.add(8); // buf + offset of lpBuffer (8 bytes)
            
            console.log(`[WSASend] fd: ${sockfd}, len: ${len}`);
            logSend(actualBuf, len);
        }
    });
}
