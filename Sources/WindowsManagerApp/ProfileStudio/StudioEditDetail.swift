import SwiftUI
import WMCore

/// Edit mode: header and notes, the builder map and the Details inspector (the same container as View mode).
struct StudioEditDetail: View {
    @ObservedObject var model: ProfileStudioModel
    @ObservedObject var builder: ProfileBuilderModel
    @Binding var inspectorTab: StudioInspectorTab
    @StateObject private var map = ProfileMapModel()
    @State private var bannerDismissed = false
    @State private var isNotesShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch builder.phase {
        case .idle:
            // A new profile reads the workspace before there is a draft to show: progress until the map can open.
            VStack(spacing: Spacing.l) {
                ProgressView()
                Text("Reading your windows…").font(.wmSection)
                Text("This can take a few seconds.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .starting:
            ProgressView("Preparing the draft…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Banner(tone: .danger, title: "Could not open the draft", message: message,
                   actionLabel: "Back to View", action: { model.leaveEdit() })
                .frame(maxWidth: 480)
                .padding(Spacing.l).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                headerRow
                Divider()
                if hasBanner { banner }
                BuilderMapCanvas(map: map, builder: builder)
                    .onAppear { builder.mapModel = map; model.activeMap = map }
            }
            .inspector(isPresented: $model.isInspectorShown) {
                StudioInspectorHost(tab: $inspectorTab, map: map, builder: builder, plan: nil, isCompareOn: false)
                    .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
            }
            .onChange(of: builder.isDirty) { _, _ in model.titleChanged() }
            .onChange(of: builder.nameText) { _, _ in model.titleChanged() }
        }
    }

    /// Icon and name stay here: a text field has no toolbar home. Everything else is in the window toolbar.
    private var headerRow: some View {
        let title = builder.nameText.isEmpty ? "Untitled profile" : builder.nameText
        return HStack(spacing: Spacing.s) {
            ProfileIconPicker(current: (builder.profile?.icon ?? "").isEmpty ? Profile.defaultIcon : builder.profile!.icon) { builder.setIcon($0) }
            TextField("Profile name", text: Binding(get: { builder.nameText }, set: { builder.setName($0) }))
                .textFieldStyle(.roundedBorder).font(.wmTitle).lineLimit(1)
                .frame(maxWidth: 320, alignment: .leading)
                .help(builder.isNewProfile ? "New profile (not saved yet). Edit the name here." : "Editing a saved profile. Edit the name here.")
                .accessibilityLabel("Profile name, \(title)")
            if builder.isDirty {
                Circle().fill(Palette.warn).frame(width: Spacing.s, height: Spacing.s)
                    .transition(.scale.combined(with: .opacity))
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : Motion.spring, value: builder.isDirty)
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
    }

    private var hasBanner: Bool {
        guard !bannerDismissed else { return false }
        return builder.lastError != nil || !builder.startNotes.isEmpty
    }

    /// The last error in full, or a one-line summary of the start notes with the list behind "Show Details".
    private var banner: some View {
        let notes = builder.startNotes
        let error = builder.lastError
        let summary = notes.count == 1 ? notes[0] : "\(notes.count) notes about this capture."
        return Banner(tone: error == nil ? .info : .danger, title: error == nil ? "Note" : "Problem",
                      message: error ?? summary,
                      actionLabel: error == nil && notes.count > 1 ? "Show Details" : nil,
                      action: { isNotesShown = true },
                      onDismiss: { bannerDismissed = true })
            .padding(Spacing.s)
            .popover(isPresented: $isNotesShown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        InspectorNote(text: note, tone: .info)
                    }
                }
                .padding(Spacing.m)
                .frame(width: 340, alignment: .leading)
            }
            .onChange(of: error ?? summary) { _, _ in bannerDismissed = false }
    }
}
