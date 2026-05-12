#!/usr/bin/env bats
# test_sync.bats - quota guard + abort-path tests for atm-sync.sh
#
# Strategy: stub the rclone binary with a tiny zsh script whose responses
# are driven by environment variables the test sets. Never touches the real
# rclone config or Google Drive.

setup() {
    TMPDIR_TEST="$(mktemp -d /tmp/atm-sync-test.XXXXXX)"
    export ATM_CONFIG=/dev/null
    export ATM_VERSIONS_DIR="${TMPDIR_TEST}/versions"
    export ATM_LOG="${TMPDIR_TEST}/atm.log"
    export ATM_SUMMARY="${TMPDIR_TEST}/atm-summary"
    export ATM_SYNC_LOCKFILE="${TMPDIR_TEST}/sync.lock"
    # Isolate notify state so tests don't read/write the real ~/.atm-notify-state
    export ATM_NOTIFY_STATE="${TMPDIR_TEST}/notify-state"
    export ATM_NOTIFY_LOG="${TMPDIR_TEST}/notify.log"
    export ATM_QUOTA_REMOTE="atm-gdrive"
    export ATM_SYNC_REMOTE="atm-crypt"
    export ATM_SYNC_PATH="versions"
    # NEVER fire real notifications during tests - they pile up in
    # Notification Center and can't be cleared programmatically.
    export ATM_NO_NOTIFY=1
    mkdir -p "${ATM_VERSIONS_DIR}/proj1"
    : > "${ATM_LOG}"
    : > "${ATM_SUMMARY}"

    # Build a stub rclone. It reads STUB_ABOUT_JSON, STUB_SIZE_JSON, and
    # STUB_SYNC_RC from the env to control responses. listremotes always
    # returns both remotes so the preflight passes; tests that need the
    # missing-remote path override it via STUB_LISTREMOTES.
    STUB_BIN="${TMPDIR_TEST}/bin"
    mkdir -p "${STUB_BIN}"
    cat > "${STUB_BIN}/rclone" <<'STUB'
#!/usr/bin/env zsh
case "$1" in
    listremotes)
        if [[ -n "${STUB_LISTREMOTES:-}" ]]; then
            printf '%s\n' "${STUB_LISTREMOTES}"
        else
            printf 'atm-gdrive:\natm-crypt:\n'
        fi
        ;;
    about)
        # $2 = remote, may have --json flag among rest
        if [[ "$*" == *--json* ]]; then
            printf '%s\n' "${STUB_ABOUT_JSON:-{\"total\":107374182400,\"used\":42949672960,\"free\":64424509440}}"
        else
            printf 'Total: 100 GiB\nUsed: 40 GiB\nFree: 60 GiB\n'
        fi
        ;;
    size)
        printf '%s\n' "${STUB_SIZE_JSON:-{\"count\":0,\"bytes\":0}}"
        ;;
    sync)
        # Honour STUB_SYNC_RC for failure injection
        exit "${STUB_SYNC_RC:-0}"
        ;;
    version)
        printf 'rclone v1.0.0-stub\n'
        ;;
    *)
        printf 'stub-rclone: unhandled %s\n' "$*" >&2
        exit 0
        ;;
esac
STUB
    chmod +x "${STUB_BIN}/rclone"
    export ATM_RCLONE="${STUB_BIN}/rclone"

    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/atm-sync.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "exits 0 silently when rclone is not installed (no notification)" {
    export ATM_RCLONE="/nonexistent/rclone"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'skip (not configured): rclone not installed' "${ATM_LOG}"
    # Critical: nothing fired into the notification dispatcher
    [ ! -s "${ATM_NOTIFY_LOG}" ]
}

@test "exits 0 silently when quota remote is not configured" {
    export STUB_LISTREMOTES="some-other-remote:"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q "quota remote 'atm-gdrive:' missing" "${ATM_LOG}"
    [ ! -s "${ATM_NOTIFY_LOG}" ]
}

@test "exits 0 silently when crypt remote is not configured" {
    export STUB_LISTREMOTES="atm-gdrive:"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q "crypt remote 'atm-crypt:' missing" "${ATM_LOG}"
    [ ! -s "${ATM_NOTIFY_LOG}" ]
}

