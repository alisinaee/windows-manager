import SwiftUI
import WMCore

/// One step of an action: a single summary line (index, icon, summary, test result) that expands to the fields of
/// its kind. Drag the line to reorder; the context menu runs, duplicates, moves or deletes it.
struct ActionStepRow: View {
    let actionID: UUID
    let index: Int
    let count: Int
    let step: ActionStep
    let isEditable: Bool
    let canRun: Bool
    let report: StepReport?
    let isExpanded: Bool
    let toggle: () -> Void
    let change: (ActionStep) -> Void
    let move: (Int) -> Void
    /// (from, to): the step at `from` was dropped on this row.
    let moveTo: (Int, Int) -> Void
    let remove: () -> Void
    let duplicate: () -> Void
    let addDelayAfter: () -> Void
    let runOnly: () -> Void
    let runUpToHere: () -> Void

    @State private var advancedOpen = false
    @State private var dropTargeted = false

    private var inner: ActionStep { step.unwrapped }
    private var isOptional: Bool { step.continueOnFailure }
    private var isDelay: Bool { if case .delay = inner { return true } else { return false } }
    private var failedMessage: String? { report?.status == .failed ? (report?.error ?? "The step failed.") : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            header
            if let failedMessage {
                Label(failedMessage, systemImage: "xmark.circle.fill")
                    .font(.wmCaption).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
                    .accessibilityLabel("Step \(index + 1) failed: \(failedMessage)")
            }
            if isExpanded && !isDelay {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    fields.disabled(!isEditable)
                    if isEditable, inner.rowSupportsOptional {
                        Toggle("Continue if this step fails", isOn: Binding(
                            get: { isOptional }, set: { on in change(on ? .optional(step: inner) : inner) }))
                            .toggleStyle(.checkbox).font(.wmCaption)
                            .help("Keep going with the next step when this one fails")
                    }
                }
                .padding(.leading, 26).padding(.top, Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.s).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(isExpanded ? 0.7 : 0.4), in: RoundedRectangle(cornerRadius: Radius.small))
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: Radius.small).stroke(Palette.accent, lineWidth: 1.5) }
        }
        .dropDestination(for: String.self, action: { items, _ in
            guard isEditable, let payload = items.first else { return false }
            let parts = payload.split(separator: "|")
            guard parts.count == 3, parts[0] == "wmstep", parts[1] == actionID.uuidString, let from = Int(parts[2]) else { return false }
            moveTo(from, index)
            return true
        }, isTargeted: { dropTargeted = $0 })
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Image(systemName: StepSummary.of(step).symbol)
                .frame(width: 16).foregroundStyle(Palette.accent)
            if case .delay(let s) = inner {
                Text("Wait").lineLimit(1)
                Stepper(value: Binding(get: { s }, set: { change(isOptional ? .optional(step: .delay(seconds: max(0, $0))) : .delay(seconds: max(0, $0))) }),
                        in: 0...3600, step: 0.5) {
                    Text(StepSummary.seconds(s)).font(.wmCaption.monospacedDigit())
                }
                .disabled(!isEditable)
                Spacer(minLength: Spacing.xs)
            } else {
                Text(StepSummary.of(step).summary).lineLimit(1).truncationMode(.tail)
                    .help(StepSummary.of(step).summary)
                if isOptional {
                    Image(systemName: "arrow.uturn.forward").font(.wmCaption).foregroundStyle(.secondary)
                        .help("Continues if this step fails")
                }
                Spacer(minLength: Spacing.xs)
            }
            if let report { resultBadge(report) }
            if !isDelay {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isDelay { toggle() } }
        .draggable("wmstep|\(actionID.uuidString)|\(index)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index + 1): \(StepSummary.of(step).summary)")
        .accessibilityAddTraits(.isButton)
    }

    private func resultBadge(_ r: StepReport) -> some View {
        HStack(spacing: 3) {
            switch r.status {
            case .succeeded: Image(systemName: "checkmark").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark").foregroundStyle(Palette.danger)
            case .skipped, .cancelled: Image(systemName: "minus").foregroundStyle(.secondary)
            }
            if r.status != .skipped && r.status != .cancelled {
                Text(String(format: "%.1f s", r.duration)).foregroundStyle(.secondary)
            } else {
                Text("skipped").foregroundStyle(.secondary)
            }
        }
        .font(.wmCaption.monospacedDigit().weight(.medium))
        .help(r.error ?? r.status.rawValue)
    }

    @ViewBuilder private var menu: some View {
        Button("Run Only This Step", action: runOnly).disabled(!canRun)
        Button("Run Up to Here", action: runUpToHere).disabled(!canRun)
        if isEditable {
            Divider()
            Button("Duplicate", action: duplicate)
            Button("Add Delay After", action: addDelayAfter)
            Divider()
            Button("Move Up") { move(-1) }.disabled(index == 0)
            Button("Move Down") { move(1) }.disabled(index == count - 1)
            Divider()
            Button("Delete", role: .destructive, action: remove)
        }
    }

    // MARK: Fields

    private func set(_ new: ActionStep) { change(isOptional ? .optional(step: new) : new) }

    @ViewBuilder private var fields: some View {
        switch inner {
        case .launchApp(let id):
            text("Bundle ID", id) { set(.launchApp(bundleID: $0)) }
        case .press(let locator, let timeout, let skip):
            locatorBasics(locator) { set(.press(locator: $0, timeout: timeout, skipIfShowing: skip)) }
            seconds("Give up after", timeout) { set(.press(locator: locator, timeout: $0, skipIfShowing: skip)) }
            advanced {
                locatorAdvanced(locator) { set(.press(locator: $0, timeout: timeout, skipIfShowing: skip)) }
                matchPicker(locator) { set(.press(locator: $0, timeout: timeout, skipIfShowing: skip)) }
                skipFields(skip) { set(.press(locator: locator, timeout: timeout, skipIfShowing: $0)) }
            }
        case .menu(let id, let path):
            text("App bundle ID", id) { set(.menu(bundleID: $0, path: path)) }
            text("Menu path", path.joined(separator: " > ")) { value in
                set(.menu(bundleID: id, path: value.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }))
            }
        case .typeText(let value, let into):
            text("Text", value) { set(.typeText(text: $0, into: into)) }
            if let into {
                locatorBasics(into) { set(.typeText(text: value, into: $0)) }
                advanced { locatorAdvanced(into) { set(.typeText(text: value, into: $0)) } }
            }
        case .key(let combo):
            text("Keys", combo) { set(.key(combo: $0)) }
        case .shell(let command, let wait, let timeout):
            text("Command", command) { set(.shell(command: $0, waitForExit: wait, timeout: timeout)) }
            Toggle("Wait for it to finish", isOn: Binding(
                get: { wait }, set: { set(.shell(command: command, waitForExit: $0, timeout: timeout)) }))
                .toggleStyle(.checkbox).font(.wmCaption).help("Wait for the command to exit before the next step")
            seconds("Give up after", timeout) { set(.shell(command: command, waitForExit: wait, timeout: $0)) }
        case .terminalCommand(let command, let app, let newWindow):
            text("Command", command) { set(.terminalCommand(command: $0, app: app, newWindow: newWindow)) }
            LabeledContent("App") {
                Picker("App", selection: Binding(
                    get: { app }, set: { set(.terminalCommand(command: command, app: $0, newWindow: newWindow)) })) {
                    Text("Terminal").tag(TerminalApp.terminal)
                    Text("iTerm2").tag(TerminalApp.iTerm)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            Toggle("New window", isOn: Binding(
                get: { newWindow }, set: { set(.terminalCommand(command: command, app: app, newWindow: $0)) }))
                .toggleStyle(.checkbox).font(.wmCaption)
                .help("Open a new window instead of using the front one")
        case .openURL(let url):
            text("URL", url) { set(.openURL(url: $0)) }
        case .runShortcut(let name):
            text("Shortcut name", name) { set(.runShortcut(name: $0)) }
        case .waitFor(let locator, let containing, let timeout):
            locatorBasics(locator) { set(.waitFor(locator: $0, containing: containing, timeout: timeout)) }
            text("Containing", containing ?? "") { set(.waitFor(locator: locator, containing: $0.isEmpty ? nil : $0, timeout: timeout)) }
            seconds("Give up after", timeout) { set(.waitFor(locator: locator, containing: containing, timeout: $0)) }
            advanced {
                locatorAdvanced(locator) { set(.waitFor(locator: $0, containing: containing, timeout: timeout)) }
                matchPicker(locator) { set(.waitFor(locator: $0, containing: containing, timeout: timeout)) }
            }
        case .delay, .optional:
            EmptyView()
        }
    }

    private func advanced<C: View>(@ViewBuilder _ content: @escaping () -> C) -> some View {
        DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
            VStack(alignment: .leading, spacing: Spacing.xs) { content() }.padding(.top, Spacing.xs)
        }
        .font(.wmCaption)
    }

    /// App, element title and description (description only when set or when there is no title).
    @ViewBuilder private func locatorBasics(_ locator: ElementLocator, _ commit: @escaping (ElementLocator) -> Void) -> some View {
        text("App bundle ID", locator.bundleID) { var l = locator; l.bundleID = $0; commit(l) }
        if let last = locator.path.last {
            let noTitle = (last.title ?? "").isEmpty
            text("Element title", last.title ?? "") { value in
                var l = locator; l.path[l.path.count - 1].title = value.isEmpty ? nil : value; l.path[l.path.count - 1].volatile = nil; commit(l)
            }
            if noTitle || last.description != nil {
                text("Element description", last.description ?? "") { value in
                    var l = locator; l.path[l.path.count - 1].description = value.isEmpty ? nil : value; l.path[l.path.count - 1].volatile = nil; commit(l)
                }
            }
        }
    }

    @ViewBuilder private func locatorAdvanced(_ locator: ElementLocator, _ commit: @escaping (ElementLocator) -> Void) -> some View {
        if locator.path.last != nil {
            text("Element identifier", locator.path.last?.identifier ?? "") { value in
                var l = locator; l.path[l.path.count - 1].identifier = value.isEmpty ? nil : value; commit(l)
            }
            if locator.path.count > 1 {
                Text("Path: " + locator.path.map { $0.title ?? $0.identifier ?? $0.description ?? $0.role }.joined(separator: " > "))
                    .font(.wmCaption).foregroundStyle(.secondary)
            }
        }
    }

    /// Label first, or the recorded position first (for buttons whose label changes with the app's state).
    @ViewBuilder private func matchPicker(_ locator: ElementLocator, _ commit: @escaping (ElementLocator) -> Void) -> some View {
        LabeledContent("Match") {
            Picker("Match", selection: Binding(
                get: { locator.structuralFirst ? MatchPreference.position : .label },
                set: { var l = locator; l.match = $0; commit(l) })) {
                Text("By label").tag(MatchPreference.label)
                Text("By position").tag(MatchPreference.position)
            }
            .labelsHidden().pickerStyle(.segmented)
            .help("By position finds the element by where it sits in the window, for buttons whose label changes")
        }
    }

    /// "Skip if showing": the press is skipped when this element is already on screen.
    @ViewBuilder private func skipFields(_ skip: ElementLocator?, _ commit: @escaping (ElementLocator?) -> Void) -> some View {
        let bundle = inner.rowLocatorBundleID
        LabeledContent("Skip if showing") {
            Toggle("", isOn: Binding(
                get: { skip != nil },
                set: { commit($0 ? ElementLocator(bundleID: bundle, path: [ElementMatcher(role: "AXStaticText", title: "")]) : nil) }))
                .labelsHidden().toggleStyle(.checkbox)
                .help("Skip this press when the element below is already visible, for example Connected")
        }
        if let skip, let last = skip.path.last {
            text("Showing role", last.role) { var l = skip; l.path[l.path.count - 1].role = $0; commit(l) }
            text("Showing title", last.title ?? "") { var l = skip; l.path[l.path.count - 1].title = $0.isEmpty ? nil : $0; commit(l) }
            text("Showing description", last.description ?? "") {
                var l = skip; l.path[l.path.count - 1].description = $0.isEmpty ? nil : $0; commit(l)
            }
        }
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
}

