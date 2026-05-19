#!/usr/bin/env bats
# test_restore_roundtrip.bats - Full data-path test without launchd.
# Write fixture -> copy -> modify -> copy -> restore older -> verify byte-equality.
# This is the most important test. Exercises: copy creates files, timestamps
# sort correctly, restore picks the right version, .bak preserves overwritten file.

FIXTURE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures/fake.als"
FIXTURE_V2="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures/fake_v2.als"
WATCH_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/lives-watch.sh"
RESTORE_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/lives-restore.sh"

setup() {
    TEST_DIR="$(mktemp -d /tmp/lives-test-roundtrip.XXXXXX)"
    export TEST_DIR

    export LIVES_CONFIG=/dev/null
    export LIVES_VERSIONS_DIR="${TEST_DIR}/_versions"
    export LIVES_LOG="${TEST_DIR}/atm.log"
    export LIVES_SEEN_HASHES="${TEST_DIR}/.ableton-lives-seen-hashes"
    export LIVES_SUMMARY="${TEST_DIR}/.ableton-lives-summary"
    export LIVES_LOCKFILE="${TEST_DIR}/lives-watch.lock"
    export LIVES_MTIME_WINDOW=30
    export LIVES_INTERNAL_PATH="${TEST_DIR}/internal"
    export LIVES_USB_PATH="${TEST_DIR}/usb2_absent"

    mkdir -p "${LIVES_VERSIONS_DIR}" "${LIVES_INTERNAL_PATH}"

    # Create a project directory
    PROJECT_NAME="test_roundtrip_project"
    PROJECT_DIR="${LIVES_INTERNAL_PATH}/${PROJECT_NAME}"
    mkdir -p "${PROJECT_DIR}"
    export PROJECT_NAME PROJECT_DIR

    ALS_FILE="${PROJECT_DIR}/my_track.als"
    export ALS_FILE
}

teardown() {
    rm -rf "${TEST_DIR}"
    rm -f "${LIVES_LOCKFILE}" 2>/dev/null || true
}

@test "full_restore_roundtrip - write v1, copy, modify to v2, copy, restore v1, assert byte-equal" {
    # Step 1: Write fixture v1 as the .als file
    cp "${FIXTURE}" "${ALS_FILE}"
    touch "${ALS_FILE}"

    local sha_v1
    sha_v1=$(shasum -a 256 "${ALS_FILE}" | awk '{print $1}')

    # Step 2: Run watcher to copy version 1
    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Verify version 1 exists in _versions/
    local v1_count
    v1_count=$(find "${LIVES_VERSIONS_DIR}/${PROJECT_NAME}" -name 'my_track-*.als' 2>/dev/null | wc -l | tr -d ' ')
    [ "${v1_count}" -ge 1 ]

    # Get the timestamp of v1
    local ts_v1
    ts_v1=$(find "${LIVES_VERSIONS_DIR}/${PROJECT_NAME}" -name 'my_track-*.als' \
        | sed 's|.*/||;s/my_track-//;s/\.als$//' | sort | head -1)
    [ -n "${ts_v1}" ]

    # Step 3: Sleep 1s to guarantee distinct timestamp, then modify .als to v2
    sleep 1

    # Overwrite with different content (v2)
    cp "${FIXTURE_V2}" "${ALS_FILE}"
    touch "${ALS_FILE}"

    local sha_v2
    sha_v2=$(shasum -a 256 "${ALS_FILE}" | awk '{print $1}')

    # Verify v1 and v2 are actually different
    [ "${sha_v1}" != "${sha_v2}" ]

    # Step 4: Run watcher again to copy version 2
    # Reset lockfile (previous run cleaned it up, but just in case)
    rm -f "${LIVES_LOCKFILE}"
    run zsh "${WATCH_SCRIPT}"
    [ "${status}" -eq 0 ]

    # Verify two versions now exist
    local total_versions
    total_versions=$(find "${LIVES_VERSIONS_DIR}/${PROJECT_NAME}" -name 'my_track-*.als' 2>/dev/null | wc -l | tr -d ' ')
    [ "${total_versions}" -ge 2 ]

    # Step 5: Restore version 1 using lives-restore.sh --restore
    run zsh "${RESTORE_SCRIPT}" --restore "${PROJECT_NAME}" "${ts_v1}" "${ALS_FILE}"
    [ "${status}" -eq 0 ]

    # Step 6: Assert restored file bytes match v1 exactly
    local sha_restored
    sha_restored=$(shasum -a 256 "${ALS_FILE}" | awk '{print $1}')
    [ "${sha_restored}" = "${sha_v1}" ]

    # Step 7: Assert .bak exists and contains v2 content
    [ -f "${ALS_FILE}.bak" ]
    local sha_bak
    sha_bak=$(shasum -a 256 "${ALS_FILE}.bak" | awk '{print $1}')
    [ "${sha_bak}" = "${sha_v2}" ]
}

