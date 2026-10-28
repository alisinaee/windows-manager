import WMCore

/// Workers: add a `registerXCommands(r)` call below (one line each, keep alphabetical-ish, do not reorder).
/// A command file only needs: `func registerXCommands(_ r: Registry) { r.register(Command(["x","y"], summary: "...") { args, ctx in ... }) }`
func registerAllCommands(_ r: Registry) {
    // registerProfileCommands(r)
    // registerRunCommands(r)
    // registerSystemCommands(r)
    registerStatusCommands(r)
}
