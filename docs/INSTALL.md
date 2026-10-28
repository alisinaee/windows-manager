# Install Windows Manager (alpha, not notarized)

This alpha build is not signed with an Apple Developer ID, so macOS Gatekeeper blocks it the first time.

1. Open the .dmg and drag **Windows Manager** to **Applications**.
2. In Terminal, remove the quarantine flag (once):

       xattr -dr com.apple.quarantine "/Applications/Windows Manager.app"

3. Open the app from Applications. If macOS still objects: System Settings > Privacy & Security > "Open Anyway".
4. Grant **Accessibility** when asked (System Settings > Privacy & Security > Accessibility). The app needs it to move windows.

Requirements: macOS 26 (Tahoe) or newer, Apple silicon (arm64) build.

## Command line (optional, for scripts and AI agents)
Download `wm-<version>-arm64.zip` from the release, unzip, then:

    xattr -dr com.apple.quarantine ./wm
    chmod +x ./wm && mv ./wm /usr/local/bin/wm
    wm agent-guide      # start here if you are an AI agent
    wm doctor

## Reporting a bug
Menu bar icon > **Report a Bug…** (redacted logs, opens a prefilled GitHub issue), or `wm report`.
