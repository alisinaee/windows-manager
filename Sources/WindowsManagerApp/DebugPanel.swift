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
            Text("Debug Tests").font(.wmSection)
            Spacer(minLength: 8)
            Button("Install Fixture Profiles") { model.installFixtures() }
                .disabled(model.isBusy)
            Button("Copy Result") { model.copyResult() }
                .disabled(model.results.isEmpty)
            Button("Run All") { model.runAll() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .wmGlass(.regular, in: Capsule())
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
                                Text(scenario.title).font(.wmCallout)
                                Text(scenario.summary)
                                    .font(.wmFootnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if let status = model.lastStatus[scenario.id] {
                                badge(status)
                            } else {
                                pill("Not run", color: .secondary)
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
                        Text(focus.title).font(.wmSection)
                        Spacer(minLength: 4)
                        if let status = model.lastStatus[focus.id] { badge(status) }
                    }
                    HStack(spacing: 6) {
                        if model.running == focus.id {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.phase.isEmpty ? "Idle" : model.phase)
                            .font(.wmFootnote).foregroundStyle(.secondary)
                    }

                    if !model.steps.isEmpty {
                        Text("Steps").font(.wmSection)
                        ForEach(model.steps) { step in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: Self.icon(step.status))
                                    .foregroundStyle(Self.color(step.status))
                                    .frame(width: 14)
                                Text("\(String(describing: step.kind))")
                                    .font(.wmMonoFootnote)
                                Text(step.target)
                                    .font(.wmFootnote).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(step.detail)
                                    .font(.wmFootnote).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }

                    if !model.logLines.isEmpty {
                        Text("Log").font(.wmSection)
                        Text(model.logLines.suffix(40).joined(separator: "\n"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !model.checks.isEmpty {
                        Text("Checks").font(.wmSection)
                        ForEach(model.checks) { check in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(check.passed ? Color.green : Color.red)
                                    .frame(width: 14)
                                Text(check.name).font(.wmFootnote)
                                Spacer(minLength: 4)
                                if !check.detail.isEmpty {
                                    Text(check.detail)
                                        .font(.wmFootnote).foregroundStyle(.secondary)
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
                Text(model.fixtureMessage).font(.wmFootnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !model.copyMessage.isEmpty {
                Text(model.copyMessage).font(.wmFootnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.xs)
    }

    private func badge(_ status: DebugRunStatus) -> some View {
        switch status {
        case .pass: return pill("Pass", color: Tone.success.color, symbol: "checkmark")
        case .fail: return pill("Fail", color: Tone.danger.color, symbol: "xmark")
        case .inconclusive: return pill("Inconclusive", color: Tone.warning.color, symbol: "questionmark")
        default: return pill(status.rawValue.capitalized, color: .secondary)
        }
    }

    /// Status pill: tinted fill, readable label in both appearances (no white-on-colour).
    private func pill(_ text: String, color: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.wmCaption.bold())
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 2)
        .foregroundStyle(color == .secondary ? Color.secondary : Color.primary)
        .background(color.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.5))
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
