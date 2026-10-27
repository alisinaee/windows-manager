import SwiftUI

/// Slim icon rail shown instead of the profile sidebar when it is collapsed: toggle, New profile, one icon per profile.
struct SidebarRailView: View {
    @ObservedObject var model: ProfileStudioModel
    static let width: CGFloat = 52

    var body: some View {
        VStack(spacing: 6) {
            HStack { SidebarToggleButton(model: model) }
            Button { model.beginNewProfile() } label: {
                tile(icon: "plus", tint: .accentColor, selected: false)
            }
            .buttonStyle(.plain)
            .disabled(model.mode == .edit)
            .help("New profile")
            .accessibilityLabel("New profile")
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.rows) { row in railIcon(row) }
                }
            }
            .scrollIndicators(.hidden)
            .disabled(model.mode == .edit)
        }
        .padding(.vertical, 10)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    /// Same icon and tint as the profile's row in the full sidebar, in a rounded tile like a pro-app rail.
    private func tile(icon: String, tint: Color, selected: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? tint.opacity(0.30) : tint.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? tint.opacity(0.9) : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
    }

    private func railIcon(_ row: ProfileStudioRow) -> some View {
        let selected = row.id == model.selectedID
        return Button { model.selectedID = row.id } label: {
            tile(icon: row.icon, tint: ProfileRowTint.color(for: row.id), selected: selected)
        }
        .buttonStyle(.plain)
        .help(row.name)
        .accessibilityLabel(row.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A stable colour per profile, shared by the full sidebar row and the collapsed rail.
enum ProfileRowTint {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]

    static func color(for id: UUID) -> Color {
        let sum = id.uuid.0 &+ id.uuid.5 &+ id.uuid.10 &+ id.uuid.15
        return palette[Int(sum) % palette.count]
    }
}

/// The sidebar.left button (Cmd+Opt+S) that collapses or expands the profile sidebar.
struct SidebarToggleButton: View {
    @ObservedObject var model: ProfileStudioModel

    var body: some View {
        Button { model.toggleSidebar() } label: {
            Image(systemName: "sidebar.left").frame(width: 32, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .help(model.isSidebarShown ? "Hide the sidebar (Cmd+Opt+S)" : "Show the sidebar (Cmd+Opt+S)")
        .accessibilityLabel(model.isSidebarShown ? "Hide sidebar" : "Show sidebar")
    }
}

/// Remembered size of the Details inspector (bottom height / right width), set by dragging the divider.
@MainActor
final class StudioInspectorLayout: ObservableObject {
    static let shared = StudioInspectorLayout()
    @Published var height: CGFloat
    @Published var width: CGFloat
    @Published var isCollapsed: Bool
    fileprivate var dragStart: CGFloat?

    init() {
        let d = UserDefaults.standard
        let h = d.double(forKey: "studioInspectorHeight"), w = d.double(forKey: "studioInspectorWidth")
        height = h > 0 ? h : 150
        width = w > 0 ? w : 260
        isCollapsed = d.bool(forKey: "studioInspectorCollapsed")
    }

    func toggleCollapsed() {
        isCollapsed.toggle()
        UserDefaults.standard.set(isCollapsed, forKey: "studioInspectorCollapsed")
        DebugLog.log("studio", "details panel \(isCollapsed ? "minimized" : "restored")")
    }

    func save() {
        UserDefaults.standard.set(Double(height), forKey: "studioInspectorHeight")
        UserDefaults.standard.set(Double(width), forKey: "studioInspectorWidth")
    }
}

/// Main pane (gets all spare room) plus a resizable inspector: on the right when wide, below when not.
struct StudioInspectorSplit<Main: View, Inspector: View>: View {
    let sideBySideWidth: CGFloat
    let minMainWidth: CGFloat
    @ViewBuilder let main: () -> Main
    @ViewBuilder let inspector: () -> Inspector
    @ObservedObject private var layout = StudioInspectorLayout.shared

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= sideBySideWidth {
                let limit = 220...max(220, min(440, geo.size.width - minMainWidth))
                let w = min(max(layout.width, limit.lowerBound), limit.upperBound)
                HStack(spacing: 0) {
                    main().frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    if !layout.isCollapsed {
                        handle(vertical: true, current: w, limit: limit)
                        inspector().frame(width: w).frame(maxHeight: .infinity)
                    }
                    Divider()
                    collapseStrip(vertical: true)
                }
            } else {
                let maxH = max(90, min(geo.size.height * 0.6, geo.size.height - 200))
                let h = min(max(layout.height, 90), maxH)
                VStack(spacing: 0) {
                    main().frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    if !layout.isCollapsed {
                        handle(vertical: false, current: h, limit: 90...maxH)
                    } else {
                        Divider()
                    }
                    collapseStrip(vertical: false)
                    if !layout.isCollapsed {
                        inspector().frame(height: h).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// Slim bar with the minimize / restore button for the Details panel.
    private func collapseStrip(vertical: Bool) -> some View {
        let collapsed = layout.isCollapsed
        let symbol = vertical ? (collapsed ? "chevron.left" : "chevron.right") : (collapsed ? "chevron.up" : "chevron.down")
        return Button { layout.toggleCollapsed() } label: {
            Group {
                if vertical {
                    Image(systemName: symbol).frame(width: 22).frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                        Text("Details").font(.caption.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 22)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the Details panel" : "Minimize the Details panel")
        .accessibilityLabel(collapsed ? "Show details" : "Minimize details")
    }

    /// 1pt divider centred in a 9pt drag area (the whole area takes the drag, not only the line).
    private func handle(vertical: Bool, current: CGFloat, limit: ClosedRange<CGFloat>) -> some View {
        Color.clear
            .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if layout.dragStart == nil { layout.dragStart = current }
                    let delta = vertical ? value.translation.width : value.translation.height
                    let size = min(max((layout.dragStart ?? current) - delta, limit.lowerBound), limit.upperBound)
                    if vertical { layout.width = size } else { layout.height = size }
                }
                .onEnded { _ in layout.dragStart = nil; layout.save() })
    }
}
