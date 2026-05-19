#!/usr/bin/env zsh
# lives-sync.sh - Ableton Lives offsite sync (Google Drive, encrypted)
#
# Mirrors ~/Music/Ableton/_versions/ to an rclone crypt remote so Google
# stores only opaque encrypted blobs (no filenames, no project names, no
# content). Runs daily at 04:30 via launchd, after prune (04:00) and log
# rotation (04:05).
#
# Hard quota guards: refuses to sync if remote free space drops below
# LIVES_FREE_FLOOR_GB or if Ableton Lives' cloud footprint would exceed LIVES_REMOTE_CAP_GB.
# This is the "100 GB plan must never be at risk" invariant.
#
# Notifications: silent on success. Notifies only on:
#   - sync failure
#   - quota guard tripped (refused to sync)
#   - drive usage crosses LIVES_WARN_USED_PCT post-sync
#
# Setup: run bin/lives-sync-setup.sh once to configure the crypt remote.
#
# NOTE: In zsh, 'path' is a special tied variable - never use 'local path=...'.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (overridable via env for testing)
# ---------------------------------------------------------------------------
LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${LIVES_LIB_DIR}/lives-config.sh"

VERSIONS_DIR="${LIVES_VERSIONS_DIR}"
LOG="${LIVES_LOG}"
SUMMARY="${LIVES_SUMMARY}"
LOCKFILE="${LIVES_SYNC_LOCKFILE:-/tmp/ableton-lives-sync.lock}"

# Remotes are created by lives-sync-setup.sh.
#   LIVES_QUOTA_REMOTE = raw Drive remote, used ONLY for `rclone about` quota
#                      queries (crypt remotes don't support `about`).
#   LIVES_SYNC_REMOTE  = crypt remote that wraps the raw remote. ALL file
#                      content flows here, encrypted client-side; Google
#                      sees only opaque blobs.
QUOTA_REMOTE="${LIVES_QUOTA_REMOTE}"
SYNC_REMOTE="${LIVES_SYNC_REMOTE}"
SYNC_PATH="${LIVES_SYNC_PATH}"

# Quota guards (defaults set in lib/lives-config.sh; user-tunable via
# `bin/lives-config.sh set LIVES_REMOTE_CAP_GB 50` etc.). All integer GB.

# Safety: cap how many files a single sync can delete, so a wiped local
# _versions/ cannot nuke the entire remote in one run. Google Drive trash
# also retains deleted files for 30 days as a second line of defence.
LIVES_MAX_DELETE="${LIVES_MAX_DELETE:-100}"

# rclone binary (overridable for testing with a stub)
RCLONE="${LIVES_RCLONE:-rclone}"

# ---------------------------------------------------------------------------
# Notification dispatcher (state-transition aware, dedup-aware, audit-logged)
# ---------------------------------------------------------------------------
LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${LIVES_LIB_DIR}/lives-notify.sh"

log() {
    printf '[%s] [SYNC] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${LOG}" 2>/dev/null || true
}

# Extract an integer field from rclone --json output.
# $1 = field name (total|used|free), $2 = JSON blob
json_int() {
    printf '%s' "$2" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[0-9]+" \
        | head -1 | grep -oE '[0-9]+$' || printf '0'
}

bytes_to_gb() {
    # integer GB, rounded down (we want conservative quota math)
    printf '%d' $(( ${1:-0} / 1024 / 1024 / 1024 ))
}

# ---------------------------------------------------------------------------
# Single-instance guard
# ---------------------------------------------------------------------------
if [[ -f "${LOCKFILE}" ]]; then
    existing_pid=$(cat "${LOCKFILE}" 2>/dev/null || true)
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
        log "already running (pid ${existing_pid}), exiting"
        exit 0
    fi
    # Stale lockfile (PID dead). Clean up before claiming.
    log "cleared stale lockfile (pid ${existing_pid:-?} dead)"
    rm -f "${LOCKFILE}"
fi
printf '%d' "$$" > "${LOCKFILE}"
# EXIT trap handles normal termination. INT/TERM handlers also run cleanup
# in case the script is killed - this is what was missing before, leaving
# the lockfile orphaned when the parent (e.g., menubar app) was relaunched.
trap 'rm -f "${LOCKFILE}" 2>/dev/null || true' EXIT INT TERM HUP

mkdir -p "$(dirname "${LOG}")"
touch "${LOG}"

log "start"

# ---------------------------------------------------------------------------
# Preflight: rclone present, remotes configured, source dir exists.
#
# These are install-time / configuration problems, not data-at-risk events.
# They write to the log and exit silently. The plist is also conditionally
# loaded by install.sh, so if the user hasn't run setup we shouldn't even
# get here in normal operation.
# ---------------------------------------------------------------------------
remotes=""
if command -v "${RCLONE}" >/dev/null 2>&1; then
    remotes=$("${RCLONE}" listremotes 2>/dev/null || true)
