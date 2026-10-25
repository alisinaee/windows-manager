import AppKit
import Foundation
import WMCore

enum DoctorCommand {
    static let name = "doctor"
    static let help = "Check Accessibility, SkyLight symbols and the Dock setting (--json for JSON)"

    /// SkyLight symbols the later experiments rely on.
    static let symbols = [
        "SLSMainConnectionID",
        "SLSCopyManagedDisplaySpaces",
        "SLSCopySpacesForWindows",
        "SLSGetActiveSpace",
        "SLSManagedDisplayGetCurrentSpace",
        "SLSMoveWindowsToManagedSpace",
        "SLSSpaceSetCompatID",
        "SLSSetWindowListWorkspace",
        "SLSPerformAsynchronousBridgedWindowManagementOperation",
        "SLSCopyWindowsWithOptionsAndTags",
    ]

    static let classes = ["SLSBridgedMoveWindowsToManagedSpaceOperation"]

    struct Report: Encodable {
        var macOS: String
        var accessibilityTrusted: Bool
        var skyLightLoaded: Bool
        var skyLightError: String?
        var symbols: [String: Bool]
        var classes: [String: Bool]
        /// Raw com.apple.dock "mru-spaces"; nil when the key is not set (macOS then uses its default, on).
        var dockMruSpaces: Bool?
        var autoRearrangeSpaces: Bool
    }

    static func run(_ args: [String]) -> Int32 {
        var json = false
        for arg in args {
            if arg == "--json" {
                json = true
            } else {
                fputs("doctor: unknown option \(arg) (usage: spaceslab doctor [--json])\n", stderr)
                return 2
            }
        }

        let report = collect()
        if json {
            printJSON(report)
        } else {
            printText(report)
        }
        // Missing symbols are informational; no Accessibility or no SkyLight means the lab cannot run.
        return report.accessibilityTrusted && report.skyLightLoaded ? 0 : 1
    }

    static func collect() -> Report {
        // Touching isLoaded does the dlopen, so the ObjC class lookup below can find SkyLight classes.
        let loaded = PrivateSymbols.isLoaded

        var symbolResults: [String: Bool] = [:]
        for name in symbols { symbolResults[name] = PrivateSymbols.exists(name) }
        var classResults: [String: Bool] = [:]
        for name in classes { classResults[name] = NSClassFromString(name) != nil }

        let mru = UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "mru-spaces") as? Bool
        return Report(
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            accessibilityTrusted: AXPermission.isTrusted(),
            skyLightLoaded: loaded,
            skyLightError: PrivateSymbols.loadError,
            symbols: symbolResults,
            classes: classResults,
            dockMruSpaces: mru,
            autoRearrangeSpaces: mru ?? true
        )
    }

    static func printJSON(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func printText(_ report: Report) {
        print("macOS:          \(report.macOS)")
        if report.accessibilityTrusted {
            print("Accessibility:  trusted")
        } else {
            print("Accessibility:  NOT trusted")
            print("  Grant it in System Settings > Privacy & Security > Accessibility:")
            print("  add the terminal app you run spaceslab from (Terminal, iTerm, ...), switch it on, then run again.")
        }
        if report.skyLightLoaded {
            print("SkyLight:       loaded")
        } else {
            print("SkyLight:       NOT loaded (\(report.skyLightError ?? "unknown error"))")
        }

        print("")
        print("SkyLight symbols:")
        for name in symbols {
            print("  \((report.symbols[name] ?? false) ? "yes" : "NO ")  \(name)")
        }
        print("")
        print("ObjC classes:")
        for name in classes {
            print("  \((report.classes[name] ?? false) ? "yes" : "NO ")  \(name)")
        }

        print("")
        let raw = report.dockMruSpaces.map { $0 ? "mru-spaces = 1" : "mru-spaces = 0" } ?? "mru-spaces not set, macOS default"
        if report.autoRearrangeSpaces {
            print("Auto-rearrange Spaces by recent use: ON (\(raw))")
            print("  macOS reorders Desktops after use; Spaces order tests will drift.")
        } else {
            print("Auto-rearrange Spaces by recent use: off (\(raw))")
        }
    }
}