@test "exits 0 with message when _versions/ does not exist" {
    rm -rf "${ATM_VERSIONS_DIR}"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'nothing to sync' "${ATM_LOG}"
}

@test "aborts when Drive free space is below floor" {
    # 5 GB free, floor is 10 GB
    export STUB_ABOUT_JSON='{"total":107374182400,"used":102005473280,"free":5368709120}'
    export ATM_FREE_FLOOR_GB=10
    run zsh "${SCRIPT}"
    [ "$status" -eq 1 ]
    grep -q 'Drive free 5GB below floor 10GB' "${ATM_LOG}"
}

@test "aborts when local _versions exceeds remote cap" {
    # Stub `du` to report 60 GB (in 1KB blocks: 60 * 1024 * 1024) so the
    # cap guard fires deterministically without creating GB-sized files.
    cat > "${STUB_BIN}/du" <<'DUSTUB'
#!/usr/bin/env zsh
# Mimic 'du -sk <path>' output: <kilobytes>\t<path>
# 60 GB = 60 * 1024 * 1024 = 62914560 KB
printf '62914560\t%s\n' "${@: -1}"
DUSTUB
    chmod +x "${STUB_BIN}/du"
    PATH="${STUB_BIN}:${PATH}" \
        ATM_REMOTE_CAP_GB=50 \
        run zsh "${SCRIPT}"
    [ "$status" -eq 1 ]
    grep -q 'exceeds cap 50GB' "${ATM_LOG}"
}

@test "successful sync writes ok status to summary" {
    printf 'tiny\n' > "${ATM_VERSIONS_DIR}/proj1/file.als"
    export STUB_SYNC_RC=0
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'ATM_SYNC_LAST_STATUS=ok' "${ATM_SUMMARY}"
    grep -q '\[SYNC\] ok in' "${ATM_LOG}"
}

@test "rclone sync failure surfaces non-zero exit and failed status" {
    printf 'tiny\n' > "${ATM_VERSIONS_DIR}/proj1/file.als"
    export STUB_SYNC_RC=1
    run zsh "${SCRIPT}"
    [ "$status" -eq 1 ]
    grep -q 'ATM_SYNC_LAST_STATUS=failed' "${ATM_SUMMARY}"
    grep -q '\[SYNC\] FAILED' "${ATM_LOG}"
}

@test "repeated identical failure does not double-notify (dedup)" {
    printf 'tiny\n' > "${ATM_VERSIONS_DIR}/proj1/file.als"
    export STUB_SYNC_RC=1
    # Three identical failures back-to-back
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    rm -f "${ATM_SYNC_LOCKFILE}"
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    rm -f "${ATM_SYNC_LOCKFILE}"
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    # Audit log: 1 fired entry, 2 suppressed for sync.run
    fired=$(awk -F'\t' '$2=="sync.run" && $4=="fired"' "${ATM_NOTIFY_LOG}" | wc -l | tr -d ' ')
    suppressed=$(awk -F'\t' '$2=="sync.run" && $4=="suppressed"' "${ATM_NOTIFY_LOG}" | wc -l | tr -d ' ')
    [ "${fired}" -eq 1 ]
    [ "${suppressed}" -eq 2 ]
}

@test "recovery after failure fires a notification" {
    printf 'tiny\n' > "${ATM_VERSIONS_DIR}/proj1/file.als"
    # First run: fail
    export STUB_SYNC_RC=1
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    rm -f "${ATM_SYNC_LOCKFILE}"
    # Second run: succeed -> recovery transition should fire
    export STUB_SYNC_RC=0
    run zsh "${SCRIPT}"; [ "$status" -eq 0 ]
    fired=$(awk -F'\t' '$2=="sync.run" && $4=="fired"' "${ATM_NOTIFY_LOG}" | wc -l | tr -d ' ')
    [ "${fired}" -eq 2 ]
}

@test "lockfile prevents concurrent runs" {
    # Pre-create lockfile with our PID (which is alive)
    printf '%d' "$$" > "${ATM_SYNC_LOCKFILE}"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'already running' "${ATM_LOG}"
    # Lockfile must NOT be removed by the second-instance early exit
    [ -f "${ATM_SYNC_LOCKFILE}" ]
}
