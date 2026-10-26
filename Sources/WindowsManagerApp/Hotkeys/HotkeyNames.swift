import Foundation
import KeyboardShortcuts

/// Fixed hotkey names. Profile hotkeys are dynamic (`profile.<id>`) and live in HotkeyController.
extension KeyboardShortcuts.Name {
    static let nextWorkspace = Self("workspace.next")
    static let previousWorkspace = Self("workspace.previous")

    /// Switch to workspace 1...9 (index 0...8).
    static let workspaceIndexed: [KeyboardShortcuts.Name] = (1...9).map { Self("workspace.\($0)") }
    /// Snap the frontmost window to zone 1...9 (index 0...8) of the layout for its display.
    static let snapZones: [KeyboardShortcuts.Name] = (1...9).map { Self("snap.zone.\($0)") }

    static func profile(_ id: UUID) -> Self { Self("profile.\(id.uuidString)") }
}
