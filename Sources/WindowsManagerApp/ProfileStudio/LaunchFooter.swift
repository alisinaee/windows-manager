import SwiftUI
import WMCore

/// The pinned bottom bar of the Launch page: Add App on the left, the longest wait on the right, on one line.
/// View mode (`builder` nil) shows the wait only.
struct LaunchFooter: View {
    let profile: Profile
    let builder: ProfileBuilderModel?

    var body: some View {
        let plan = LaunchPlan.effective(for: profile)
        HStack {
            if let builder { addMenu(plan, builder) }
            Spacer(minLength: Spacing.s)
            if plan.mode == .sequential, !plan.items.isEmpty {
                Label("Up to \(durationText(LaunchSequence.worstCaseDuration(plan: plan)))", systemImage: "clock")
                    .lineLimit(1)
                    .help("The longest this launch order can take before the windows are placed")
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addMenu(_ plan: LaunchPlan, _ builder: ProfileBuilderModel) -> some View {
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
                Section("Apps without windows") { ForEach(background, id: \.bundleID) { addButton($0, builder) } }
            }
            if !others.isEmpty {
                Section("Other apps") { ForEach(others, id: \.bundleID) { addButton($0, builder) } }
            }
        } label: {
            Label("Add App", systemImage: "plus")
        }
        .fixedSize()
        .help("Launch an app without placing a window for it")
    }

    private func addButton(_ entry: LibraryEntry, _ builder: ProfileBuilderModel) -> some View {
        Button(entry.name) {
            let item = LaunchItem(app: builder.appRef(for: entry), wait: .appReady, withoutWindows: true)
            var plan = LaunchPlan.effective(for: profile)
            if !plan.items.contains(where: { $0.id == item.id }) { plan.items.append(item) }
            builder.setLaunchPlan(plan)
        }
        .help("Add \(entry.name) as a launch-only app")
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }
}
