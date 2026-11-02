import SwiftUI
import WMCore

/// The Actions page of the Details inspector: UI steps a profile runs before or after it restores windows.
/// Lists the actions (name, phase, enabled, step count) and, for the selected one, its steps with fields per
/// step kind. Every change goes through `builder.setActions`, so it is undoable; in View mode (`builder` nil)
/// the list is read only, but "Test run" still works. Plain content: the inspector container scrolls.
struct ProfileActionsPanel: View {
    let profile: Profile
    let builder: ProfileBuilderModel?

    @State private var selectedID: UUID?
    @State private var running: UUID?
    @State private var reports: [UUID: ActionRunReport] = [:]
    @StateObject private var recording = RecordingController()
    @State private var recordNote: String?

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
                    actionRow(index: index, action: action)
                }
                if isEditable {
                    HStack(spacing: Spacing.s) {
                        addActionButton
                        if !actions.contains(where: { $0.id == selectedID }) {
                            Button { startRecording(into: nil) } label: { Label("Record…", systemImage: "record.circle") }
                                .disabled(recording.isRecording)
                                .help("Record clicks and typing in other apps into a new action")
                        }
                    }
                }
            }
            if let action = actions.first(where: { $0.id == selectedID }) {
                stepsSection(action)
            }
            if let recordNote { InspectorNote(text: recordNote) }
            if let error = builder?.lastError { InspectorNote(text: error) }
        }
        .accessibilityLabel("Profile actions")
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

    private func actionRow(index: Int, action: ProfileAction) -> some View {
        let isSelected = selectedID == action.id
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Toggle("Run \(action.name)", isOn: Binding(
                    get: { action.enabled }, set: { value in update(action.id) { $0.enabled = value } }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(!isEditable)
                    .help("Run \(action.name) when the profile runs (untick to skip it)")
                Button { selectedID = isSelected ? nil : action.id } label: {
                    HStack(spacing: Spacing.s) {
                        Text(action.name.isEmpty ? "Untitled action" : action.name).lineLimit(1)
                        Text("\(action.steps.count) step\(action.steps.count == 1 ? "" : "s")")
                            .font(.wmCaption).foregroundStyle(.secondary)
                        Spacer(minLength: Spacing.xs)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the steps of \(action.name)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                if isEditable { moveButtons(index: index, count: actions.count, name: action.name) { move(index, by: $0) } }
            }
            .opacity(action.enabled ? 1 : 0.5)
            if isSelected {
                if isEditable {
                    TextField("Name", text: Binding(get: { action.name }, set: { value in update(action.id) { $0.name = value } }))
                        .textFieldStyle(.roundedBorder).help("Name of this action")
                }
                LabeledContent("Runs") {
                    Picker("Runs", selection: Binding(get: { action.phase }, set: { value in update(action.id) { $0.phase = value } })) {
                        Text("Before restoring windows").tag(ActionPhase.beforeRestore)
                        Text("After restoring windows").tag(ActionPhase.afterRestore)
                    }
                    .labelsHidden().fixedSize().disabled(!isEditable)
                    .help("Run this action before or after the windows are restored")
                }
            } else {
                Text(action.phase == .beforeRestore ? "Before restoring windows" : "After restoring windows")
                    .font(.wmCaption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.accent, lineWidth: 1.5) }
        }
        .contextMenu {
            if isEditable {
                Button("Delete Action", role: .destructive) { delete(action.id) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func moveButtons(index: Int, count: Int, name: String, move: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Button { move(-1) } label: { Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly) }
                .disabled(index == 0).accessibilityLabel("Move \(name) up").help("Move \(name) up")
            Button { move(1) } label: { Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly) }
                .disabled(index == count - 1).accessibilityLabel("Move \(name) down").help("Move \(name) down")
        }
        .buttonStyle(.borderless)
    }

    private func update(_ id: UUID, _ change: (inout ProfileAction) -> Void) {
        var list = actions
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        builder?.setActions(list)
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
        builder?.setActions(actions.filter { $0.id != id })
    }

    // MARK: Steps

    private func stepsSection(_ action: ProfileAction) -> some View {
        InspectorSection(title: "Steps of \(action.name.isEmpty ? "this action" : action.name)") {
            if action.steps.isEmpty {
                Text("No steps yet.").font(.wmCaption).foregroundStyle(.secondary)
            }
            ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                StepEditor(index: index, count: action.steps.count, step: step, isEditable: isEditable,
                           report: reports[action.id]?.steps.first { $0.index == index },
                           change: { new in update(action.id) { $0.steps[index] = new } },
                           move: { delta in update(action.id) { a in
                               let t = index + delta
                               if a.steps.indices.contains(t) { a.steps.swapAt(index, t) }
                           } },
                           remove: { update(action.id) { $0.steps.remove(at: index) } })
            }
            HStack(spacing: Spacing.s) {
                if isEditable {
                    Menu {
                        ForEach(StepKind.allCases) { kind in
                            Button(kind.title) { update(action.id) { $0.steps.append(kind.makeStep()) } }
                        }
                    } label: { Label("Add Step", systemImage: "plus") }
                        .fixedSize().help("Add a step to this action")
                    Button { startRecording(into: action.id) } label: { Label("Record…", systemImage: "record.circle") }
                        .disabled(recording.isRecording)
                        .help("Record clicks and typing in other apps as steps of this action")
                }
                Spacer(minLength: Spacing.xs)
                Button { testRun(action) } label: {
                    if running == action.id { ProgressView().controlSize(.small) } else { Label("Test Run", systemImage: "play") }
                }
                .disabled(running != nil || action.steps.isEmpty)
                .help("Run this action now and show what each step did")
            }
            if let report = reports[action.id] { reportView(report) }
        }
    }

    /// Records into the selected action; `nil` appends to a new "Recorded <date>" action instead.
    private func startRecording(into id: UUID?) {
        recordNote = nil
        let started = recording.start { steps, skipped in finishRecording(steps, skipped: skipped, into: id) }
        if !started { RecordingPermission.showStartFailedAlert() }
    }

    private func finishRecording(_ steps: [ActionStep], skipped: Bool, into id: UUID?) {
        var list = actions
        if steps.isEmpty {
            recordNote = "Nothing was recorded."
        } else if let id, let i = list.firstIndex(where: { $0.id == id }) {
            list[i].steps.append(contentsOf: steps)
            builder?.setActions(list)
        } else {
            let name = "Recorded " + Date.now.formatted(date: .abbreviated, time: .shortened)
            var action = ProfileAction(name: name)
            action.steps = steps
            list.append(action)
            selectedID = action.id
            builder?.setActions(list)
        }
        if skipped {
            let extra = "Text typed into a password field was left out of the recording."
            recordNote = recordNote.map { $0 + " " + extra } ?? extra
        }
    }

    private func testRun(_ action: ProfileAction) {
        running = action.id
        reports[action.id] = nil
        var copy = action
        copy.enabled = true
        Task {
            let runner = ActionRunner(ax: SystemAXProvider(), process: SystemProcessRunner())
            let report = await runner.run(copy)
            reports[action.id] = report
            running = nil
        }
    }

    private func reportView(_ report: ActionRunReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            InspectorNote(text: report.succeeded ? "Test run finished in \(String(format: "%.1f", report.duration)) s."
                          : (report.cancelled ? "Test run was cancelled." : "Test run failed."),
                          tone: report.succeeded ? .info : .warning)
            ForEach(report.steps, id: \.index) { step in
                Text("\(step.index + 1). \(step.summary): \(step.status.rawValue)" + (step.error.map { " (\($0))" } ?? ""))
                    .font(.wmCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Test run report")
    }
}

// MARK: - Step kinds

/// The kinds of step the "Add Step" menu offers, each with a sensible empty step.
enum StepKind: String, CaseIterable, Identifiable {
    case launchApp, press, menu, typeText, key, shell, openURL, runShortcut, waitFor, delay
    var id: String { rawValue }

    var title: String {
        switch self {
        case .launchApp: "Open App"
        case .press: "Press Button"
        case .menu: "Choose Menu Item"
        case .typeText: "Type Text"
        case .key: "Press Keys"
        case .shell: "Run Terminal Command"
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
        case .openURL: return .openURL(url: "https://")
        case .runShortcut: return .runShortcut(name: "")
        case .waitFor: return .waitFor(locator: locator)
        case .delay: return .delay(seconds: 1)
        }
    }
}

/// One step: summary line with order buttons, and fields for its kind.
private struct StepEditor: View {
    let index: Int
    let count: Int
    let step: ActionStep
    let isEditable: Bool
    let report: StepReport?
    let change: (ActionStep) -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    private var inner: ActionStep { step.unwrapped }
    private var isOptional: Bool { step.continueOnFailure }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text("\(index + 1)").font(.wmCaption.monospacedDigit()).foregroundStyle(.secondary)
                Text(kindTitle).lineLimit(1)
                if let report { Image(systemName: icon(report.status)).foregroundStyle(color(report.status)).help(report.error ?? report.status.rawValue) }
                Spacer(minLength: Spacing.xs)
                if isEditable {
                    Button { move(-1) } label: { Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly) }
                        .disabled(index == 0).help("Move step \(index + 1) up")
                    Button { move(1) } label: { Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly) }
                        .disabled(index == count - 1).help("Move step \(index + 1) down")
                    Button(role: .destructive, action: remove) { Label("Delete Step", systemImage: "trash").labelStyle(.iconOnly) }
                        .help("Delete step \(index + 1)")
                }
            }
            .buttonStyle(.borderless)
            fields.disabled(!isEditable)
            if isEditable, inner.supportsOptional {
                Toggle("Continue if this step fails", isOn: Binding(
                    get: { isOptional }, set: { on in change(on ? .optional(step: inner) : inner) }))
                    .toggleStyle(.checkbox).font(.wmCaption)
                    .help("Keep going with the next step when this one fails")
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small))
        .accessibilityElement(children: .contain)
    }

    private func set(_ new: ActionStep) { change(isOptional ? .optional(step: new) : new) }

    private var kindTitle: String {
        switch inner {
        case .launchApp: "Open App"
        case .press: "Press Button"
        case .menu: "Choose Menu Item"
        case .typeText: "Type Text"
        case .key: "Press Keys"
        case .shell: "Run Terminal Command"
        case .openURL: "Open URL"
        case .runShortcut: "Run Shortcut"
        case .waitFor: "Wait for Element"
        case .delay: "Wait"
        case .optional: "Step"
        }
    }

    @ViewBuilder private var fields: some View {
        switch inner {
        case .launchApp(let id):
            text("Bundle ID", id) { set(.launchApp(bundleID: $0)) }
        case .press(let locator, let timeout):
            locatorFields(locator) { set(.press(locator: $0, timeout: timeout)) }
            seconds("Give up after", timeout) { set(.press(locator: locator, timeout: $0)) }
        case .menu(let id, let path):
            text("App bundle ID", id) { set(.menu(bundleID: $0, path: path)) }
            text("Menu path", path.joined(separator: " > ")) { value in
                set(.menu(bundleID: id, path: value.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }))
            }
        case .typeText(let value, let into):
            text("Text", value) { set(.typeText(text: $0, into: into)) }
            if let into { Text("Into: " + describe(into)).font(.wmCaption).foregroundStyle(.secondary) }
        case .key(let combo):
            text("Keys", combo) { set(.key(combo: $0)) }
        case .shell(let command, let wait, let timeout):
            text("Command", command) { set(.shell(command: $0, waitForExit: wait, timeout: timeout)) }
            Toggle("Wait for it to finish", isOn: Binding(
                get: { wait }, set: { set(.shell(command: command, waitForExit: $0, timeout: timeout)) }))
                .toggleStyle(.checkbox).font(.wmCaption).help("Wait for the command to exit before the next step")
            seconds("Give up after", timeout) { set(.shell(command: command, waitForExit: wait, timeout: $0)) }
        case .openURL(let url):
            text("URL", url) { set(.openURL(url: $0)) }
        case .runShortcut(let name):
            text("Shortcut name", name) { set(.runShortcut(name: $0)) }
        case .waitFor(let locator, let containing, let timeout):
            locatorFields(locator) { set(.waitFor(locator: $0, containing: containing, timeout: timeout)) }
            text("Containing", containing ?? "") { set(.waitFor(locator: locator, containing: $0.isEmpty ? nil : $0, timeout: timeout)) }
            seconds("Give up after", timeout) { set(.waitFor(locator: locator, containing: containing, timeout: $0)) }
        case .delay(let s):
            seconds("Wait", s) { set(.delay(seconds: $0)) }
        case .optional:
            EmptyView()
        }
    }

    // The recorder fills in full element paths; here the app and the last element's role and title can be fixed.
    @ViewBuilder private func locatorFields(_ locator: ElementLocator, _ commit: @escaping (ElementLocator) -> Void) -> some View {
        text("App bundle ID", locator.bundleID) { var l = locator; l.bundleID = $0; commit(l) }
        if let last = locator.path.last {
            text("Element title", last.title ?? "") { value in
                var l = locator; l.path[l.path.count - 1].title = value.isEmpty ? nil : value; commit(l)
            }
            if locator.path.count > 1 { Text("Path: " + describe(locator)).font(.wmCaption).foregroundStyle(.secondary) }
        }
    }

    private func describe(_ locator: ElementLocator) -> String {
        locator.path.map { $0.title ?? $0.identifier ?? $0.description ?? $0.role }.joined(separator: " > ")
    }

    private func text(_ label: String, _ value: String, _ commit: @escaping (String) -> Void) -> some View {
        LabeledContent(label) {
            TextField(label, text: Binding(get: { value }, set: commit))
                .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
        }
    }

    private func seconds(_ label: String, _ value: TimeInterval, _ commit: @escaping (TimeInterval) -> Void) -> some View {
        LabeledContent(label) {
            HStack(spacing: Spacing.xs) {
                TextField(label, value: Binding(get: { value }, set: { commit(max(0, $0)) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56).textFieldStyle(.roundedBorder)
                Text("s").foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ s: StepStatus) -> String {
        switch s {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped, .cancelled: "minus.circle"
        }
    }

    private func color(_ s: StepStatus) -> Color {
        switch s {
        case .succeeded: Tone.info.color
        case .failed: Tone.warning.color
        case .skipped, .cancelled: .secondary
        }
    }
}

private extension ActionStep {
    /// Waiting for something or pausing has nothing to "fail past", the other kinds do.
    var supportsOptional: Bool {
        if case .delay = self { return false }
        return true
    }
}
