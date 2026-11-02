import Foundation
import WMCore

/// `wm profile action ...` (P9.4): the UI steps a profile runs before or after its restore. Editing goes through
/// ProfileService (the same calls the Studio makes). `test` runs one action now with the system providers and
/// touches real windows and apps, so it needs --yes (MCP: confirm).

/// Reads a steps file, or standard input for "-".
private func readStepsData(_ source: String) throws -> Data {
    if source == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
    guard let data = FileManager.default.contents(atPath: source) else {
        throw CLIFailure.usage("Cannot read the steps file \(source).", hint: "Pass a JSON file, or - for standard input")
    }
    return data
}

private func phaseWord(_ phase: ActionPhase) -> String {
    phase == .beforeRestore ? "before" : "after"
}

private func actionSummary(_ action: ProfileAction, position: Int) -> JSONValue {
    .object([
        "position": .int(position),
        "id": .string(action.id.uuidString),
        "name": .string(action.name),
        "phase": .string(action.phase.rawValue),
        "enabled": .bool(action.enabled),
        "steps": .int(action.steps.count),
    ])
}

private func stepsText(_ action: ProfileAction) -> String {
    action.steps.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
}

/// True when a step reads or drives the UI (needs Accessibility or key events).
private func needsAccessibility(_ step: ActionStep) -> Bool {
    switch step.unwrapped {
    case .press, .menu, .typeText, .key, .waitFor: return true
    case .launchApp, .shell, .openURL, .runShortcut, .delay, .optional: return false
    }
}

