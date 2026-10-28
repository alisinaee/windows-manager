import CoreGraphics
import Foundation

// Headless profile editing (P6.88). Everything the Profile Studio does to a profile, as UI-free calls on a
// `ProfileStore`. Every mutating call loads the profile, edits it through `ProfileDraftEditor` (so the result
// stays consistent), saves it and returns the stored `Profile`; failures are `ServiceError`.
// Profiles are addressed by a "ref": a UUID or a name (case-insensitive, unique).

public struct ProfileService {
    public let store: ProfileStore

    public init(store: ProfileStore = ProfileStore()) {
        self.store = store
    }

    // MARK: Lookup

    public func list() -> [ProfileSummary] { store.list() }

    /// Finds a profile id by UUID text or by name. Several profiles with the same name is a conflict.
    public func resolve(_ ref: String) throws -> UUID {
        let text = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text), store.list().contains(where: { $0.id == id }) { return id }
        let matches = store.list().filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
        switch matches.count {
        case 0: throw ServiceError.notFound("No profile named or with id \"\(text)\".")
        case 1: return matches[0].id
        default: throw ServiceError.conflict("\(matches.count) profiles are named \"\(text)\"; use the id.")
        }
    }

    public func show(_ ref: String) throws -> Profile {
        try load(try resolve(ref))
    }

    // MARK: Create, copy, rename, delete

    /// A new profile with one empty Desktop per display (`displays` may be empty).
    public func createBlank(name: String, displays: [DisplayIdentity] = [], icon: String? = nil) throws -> Profile {
        let trimmed = try cleanName(name)
        try requireFreeName(trimmed, except: nil)
        var profile = DraftSession.blankProfile(name: trimmed, displays: displays)
        if let icon { profile.icon = try cleanIcon(icon) }
        return try save(profile)
    }

    /// Saves a copy under a new id (no shortcut). Default name is "<name> copy", made unique.
    public func copy(_ ref: String, name: String? = nil) throws -> Profile {
        let id = try resolve(ref)
        let source = try load(id)
        let names = store.list().map(\.name)
        let newName: String
        if let name {
            newName = try cleanName(name)
            try requireFreeName(newName, except: nil)
        } else {
            newName = ProfileTransfer.uniqueName("\(source.name) copy", among: names)
        }
        return try wrap { try store.duplicate(id, name: newName) }
    }

    public func rename(_ ref: String, to name: String) throws -> Profile {
        let id = try resolve(ref)
        let trimmed = try cleanName(name)
        try requireFreeName(trimmed, except: id)
        return try wrap { try store.rename(id, to: trimmed) }
    }

    /// Moves the profile to the store's Trash. Returns the deleted profile.
    @discardableResult
    public func delete(_ ref: String) throws -> Profile {
        let id = try resolve(ref)
        let profile = try load(id)
        try wrap { _ = try store.delete(id) }
        return profile
    }

    // MARK: Icon, shortcut, options, notes

    /// The curated icons the Studio offers (SF Symbol names), default first.
    public static let iconChoices: [String] = [
        Profile.defaultIcon,
        "house", "briefcase", "laptopcomputer", "desktopcomputer", "gamecontroller", "music.note", "paintbrush",
        "hammer", "wrench.and.screwdriver", "book", "graduationcap", "film", "camera", "photo", "cart", "cup.and.saucer",
        "fork.knife", "moon", "bolt", "star", "heart", "leaf", "pawprint", "globe", "airplane", "car", "bicycle",
        "figure.run", "sportscourt", "building.2", "envelope", "phone", "message", "calendar", "clock", "folder",
        "terminal", "chart.bar", "doc.text", "tv",
    ]

    /// Sets the icon. Any non-empty SF Symbol name is accepted; `nil` or "" restores the default.
    public func setIcon(_ ref: String, icon: String?) throws -> Profile {
        let value = try icon.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try cleanIcon($0) }
        return try mutate(ref) { $0.icon = value ?? Profile.defaultIcon }
    }

    /// Sets the run shortcut, written like "ctrl+opt+cmd+1" (modifiers ctrl/opt/shift/cmd, then a digit 1-9).
    /// Throws `.conflict` when another profile uses it or it is a well-known system shortcut.
    public func setShortcut(_ ref: String, shortcut: String) throws -> Profile {
        let combo = try Self.parseShortcut(shortcut)
        if let warning = ShortcutAdvice.warning(for: combo) { throw ServiceError.conflict(warning) }
        let id = try resolve(ref)
        for summary in store.list() where summary.id != id {
            if let other = try? load(summary.id).options.hotkey, let c = try? Self.parseShortcut(other), c == combo {
                throw ServiceError.conflict("Already used by profile \(summary.name).")
            }
        }
        return try mutate(ref) { $0.options.hotkey = Self.formatShortcut(combo) }
    }

    public func clearShortcut(_ ref: String) throws -> Profile {
        try mutate(ref) { $0.options.hotkey = nil }
    }

    /// Combos the Studio suggests (hyper first, then light), each with the owner when another profile has it.
    public func shortcutSuggestions(for ref: String) throws -> [(shortcut: String, takenBy: String?)] {
        let id = try resolve(ref)
        var taken: [ShortcutCombo: String] = [:]
        for summary in store.list() where summary.id != id {
            if let h = try? load(summary.id).options.hotkey, let c = try? Self.parseShortcut(h) { taken[c] = summary.name }
        }
        return (ShortcutAdvice.hyperSuggestions + ShortcutAdvice.lightSuggestions).map {
            (Self.formatShortcut($0), taken[$0])
        }
    }

    public static func parseShortcut(_ text: String) throws -> ShortcutCombo {
        var mods: ShortcutModifiers = []
        var key: Int?
        for raw in text.lowercased().split(whereSeparator: { "+- ".contains($0) }) {
            switch raw {
            case "ctrl", "control": mods.insert(.control)
            case "opt", "option", "alt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "cmd", "command": mods.insert(.command)
            default:
                guard key == nil, raw.count == 1, let d = Int(raw), (1...9).contains(d) else {
                    throw ServiceError.invalid("Shortcut \"\(text)\" is not valid. Use modifiers (ctrl, opt, shift, cmd) and a digit 1-9, for example ctrl+opt+cmd+1.")
                }
                key = ShortcutAdvice.digitKeyCodes[d - 1]
            }
        }
        guard let key, !mods.isEmpty else {
            throw ServiceError.invalid("Shortcut \"\(text)\" needs at least one modifier and a digit 1-9, for example ctrl+opt+cmd+1.")
        }
        return ShortcutCombo(keyCode: key, modifiers: mods)
    }

    public static func formatShortcut(_ combo: ShortcutCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.control) { parts.append("ctrl") }
        if combo.modifiers.contains(.option) { parts.append("opt") }
        if combo.modifiers.contains(.shift) { parts.append("shift") }
        if combo.modifiers.contains(.command) { parts.append("cmd") }
        parts.append(ShortcutAdvice.digit(forKeyCode: combo.keyCode).map(String.init) ?? "?")
        return parts.joined(separator: "+")
    }

    /// Changes profile options (the switches of the Studio Options panel).
    public func setOptions(_ ref: String, _ change: (inout ProfileOptions) -> Void) throws -> Profile {
        try edit(ref) { try $0.setOptions { o in
            let hotkey = o.hotkey
            change(&o)
            o.hotkey = hotkey   // the shortcut has its own call with a conflict check
        } }
    }

    public func setNotes(_ ref: String, notes: String?) throws -> Profile {
        try mutate(ref) { $0.notes = (notes?.isEmpty == true) ? nil : notes }
    }

    // MARK: Desktops

    public func addDesktop(_ ref: String, display: String, atNumber: Int? = nil) throws -> (profile: Profile, number: Int) {
        var number = 0
        let p = try edit(ref) { number = try $0.addDesktop(onDisplay: display, atNumber: atNumber) }
        return (p, number)
    }

    public func removeDesktop(_ ref: String, display: String, number: Int, moveWindowsTo: Int? = nil) throws -> Profile {
        try edit(ref) { try $0.deleteDesktop(onDisplay: display, number: number, moveWindowsTo: moveWindowsTo) }
    }

    // MARK: Windows and apps

    /// Adds a planned window for an app on a Desktop. `frame` is global points, `relativeFrame` fractions of the
    /// visible frame; with neither it is centered 50% x 70%. Returns the profile and the new window id.
    public func addWindow(_ ref: String, app: AppRef, display: String, desktop: Int = 1,
                          frame: CGRect? = nil, relativeFrame: CGRect? = nil,
                          zoneName: String? = nil) throws -> (profile: Profile, windowID: UUID) {
        guard !app.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ServiceError.invalid("The app needs a name.") }
        var windowID = UUID()
        let p = try edit(ref) {
            windowID = try $0.addPlannedWindow(app: app, onDisplay: display, desktop: desktop, frame: frame,
                                               relativeFrame: relativeFrame, zoneName: zoneName)
        }
        return (p, windowID)
    }

    public func removeWindow(_ ref: String, window: UUID) throws -> Profile {
        try edit(ref) { try $0.removeWindow(window) }
    }

    /// Removes every window of an app (matched by bundle id, else name) and its launch-order entry.
    public func removeApp(_ ref: String, app query: String) throws -> Profile {
        let current = try show(ref)
        let q = query.lowercased()
        let ids = current.windows.filter {
            $0.app.bundleID?.lowercased() == q || $0.app.name.lowercased() == q
        }.map(\.id)
        let launchOnly = current.launchPlan?.items.contains { $0.id == q || $0.app.name.lowercased() == q } ?? false
        guard !ids.isEmpty || launchOnly else { throw ServiceError.notFound("The profile has no app \"\(query)\".") }
        return try edit(ref) { editor in
            for id in ids { try editor.removeWindow(id) }
            if var plan = editor.profile.launchPlan {
                plan.items.removeAll { $0.id == q || $0.app.name.lowercased() == q }
                try editor.setLaunchPlan(plan)
            }
        }
    }

    public func moveWindow(_ ref: String, window: UUID, display: String, desktop: Int) throws -> Profile {
        try edit(ref) { try $0.moveWindow(window, toDisplay: display, desktop: desktop) }
    }

    public func setRestore(_ ref: String, window: UUID, restore: Bool) throws -> Profile {
        try edit(ref) { try $0.setRestore(restore, forWindow: window) }
    }

    /// Sets a window's global frame (points).
    public func setWindowFrame(_ ref: String, window: UUID, frame: CGRect) throws -> Profile {
        guard frame.width > 0, frame.height > 0, frame.width.isFinite, frame.height.isFinite else {
            throw ServiceError.invalid("A window frame needs a positive width and height.")
        }
        return try edit(ref) { try $0.setFrame(ofWindow: window, frame: frame) }
    }

    /// Sets a window's frame as fractions (0...1) of its monitor's visible frame.
    public func setWindowRelativeFrame(_ ref: String, window: UUID, relativeFrame: CGRect) throws -> Profile {
        guard relativeFrame.width > 0, relativeFrame.height > 0 else {
            throw ServiceError.invalid("A relative frame needs a positive width and height.")
        }
        return try edit(ref) { try $0.setRelativeFrame(ofWindow: window, relativeFrame: relativeFrame) }
    }

    /// Puts a window into a layout zone (fractions of the monitor, as `Layout` zones are).
    public func applyZone(_ ref: String, window: UUID, zone: NormalizedRect, zoneName: String? = nil,
                          gap: CGFloat = 0) throws -> Profile {
        try edit(ref) { editor in
            let display = try Self.display(of: window, in: editor.profile)
            let frame = LayoutGeometry.frame(of: zone, in: Self.area(display), gap: gap)
            try editor.setFrame(ofWindow: window, frame: frame, zoneName: zoneName)
        }
    }

    /// Snaps a window's frame to the grid of its monitor (like the Studio grid overlay).
    public func applyGridSnap(_ ref: String, window: UUID, grid: GridSpec) throws -> Profile {
        try edit(ref) { editor in
            let (w, display) = try Self.windowAndDisplay(window, in: editor.profile)
            let snapped = GridSnap.snapMove(w.frame, spec: grid, in: Self.area(display))
            try editor.setFrame(ofWindow: window, frame: snapped, zoneName: w.zoneName)
        }
    }

    /// Snaps a window to the monitor edges and to the edges of the other windows on the same Desktop (magnet mode).
    public func applyMagnetSnap(_ ref: String, window: UUID, threshold: CGFloat = MagnetSnap.screenThreshold) throws -> Profile {
        try edit(ref) { editor in
            let (w, display) = try Self.windowAndDisplay(window, in: editor.profile)
            let others = Self.neighbours(of: w, in: editor.profile).map(\.frame)
            let result = MagnetSnap.snapMove(w.frame, monitor: Self.area(display), others: others, threshold: threshold)
            try editor.setFrame(ofWindow: window, frame: result.rect, zoneName: w.zoneName)
        }
    }

    /// The auto layout candidates for the windows of one Desktop, best first (names and frames by window id).
    public func autoLayoutCandidates(_ ref: String, display: String, desktop: Int,
                                     gap: CGFloat = AutoLayout.defaultGap) throws -> [AutoLayout.Candidate] {
        let p = try show(ref)
        let d = try Self.requireDisplay(display, in: p)
        let items = Self.desktopWindows(p, display: display, desktop: desktop).map {
            AutoLayout.Item(id: $0.id, bundleID: $0.app.bundleID)
        }
        return AutoLayout.candidates(items: items, visible: Self.area(d), gap: gap)
    }

    /// Applies candidate `index` (0 = best) of the auto layout to the windows of one Desktop.
    public func applyAutoLayout(_ ref: String, display: String, desktop: Int, candidate index: Int = 0,
                                gap: CGFloat = AutoLayout.defaultGap) throws -> Profile {
        let candidates = try autoLayoutCandidates(ref, display: display, desktop: desktop, gap: gap)
        guard !candidates.isEmpty else { throw ServiceError.invalid("Desktop \(desktop) has no windows to arrange.") }
        guard candidates.indices.contains(index) else {
            throw ServiceError.invalid("Candidate \(index) does not exist; choose 0...\(candidates.count - 1).")
        }
        let frames = candidates[index].frames
        return try edit(ref) { editor in
            for (id, frame) in frames { try editor.setFrame(ofWindow: id, frame: frame) }
        }
    }

    /// Resizes a window from `handle` to `proposed` and drags the tiles that share the moving edge along.
    public func resizeLinked(_ ref: String, window: UUID, handle: ResizeHandle, proposed: CGRect,
                             minSize: CGSize = CGSize(width: 120, height: 80)) throws -> Profile {
        try edit(ref) { editor in
            let (w, _) = try Self.windowAndDisplay(window, in: editor.profile)
            let others = Self.neighbours(of: w, in: editor.profile)
            let result = LinkedResize.apply(start: w.frame, proposed: proposed, handle: handle,
                                            neighbours: others.map { LinkedResize.Neighbour(id: $0.id, rect: $0.frame) },
                                            minSize: minSize)
            try editor.setFrame(ofWindow: window, frame: result.rect, zoneName: w.zoneName)
            for (id, rect) in result.neighbours {
                let zone = others.first { $0.id == id }?.zoneName
                try editor.setFrame(ofWindow: id, frame: rect, zoneName: zone)
            }
        }
    }

    // MARK: Export and import

    /// JSON bytes of the profile (the store's file format).
    public func exportData(_ ref: String) throws -> Data {
        try wrap { try ProfileTransfer.export(try show(ref)) }
    }

    /// Writes the profile JSON to `url`.
    public func export(_ ref: String, to url: URL) throws {
        let id = try resolve(ref)
        try wrap { try store.export(id, to: url) }
    }

    /// Imports JSON bytes as a new profile (new id, unique name, no shortcut).
    public func importData(_ data: Data, source: String = "The data") throws -> Profile {
        try wrap {
            let profile = try ProfileTransfer.importProfile(data, existingNames: store.list().map(\.name), source: source)
            return try store.save(profile)
        }
    }

    public func importFile(_ url: URL) throws -> Profile {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ServiceError.notFound("Cannot read \(url.path): \(error.localizedDescription)")
        }
        return try importData(data, source: url.lastPathComponent)
    }

    // MARK: Plumbing (shared with LaunchOrderService)

    func load(_ id: UUID) throws -> Profile { try wrap { try store.load(id) } }

    func save(_ profile: Profile) throws -> Profile { try wrap { try store.save(profile) } }

    /// Load, edit through the draft editor (consistency checked), save.
    @discardableResult
    func edit(_ ref: String, _ change: (inout ProfileDraftEditor) throws -> Void) throws -> Profile {
        var editor = ProfileDraftEditor(try show(ref))
        try wrap { try change(&editor) }
        return try save(editor.profile)
    }

    @discardableResult
    func mutate(_ ref: String, _ change: (inout Profile) throws -> Void) throws -> Profile {
        var profile = try show(ref)
        try wrap { try change(&profile) }
        return try save(profile)
    }

    @discardableResult
    func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw ServiceError.wrap(error) }
    }

    private func cleanName(_ name: String) throws -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ServiceError.invalid("A profile needs a name.") }
        return t
    }

    private func cleanIcon(_ icon: String) throws -> String {
        let t = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else {
            throw ServiceError.invalid("The icon must be an SF Symbol name such as \"briefcase\".")
        }
        return t
    }

    private func requireFreeName(_ name: String, except id: UUID?) throws {
        if store.list().contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ServiceError.conflict("A profile named \"\(name)\" already exists.")
        }
    }

    // MARK: Geometry helpers

    private static func area(_ d: DisplayIdentity) -> CGRect {
        d.visibleFrame.width > 0 && d.visibleFrame.height > 0 ? d.visibleFrame : d.frame
    }

    private static func requireDisplay(_ uuid: String, in p: Profile) throws -> DisplayIdentity {
        guard let d = p.displays.first(where: { $0.uuid == uuid }) else { throw ProfileDraftError.unknownDisplay(uuid) }
        return d
    }

    private static func windowAndDisplay(_ id: UUID, in p: Profile) throws -> (WindowSnapshot, DisplayIdentity) {
        guard let w = p.windows.first(where: { $0.id == id }) else { throw ProfileDraftError.unknownWindow(id) }
        return (w, try requireDisplay(w.displayUUID, in: p))
    }

    private static func display(of id: UUID, in p: Profile) throws -> DisplayIdentity {
        try windowAndDisplay(id, in: p).1
    }

    /// The other normal windows on the same monitor and Desktop.
    private static func neighbours(of w: WindowSnapshot, in p: Profile) -> [WindowSnapshot] {
        p.windows.filter { $0.id != w.id && $0.displayUUID == w.displayUUID && $0.placement == w.placement && !$0.isFullScreen }
    }

    private static func desktopWindows(_ p: Profile, display: String, desktop: Int) -> [WindowSnapshot] {
        p.windows.filter { $0.displayUUID == display && $0.placement == .desktop(number: desktop) && !$0.isFullScreen }
    }
}
