#!/usr/bin/env zsh
# lives-notify.sh - central notification dispatcher for Ableton Lives
#
# Source from any Ableton Lives script. Provides one function:
#
#   lives_notify_event <category> <status> <title> <message>
#     category: short identifier (e.g., "sync", "prune.large", "crash")
#     status:   ok | warn | error
#     title:    notification title (shown bold)
#     message:  notification body (<=170 chars recommended)
#
# Suppression policy (the whole reason this exists):
#   - Audit log is ALWAYS written. Useful for menu bar, debugging,
#     "what did Ableton Lives tell me last week" forensics, and tests.
#   - The macOS notification fires only when ONE of:
#       (a) fingerprint (status + message) differs from last for category;
#       (b) status went from non-ok to ok (a recovery is news);
#       (c) elapsed since last *fire* > LIVES_NOTIFY_DEDUP_HOURS (default 24).
#   - First-ever event of a given category with status=ok stays silent
#     (it's the baseline; nothing has gone wrong yet).
#   - LIVES_NO_NOTIFY=1 hard-suppresses the macOS fire (audit log still
#     written). Tests must set this; production scripts must not.
#
# Files:
#   LIVES_NOTIFY_STATE   ~/.ableton-lives-notify-state (key=value, one per line)
#   LIVES_NOTIFY_LOG     ~/Library/Logs/ableton-lives-notifications.log
#                      (one tab-separated line per event:
#                       ISO_TS \t category \t status \t fired \t title \t message)

LIVES_NOTIFY_STATE="${LIVES_NOTIFY_STATE:-${HOME}/.ableton-lives-notify-state}"
LIVES_NOTIFY_LOG="${LIVES_NOTIFY_LOG:-${HOME}/Library/Logs/ableton-lives-notifications.log}"
LIVES_NOTIFY_DEDUP_HOURS="${LIVES_NOTIFY_DEDUP_HOURS:-24}"

# Read a key from the state file. Empty if absent. Always returns 0 -
# callers source this lib from scripts with `set -euo pipefail`, where a
# failing pipeline (grep finding nothing) would propagate up through the
# command substitution and kill the caller after a successful sync.
_lives_state_get() {
    local key="$1"
    [[ -f "${LIVES_NOTIFY_STATE}" ]] || return 0
    grep -E "^${key}=" "${LIVES_NOTIFY_STATE}" 2>/dev/null | tail -1 | cut -d= -f2- || true
    return 0
}

# Write/update a key in the state file atomically.
# Multiple keys per call: _lives_state_set k1 v1 k2 v2 ...
_lives_state_set() {
    mkdir -p "$(dirname "${LIVES_NOTIFY_STATE}")"
    local tmp="${LIVES_NOTIFY_STATE}.tmp.$$"
    : > "${tmp}"
    # Copy existing, dropping keys we're about to set
    if [[ -f "${LIVES_NOTIFY_STATE}" ]]; then
        local skip_pat=""
        local i=1
        while [[ ${i} -le $# ]]; do
            local k="${(P)i}"
            [[ -z "${skip_pat}" ]] && skip_pat="^${k}=" || skip_pat="${skip_pat}|^${k}="
            i=$(( i + 2 ))
        done
        grep -Ev "${skip_pat}" "${LIVES_NOTIFY_STATE}" >> "${tmp}" 2>/dev/null || true
    fi
    # Append new key/value pairs
    local i=1
    while [[ ${i} -le $# ]]; do
        local k="${(P)i}"
        local j=$(( i + 1 ))
        local v="${(P)j}"
        printf '%s=%s\n' "${k}" "${v}" >> "${tmp}"
        i=$(( i + 2 ))
    done
    mv "${tmp}" "${LIVES_NOTIFY_STATE}"
}

# Compute a stable fingerprint over status+message.
_lives_fingerprint() {
    printf '%s\n%s' "$1" "$2" | shasum -a 256 | awk '{print $1}'
}

# Append a line to the audit log.
_lives_audit_log() {
    local category="$1" event_status="$2" fired="$3" title="$4" message="$5"
    mkdir -p "$(dirname "${LIVES_NOTIFY_LOG}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" \
        "${category}" "${event_status}" "${fired}" \
        "${title}" "${message}" >> "${LIVES_NOTIFY_LOG}"
}

# Fire a real macOS notification (no suppression logic here).
_lives_fire_macos() {
    local title="$1" message="$2"
    # Escape double quotes for the AppleScript string
    local esc_title="${title//\"/\\\"}"
    local esc_message="${message//\"/\\\"}"
    osascript -e "display notification \"${esc_message}\" with title \"${esc_title}\"" 2>/dev/null || true
}

# Public: dispatch an event.
lives_notify_event() {
    local category="$1" event_status="$2" title="$3" message="$4"
    [[ -z "${category}" || -z "${event_status}" ]] && return 2

    local fingerprint
    fingerprint=$(_lives_fingerprint "${event_status}" "${message}")
    local now_epoch
    now_epoch=$(date '+%s')

    local prev_fp prev_status prev_fire_epoch
    prev_fp=$(_lives_state_get "${category}.fingerprint")
    prev_status=$(_lives_state_get "${category}.status")
    prev_fire_epoch=$(_lives_state_get "${category}.fire_epoch")
    prev_fire_epoch="${prev_fire_epoch:-0}"

    local should_fire=0

    if [[ "${event_status}" = "ok" ]]; then
        # Recovery: only fire if there was a prior non-ok status.
        if [[ -n "${prev_status}" && "${prev_status}" != "ok" ]]; then
            should_fire=1
        fi
    else
        if [[ "${fingerprint}" != "${prev_fp}" ]]; then
            # Different problem (or first occurrence): fire.
            should_fire=1
        else
            # Same problem as last time: fire only if dedup window expired.
            local dedup_seconds=$(( LIVES_NOTIFY_DEDUP_HOURS * 3600 ))
            local elapsed=$(( now_epoch - prev_fire_epoch ))
            [[ ${elapsed} -ge ${dedup_seconds} ]] && should_fire=1
        fi
    fi

    # The logical decision (should_fire) is what the audit log records, so
    # tests can verify dispatch policy without touching the OS. The OS call
    # is separately gated by LIVES_NO_NOTIFY.
    local fired_field="suppressed"
    if [[ ${should_fire} -eq 1 ]]; then
        fired_field="fired"
        if [[ -z "${LIVES_NO_NOTIFY:-}" ]]; then
            _lives_fire_macos "${title}" "${message}"
        fi
        _lives_state_set \
            "${category}.fingerprint" "${fingerprint}" \
            "${category}.status" "${event_status}" \
            "${category}.fire_epoch" "${now_epoch}" \
            "${category}.title" "${title}" \
            "${category}.message" "${message}"
    else
        _lives_state_set \
            "${category}.fingerprint" "${fingerprint}" \
            "${category}.status" "${event_status}" \
            "${category}.title" "${title}" \
            "${category}.message" "${message}"
    fi

    _lives_audit_log "${category}" "${event_status}" "${fired_field}" "${title}" "${message}"
    return 0
}

# Public: explicitly mark a category as resolved without sending a
# notification. Useful when a script wants to clear stale state on startup.
lives_notify_clear() {
    local category="$1"
    _lives_state_set \
        "${category}.fingerprint" "" \
        "${category}.status" "ok" \
        "${category}.title" "" \
        "${category}.message" ""
}
