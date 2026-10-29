import SwiftUI
import WMCore

// "New profile" starts from the current workspace (P6.54): the capture runs in the background and the draft opens
// with everything kept. "Review capture" (from the New profile menu) unticks what to leave out; each change is an
// undoable edit on the draft, so nothing waits for a button.

/// The capture behind the draft. Owned by `ProfileStudioModel`.
@MainActor
final class CaptureChoiceModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case capturing
        case ready
    }

    @Published private(set) var stage: Stage = .idle
    /// The whole capture as read, before any untick. Nil when no capture is behind the draft.
    private(set) var captured: Profile?
    /// A cancelled or left draft cannot stop its capture; its late result is ignored instead.
    private var generation = 0

    /// Captures the workspace, then starts the draft with everything kept so the map can show it.
    func run(builder: ProfileBuilderModel) async {
        generation += 1
        let mine = generation
        stage = .capturing
        let result = await builder.captureWorkspace()
        guard mine == generation else { return }
        switch result {
        case .failure(let failure):
            stage = .idle
            builder.failCapture(failure.message)
        case .success(let (profile, notes)):
            captured = profile
            await builder.start(fromCapture: profile, notes: notes)
            guard mine == generation else { return }
            stage = .ready
            DebugLog.log("studio", "capture ready: \(profile.windows.count) windows, \(profile.displays.count) monitors")
        }
    }

    /// Back to View: a capture that is still running is ignored when it ends.
    func reset() {
        generation += 1
        stage = .idle
        captured = nil
    }

    /// The ticks as the draft has them now: a captured window is ticked while it is still in the draft.
    func selection(for builder: ProfileBuilderModel) -> CaptureSelection? {
        guard let captured else { return nil }
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: captured))
        let inDraft = Set(builder.profile?.windows.map(\.id) ?? [])
        for id in sel.tree.allWindowIDs where !inDraft.contains(id) { sel.toggle(window: id) }
        return sel
    }

    /// One tick change in "Review capture". Windows left out by the result of `CaptureSelection.applying(to:)` leave the
    /// draft as one undoable edit. A window that already left stays out: Undo brings it back, a tick does not.
    func review(builder: ProfileBuilderModel, _ change: (inout CaptureSelection) -> Void) {
        guard let captured, var sel = selection(for: builder) else { return }
        change(&sel)
        let kept = Set(sel.applying(to: captured).windows.map(\.id))
        let capturedIDs = Set(captured.windows.map(\.id))
        let removed = (builder.profile?.windows.map(\.id) ?? []).filter { capturedIDs.contains($0) && !kept.contains($0) }
        guard !removed.isEmpty else { return }
        builder.edit(kind: "reviewCapture") { editor in
            for id in removed { try editor.removeWindow(id) }
        }
        DebugLog.log("studio", "capture review: removed \(removed.count) windows, \(kept.count) of \(capturedIDs.count) kept")
    }

    var windowsByID: [UUID: WindowSnapshot] {
        Dictionary((captured?.windows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The New profile chevron: the other starting points, and "Review capture" while a capture is behind the draft.
struct NewProfileMenu: View {
    @ObservedObject var model: ProfileStudioModel
    @ObservedObject var capture: CaptureChoiceModel

    private var canReview: Bool { model.mode == .edit && capture.stage == .ready }

    var body: some View {
        Menu {
            // Enabled in Edit mode too: a press there shows the same notice as the New profile button.
            Button("From current workspace") { model.beginNewProfile() }.help("Start a profile from the windows open now")
            Button("Blank on these monitors") { model.beginBlankProfile() }.help("Start an empty profile on these monitors")
            Button("Copy of a profile…") { model.requestCopyPicker() }.help("Start from a copy of a saved profile")
            if canReview {
                Button("Review capture…") { model.isReviewCapturePresented = true }.help("Untick the captured windows to leave out")
            }
        } label: {
            Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More ways to start: blank, a copy of a profile, or review the captured windows")
        .accessibilityLabel("More ways to start a profile")
    }
}

/// "Review capture": monitors > Desktops > windows of the capture, ticked as the draft has them. Unticking a window
/// removes it from the draft; a window already gone is shown unticked and cannot be ticked back (Undo does that).
struct CaptureReviewPanel: View {
    @ObservedObject var capture: CaptureChoiceModel
    @ObservedObject var builder: ProfileBuilderModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review capture").font(.headline)
            if let selection = capture.selection(for: builder) {
                Text("Untick what this profile should leave out. Undo takes a change back.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("\(selection.selectedWindows) of \(selection.totalWindows) windows kept")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(selection.tree.monitors) { monitorView($0, selection) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
            HStack { Spacer(); Button("Done", action: onDone).keyboardShortcut(.defaultAction).help("Close the review (Return)") }
        }
        .padding(16)
        .frame(width: 380, height: 420)
    }

    // MARK: Tree

    private func monitorView(_ monitor: CaptureSelectionTree.Monitor, _ selection: CaptureSelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            checkRow(selection.state(of: monitor), icon: "display", title: monitor.display?.name ?? "Monitor", bold: true,
                     indent: 0, enabled: !monitor.windowIDs.isEmpty) { capture.review(builder: builder) { $0.toggle(monitor: monitor) } }
            ForEach(monitor.groups) { group in
                checkRow(selection.state(of: group), icon: icon(for: group), title: title(for: group), bold: false,
                         indent: 1, detail: group.windowIDs.isEmpty ? "empty" : nil, enabled: !group.windowIDs.isEmpty) {
                    capture.review(builder: builder) { $0.toggle(group: group) }
                }
                ForEach(group.windowIDs, id: \.self) { windowRow($0, selection) }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func windowRow(_ id: UUID, _ selection: CaptureSelection) -> some View {
        if let window = capture.windowsByID[id] {
            let inDraft = selection.isSelected(window: id)
            checkRow(inDraft ? .on : .off, icon: nil, title: window.app.name, bold: false, indent: 2,
                     detail: window.title.flatMap { $0.isEmpty ? nil : $0 }, enabled: inDraft) {
                capture.review(builder: builder) { $0.toggle(window: id) }
            }
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
                          detail: String? = nil, enabled: Bool = true, action: @escaping () -> Void) -> some View {
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
        .disabled(!enabled)
        .help(state == .off ? "Tick to keep \(title) in the profile" : "Untick to leave \(title) out of the profile")
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .on ? "checked" : state == .mixed ? "partly checked" : "unchecked")
    }
}