/// Thin divider row between two steps showing the action's pause between steps; click to change it.
struct StepGapRow: View {
    let seconds: TimeInterval
    let isEditable: Bool
    let commit: (TimeInterval) -> Void
    @State private var editing = false

    var body: some View {
        Button { if isEditable { editing = true } } label: {
            HStack(spacing: Spacing.xs) {
                line
                Label(StepSummary.seconds(seconds), systemImage: "timer")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                line
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isEditable ? "Pause between steps. Click to change it for every step of this action" : "Pause between steps")
        .popover(isPresented: $editing) {
            HStack(spacing: Spacing.s) {
                Text("Pause between steps")
                TextField("Seconds", value: Binding(get: { seconds }, set: { commit(max(0, $0)) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.trailing).frame(width: 56).textFieldStyle(.roundedBorder)
                Text("s").foregroundStyle(.secondary)
            }
            .padding(Spacing.m)
        }
        .accessibilityLabel("Pause between steps \(StepSummary.seconds(seconds))")
    }

    private var line: some View {
        Rectangle().fill(.quaternary).frame(height: 1)
    }
}

private extension ActionStep {
    /// Waiting for something or pausing has nothing to "fail past", the other kinds do.
    var rowSupportsOptional: Bool {
        if case .delay = self { return false }
        return true
    }

    /// The app of the step's own locator, used to seed a new "skip if showing" element.
    var rowLocatorBundleID: String {
        if case .press(let l, _, _) = unwrapped { return l.bundleID }
        return ""
    }
}
