#!/usr/bin/env zsh
# atm-crash-watch.sh - detect Ableton Live crashes, tag the closest
# preceding version snapshot so recovery is one click away.
#
# macOS writes crash reports to ~/Library/Logs/DiagnosticReports/. For
# Ableton these match Live*.ips or Live*.crash. We poll every few minutes
# (via launchd StartInterval) and process any new ones we haven't seen.
#
# For each new crash:
#   1. Read the crash file's mtime as the crash time.
#   2. Find the .als version with the closest mtime BEFORE the crash time
#      across all projects.
#   3. Add an atm-tag pin labelled "pre-crash-<crash-ts>" so it survives
#      every retention zone.
#   4. Write/refresh ~/.atm-last-crash with structured info the menu bar reads.
#   5. Fire one notification (state-transition aware - same crash file
#      doesn't re-notify).
#
# State: ~/.atm-crash-seen records the basename of every processed crash
# file so we only act on new ones.

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"
source "${ATM_LIB_DIR}/atm-notify.sh"

VERSIONS_DIR="${ATM_VERSIONS_DIR}"
LOG="${ATM_LOG}"
CRASH_DIR="${ATM_CRASH_DIR:-${HOME}/Library/Logs/DiagnosticReports}"
SEEN="${ATM_CRASH_SEEN:-${HOME}/.atm-crash-seen}"
MARKER="${ATM_CRASH_MARKER:-${HOME}/.atm-last-crash}"
TAG_BIN="${ATM_TAG_BIN:-$(cd "$(dirname "$0")" && pwd)/atm-tag.sh}"

log() {
    printf '[%s] [CRASH] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${LOG}" 2>/dev/null || true
}

mkdir -p "$(dirname "${LOG}")" "$(dirname "${SEEN}")"

[[ ! -d "${CRASH_DIR}" ]] && exit 0
[[ ! -d "${VERSIONS_DIR}" ]] && exit 0

# First-run guard: if the seen-file does NOT exist yet, this is the first
# time atm-crash-watch.sh has run on this machine. Pre-populate it with
# every existing crash report so we never retroactively fire notifications
# for crashes from before ATM was installed (which was the bug where the
# menubar showed "Ableton crashed Xh ago" even when Ableton hadn't been
# open). After this point, only NEW crash files trigger.
if [[ ! -f "${SEEN}" ]]; then
    log "first run - cataloguing existing crash reports as already-seen"
    find "${CRASH_DIR}" -maxdepth 1 -type f \
        \( -iname 'Live-*.ips' -o -iname 'Live_*.ips' -o -iname 'Live*.ips' \
           -o -iname 'Live*.crash' -o -iname 'Live*.diag' \) \
        -exec basename {} \; > "${SEEN}" 2>/dev/null || true
    pre_count=$(wc -l < "${SEEN}" 2>/dev/null | tr -d ' ' || echo 0)
    log "first run - ignored ${pre_count} pre-existing report(s); only new crashes will trigger"
    exit 0
fi
touch "${LOG}"

# List all matching crash files (Live, Live Set, etc - case insensitive).
mapfile_crashes() {
    find "${CRASH_DIR}" -maxdepth 1 -type f \
        \( -iname 'Live-*.ips' -o -iname 'Live_*.ips' -o -iname 'Live*.ips' \
           -o -iname 'Live*.crash' -o -iname 'Live*.diag' \) 2>/dev/null
}

new_crashes=()
while IFS= read -r f; do
    bn=$(basename "${f}")
    if ! grep -qxF "${bn}" "${SEEN}" 2>/dev/null; then
        new_crashes+=("${f}")
    fi
done < <(mapfile_crashes)

if [[ ${#new_crashes[@]} -eq 0 ]]; then
    exit 0
fi

# Process each new crash, oldest first (mtime asc).
sort_by_mtime() {
    while IFS= read -r f; do
        local mt
        mt=$(stat -f '%m' "${f}" 2>/dev/null || echo 0)
        printf '%d\t%s\n' "${mt}" "${f}"
    done | sort -n | cut -f2-
}

ordered=$(printf '%s\n' "${new_crashes[@]}" | sort_by_mtime)

# Find the .als snapshot with the largest mtime <= crash_epoch.
find_pre_crash_version() {
    local crash_epoch="$1"
    local best=""
    local best_mt=0
    while IFS= read -r f; do
        local mt
        mt=$(stat -f '%m' "${f}" 2>/dev/null || echo 0)
        if [[ ${mt} -le ${crash_epoch} ]] && [[ ${mt} -gt ${best_mt} ]]; then
            best_mt=${mt}
            best="${f}"
        fi
    done < <(find "${VERSIONS_DIR}" -name '*.als' -not -path '*/_exports/*' -not -path '*/_bundles/*' 2>/dev/null)
    [[ -n "${best}" ]] && printf '%s\n' "${best}"
}

while IFS= read -r crash_file; do
    [[ -z "${crash_file}" ]] && continue
    crash_bn=$(basename "${crash_file}")
    crash_epoch=$(stat -f '%m' "${crash_file}" 2>/dev/null || date '+%s')
    crash_iso=$(date -r "${crash_epoch}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo unknown)
    crash_tag_ts=$(date -r "${crash_epoch}" '+%Y%m%d-%H%M%S' 2>/dev/null || date '+%Y%m%d-%H%M%S')

    log "new crash report: ${crash_bn} (${crash_iso})"

    pre_version=$(find_pre_crash_version "${crash_epoch}")

    if [[ -z "${pre_version}" ]]; then
        log "no preceding version found for crash at ${crash_iso}"
        printf '%s\n' "${crash_bn}" >> "${SEEN}"
        continue
    fi

    # Derive project + ts to feed atm-tag
    project=$(basename "$(dirname "${pre_version}")")
    pre_ts=$(basename "${pre_version}" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
    label="pre-crash-${crash_tag_ts}"

    if [[ -x "${TAG_BIN}" ]] && [[ -n "${pre_ts}" ]]; then
        # Best-effort tag; ignore failure (e.g., already tagged)
        "${TAG_BIN}" add "${project}" "${pre_ts}" "${label}" 2>>"${LOG}" || true
        log "tagged: ${project}/${pre_ts} as ${label}"
    fi

    # Write/refresh marker (atomic). The menu bar reads this.
    tmp="${MARKER}.tmp.$$"
    cat > "${tmp}" <<MARKER
ATM_CRASH_FILE=${crash_bn}
ATM_CRASH_AT=${crash_iso}
ATM_CRASH_EPOCH=${crash_epoch}
ATM_CRASH_PROJECT=${project}
ATM_CRASH_PRE_VERSION_TS=${pre_ts}
ATM_CRASH_PRE_VERSION_PATH=${pre_version}
ATM_CRASH_TAG_LABEL=${label}
MARKER
    mv "${tmp}" "${MARKER}"

    # State-transition aware - one notification per unique crash file.
    atm_notify_event "crash.detected" "warn" "Ableton crashed - recovery ready" \
        "Tagged ${project}/${pre_ts} as ${label}. Right-click the .als in Finder to restore."

    printf '%s\n' "${crash_bn}" >> "${SEEN}"
done <<< "${ordered}"

exit 0