@test "restore_list_returns_newest_first - versions listed with newest timestamp at top" {
    # Create two versioned files with distinct timestamps (older first)
    local proj_dir="${LIVES_VERSIONS_DIR}/${PROJECT_NAME}"
    mkdir -p "${proj_dir}"

    # Create older version
    cp "${FIXTURE}" "${proj_dir}/my_track-20260101-120000.als"
    # Create newer version
    cp "${FIXTURE_V2}" "${proj_dir}/my_track-20260201-130000.als"

    run zsh "${RESTORE_SCRIPT}" --list "${PROJECT_NAME}"
    [ "${status}" -eq 0 ]

    # First line should be the newer timestamp
    local first_line
    first_line=$(echo "${output}" | head -1)
    [ "${first_line}" = "20260201-130000" ]

    # Second line should be the older timestamp
    local second_line
    second_line=$(echo "${output}" | sed -n '2p')
    [ "${second_line}" = "20260101-120000" ]
}

@test "restore_writes_bak_before_overwrite - D5 invariant: .bak always created" {
    # Arrange: create a live .als file and a versioned copy
    cp "${FIXTURE}" "${ALS_FILE}"
    touch "${ALS_FILE}"

    local original_sha
    original_sha=$(shasum -a 256 "${ALS_FILE}" | awk '{print $1}')

    local proj_dir="${LIVES_VERSIONS_DIR}/${PROJECT_NAME}"
    mkdir -p "${proj_dir}"
    cp "${FIXTURE_V2}" "${proj_dir}/my_track-20260112-100000.als"

    # Act: restore
    run zsh "${RESTORE_SCRIPT}" --restore "${PROJECT_NAME}" "20260112-100000" "${ALS_FILE}"
    [ "${status}" -eq 0 ]

    # Assert: .bak was created
    [ -f "${ALS_FILE}.bak" ]

    # Assert: .bak contains the original content (not the restored version)
    local bak_sha
    bak_sha=$(shasum -a 256 "${ALS_FILE}.bak" | awk '{print $1}')
    [ "${bak_sha}" = "${original_sha}" ]

    # Assert: the live file now has v2 content
    local restored_sha
    restored_sha=$(shasum -a 256 "${ALS_FILE}" | awk '{print $1}')
    local v2_sha
    v2_sha=$(shasum -a 256 "${proj_dir}/my_track-20260112-100000.als" | awk '{print $1}')
    [ "${restored_sha}" = "${v2_sha}" ]
}

@test "restore_nonexistent_version_exits_nonzero - error on unknown timestamp" {
    local proj_dir="${LIVES_VERSIONS_DIR}/${PROJECT_NAME}"
    mkdir -p "${proj_dir}"

    run zsh "${RESTORE_SCRIPT}" --restore "${PROJECT_NAME}" "99991231-235959" "${ALS_FILE}"
    [ "${status}" -ne 0 ]
}

@test "restore_list_empty_project_exits_0 - no output for project with no versions" {
    # Project dir does not exist
    run zsh "${RESTORE_SCRIPT}" --list "nonexistent_project_xyz"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
