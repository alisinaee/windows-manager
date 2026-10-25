import ApplicationServices

/// Accessibility (AX) permission check for the process that hosts us (usually the terminal app).
public enum AXPermission {
    /// True when this process may use the Accessibility API. Never shows a dialog.
    public static func isTrusted() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Asks macOS to show its "grant Accessibility access" dialog (only if not trusted yet).
    public static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
