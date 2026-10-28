import Foundation
import KeyboardShortcuts
import WMCore

/// Fixed hotkey names. Profile hotkeys are dynamic (`profile.<id>`) and live in HotkeyController.
extension KeyboardShortcuts.Name {
    static let nextWorkspace = Self("workspace.next")
    static let previousWorkspace = Self("workspace.previous")

    /// Switch to workspace 1...9 (index 0...8).
    static let workspaceIndexed: [KeyboardShortcuts.Name] = (1...9).map { Self("workspace.\($0)") }
    /// Snap the frontmost window to zone 1...9 (index 0...8) of the layout for its display.
    static let snapZones: [KeyboardShortcuts.Name] = (1...9).map { Self("snap.zone.\($0)") }

    /// Cycle the frontmost window through half, two-thirds and one-third on one side (or centred).
    static func windowSize(_ direction: WindowSizeDirection) -> Self { Self("window.size.\(direction.rawValue)") }
    static let moveToNextDisplay = Self("display.move.next")
    static let moveToPreviousDisplay = Self("display.move.previous")

    static func profile(_ id: UUID) -> Self { Self("profile.\(id.uuidString)") }
}
