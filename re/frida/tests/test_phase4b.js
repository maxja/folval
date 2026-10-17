const libcef = Process.findModuleByName("libcef.dll");
const bcrypt = Process.findModuleByName("bcrypt.dll");

if (libcef) {
    console.log(`libcef.dll: ${libcef.base}`);
    const sslWrite = libcef.findExportByName("SSL_write");
    const sslRead = libcef.findExportByName("SSL_read");
    console.log(`SSL_write in libcef.dll: ${sslWrite ? sslWrite : "Not found"}`);
    console.log(`SSL_read in libcef.dll: ${sslRead ? sslRead : "Not found"}`);
} else {
    console.log("libcef.dll not found");
}

if (bcrypt) {
    console.log(`bcrypt.dll: ${bcrypt.base}`);
    const bcryptEncrypt = bcrypt.findExportByName("BCryptEncrypt");
    console.log(`BCryptEncrypt in bcrypt.dll: ${bcryptEncrypt ? bcryptEncrypt : "Not found"}`);
} else {
    console.log("bcrypt.dll not found");
}
