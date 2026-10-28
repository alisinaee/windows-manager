import WMCore

/// Workers: add a `registerXCommands(r)` call below (one line each, keep alphabetical-ish, do not reorder).
/// A command file only needs: `func registerXCommands(_ r: Registry) { r.register(Command(["x","y"], summary: "...") { args, ctx in ... }) }`
func registerAllCommands(_ r: Registry) {
    registerProfileCommands(r)
    // registerRunCommands(r)
    registerDoctorCommands(r)
    registerSettingsCommands(r)
    registerLayoutCommands(r)
    registerRuleCommands(r)
    registerDebugTestsCommands(r)
    registerSpacesCommands(r)
    registerStatusCommands(r)
    registerWindowLimitsCommands(r)
    registerCaptureCommands(r)
    registerPlanCommands(r)
    registerRunCommands(r)
    registerVerifyCommands(r)
    registerSchemaCommands(r)
    registerAgentGuideCommands(r)
    registerReportCommands(r)
}
