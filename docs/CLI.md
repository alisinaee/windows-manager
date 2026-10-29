# wm CLI reference

Generated from `wm schema --json` (version 0.1.0). For agents, start with `wm agent-guide`.

Columns: **M** = mutates stored state (profiles, settings, layouts, rules); **W** = reads or moves real windows. Commands without M or W are read-only and safe.

## Global

| Flag | Meaning |
|---|---|
| `--json` | Print the `{"ok":...}` envelope; long runs add NDJSON events |
| `-h, --help` | Show help for a command |
| `--via app\|direct\|auto` | Choose the app IPC socket, direct file and AX access, or auto (default) |

Exit codes: 0 ok, 1 runtime, 2 usage, 3 not found, 4 permission (Accessibility), 5 app not running, 6 partial (unmatched windows).

Envelope: success `{"ok":true,"data":...}`; failure `{"ok":false,"error":{"code","message","hint"}}`.

## Bootstrap and info

| Command | M | W | Summary |
|---|---|---|---|
| `wm version` | | | Print the wm version |
| `wm commands` | | | List all registered commands |
| `wm schema` | | | Machine-readable command list, flags, safety metadata, exit codes, envelope |
| `wm agent-guide` | | | Markdown guide for AI agents (`--json` gives `{markdown}`) |
| `wm doctor` | | | Check Accessibility, screen recording, SkyLight, Stage Manager and Spaces settings |
| `wm status` | | | Show app and permission status |
| `wm spaces` | | | List displays, Desktops, full-screen Spaces and windows (read-only) |
| `wm windows limits` | | | `<app>` `--probe --yes`: which windows of an app refuse resizing (`--probe` nudges real windows by 8 pt and restores them, so it is W) |
| `wm debug list` | | | List live debug scenarios |
| `wm debug results` | | | Show the last headless debug run |
| `wm report` | M | | `--title T` `--description D` `--include-profile NAME` `--out DIR` (default ~/Desktop) `--submit` (needs `gh`; the only network use). Writes a redacted zip and prints the prefilled issue URL |
| `wm debug run` | M | W | `--scenario <id>\|all` (default all) `--yes` (required; moves real windows; exit 4 without Accessibility, 6 if a scenario fails) |

## Profiles

| Command | M | W | Arguments and options |
|---|---|---|---|
| `wm profile list` | | | |
| `wm profile show` | | | `<profile>` |
| `wm profile create` | M | | `<name>` `--icon <symbol>` |
| `wm profile copy` | M | | `<profile>` `--name <name>` |
| `wm profile rename` | M | | `<profile> <new-name>` |
| `wm profile delete` | M | | `<profile> --yes` (moves to Trash) |
| `wm profile icon` | M | | `<profile> [sf-symbol]` |
| `wm profile shortcut` | M | | `<profile> [combo]` `--clear` |
| `wm profile options` | M | | `<profile> --set key=value` (repeatable) |
| `wm profile desktop add` | M | | `<profile> [number]` `--display <uuid>` |
| `wm profile desktop remove` | M | | `<profile> <number>` `--display <uuid>` `--move-to <n>` |
| `wm profile window add` | M | | `<profile>` `--app <name>` `--bundle <id>` `--display <uuid>` `--desktop <n>` `--frame x,y,w,h` `--relative x,y,w,h` |
| `wm profile window remove` | M | | `<profile> <window>` |
| `wm profile window move` | M | | `<profile> <window>` `--display <uuid>` `--desktop <n>` |
| `wm profile window frame` | M | | `<profile> <window> <frame>` `--relative` |
| `wm profile zone` | M | | `<profile> <window>` `--layout <name>` `--zone <i>` (0-based) |
| `wm profile grid` | M | | `<profile> <window>` `--cols <n>` `--rows <n>` |
| `wm profile auto-layout` | M | | `<profile>` `--display <uuid>` `--desktop <n>` `--candidate <i>` `--apply` |
| `wm profile launch-order get` | | | `<profile>` |
| `wm profile launch-order set` | M | | `<profile> <item...>` |
| `wm profile launch-order move` | M | | `<profile> <item> <position>` |
| `wm profile launch-order delay` | M | | `<profile> <item> <seconds>` |
| `wm profile export` | | | `<profile>` `--out <file>` (stdout if omitted) |
| `wm profile import` | M | | `<file>` (new id, no shortcut) |

## Capture, plan, run, verify

| Command | M | W | Arguments and options |
|---|---|---|---|
| `wm capture` | M | W | `--name <name>` `--select <selector>` (repeatable: `app:`, `desktop:N`, `monitor:<uuid\|name\|index>`, `fullscreen`, `minimized`; selectors combine as a union) |
| `wm plan` | | | `<profile>` `--monitor <uuid\|name\|index>` `--desktop N` `--app <bundle\|name>` (repeatable scope flags; `--desktop` is relative to `--monitor` when given; empty or unknown scope = exit 2): dry-run plan grouped by phase, with `scope` in the JSON |
| `wm run` | M | W | `<profile>` `--dry-run` `--yes` `--monitor` `--desktop N` `--app` (same scope flags as `wm plan`; only the scope is touched) (streams NDJSON with `--json`; each `progress` event and the envelope carry `scope`) |
| `wm verify` | | W | `<profile>`: compare live windows with the profile (exit 6 on mismatch) |

## Layouts

