# Sourced by the build scripts. Uses Xcode's toolchain when it is installed:
# SwiftUI macros such as @State only ship with Xcode, not with the Command Line Tools.
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
