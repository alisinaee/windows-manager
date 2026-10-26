# Windows Manager: user guide

This guide covers the early version of Windows Manager. For building the app, see the [README](../README.md).

## 1. First run and Accessibility permission

Windows Manager moves and resizes the windows of other apps. macOS allows that only for apps you trust in Accessibility.

1. Open the app. It lives in the menu bar. There is no Dock icon.
2. Click the menu bar icon, then **Setup…**. The guide walks you through the steps.
3. On the Accessibility step, click **Open System Settings**. Go to **Privacy & Security > Accessibility** and switch **Windows Manager** on.
4. The guide checks again every second. When it shows "Allowed", you are set.

Two notes:

- The menu also shows **Accessibility: allowed** or **not allowed**, with a **Grant…** button.
- If you rebuild the app yourself and the switch is on but the status still says "not allowed", remove Windows Manager from the list with the minus button and add it again. A build with a changing signature can lose the grant. Run `scripts/make-dev-cert.sh` once to avoid this for local builds.

The guide also explains Stage Manager and the Desktop order setting. Stage Manager can stay on or off. For Desktops to keep their order, turn off **Automatically rearrange Spaces based on most recent use** in **System Settings > Desktop & Dock > Mission Control**. The app never changes this setting itself.

## 2. Capture a workspace

A capture saves the current arrangement of your windows as a profile.

1. Arrange your windows the way you want them.
2. Click the menu bar icon, then **Capture current workspace…**.
3. Type a name, for example `Work`, and press Return or click **Save**. Click **Cancel** to stop.

The profile is saved on your Mac. You can capture as many profiles as you like.

## 3. Run a profile

1. Click the menu bar icon.
2. Click **Run** followed by the profile name, for example **Run Work**.
3. Watch the status line at the bottom of the menu. It shows progress, then "done" or a warning.

Running a profile:

- opens apps that are closed,
- moves windows that are already open to their saved place,
- puts windows back into full screen or onto their Desktop when the profile says so.

Run and Capture are greyed out while Accessibility is not allowed or while another run is still going.

If the status shows a warning, read it. Common reasons:

- Stage Manager is on and some windows are in the strip or in another stage, so they were left alone.
- Stage Manager was on when the profile was captured but is off now, or the other way round.

## 4. Import and export profiles

Profiles can be moved to another Mac or backed up as one JSON file. For now this is done with the `spaceslab` command line tool (see [LAB.md](LAB.md) for how to build it):

```bash
# Save a copy of a profile named "Work" to a file
spaceslab profile export Work ~/Desktop/work-profile.json

# Add a profile from a file
spaceslab profile import ~/Desktop/work-profile.json
```

Notes:

- The name match for export ignores upper and lower case. If two profiles have the same name, rename one first.
- An imported profile gets a new id. If its name is already used, it is saved as "Work 2" (or the next free number).
- The hotkey of an imported profile is cleared.

## 5. Control the app from links and scripts

The app accepts links with the `windowsmanager://` scheme. There are three commands:

| Link | What it does |
| --- | --- |
| `windowsmanager://run?profile=Work` | Runs the profile named Work |
| `windowsmanager://capture?name=Work` | Captures the current workspace as a profile named Work |
| `windowsmanager://list` | Shows the saved profile names in the status line |

Names are not case sensitive for `run`. Use percent-encoding for names with spaces, for example `windowsmanager://run?profile=Work%20Setup`.

You can open a link from Terminal:

```bash
open "windowsmanager://run?profile=Work"
```

Or use the same three commands with `spaceslab ctl`:

```bash
spaceslab ctl run Work
spaceslab ctl list
spaceslab ctl capture Work
```

`spaceslab ctl` opens the link for you. Extra words after the command are joined into one name, so `spaceslab ctl run Work Setup` runs the profile "Work Setup".

Any app or script that can open a link can send these commands.

## 6. Troubleshooting

- **Run does nothing or says Accessibility is not allowed.** Allow Windows Manager in Accessibility (section 1).
- **A profile says "No profile named ...".** Check the name with `windowsmanager://list` or `spaceslab ctl list`.
- **Check your Mac's setup.** Run `spaceslab doctor` from the project folder for a report on Accessibility, Desktop settings and the system calls the app uses.
