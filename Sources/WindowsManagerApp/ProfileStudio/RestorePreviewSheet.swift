import SwiftUI
import WMCore

// B3 of docs/PLAN-profile-maps.md: the dry-run plan of a restore, in plain language. Only a scan runs here
// (`RestoreEngine.preview`); nothing is launched, moved or hidden until the person presses "Run now".

// MARK: - Plain-language text

/// Words for plan steps, shared by the sheet and the inspector.
enum RestoreStepText {
    /// `Safari "Inbox"`.
    static func label(_ target: RestoreTarget) -> String {
        quoted(target.app.name, target.title)
    }

    static func quoted(_ name: String, _ title: String?) -> String {
        guard let title, !title.isEmpty else { return name }
        let flat = title.replacingOccurrences(of: "\n", with: " ")
        return "\(name) \"\(flat.count > 40 ? String(flat.prefix(39)) + "\u{2026}" : flat)\""
    }

    static func size(_ frame: CGRect) -> String {
        "\(Int(frame.width.rounded())) \u{00D7} \(Int(frame.height.rounded()))"
    }

    /// One step as a sentence fragment ("Move Safari "Inbox" to Desktop 2 on DELL").
    static func text(_ step: RestoreStep) -> String {
        switch step {
        case .launch(let app, let count):
            return count > 0 ? "Open \(app.name), wait for \(count) window\(count == 1 ? "" : "s")" : "Open \(app.name)"
        case .exitFullScreen(let t):
            return "Leave full screen: \(label(t))"
        case .unminimize(let t):
            return "Unminimize \(label(t))"
        case .addDesktop(let display, let count):
            return "Add \(count) Desktop\(count == 1 ? "" : "s") to \(display.name)"
        case .moveToDesktop(let t, let desktop, _, let display, _, _):
            return "Move \(label(t)) to Desktop \(desktop) on \(display)"
        case .setFrame(let t, let frame, _, let beforeFullScreen):
            if beforeFullScreen { return "Move \(label(t)) to the right monitor, before full screen" }
            return "Place \(label(t)) at \(size(frame)), position \(Int(frame.minX.rounded())), \(Int(frame.minY.rounded()))"
        case .enterFullScreen(let t, _, let display, _):
            return "Make \(label(t)) full screen on \(display)"
        case .minimize(let t):
            return "Minimize \(label(t))"
        case .raise(let t, _):
            return "Bring \(label(t)) to the front"
        case .hideApp(let app, _):
            return "Hide \(app.name)"
        case .needsConfirmationQuit(let app, _):
            return "Ask before quitting \(app.name)"
        }
    }

    /// The heading of a phase group.
    static func heading(_ phase: RestorePhase) -> String {
        switch phase {
        case .launch: return "Launch apps"
        case .exitFullScreen: return "Leave full screen"
        case .unminimize: return "Unminimize"
        case .addDesktop: return "Add Desktops"
        case .moveToDesktop: return "Move to Desktops"
        case .setFrame: return "Place windows"
        case .enterFullScreen: return "Full screen"
        case .minimize: return "Minimize"
        case .raise: return "Bring to front"
        case .otherApps: return "Hide other apps"
        }
    }

    /// "8 in place, 4 will move, 2 apps will launch, 1 not found", or "Nothing to restore".
    static func summaryLine(_ s: ProfileLiveSummary) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var parts: [String] = []
        if s.inPlace > 0 { parts.append("\(s.inPlace) in place") }
        if s.willMove > 0 { parts.append("\(s.willMove) will move") }
        if s.appsToLaunch > 0 { parts.append(n(s.appsToLaunch, "app will launch", "apps will launch")) }
        if s.notFound > 0 { parts.append("\(s.notFound) not found") }
        if s.mayBeParked > 0 { parts.append("\(s.mayBeParked) may be in the Stage Manager strip") }
        if s.notRestored > 0 { parts.append("\(s.notRestored) not restored") }
        if s.missingDesktops > 0 { parts.append(n(s.missingDesktops, "Desktop missing", "Desktops missing")) }
        return parts.isEmpty ? "Nothing to restore" : parts.joined(separator: ", ")
    }

    static func sameApp(_ a: AppRef, _ b: AppRef) -> Bool {
        if let x = a.bundleID, let y = b.bundleID { return x.caseInsensitiveCompare(y) == .orderedSame }
        return a.name.caseInsensitiveCompare(b.name) == .orderedSame
    }
}

// MARK: - Run controls

