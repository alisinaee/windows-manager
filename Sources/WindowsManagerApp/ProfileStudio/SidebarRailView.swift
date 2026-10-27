import SwiftUI

/// Slim icon rail shown instead of the profile sidebar when it is collapsed: toggle, New profile, one icon per profile.
struct SidebarRailView: View {
    @ObservedObject var model: ProfileStudioModel
    static let width: CGFloat = 48

    var body: some View {
        VStack(spacing: 6) {
            SidebarToggleButton(model: model)
            Button { model.beginNewProfile() } label: {
                Image(systemName: "plus").frame(width: 32, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(model.mode == .edit)
            .help("New profile")
            .accessibilityLabel("New profile")
            Divider().padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.rows) { row in railIcon(row) }
                }
                .padding(.horizontal, 6)
            }
            .disabled(model.mode == .edit)
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    private func railIcon(_ row: ProfileStudioRow) -> some View {
        let selected = row.id == model.selectedID
        return Button { model.selectedID = row.id } label: {
            Image(systemName: row.icon)
                .frame(width: 32, height: 30)
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.name)
        .accessibilityLabel(row.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    fileprivate var dragStart: CGFloat?

    init() {
        let d = UserDefaults.standard
        let h = d.double(forKey: "studioInspectorHeight"), w = d.double(forKey: "studioInspectorWidth")
        height = h > 0 ? h : 150
        width = w > 0 ? w : 260
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
                let w = min(max(layout.width, 220), max(220, min(440, geo.size.width - minMainWidth)))
                HStack(spacing: 0) {
                    main().frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    handle(vertical: true, current: w, limit: 220...max(220, min(440, geo.size.width - minMainWidth)))
                    inspector().frame(width: w).frame(maxHeight: .infinity)
                }
            } else {
                let maxH = max(90, min(geo.size.height * 0.6, geo.size.height - 200))
                let h = min(max(layout.height, 90), maxH)
                VStack(spacing: 0) {
                    main().frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    handle(vertical: false, current: h, limit: 90...maxH)
                    inspector().frame(height: h).frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 1pt divider with an 8pt drag area.
    private func handle(vertical: Bool, current: CGFloat, limit: ClosedRange<CGFloat>) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: vertical ? 8 : nil, height: vertical ? nil : 8)
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
}
