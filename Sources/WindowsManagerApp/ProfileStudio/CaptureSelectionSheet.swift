import SwiftUI
import WMCore

// "Start from the current workspace" (P6.47): the capture runs in the background into a draft capture, then this
// step lets people tick the monitors, Desktops and windows to keep. Nothing is saved or started until "Create draft".

/// The capture and the ticked boxes. Owned by `ProfileStudioModel`; the sheet observes it.
@MainActor
final class CaptureChoiceModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case capturing
        case failed(String)
        case choosing
    }

    @Published private(set) var stage: Stage = .idle
    @Published var selection: CaptureSelection?
    private var captured: Profile?
    private var notes: [String] = []
    /// A cancelled or restarted capture cannot be stopped; its late result is ignored instead.
    private var generation = 0

    /// Captures in the background, then moves to the selection step.
    func run(builder: ProfileBuilderModel) async {
        generation += 1
        let mine = generation
        stage = .capturing
        let result = await builder.captureWorkspace()
        guard mine == generation else { return }
        switch result {
        case .failure(let failure):
            stage = .failed(failure.message)
        case .success(let (profile, captureNotes)):
            captured = profile
            notes = captureNotes
            let sel = CaptureSelection(tree: CaptureSelectionTree(profile: profile))
            selection = sel
            stage = .choosing
            DebugLog.log("studio", "capture selection: \(sel.selectedWindows) of \(sel.totalWindows) windows selected")
        }
    }

    /// Back to the start sheet (also ignores a capture that is still running).
    func reset() {
        generation += 1
        stage = .idle
        selection = nil
        captured = nil
        notes = []
    }

    /// The captured profile reduced to what is ticked, with the capture notes; nil when nothing is ticked.
    func filtered() -> (Profile, [String])? {
        guard let captured, let selection, selection.hasSelection else { return nil }
        let profile = selection.applying(to: captured)
        DebugLog.log("studio", "capture create: \(selection.selectedWindows) of \(selection.totalWindows) windows, "
            + "\(profile.displays.count) monitors, \(profile.spaces.count) spaces")
        return (profile, notes)
    }

    func update(_ change: (inout CaptureSelection) -> Void) {
        guard var sel = selection else { return }
        change(&sel)
        selection = sel
        DebugLog.log("studio", "capture selection: \(sel.selectedWindows) of \(sel.totalWindows) windows selected")
    }

    var windowsByID: [UUID: WindowSnapshot] {
        Dictionary((captured?.windows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The content of the start sheet: the three starting points, then (for the current workspace) progress and selection.
struct StudioStartFlow: View {
    @ObservedObject var capture: CaptureChoiceModel
    let profiles: [ProfileStudioRow]
    let onChoose: (StudioStartChoice) -> Void
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch capture.stage {
        case .idle:
            StudioStartSheet(profiles: profiles, onChoose: onChoose, onCancel: onCancel)
        case .capturing:
            VStack(spacing: 14) {
                ProgressView()
                Text("Reading your workspace…").font(.headline)
                Text("This can take a few seconds. You will choose what to include next.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Cancel") { capture.reset() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .frame(minWidth: 300, maxWidth: 480)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text("New profile").font(.title2.bold())
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Back") { capture.reset() }.keyboardShortcut(.cancelAction) }
            }
            .padding(20)
            .frame(minWidth: 300, maxWidth: 480)
        case .choosing:
            CaptureSelectionSheet(capture: capture, onCreate: onCreate, onBack: { capture.reset() }, onCancel: onCancel)
        }
    }
}

/// Tree of monitors > Desktops > windows with check boxes, "Select all / none" and the count.
struct CaptureSelectionSheet: View {
    @ObservedObject var capture: CaptureChoiceModel
    let onCreate: () -> Void
    let onBack: () -> Void
    let onCancel: () -> Void

    private var selection: CaptureSelection? { capture.selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose what to include").font(.title2.bold())
            if let selection {
                Text("Tick the monitors, Desktops and windows the new profile should start with.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                toolbar(selection)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(selection.tree.monitors) { monitorView($0, selection) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                footer(selection)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 480, minHeight: 280, idealHeight: 480)
    }

    private func toolbar(_ selection: CaptureSelection) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { toolbarContent(selection) }
            VStack(alignment: .leading, spacing: 6) { toolbarContent(selection) }
        }
    }

    @ViewBuilder private func toolbarContent(_ selection: CaptureSelection) -> some View {
        Button("Select all") { capture.update { $0.selectAll() } }
        Button("Select none") { capture.update { $0.selectNone() } }
        Spacer(minLength: 8)
        Text("\(selection.selectedWindows) of \(selection.totalWindows) windows selected")
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }

    private func footer(_ selection: CaptureSelection) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Spacer(); footerButtons(selection) }
            VStack(alignment: .trailing, spacing: 6) { footerButtons(selection) }
        }
    }

    @ViewBuilder private func footerButtons(_ selection: CaptureSelection) -> some View {
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Back", action: onBack)
        Button("Create draft", action: onCreate)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!selection.hasSelection)
    }

    // MARK: Tree

    private func monitorView(_ monitor: CaptureSelectionTree.Monitor, _ selection: CaptureSelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            checkRow(selection.state(of: monitor), icon: "display", title: monitor.display?.name ?? "Monitor", bold: true,
                     indent: 0) { capture.update { $0.toggle(monitor: monitor) } }
            ForEach(monitor.groups) { group in
                checkRow(selection.state(of: group), icon: icon(for: group), title: title(for: group), bold: false,
                         indent: 1, detail: group.windowIDs.isEmpty ? "empty" : nil) { capture.update { $0.toggle(group: group) } }
                ForEach(group.windowIDs, id: \.self) { windowRow($0, selection) }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func windowRow(_ id: UUID, _ selection: CaptureSelection) -> some View {
        if let window = capture.windowsByID[id] {
            checkRow(selection.isSelected(window: id) ? .on : .off, icon: nil, title: window.app.name, bold: false, indent: 2,
                     detail: window.title.flatMap { $0.isEmpty ? nil : $0 }) { capture.update { $0.toggle(window: id) } }
        }
    }

    private func title(for group: CaptureSelectionTree.Group) -> String {
        switch group.kind {
        case .desktop: return group.desktopNumber.map { "Desktop \($0)" } ?? "Desktop"
        case .fullScreen:
            let owner = group.windowIDs.first.flatMap { capture.windowsByID[$0] }
            return "Full screen" + (owner.map { ": \($0.app.name)" } ?? "")
        case .other: return group.isOtherWindows ? "Minimized and other windows" : "Other Space"
        }
    }

    private func icon(for group: CaptureSelectionTree.Group) -> String {
        switch group.kind {
        case .desktop: return "rectangle.on.rectangle"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .other: return "tray"
        }
    }

    private func checkRow(_ state: CaptureCheckState, icon: String?, title: String, bold: Bool, indent: Int,
                          detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                    .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                Text(title).fontWeight(bold ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .on ? "checked" : state == .mixed ? "partly checked" : "unchecked")
    }
}
