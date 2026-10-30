import SwiftUI
import WMCore

/// The Debug window: fixture install, one Run button per live scenario, and the live step and check list of the focused run.
struct DebugPanel: View {
    @ObservedObject var model: DebugPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView { scenarioList }
                .frame(minHeight: 120, maxHeight: .infinity)
            Divider()
            liveSection
            footer
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 420, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Debug tests").font(.headline)
            Spacer(minLength: 8)
            Button("Install fixture profiles") { model.installFixtures() }
                .disabled(model.isBusy)
            Button("Run all") { model.runAll() }
                .disabled(model.isBusy)
        }
    }

    private var scenarioList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(DebugRunnerRegistry.entries) { scenario in
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        model.focus = scenario.id
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(scenario.title).fontWeight(.medium)
                                Text(scenario.summary)
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if let status = model.lastStatus[scenario.id] {
                                badge(status)
                            } else {
                                Text("not run").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button("Run") { model.run(scenario) }
                        .disabled(model.isBusy)
                        .accessibilityLabel("Run \(scenario.title)")
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(model.focus == scenario.id ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            }
        }
    }

    @ViewBuilder private var liveSection: some View {
        if let focusID = model.focus, let focus = DebugRunnerRegistry.entry(id: focusID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(focus.title).font(.subheadline).fontWeight(.semibold)
                        Spacer(minLength: 4)
                        if let status = model.lastStatus[focus.id] { badge(status) }
                    }
                    HStack(spacing: 6) {
                        if model.running == focus.id {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.phase.isEmpty ? "Idle" : model.phase)
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    if !model.steps.isEmpty {
                        Text("Steps").font(.footnote).fontWeight(.semibold)
                        ForEach(model.steps) { step in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: Self.icon(step.status))
                                    .foregroundStyle(Self.color(step.status))
                                    .frame(width: 14)
                                Text("\(String(describing: step.kind))")
                                    .font(.footnote.monospaced())
                                Text(step.target)
                                    .font(.footnote).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(step.detail)
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }

                    if !model.logLines.isEmpty {
                        Text("Log").font(.footnote).fontWeight(.semibold)
                        Text(model.logLines.suffix(40).joined(separator: "\n"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !model.checks.isEmpty {
                        Text("Checks").font(.footnote).fontWeight(.semibold)
                        ForEach(model.checks) { check in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(check.passed ? Color.green : Color.red)
                                    .frame(width: 14)
                                Text(check.name).font(.footnote)
                                Spacer(minLength: 4)
                                if !check.detail.isEmpty {
                                    Text(check.detail)
                                        .font(.footnote).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.fixtureMessage.isEmpty {
                Text(model.fixtureMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !model.copyMessage.isEmpty {
                Text(model.copyMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Copy result") { model.copyResult() }
                .disabled(model.results.isEmpty)
        }
    }

    private func badge(_ status: DebugRunStatus) -> some View {
        let color: Color = status == .pass ? .green : status == .fail ? .red : status == .inconclusive ? .orange : .gray
        return Text(status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Capsule().fill(color))
    }

    private static func icon(_ status: DebugStepStatus) -> String {
        switch status {
        case .pending: return "circle.dashed"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private static func color(_ status: DebugStepStatus) -> Color {
        switch status {
        case .pending, .skipped: return .secondary
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        }
    }
}
