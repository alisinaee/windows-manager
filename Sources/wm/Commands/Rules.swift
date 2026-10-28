import Foundation
import WMCore

/// Where a pin rule sends a window: `--space ID`, or `--desktop N --display UUID`.
private func pinTarget(from a: ParsedArgs) throws -> PinTarget {
    if let space = a.value("space") {
        guard let id = UInt64(space) else { throw CLIFailure.usage("--space must be a Space id number") }
        return .spaceID(id)
    }
    guard let desktop = a.value("desktop"), let number = Int(desktop) else {
        throw CLIFailure.usage("Give --desktop N --display UUID, or --space ID", hint: "Run: wm rules pins add --help")
    }
    guard let display = a.value("display"), !display.isEmpty else {
        throw CLIFailure.usage("--display UUID is required with --desktop")
    }
    return .desktopIndex(number: number, displayUUID: display)
}

private func windowAction(from a: ParsedArgs) throws -> WindowRuleAction {
    switch a.positionals[1] {
    case "ignore": return .ignore
    case "alwaysRestore": return .alwaysRestore
    case "pinToDisplay":
        guard let uuid = a.value("display"), !uuid.isEmpty else { throw CLIFailure.usage("pinToDisplay needs --display UUID") }
        return .pinToDisplay(uuid: uuid)
    default:
        throw CLIFailure.usage("Action must be ignore, alwaysRestore or pinToDisplay")
    }
}

func registerRuleCommands(_ r: Registry) {
    r.register(Command(["rules", "list"], summary: "Show auto profile settings, pin rules and window rules") { _, _ in
        let service = RuleService()
        let data = JSONValue.object([
            "autoProfile": try JSONValue.from(service.autoProfile()),
            "pins": try JSONValue.from(service.pins()),
            "windowRules": try JSONValue.from(service.windowRules()),
        ])
        return CLIResult(data: data)
    })

    r.register(Command(["rules", "pins"], summary: "List Space pin rules") { _, _ in
        let pins = RuleService().pins()
        return CLIResult(data: .object(["pins": try JSONValue.from(pins)]),
                         text: pins.map { "\($0.id.uuidString)\t\($0.bundleID)" }.joined(separator: "\n"))
    })

    r.register(Command(["rules", "pins", "add"], summary: "Add a pin rule: move a window of an app to a Desktop or Space",
                       args: [CLIArg("bundleID")],
                       options: [
                           CLIOption("desktop", "Desktop number (1-based)", takesValue: true, valueName: "N"),
                           CLIOption("display", "Display UUID for --desktop", takesValue: true, valueName: "uuid"),
                           CLIOption("space", "Space id instead of a Desktop", takesValue: true, valueName: "id"),
                           CLIOption("title", "Only windows whose title contains this", takesValue: true, valueName: "text"),
                       ]) { a, _ in
        let target = try pinTarget(from: a)
        let rule = try cliService { try RuleService().addPin(bundleID: a.positionals[0], titleContains: a.value("title"), target: target) }
        return CLIResult(data: try JSONValue.from(rule), text: rule.id.uuidString)
    })

    r.register(Command(["rules", "pins", "remove"], summary: "Remove a pin rule by id", args: [CLIArg("id")]) { a, _ in
        guard let id = UUID(uuidString: a.positionals[0]) else { throw CLIFailure.usage("Pin rule id must be a UUID") }
        try cliService { try RuleService().removePin(id) }
        return CLIResult(data: .object(["removed": .string(id.uuidString)]), text: "removed \(id.uuidString)")
    })

    r.register(Command(["rules", "window-rules"], summary: "List per-app window rules") { _, _ in
        let rules = RuleService().windowRules()
        return CLIResult(data: .object(["windowRules": try JSONValue.from(rules)]),
                         text: rules.map { "\($0.bundleID)" }.joined(separator: "\n"))
    })

    r.register(Command(["rules", "window-rules", "set"], summary: "Set a window rule: ignore, alwaysRestore or pinToDisplay",
                       args: [CLIArg("bundleID"), CLIArg("action", "ignore | alwaysRestore | pinToDisplay")],
                       options: [CLIOption("display", "Display UUID for pinToDisplay", takesValue: true, valueName: "uuid")]) { a, _ in
        let action = try windowAction(from: a)
        let rule = try cliService { try RuleService().setWindowRule(bundleID: a.positionals[0], action: action) }
        return CLIResult(data: try JSONValue.from(rule), text: "\(rule.bundleID)")
    })

    r.register(Command(["rules", "window-rules", "remove"], summary: "Remove the window rule of an app",
                       args: [CLIArg("bundleID")]) { a, _ in
        let bundleID = a.positionals[0]
        try cliService { try RuleService().removeWindowRule(bundleID: bundleID) }
        return CLIResult(data: .object(["removed": .string(bundleID)]), text: "removed \(bundleID)")
    })
}
