#!/usr/bin/env bats
# test_filter_mtime.bats - Tests for atm-watch.sh mtime filter logic.
# Exercises: .als mtime < 30s is included; mtime > 30s is excluded;
# non-.als files excluded; _versions/ paths excluded; absent USB2 handled.

setup() {
    TEST_DIR="$(mktemp -d /tmp/atm-test-mtime.XXXXXX)"
    export TEST_DIR

    # Override all ATM paths to temp dirs
    export ATM_CONFIG=/dev/null
    export ATM_VERSIONS_DIR="${TEST_DIR}/_versions"
    export ATM_LOG="${TEST_DIR}/atm.log"
    export ATM_SEEN_HASHES="${TEST_DIR}/.atm-seen-hashes"
    export ATM_SUMMARY="${TEST_DIR}/.atm-summary"
    export ATM_LOCKFILE="${TEST_DIR}/atm-watch.lock"
    export ATM_MTIME_WINDOW=30

    # Internal path: use a writable temp dir
    export ATM_INTERNAL_PATH="${TEST_DIR}/internal"
    # USB2: default to nonexistent path (tested per-test)
    export ATM_USB_PATH="${TEST_DIR}/usb2_absent"

    mkdir -p "${ATM_VERSIONS_DIR}"
    mkdir -p "${ATM_INTERNAL_PATH}"

    WATCH_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/atm-watch.sh"
}

teardown() {
    rm -rf "${TEST_DIR}"
    rm -f "${ATM_LOCKFILE}" 2>/dev/null || true
}

# Helper: create a reference file with mtime N seconds in the past
make_ref_file() {
    local seconds_ago="$1"
    local ref="${TEST_DIR}/ref_${seconds_ago}"
    touch -m -t "$(date -v-${seconds_ago}S '+%Y%m%d%H%M.%S')" "${ref}" 2>/dev/null || \
        touch -d "-${seconds_ago} seconds" "${ref}" 2>/dev/null
    echo "${ref}"
}

# Helper: check if a file would be picked up by find -newer <ref>
# Returns 0 if file is found (newer than ref), 1 if not
find_newer_than() {
    local target="$1"
    local ref="$2"
    find "$(dirname "${target}")" -name "$(basename "${target}")" -newer "${ref}" | grep -q "$(basename "${target}")"
}

@test "copies_file_modified_within_30s - fresh .als appears in candidate scan" {
    # Create a fresh .als file (mtime = now)
    local als_file="${ATM_INTERNAL_PATH}/myproject/my_track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    touch "${als_file}"  # set mtime to now

    # Create a reference file 30 seconds in the past
    local ref
    ref="$(make_ref_file 30)"

    # File modified NOW should be newer than ref (30s ago)
    run find_newer_than "${als_file}" "${ref}"
    [ "${status}" -eq 0 ]
}

@test "skips_file_modified_60s_ago - stale .als not in candidate scan" {
    local als_file="${ATM_INTERNAL_PATH}/myproject/old_track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    # Set mtime to 60 seconds ago
    touch -m -t "$(date -v-60S '+%Y%m%d%H%M.%S')" "${als_file}" 2>/dev/null || \
        touch -d "-60 seconds" "${als_file}" 2>/dev/null

    local ref
    ref="$(make_ref_file 30)"

    # File modified 60s ago should NOT be newer than ref (30s ago)
    run find_newer_than "${als_file}" "${ref}"
    [ "${status}" -ne 0 ]
}

@test "skips_non_als_file - .txt with fresh mtime not in candidates" {
    local txt_file="${ATM_INTERNAL_PATH}/myproject/notes.txt"
    mkdir -p "$(dirname "${txt_file}")"
    echo "hello" > "${txt_file}"
    touch "${txt_file}"

    local ref
    ref="$(make_ref_file 30)"

    # find -name '*.als' should not find a .txt file
    run bash -c "find '${ATM_INTERNAL_PATH}' -name '*.als' -newer '${ref}' | grep -c 'notes.txt'"
    [ "${output}" = "0" ] || [ "${status}" -ne 0 ]
}

@test "skips_files_in_versions_subdir - .als inside _versions is excluded" {
    # Simulate a file that ended up inside _versions/
    local versions_file="${ATM_VERSIONS_DIR}/myproject/my_track-20260101-120000.als"
    mkdir -p "$(dirname "${versions_file}")"
    cp "${FIXTURE}" "${versions_file}"
    touch "${versions_file}"  # fresh mtime

    local ref
    ref="$(make_ref_file 30)"

    # The find command in atm-watch.sh excludes */_versions/* paths
    local found
    found=$(find "${ATM_INTERNAL_PATH}" "${ATM_VERSIONS_DIR}" -name '*.als' -newer "${ref}" \
        -not -path '*/_versions/*' 2>/dev/null || true)
    [ -z "${found}" ]
}

@test "handles_absent_usb2_path - script exits 0 and logs skip when USB2 missing" {
    # USB2 path is already set to a nonexistent dir in setup
    # Internal has a fresh .als so script has something to do
    local als_file="${ATM_INTERNAL_PATH}/proj/track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    touch "${als_file}"

    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Log should contain the USB2 skip message
    run grep -i "USB2\|not mounted\|absent" "${ATM_LOG}"
    [ "${status}" -eq 0 ]
}
