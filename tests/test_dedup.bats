#!/usr/bin/env bats
# test_dedup.bats - Tests for atm-watch.sh hash-based deduplication.
# Exercises: known hash skipped; new hash copied; stale entries pruned;
# absent seen-hashes file handled gracefully.

FIXTURE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures/fake.als"
FIXTURE_V2="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures/fake_v2.als"
WATCH_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/atm-watch.sh"

setup() {
    TEST_DIR="$(mktemp -d /tmp/atm-test-dedup.XXXXXX)"
    export TEST_DIR

    export ATM_CONFIG=/dev/null
    export ATM_VERSIONS_DIR="${TEST_DIR}/_versions"
    export ATM_LOG="${TEST_DIR}/atm.log"
    export ATM_SEEN_HASHES="${TEST_DIR}/.atm-seen-hashes"
    export ATM_SUMMARY="${TEST_DIR}/.atm-summary"
    export ATM_LOCKFILE="${TEST_DIR}/atm-watch.lock"
    export ATM_MTIME_WINDOW=30
    export ATM_INTERNAL_PATH="${TEST_DIR}/internal"
    export ATM_USB_PATH="${TEST_DIR}/usb2_absent"

    mkdir -p "${ATM_VERSIONS_DIR}" "${ATM_INTERNAL_PATH}"
}

teardown() {
    rm -rf "${TEST_DIR}"
    rm -f "${ATM_LOCKFILE}" 2>/dev/null || true
}

@test "skips_file_with_known_hash - no copy made when hash already in seen-hashes" {
    # Arrange: put the fixture hash in seen-hashes for today
    local als_file="${ATM_INTERNAL_PATH}/proj/track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    touch "${als_file}"  # fresh mtime

    local hash
    hash=$(shasum -a 256 "${als_file}" | awk '{print $1}')
    local today
    today=$(date '+%Y%m%d')
    echo "${hash} ${today}" > "${ATM_SEEN_HASHES}"

    # Act
    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Assert: no file copied - _versions/proj should be empty or not exist
    local copied_count
    copied_count=$(find "${ATM_VERSIONS_DIR}" -name '*.als' 2>/dev/null | wc -l | tr -d ' ')
    [ "${copied_count}" -eq 0 ]

    # Log should show dedup skip
    run grep -i "dedup\|skip" "${ATM_LOG}"
    [ "${status}" -eq 0 ]
}

@test "copies_file_with_new_hash - file copied and hash recorded when seen-hashes empty" {
    # Arrange: empty seen-hashes
    touch "${ATM_SEEN_HASHES}"

    local als_file="${ATM_INTERNAL_PATH}/proj/track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    touch "${als_file}"

    # Act
    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Assert: one file copied into _versions
    local copied_count
    copied_count=$(find "${ATM_VERSIONS_DIR}" -name '*.als' 2>/dev/null | wc -l | tr -d ' ')
    [ "${copied_count}" -eq 1 ]

    # Assert: hash is recorded in seen-hashes
    local hash
    hash=$(shasum -a 256 "${als_file}" | awk '{print $1}')
    run grep "${hash}" "${ATM_SEEN_HASHES}"
    [ "${status}" -eq 0 ]
}

@test "prunes_stale_hash_entries - yesterday's hash removed; file treated as new" {
    # Arrange: put hash with yesterday's date in seen-hashes
    local als_file="${ATM_INTERNAL_PATH}/proj/track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    touch "${als_file}"

    local hash
    hash=$(shasum -a 256 "${als_file}" | awk '{print $1}')
    local yesterday
    yesterday=$(date -v-1d '+%Y%m%d' 2>/dev/null || date -d 'yesterday' '+%Y%m%d' 2>/dev/null)
    echo "${hash} ${yesterday}" > "${ATM_SEEN_HASHES}"

    # Act
    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Assert: stale entry was pruned and the file was copied (treated as new)
    local copied_count
    copied_count=$(find "${ATM_VERSIONS_DIR}" -name '*.als' 2>/dev/null | wc -l | tr -d ' ')
    [ "${copied_count}" -eq 1 ]

    # Assert: log mentions hash prune
    run grep -i "prune\|stale" "${ATM_LOG}"
    [ "${status}" -eq 0 ]
}

@test "handles_empty_seen_hashes_file - absent seen-hashes created and copy proceeds" {
    # Arrange: no seen-hashes file at all
    [ ! -f "${ATM_SEEN_HASHES}" ]

    local als_file="${ATM_INTERNAL_PATH}/proj/track.als"
    mkdir -p "$(dirname "${als_file}")"
    cp "${FIXTURE}" "${als_file}"
    touch "${als_file}"

    # Act
    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Assert: seen-hashes was created
    [ -f "${ATM_SEEN_HASHES}" ]

    # Assert: file was copied
    local copied_count
    copied_count=$(find "${ATM_VERSIONS_DIR}" -name '*.als' 2>/dev/null | wc -l | tr -d ' ')
    [ "${copied_count}" -eq 1 ]
}
