import Foundation

// Rule CRUD for the CLI and tests (P6.89): auto-profile settings, Space pin rules and per-app window rules.
// Wraps the file stores in WMCore; nothing here touches windows.

public final class RuleService: @unchecked Sendable {
    private let autoStore: AutoProfileStore
    private let pinStore: PinRulesStore
    private let windowStore: WindowRulesStore

    public init(autoProfile: AutoProfileStore = AutoProfileStore(), pins: PinRulesStore = PinRulesStore(),
                windowRules: WindowRulesStore = WindowRulesStore()) {
        self.autoStore = autoProfile
        self.pinStore = pins
        self.windowStore = windowRules
    }

    // MARK: Auto profile

    public func autoProfile() -> AutoProfileSettings { autoStore.load() }

    @discardableResult
    public func updateAutoProfile(enabled: Bool? = nil, monitorChange: Bool? = nil, wake: Bool? = nil, unlock: Bool? = nil,
                                  delaySeconds: Double? = nil, cooldownSeconds: Double? = nil) throws -> AutoProfileSettings {
        var s = autoStore.load()
        for (name, v) in [("delay", delaySeconds), ("cooldown", cooldownSeconds)] {
            if let v, !(v.isFinite && v >= 0 && v <= 3600) { throw ServiceError.invalid("Auto profile \(name) must be 0-3600 seconds.") }
        }
        if let enabled { s.enabled = enabled }
        if let monitorChange { s.triggers.monitorChange = monitorChange }
        if let wake { s.triggers.wake = wake }
        if let unlock { s.triggers.unlock = unlock }
        if let delaySeconds { s.delaySeconds = delaySeconds }
        if let cooldownSeconds { s.cooldownSeconds = cooldownSeconds }
        try saveAuto(s)
        return s
    }

    /// Maps a monitor set key (`DisplayMap.monitorSetKey`) to a profile id.
    @discardableResult
    public func setAutoProfileMapping(monitorSetKey: String, profileID: UUID) throws -> AutoProfileSettings {
        let key = monitorSetKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ServiceError.invalid("Monitor set key is empty.") }
        var s = autoStore.load()
        s.mapping[key] = profileID
        try saveAuto(s)
        return s
    }

    @discardableResult
    public func removeAutoProfileMapping(monitorSetKey: String) throws -> AutoProfileSettings {
        var s = autoStore.load()
        guard s.mapping.removeValue(forKey: monitorSetKey) != nil else {
            throw ServiceError.notFound("No auto profile mapping for \"\(monitorSetKey)\".")
        }
        try saveAuto(s)
        return s
    }

    // MARK: Pin rules

    public func pins() -> [PinRule] { pinStore.load() }

    public func pin(_ id: UUID) throws -> PinRule {
        guard let r = pinStore.load().first(where: { $0.id == id }) else { throw ServiceError.notFound("No pin rule \(id.uuidString).") }
        return r
    }

    @discardableResult
    public func addPin(bundleID: String, titleContains: String? = nil, target: PinTarget) throws -> PinRule {
        let rule = try Self.cleanPin(PinRule(bundleID: bundleID, titleContains: titleContains, target: target))
        var all = pinStore.load()
        if all.contains(where: { Self.samePin($0, rule) }) { throw ServiceError.conflict("An identical pin rule already exists.") }
        all.append(rule)
        try savePins(all)
        return rule
    }

    @discardableResult
    public func updatePin(_ id: UUID, bundleID: String? = nil, titleContains: String?? = nil, target: PinTarget? = nil) throws -> PinRule {
        var all = pinStore.load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { throw ServiceError.notFound("No pin rule \(id.uuidString).") }
        var r = all[i]
        if let bundleID { r.bundleID = bundleID }
        if let titleContains { r.titleContains = titleContains }
        if let target { r.target = target }
        r = try Self.cleanPin(r)
        if all.contains(where: { $0.id != id && Self.samePin($0, r) }) { throw ServiceError.conflict("An identical pin rule already exists.") }
        all[i] = r
        try savePins(all)
        return r
    }

    public func removePin(_ id: UUID) throws {
        var all = pinStore.load()
        guard all.contains(where: { $0.id == id }) else { throw ServiceError.notFound("No pin rule \(id.uuidString).") }
        all.removeAll { $0.id == id }
        try savePins(all)
    }

    // MARK: Window rules

    public func windowRules() -> [WindowRule] { windowStore.load().rules }

    public func windowRule(bundleID: String) throws -> WindowRule {
        guard let r = windowStore.load().rule(for: bundleID) else { throw ServiceError.notFound("No window rule for \(bundleID).") }
        return r
    }

    /// Adds the rule or replaces the app's existing one.
    @discardableResult
    public func setWindowRule(bundleID: String, action: WindowRuleAction) throws -> WindowRule {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BundleIDValidation.looksLikeBundleID(id) else { throw ServiceError.invalid("\"\(bundleID)\" is not a bundle id.") }
        if case .pinToDisplay(let uuid) = action, uuid.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ServiceError.invalid("Display uuid is empty.")
        }
        var all = windowStore.load()
        all.set(WindowRule(bundleID: id, action: action))
        do { try windowStore.save(all) } catch { throw ServiceError.wrap(error) }
        return all.rule(for: id)!
    }

    public func removeWindowRule(bundleID: String) throws {
        var all = windowStore.load()
        guard all.rule(for: bundleID) != nil else { throw ServiceError.notFound("No window rule for \(bundleID).") }
        all.remove(bundleID: bundleID)
        do { try windowStore.save(all) } catch { throw ServiceError.wrap(error) }
    }

    // MARK: Internals

    private func saveAuto(_ s: AutoProfileSettings) throws {
        do { try autoStore.save(s) } catch { throw ServiceError.wrap(error) }
    }

    private func savePins(_ rules: [PinRule]) throws {
        do { try pinStore.save(rules) } catch { throw ServiceError.wrap(error) }
    }

    private static func samePin(_ a: PinRule, _ b: PinRule) -> Bool {
        a.bundleID.caseInsensitiveCompare(b.bundleID) == .orderedSame && a.titleContains == b.titleContains && a.target == b.target
    }

    private static func cleanPin(_ rule: PinRule) throws -> PinRule {
        var r = rule
        r.bundleID = r.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BundleIDValidation.looksLikeBundleID(r.bundleID) else { throw ServiceError.invalid("\"\(rule.bundleID)\" is not a bundle id.") }
        let title = r.titleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        r.titleContains = (title?.isEmpty ?? true) ? nil : title
        switch r.target {
        case .desktopIndex(let n, let uuid):
            guard n >= 1 else { throw ServiceError.invalid("Desktop number must be 1 or more.") }
            guard !uuid.trimmingCharacters(in: .whitespaces).isEmpty else { throw ServiceError.invalid("Display uuid is empty.") }
        case .spaceID:
            break
        }
        return r
    }
}
