import SwiftUI
import WMCore

/// What a finished recording found, waiting for the user's review.
struct PendingRecording: Identifiable {
    let id = UUID()
    var analysis: RecordingAnalysis
    /// Windows of the apps the user opened, as they were when recording stopped.
    var windows: [WindowSnapshot]
    var displayNames: [String: String]
    var skippedSecureInput: Bool
}

/// Shown after Stop: a checklist of the window layout and each detected action. Nothing is added until
/// "Add to Profile"; Cancel throws the recording away.
struct RecordingReviewSheet: View {
    let pending: PendingRecording
    let onAdd: (_ windows: [WindowSnapshot], _ actions: [ProfileAction]) -> Void
    let onCancel: () -> Void

    @State private var includeLayout: Bool
    @State private var windowOn: Set<UUID>
    @State private var actions: [DetectedAction]
    @State private var actionOn: Set<UUID>
    @State private var phases: [UUID: ActionPhase] = [:]
    @State private var keepTiming = false

    init(pending: PendingRecording, onAdd: @escaping ([WindowSnapshot], [ProfileAction]) -> Void, onCancel: @escaping () -> Void) {
        self.pending = pending; self.onAdd = onAdd; self.onCancel = onCancel
        _includeLayout = State(initialValue: !pending.windows.isEmpty)
        _windowOn = State(initialValue: Set(pending.windows.map(\.id)))
        _actions = State(initialValue: pending.analysis.actions)
        _actionOn = State(initialValue: Set(pending.analysis.actions.map(\.id)))
    }

    private var chosenWindows: [WindowSnapshot] {
        includeLayout ? pending.windows.filter { windowOn.contains($0.id) } : []
    }
    private var chosenActions: [ProfileAction] {
        actions.filter { actionOn.contains($0.id) }.map {
            $0.profileAction(keepTiming: keepTiming, phase: phases[$0.id] ?? .afterRestore)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Review recording").font(.wmTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if !pending.windows.isEmpty { layoutItem }
                    ForEach($actions) { $action in actionItem($action) }
                    if pending.windows.isEmpty && actions.isEmpty {
                        Text("Nothing worth keeping was found in this recording.")
                            .font(.wmCaption).foregroundStyle(.secondary)
                    }
                    if pending.skippedSecureInput {
                        InspectorNote(text: "Text typed into a password field was left out of the recording.")
                    }
                }
            }
            Toggle("Keep my recorded timing", isOn: $keepTiming).toggleStyle(.checkbox)
                .help("Add a wait where you paused for more than a second while recording (rounded to 0.5 s, at most 10 s)")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add to Profile") { onAdd(chosenWindows, chosenActions) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenWindows.isEmpty && chosenActions.isEmpty)
                    .help("Add the ticked windows and actions to the profile")
            }
        }
        .padding(Spacing.l)
        .frame(width: 460, height: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review recording")
    }

    private var layoutItem: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(isOn: $includeLayout) {
                Text("Windows & layout").font(.wmSection)
            }
            .toggleStyle(.checkbox)
            .help("Add the windows of the apps you opened, where they are now")
            Text("The profile opens these apps and places their windows, so no launch steps are needed.")
                .font(.wmCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(pending.windows) { w in
                Toggle(isOn: Binding(get: { windowOn.contains(w.id) },
                                     set: { if $0 { windowOn.insert(w.id) } else { windowOn.remove(w.id) } })) {
                    HStack {
                        Text(w.app.name).lineLimit(1)
                        Spacer(minLength: Spacing.xs)
                        Text(detail(w)).font(.wmCaption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox).disabled(!includeLayout)
                .padding(.leading, Spacing.l)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium))
    }

    private func detail(_ w: WindowSnapshot) -> String {
        var desktop = "Desktop"
        if case .desktop(let n) = w.placement { desktop = "Desktop \(n)" }
        let display = pending.displayNames[w.displayUUID] ?? "Monitor"
        return "\(display), \(desktop), \(Int(w.frame.width))×\(Int(w.frame.height))"
    }

    private func actionItem(_ action: Binding<DetectedAction>) -> some View {
        let id = action.wrappedValue.id
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Toggle("Include \(action.wrappedValue.name)", isOn: Binding(
                    get: { actionOn.contains(id) }, set: { if $0 { actionOn.insert(id) } else { actionOn.remove(id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
                TextField("Name", text: action.name).textFieldStyle(.roundedBorder)
                Text("\(action.wrappedValue.steps.count) step\(action.wrappedValue.steps.count == 1 ? "" : "s")")
                    .font(.wmCaption).foregroundStyle(.secondary).fixedSize()
                Button(role: .destructive) {
                    actions.removeAll { $0.id == id }; actionOn.remove(id)
                } label: { Label("Remove", systemImage: "trash").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help("Remove this action from the list")
            }
            DisclosureGroup("Steps") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(action.wrappedValue.steps.enumerated()), id: \.offset) { i, e in
                        Text("\(i + 1). \(e.step.summary)").font(.wmCaption).foregroundStyle(.secondary)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            LabeledContent("Runs") {
                Picker("Runs", selection: Binding(get: { phases[id] ?? .afterRestore }, set: { phases[id] = $0 })) {
                    Text("Before restoring windows").tag(ActionPhase.beforeRestore)
                    Text("After restoring windows").tag(ActionPhase.afterRestore)
                }
                .labelsHidden().fixedSize()
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium))
        .opacity(actionOn.contains(id) ? 1 : 0.5)
    }
}
