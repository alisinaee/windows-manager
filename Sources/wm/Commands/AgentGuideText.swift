/// Markdown text printed by `wm agent-guide` (and returned as {"markdown": ...} with --json).
let agentGuideMarkdown = #"""
# wm agent guide

For AI agents operating the Windows Manager `wm` CLI on the user's Mac. Start here, then run `wm schema --json` for the exact commands, arguments and flags.

## 1. Safety rules

- Dry-run first. `wm plan <profile>` and `wm run <profile> --dry-run` change nothing. Show the result and ask before any real run.
- Never run `wm run`, `wm capture` or `wm verify` without the user's explicit consent in this conversation. They move or read real windows.
- Commands with `"mutates": true` in `wm schema --json` change profiles, settings, layouts or rules. Confirm before changing the user's data. For experiments, copy first: `wm profile copy <profile> --name <new>`.
- `wm profile delete` needs `--yes`. Ask the user before passing it.
- Do not edit profile JSON files by hand. Use `wm profile ...` commands, or `wm profile import` for a file the user gives you.
- Read the `ok` field of the envelope, not only the exit code.
- The CLI cannot grant macOS permissions. Tell the user what to enable; never try to change system or security settings.

## 2. Bootstrap

1. `wm doctor --json`: permissions and settings. Exit 4 means Accessibility is missing. Ask the user to enable it for their terminal.
2. `wm schema --json`: every command with `args`, `options`, `mutates`, `touchesWindows`, exit codes, envelope and global flags.
3. `wm status --json`: whether the app is running and which source answered.
4. `wm profile list --json`: existing profiles and their ids.

## 3. Concepts

- Profile: a saved workspace. It holds Desktops per display, planned windows (app, desktop, frame), launch order, options and an optional run shortcut.
- Desktop: numbered from 1 per display. Pass `--desktop N`.
- Window id: a UUID shown by `wm profile show <profile> --json`. Window commands take it.
- Display: identified by a UUID. Find it with `wm spaces --json`. Commands default to the only display when there is one.
- Layout: named zones on a display. Zone indexes are 0-based.
- Launch order: the order apps start in. Items are bundle ids, app names or 1-based positions.
- Rules: pin rules move an app's windows to a Desktop or Space. Window rules set an app to ignore, alwaysRestore or pinToDisplay.
- Profile refs: a name or a profile id. Use the id when names may clash; ambiguous names return usage errors.
- Modes: `--via app|direct|auto`. `direct` works on files and Accessibility. `app` uses the running app. `auto` (default) picks the app when it runs.

## 4. Recipes

### 4.1 Capture, show, edit, plan, run, verify

1. Ask the user to arrange their windows. Ask consent before capturing.
2. `wm capture --name Work --json` saves the current windows as a profile. Narrow it with `--select app:Safari` or `--select desktop:2` (repeatable).
3. `wm profile show Work --json` lists window ids and frames.
4. Edit with `wm profile window frame Work <window-id> 0,0,960,1080`, `wm profile window move`, `wm profile launch-order move Work Safari 1` or `wm profile options Work --set <key=value>`.
5. `wm plan Work` shows the grouped plan. It changes nothing.
6. `wm run Work --dry-run --json` previews. Ask consent, then run `wm run Work --yes --json`. Progress arrives as NDJSON lines before the envelope.
7. `wm verify Work --json` compares live windows with the profile. Exit 0 means they match. Exit 6 means some are unmatched. Ask consent first.

### 4.2 Build a profile from scratch

1. `wm profile create Dev --icon hammer`
2. `wm profile desktop add Dev 2 --display <uuid>` when more Desktops are needed.
3. `wm profile window add Dev --app Safari --desktop 1 --frame 0,0,960,1080` prints the new window id in `data.windowID`.
4. `wm profile window add Dev --app Terminal --bundle com.apple.Terminal --desktop 1 --relative 0.5,0,0.5,1` uses fractions of the monitor.
5. `wm profile launch-order set Dev Safari Terminal`
6. `wm profile shortcut Dev ctrl+opt+cmd+1` (optional)
7. `wm plan Dev`, then ask before any `wm run`.

### 4.3 Grid and zone layouts

- Grid: `wm profile grid Dev <window-id> --cols 2 --rows 2` snaps a window to a cell on its monitor.
- Zones: `wm layouts create Halves --display <uuid>` makes a layout. `wm profile zone Dev <window-id> --layout Halves --zone 0` places the window in zone 0. A wrong index error lists the valid range.
- Auto layout: `wm profile auto-layout Dev --desktop 1 --json` lists candidates (candidate 0 is the best). `wm profile auto-layout Dev --desktop 1 --apply --candidate 0` applies one.

### 4.4 Debug results

- `wm debug list --json` lists the live debug scenarios.
- `wm debug results --json` reads the last headless debug run (`debug-run.json`). Read it and summarize it for the user. Do not start debug runs unless the user asks.

## 5. Envelope and exit codes

Success: `{"ok":true,"data":...}`. Failure: `{"ok":false,"error":{"code","message","hint"}}`. Use `--json` for every call you parse. Long runs print NDJSON events such as `{"event":"progress",...}` before the envelope.

| Exit | Name | Meaning |
|---|---|---|
| 0 | ok | Success |
| 1 | runtime | Runtime failure |
| 2 | usage | Bad arguments; run `wm <command> --help` |
| 3 | not_found | Profile, layout, rule or window not found |
| 4 | permission | Accessibility missing; run `wm doctor --json` |
| 5 | app_not_running | The call needs the app; start it or use `--via direct` |
| 6 | partial | Some windows unmatched (verify, run) |

## 6. Modes (--via)

- `direct`: reads and writes profile and settings files, and uses Accessibility and window APIs from the CLI.
- `app`: sends the call to the running Windows Manager app over its local socket. Use it when live app state matters.
- `auto`: app when it runs, otherwise direct. After file writes the CLI tells a running app to reload.

## 7. Troubleshooting

- Usage error: check the spelling with `wm <command> --help`. Argument names come from `wm schema --json`.
- Not found: list with `wm profile list --json` and retry with the id.
- Exit 4: ask the user to enable Accessibility for their terminal, restart the terminal, then retry `wm doctor --json`.
- Exit 5: ask the user to open Windows Manager, or retry with `--via direct`.
- Exit 6: read the `windows` entries with `passed: false`. The window may be closed, on another Desktop, or have a different title. Report it; do not guess.
- Unreadable profile: report the error and stop. Do not repair files by hand.

## 8. GUI-only limits

- The Studio canvas, live hotkeys, window watchers and app updates exist only in the app. Ask the user to use the app for them.
- The CLI cannot click through macOS dialogs or grant permissions.
- Windows on other Spaces or in full screen may not match a profile. Expect exit 6 and explain it.
"""#
