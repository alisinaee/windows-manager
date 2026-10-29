import Foundation

/// Collapsed or expanded profile sidebar of the Studio (P6.49). Pure value logic; the app stores `isVisible`.
/// The user's choice (`isVisible`) wins; a narrow window collapses the sidebar unless the user opened it on purpose.
public struct StudioSidebarState: Equatable, Sendable {
    public static let narrowWidth: Double = 760

    /// The remembered choice (expanded by default).
    public private(set) var isVisible: Bool
    /// The window content is narrower than `narrowWidth`.
    public private(set) var isNarrow = false
    private var userForcedOpen = false

    public init(isVisible: Bool = true) { self.isVisible = isVisible }

    /// True when the full sidebar shows; false when only the icon rail shows.
    public var isShown: Bool { isVisible && (!isNarrow || userForcedOpen) }

    public mutating func toggle() {
        if isShown {
            isVisible = false
            userForcedOpen = false
        } else {
            isVisible = true
            userForcedOpen = true   // explicit: do not fight it when the window is narrow
        }
    }

    /// Sets the choice directly (UX hook, restore). Expanding counts as explicit.
    public mutating func set(shown: Bool) {
        if shown != isShown { toggle() }
    }

    public mutating func contentWidthChanged(_ width: Double) {
        let narrow = width < Self.narrowWidth
        guard narrow != isNarrow else { return }
        isNarrow = narrow
        if !narrow { userForcedOpen = false }
    }
}
