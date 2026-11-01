import Foundation

/// Which monitor the map tools act on: the focused one while it still exists, else the first.
public enum MonitorFocus {
    public static func resolve(focused: String?, ids: [String]) -> String? {
        if let focused, ids.contains(focused) { return focused }
        return ids.first
    }
}
