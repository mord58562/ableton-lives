#!/usr/bin/env zsh
# smoke.sh - Smoke test for Ableton Lives.
# Tests the copy logic directly against a temp directory WITHOUT touching:
#   - /Volumes/<your-external>/ (irreplaceable, 100% full)
#   - ~/Music/Ableton/ (real workspace)
#
# Usage: zsh tests/smoke.sh
# Exit 0 on pass, 1 on fail.
#
# Called by install.sh after loading plists. Also runnable standalone
# for dev testing (does NOT require launchd to be active).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE="${SCRIPT_DIR}/fixtures/fake.als"
WATCH_SCRIPT="${PROJECT_ROOT}/bin/lives-watch.sh"

# Use /tmp for all smoke test I/O - never touch real paths
SMOKE_DIR="/tmp/lives-smoke-$$"
SMOKE_VERSIONS="${SMOKE_DIR}/_versions"
SMOKE_INTERNAL="${SMOKE_DIR}/internal"
SMOKE_LOG="${SMOKE_DIR}/lives-smoke.log"
SMOKE_HASHES="${SMOKE_DIR}/.ableton-lives-smoke-hashes"
SMOKE_SUMMARY="${SMOKE_DIR}/.ableton-lives-smoke-summary"
SMOKE_LOCKFILE="${SMOKE_DIR}/lives-watch.lock"

cleanup() {
    rm -rf "${SMOKE_DIR}"
}
trap cleanup EXIT

printf '[SMOKE] starting smoke test in %s\n' "${SMOKE_DIR}"
mkdir -p "${SMOKE_VERSIONS}" "${SMOKE_INTERNAL}/smoke_project"

# Create a fresh .als file to copy
TEST_ALS="${SMOKE_INTERNAL}/smoke_project/smoke_track.als"
cp "${FIXTURE}" "${TEST_ALS}"
touch "${TEST_ALS}"  # mtime = now

printf '[SMOKE] invoking lives-watch.sh against temp paths\n'

# Override all paths to point at temp dirs (NOT real workspace)
LIVES_VERSIONS_DIR="${SMOKE_VERSIONS}" \
LIVES_LOG="${SMOKE_LOG}" \
LIVES_SEEN_HASHES="${SMOKE_HASHES}" \
LIVES_SUMMARY="${SMOKE_SUMMARY}" \
LIVES_LOCKFILE="${SMOKE_LOCKFILE}" \
LIVES_INTERNAL_PATH="${SMOKE_INTERNAL}" \
LIVES_USB_PATH="${SMOKE_DIR}/usb2_absent" \
LIVES_MTIME_WINDOW=30 \
    zsh "${WATCH_SCRIPT}"
exit_code=$?

if [[ "${exit_code}" -ne 0 ]]; then
    printf '[SMOKE FAIL] lives-watch.sh exited with code %d\n' "${exit_code}"
    printf '[SMOKE] log output:\n'
    cat "${SMOKE_LOG}" 2>/dev/null || true
    exit 1
fi

# Poll for the versioned copy (up to 10 seconds)
printf '[SMOKE] polling for version copy...\n'
found=0
for i in $(seq 1 10); do
    count=$(find "${SMOKE_VERSIONS}" -name 'smoke_track-*.als' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${count}" -ge 1 ]]; then
        found=1
        break
    fi
    sleep 1
done

if [[ "${found}" -eq 0 ]]; then
    printf '[SMOKE FAIL] no versioned copy found after 10s\n'
    printf '[SMOKE] log:\n'
    cat "${SMOKE_LOG}" 2>/dev/null || true
    exit 1
fi

# Verify the copy is a valid gzip file (real .als must be valid gzip)
found_file=$(find "${SMOKE_VERSIONS}" -name 'smoke_track-*.als' | head -1)
if ! gunzip -t "${found_file}" 2>/dev/null; then
    printf '[SMOKE FAIL] copied file is not valid gzip: %s\n' "${found_file}"
    exit 1
fi

# Verify byte equality
original_sha=$(shasum -a 256 "${TEST_ALS}" | awk '{print $1}')
copy_sha=$(shasum -a 256 "${found_file}" | awk '{print $1}')
if [[ "${original_sha}" != "${copy_sha}" ]]; then
    printf '[SMOKE FAIL] copy SHA mismatch: original=%s copy=%s\n' "${original_sha}" "${copy_sha}"
    exit 1
fi

printf '[SMOKE PASS] version copy detected: %s\n' "${found_file}"
printf '[SMOKE PASS] SHA-256 verified: %s\n' "${original_sha}"
printf '[SMOKE PASS] lives-watch.sh log:\n'
cat "${SMOKE_LOG}" 2>/dev/null || true
printf '\n[SMOKE PASS] all checks passed\n'
exit 0
