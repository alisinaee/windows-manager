import SwiftUI
import WMCore

/// Right-hand inspector of the Profile Studio (View mode): details of the selected window, or of the Space the
/// focused monitor shows. Read only. With "Show what is missing now" on it also gives the live status, the
/// reason, and the planned steps for the selected window.
struct MapInspectorView: View {
    @ObservedObject var map: ProfileMapModel
    /// The plan behind the live status, when Compare is on and done.
    var plan: RestorePlan?
    var isCompareOn: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let id = map.selectedWindowID, let window = map.window(id) {
                    windowDetails(window)
                } else if let profile = map.profile, let space = focusedSpace(profile) {
                    spaceDetails(space, profile)
                } else {
                    Text("Select a window or a Desktop on the map to see its details.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func focusedSpace(_ profile: Profile) -> ProfileSpaceIndex.Space? {
        guard let uuid = map.focusedDisplayUUID ?? profile.displays.first?.uuid else { return nil }
        return map.shownSpace(onDisplay: uuid)
    }

    // MARK: Window

    @ViewBuilder private func windowDetails(_ window: WindowSnapshot) -> some View {
        let profile = map.profile
        let tile = map.layout.windows.first { $0.windowID == window.id }
        HStack(spacing: 10) {
            Image(nsImage: AppIconCache.icon(for: window.app))
                .resizable().frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.app.name).font(.headline)
                if let title = window.title, !title.isEmpty {
                    Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    Text("No title saved").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)

        if let stack = map.selectedStack { stackSection(stack, selected: window.id) }

        let live = map.status
        let status = live?.windows[window.id]
        let parked = live?.parked.contains(window.id) == true
        if status != nil || parked { statusBlock(status, parked: parked) }
        else if isCompareOn { Text("Comparing with your Mac…").font(.callout).foregroundStyle(.secondary) }

        let steps = (plan?.steps ?? []).filter { $0.target?.snapshotID == window.id && !isRaise($0) }
        if !steps.isEmpty || launchStep(for: window) != nil {
            section("Planned steps") {
                if let launch = launchStep(for: window) {
                    Text(RestoreStepText.text(launch)).font(.callout)
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text(RestoreStepText.text(step)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        section("Where") {
            row("Monitor", profile?.displays.first { $0.uuid == window.displayUUID }?.name ?? "Unknown monitor")
            row("Desktop", placementText(window.placement, tile: tile))
            if let zone = window.zoneName { row("Zone", zone) }
        }

        section("Size and position") {
            row("Relative", percentText(window.relativeFrame))
            row("Points", "\(RestoreStepText.size(window.frame)) at \(Int(window.frame.minX.rounded())), \(Int(window.frame.minY.rounded()))")
            if let phrase = ProfileMapModel.positionPhrase(for: window, tile: tile) { row("Looks like", phrase) }
        }

        section("State") {
            row("Full screen", window.isFullScreen ? "Yes" : "No")
            row("Minimized", window.isMinimized ? "Yes" : "No")
            row("Restored", window.restore ? "Yes" : "No, left out of a restore")
            row("Stacking", window.zIndex == 0 ? "Front" : "Number \(window.zIndex + 1) from the front")
            row("Title match", titleMatchText(window.titleMatch))
            if let doc = window.documentPath, !doc.isEmpty { row("Document", doc) }
            if window.origin == .planned { row("Origin", "Planned in the Builder") }
        }

        if let profile, let launch = launchOrderText(window.app, profile) {
            section("Launch order") { Text(launch).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// Every window of the selected stack; a click brings that window to the front of the stack.
    private func stackSection(_ stack: TileStacking.Stack, selected: UUID) -> some View {
        section("Overlapping windows (\(stack.count))") {
            ForEach(Array(map.orderedMembers(of: stack).enumerated()), id: \.element) { at, id in
                if let member = map.window(id) {
                    let isSelected = id == selected
                    Button { map.selectWindow(id) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: AppIconCache.icon(for: member.app)).resizable().frame(width: 16, height: 16)
                            Text(RestoreStepText.quoted(member.app.name, member.title)).font(.callout).lineLimit(2)
                            Spacer(minLength: 0)
                            if isSelected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this window in front of the stack")
                    .accessibilityLabel("\(RestoreStepText.quoted(member.app.name, member.title)), \(at + 1) of \(stack.count) overlapping windows")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func statusBlock(_ status: WindowLiveStatus?, parked: Bool) -> some View {
        let symbol = parked ? "rectangle.stack" : WindowStatusStyle.symbol(status ?? .inPlace)
        let color = parked ? Color.secondary : WindowStatusStyle.color(status ?? .inPlace)
        let text: String = {
            if parked { return "May be in the Stage Manager strip" }
            guard let status else { return "" }
            switch status {
            case .inPlace: return "In place"
            case .willMove: return "Will be moved"
            case .willLaunch: return "App will launch"
            case .notFound: return "Not found"
            case .notRestored: return "Not restored"
            }
        }()
        var reason: String?
        if parked {
            reason = "Stage Manager is on and this app has windows in the strip or another stage, so the window may be there."
        } else if case .notFound(let why) = status, !why.isEmpty {
            reason = why
        }
        return VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: symbol).font(.headline).foregroundStyle(color)
            if let reason { Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(text)" + (reason.map { ". \($0)" } ?? ""))
    }

    private func isRaise(_ step: RestoreStep) -> Bool {
        if case .raise = step { return true } else { return false }
    }

    /// The launch step of this window's app, shown on windows whose app will be opened.
    private func launchStep(for window: WindowSnapshot) -> RestoreStep? {
        guard case .willLaunch? = map.status?.windows[window.id] else { return nil }
        return plan?.steps.first { step in
            if case .launch(let app, _) = step { return RestoreStepText.sameApp(app, window.app) }
            return false
        }
    }

    // MARK: Space

    @ViewBuilder private func spaceDetails(_ space: ProfileSpaceIndex.Space, _ profile: Profile) -> some View {
        Text(map.spaceName(space)).font(.headline)
        let display = profile.displays.first { $0.uuid == space.displayUUID }?.name ?? "Unknown monitor"
        section("Space") {
            row("Monitor", display)
            row("Position", "\(space.position + 1) in Mission Control order")
            row("Kind", kindText(space))
            row("Windows", "\(space.windowIDs.count)")
        }
        if let number = space.desktopNumber,
           case .desktopMissing(let available, let willBeAdded, _)? = map.status?.spaces[SpaceKey(displayUUID: space.displayUUID, desktopNumber: number)] {
            VStack(alignment: .leading, spacing: 4) {
                Label("Desktop missing", systemImage: "circle.dashed").font(.headline)
                Text(willBeAdded ? "This monitor has \(available) Desktop\(available == 1 ? "" : "s"); this one will be added."
                                 : "This monitor has \(available) Desktop\(available == 1 ? "" : "s"). The windows stay where they are.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        let names = space.windowIDs.compactMap { map.window($0) }
        if !names.isEmpty {
            section("Windows here") {
                ForEach(names) { window in
                    Text(RestoreStepText.quoted(window.app.name, window.title)).font(.callout).lineLimit(2)
                }
            }
        }
        Text("Select a window on the map to see its details.").font(.callout).foregroundStyle(.secondary)
    }

    private func kindText(_ space: ProfileSpaceIndex.Space) -> String {
        switch space.kind {
        case .desktop: return "Desktop"
        case .fullScreen: return space.isSplitView ? "Split View" : "Full screen"
        case .other: return "Other"
        }
    }

    // MARK: Text helpers

    private func placementText(_ placement: SpacePlacement, tile: ProfileMapLayout.WindowTile?) -> String {
        switch placement {
        case .desktop(let number): return "Desktop \(number)"
        case .fullScreen(let position): return "Full-screen Space (Space \(position + 1))"
        case .allDesktops: return "On all Desktops"
        case .unknown: return "Unknown"
        }
    }

    private func percentText(_ r: CGRect) -> String {
        func pct(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))%" }
        return "\(pct(r.width)) \u{00D7} \(pct(r.height)) at \(pct(r.minX)), \(pct(r.minY))"
    }

    private func titleMatchText(_ match: TitleMatch) -> String {
        switch match {
        case .any: return "Any title"
        case .exact(let text): return "Title is \"\(text)\""
        case .contains(let text): return "Title contains \"\(text)\""
        case .regex(let text): return "Title matches \(text)"
        }
    }

    /// "Launches 2nd of 5 (one after another)", "Never launched (turned off)", or nil when there is no plan.
    private func launchOrderText(_ app: AppRef, _ profile: Profile) -> String? {
        guard let plan = profile.launchPlan else { return nil }
        let order = LaunchSequence.order(profile)
        if let at = order.firstIndex(where: { RestoreStepText.sameApp($0.app, app) }) {
            let how = plan.mode == .sequential ? "one after another" : "all at once"
            return "Position \(at + 1) of \(order.count) (\(how))."
        }
        if plan.items.contains(where: { RestoreStepText.sameApp($0.app, app) && !$0.enabled }) {
            return "Not launched: turned off in the launch order. Its windows are placed if the app is already open."
        }
        return nil
    }

    // MARK: Layout helpers

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary).textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
