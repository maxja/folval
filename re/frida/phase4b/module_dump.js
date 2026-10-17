Process.enumerateModules().forEach(m => {
    console.log(`Module: ${m.name} @ ${m.base} (size: ${m.size})`);
});
