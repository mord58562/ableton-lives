#!/usr/bin/env zsh
# release.sh - build a public release tarball.
#
# Strips machine-local files (presets/local.preset, this user's caches, etc.)
# and produces ableton-lives-<version>.tar.gz.

set -euo pipefail

VERSION="${1:-$(date '+%Y.%m.%d')}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${SRC}/dist"
STAGE="${OUT_DIR}/ableton-lives-${VERSION}"

rm -rf "${STAGE}"
mkdir -p "${STAGE}"

# Copy everything except things we explicitly want to omit.
rsync -a --exclude '.git' \
         --exclude 'dist' \
         --exclude 'presets/local.preset' \
         --exclude 'presets/local.preset.stash' \
         --exclude 'RECON.md' \
         --exclude '.ableton-lives-*' \
         --exclude '*.log' \
         --exclude '.DS_Store' \
         --exclude 'tests/fixtures/*.als.bak' \
         "${SRC}/" "${STAGE}/"

# Sanity check: the public bundle must not contain personal identifiers
# or hardcoded /Users/<name>/ paths. The pattern is built from concatenated
# string literals so this script doesn't false-match itself when grep is
# run over a release that includes release.sh.
PERSONAL_PAT="rob""russell"
if grep -RIn "${PERSONAL_PAT}" "${STAGE}" --exclude-dir=.git \
        --include='*.sh' --include='*.md' --include='*.template' --include='*.plist' 2>/dev/null \
        | grep -v 'pre-cRob\|robust\|robot' >/dev/null; then
    printf '\n!! Personal references found in release bundle:\n'
    grep -RIn "${PERSONAL_PAT}" "${STAGE}" --exclude-dir=.git \
        --include='*.sh' --include='*.md' --include='*.template' --include='*.plist' \
        | grep -v 'pre-cRob\|robust\|robot'
    printf '\nFix these before releasing.\n'
    exit 1
fi
if grep -RIn '/Users/[a-zA-Z]' "${STAGE}" --exclude-dir=.git \
        --include='*.sh' --include='*.md' --include='*.template' --include='*.plist' >/dev/null; then
    printf '\n!! Hardcoded /Users/<name>/ paths found in release bundle:\n'
    grep -RIn '/Users/[a-zA-Z]' "${STAGE}" --exclude-dir=.git \
        --include='*.sh' --include='*.md' --include='*.template' --include='*.plist'
    printf '\nFix these before releasing.\n'
    exit 1
fi

cd "${OUT_DIR}"
tar -czf "ableton-lives-${VERSION}.tar.gz" "ableton-lives-${VERSION}"
printf 'Built: %s/ableton-lives-%s.tar.gz\n' "${OUT_DIR}" "${VERSION}"
