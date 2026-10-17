
const WS2 = Process.getModuleByName("ws2_32.dll");
const sendPtr = WS2.getExportByName("send");
const WSASendPtr = WS2.getExportByName("WSASend");

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
