import Foundation

/// Picks the screen named by `WM_UX_DISPLAY`. Pure, so it is testable without real displays.
public enum UXScreenChoice {
    public struct Screen: Equatable, Sendable {
        public var name: String
        public var area: Double
        public init(name: String, area: Double) { self.name = name; self.area = area }
    }

    /// Index into `screens` for: a 1-based number, "secondary" (first after the menu bar screen), "largest",
    /// or a screen name (case-insensitive, exact match first, then contains). Nil when nothing matches.
    public static func pick(_ value: String, screens: [Screen]) -> Int? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !v.isEmpty else { return nil }
        switch v {
        case "secondary": return screens.count > 1 ? 1 : nil
        case "largest": return screens.indices.max { screens[$0].area < screens[$1].area }
        default:
            if let n = Int(v) { return n >= 1 && n <= screens.count ? n - 1 : nil }
            return screens.firstIndex { $0.name.lowercased() == v }
                ?? screens.firstIndex { $0.name.lowercased().contains(v) }
        }
    }
}
