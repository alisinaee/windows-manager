import SwiftUI
import WMCore

/// The Actions page of the Details inspector: UI steps a profile runs before or after it restores windows.
/// Each action is a collapsible card (`ActionCard`) whose steps are one-line rows (`ActionStepRow`) that expand to
/// their fields. Every change goes through `builder.setActions`, so it is undoable; in View mode (`builder` nil)
/// the list is read only, but "Test run" still works. Plain content: the inspector container scrolls.
struct ProfileActionsPanel: View {
    let profile: Profile
    let builder: ProfileBuilderModel?

    /// The expanded card (only one at a time); also where "Record…" and new steps go.
    @State private var selectedID: UUID?
    @State private var didSeedSelection = false
    @State private var running: UUID?
    @State private var reports: [UUID: ActionRunReport] = [:]
    @State private var expandedSteps: [UUID: Set<Int>] = [:]
    @StateObject private var recording = RecordingController()
    @State private var recordNote: String?
    @State private var pendingRecording: PendingRecording?
    @State private var analyzing = false

    private var actions: [ProfileAction] { profile.actions }
    private var isEditable: Bool { builder != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            InspectorSection(title: "Actions") {
                if actions.isEmpty {
                    Text("No actions yet. An action is a short list of steps, such as opening an app and pressing a button, that runs before or after the windows are restored.")
                        .font(.wmCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    card(index: index, action: action)
                }
                if isEditable {
                    HStack(spacing: Spacing.s) {
                        addActionButton
                        if !actions.contains(where: { $0.id == selectedID }) {
                            Button { startRecording(into: nil) } label: { Label("Record…", systemImage: "record.circle") }
                                .disabled(recording.isRecording || analyzing)
                                .help("Record clicks and typing in other apps; you review what was found before it is added")
                        }
                    }
                }
            }
            if let recordNote { InspectorNote(text: recordNote) }
            if let error = builder?.lastError { InspectorNote(text: error) }
        }
        .accessibilityLabel("Profile actions")
        .onAppear {
            if !didSeedSelection { didSeedSelection = true; selectedID = selectedID ?? actions.first?.id }
        }
        .sheet(item: $pendingRecording) { pending in
            RecordingReviewSheet(pending: pending, onAdd: { windows, newActions in
                _ = builder?.applyRecording(windows: windows, actions: newActions)
                if let note = builder?.recordingSkipNote, !note.isEmpty { recordNote = note }
                if let first = newActions.first { selectedID = first.id }
                pendingRecording = nil
            }, onCancel: { pendingRecording = nil })
        }
    }

    // MARK: Actions

    private var addActionButton: some View {
        Button {
            var list = actions
            let action = ProfileAction(name: "Action \(list.count + 1)")
            list.append(action)
            selectedID = action.id
            builder?.setActions(list)
        } label: { Label("Add Action", systemImage: "plus") }
            .help("Add an action that runs before or after the restore")
    }

    private func card(index: Int, action: ProfileAction) -> some View {
        ActionCard(action: action, isExpanded: selectedID == action.id, isEditable: isEditable,
                   lastResult: reports[action.id].map { $0.succeeded },
                   toggleExpanded: { selectedID = selectedID == action.id ? nil : action.id },
                   update: { change in update(action.id, change) },
                   canMoveUp: index > 0, canMoveDown: index < actions.count - 1,
                   move: { move(index, by: $0) }, delete: { delete(action.id) }) {
            stepsArea(action)
        }
    }

    private func update(_ id: UUID, _ change: (inout ProfileAction) -> Void) {
        var list = actions
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        builder?.setActions(list)
    }

    /// Edits that shift step positions: the per-index expansion and test results no longer line up, so they reset.
    private func restructure(_ id: UUID, _ change: (inout ProfileAction) -> Void) {
        expandedSteps[id] = nil
        reports[id] = nil
        update(id, change)
    }

    private func move(_ index: Int, by delta: Int) {
        var list = actions
        let target = index + delta
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        builder?.setActions(list)
    }

    private func delete(_ id: UUID) {
        if selectedID == id { selectedID = nil }
        expandedSteps[id] = nil
        reports[id] = nil
        builder?.setActions(actions.filter { $0.id != id })
    }

    // MARK: Steps

