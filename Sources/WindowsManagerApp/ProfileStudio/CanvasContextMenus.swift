import AppKit
import SwiftUI
import WMCore

// Right-click menus of the map canvas. `controller` is nil in View mode, which gets only the read-only items.

/// A window tile.
struct WindowTileMenu: View {
    @ObservedObject var map: ProfileMapModel
    let windowID: UUID
    var controller: BuilderCanvasController?

    var body: some View {
        let window = map.window(windowID)
        Button("Select") { select() }
            .help("Select this window; the inspector shows it")
        Button("Zoom to Window") { select(); map.zoomToSelection() }
            .help("Zoom the map to this window")
        if let controller, let window {
            Divider()
            Button(window.isFullScreen ? "Leave Full Screen" : "Make Full Screen") { controller.toggleFullScreen(window) }
                .help("Save this window as full screen in its own Space, or back on a Desktop")
            Button(window.isMinimized ? "Restore From Minimized" : "Save as Minimized") {
                controller.builder.setMinimized(!window.isMinimized, forWindow: windowID)
            }
            .help("Whether the profile restores this window minimized")
            Divider()
            Button("Bring to Front") { controller.builder.restack(windowID, toFront: true) }
                .help("Restore this window in front of the others")
            Button("Send to Back") { controller.builder.restack(windowID, toFront: false) }
                .help("Restore this window behind the others")
            Divider()
            Button("Remove from Profile", role: .destructive) { controller.builder.removeWindow(windowID) }
                .help("Remove this window from the profile")
        }
    }

    private func select() {
        if let controller {
            controller.select(windowID, display: map.layout.windows.first { $0.windowID == windowID }?.displayUUID)
        } else {
            map.selectWindow(windowID)
        }
    }
}

/// A monitor's frame or title.
struct MonitorMenu: View {
    @ObservedObject var map: ProfileMapModel
    let monitorID: String
    var controller: BuilderCanvasController?

    var body: some View {
        let name = map.monitorName(monitorID)
        Button("Focus This Monitor") { focus() }
            .help("Make \(name) the monitor the tools act on")
        if let controller {
            let count = map.index.spaces(onDisplay: monitorID).filter { $0.kind == .desktop }.count
            Button("Add Desktop to \(name)") { focus(); controller.builder.addDesktop(onDisplay: monitorID) }
                .disabled(count >= ProfileDraftEditor.maxDesktopsPerDisplay)
                .help("Add a Desktop to \(name)")
        }
        Button("Zoom to Monitor") { map.zoomToDisplay(monitorID) }
            .help("Fit \(name) in the view")
        Divider()
        Button("Restore Only This Monitor…") { map.onRestoreScope?(ProfileMapModel.restoreScope(display: monitorID)) }
            .disabled(map.onRestoreScope == nil)
            .help("Preview restoring only \(name)")
    }

    private func focus() {
        if let controller { controller.focusMonitor(monitorID) } else { map.focusDisplay(monitorID) }
    }
}

/// A Desktop chip (D1, D2...). Edit mode adds its own move / delete items after these.
struct DesktopRestoreMenu: View {
    @ObservedObject var map: ProfileMapModel
    let space: ProfileSpaceIndex.Space

    var body: some View {
        let scope = ProfileMapModel.restoreScope(of: space)
        Button("Restore Only This Desktop…") { if let scope { map.onRestoreScope?(scope) } }
            .disabled(scope == nil || map.onRestoreScope == nil)
            .help(scope == nil ? "A full-screen Space is not a Desktop" : "Preview restoring only \(map.spaceName(space))")
    }
}

/// Empty canvas.
struct CanvasBackgroundMenu: View {
    @ObservedObject var map: ProfileMapModel
    var controller: BuilderCanvasController?

    var body: some View {
        Button("Fit Map") { map.fit() }.help("Fit every monitor in the window")
        Button("Actual Size") { map.actualSize() }.help("Show the map at 100%")
        if let controller {
            let name = map.activeDisplayUUID.map { map.monitorName($0) } ?? "the focused monitor"
            Button("Add App…") { controller.addAppFromPanel() }
                .help("Choose an app and add a window for it to \(name)")
        }
        Divider()
        Button(map.showsLegend ? "Hide Legend" : "Show Legend") { map.showsLegend.toggle() }
    }
}

extension BuilderCanvasController {
    /// Focuses a monitor on the map and in the builder (so the inspector and tools follow).
    func focusMonitor(_ id: String) {
        map.focusDisplay(id)
        builder.selectedDisplayUUID = id
        if map.selectedWindowID == nil { builder.selectedWindowID = nil }
        if let shown = map.shownSpace(onDisplay: id), shown.kind == .desktop, let n = shown.desktopNumber {
            builder.selectedDesktop = n
        }
    }

    /// Open panel for an `.app`, then a planned window on the focused monitor's Desktop.
    func addAppFromPanel() {
        guard let display = map.activeDisplayUUID, let number = desktopNumber(onDisplay: display) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose an app to add to \(map.monitorName(display))"
        guard panel.runModal() == .OK, let url = panel.url, let entry = builder.addAppBundle(at: url) else { return }
        builder.addWindow(app: builder.appRef(for: entry), onDisplay: display, desktop: number)
    }
}
