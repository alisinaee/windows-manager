import Foundation

/// One-line human description of an `ActionStep` for the Studio's step rows: an SF Symbol and a short summary.
public enum StepSummary {
    public static func of(_ step: ActionStep) -> (symbol: String, summary: String) {
        switch step.unwrapped {
        case .launchApp(let b): return ("app.badge", "Open \(appName(b))")
        case .press(let l, _, _): return ("cursorarrow.click", "Press · " + element(l))
        case .menu(let b, let p):
            return ("filemenu.and.selection", "Menu · " + ([appName(b)] + p.filter { !$0.isEmpty }).joined(separator: " › "))
        case .typeText(let t, _): return ("character.cursor.ibeam", "Type · " + (t.isEmpty ? "(empty)" : clip(t)))
        case .key(let k): return ("keyboard", "Keys · \(k)")
        case .shell(let c, _, _): return ("terminal", "Run · " + (c.isEmpty ? "(empty)" : clip(c)))
        case .terminalCommand(let c, let app, _):
            return ("terminal", "Run in \(TerminalApp.displayName(app)) · " + (c.isEmpty ? "(empty)" : clip(c)))
        case .openURL(let u): return ("link", "Open · " + clip(u))
        case .runShortcut(let n): return ("square.stack.3d.up", "Shortcut · " + (n.isEmpty ? "(none)" : n))
        case .waitFor(let l, let c, _):
            return ("hourglass", "Wait for · " + element(l) + (c.map { $0.isEmpty ? "" : " = \(clip($0))" } ?? ""))
        case .delay(let s): return ("timer", "Wait \(seconds(s))")
        case .optional: return ("questionmark.circle", "Step")
        }
    }

    /// "1.5 s", "2 s".
    public static func seconds(_ s: TimeInterval) -> String {
        let text = s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
        return text + " s"
    }

    private static func clip(_ text: String, _ limit: Int = 60) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > limit ? String(one.prefix(limit)) + "…" : one
    }

    /// "com.google.Chrome" -> "Chrome".
    static func appName(_ bundleID: String) -> String {
        if bundleID.isEmpty { return "app" }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    private static func element(_ l: ElementLocator) -> String {
        let label = l.path.last.flatMap { m in
            [m.title, m.description, m.identifier].compactMap { $0 }.first { !$0.isEmpty } ?? (m.role.isEmpty ? nil : m.role)
        }
        return [l.bundleID.isEmpty ? nil : appName(l.bundleID), label.map { clip($0, 40) }].compactMap { $0 }.joined(separator: " › ")
    }
}
