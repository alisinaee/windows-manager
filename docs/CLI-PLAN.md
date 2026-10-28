# Full CLI for AI agents (P6.86, Opus plan)

Goal: every GUI feature usable headless. One binary `wm` (keep `spaceslab` as alias; lab commands under `wm lab ...`). Logic lives in WMCore services; AppState, Studio and CLI call the same code.

Output: `--json` everywhere. Envelope `{"ok":true,"data":...}` or `{"ok":false,"error":{"code","message","hint"}}`. Long runs print NDJSON events (`{"event":"progress",...}`) then the envelope.
Exit codes: 0 ok, 1 runtime failure, 2 usage, 3 not found, 4 permission missing, 5 app needed but not running, 6 partial (unmatched windows).
Modes: `--via app|direct|auto`. Direct works on profile/settings files and AX/SkyLight (needs Accessibility for the terminal). App IPC (Unix socket, JSON) for hotkeys/watchers/live Studio; CLI sends "profilesChanged" after file writes.
Verify: mutating commands return the new object; `wm run --json` returns RestoreReport; `wm verify <profile>` diffs live vs profile (DebugVerify, ProfileLiveStatus); `wm windows --json` is ground truth; `wm doctor --json` lists permissions with fix text.

## Tasks (disjoint files)
- T1 CLI core (sonnet, first): Sources/wm/main.swift, Sources/wm/Output/* (envelope, exit codes, NDJSON, arg parsing), Package.swift product, alias script.
- T2 Core profile services (sonnet): Sources/WMCore/Services/ProfileService.swift, LaunchOrderService.swift (CRUD, icon, shortcut, launch order, window frame/zone/grid/auto layout), tests.
- T3 Core settings/layouts/rules (sonnet): Services/SettingsStore.swift, LayoutService.swift, RuleService.swift, tests.
- T4 Profile commands (haiku; after T1,T2): Sources/wm/Commands/Profile*.swift.
- T5 Run/capture/verify/plan (sonnet; after T1,T2): Commands/{Run,Capture,Verify,Plan}.swift.
- T6 System commands (haiku; after T1,T3): Commands/{Doctor,Spaces,Displays,Windows,Settings,Layouts,Rules,Debug}.swift; wrap old lab commands.
- T7 App IPC (sonnet): Sources/WMCore/IPC/*, Sources/WindowsManagerApp/IPC/AppControlServer.swift.
- T8 Schema, guide, docs, rewiring (haiku; last): Commands/{Schema,AgentGuide}.swift, docs/CLI.md, AppState/Studio onto services.
Agent guide outline: safety (dry-run first), bootstrap (doctor, schema), concepts, recipes (capture-edit-plan-run-verify; build from scratch; grid layout; debug tests), envelope/exit codes, modes, troubleshooting, GUI-only limits.
