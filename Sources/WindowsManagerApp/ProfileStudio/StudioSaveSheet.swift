import SwiftUI
import WMCore

// Sheets of the Profile Builder (plan B2): the copy picker (New profile menu, P6.54) and the save sheet (step 7).

/// One header style for every Studio sheet (P2-9): a `.title3.bold()` title and an optional secondary subtitle.
struct SheetHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.bold())
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

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
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(title: "Copy of a Profile", subtitle: "The copy opens as a draft. Nothing is saved until you press Save.")

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
                .buttonStyle(.borderedProminent).tint(Palette.accentStrong)
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
    /// How a name clash is resolved; defaults to the non-destructive "keep both".
    @Published var choice: ConflictChoice? = .keepBoth
}

private enum ConflictChoice { case replace, keepBoth }

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

    private var trimmedName: String { shownName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var store: ProfileStore { AppState.current?.store ?? ProfileStore() }
    /// Another saved profile (not this one) that already has the typed name.
    private var conflict: ProfileSummary? {
        guard !trimmedName.isEmpty else { return nil }
        let own = builder.profile?.id
        return store.list().first { $0.id != own && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }
    private var needsChoice: Bool { conflict != nil && draft.choice == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SheetHeader(title: "Save Profile")
            TextField("Name", text: Binding(get: { shownName }, set: { draft.text = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .help("Name the profile (Return saves)")
                .onChange(of: shownName) { _, _ in draft.choice = .keepBoth }

            if let clash = conflict {
                // One box: the warning and the choice it asks for (P1-9), not the same sentence twice.
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Label("A profile named \u{201C}\(clash.name)\u{201D} already exists.", systemImage: Tone.warning.symbol)
                        .font(.callout.bold())
                        .foregroundStyle(Tone.warning.color)
                    Picker("When the name exists", selection: Binding(get: { draft.choice }, set: { draft.choice = $0 })) {
                        Text("Replace the old one").tag(Optional(ConflictChoice.replace))
                        Text("Keep both (adds a number)").tag(Optional(ConflictChoice.keepBoth))
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .help("Replace moves the old profile to the Trash. Keep both saves this one with a number added to its name.")
                    Text("Or type another name above.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.medium).fill(Tone.warning.color.opacity(0.12)))
                .accessibilityElement(children: .contain)
            }

            if shownName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issueRow("exclamationmark.octagon.fill", Tone.danger.color, "Give the profile a name.")
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(Array(errors.enumerated()), id: \.offset) { issueRow("exclamationmark.octagon.fill", Tone.danger.color, $0.element.message) }
                ForEach(Array(builder.launchIssues.enumerated()), id: \.offset) { issueRow("exclamationmark.triangle.fill", Tone.warning.color, $0.element.message) }
                ForEach(Array(warnings.enumerated()), id: \.offset) { issueRow("exclamationmark.triangle.fill", Tone.warning.color, $0.element.message) }
                if errors.isEmpty, warnings.isEmpty, builder.launchIssues.isEmpty, conflict == nil, !trimmedName.isEmpty {
                    issueRow("checkmark.circle.fill", Tone.success.color, "No problems found.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !errors.isEmpty {
                Text("Fix the \(errors.count) problem\(errors.count == 1 ? "" : "s") marked in red to save. Warnings never block saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = builder.lastError {
                Text(message).font(.caption).foregroundStyle(Tone.danger.color)
            }

            HStack {
                if let reason = saveDisabledReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .help("Close without saving (Esc)")
                Button(saveTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Palette.accentStrong)
                    .disabled(builder.blocksSaving || trimmedName.isEmpty || needsChoice)
                    .help(builder.blocksSaving ? "Fix the problems marked in red first"
                          : needsChoice ? "Choose Replace or Keep both, or change the name" : "Save the profile (Return)")
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
    }

    /// "Save", or what Save will do about a name clash: "Replace" / "Save as Writing 2".
    private var saveTitle: String {
        guard conflict != nil, let choice = draft.choice else { return "Save" }
        switch choice {
        case .replace: return "Replace"
        case .keepBoth:
            return "Save as \(ProfileTransfer.uniqueName(trimmedName, among: store.list().map(\.name)))"
        }
    }

    /// Why Save is disabled, shown next to the button (nil when it is enabled).
    private var saveDisabledReason: String? {
        if trimmedName.isEmpty { return "Give the profile a name to save." }
        if builder.blocksSaving { return "Fix the problems marked in red to save." }
        if needsChoice { return "Choose Replace or Keep both, or change the name." }
        return nil
    }

    private func save() {
        if let nameDraft { builder.setName(nameDraft) }
        guard !needsChoice, !trimmedName.isEmpty else { return }
        if draft.choice == .replace, let clash = conflict { _ = try? store.delete(clash.id) }
        guard !builder.blocksSaving, let saved = builder.save() else { return }
        onSaved(saved)
    }

    private func issueRow(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sheet content fades in as the system sheet transition runs; Reduce Motion shows it at once.
private struct SheetFadeIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : Motion.smooth) { shown = true } }
    }
}

extension View {
    /// Fade a sheet's content in on appear.
    func sheetFadeIn() -> some View { modifier(SheetFadeIn()) }
}
