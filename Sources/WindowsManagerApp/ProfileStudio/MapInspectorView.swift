import SwiftUI
import WMCore

/// The Selection page of the Details inspector (both modes): details of the selected window, or of the Space the
/// focused monitor shows. Read only. With Compare on it also gives the live status, the reason, and the planned
/// steps for the selected window. Plain content: the inspector container supplies the scrolling and the title.
struct MapInspectorView: View {
    @ObservedObject var map: ProfileMapModel
    /// The plan behind the live status, when Compare is on and done.
    var plan: RestorePlan?
    var isCompareOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if let id = map.selectedWindowID, let window = map.window(id) {
                windowDetails(window)
            } else if let profile = map.profile, let space = focusedSpace(profile) {
                spaceDetails(space, profile)
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "rectangle.dashed",
                                       description: Text("Select a window or a Desktop on the map to see its details."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Title for the inspector header: the selected window, else the shown Desktop.
    static func title(for map: ProfileMapModel) -> String {
        if let id = map.selectedWindowID, let window = map.window(id) {
            return RestoreStepText.quoted(window.app.name, window.title)
        }
        if let profile = map.profile, let uuid = map.focusedDisplayUUID ?? profile.displays.first?.uuid,
           let space = map.shownSpace(onDisplay: uuid) {
            return map.spaceName(space)
        }
        return "Selection"
    }

    private func focusedSpace(_ profile: Profile) -> ProfileSpaceIndex.Space? {
        guard let uuid = map.focusedDisplayUUID ?? profile.displays.first?.uuid else { return nil }
        return map.shownSpace(onDisplay: uuid)
    }

    // MARK: Window

    @ViewBuilder private func windowDetails(_ window: WindowSnapshot) -> some View {
        let profile = map.profile
        let tile = map.layout.windows.first { $0.windowID == window.id }

        if let stack = map.selectedStack { stackSection(stack, selected: window.id) }

        let live = map.status
        let status = live?.windows[window.id]
        let parked = live?.parked.contains(window.id) == true
        if status != nil || parked { statusBlock(status, parked: parked) }
        else if isCompareOn { Text("Comparing with your Mac…").foregroundStyle(.secondary) }

        let steps = (plan?.steps ?? []).filter { $0.target?.snapshotID == window.id && !isRaise($0) }
        if !steps.isEmpty || launchStep(for: window) != nil {
            InspectorSection(title: "Planned steps") {
                if let launch = launchStep(for: window) {
                    Text(RestoreStepText.text(launch))
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text(RestoreStepText.text(step)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        InspectorSection(title: "Where") {
            LabeledContent("Monitor", value: profile?.displays.first { $0.uuid == window.displayUUID }?.name ?? "Unknown monitor")
            LabeledContent("Desktop", value: placementText(window.placement, tile: tile))
            if let zone = window.zoneName { LabeledContent("Zone", value: zone) }
        }

        InspectorSection(title: "Size and position") {
            LabeledContent("Relative", value: percentText(window.relativeFrame))
            LabeledContent("Points", value: "\(RestoreStepText.size(window.frame)) at \(Int(window.frame.minX.rounded())), \(Int(window.frame.minY.rounded()))")
            if let phrase = ProfileMapModel.positionPhrase(for: window, tile: tile) { LabeledContent("Looks like", value: phrase) }
        }

        InspectorSection(title: "State") {
            LabeledContent("Full screen", value: window.isFullScreen ? "Yes" : "No")
            LabeledContent("Minimized", value: window.isMinimized ? "Yes" : "No")
            LabeledContent("Restored", value: window.restore ? "Yes" : "No, left out of a restore")
            LabeledContent("Stacking", value: window.zIndex == 0 ? "Front" : "Number \(window.zIndex + 1) from the front")
            LabeledContent("Title match", value: titleMatchText(window.titleMatch))
            if let doc = window.documentPath, !doc.isEmpty { LabeledContent("Document", value: doc) }
            if window.origin == .planned { LabeledContent("Origin", value: "Planned in the Builder") }
        }

        if let profile, let launch = launchOrderText(window.app, profile) {
            InspectorSection(title: "Launch order") { Text(launch).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// Every window of the selected stack; a click brings that window to the front of the stack.
    private func stackSection(_ stack: TileStacking.Stack, selected: UUID) -> some View {
        InspectorSection(title: "Overlapping windows (\(stack.count))") {
            ForEach(Array(map.orderedMembers(of: stack).enumerated()), id: \.element) { at, id in
                if let member = map.window(id) {
                    let isSelected = id == selected
                    Button { map.selectWindow(id) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: AppIconCache.icon(for: member.app)).resizable().frame(width: 16, height: 16)
                            Text(RestoreStepText.quoted(member.app.name, member.title)).lineLimit(2)
                            Spacer(minLength: 0)
                            if isSelected { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
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
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(text, systemImage: symbol).font(.wmSection).foregroundStyle(color)
            if let reason { Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.medium))
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
        let display = profile.displays.first { $0.uuid == space.displayUUID }?.name ?? "Unknown monitor"
        InspectorSection {
            LabeledContent("Monitor", value: display)
            LabeledContent("Order", value: orderText(space))
            LabeledContent("Kind", value: kindText(space))
            LabeledContent("Windows", value: "\(space.windowIDs.count)")
        }
        if let number = space.desktopNumber,
           case .desktopMissing(let available, let willBeAdded, _)? = map.status?.spaces[SpaceKey(displayUUID: space.displayUUID, desktopNumber: number)] {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Desktop missing", systemImage: "circle.dashed").font(.wmSection)
                Text(willBeAdded ? "This monitor has \(available) Desktop\(available == 1 ? "" : "s"); this one will be added."
                                 : "This monitor has \(available) Desktop\(available == 1 ? "" : "s"). The windows stay where they are.")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        let names = space.windowIDs.compactMap { map.window($0) }
        if !names.isEmpty {
            InspectorSection(title: "Windows here") {
                ForEach(names) { window in
                    Button { map.selectWindow(window.id) } label: {
                        Label {
                            Text(RestoreStepText.quoted(window.app.name, window.title)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } icon: {
                            Image(nsImage: AppIconCache.icon(for: window.app)).resizable().frame(width: 16, height: 16)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Select this window on the map")
                    .accessibilityLabel("Select \(RestoreStepText.quoted(window.app.name, window.title))")
                }
            }
        }
        Text("Select a window on the map to see its details.").font(.wmCaption).foregroundStyle(.secondary)
    }

    /// "1st Desktop" for a Desktop, "2nd Space" for any other Space.
    private func orderText(_ space: ProfileSpaceIndex.Space) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        let ordinal = formatter.string(from: NSNumber(value: space.position + 1)) ?? "\(space.position + 1)"
        return "\(ordinal) \(space.kind == .desktop ? "Desktop" : "Space")"
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
}