| Command | M | W | Arguments and options |
|---|---|---|---|
| `wm layouts list` | | | |
| `wm layouts show` | | | `<layout>` |
| `wm layouts create` | M | | `<name>` `--display <uuid>` |
| `wm layouts rename` | M | | `<layout> <newName>` |
| `wm layouts delete` | M | | `<layout>` |
| `wm layouts zones list` | | | `<layout>` |
| `wm layouts zones add` | M | | `<layout> <name>` `--rect x,y,w,h` (fractions 0-1 of the display, origin top-left) |
| `wm layouts zones set` | M | | `<layout> <zone>` `--rect x,y,w,h` `--name <text>` (move, resize, rename) |
| `wm layouts zones remove` | M | | `<layout> <zone>` |

## Settings

| Command | M | W | Arguments and options |
|---|---|---|---|
| `wm settings list` | | | |
| `wm settings get` | | | `<key>` |
| `wm settings set` | M | | `<key> <value>` (text, e.g. `snap.gap 8`) |
| `wm settings reset` | M | | `<key>` |

## Rules

| Command | M | W | Arguments and options |
|---|---|---|---|
| `wm rules list` | | | Auto profile settings, pin rules, window rules |
| `wm rules pins` | | | List Space pin rules |
| `wm rules pins add` | M | | `<bundleID>` `--desktop <n>` `--display <uuid>` `--space <id>` `--title <text>` |
| `wm rules pins remove` | M | | `<id>` |
| `wm rules auto` | M | | `--enabled on\|off` `--monitor-change on\|off` `--wake on\|off` `--unlock on\|off` `--delay <s>` `--cooldown <s>` (0-3600 s): auto profile triggers |
| `wm rules auto-map` | | | `list`: monitor set to profile mappings plus the current monitor set key |
| `wm rules auto-map set` | M | | `<profile>` `--key <monitorSetKey>` (default: displays connected now) |
| `wm rules auto-map remove` | M | | `--key <monitorSetKey>` (default: displays connected now) |
| `wm rules window-rules` | | | List per-app window rules |
| `wm rules window-rules set` | M | | `<bundleID> <ignore\|alwaysRestore\|pinToDisplay>` `--display <uuid>` |
| `wm rules window-rules remove` | M | | `<bundleID>` |

## System: hotkeys, backups, windows, updates

| Command | M | W | Arguments and options |
|---|---|---|---|
| `wm hotkeys list` | | | Global hotkeys (workspace, snap zone, window size, move to display) and profile hotkeys found in the store |
| `wm hotkeys set` | M | | `<name> <combo>` e.g. `workspace.next ctrl+opt+cmd+right`; needs a modifier; refuses system shortcuts and combos already used (exit 1). Keys: letters, digits, arrows, `space`, `return`, `tab`, `esc`, `f1`-`f12`, `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backslash`, `leftbracket`, `rightbracket`, `grave`. The app reads hotkeys at launch: restart it to apply |
| `wm hotkeys clear` | M | | `<name>` |
| `wm backup list` | | | Space order backups, newest first |
| `wm backup create` | M | | `--reason <text>`: reads `com.apple.spaces` and the Mission Control shortcuts, writes one file in `~/Library/Application Support/WindowsManager/Backups` |
| `wm backup restore` | M | | `<backup>` (file name, unique prefix or `latest`) `--yes` `--no-dock-restart`: imports the preferences and restarts the Dock. Without `--yes` it refuses (exit 2) |
| `wm windows list` | | | `--app <name>` `--space <id>` `--on-screen` `--all` (include windows with no Space): id, app, pid, title, Space (Desktop number or full-screen), frame. Read-only; to move windows use a profile |
| `wm updates check` | | | `--app <path>`: reads `SUFeedURL` from the installed app, fetches the appcast, compares builds. Read-only, never downloads or installs; reports "not configured" while there is no feed URL |

## GUI features without a CLI command (gaps, P6.86)

| GUI feature | Status |
|---|---|
| Moving or closing an arbitrary live window | `wm windows list` lists them; moving windows outside a profile is not exposed (use a profile: `wm profile window add`, `wm run`) |
| Launch at login | Not feasible: `SMAppService.mainApp` registers the calling process's own bundle, so from `wm` it would register `wm`, not the app, and `sfltool dumpbtm` needs root. Use the app's Settings or System Settings > General > Login Items |
| Installing an update (Sparkle) | The download and install UI is Sparkle's and only the app links it. `wm updates check` covers the version check |
| Live hotkey reload | `wm hotkeys` edits the stored shortcuts; the running app picks them up at its next launch |
| Space guard watch and auto fix | Settings keys `spaceGuard.watchEnabled`, `spaceGuard.autoFix` via `wm settings` |
| Virtual workspaces | Settings keys `virtualWorkspaces*` via `wm settings`; switching is in the old `spaceslab virtual` lab command |
| Snap-on-drag | Settings keys `snap.*` via `wm settings`; the drag itself is GUI-only |
| Onboarding | GUI-only |
| Menu bar scoped Run (monitor, Desktop, app) | CLI equivalent: `wm run --monitor --desktop --app` |
| Shortcuts / Siri intents | App Intents only; the same actions are `wm run`, `wm profile` |

## Debug

`wm debug run` runs the live scenarios in-process, one after another, on the real desktop. It installs the fixture profiles first. With `--json` it streams NDJSON `phase`, `step` and `check` events, then the envelope with each scenario's checks. It also writes `~/Library/Logs/Windows Manager/debug-run.json`, the same file as the app's `--debug-run`. Read the last run with `wm debug results`. Never run it on a desktop you are not willing to have rearranged.
