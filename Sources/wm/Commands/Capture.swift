import Foundation
import WMCore

func registerCaptureCommands(_ r: Registry) {
    r.register(Command(["capture"], summary: "Capture the current workspace into a new profile",
                       options: [CLIOption("name", short: "n", "Profile name", takesValue: true, valueName: "name"),
                                 CLIOption("select", short: "s",
                                           "Keep only matching windows: app:<name|bundle id>, desktop:<N>, fullscreen, minimized (repeatable)",
                                           takesValue: true, valueName: "selector")]) { args, _ in
        guard let name = args.value("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw CLIFailure.usage("--name is required", hint: "wm capture --name Work")
        }
        let store = ProfileStore()
        if store.list().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw CLIFailure.usage("A profile named '\(name)' already exists", hint: "Pick another --name")
        }
        var (profile, warnings) = ProfileCapture.capture(name: name)
        let captured = profile.windows.count
        let selectors = args.values("select")
        if !selectors.isEmpty {
            let ids = CLICaptureFilter.windowIDs(in: profile, selectors: selectors)
            if ids.isEmpty {
                throw CLIFailure.usage("--select matched no captured window (\(captured) captured)",
                                       hint: "Use app:<name>, desktop:<N>, fullscreen or minimized")
            }
            var selection = CaptureSelection(tree: CaptureSelectionTree(profile: profile))
            selection.selectNone()
            for id in ids { selection.toggle(window: id) }
            profile = selection.applying(to: profile)
        }
        if !AXPermission.isTrusted() {
            warnings.append("Accessibility is not granted: minimized state and document paths may be missing")
        }
        do { profile = try store.save(profile) }
        catch { throw CLIFailure(.runtime, code: "save_failed", message: "\(error.localizedDescription)") }
        let result = CLICaptureResult(profile: profile, capturedWindowCount: captured, warnings: warnings)
        return CLIResult(data: try JSONValue.from(result),
                         text: "Saved profile \"\(profile.name)\" (\(profile.id.uuidString)) with \(result.windowCount) window(s)")
    })
}
