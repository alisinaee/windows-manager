import AppKit
import SwiftUI
import WMCore

/// Row selection of the launch order list. A class because this target cannot use the @State macro.
@MainActor
final class LaunchOrderSelection: ObservableObject {
    @Published var itemID: String?
}

/// The Builder's Launch order step (plan B2 step 5). The list shows the plan's items followed by apps of the
/// profile the plan does not list (they launch last, in profile order); the first edit writes all of them into
/// the plan so the order on screen is the order that runs. All edits go through `LaunchSequence` helpers.
///
/// Host: `LaunchOrderEditor(builder: builder)` (UI7 puts it in the Inspector tab "Launch order" or a wide sheet).
struct LaunchOrderEditor: View {
    @ObservedObject var builder: ProfileBuilderModel
    @StateObject private var selection = LaunchOrderSelection()

    var body: some View {
        if let profile = builder.profile {
            let plan = effectivePlan(profile)
            VStack(spacing: 0) {
                header(plan)
                Divider()
                if plan.items.isEmpty {
                    emptyState
                } else {
                    list(plan, profile)
                }
                Divider()
                footer(plan)
            }
        } else {
            Text("No profile is open.").foregroundStyle(.secondary).padding()
        }
    }

    // MARK: Plan access

    /// The plan with unlisted apps appended. No plan at all means "parallel", as the engine reads it.
    private func effectivePlan(_ profile: Profile) -> LaunchPlan {
        var plan = profile.launchPlan ?? LaunchPlan(mode: .parallel)
        for app in profile.launchApps {
            let item = LaunchItem(app: app)
            if !plan.items.contains(where: { $0.id == item.id }) { plan.items.append(item) }
        }
        return plan
    }

    private func commit(_ change: (LaunchPlan) -> LaunchPlan) {
        guard let profile = builder.profile else { return }
        builder.setLaunchPlan(change(effectivePlan(profile)))
    }

    private func issues(for id: String, plan: LaunchPlan, profile: Profile) -> [LaunchIssue] {
        var result = builder.launchIssues.filter { $0.itemID == id }
        for issue in LaunchSequence.validate(plan: plan, profile: profile)
        where issue.itemID == id && !result.contains(issue) { result.append(issue) }
        return result
    }

    // MARK: Header and footer