fi

config_problem=""
if [[ -z "${remotes}" ]]; then
    if ! command -v "${RCLONE}" >/dev/null 2>&1; then
        config_problem="rclone not installed"
    else
        config_problem="rclone installed but no remotes configured"
    fi
elif ! printf '%s' "${remotes}" | grep -qx "${QUOTA_REMOTE}:"; then
    config_problem="quota remote '${QUOTA_REMOTE}:' missing - run lives-sync-setup.sh"
elif ! printf '%s' "${remotes}" | grep -qx "${SYNC_REMOTE}:"; then
    config_problem="crypt remote '${SYNC_REMOTE}:' missing - run lives-sync-setup.sh"
fi

if [[ -n "${config_problem}" ]]; then
    log "skip (not configured): ${config_problem}"
    exit 0
fi

if [[ ! -d "${VERSIONS_DIR}" ]]; then
    log "nothing to sync: ${VERSIONS_DIR} does not exist yet"
    exit 0
fi

# ---------------------------------------------------------------------------
# Quota guard 1: query total Drive free space (uses raw remote, not crypt)
# ---------------------------------------------------------------------------
about_json=$("${RCLONE}" about "${QUOTA_REMOTE}:" --json 2>>"${LOG}" || true)
if [[ -z "${about_json}" ]]; then
    log "ABORT: could not query Drive quota via '${QUOTA_REMOTE}:'"
    lives_notify_event "sync.network" "error" "Ableton Lives sync: cannot reach Drive" \
        "rclone could not query the Drive quota. Check internet / re-auth: rclone config reconnect ${QUOTA_REMOTE}:"
    exit 1
fi

total_bytes=$(json_int total "${about_json}")
used_bytes=$(json_int used "${about_json}")
free_bytes=$(json_int free "${about_json}")
total_gb=$(bytes_to_gb "${total_bytes}")
used_gb=$(bytes_to_gb "${used_bytes}")
free_gb=$(bytes_to_gb "${free_bytes}")

log "drive quota: used=${used_gb}GB free=${free_gb}GB total=${total_gb}GB"

if [[ "${free_gb}" -lt "${LIVES_FREE_FLOOR_GB}" ]]; then
    log "ABORT: Drive free ${free_gb}GB below floor ${LIVES_FREE_FLOOR_GB}GB"
    lives_notify_event "sync.drive_quota" "warn" "Ableton Lives sync paused: Drive nearly full" \
        "Drive has ${free_gb}GB free (need ${LIVES_FREE_FLOOR_GB}GB). Free space or lower LIVES_FREE_FLOOR_GB."
    exit 1
fi

# ---------------------------------------------------------------------------
# Quota guard 2: Ableton Lives cloud footprint must not exceed cap
# ---------------------------------------------------------------------------
local_bytes=$(du -sk "${VERSIONS_DIR}" 2>/dev/null | awk '{print $1 * 1024}')
local_gb=$(bytes_to_gb "${local_bytes}")

# Current remote Ableton Lives size (skipped on first run if path doesn't exist yet)
remote_size_json=$("${RCLONE}" size "${SYNC_REMOTE}:${SYNC_PATH}" --json 2>/dev/null || true)
remote_bytes=$(json_int bytes "${remote_size_json}")
remote_gb=$(bytes_to_gb "${remote_bytes}")

log "footprint: local=${local_gb}GB remote=${remote_gb}GB cap=${LIVES_REMOTE_CAP_GB}GB"

if [[ "${local_gb}" -gt "${LIVES_REMOTE_CAP_GB}" ]]; then
    log "ABORT: local _versions/ ${local_gb}GB exceeds cap ${LIVES_REMOTE_CAP_GB}GB"
    lives_notify_event "sync.cap" "error" "Ableton Lives sync paused: cap exceeded" \
        "_versions/ is ${local_gb}GB, over ${LIVES_REMOTE_CAP_GB}GB cap. Tighten retention or raise LIVES_REMOTE_CAP_GB."
    exit 1
fi

cap_warn_gb=$(( LIVES_REMOTE_CAP_GB * LIVES_CAP_WARN_PCT / 100 ))
if [[ "${local_gb}" -ge "${cap_warn_gb}" ]]; then
    log "WARN: local _versions/ ${local_gb}GB at ${LIVES_CAP_WARN_PCT}%+ of cap (${cap_warn_gb}/${LIVES_REMOTE_CAP_GB}GB)"
    lives_notify_event "sync.cap" "warn" "Ableton Lives sync: nearing cap" \
        "_versions/ is ${local_gb}GB of ${LIVES_REMOTE_CAP_GB}GB cap (${LIVES_CAP_WARN_PCT}%+)."
fi

# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------
# Flags:
#   --checksum            compare by hash, not mtime (versioned files have
#                         stable contents per timestamp)
#   --transfers 4         modest parallelism
#   --max-delete N        cap destructive deletes per run (anti-wipe)
#   --no-update-modtime   skip pointless modtime updates on unchanged files
#   --stats 0             suppress periodic stats lines in the log
#   --log-level NOTICE    quiet but record errors and transfers
sync_start=$(date '+%s')
sync_ok=1
if "${RCLONE}" sync "${VERSIONS_DIR}" "${SYNC_REMOTE}:${SYNC_PATH}" \
    --size-only \
    --transfers 4 \
    --max-delete "${LIVES_MAX_DELETE}" \
    --no-update-modtime \
    --stats 1s --stats-one-line \
    --log-file "${LOG}" \
    --log-level NOTICE 2>>"${LOG}"; then
    sync_ok=1
else
    sync_ok=0
fi
sync_end=$(date '+%s')
sync_dur=$(( sync_end - sync_start ))

if [[ "${sync_ok}" -eq 0 ]]; then
    # Pull the most recent rclone error line out of the log for context.
    # `|| true` so grep returning 1 (no match) doesn't trip pipefail.
    last_err=$( { grep -E 'ERROR|Failed' "${LOG}" 2>/dev/null || true; } \
        | tail -1 \
        | sed 's/.*ERROR : //; s/.*Failed [^:]*: //; s/^[[:space:]]*//' \
        | cut -c1-100)
    log "FAILED after ${sync_dur}s: ${last_err:-see log}"
    lives_notify_event "sync.run" "error" "Ableton Lives sync failed" \
        "${last_err:-rclone exited non-zero} (after ${sync_dur}s). See log for full trace."
    _lives_sync_status="failed"
else
    log "ok in ${sync_dur}s"
    lives_notify_event "sync.run" "ok" "Ableton Lives sync recovered" \
        "Backup is current again (took ${sync_dur}s)."
    _lives_sync_status="ok"
fi

# ---------------------------------------------------------------------------
# Post-sync quota check
# ---------------------------------------------------------------------------
about_json2=$("${RCLONE}" about "${QUOTA_REMOTE}:" --json 2>/dev/null || true)
post_total_bytes=$(json_int total "${about_json2}")
post_free_bytes=$(json_int free "${about_json2}")
# rclone's `used` = just Drive files. To match Google's web UI ("X GB of
# Y GB used") we want everything counted against the user's storage quota
# (Drive + Gmail + Photos), which is Total - Free.
if [[ "${post_total_bytes}" -gt 0 && "${post_free_bytes}" -gt 0 ]]; then
    post_used_bytes=$(( post_total_bytes - post_free_bytes ))
else
    post_used_bytes=$(json_int used "${about_json2}")
fi
post_used_gb=$(bytes_to_gb "${post_used_bytes}")

if [[ "${post_total_bytes}" -gt 0 ]]; then
    # integer percent: 100 * used / total
    post_pct=$(( 100 * post_used_bytes / post_total_bytes ))
    log "post-sync drive used ${post_used_gb}GB (${post_pct}%)"
    if [[ "${post_pct}" -ge "${LIVES_WARN_USED_PCT}" ]]; then
        lives_notify_event "sync.drive_full" "warn" "Drive ${post_pct}% full" \
            "${post_used_gb}GB used. Free space or lower LIVES_REMOTE_CAP_GB before sync starts refusing."
    fi
fi

# ---------------------------------------------------------------------------
# Update summary (create the file if it doesn't exist - the watcher writes
# its own fields here too, but if the watcher hasn't fired yet there's no
# file. Without this, every sync was completing successfully but leaving
# no trace anywhere the menubar could read it).
# ---------------------------------------------------------------------------
now_iso=$(date '+%Y-%m-%dT%H:%M:%S')
mkdir -p "$(dirname "${SUMMARY}")"
[[ -f "${SUMMARY}" ]] || : > "${SUMMARY}"

tmp_sum="${SUMMARY}.sync.tmp.$$"
grep -v '^LIVES_SYNC_' "${SUMMARY}" > "${tmp_sum}" 2>/dev/null || true
{
    printf 'LIVES_SYNC_LAST_RUN=%s\n' "${now_iso}"
    printf 'LIVES_SYNC_LAST_STATUS=%s\n' "${_lives_sync_status}"
    printf 'LIVES_SYNC_LAST_DURATION_S=%d\n' "${sync_dur}"
    printf 'LIVES_SYNC_REMOTE_BYTES=%d\n' "${remote_bytes}"
    printf 'LIVES_SYNC_DRIVE_USED_BYTES=%d\n' "${post_used_bytes:-0}"
    printf 'LIVES_SYNC_DRIVE_TOTAL_BYTES=%d\n' "${post_total_bytes:-0}"
} >> "${tmp_sum}"
mv "${tmp_sum}" "${SUMMARY}"

if [[ "${_lives_sync_status}" = "failed" ]]; then
    exit 1
fi
exit 0
