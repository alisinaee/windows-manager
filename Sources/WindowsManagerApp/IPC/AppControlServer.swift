import AppKit
import WMCore

/// Answers `wm` CLI requests over the control socket. Handlers run on the main actor.
final class AppControlServer {
    static let shared = AppControlServer()
    private var server: IPCServer?

    func start() {
        guard server == nil else { return }
        let s = IPCServer { request in
            // The connection thread blocks while the main thread does the work.
            DispatchQueue.main.sync { MainActor.assumeIsolated { AppControlServer.handle(request) } }
        }
        do { try s.start(); server = s }
        catch { AppInfo.logger.error("Control socket failed: \(error.localizedDescription)") }
    }

    func stop() { server?.stop(); server = nil }

    @MainActor
    private static func handle(_ req: IPCRequest) -> IPCResponse {
        guard let state = AppState.current else {
            return .failure(id: req.id, code: "not_ready", message: "The app is still starting")
        }
        switch req.command {
        case "status":
            return .success(id: req.id, .object([
                "appRunning": .bool(true),
                "version": .string(AppInfo.version),
                "build": .string(AppInfo.build),
                "accessibilityTrusted": .bool(AXPermission.isTrusted()),
                "debugMode": .bool(state.debugMode),
                "profileCount": .int(state.store.list().count),
            ]))
        case "profilesChanged":
            state.reloadProfiles()
            return .success(id: req.id, .object(["profileCount": .int(state.profiles.count)]))
        case "list":
            state.reloadProfiles()
            return .success(id: req.id, .array(state.savedProfiles.map {
                .object(["id": .string($0.id.uuidString), "name": .string($0.name), "windowCount": .int($0.windowCount)])
            }))
        case "run":
            guard case .string(let name)? = req.args["profile"] else {
                return .failure(id: req.id, code: "usage", message: "run needs args.profile")
            }
            switch ProfileResolver.resolve(name, in: state.savedProfiles) {
            case .found(let id):
                guard state.canAct else {
                    return .failure(id: req.id, code: "busy", message: "Accessibility is missing or another action is running")
                }
                state.run(id: id)
                return .success(id: req.id, .object(["started": .bool(true), "id": .string(id.uuidString)]))
            case .ambiguous:
                return .failure(id: req.id, code: "ambiguous", message: "Several profiles are named \(name)")
            case .none:
                return .failure(id: req.id, code: "not_found", message: "No profile named \(name)")
            }
        default:
            return .failure(id: req.id, code: "unknown_command", message: "Unknown command \(req.command)")
        }
    }
}