func registerProfileActionCommands(_ r: Registry) {
    let profileArg = CLIArg("profile", "Profile name or id")
    let actionArg = CLIArg("action", "Action name or id (see wm profile action list)")
    let stepsOption = CLIOption("steps-json", "Steps as a JSON array (file path, or - for standard input)",
                                takesValue: true, valueName: "file|-")

    func cmd(_ path: [String], _ summary: String, args: [CLIArg] = [], options: [CLIOption] = [],
             mutates: Bool = true, touchesWindows: Bool = false,
             _ body: @escaping (ParsedArgs) throws -> CLIResult) {
        r.register(Command(path, summary: summary, args: args, options: options,
                           mutates: mutates, touchesWindows: touchesWindows) { a, _ in
            try service { try body(a) }
        })
    }

    cmd(["profile", "action", "list"], "List a profile's actions in run order", args: [profileArg], mutates: false) { a in
        let list = try profiles().actions(a.positionals[0])
        let data = JSONValue.array(list.enumerated().map { actionSummary($0.element, position: $0.offset + 1) })
        let text = list.enumerated().map { i, action in
            "\(i + 1)\t\(action.name)\t\(phaseWord(action.phase))\t\(action.enabled ? "on" : "off")\t\(action.steps.count) step(s)"
        }.joined(separator: "\n")
        return CLIResult(data: data, text: text.isEmpty ? "No actions." : text)
    }

    cmd(["profile", "action", "show"], "Show one action with all its steps",
        args: [profileArg, actionArg], mutates: false) { a in
        let action = try profiles().action(a.positionals[0], action: a.positionals[1])
        return CLIResult(data: try JSONValue.from(action), text: stepsText(action))
    }

    cmd(["profile", "action", "add"], "Add an action that runs before or after the restore (steps optional)",
        args: [profileArg],
        options: [CLIOption("name", "Action name", takesValue: true, valueName: "name"),
                  CLIOption("phase", "before | after", takesValue: true, valueName: "phase"),
                  stepsOption]) { a in
        guard let name = a.value("name") else { throw CLIFailure.usage("Give the action name with --name <name>.") }
        guard let phaseText = a.value("phase") else { throw CLIFailure.usage("Give the phase with --phase before|after.") }
        let phase = try ProfileService.parsePhase(phaseText)
        let steps = try a.value("steps-json").map { try ProfileService.decodeSteps(try readStepsData($0)) } ?? []
        let created = try profiles().addAction(a.positionals[0], name: name, phase: phase, steps: steps)
        return CLIResult(data: try JSONValue.from(created),
                         text: "Added action \"\(created.name)\" (\(created.id.uuidString)) with \(created.steps.count) step(s)")
    }

    cmd(["profile", "action", "set-steps"], "Replace an action's steps with the JSON array in --steps-json",
        args: [profileArg, actionArg], options: [stepsOption]) { a in
        guard let source = a.value("steps-json") else {
            throw CLIFailure.usage("Give the steps with --steps-json <file|->.")
        }
        let steps = try ProfileService.decodeSteps(try readStepsData(source))
        let action = try profiles().setActionSteps(a.positionals[0], action: a.positionals[1], steps: steps)
        return CLIResult(data: try JSONValue.from(action), text: "Set \(steps.count) step(s) on \"\(action.name)\"")
    }

    cmd(["profile", "action", "rename"], "Rename an action",
        args: [profileArg, actionArg, CLIArg("new-name", "The new name")]) { a in
        let action = try profiles().renameAction(a.positionals[0], action: a.positionals[1], to: a.positionals[2])
        return CLIResult(data: try JSONValue.from(action), text: "Renamed to \"\(action.name)\"")
    }

    cmd(["profile", "action", "enable"], "Turn an action on (it runs at restore time)",
        args: [profileArg, actionArg]) { a in
        let action = try profiles().setActionEnabled(a.positionals[0], action: a.positionals[1], enabled: true)
        return CLIResult(data: try JSONValue.from(action), text: "\"\(action.name)\" is on")
    }

    cmd(["profile", "action", "disable"], "Turn an action off (it is kept but skipped at restore time)",
        args: [profileArg, actionArg]) { a in
        let action = try profiles().setActionEnabled(a.positionals[0], action: a.positionals[1], enabled: false)
        return CLIResult(data: try JSONValue.from(action), text: "\"\(action.name)\" is off")
    }

    cmd(["profile", "action", "move"], "Move an action to a 1-based position in the list",
        args: [profileArg, actionArg, CLIArg("position", "1-based position")]) { a in
        let position = try ProfileArgs.parseInt(a.positionals[2], name: "position")
        let action = try profiles().moveAction(a.positionals[0], action: a.positionals[1], toPosition: position)
        return CLIResult(data: try JSONValue.from(action), text: "Moved \"\(action.name)\" to position \(position)")
    }

    cmd(["profile", "action", "delete"], "Delete an action from a profile (needs --yes)",
        args: [profileArg, actionArg], options: [CLIOption("yes", "Confirm the delete")]) { a in
        guard a.flag("yes") else {
            throw CLIFailure.usage("Deleting action \(a.positionals[1]) needs --yes.",
                                   hint: "Run: wm profile action delete \(a.positionals[0]) \(a.positionals[1]) --yes")
        }
        let action = try profiles().deleteAction(a.positionals[0], action: a.positionals[1])
        return CLIResult(data: try JSONValue.from(action), text: "Deleted action \"\(action.name)\"")
    }

    cmd(["profile", "action", "test"],
        "Run one action now and report each step (clicks, types and runs commands; needs --yes)",
        args: [profileArg, actionArg],
        options: [CLIOption("yes", "Confirm: the steps act on real apps and windows now")],
        mutates: false, touchesWindows: true) { a in
        guard a.flag("yes") else {
            throw CLIFailure.usage("Testing action \(a.positionals[1]) runs its steps now: it clicks, types and runs commands.",
                                   hint: "Ask the user first, then add --yes")
        }
        let stored = try profiles().action(a.positionals[0], action: a.positionals[1])
        if stored.steps.contains(where: needsAccessibility) { try requireAccessibility() }
        // Like the Studio's Test Run: the action runs even when it is switched off.
        var runnable = stored
        runnable.enabled = true
        let report = runOnMain { () -> ActionRunReport in
            await ActionRunner(ax: SystemAXProvider(), process: SystemProcessRunner()).run(runnable)
        }
        var lines: [String] = [report.succeeded ? "Test run passed" : (report.cancelled ? "Test run cancelled" : "Test run failed")]
        lines[0] += String(format: " in %.1f s", report.duration)
        if !stored.enabled { lines.append("The action is off; it ran anyway because of the test.") }
        for step in report.steps {
            lines.append("\(step.index + 1). \(step.summary): \(step.status.rawValue)" + (step.error.map { " (\($0))" } ?? ""))
        }
        return CLIResult(data: try JSONValue.from(report), exit: report.succeeded ? .ok : .runtime,
                         text: lines.joined(separator: "\n"))
    }
}
