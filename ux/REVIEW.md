# UX review (P6.102)

Reviewed 6 shots (capture-sheet.png is a duplicate of the inspector view; see UX-015). Findings: ux/findings.jsonl.

## Top 12
1. UX-015 capture sheet not captured, hook broken (blocks review)
2. UX-013 Restore preview: Run now looks disabled, "Not found" misleads
3. UX-011 Empty state: Capture is the only path, low contrast
4. UX-010 Edit mode: no unsaved indicator, Cancel unsafe, Live unexplained
5. UX-001 Launch order rows wrap ("de-fault")
6. UX-006 Garbled overlapping tile labels in stacks
7. UX-003 Top bar: Run not primary, Compare/Sync unexplained
8. UX-002 Set shortcut disabled with no explanation, odd font
9. UX-004 Tile stacks and positions unclear
10. UX-009 Unlabeled edit toolbar icons
11. UX-012 Left rail icons unlabeled, red eye reads as error
12. UX-008 Options wording (guarded repair, other apps)

## Fix order by file ownership (parallel-safe)
- Worker A: LaunchOrderEditor.swift (UX-001, 017)
- Worker B: ProfileStudioView.swift (UX-003, 010, 011, 016)
- Worker C: TileStackView.swift + ProfileMapCanvas.swift (UX-004, 005, 006)
- Worker D: RestorePreviewSheet.swift (UX-013, 014)
- Worker E: ProfileOptionsPanel.swift + MapInspectorView.swift (UX-007, 008, 018)
- Worker F: BuilderCanvasOverlay.swift (UX-009)
- Worker G: ProfileShortcutView.swift + SidebarRailView.swift (UX-002, 012)
- Worker H: ProfileStudioModel+UXTest.swift (UX-015), then re-shoot

# Round 2 (P6.102)

Reviewed 14 distinct shots. Many target states are still wrong (see UX-019): capture sheet, onboarding, narrow, wide, tile selection and name conflict were not captured. New findings: UX-019..032.

## Round-1 status
- UX-001 fixed (rows now two lines, no wrapping)
- UX-002 not fixed (Set shortcut still disabled monospace)
- UX-003 partly (Run filled but gray, not accent; Compare/Sync still unexplained)
- UX-004 partly (stack still hides 3 of 4 windows; tile still clumped in corner)
- UX-005 fixed ("No windows on this display")
- UX-006 fixed (labels clean)
- UX-007 fixed (Options fits, off toggle visible)
- UX-008 fixed (plain wording, "Leave alone")
- UX-009 not fixed (icons still unlabeled)
- UX-010 partly (no unsaved dot, Live unexplained; Cancel still beside Save)
- UX-011 partly (New profile added; both buttons gray, no primary)
- UX-012 not fixed (rail unchanged, red eye)
- UX-013 partly (wording better; Run now gray; duplicate lists; empty space)
- UX-014 partly (still no clear modal edge; Refresh style)
- UX-015 not fixed (capture sheet still not shown)
- UX-016 not fixed (bug icon and small legend remain)
- UX-017 partly ("Longest wait" renamed; reorder arrows still beside mode picker)
- UX-018 partly (inspector tabs still only in Edit; chevron floats)

## Top 10 new
1. UX-019 harness captures wrong states (blocker)
2. UX-021 save sheet: no visible name-conflict handling, gray Save
3. UX-031 primary actions not accent
4. UX-020 restore sheet overflows narrow window
5. UX-024 three rows of unlabeled edit chrome, no lock badges
6. UX-022 banner messages concatenated
7. UX-030 empty state has no primary action
8. UX-025 desktop strip mixed labels, tiny text
9. UX-028 rail dimmed in edit without explanation
10. UX-026 low-contrast secondary text

## Fix split by file ownership
- ProfileStudioModel+UXTest.swift: UX-019, 029, then re-shoot
- ProfileStudioView.swift: UX-022, 023, 030, 031, 032 plus open R1 UX-003, 010, 011, 016
- StudioSaveSheet.swift: UX-021
- RestorePreviewSheet.swift: UX-020 plus open R1 UX-013, 014
- BuilderCanvasOverlay.swift: UX-024 plus UX-009
- SpaceStripView.swift: UX-025
- MapLegendView.swift: UX-026
- ProfileOptionsPanel.swift: UX-027
- SidebarRailView.swift: UX-028 plus UX-012
- ProfileShortcutView.swift: UX-002; LaunchOrderEditor.swift: UX-017; TileStackView.swift: UX-004; MapInspectorView.swift: UX-018

# Sign-off (P6.102, code check)
Code and fix commits (43fdd4b, c6cea50, 7115a07, 6d52b22, 75b26f1, 84b371f, 46090b1) checked against round 2. Each line in findings.jsonl now has `status`. Shots exist for sections: studio view/edit/sidebar/narrow/wide, inspector, sheets (save, capture, restore, shortcut), onboarding, settings, debug, popover (ux/shots, shots-check, shots-live).
Open (not fixed in code): UX-004 tiles still clumped/not scaled to the saved frames (unverified in a new shot), UX-016 Debug log toggle still in the footer, UX-017 order arrows still beside the mode picker, UX-018 inspector chrome differs between modes, UX-023 window title lacks an unsaved marker, UX-029 no light-mode or increased-contrast shots.
No re-review shots were taken after rounds 2-3; statuses rest on code and commit diffs.
