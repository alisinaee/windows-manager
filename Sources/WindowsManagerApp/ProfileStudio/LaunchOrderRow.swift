import SwiftUI
import WMCore

/// One app of the launch order: enable box, name, hover chevrons, and its wait, delay and timeout. The wait and the
/// delay only exist in sequential mode; in "At once" mode they are not shown because the engine ignores them.
struct LaunchOrderRow: View {
    let index: Int
    let count: Int
    let item: LaunchItem
    let mode: LaunchPlan.Mode
    let issues: [LaunchIssue]
    let isSelected: Bool
    /// Edits are applied through the host (View mode passes false and the row is read only).
    let isEditable: Bool
    let onSelect: () -> Void
    let commit: ((LaunchPlan) -> LaunchPlan) -> Void
    let move: (Int) -> Void
    /// Another row was dropped on this one: its item id.
    let drop: (String) -> Void

    @State private var isHovering = false
    @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 52

    private var timeout: TimeInterval { item.timeout ?? LaunchOptions.defaultTimeout }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            VStack(alignment: .leading, spacing: Spacing.s) {
                if mode == .sequential {
                    if item.withoutWindows {
                        Text("Waits until the app is ready").font(.wmCaption).foregroundStyle(.secondary)
                    } else {
                        waitRow
                    }
                    delayRow
                }
                timeoutRow
            }
            .disabled(!isEditable)
            .opacity(item.enabled ? 1 : 0.5)
            ForEach(issues, id: \.message) { issue in
                InspectorNote(text: issue.message, tone: .warning)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.accent, lineWidth: 1.5) }
        }
        .onHover { isHovering = $0 }
        .draggable(item.id)
        .dropDestination(for: String.self) { ids, _ in
            guard isEditable, let id = ids.first, id != item.id else { return false }
            drop(id)
            return true
        }
        .contextMenu {
            if item.timeout != nil {
                Button("Use Default Timeout") { commit { LaunchSequence.settingTimeout($0, id: item.id, nil) } }
                    .help("Use the default timeout for \(item.app.name)")
            }
            if item.withoutWindows {
                Button("Remove from Launch Order", role: .destructive) {
                    commit { var p = $0; p.items.removeAll { $0.id == item.id }; return p }
                }
                .help("Remove this launch-only app from the order")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { move(-1) }
        .accessibilityAction(named: "Move down") { move(1) }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Toggle("Launch \(item.app.name)", isOn: Binding(
                get: { item.enabled },
                set: { _ in commit { LaunchSequence.toggled($0, id: item.id) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!isEditable)
                .help("Launch \(item.app.name) when the profile runs (untick to skip it)")
            Button(action: onSelect) {
                HStack(spacing: Spacing.s) {
                    Text("\(index + 1)").font(.wmCaption.monospacedDigit()).foregroundStyle(.secondary)
                    Image(nsImage: AppIconCache.icon(for: item.app)).resizable().frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(item.app.name).lineLimit(1)
                    if item.withoutWindows { Text("launch only").font(.wmCaption).foregroundStyle(.secondary) }
                    Spacer(minLength: Spacing.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select \(item.app.name); Command-Option-Up and -Down move the selected app")
            .accessibilityLabel("\(item.app.name), \(index + 1) of \(count)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color)
                    .help(issues.map(\.message).joined(separator: "\n"))
                    .accessibilityLabel("Problem: " + issues.map(\.message).joined(separator: " "))
            }
            if isEditable {
                HStack(spacing: 0) {
                    Button { move(-1) } label: { Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly) }
                        .disabled(index == 0)
                        .accessibilityLabel("Move \(item.app.name) up")
                        .help("Move \(item.app.name) up in the launch order")
                    Button { move(1) } label: { Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly) }
                        .disabled(index == count - 1)
                        .accessibilityLabel("Move \(item.app.name) down")
                        .help("Move \(item.app.name) down in the launch order")
                }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0)
            }
        }
    }

    private var waitRow: some View {
        LabeledContent("Wait for") {
            Picker("Wait for", selection: Binding(
                get: { item.wait },
                set: { wait in commit { LaunchSequence.settingWait($0, id: item.id, wait) } })) {
                Text("First window").tag(LaunchWait.windows)
                Text("App ready").tag(LaunchWait.appReady)
            }
            .labelsHidden()
            .fixedSize()
            .help("Wait for the first window, or until the app is ready")
        }
    }

    private var delayRow: some View {
        LabeledContent("Delay after") {
            secondsField(value: Binding(
                get: { item.delayAfter },
                set: { value in commit { LaunchSequence.settingDelay($0, id: item.id, value) } }),
                         range: LaunchItem.delayRange, step: 1, label: "Delay after \(item.app.name)")
                .help("Seconds to wait after this app before the next one")
        }
    }

    private var timeoutRow: some View {
        LabeledContent("Give up after") {
            secondsField(value: Binding(
                get: { timeout },
                set: { value in commit { LaunchSequence.settingTimeout($0, id: item.id, value) } }),
                         range: LaunchItem.timeoutRange, step: 5, label: "Timeout for \(item.app.name)")
                .foregroundStyle(item.timeout == nil ? .secondary : .primary)
                .help(item.timeout == nil
                      ? "Longest wait for \(item.app.name) before moving on (default)"
                      : "Longest wait for \(item.app.name) before moving on")
        }
    }

    /// A typed number of seconds with a stepper.
    private func secondsField(value: Binding<TimeInterval>, range: ClosedRange<TimeInterval>, step: TimeInterval,
                              label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
                .textFieldStyle(.roundedBorder)
            Text("s").foregroundStyle(.secondary)
            Stepper(label, value: value, in: range, step: step)
                .labelsHidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
