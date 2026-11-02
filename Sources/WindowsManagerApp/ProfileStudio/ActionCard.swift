import SwiftUI
import WMCore

/// One action as a collapsible card. The header always shows chevron, enable toggle, name, Before/After badge,
/// step count and the last test result; the expanded card adds the action's settings and its `content` (steps).
struct ActionCard<Content: View>: View {
    let action: ProfileAction
    let isExpanded: Bool
    let isEditable: Bool
    /// nil = not tested yet, true = the last test run passed, false = it failed.
    let lastResult: Bool?
    let toggleExpanded: () -> Void
    let update: (@escaping (inout ProfileAction) -> Void) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let delete: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            if isExpanded {
                settings
                content()
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay {
            if isExpanded { RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.accent.opacity(0.7), lineWidth: 1) }
        }
        .contextMenu {
            if isEditable {
                Button("Move Up") { move(-1) }.disabled(!canMoveUp)
                Button("Move Down") { move(1) }.disabled(!canMoveDown)
                Divider()
                Button("Delete Action", role: .destructive, action: delete)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(action.name)" : "Expand \(action.name)")
            Toggle("Run \(action.name)", isOn: Binding(
                get: { action.enabled }, set: { value in update { $0.enabled = value } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(!isEditable)
                .help("Run \(action.name) when the profile runs (untick to skip it)")
            Button(action: toggleExpanded) {
                HStack(spacing: Spacing.s) {
                    Text(action.name.isEmpty ? "Untitled action" : action.name).font(.wmCallout).lineLimit(1)
                    StatusBadge(tone: action.phase == .beforeRestore ? .warning : .info,
                                text: action.phase == .beforeRestore ? "Before" : "After")
                        .help(action.phase == .beforeRestore ? "Runs before restoring windows" : "Runs after restoring windows")
                    Spacer(minLength: Spacing.xs)
                    Text("\(action.steps.count) step\(action.steps.count == 1 ? "" : "s")")
                        .font(.wmCaption).foregroundStyle(.secondary)
                    resultDot
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the steps of \(action.name)")
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
        }
        .opacity(action.enabled ? 1 : 0.5)
    }

    @ViewBuilder private var resultDot: some View {
        if let lastResult {
            Circle().fill(lastResult ? Color.green : Palette.danger).frame(width: 8, height: 8)
                .help(lastResult ? "Last test run passed" : "Last test run failed")
                .accessibilityLabel(lastResult ? "Last test passed" : "Last test failed")
        } else {
            Circle().stroke(.quaternary, lineWidth: 1).frame(width: 8, height: 8)
                .help("Not tested yet").accessibilityHidden(true)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if isEditable {
                TextField("Name", text: Binding(get: { action.name }, set: { value in update { $0.name = value } }))
                    .textFieldStyle(.roundedBorder).help("Name of this action")
            }
            LabeledContent("Runs") {
                Picker("Runs", selection: Binding(get: { action.phase }, set: { value in update { $0.phase = value } })) {
                    Text("Before restoring windows").tag(ActionPhase.beforeRestore)
                    Text("After restoring windows").tag(ActionPhase.afterRestore)
                }
                .labelsHidden().fixedSize().disabled(!isEditable)
                .help("Run this action before or after the windows are restored")
            }
            seconds("Wait before", action.delayBefore, help: "Seconds to wait before the first step") { v in update { $0.delayBefore = v } }
            seconds("Pause between steps", action.stepGap, help: "Seconds to pause between steps") { v in update { $0.stepGap = v } }
        }
    }

    private func seconds(_ label: String, _ value: TimeInterval, help: String,
                         _ commit: @escaping (TimeInterval) -> Void) -> some View {
        LabeledContent(label) {
            HStack(spacing: Spacing.xs) {
                TextField(label, value: Binding(get: { value }, set: { commit(max(0, $0)) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56).textFieldStyle(.roundedBorder)
                Text("s").foregroundStyle(.secondary)
            }
        }
        .disabled(!isEditable)
        .help(help)
    }
}
