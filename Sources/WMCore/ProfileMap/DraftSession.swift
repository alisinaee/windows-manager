import Foundation

// Pure state of one Builder session (plan B2): the draft and its undo history, the dirty flag, and the rule
// that decides whether the draft may be saved. The app's `ProfileBuilderModel` is a thin shell over this.

/// Why a draft cannot be saved right now.
public enum DraftSaveRefusal: Error, Equatable, LocalizedError {
    case emptyName
    /// Blocking problems (errors from `ProfileDraftCheck`).
    case blocked([DraftCheckIssue])

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the profile a name before saving."
        case .blocked(let issues):
            let first = issues.first?.message ?? "The profile has problems."
            return issues.count > 1 ? "\(first) (and \(issues.count - 1) more)" : first
        }
    }
}

public struct DraftSession {
    /// Undo cap from the plan (B2 "Undo").
    public static let historyCap = 200

    public private(set) var history: EditHistory<Profile>
    /// The last saved (or initial) value; the draft is dirty when it differs.
    public private(set) var baseline: Profile
    /// True until the first successful save: the draft has never been stored under its id.
    public private(set) var isNew: Bool

    public init(initial: Profile, isNew: Bool, cap: Int = DraftSession.historyCap,
                coalesceWindow: TimeInterval = EditHistory<Profile>.defaultCoalesceWindow,
                clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        history = EditHistory(initial: initial, cap: cap, coalesceWindow: coalesceWindow, clock: clock)
        baseline = initial
        self.isNew = isNew
    }

    public var profile: Profile { history.current }
    public var isDirty: Bool { history.current != baseline }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    /// Runs `body` on an editor holding the draft. When it succeeds and changes the profile, the result becomes
    /// the new draft with one undo entry (edits with the same `kind` in quick succession share an entry). When
    /// it throws, the draft is untouched and the error is rethrown.
    @discardableResult
    public mutating func edit<T>(kind: String? = nil, _ body: (inout ProfileDraftEditor) throws -> T) throws -> T {
        var editor = ProfileDraftEditor(history.current)
        let result = try body(&editor)
        if editor.profile != history.current { history.record(editor.profile, kind: kind) }
        return result
    }

    /// The icon is plain profile data that `ProfileDraftEditor` has no mutation for.
    public mutating func setIcon(_ icon: String) {
        guard icon != history.current.icon else { return }
        var p = history.current
        p.icon = icon
        history.record(p, kind: "icon")
    }

    @discardableResult public mutating func undo() -> Bool { history.undo() }
    @discardableResult public mutating func redo() -> Bool { history.redo() }

    /// Builder issues for the current draft: `ProfileDraftCheck` plus nothing else (launch issues are separate).
    public func issues(connectedDisplays: [DisplayIdentity]? = nil) -> [DraftCheckIssue] {
        ProfileDraftCheck.check(profile, connectedDisplays: connectedDisplays)
    }

    /// The profile to hand to `ProfileStore.save`: trimmed name made unique among `otherNames` (names of the
    /// other saved profiles, not this one). Throws when saving is blocked (empty name or any error issue).
    public func prepareSave(otherNames: [String], connectedDisplays: [DisplayIdentity]? = nil) throws -> Profile {
        var draft = profile
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftSaveRefusal.emptyName }
        let found = ProfileDraftCheck.check(draft, connectedDisplays: connectedDisplays)
        if ProfileDraftCheck.blocksSaving(found) { throw DraftSaveRefusal.blocked(ProfileDraftCheck.errors(found)) }
        draft.name = ProfileTransfer.uniqueName(trimmed, among: otherNames)
        return draft
    }

    /// After a successful save: `saved` is the stored value, history starts over and the draft is clean.
    public mutating func markSaved(_ saved: Profile) {
        history.reset(to: saved)
        baseline = saved
        isNew = false
    }

    // MARK: Starting points

    /// "Blank on these monitors": one empty Desktop per display, options for a built profile.
    public static func blankProfile(name: String = "New profile", displays: [DisplayIdentity],
                                    now: Date = Date(), id: UUID = UUID()) -> Profile {
        let spaces = displays.map { SpaceSnapshot(displayUUID: $0.uuid, position: 0, kind: .desktop, desktopNumber: 1) }
        return Profile(id: id, name: name, createdAt: now, monitorSetKey: DisplayMap.monitorSetKey(displays),
                       displays: displays, spaces: spaces, options: ProfileOptions(addMissingDesktops: true))
    }

    /// "Start from a copy of <profile>": a new profile (new id, fresh dates, no hotkey, a free name).
    public static func copyProfile(of source: Profile, existingNames: [String], now: Date = Date(),
                                   id: UUID = UUID()) -> Profile {
        var copy = source
        copy.id = id
        copy.name = ProfileTransfer.uniqueName("\(source.name) copy", among: existingNames)
        copy.createdAt = now
        copy.updatedAt = now
        copy.options.hotkey = nil
        return copy
    }

    /// A captured profile as a draft start: unique name, fresh id kept as captured.
    public static func capturedDraft(_ captured: Profile, existingNames: [String]) -> Profile {
        var draft = captured
        draft.name = ProfileTransfer.uniqueName(captured.name, among: existingNames)
        return draft
    }
}
