import Foundation
import WMCore

/// Everything `wm spaces --json` prints.
private struct SpacesSnapshot: Encodable {
    var generatedAt: String
    var macOS: String
    var activeSpaceID: UInt64
    var displays: [DisplaySpaces]
    var windows: [CatalogWindow]
}

private func spacesText(_ displays: [DisplaySpaces]) -> String {
    if displays.isEmpty { return "No displays reported by SkyLight." }
    var lines: [String] = []
    for (n, display) in displays.enumerated() {
        lines.append("Display \(n + 1): \(display.displayName ?? display.displayIdentifier)")
        for space in display.spaces {
            let label: String
            switch space.kind {
            case .desktop: label = "Desktop \(display.desktopNumber(of: space) ?? 0)"
            case .fullscreen:
                let apps = space.ownerAppNames.isEmpty ? "unknown app" : space.ownerAppNames.joined(separator: " + ")
                label = (space.isSplitView ? "Split View" : "Full screen") + ": " + apps
            case .other(let raw): label = "Other Space (type \(raw))"
            }
            lines.append("  [\(space.index + 1)] \(label)" + (space.isCurrent ? " (current)" : ""))
        }
    }
    return lines.joined(separator: "\n")
}

func registerSpacesCommands(_ r: Registry) {
    r.register(Command(["spaces"], summary: "List displays, Desktops, full-screen Spaces and windows (read-only)") { _, _ in
        let displays = try cliService { try SpaceReader.displays() }
        let snapshot = SpacesSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            activeSpaceID: SpaceReader.activeSpaceID(),
            displays: displays,
            windows: WindowCatalog.all()
        )
        return CLIResult(data: try JSONValue.from(snapshot), text: spacesText(displays))
    })
}
