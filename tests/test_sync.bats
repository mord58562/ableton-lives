#!/usr/bin/env bats
# test_sync.bats - quota guard + abort-path tests for lives-sync.sh
#
# Strategy: stub the rclone binary with a tiny zsh script whose responses
# are driven by environment variables the test sets. Never touches the real
# rclone config or Google Drive.

setup() {
    TMPDIR_TEST="$(mktemp -d /tmp/lives-sync-test.XXXXXX)"
    export LIVES_CONFIG=/dev/null
    export LIVES_VERSIONS_DIR="${TMPDIR_TEST}/versions"
    export LIVES_LOG="${TMPDIR_TEST}/atm.log"
    export LIVES_SUMMARY="${TMPDIR_TEST}/lives-summary"
    export LIVES_SYNC_LOCKFILE="${TMPDIR_TEST}/sync.lock"
    # Isolate notify state so tests don't read/write the real ~/.ableton-lives-notify-state
    export LIVES_NOTIFY_STATE="${TMPDIR_TEST}/notify-state"
    export LIVES_NOTIFY_LOG="${TMPDIR_TEST}/notify.log"
    export LIVES_QUOTA_REMOTE="lives-gdrive"
    export LIVES_SYNC_REMOTE="lives-crypt"
    export LIVES_SYNC_PATH="versions"
    # NEVER fire real notifications during tests - they pile up in
    # Notification Center and can't be cleared programmatically.
    export LIVES_NO_NOTIFY=1
    mkdir -p "${LIVES_VERSIONS_DIR}/proj1"
    : > "${LIVES_LOG}"
    : > "${LIVES_SUMMARY}"

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
            printf 'lives-gdrive:\nlives-crypt:\n'
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
    export LIVES_RCLONE="${STUB_BIN}/rclone"

    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/lives-sync.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "exits 0 silently when rclone is not installed (no notification)" {
    export LIVES_RCLONE="/nonexistent/rclone"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'skip (not configured): rclone not installed' "${LIVES_LOG}"
    # Critical: nothing fired into the notification dispatcher
    [ ! -s "${LIVES_NOTIFY_LOG}" ]
}

@test "exits 0 silently when quota remote is not configured" {
    export STUB_LISTREMOTES="some-other-remote:"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q "quota remote 'lives-gdrive:' missing" "${LIVES_LOG}"
    [ ! -s "${LIVES_NOTIFY_LOG}" ]
}

@test "exits 0 silently when crypt remote is not configured" {
    export STUB_LISTREMOTES="lives-gdrive:"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q "crypt remote 'lives-crypt:' missing" "${LIVES_LOG}"
    [ ! -s "${LIVES_NOTIFY_LOG}" ]
}

@test "exits 0 with message when _versions/ does not exist" {
    rm -rf "${LIVES_VERSIONS_DIR}"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'nothing to sync' "${LIVES_LOG}"
}

@test "aborts when Drive free space is below floor" {
    # 5 GB free, floor is 10 GB
    export STUB_ABOUT_JSON='{"total":107374182400,"used":102005473280,"free":5368709120}'
    export LIVES_FREE_FLOOR_GB=10
    run zsh "${SCRIPT}"
    [ "$status" -eq 1 ]
    grep -q 'Drive free 5GB below floor 10GB' "${LIVES_LOG}"
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
        LIVES_REMOTE_CAP_GB=50 \
        run zsh "${SCRIPT}"
    [ "$status" -eq 1 ]
    grep -q 'exceeds cap 50GB' "${LIVES_LOG}"
}

@test "successful sync writes ok status to summary" {
    printf 'tiny\n' > "${LIVES_VERSIONS_DIR}/proj1/file.als"
    export STUB_SYNC_RC=0
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'LIVES_SYNC_LAST_STATUS=ok' "${LIVES_SUMMARY}"
    grep -q '\[SYNC\] ok in' "${LIVES_LOG}"
}

@test "rclone sync failure surfaces non-zero exit and failed status" {
    printf 'tiny\n' > "${LIVES_VERSIONS_DIR}/proj1/file.als"
    export STUB_SYNC_RC=1
    run zsh "${SCRIPT}"
    [ "$status" -eq 1 ]
    grep -q 'LIVES_SYNC_LAST_STATUS=failed' "${LIVES_SUMMARY}"
    grep -q '\[SYNC\] FAILED' "${LIVES_LOG}"
}

@test "repeated identical failure does not double-notify (dedup)" {
    printf 'tiny\n' > "${LIVES_VERSIONS_DIR}/proj1/file.als"
    export STUB_SYNC_RC=1
    # Three identical failures back-to-back
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    rm -f "${LIVES_SYNC_LOCKFILE}"
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    rm -f "${LIVES_SYNC_LOCKFILE}"
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    # Audit log: 1 fired entry, 2 suppressed for sync.run
    fired=$(awk -F'\t' '$2=="sync.run" && $4=="fired"' "${LIVES_NOTIFY_LOG}" | wc -l | tr -d ' ')
    suppressed=$(awk -F'\t' '$2=="sync.run" && $4=="suppressed"' "${LIVES_NOTIFY_LOG}" | wc -l | tr -d ' ')
    [ "${fired}" -eq 1 ]
    [ "${suppressed}" -eq 2 ]
}

@test "recovery after failure fires a notification" {
    printf 'tiny\n' > "${LIVES_VERSIONS_DIR}/proj1/file.als"
    # First run: fail
    export STUB_SYNC_RC=1
    run zsh "${SCRIPT}"; [ "$status" -eq 1 ]
    rm -f "${LIVES_SYNC_LOCKFILE}"
    # Second run: succeed -> recovery transition should fire
    export STUB_SYNC_RC=0
    run zsh "${SCRIPT}"; [ "$status" -eq 0 ]
    fired=$(awk -F'\t' '$2=="sync.run" && $4=="fired"' "${LIVES_NOTIFY_LOG}" | wc -l | tr -d ' ')
    [ "${fired}" -eq 2 ]
}

@test "lockfile prevents concurrent runs" {
    # Pre-create lockfile with our PID (which is alive)
    printf '%d' "$$" > "${LIVES_SYNC_LOCKFILE}"
    run zsh "${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'already running' "${LIVES_LOG}"
    # Lockfile must NOT be removed by the second-instance early exit
    [ -f "${LIVES_SYNC_LOCKFILE}" ]
}
