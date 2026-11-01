import SwiftUI
import WMCore

/// The Launch page of the Details inspector (plan B2 step 5). Shows the plan's items followed by apps of the
/// profile the plan does not list (they launch last, in profile order); the first edit writes all of them into
/// the plan so the order on screen is the order that runs. All edits go through `LaunchSequence` helpers.
/// In View mode (`builder` nil) the same rows show the saved plan and cannot be changed. Plain content: the
/// inspector container supplies the scrolling, and `LaunchFooter` is its pinned bottom bar.
struct LaunchOrderEditor: View {
    let profile: Profile
    let builder: ProfileBuilderModel?

    @State private var selectedID: String?

    private var plan: LaunchPlan { LaunchPlan.effective(for: profile) }

    var body: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: Spacing.m) {
            if plan.items.isEmpty {
                ContentUnavailableView("No Apps Yet", systemImage: "app.dashed",
                                       description: Text("Place apps on the map, or add an app that only needs to launch."))
            } else {
                modePicker(plan)
                ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in
                    LaunchOrderRow(index: index, count: plan.items.count, item: item, mode: plan.mode,
                                   issues: issues(for: item.id, plan: plan), isSelected: selectedID == item.id,
                                   isEditable: builder != nil,
                                   onSelect: { selectedID = item.id },
                                   commit: commit,
                                   move: { move(index, by: $0) },
                                   drop: { id in moveItem(id: id, to: index, plan) })
                }
                Text("Apps not in the list launch last, in profile order.")
                    .font(.wmCaption).foregroundStyle(.secondary)
            }
        }
        .background { orderShortcuts(plan) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Launch order")
    }

    // MARK: Plan access

    private func commit(_ change: (LaunchPlan) -> LaunchPlan) {
        builder?.setLaunchPlan(change(plan))
    }

    private func issues(for id: String, plan: LaunchPlan) -> [LaunchIssue] {
        var result = (builder?.launchIssues ?? []).filter { $0.itemID == id }
        for issue in LaunchSequence.validate(plan: plan, profile: profile)
        where issue.itemID == id && !result.contains(issue) { result.append(issue) }
        return result
    }

    // MARK: Mode

    private func modePicker(_ plan: LaunchPlan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Picker("Mode", selection: Binding(
                get: { plan.mode },
                set: { mode in commit { var p = $0; p.mode = mode; return p } })) {
                Text("Sequential").tag(LaunchPlan.Mode.sequential)
                Text("At once").tag(LaunchPlan.Mode.parallel)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(builder == nil)
            .accessibilityLabel("Launch mode")
            .help("Launch apps one after another, or all at once")
            Text(plan.mode == .sequential
                 ? "One app after another, each waiting for its window, then its delay. Slower, but steadier."
                 : "Every app starts together and delays are ignored. Faster, but less steady on a busy Mac.")
                .font(.wmCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Moving

    /// Command-Option-Up / -Down move the selected row. Hidden buttons keep the shortcuts without an order bar.
    private func orderShortcuts(_ plan: LaunchPlan) -> some View {
        HStack {
            Button("Move Selected App Up") { moveSelected(by: -1, plan) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!canMove(-1, plan))
            Button("Move Selected App Down") { moveSelected(by: 1, plan) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!canMove(1, plan))
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        commit { plan in
            guard plan.items.indices.contains(index), plan.items.indices.contains(target) else { return plan }
            return LaunchSequence.moved(plan, from: index, to: target)
        }
    }

    /// A row was dropped on the row at `destination`: the dragged item takes that place.
    private func moveItem(id: String, to destination: Int, _ plan: LaunchPlan) {
        guard let from = plan.items.firstIndex(where: { $0.id == id }) else { return }
        commit { LaunchSequence.moved($0, from: from, to: destination) }
    }

    private func selectedIndex(_ plan: LaunchPlan) -> Int? {
        guard let id = selectedID else { return nil }
        return plan.items.firstIndex { $0.id == id }
    }

    private func canMove(_ offset: Int, _ plan: LaunchPlan) -> Bool {
        guard builder != nil, let index = selectedIndex(plan) else { return false }
        return plan.items.indices.contains(index + offset)
    }

    private func moveSelected(by offset: Int, _ plan: LaunchPlan) {
        guard let index = selectedIndex(plan) else { return }
        move(index, by: offset)
    }
}
