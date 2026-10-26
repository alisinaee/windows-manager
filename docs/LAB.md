# Spaces Lab: how to run the tests (P1.9)

`spaceslab` checks what we can control on your macOS before we build the real app.
Every test saves a result file in `lab-results/`. When you are done, I read those files.

Run everything from the project folder, in Terminal:

```bash
cd ~/Works/windows_manager
scripts/build.sh
```

The tool is then `.build/release/spaceslab` (below just `spaceslab`; you can run `alias spaceslab=.build/release/spaceslab`).
Terminal needs Accessibility: System Settings > Privacy & Security > Accessibility > Terminal on.

## 0. Before you start

- Turn OFF: System Settings > Desktop & Dock > Mission Control > "Automatically rearrange Spaces based on most recent use".
- Keep your hands off the keyboard and trackpad while a test runs (except the trackpad test).
- Leave Stage Manager as it is; every result records it.

## 1. Read-only checks (change nothing)

```bash
spaceslab doctor
spaceslab spaces
spaceslab move --probe
spaceslab switch --probe
spaceslab virtual --probe
spaceslab order-file show
```

## 2. Desktops (adds a Desktop 2 that the next tests need)

```bash
spaceslab desktops dump-tree
spaceslab desktops add --display 1
spaceslab desktops list
```

`dump-tree` opens and closes Mission Control for a second.

## 3. Move a window between Desktops (most important)

```bash
spaceslab move --self-test --to 2
spaceslab move --self-test --to 2 --method bridgedScanned
spaceslab move --self-test --to 2 --method compatID
spaceslab move --self-test --to 2 --method legacy
```

The tool opens its own small "Spaces Lab test window", moves it to Desktop 2, checks it, moves it back and closes it.
Stand on Desktop 1 of the Samsung while you run these.

## 4. Switch between Spaces

```bash
spaceslab switch --bench --display 1
```

It steps one Space right and back with each method, 3 times. The screen will slide; that is expected.

## 5. Full screen order

Open TextEdit and Notes, one window each, on Desktop 1. Stay on Desktop 1.

```bash
spaceslab fullscreen --probe --app TextEdit --app Notes
spaceslab fullscreen test --app TextEdit --app Notes --method ax
spaceslab fullscreen test --app TextEdit --app Notes --method ax --delay 8
```

In the `--delay 8` run, switch to another Space during the countdown.

## 6. Virtual mode

```bash
spaceslab virtual trackpad --seconds 15
spaceslab virtual hide-test --app TextEdit --repeat 5
spaceslab virtual park-test --app TextEdit
```

During the trackpad test, swipe 3 fingers left and right a few times.

## 7. Space order file (riskiest, do it last)

```bash
spaceslab order-file backup
spaceslab order-file apply --display 2 --order 3,1,2
spaceslab order-file apply --display 2 --order 3,1,2 --yes
```

The first `apply` is a dry run. The `--yes` run backs up, rewrites the order on the MacBook screen (Desktop first), restarts the Dock and checks.
To undo, use the restore line it prints: `spaceslab order-file restore <backup file> --yes`.

## 8. Clean up and report

```bash
spaceslab desktops remove 2 --display 1
spaceslab report --out lab-results/REPORT.md
```

Turn "Automatically rearrange Spaces" back on only if you want it. Then tell me "lab done".

## 9. App engine checks (phase 2, screen unlocked)

```bash
spaceslab ax-remote --app Arc
spaceslab capture --out lab-results/my-setup.json
spaceslab restore --profile lab-results/my-setup.json --dry-run
```

`ax-remote` shows whether windows on other Spaces can be reached; `capture` saves your current setup as a profile;
the restore dry run prints what a restore would do, without doing it.
Builds use Xcode's toolchain automatically (`scripts/env.sh`).
