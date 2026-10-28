#!/bin/bash
# Build wm + spaceslab (release) and symlink them into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product wm
swift build -c release --product spaceslab
BIN="$(swift build -c release --show-bin-path)"
DEST="$HOME/.local/bin"
mkdir -p "$DEST"
ln -sf "$BIN/wm" "$DEST/wm"
ln -sf "$BIN/spaceslab" "$DEST/spaceslab"
echo "Installed: $DEST/wm and $DEST/spaceslab"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "Add $DEST to your PATH." ;; esac
