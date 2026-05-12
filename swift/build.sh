#!/usr/bin/env zsh
# build.sh - compile and bundle the ATM menubar Swift app.
#
# Output:  swift/ATMMenuBar.app/
#   Contents/
#     Info.plist
#     MacOS/atm-menubar          (the swiftc-compiled binary)
#
# Requirements: Xcode Command Line Tools (swiftc, codesign).
# Install with: xcode-select --install
#
# Usage:
#   zsh swift/build.sh           # build
#   zsh swift/build.sh --clean   # remove the .app and rebuild

set -euo pipefail

SWIFT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${SWIFT_DIR}/ATMMenuBar.app"
SOURCES="${SWIFT_DIR}/Sources/ATMMenuBar.swift"
PLIST="${SWIFT_DIR}/Info.plist"

if [[ "${1:-}" = "--clean" ]]; then
    rm -rf "${APP_DIR}"
fi

if ! command -v swiftc >/dev/null 2>&1; then
    printf 'swiftc not found. Install Xcode Command Line Tools:\n' >&2
    printf '  xcode-select --install\n' >&2
    exit 1
fi

mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${PLIST}" "${APP_DIR}/Contents/Info.plist"

# -O = optimised, -whole-module-optimization for a single module.
# Keep the binary small; this is a status app, not a heavy renderer.
swiftc -O -whole-module-optimization \
    -framework AppKit \
    -framework SwiftUI \
    -framework Foundation \
    -o "${APP_DIR}/Contents/MacOS/atm-menubar" \
    "${SOURCES}"

# Ad-hoc signing is enough for launchd. Without it Gatekeeper may prompt
# the first time the user runs the app, which is harmless but ugly.
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true

printf 'Built: %s\n' "${APP_DIR}"
printf 'Run:   open %s\n' "${APP_DIR}"
