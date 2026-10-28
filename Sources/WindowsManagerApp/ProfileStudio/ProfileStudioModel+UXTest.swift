import AppKit
import SwiftUI
import WMCore

/// Deterministic hooks for UX capture (P6.103). Used only by `UXTestRoute`, which runs only with WM_UX_TEST=1.
extension ProfileStudioModel {
    /// Wanted initial inspector tab for the next Edit session. NOT YET READ by the view: `StudioEditLocalState.tab`
    /// should start from `ProfileStudioModel.uxInspectorTab ?? .inspector` (one-line change in ProfileStudioView.swift).
    @MainActor static var uxInspectorTab: StudioInspectorTab?

    /// The model of the open Studio window, found through its hosting controller.
    @MainActor static func uxCurrent() -> ProfileStudioModel? {
        for window in NSApp.windows {
            if let hosting = window.contentViewController as? NSHostingController<ProfileStudioView> {
                return hosting.rootView.model
            }
        }
        return nil
    }

    /// Waits (up to ~4 s) until the profile list has loaded.
    @MainActor func uxWaitLoaded() async {
        for _ in 0..<80 where state == .loading {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Selects a profile by name (case-insensitive), switches mode and opens a sheet. Returns false when the profile is unknown.
    @MainActor @discardableResult
    func uxApply(profile name: String?, mode wanted: UXOpenRoute.Mode?, sheet: UXOpenRoute.Sheet?,
                 selectTile: Int? = nil, saveName: String? = nil) async -> Bool {
        await uxWaitLoaded()
        // A sheet left by the previous route must not show in this state.
        isPreviewPresented = false; isSaveSheetPresented = false; isReviewCapturePresented = false; isCopyPickerPresented = false
        try? await Task.sleep(for: .milliseconds(400))
        var found = true
        if let name {
            if let row = rows.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                if mode == .edit { leaveEdit() }
                selectedID = row.id
            } else { found = false }
        }
        if wanted == .edit, mode != .edit, let id = selectedID {
            startEditing(id)
            for _ in 0..<80 { // wait for the builder map to open
                if let phase = builder?.phase, "\(phase)" != "idle" { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        } else if wanted == .view, mode == .edit {
            leaveEdit()
        }
        if sheet == .capture {
            // "Review capture" (CaptureReviewPanel, shown by isReviewCapturePresented) exists only behind a new profile
            // started from the workspace: start one the way the New profile menu does, wait for the capture, then open it.
            if mode == .edit { leaveEdit() }
            beginNewProfile()
            for _ in 0..<200 where capture.stage != .ready { try? await Task.sleep(for: .milliseconds(50)) }
            isReviewCapturePresented = mode == .edit && capture.stage == .ready
        }
        if let n = selectTile, mode == .edit, let b = builder, let p = b.profile {
            let onScreen = p.windows.filter { $0.displayUUID == b.selectedDisplayUUID }
            let pool = onScreen.isEmpty ? p.windows : onScreen
            if pool.indices.contains(n) {
                b.selectedWindowID = pool[n].id
            } else if let last = pool.last {
                b.selectedWindowID = last.id
            }
        }
        switch sheet {
        case .save:
            if mode == .edit {
                if let saveName { builder?.setName(saveName) }
                isSaveSheetPresented = true
            }
        case .capture: break
        case .restore: isPreviewPresented = true
        case nil: break
        }
        return found
    }
}
