import CoreGraphics
import Foundation

// Builder validation of a profile draft (plan B2 step 7). Errors block saving; warnings never do.

public struct DraftCheckIssue: Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable { case error, warning }
    public enum Code: String, Hashable, Sendable {
        case inconsistent, tooManyDesktops, emptyDesktop, windowOnMissingDesktop, fullScreenWithoutOwner
        case duplicateWindow, windowOutsideMonitor, fullScreenAlsoNormalWindow, missingMonitor
        case severalPlannedWindows
    }

    public var severity: Severity
    public var code: Code
    /// A sentence for people.
    public var message: String
    public var windowID: UUID?
    public var displayUUID: String?
    public var desktopNumber: Int?
}

public enum ProfileDraftCheck {
    /// Tolerance (fraction of the monitor) before a window counts as sticking out.
    public static let outsideTolerance: CGFloat = 0.02

    /// Everything worth telling the user about `profile`. `connectedDisplays` (when known) enables the
    /// missing-monitor warning.
    public static func check(_ profile: Profile, connectedDisplays: [DisplayIdentity]? = nil) -> [DraftCheckIssue] {
        var issues: [DraftCheckIssue] = []
        func add(_ severity: DraftCheckIssue.Severity, _ code: DraftCheckIssue.Code, _ message: String,
                 window: UUID? = nil, display: String? = nil, desktop: Int? = nil) {
            issues.append(DraftCheckIssue(severity: severity, code: code, message: message, windowID: window,
                                          displayUUID: display, desktopNumber: desktop))
        }
        func name(_ uuid: String) -> String { profile.displays.first { $0.uuid == uuid }?.name ?? uuid }

        for problem in profile.validate() { add(.error, .inconsistent, problem) }

        let fullScreenOwners = Set(profile.spaces.flatMap(\.fullScreenWindowIDs))

        for display in profile.displays {
            let spaces = profile.spaces(onDisplay: display.uuid)
            let desktops = spaces.filter { $0.kind == .desktop }
            if desktops.count > ProfileDraftEditor.maxDesktopsPerDisplay {
                add(.error, .tooManyDesktops,
                    "\(name(display.uuid)) has \(desktops.count) Desktops; the most is \(ProfileDraftEditor.maxDesktopsPerDisplay).",
                    display: display.uuid)
            }
            for space in desktops {
                guard let number = space.desktopNumber else { continue }
                let has = profile.windows.contains {
                    $0.displayUUID == display.uuid && $0.placement == .desktop(number: number)
                }
                if !has {
                    add(.warning, .emptyDesktop, "Desktop \(number) on \(name(display.uuid)) is empty.",
                        display: display.uuid, desktop: number)
                }
            }
            for space in spaces where space.kind == .fullScreen && space.fullScreenWindowIDs.isEmpty {
                add(.error, .fullScreenWithoutOwner,
                    "The full-screen Space at position \(space.position + 1) on \(name(display.uuid)) has no app.",
                    display: display.uuid)
            }
            if let connected = connectedDisplays, !connected.contains(where: { $0.uuid == display.uuid }) {
                add(.warning, .missingMonitor,
                    "\(name(display.uuid)) is not connected; its windows are placed on another monitor.",
                    display: display.uuid)
            }
        }

        for w in profile.windows {
            if case .desktop(let n) = w.placement,
               !profile.spaces.contains(where: { $0.displayUUID == w.displayUUID && $0.kind == .desktop && $0.desktopNumber == n }) {
                add(.error, .windowOnMissingDesktop,
                    "\(w.app.name) is on Desktop \(n) of \(name(w.displayUUID)), which does not exist.",
                    window: w.id, display: w.displayUUID, desktop: n)
            }
            if !w.isFullScreen && !w.isMinimized {
                let r = w.relativeFrame, t = outsideTolerance
                if r.minX < -t || r.minY < -t || r.maxX > 1 + t || r.maxY > 1 + t {
                    add(.warning, .windowOutsideMonitor,
                        "\(w.app.name) sticks out of \(name(w.displayUUID)).", window: w.id, display: w.displayUUID)
                }
            }
            if fullScreenOwners.contains(w.id) {
                let others = profile.windows.filter {
                    $0.id != w.id && Profile.isSameApp($0.app, w.app) && !$0.isFullScreen
                        && !fullScreenOwners.contains($0.id)
                }
                if !others.isEmpty {
                    add(.warning, .fullScreenAlsoNormalWindow,
                        "\(w.app.name) is full screen and also has a normal window; one app window cannot be both.",
                        window: w.id, display: w.displayUUID)
                }
            }
        }

        // The same app twice on one Desktop at the same frame: the second one hides the first.
        var seen: [String: UUID] = [:]
        for w in profile.windows where !w.isFullScreen {
            guard case .desktop(let n) = w.placement else { continue }
            let key = "\(w.displayUUID)|\(n)|\(w.app.bundleID?.lowercased() ?? "name:" + w.app.name.lowercased())|"
                + "\(Int((w.relativeFrame.minX * 1000).rounded())),\(Int((w.relativeFrame.minY * 1000).rounded())),"
                + "\(Int((w.relativeFrame.width * 1000).rounded())),\(Int((w.relativeFrame.height * 1000).rounded()))"
            if seen[key] != nil {
                add(.warning, .duplicateWindow,
                    "\(w.app.name) is placed twice at the same spot on Desktop \(n) of \(name(w.displayUUID)).",
                    window: w.id, display: w.displayUUID, desktop: n)
            } else {
                seen[key] = w.id
            }
        }

        // An app usually opens one window when it launches, so more planned windows are placed only if they exist.
        for app in profile.apps {
            let planned = profile.windows(for: app).filter { $0.origin == .planned && $0.restore }
            if planned.count > 1 {
                add(.warning, .severalPlannedWindows,
                    "\(app.name) is planned with \(planned.count) windows; an app usually opens 1 window when launched, the other \(planned.count - 1) are placed only if they already exist.")
            }
        }
        return issues
    }

    public static func errors(_ issues: [DraftCheckIssue]) -> [DraftCheckIssue] { issues.filter { $0.severity == .error } }
    public static func warnings(_ issues: [DraftCheckIssue]) -> [DraftCheckIssue] { issues.filter { $0.severity == .warning } }
    /// True when saving must be blocked.
    public static func blocksSaving(_ issues: [DraftCheckIssue]) -> Bool { issues.contains { $0.severity == .error } }
}
