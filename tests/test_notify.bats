#!/usr/bin/env bats
# test_notify.bats - lib/atm-notify.sh: state-transition + dedup behaviour.
#
# These tests verify the *audit log* (which is always written), not real
# macOS notifications. ATM_NO_NOTIFY=1 prevents osascript from being called,
# but the dispatcher still records what it would have fired.

LIB="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/lib/atm-notify.sh"

setup() {
    TMP="$(mktemp -d /tmp/atm-notify-test.XXXXXX)"
    export ATM_NOTIFY_STATE="${TMP}/state"
    export ATM_NOTIFY_LOG="${TMP}/audit.log"
    export ATM_NO_NOTIFY=1
    : > "${ATM_NOTIFY_LOG}"
}

teardown() {
    rm -rf "${TMP}"
}

# Run a single dispatch in a subshell that sources the lib.
dispatch() {
    zsh -c "source '${LIB}'; atm_notify_event \"\$@\"" -- "$@"
}

# Count fired vs suppressed entries in the audit log.
count_fired() {
    awk -F'\t' -v want="$1" 'BEGIN{c=0} $4==want {c++} END{print c}' "${ATM_NOTIFY_LOG}"
}

@test "first event of a category is logged AND fires" {
    dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    [ "$(count_fired fired)" -eq 1 ]
    [ "$(count_fired suppressed)" -eq 0 ]
}

@test "identical event within dedup window is suppressed" {
    dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    # 1 fired, 2 suppressed
    [ "$(count_fired fired)" -eq 1 ]
    [ "$(count_fired suppressed)" -eq 2 ]
}

@test "different message in same category fires (state transition)" {
    dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    dispatch "sync.run" "error" "Sync failed" "rclone exit 7 (auth)"
    [ "$(count_fired fired)" -eq 2 ]
}

@test "recovery from non-ok to ok fires" {
    dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    dispatch "sync.run" "ok" "Sync recovered" "back to normal"
    [ "$(count_fired fired)" -eq 2 ]
}

@test "first ever event with status=ok is silent (baseline)" {
    dispatch "sync.run" "ok" "All good" "everything works"
    [ "$(count_fired fired)" -eq 0 ]
    [ "$(count_fired suppressed)" -eq 1 ]
}

@test "ok-after-ok is silent" {
    dispatch "sync.run" "ok" "All good" "everything works"
    dispatch "sync.run" "ok" "All good" "everything works"
    [ "$(count_fired fired)" -eq 0 ]
}

@test "different categories are tracked independently" {
    dispatch "sync.run" "error" "Sync failed" "x"
    dispatch "prune.large" "warn" "Prune big" "y"
    [ "$(count_fired fired)" -eq 2 ]
}

@test "elapsed > dedup window re-fires the same event" {
    dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    # Backdate the fire epoch beyond the dedup window
    perl -i -pe 's/^sync\.run\.fire_epoch=.*/sync.run.fire_epoch=1/' "${ATM_NOTIFY_STATE}"
    ATM_NOTIFY_DEDUP_HOURS=1 dispatch "sync.run" "error" "Sync failed" "rclone exit 1"
    [ "$(count_fired fired)" -eq 2 ]
}

@test "audit log contains category, status, and message fields" {
    dispatch "sync.run" "error" "Sync failed" "details here"
    grep -q $'\tsync.run\terror\tfired\tSync failed\tdetails here' "${ATM_NOTIFY_LOG}"
}

@test "atm_notify_clear resets state without firing" {
    dispatch "sync.run" "error" "Sync failed" "x"
    zsh -c "source '${LIB}'; atm_notify_clear sync.run"
    # Next error event should fire because state is cleared
    dispatch "sync.run" "error" "Sync failed" "x"
    [ "$(count_fired fired)" -eq 2 ]
}
