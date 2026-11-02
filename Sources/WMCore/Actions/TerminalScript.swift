import Foundation

/// Builds the AppleScript that sends a command to Terminal or iTerm2.
public enum TerminalScript {
    /// Escapes text for use inside an AppleScript string literal.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// nil when `app` is neither Terminal nor iTerm2.
    public static func source(command: String, app: String, newWindow: Bool) -> String? {
        let c = escape(command)
        switch app {
        case TerminalApp.terminal:
            if newWindow {
                return """
                tell application id "com.apple.Terminal"
                    activate
                    do script "\(c)"
                end tell
                """
            }
            return """
            tell application id "com.apple.Terminal"
                activate
                if (count of windows) > 0 then
                    do script "\(c)" in front window
                else
                    do script "\(c)"
                end if
            end tell
            """
        case TerminalApp.iTerm:
            return """
            tell application id "com.googlecode.iterm2"
                activate
                if (count of windows) = 0 or \(newWindow ? "true" : "false") then
                    create window with default profile
                end if
                tell current session of current window to write text "\(c)"
            end tell
            """
        default:
            return nil
        }
    }

    /// What to tell the user when macOS refuses the Apple event (error -1743).
    public static func automationDeniedMessage(app: String) -> String {
        "Allow Windows Manager to control \(TerminalApp.displayName(app)) in System Settings > Privacy & Security > Automation"
    }
}
