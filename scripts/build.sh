#!/bin/sh
# Builds the release binary and prints where it is.
set -e
cd "$(dirname "$0")/.."
. scripts/env.sh
swift build -c release
echo "Built: $(pwd)/.build/release/spaceslab"
