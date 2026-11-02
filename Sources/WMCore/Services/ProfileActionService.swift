import Foundation

// Headless editing of a profile's UI actions (P9.4), used by `wm profile action`. An action is addressed by its
// UUID or its name (case-insensitive, unique within the profile). Positions are 1-based in list order.

extension ProfileService {
    /// "before" / "after", or the stored names "beforeRestore" / "afterRestore".
    public static func parsePhase(_ text: String) throws -> ActionPhase {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "before", "beforerestore": return .beforeRestore
        case "after", "afterrestore": return .afterRestore
        default: throw ServiceError.invalid("Phase \"\(text)\" is not valid. Use before or after.")
        }
    }

    /// Decodes a JSON array of steps (the Codable form of `ActionStep`) and checks every step.
    public static func decodeSteps(_ data: Data) throws -> [ActionStep] {
        let steps: [ActionStep]
        do {
            steps = try JSONDecoder().decode([ActionStep].self, from: data)
        } catch let error as DecodingError {
            throw ServiceError.invalid("The steps JSON does not match the step format: \(describe(error))")
        } catch {
            throw ServiceError.invalid("The steps are not valid JSON: \(error.localizedDescription)")
        }
        try validateSteps(steps)
        return steps
    }

    /// Checks values the decoder cannot: empty names, unknown key combinations, negative times, bad URLs.
    public static func validateSteps(_ steps: [ActionStep]) throws {
        for (index, step) in steps.enumerated() {
            do {
                try validateStep(step.unwrapped)
            } catch let error as ServiceError {
                throw ServiceError.invalid("Step \(index + 1): \(error.message)")
            }
        }
    }

    // MARK: Reading and editing

    public func actions(_ ref: String) throws -> [ProfileAction] {
        try show(ref).actions
    }

    public func action(_ ref: String, action: String) throws -> ProfileAction {
        let list = try show(ref).actions
        return list[try Self.actionIndex(action, in: list)]
    }

    /// Appends an action. It runs before or after the restore, last in its phase.
    @discardableResult
    public func addAction(_ ref: String, name: String, phase: ActionPhase, steps: [ActionStep] = [],
                          enabled: Bool = true) throws -> ProfileAction {
        let trimmed = try Self.cleanActionName(name)
        try Self.validateSteps(steps)
        return try editActions(ref) { list in
            try Self.requireFreeActionName(trimmed, in: list, except: nil)
            let created = ProfileAction(name: trimmed, phase: phase, steps: steps, enabled: enabled)
            list.append(created)
            return created
        }
    }

    /// Replaces the steps of an action.
    @discardableResult
    public func setActionSteps(_ ref: String, action: String, steps: [ActionStep]) throws -> ProfileAction {
        try Self.validateSteps(steps)
        return try editActions(ref) { list in
            let i = try Self.actionIndex(action, in: list)
            list[i].steps = steps
            return list[i]
        }
    }

    @discardableResult
    public func renameAction(_ ref: String, action: String, to name: String) throws -> ProfileAction {
        let trimmed = try Self.cleanActionName(name)
        return try editActions(ref) { list in
            let i = try Self.actionIndex(action, in: list)
            try Self.requireFreeActionName(trimmed, in: list, except: list[i].id)
            list[i].name = trimmed
            return list[i]
        }
    }

    @discardableResult
    public func setActionEnabled(_ ref: String, action: String, enabled: Bool) throws -> ProfileAction {
        try editActions(ref) { list in
            let i = try Self.actionIndex(action, in: list)
            list[i].enabled = enabled
            return list[i]
        }
    }

    /// Moves an action to a 1-based position in the list.
    @discardableResult
    public func moveAction(_ ref: String, action: String, toPosition position: Int) throws -> ProfileAction {
        try editActions(ref) { list in
            let i = try Self.actionIndex(action, in: list)
            guard position >= 1, position <= list.count else {
                throw ServiceError.invalid("Position must be from 1 to \(list.count).")
            }
            let moved = list.remove(at: i)
            list.insert(moved, at: position - 1)
            return moved
        }
    }

    /// Removes an action from the profile. Returns the removed action.
    @discardableResult
    public func deleteAction(_ ref: String, action: String) throws -> ProfileAction {
        try editActions(ref) { list in
            let i = try Self.actionIndex(action, in: list)
            return list.remove(at: i)
        }
    }

    // MARK: Plumbing

    /// Loads the profile, lets `change` edit its action list, saves it and returns the action `change` returns.
    private func editActions(_ ref: String, _ change: (inout [ProfileAction]) throws -> ProfileAction) throws -> ProfileAction {
        var profile = try show(ref)
        var list = profile.actions
        let result = try wrap { try change(&list) }
        profile.actions = list
        _ = try save(profile)
        return result
    }

    private static func actionIndex(_ ref: String, in list: [ProfileAction]) throws -> Int {
        let text = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text), let i = list.firstIndex(where: { $0.id == id }) { return i }
        let hits = list.indices.filter { list[$0].name.caseInsensitiveCompare(text) == .orderedSame }
        switch hits.count {
        case 0: throw ServiceError.notFound("No action named or with id \"\(text)\" in this profile.")
        case 1: return hits[0]
        default: throw ServiceError.conflict("\(hits.count) actions are named \"\(text)\"; use the id.")
        }
    }

    private static func cleanActionName(_ name: String) throws -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ServiceError.invalid("An action needs a name.") }
        return t
    }

    private static func requireFreeActionName(_ name: String, in list: [ProfileAction], except id: UUID?) throws {
        if list.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ServiceError.conflict("An action named \"\(name)\" already exists in this profile.")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .valueNotFound(_, let c), .typeMismatch(_, let c):
            context = c
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: " > ")
        return path.isEmpty ? context.debugDescription : "\(context.debugDescription) (at \(path))"
    }

    private static func validateStep(_ step: ActionStep) throws {
        if case .delay(let seconds) = step {
            guard seconds.isFinite, seconds >= 0 else { throw ServiceError.invalid("the delay must be 0 seconds or more.") }
        } else {
            guard step.timeout.isFinite, step.timeout >= 0 else { throw ServiceError.invalid("the timeout must be 0 seconds or more.") }
        }
        switch step {
        case .launchApp(let bundleID):
            try requireText(bundleID, "bundle id")
        case .press(let locator, _, let skip):
            try validateLocator(locator)
            if let skip { try validateLocator(skip) }
        case .waitFor(let locator, _, _):
            try validateLocator(locator)
        case .menu(let bundleID, let path):
            try requireText(bundleID, "bundle id")
            guard !path.isEmpty else { throw ServiceError.invalid("the menu path is empty.") }
            for title in path { try requireText(title, "menu title") }
        case .typeText(_, let into):
            if let into { try validateLocator(into) }
        case .key(let combo):
            guard KeyCombo.parse(combo) != nil else {
                throw ServiceError.invalid("\"\(combo)\" is not a key combination such as cmd+t.")
            }
        case .shell(let command, _, _):
            try requireText(command, "command")
        case .openURL(let url):
            try requireText(url, "URL")
            guard URL(string: url) != nil else { throw ServiceError.invalid("\"\(url)\" is not a URL.") }
        case .runShortcut(let name):
            try requireText(name, "shortcut name")
        case .terminalCommand(let command, let app, _):
            try requireText(command, "command")
            guard TerminalApp.isTerminal(app) else { throw ServiceError.invalid("\(app) is not Terminal or iTerm2.") }
        case .delay:
            break
        case .optional:
            break   // validateSteps checks the unwrapped step
        }
    }

    private static func validateLocator(_ locator: ElementLocator) throws {
        try requireText(locator.bundleID, "bundle id")
        guard !locator.path.isEmpty else { throw ServiceError.invalid("the element path is empty.") }
        for matcher in locator.path {
            if let index = matcher.index, index < 0 { throw ServiceError.invalid("the element index must be 0 or more.") }
        }
    }

    private static func requireText(_ value: String, _ what: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.invalid("the \(what) is empty.")
        }
    }
}
