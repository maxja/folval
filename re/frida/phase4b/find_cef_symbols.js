
const moduleName = "libcef.dll";
const module = Process.getModuleByName(moduleName);
console.log(`Enumerating exports in ${moduleName} (${module.enumerateExports().length} exports)...`);

const patterns = ["socket", "connect", "send", "recv", "bind", "listen", "accept", "select", "poll", "getaddrinfo", "gethostbyname"];

module.enumerateExports().forEach(exp => {
    const name = exp.name.toLowerCase();
    if (patterns.some(p => name.includes(p))) {
        console.log(`  [MATCH] ${exp.name} at ${exp.address}`);
    }
});
