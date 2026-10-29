import CoreGraphics
import Foundation
import WMCore

/// SkyLight symbols and classes the lab doctor checks (same list as spaceslab doctor).
private let doctorSymbols = [
    "SLSMainConnectionID", "SLSCopyManagedDisplaySpaces", "SLSCopySpacesForWindows", "SLSGetActiveSpace",
    "SLSManagedDisplayGetCurrentSpace", "SLSMoveWindowsToManagedSpace", "SLSSpaceSetCompatID",
    "SLSSetWindowListWorkspace", "SLSPerformAsynchronousBridgedWindowManagementOperation",
    "SLSCopyWindowsWithOptionsAndTags",
]
private let doctorClasses = ["SLSBridgedMoveWindowsToManagedSpaceOperation"]

/// Reads one `defaults` boolean through Process. Nil when the key is missing or unreadable.
private func defaultsBool(domain: String, key: String) -> Bool? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["read", domain, key]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return parseDefaultsBool(String(decoding: data, as: UTF8.self))
}

private func doctorItems() -> [DoctorItem] {
    let trusted = AXPermission.isTrusted()
    let screen = CGPreflightScreenCaptureAccess()
    let loaded = PrivateSymbols.isLoaded

    var symbols: [String: Bool] = [:]
    for name in doctorSymbols { symbols[name] = PrivateSymbols.exists(name) }
    var classes: [String: Bool] = [:]
    for name in doctorClasses { classes[name] = NSClassFromString(name) != nil }
    let health = SkyLightHealth.evaluate(symbols: symbols, classes: classes,
                                         osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                         loadError: PrivateSymbols.loadError)

    // A missing key means the macOS default: Stage Manager off, Spaces rearranged by recent use.
    let stageManager = StageManagerProvider.live.isEnabled() ?? false
    let rearrange = defaultsBool(domain: "com.apple.dock", key: "mru-spaces") ?? true

    var healthDetail = health.overall.rawValue
    if !health.missing.isEmpty { healthDetail += ", missing: " + health.missing.joined(separator: ", ") }

    return [
        DoctorItem(id: "accessibility", title: "Accessibility", ok: trusted,
                   detail: trusted ? "trusted" : "NOT trusted",
                   fix: trusted ? nil : "System Settings > Privacy & Security > Accessibility: add your terminal app, switch it on, run again."),
        DoctorItem(id: "screenRecording", title: "Screen recording", ok: screen,
                   detail: screen ? "granted" : "NOT granted",
                   fix: screen ? nil : "System Settings > Privacy & Security > Screen & System Audio Recording: allow your terminal app."),
        DoctorItem(id: "skyLight", title: "SkyLight", ok: loaded,
                   detail: loaded ? "loaded" : "NOT loaded (\(PrivateSymbols.loadError ?? "unknown error"))",
                   fix: loaded ? nil : "Spaces and window moves need SkyLight; check the macOS version."),
        DoctorItem(id: "skyLightHealth", title: "SkyLight health", ok: health.overall == .ok,
                   detail: healthDetail,
                   fix: health.overall == .ok || health.fallbacks.isEmpty ? nil : health.fallbacks.joined(separator: "; ")),
        DoctorItem(id: "stageManager", title: "Stage Manager", ok: !stageManager,
                   detail: stageManager ? "ON" : "off",
                   fix: stageManager ? "Control Center > Stage Manager: turn it off. Window moves and Spaces results differ with it on." : nil),
        DoctorItem(id: "autoRearrangeSpaces", title: "Automatically rearrange Spaces", ok: !rearrange,
                   detail: rearrange ? "ON" : "off",
                   fix: rearrange ? "System Settings > Desktop & Dock: turn off 'Automatically rearrange Spaces based on most recent use'." : nil),
    ]
}

func registerDoctorCommands(_ r: Registry) {
    r.register(Command(["doctor"], summary: "Check Accessibility, screen recording, SkyLight and Spaces settings (exit 4 if Accessibility is missing)") { _, _ in
        let items = doctorItems()
        let encoded = try JSONValue.from(items)
        let data = JSONValue.object(["healthy": .bool(items.allSatisfy(\.ok)), "items": encoded])
        return CLIResult(data: data, exit: DoctorReport.exit(items), text: DoctorReport.text(items))
    })
}
