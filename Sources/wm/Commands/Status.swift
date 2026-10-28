import Foundation
import WMCore

func registerStatusCommands(_ r: Registry) {
    r.register(Command(["status"], summary: "Show app and permission status (--via app|direct|auto)") { _, ctx in
        func viaApp() throws -> CLIResult? {
            do {
                let resp = try IPCClient(timeout: 3).send("status")
                guard resp.ok else {
                    throw CLIFailure(.runtime, code: resp.error?.code ?? "app_error", message: resp.error?.message ?? "app error")
                }
                var data = resp.data ?? .null
                if case .object(var o) = data { o["source"] = .string("app"); data = .object(o) }
                return CLIResult(data: data, text: render(data))
            } catch IPCError.notRunning {
                return nil
            } catch IPCError.timeout {
                throw CLIFailure(.runtime, code: "app_timeout", message: "The app did not answer in time")
            }
        }
        func direct() -> CLIResult {
            let count = ProfileStore().list().count
            let data = JSONValue.object([
                "source": .string("direct"),
                "appRunning": .bool(false),
                "accessibilityTrusted": .bool(AXPermission.isTrusted()),
                "profileCount": .int(count),
            ])
            return CLIResult(data: data, text: render(data))
        }
        switch ctx.via {
        case .direct: return direct()
        case .app:
            if let r = try viaApp() { return r }
            throw CLIFailure(.appNotRunning, code: "app_not_running", message: "Windows Manager is not running",
                             hint: "Open the app, or use --via direct")
        case .auto:
            return try viaApp() ?? direct()
        }
    })
}

private func render(_ v: JSONValue) -> String {
    guard case .object(let o) = v else { return "" }
    return o.keys.sorted().map { k in
        let s: String
        switch o[k]! {
        case .string(let x): s = x
        case .bool(let x): s = x ? "yes" : "no"
        case .int(let x): s = String(x)
        default: s = "-"
        }
        return "\(k): \(s)"
    }.joined(separator: "\n")
}
