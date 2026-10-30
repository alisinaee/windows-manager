import AppKit
import SwiftUI
import WMCore

/// The three onboarding steps. The current step lives in the model (not in `@State`) so this target
/// keeps building without the SwiftUI macro plugin, like the rest of the app.
enum OnboardingStep: Int, CaseIterable {
    case accessibility, spaces, done

    var title: String {
        switch self {
        case .accessibility: return "Accessibility access"
        case .spaces: return "Desktops and Spaces"
        case .done: return "All set"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "hand.raised.fill"
        case .spaces: return "rectangle.3.group"
        case .done: return "checkmark.seal.fill"
        }
    }
}

/// Holds the current step and a live copy of the system report, refreshed once a second.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .accessibility
    @Published private(set) var report: SystemReport = OnboardingModel.currentReport()

    /// UX capture only (WM_UX_TEST=1, `permission=before|after`): shows the Accessibility step as granted or not.
    /// Display only; the real permission is never touched.
    @MainActor static var uxAccessibilityOverride: Bool?

    private static func currentReport() -> SystemReport {
        var r = SystemChecks.report()
        if let o = uxAccessibilityOverride { r.accessibilityTrusted = o }
        return r
    }

    /// Re-reads Accessibility trust and the Spaces settings. Cheap, read only, never shows a dialog.
    func refresh() {
        let latest = Self.currentReport()
        if latest != report { report = latest }
    }

    func move(by delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        step = next
    }
}

/// First-run setup: Accessibility permission, advice about the Spaces settings, and a summary.
struct OnboardingView: View {
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let desktopAndDockSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!

    /// Called when the user presses Finish on the last step.
    let onFinish: () -> Void

    @StateObject private var model = OnboardingModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.step {
                case .accessibility: accessibilityStep
                case .spaces: spacesStep
                case .done: doneStep
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 540, height: 500)
        // Live re-check: the user flips the switch in System Settings and this window follows.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                model.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.step.title)
                    .font(.title2.bold())
                Text("Step \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.rawValue <= model.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 22, height: 5)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            if model.step != .accessibility {
                Button("Back") { model.move(by: -1) }
            }
            Spacer()
            if model.step == .done {
                Button("Finish") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { model.move(by: 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Next steps on the last page: start the first profile, or just open Profile Studio. Both close this guide first.
    private var nextStepButtons: some View {
        HStack(spacing: Spacing.s) {
            Button("Capture First Profile") {
                onFinish()
                ProfileStudioWindowController.shared.show()
                ProfileStudioWindowController.shared.model.beginNewProfile()
            }
            .buttonStyle(.bordered)
            Button("Open Profile Studio") {
                onFinish()
                ProfileStudioWindowController.shared.show()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Step 1: Accessibility

    private var accessibilityStep: some View {
        Form {
            Section {
                Text("Windows Manager moves and resizes the windows of your other apps. macOS only allows that for apps you have trusted in Privacy & Security > Accessibility.")
                LabeledContent("Status") {
                    StatusLabel(
                        model.report.accessibilityTrusted ? "Allowed" : "Not allowed yet",
                        kind: model.report.accessibilityTrusted ? .good : .warning)
                }
                HStack {
                    Button("Ask macOS") { AXPermission.prompt() }
                        .disabled(model.report.accessibilityTrusted)
                    Button("Open System Settings") { NSWorkspace.shared.open(Self.accessibilitySettingsURL) }
                }
                if !model.report.accessibilityTrusted {
                    Text("This page checks again every second, so it updates as soon as you switch Windows Manager on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                #if DEBUG
                Text("After you rebuild the app, macOS may stop trusting it, because an ad-hoc signature changes with every build. If the switch is on but the status stays \"Not allowed yet\", select Windows Manager in the Accessibility list, remove it with the minus button and add it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #else
                EmptyView()
                #endif
            }
        }
    }

    // MARK: Step 2: Spaces advice

    private var spacesStep: some View {
        Form {
            Section("Desktops") {
                LabeledContent("Rearrange Spaces automatically") {
                    StatusLabel(
                        model.report.autoRearrangeSpaces ? "On" : "Off",
                        kind: model.report.autoRearrangeSpaces ? .warning : .good)
                }
                if model.report.autoRearrangeSpaces {
                    Text("macOS is set to reorder your Desktops by how recently you used them. Desktop numbers then change behind your back, so a profile can send windows to the wrong Desktop. We recommend turning this off.")
                    Button("Open Desktop & Dock Settings") {
                        NSWorkspace.shared.open(Self.desktopAndDockSettingsURL)
                    }
                    Text("Under Mission Control, switch off \"Automatically rearrange Spaces based on most recent use\". Windows Manager never changes this setting itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Your Desktops keep their order, so profiles always find the right one.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Stage Manager") {
                LabeledContent("Stage Manager") {
                    StatusLabel(
                        model.report.stageManagerOn ? "On" : "Off",
                        kind: .good)
                }
                Text(model.report.stageManagerOn
                    ? "Keep Stage Manager on if you like it. Windows Manager works with it and restores your windows inside it."
                    : "Stage Manager is off. Windows Manager works with it on or off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 3: Done

    private var doneStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("You're ready to go")
                .font(.title.bold())
            Text("Windows Manager lives in the menu bar. You can open this guide again any time from the menu with Setup.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            GroupBox {
                VStack(spacing: 0) {
                    summaryRow(
                        "Accessibility",
                        model.report.accessibilityTrusted ? "Allowed" : "Not allowed yet",
                        model.report.accessibilityTrusted ? .good : .warning)
                    Divider().padding(.vertical, 6)
                    summaryRow(
                        "Rearrange Spaces automatically",
                        model.report.autoRearrangeSpaces ? "On" : "Off",
                        model.report.autoRearrangeSpaces ? .warning : .good)
                    Divider().padding(.vertical, 6)
                    summaryRow(
                        "Stage Manager",
                        model.report.stageManagerOn ? "On" : "Off",
                        .good)
                }
                .padding(4)
            }
            .frame(maxWidth: 400)
            if !model.report.accessibilityTrusted {
                Text("Without Accessibility access Windows Manager cannot move windows. Go back to step 1 to allow it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            nextStepButtons
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryRow(_ title: String, _ value: String, _ kind: StatusLabel.Kind) -> some View {
        HStack {
            Text(title)
            Spacer()
            StatusLabel(value, kind: kind)
        }
    }
}

/// A short status with a colored SF Symbol, readable in light and dark appearance.
private struct StatusLabel: View {
    enum Kind { case good, warning }

    let text: String
    let kind: Kind

    init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: kind == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(kind == .good ? Color.green : Color.orange)
        }
    }
}