    private func stepsArea(_ action: ProfileAction) -> some View {
        let open = expandedSteps[action.id] ?? []
        let report = reports[action.id]
        let busy = running != nil
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Steps").font(.wmCallout.weight(.semibold))
                Spacer()
                if action.steps.count > 1 {
                    Button(open.count == action.steps.count ? "Collapse all" : "Expand all") {
                        expandedSteps[action.id] = open.count == action.steps.count ? [] : Set(action.steps.indices)
                    }
                    .buttonStyle(.link).font(.wmCaption)
                    .help("Show or hide the fields of every step")
                }
            }
            if action.steps.isEmpty {
                Text("No steps yet.").font(.wmCaption).foregroundStyle(.secondary)
            }
            ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                ActionStepRow(
                    actionID: action.id, index: index, count: action.steps.count, step: step,
                    isEditable: isEditable, canRun: !busy,
                    report: report?.steps.first { $0.index == index },
                    isExpanded: open.contains(index),
                    toggle: {
                        if open.contains(index) { expandedSteps[action.id]?.remove(index) }
                        else { expandedSteps[action.id, default: []].insert(index) }
                    },
                    change: { new in update(action.id) { $0.steps[index] = new } },
                    move: { delta in restructure(action.id) { a in
                        let t = index + delta
                        if a.steps.indices.contains(t) { a.steps.swapAt(index, t) }
                    } },
                    moveTo: { from, to in restructure(action.id) { a in
                        guard a.steps.indices.contains(from), a.steps.indices.contains(to), from != to else { return }
                        a.steps.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                    } },
                    remove: { restructure(action.id) { $0.steps.remove(at: index) } },
                    duplicate: { restructure(action.id) { $0.steps.insert($0.steps[index], at: index + 1) } },
                    addDelayAfter: { restructure(action.id) { $0.steps.insert(.delay(seconds: 1), at: index + 1) } },
                    runOnly: { runSteps(action, indices: [index]) },
                    runUpToHere: { runSteps(action, indices: Array(0...index)) })
                if index < action.steps.count - 1, action.stepGap > 0 {
                    StepGapRow(seconds: action.stepGap, isEditable: isEditable) { v in update(action.id) { $0.stepGap = v } }
                }
            }
            footer(action)
            if let report { reportSummary(report, total: action.steps.count) }
        }
    }

    private func footer(_ action: ProfileAction) -> some View {
        HStack(spacing: Spacing.s) {
            if isEditable {
                Menu {
                    ForEach(StepKind.allCases) { kind in
                        Button(kind.title) {
                            update(action.id) { $0.steps.append(kind.makeStep()) }
                            if kind != .delay { expandedSteps[action.id, default: []].insert(action.steps.count) }
                        }
                    }
                } label: { Label("Add Step", systemImage: "plus") }
                    .fixedSize().help("Add a step to this action")
                Button { startRecording(into: action.id) } label: { Label("Record…", systemImage: "record.circle") }
                    .disabled(recording.isRecording)
                    .help("Record clicks and typing in other apps as steps of this action")
            }
            Spacer(minLength: Spacing.xs)
            Button { runSteps(action, indices: Array(action.steps.indices)) } label: {
                if running == action.id { ProgressView().controlSize(.small) } else { Label("Test Run", systemImage: "play") }
            }
            .disabled(running != nil || action.steps.isEmpty)
            .help("Run this action now and show what each step did")
        }
        .padding(.top, Spacing.xs)
    }

    /// Records into the selected action; `nil` records a new set: after Stop the recording is analyzed and reviewed.
    private func startRecording(into id: UUID?) {
        recordNote = nil
        let started = recording.start { steps, skipped in
            if let id { finishRecording(steps.map(\.step), skipped: skipped, into: id) }
            else { analyze(steps, skipped: skipped) }
        }
        if !started { RecordingPermission.showStartFailedAlert() }
    }

    private func finishRecording(_ steps: [ActionStep], skipped: Bool, into id: UUID) {
        var list = actions
        if steps.isEmpty {
            recordNote = "Nothing was recorded."
        } else if let i = list.firstIndex(where: { $0.id == id }) {
            list[i].steps.append(contentsOf: steps)
            builder?.setActions(list)
        }
        if skipped {
            let extra = "Text typed into a password field was left out of the recording."
            recordNote = recordNote.map { $0 + " " + extra } ?? extra
        }
    }

    /// Reads the windows that exist now, keeps those of the apps the user opened, and opens the review.
    private func analyze(_ steps: [TimedStep], skipped: Bool) {
        guard !steps.isEmpty else {
            recordNote = "Nothing was recorded."
            if skipped { recordNote = (recordNote ?? "") + " Text typed into a password field was left out of the recording." }
            return
        }
        analyzing = true
        Task {
            let touched = Set(steps.compactMap { step -> String? in
                if case .launchApp(let b) = step.step { return b } else { return nil }
            })
            var windows: [WindowSnapshot] = []
            var names: [String: String] = [:]
            var displayNames: [String: String] = [:]
            var haveWindows: Set<String> = []
            if !touched.isEmpty, let scan = await CaptureSession.runTimed(limit: CaptureTimeout.defaultLimit, { CaptureSession.scanWorkspace() }) {
                let captured = await Task.detached { ProfileCapture.makeProfile(name: "Recording", from: scan).0 }.value
                displayNames = Dictionary(captured.displays.map { ($0.uuid, $0.name) }, uniquingKeysWith: { a, _ in a })
                for w in captured.windows {
                    guard let b = w.app.bundleID, !w.isMinimized else { continue }
                    names[b] = w.app.name
                    haveWindows.insert(b)
                    if touched.contains(b) { windows.append(w) }
                }
            }
            let analysis = RecordingAnalyzer.analyze(steps, windowBundleIDs: haveWindows, appNames: names)
            windows = windows.filter { analysis.layoutBundleIDs.contains($0.app.bundleID ?? "") }
            analyzing = false
            pendingRecording = PendingRecording(analysis: analysis, windows: windows, displayNames: displayNames,
                                                skippedSecureInput: skipped)
        }
    }


    /// Runs the steps at `indices` as a temporary action through the normal runner; the report is mapped back to
    /// the real step positions. A failed step opens so its error is visible.
    private func runSteps(_ action: ProfileAction, indices: [Int]) {
        guard running == nil, !indices.isEmpty, indices.allSatisfy({ action.steps.indices.contains($0) }) else { return }
        running = action.id
        reports[action.id] = nil
        var copy = action
        copy.enabled = true
        copy.steps = indices.map { action.steps[$0] }
        if indices.count != action.steps.count { copy.delayBefore = 0 }
        Task {
            let runner = ActionRunner(ax: SystemAXProvider(), process: SystemProcessRunner())
            var report = await runner.run(copy)
            for i in report.steps.indices { report.steps[i].index = indices[report.steps[i].index] }
            reports[action.id] = report
            let failed = report.steps.filter { $0.status == .failed }.map(\.index)
            if !failed.isEmpty { expandedSteps[action.id, default: []].formUnion(failed) }
            running = nil
        }
    }

    private func reportSummary(_ report: ActionRunReport, total: Int) -> some View {
        let ran = report.steps.filter { $0.status == .succeeded || $0.status == .failed }.count
        var text = "\(ran) of \(total) step\(total == 1 ? "" : "s") ran"
        if let failed = report.steps.first(where: { $0.status == .failed }) {
            text += " — failed at step \(failed.index + 1)"
        } else if report.cancelled {
            text += " — cancelled"
        } else {
            text += " in \(String(format: "%.1f", report.duration)) s"
        }
        return InspectorNote(text: text, tone: report.succeeded ? .info : .warning)
            .padding(.top, Spacing.xs)
            .accessibilityLabel("Test run report: \(text)")
    }
}

