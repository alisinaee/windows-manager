import SwiftUI
import WMCore

// Sheets of the Profile Builder (plan B2): the copy picker (New profile menu, P6.54) and the save sheet (step 7).

/// Local state of the copy picker (`@State` is not used in the app target).
@MainActor
final class CopyPickState: ObservableObject {
    @Published var copySourceID: UUID?
}

/// "Copy of a profile…": picks the saved profile to copy. Nothing is created until the draft opens.
struct StudioCopyPickerSheet: View {
    /// Saved profiles offered for the copy.
    let profiles: [ProfileStudioRow]
    let onCopy: (UUID) -> Void
    let onCancel: () -> Void

    @StateObject private var local = CopyPickState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy of a profile").font(.title2.bold())
            Text("The copy opens as a draft. Nothing is saved until you press Save.")
                .font(.callout).foregroundStyle(.secondary)

            if profiles.isEmpty {
                Text("There are no saved profiles yet.").foregroundStyle(.secondary)
            } else {
                Picker("Profile", selection: Binding(get: { local.copySourceID ?? profiles.first?.id }, set: { local.copySourceID = $0 })) {
                    ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                .help("Choose the saved profile to copy")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .help("Close without copying (Esc)")
                Button("Copy") {
                    if let id = local.copySourceID ?? profiles.first?.id { onCopy(id) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(profiles.isEmpty)
                .help("Open a draft copy of the chosen profile (Return)")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private final class NameDraft: ObservableObject {
    @Published var text: String?
}

/// Name, problems and Save/Cancel. The model refuses to save while an error is listed.
struct StudioSaveSheet: View {
    @ObservedObject var builder: ProfileBuilderModel
    /// Called with the stored profile after a successful save.
    let onSaved: (Profile) -> Void
    let onCancel: () -> Void
    /// Edited locally; committed to the builder on Save so Cancel leaves the draft untouched.
    @StateObject private var draft = NameDraft()
    private var nameDraft: String? { draft.text }
    private var shownName: String { nameDraft ?? builder.nameText }

    private var errors: [DraftCheckIssue] { ProfileDraftCheck.errors(builder.draftIssues) }
    private var warnings: [DraftCheckIssue] { ProfileDraftCheck.warnings(builder.draftIssues) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save profile").font(.title2.bold())
            TextField("Name", text: Binding(get: { shownName }, set: { draft.text = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .help("Name the profile (Return saves)")

            if shownName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    .help("Close without saving (Esc)")
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(builder.blocksSaving || shownName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(builder.blocksSaving ? "Fix the problems marked in red first" : "Save the profile (Return)")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save() {
        if let nameDraft { builder.setName(nameDraft) }
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
