import Foundation

// Pure selection rules for the layout editor's zones: a plain tap selects one zone, Shift or Command
// toggles a zone in the set. No UI and no store here, so the rules are testable on their own.

public enum ZoneSelection {
    /// The new selection after a zone is tapped. A plain tap replaces the selection with that zone. With
    /// `extend` (Shift or Command) the zone is added when it is missing and removed when it is already there.
    public static func afterTap(_ current: Set<UUID>, tapped: UUID, extend: Bool) -> Set<UUID> {
        guard extend else { return [tapped] }
        var next = current
        if !next.insert(tapped).inserted { next.remove(tapped) }
        return next
    }

    /// The zone that single-zone actions (split, delete, remove) use. It is the only selected zone when there
    /// is one, else the tapped zone when that is still selected, else nil.
    public static func primary(in selection: Set<UUID>, tapped: UUID?) -> UUID? {
        if selection.count == 1 { return selection.first }
        if let tapped, selection.contains(tapped) { return tapped }
        return nil
    }
}