// MARK: - Step kinds

/// The kinds of step the "Add Step" menu offers, each with a sensible empty step.
enum StepKind: String, CaseIterable, Identifiable {
    case launchApp, press, menu, typeText, key, shell, terminalCommand, openURL, runShortcut, waitFor, delay
    var id: String { rawValue }

    var title: String {
        switch self {
        case .launchApp: "Open App"
        case .press: "Press Button"
        case .menu: "Choose Menu Item"
        case .typeText: "Type Text"
        case .key: "Press Keys"
        case .shell: "Run Terminal Command"
        case .terminalCommand: "Run in Terminal"
        case .openURL: "Open URL"
        case .runShortcut: "Run Shortcut"
        case .waitFor: "Wait for Element"
        case .delay: "Wait"
        }
    }

    func makeStep() -> ActionStep {
        let locator = ElementLocator(bundleID: "", path: [ElementMatcher(role: "AXButton", title: "")])
        switch self {
        case .launchApp: return .launchApp(bundleID: "")
        case .press: return .press(locator: locator)
        case .menu: return .menu(bundleID: "", path: [""])
        case .typeText: return .typeText(text: "")
        case .key: return .key(combo: "cmd+t")
        case .shell: return .shell(command: "")
        case .terminalCommand: return .terminalCommand(command: "")
        case .openURL: return .openURL(url: "https://")
        case .runShortcut: return .runShortcut(name: "")
        case .waitFor: return .waitFor(locator: locator)
        case .delay: return .delay(seconds: 1)
        }
    }
}
