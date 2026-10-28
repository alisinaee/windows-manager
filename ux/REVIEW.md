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