/// Why Run cannot start now, or nil.
@MainActor func studioRunBlockReason(_ app: AppState) -> String? {
    if !app.isAccessibilityTrusted { return "Accessibility is not allowed yet" }
    if app.status.isBusy { return "Busy: another action is running" }
    return nil
}

/// A Run button that follows `AppState` (Accessibility, busy).
struct RunProfileButton: View {
    @ObservedObject var app: AppState
    let profileID: UUID
    let profileName: String
    var title = "Run"

    var body: some View {
        Button { app.run(id: profileID) } label: { Label(title, systemImage: "play.fill") }
            .disabled(!app.canAct)
            .help(studioRunBlockReason(app) ?? "Restore \(profileName) now")
            .accessibilityLabel("\(title) profile \(profileName)")
    }
}

/// The busy / failed / done line of `AppState.status`, or the reason Run is blocked.
struct RunStatusLine: View {
    @ObservedObject var app: AppState

    var body: some View {
        switch app.status {
        case .running(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).lineLimit(1)
            }
            .font(.callout).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Running: \(text)")
        case .failure(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange).lineLimit(2)
                .accessibilityLabel("Failed: \(text)")
        case .success(let text):
            Label(text, systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .accessibilityLabel("Done: \(text)")
        case .idle:
            if let reason = studioRunBlockReason(app) {
                Label(reason, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Model

@MainActor
final class RestorePreviewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let profileID: UUID
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var profile: Profile?
    @Published private(set) var plan: RestorePlan?
    @Published private(set) var summary = ProfileLiveSummary()
    /// Phases the person opened or closed; the rest follow the "collapsed when more than 6 steps" default.
    @Published var expansion: [RestorePhase: Bool] = [:]
    private var task: Task<Void, Never>?

    let scope: RestoreScope
    @Published private(set) var isRunning = false
    @Published private(set) var runResult: String?

    init(profileID: UUID, scope: RestoreScope = .whole) { self.profileID = profileID; self.scope = scope }

    /// Runs only the scoped part (the whole profile goes through `AppState.run`).
    func runScoped() {
        guard let profile, !isRunning else { return }
        isRunning = true; runResult = nil
        let scope = scope
        Task { [weak self] in
            let report = await RestoreEngine().run(profile, scope: scope)
            self?.runResult = report.summary
            self?.isRunning = false
        }
    }

    func isExpanded(_ phase: RestorePhase, count: Int) -> Bool { expansion[phase] ?? (count <= 6) }

    func cancel() { task?.cancel(); task = nil }

    /// Scans the Mac and plans. Nothing else happens: `RestoreEngine.preview` never acts.
    func load() {
        task?.cancel()
        guard let app = AppState.current else {
            phase = .failed("The app is not ready yet.")
            return
        }
        guard app.isAccessibilityTrusted else {
            phase = .failed("Accessibility is not allowed yet, so the preview cannot read your windows. Allow it in System Settings > Privacy & Security > Accessibility.")
            return
        }
        phase = .loading
        let store = app.store
        let id = profileID
        task = Task { [weak self] in
            do {
                let profile = try await Task.detached(priority: .userInitiated) { try store.load(id) }.value
                guard !Task.isCancelled else { return }
                let plan = await RestoreEngine().preview(profile: profile, scope: scope)
                guard !Task.isCancelled, let self else { return }
                self.profile = profile
                self.plan = plan
                self.summary = ProfileLiveStatus(profile: profile, plan: plan).summary
                self.phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed("Could not preview: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Sheet

struct RestorePreviewSheet: View {
    let profileID: UUID
    let profileName: String
    let scope: RestoreScope
    var onClose: () -> Void
    @StateObject private var model: RestorePreviewModel

    init(profileID: UUID, profileName: String, scope: RestoreScope = .whole, onClose: @escaping () -> Void) {
        self.profileID = profileID
        self.profileName = profileName
        self.scope = scope
        self.onClose = onClose
        _model = StateObject(wrappedValue: RestorePreviewModel(profileID: profileID, scope: scope))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 360, idealWidth: 640, maxWidth: 640, minHeight: 320, idealHeight: 520, maxHeight: 520)
        .onAppear { model.load() }
        .onDisappear { model.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview restore of \(profileName)")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview restore of \"\(profileName)\"").font(.title3.bold())
                Text("Nothing is changed until you press Run now.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            scopeChip
            Button { model.load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.phase == .loading)
                .help("Scan your Mac again (Cmd+R)")
        }
        .padding(16)
    }

    /// "Whole profile" or "Desktop 2 on DELL only".
    private var scopeChip: some View {
        let text = scope.isWhole ? "Whole profile" : (model.profile.map { scope.describe(profile: $0) } ?? "Part of the profile")
        return Text(text).font(.callout).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill((scope.isWhole ? Color.secondary : Color.blue).opacity(0.15)))
            .accessibilityLabel("Scope: \(text)")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Comparing with your Mac…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let plan = model.plan, let profile = model.profile {
                planView(plan, profile)
            }
        }
    }

    private func planView(_ plan: RestorePlan, _ profile: Profile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(RestoreStepText.summaryLine(model.summary), systemImage: "checklist")
                    .font(.headline)
                    .accessibilityLabel("Summary: \(RestoreStepText.summaryLine(model.summary))")
                if !plan.warnings.isEmpty { warnings(plan.warnings) }
                if plan.steps.isEmpty {
                    Text("Nothing to do: every matched window is already where the profile says.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(plan.phases.enumerated()), id: \.element) { offset, phase in
                    phaseGroup(phase, number: offset + 1, plan: plan, profile: profile)
                }
                if !plan.unmatched.isEmpty { notFound(plan) }
                if !plan.possiblyParked.isEmpty {
                    Label("\(plan.possiblyParked.count) window\(plan.possiblyParked.count == 1 ? "" : "s") may be in the Stage Manager strip, so they are not counted as missing.",
                          systemImage: "rectangle.stack")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func warnings(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(items.count) warning\(items.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                .font(.callout.bold()).foregroundStyle(.orange)
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    private func phaseGroup(_ phase: RestorePhase, number: Int, plan: RestorePlan, profile: Profile) -> some View {
        let steps = plan.steps(in: phase)
        let binding = Binding<Bool>(get: { model.isExpanded(phase, count: steps.count) },
                                    set: { model.expansion[phase] = $0 })
        return DisclosureGroup(isExpanded: binding) {
            VStack(alignment: .leading, spacing: 4) {
                if phase == .launch, let note = launchNote(profile) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text(RestoreStepText.text(step)).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4).padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("\(number). \(RestoreStepText.heading(phase)) (\(steps.count))").font(.body.bold())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(RestoreStepText.heading(phase)), \(steps.count) step\(steps.count == 1 ? "" : "s")")
    }

    private func launchNote(_ profile: Profile) -> String? {
        guard let plan = profile.launchPlan else { return "Apps open at the same time." }
        switch plan.mode {
        case .parallel:
            return "Apps open at the same time."
        case .sequential:
            let seconds = Int(LaunchSequence.worstCaseDuration(plan: plan).rounded())
            return seconds > 0 ? "Apps open one after another, up to about \(seconds) s in the worst case."
                               : "Apps open one after another."
        }
    }

    /// True when the plan opens this app, so the window is not really missing.
    private func isLaunching(_ item: UnmatchedSnapshot, _ plan: RestorePlan) -> Bool {
        plan.steps.contains { step in
            if case .launch(let app, _) = step { return RestoreStepText.sameApp(app, item.app) }
            return false
        }
    }

    private func notFound(_ plan: RestorePlan) -> some View {
        let launching = plan.unmatched.filter { isLaunching($0, plan) }
        let missing = plan.unmatched.filter { !isLaunching($0, plan) }
        return VStack(alignment: .leading, spacing: 14) {
            if !launching.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Will launch (\(launching.count))", systemImage: "arrow.up.forward.app")
                        .font(.body.bold())
                    ForEach(launching, id: \.snapshotID) { item in
                        Text(item.label).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not found right now (\(missing.count))", systemImage: "questionmark.circle")
                        .font(.body.bold())
                    ForEach(missing, id: \.snapshotID) { item in
                        Text("\(item.label): \(item.reason)").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if let app = AppState.current {
                RunStatusLine(app: app)
            }
            if model.isRunning { ProgressView().controlSize(.small) }
            if let result = model.runResult { Text(result).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Close", role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
                .help("Close the preview (Esc)")
            if let app = AppState.current {
                if scope.isWhole {
                    RunProfileButton(app: app, profileID: profileID, profileName: profileName, title: "Run now")
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button { model.runScoped() } label: { Label("Run now (scope only)", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!app.canAct || model.isRunning || model.profile == nil)
                        .help(studioRunBlockReason(app) ?? "Restore only \(scope.describe(profile: model.profile ?? Profile.emptyForMap))")
                }
            }
        }
        .padding(16)
    }
}
