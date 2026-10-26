import SwiftUI
import WMCore

// Sheets of the Profile Builder (plan B2): the start-point sheet (step 1) and the save sheet (step 7).

/// Local state of the start sheet (`@State` is not available in this toolchain).
@MainActor
final class StartSheetState: ObservableObject {
    @Published var copySourceID: UUID?
    @Published var showCopyPicker = false
}

/// "How do you want to start?" Shown when the Builder opens on a new profile.
struct StudioStartSheet: View {
    /// Saved profiles offered for "Start from a copy".
    let profiles: [ProfileStudioRow]
    let onChoose: (StudioStartChoice) -> Void
    let onCancel: () -> Void

    @StateObject private var local = StartSheetState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New profile").font(.title2.bold())
            Text("Choose where the draft starts. Nothing is saved until you press Save.")
                .font(.callout).foregroundStyle(.secondary)

            choiceRow(icon: "rectangle.dashed", title: "Blank on these monitors",
                      detail: "One empty Desktop for each monitor that is connected now.") { onChoose(.blank) }
            choiceRow(icon: "camera.viewfinder", title: "Start from the current workspace",
                      detail: "Captures the windows and Desktops you have open right now.") { onChoose(.currentWorkspace) }
            choiceRow(icon: "doc.on.doc", title: "Start from a copy of a profile",
                      detail: profiles.isEmpty ? "There are no saved profiles yet." : "Copies a saved profile so you can change it.",
                      disabled: profiles.isEmpty) { local.showCopyPicker.toggle() }

            if local.showCopyPicker, !profiles.isEmpty {
                HStack {
                    Picker("Profile", selection: Binding(get: { local.copySourceID ?? profiles.first?.id }, set: { local.copySourceID = $0 })) {
                        ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("Copy") {
                        if let id = local.copySourceID ?? profiles.first?.id { onChoose(.copyOf(id)) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.leading, 40)
            }

            HStack { Spacer(); Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func choiceRow(icon: String, title: String, detail: String, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 28).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .combine)
    }
}

/// Name, problems and Save/Cancel. The model refuses to save while an error is listed.
struct StudioSaveSheet: View {
    @ObservedObject var builder: ProfileBuilderModel
    /// Called with the stored profile after a successful save.
    let onSaved: (Profile) -> Void
    let onCancel: () -> Void

    private var errors: [DraftCheckIssue] { ProfileDraftCheck.errors(builder.draftIssues) }
    private var warnings: [DraftCheckIssue] { ProfileDraftCheck.warnings(builder.draftIssues) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save profile").font(.title2.bold())
            TextField("Name", text: Binding(get: { builder.nameText }, set: { builder.setName($0) }))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            if builder.nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issueRow("exclamationmark.octagon.fill", .red, "Give the profile a name.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(errors.enumerated()), id: \.offset) { issueRow("exclamationmark.octagon.fill", .red, $0.element.message) }
                    ForEach(Array(builder.launchIssues.enumerated()), id: \.offset) { issueRow("exclamationmark.triangle.fill", .orange, $0.element.message) }
                    ForEach(Array(warnings.enumerated()), id: \.offset) { issueRow("exclamationmark.triangle.fill", .orange, $0.element.message) }
                    if errors.isEmpty, warnings.isEmpty, builder.launchIssues.isEmpty {
                        issueRow("checkmark.circle.fill", .green, "No problems found.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 220)

            if !errors.isEmpty {
                Text("Fix the \(errors.count) problem\(errors.count == 1 ? "" : "s") marked in red to save. Warnings never block saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = builder.lastError {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(builder.blocksSaving)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save() {
        guard !builder.blocksSaving, let saved = builder.save() else { return }
        onSaved(saved)
    }

    private func issueRow(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
