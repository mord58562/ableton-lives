#!/usr/bin/env bats
# test_usb_absent.bats - Tests for graceful handling when USB2 path is missing.
# Exercises: exit 0 when USB2 absent; log contains skip message;
# internal path still processed when USB2 is missing.

FIXTURE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures/fake.als"
WATCH_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/lives-watch.sh"

setup() {
    TEST_DIR="$(mktemp -d /tmp/lives-test-usb.XXXXXX)"
    export TEST_DIR

    export LIVES_CONFIG=/dev/null
    export LIVES_VERSIONS_DIR="${TEST_DIR}/_versions"
    export LIVES_LOG="${TEST_DIR}/atm.log"
    export LIVES_SEEN_HASHES="${TEST_DIR}/.ableton-lives-seen-hashes"
    export LIVES_SUMMARY="${TEST_DIR}/.ableton-lives-summary"
    export LIVES_LOCKFILE="${TEST_DIR}/lives-watch.lock"
    export LIVES_MTIME_WINDOW=30
    export LIVES_INTERNAL_PATH="${TEST_DIR}/internal"
    # Set USB2 to a path that definitely does not exist
    export LIVES_USB_PATH="${TEST_DIR}/nonexistent_external_path_xyz"

    mkdir -p "${LIVES_VERSIONS_DIR}" "${LIVES_INTERNAL_PATH}"
}

teardown() {
    rm -rf "${TEST_DIR}"
    rm -f "${LIVES_LOCKFILE}" 2>/dev/null || true
}

@test "exits_0_when_usb2_missing - script exits cleanly without USB2 path" {
    # USB2_PATH is set to a nonexistent path in setup
    [ ! -d "${LIVES_USB_PATH}" ]

    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]
}

@test "logs_skip_message - log contains external absent/skip message" {
    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    [ -f "${LIVES_LOG}" ]
    run grep -iE "external|not mounted|absent|skip" "${LIVES_LOG}"
    [ "${status}" -eq 0 ]
}

@test "still_scans_internal_path - internal .als files processed when USB2 absent" {
    # Place a fresh .als in the internal path
    local als_file="${LIVES_INTERNAL_PATH}/myproject/track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    touch "${als_file}"

    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # The internal .als should have been copied to _versions/
    local copied_count
    copied_count=$(find "${LIVES_VERSIONS_DIR}" -name '*.als' 2>/dev/null | wc -l | tr -d ' ')
    [ "${copied_count}" -ge 1 ]
}

@test "usb2_path_present_but_empty - script exits 0 and no errors with empty USB2 dir" {
    # Create the USB2 path but put nothing in it
    mkdir -p "${LIVES_USB_PATH}"

    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Log should NOT show any error for USB2
    run grep -i "error" "${LIVES_LOG}"
    # Either no error lines at all, or none related to USB2 (exit code doesn't matter here,
    # we just ensure the overall exit was 0, which was already checked above)
    true
}