    private func header(_ plan: LaunchPlan) -> some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: Binding(
                get: { plan.mode },
                set: { mode in commit { var p = $0; p.mode = mode; return p } })) {
                Text("Sequential").tag(LaunchPlan.Mode.sequential)
                Text("At once").tag(LaunchPlan.Mode.parallel)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Launch mode")
            Button { moveSelected(by: -1, plan) } label: { Image(systemName: "arrow.up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .help("Move the selected app up (Command-Option-Up)")
                .accessibilityLabel("Move selected app up")
                .disabled(!canMove(-1, plan))
            Button { moveSelected(by: 1, plan) } label: { Image(systemName: "arrow.down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .help("Move the selected app down (Command-Option-Down)")
                .accessibilityLabel("Move selected app down")
                .disabled(!canMove(1, plan))
        }
        .padding(8)
    }

    private func footer(_ plan: LaunchPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                addMenu(plan)
                Spacer()
                Label("Worst case: \(durationText(LaunchSequence.worstCaseDuration(plan: plan)))", systemImage: "clock")
                    .font(.callout)
            }
            Text(plan.mode == .sequential
                 ? "Sequential: one app after another, each waiting for its window or readiness, then its delay. Slower, but steadier."
                 : "At once: every app starts together and delays are ignored. Faster, but a busy Mac may place windows less reliably.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Apps not in the list launch last, in profile order.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func addMenu(_ plan: LaunchPlan) -> some View {
        let candidates = builder.library.filter { entry in
            !plan.items.contains { $0.id == entry.bundleID.lowercased() }
        }
        let background = candidates.filter(\.isBackgroundOnly)
        let others = candidates.filter { !$0.isBackgroundOnly }
        return Menu {
            if candidates.isEmpty {
                Text("No more apps")
            }
            if !background.isEmpty {
                Section("Apps without windows") { ForEach(background, id: \.bundleID) { addButton($0) } }
            }
            if !others.isEmpty {
                Section("Other apps") { ForEach(others, id: \.bundleID) { addButton($0) } }
            }
        } label: {
            Label("Add launch-only app", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Launch an app without placing a window for it")
    }

    private func addButton(_ entry: LibraryEntry) -> some View {
        Button(entry.name) {
            let item = LaunchItem(app: builder.appRef(for: entry), wait: .appReady, withoutWindows: true)
            commit { var p = $0; if !p.items.contains(where: { $0.id == item.id }) { p.items.append(item) }; return p }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(.secondary)
            Text("No apps yet").font(.headline)
            Text("Place apps on the map, or add an app that only needs to launch.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            addMenu(LaunchPlan())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .contain)
    }

    // MARK: List

    private func list(_ plan: LaunchPlan, _ profile: Profile) -> some View {
        List(selection: $selection.itemID) {
            ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in
                row(index: index, item: item, plan: plan, profile: profile)
                    .tag(item.id)
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                commit { LaunchSequence.moved($0, from: from, to: from < destination ? destination - 1 : destination) }
            }
        }
        .listStyle(.inset)
    }

    private func row(index: Int, item: LaunchItem, plan: LaunchPlan, profile: Profile) -> some View {
        let itemIssues = issues(for: item.id, plan: plan, profile: profile)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Launch \(item.app.name)", isOn: Binding(
                    get: { item.enabled },
                    set: { _ in commit { LaunchSequence.toggled($0, id: item.id) } }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Image(nsImage: AppIconCache.icon(for: item.app)).resizable().frame(width: 20, height: 20)
                Text(item.app.name).lineLimit(1)
                if item.withoutWindows { Text("launch only").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if !itemIssues.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .help(itemIssues.map(\.message).joined(separator: "\n"))
                        .accessibilityLabel("Problem: " + itemIssues.map(\.message).joined(separator: " "))
                }
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                    .accessibilityLabel("Move \(item.app.name) up")
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == plan.items.count - 1)
                    .accessibilityLabel("Move \(item.app.name) down")
            }
            HStack(spacing: 10) {
                if item.withoutWindows {
                    Text("Waits until the app is ready").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Wait for", selection: Binding(
                        get: { item.wait },
                        set: { wait in commit { LaunchSequence.settingWait($0, id: item.id, wait) } })) {
                        Text("First window").tag(LaunchWait.windows)
                        Text("App ready").tag(LaunchWait.appReady)
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                Stepper(value: Binding(
                    get: { item.delayAfter },
                    set: { value in commit { LaunchSequence.settingDelay($0, id: item.id, value) } }),
                        in: LaunchItem.delayRange, step: 1) {
                    Text("then \(secondsText(item.delayAfter))").font(.callout.monospacedDigit())
                }
                .controlSize(.small)
                .disabled(plan.mode == .parallel)
                .help(plan.mode == .parallel ? "Delays are ignored when apps launch at once." : "Seconds to wait after this app before the next one")
                .accessibilityLabel("Delay after \(item.app.name)")
                Stepper(value: Binding(
                    get: { item.timeout ?? LaunchOptions.defaultTimeout },
                    set: { value in commit { LaunchSequence.settingTimeout($0, id: item.id, value) } }),
                        in: LaunchItem.timeoutRange, step: 5) {
                    Text("max \(secondsText(item.timeout ?? LaunchOptions.defaultTimeout))\(item.timeout == nil ? " (default)" : "")")
                        .font(.callout.monospacedDigit())
                }
                .controlSize(.small)
                .accessibilityLabel("Timeout for \(item.app.name)")
            }
            .opacity(item.enabled ? 1 : 0.5)
            ForEach(itemIssues, id: \.message) { issue in
                Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if item.timeout != nil {
                Button("Use default timeout") { commit { LaunchSequence.settingTimeout($0, id: item.id, nil) } }
            }
            if item.withoutWindows {
                Button("Remove from launch order", role: .destructive) {
                    commit { var p = $0; p.items.removeAll { $0.id == item.id }; return p }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { move(index, by: -1) }
        .accessibilityAction(named: "Move down") { move(index, by: 1) }
    }

    // MARK: Moving

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        commit { plan in
            guard plan.items.indices.contains(index), plan.items.indices.contains(target) else { return plan }
            return LaunchSequence.moved(plan, from: index, to: target)
        }
    }

    private func selectedIndex(_ plan: LaunchPlan) -> Int? {
        guard let id = selection.itemID else { return nil }
        return plan.items.firstIndex { $0.id == id }
    }

    private func canMove(_ offset: Int, _ plan: LaunchPlan) -> Bool {
        guard let index = selectedIndex(plan) else { return false }
        return plan.items.indices.contains(index + offset)
    }

    private func moveSelected(by offset: Int, _ plan: LaunchPlan) {
        guard let index = selectedIndex(plan) else { return }
        move(index, by: offset)
    }

    // MARK: Text

    private func secondsText(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }
}
