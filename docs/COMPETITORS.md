# Competitors: macOS window managers and layout restorers

Research note (R1). Sources: project pages, GitHub repos, and web search summaries, checked on 2026-10-28. Items marked "?" were not verified. Star counts move daily and are approximate.

## 1. Feature table

Legend: yes = documented; no = not offered; ? = not verified; n/a = not applicable.

| App | License | Stars | Snapping | Radial menu | Keyboard shortcuts | Multi-display | Spaces / Desktops | Save/restore layouts | Stage Manager | Scripting / CLI | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Windows Manager (ours)** | private | n/a | zones (planned) | no | yes (hotkeys) | yes | yes (Desktop per window) | yes (profiles) | yes (aware) | `spaceslab` CLI, `windowsmanager://` URLs | Only app here that restores full multi-desktop profiles |
| Loop | GPL-3.0 | 11.9k | drag preview | yes (hold trigger) | yes | yes (next/prev/edges) | ? | no | ? | `loop://` URLs, AppleScript | Stash windows at edge; cycles |
| Magnet | closed source, paid (App Store) | n/a | yes (edge/corner drag) | no | yes (custom + defaults) | yes (up to 6 external) | ? | no | ? | none advertised | Vertical-screen zones; price not on site |
| Rectangle | not confirmed (sources conflict; check LICENSE) | 30.2k | yes (edges, corners) | no (Pro adds cursor move) | yes | yes | ? | no | ? | `rectangle://` URLs | Cycles, sixths/eighths, mouse side buttons, app ignore list |
| AeroSpace | MIT (per search) | ? | n/a (tiling) | no | yes | ? | own virtual workspaces, not macOS Spaces | no | ? | `aerospace` CLI, TOML-style config | Public beta; no SIP needed |
| Amethyst | MIT (per search, verify) | ? | n/a (tiling) | no | yes | ? | throw windows to up to 10 spaces | no | ? | YAML config, JavaScript custom layouts | Tiling layouts, xmonad-style |
| yabai | MIT (verify) | ? | n/a (BSP tiling) | no | via skhd (separate tool) | yes | yes (deep control) | no | ? | full CLI (`yabai -m`) | Some features need SIP partly off |
| Hammerspoon | MIT (one source, verify) | ~11.5k to 14.9k (sources differ) | via Lua/Spoons (e.g. ShiftIt) | no | yes (Lua) | yes (API) | limited | no native | ? | Lua scripting engine | General automation tool, not a WM |
| Tokoro | free, open source | ? | no | no | ? | ? | yes (saves across Spaces) | yes (named profiles) | ? | ? | Menu bar app, macOS 13+ |
| winlayout | open source | ? | no | no | no | ? | ? | yes (named layouts) | ? | shell script CLI | No background service |
| SpacePigeon | open source | ? | no | no | ? | yes (external monitors) | ? | yes (saved workspaces) | ? | built on Hammerspoon | Presets per workspace |

## 2. What each does best

- **Loop**: the radial menu. Hold a trigger key and flick in a direction to move or resize, with no keyboard chord to memorize. Stash and cycles add quick, reversible moves.
- **Magnet**: the drag-to-edge experience. Edge, corner, and bottom-edge drop zones with a clear preview; the polish is the reason people pay for it.
- **Rectangle**: the most complete free snapping set. Sixths, eighths, ninths, and row or column tiling, plus an app ignore list and mouse side buttons. Large community, so fixes arrive fast.
- **AeroSpace**: keyboard-driven tiling with its own workspaces that do not fight macOS Spaces. Config is plain text, and it needs no SIP changes.
- **Amethyst**: tiling layouts you can cycle and script in JavaScript. Good if you want xmonad-style control.
- **yabai**: the deepest control of windows and Spaces via a CLI, at the cost of partly disabling SIP for some features.
- **Hammerspoon**: a Lua runtime for anything, including window logic. It is a toolkit, not a finished app.
- **Tokoro / winlayout / SpacePigeon**: the closest to our product. Named layout save and restore, with the simplest ones scriptable. None of them shows a map of the layout or handles Stage Manager as far as the sources say.

Our gap is not snapping; the strong snapping apps already cover it. Our edge is restoring a whole multi-desktop workspace (apps, Desktops, full screen, Stage Manager state) from one profile. The features below extend that edge.

## 3. Ten features worth bringing to our app (ranked)

1. **Drop-zone preview while dragging a window** (Magnet, Rectangle). Shows where a window will land before release; makes our existing snapping zones usable. Effort: S.
2. **Cycle a window through sizes on repeated shortcut** (Rectangle, Loop). Half, then two-thirds, then one-third with one key; cheap and used daily. Effort: S.
3. **Move window to next or previous display shortcut** (Magnet, Loop). Fast multi-monitor moves without opening the Studio. Effort: S.
4. **Per-app ignore list for hotkeys** (Rectangle). Stops our shortcuts from hijacking games, terminals, or remote desktops. Effort: S.
5. **Mouse side-button bindings** (Rectangle). Cheap input option for users with extra buttons. Effort: S.
6. **Trigger-key radial or hold-to-move menu** (Loop). A second, gesture-based way to place windows that fits our existing hotkey model. Effort: M.
7. **Stash windows at a screen edge** (Loop). Parks an app out of the way and brings it back, useful with Stage Manager. Effort: M.
8. **Pick a profile by connected display set** (winlayout caveat, Tokoro). Restores the right layout after a monitor change instead of putting windows on the wrong screen. Effort: M.
9. **Profile hotkeys and a switcher** (Hammerspoon, SpacePigeon). Bind a key to run a named profile, and cycle profiles from the menu bar. Effort: S to M.
10. **Row and column tiling inside one Desktop** (Rectangle, Amethyst). Lets a profile describe a tiled set, not only free-floating frames. Effort: L.

## 4. Open questions

- Confirm the license of Rectangle, Amethyst, yabai, and Hammerspoon from their LICENSE files before quoting them.
- Magnet price and Stage Manager behavior were not confirmed; Magnet's site lists none of its features in detail.
- Star counts for AeroSpace, Amethyst, yabai, Tokoro, and winlayout were not fetched.
- The Loop comparison page was unavailable (HTTP 410), so Loop's Spaces and Stage Manager support is unknown.
