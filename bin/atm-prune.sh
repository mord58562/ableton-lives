#!/usr/bin/env zsh
# atm-prune.sh - Ableton Time Machine retention pruner
#
# Tiered retention (rationalised to keep cloud + local footprint <5GB even
# under heavy multi-project use):
#   Zone 0 - mtime < 24 h            : keep ALL (true undo window)
#   Zone 1 - 24 h to 30 d            : keep latest per HOUR per .als name
#   Zone 2 - 30 d to 180 d           : keep latest per DAY  per .als name
#   Zone 3 - 180 d to 365 d          : keep latest per WEEK per .als name
#   Zone 4 - mtime > 365 d           : DELETE
#
# Runs daily at 04:00 via launchd. Logs every deletion to the ATM log.
# Notification policy is deliberately quiet - see end of file.
#
# VERSIONS_DIR and LOG can be overridden via environment variables for testing.
#
# NOTE: In zsh, 'path' is a special tied variable that maps to PATH.
# Do NOT use 'local path=...' in any function.

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"
source "${ATM_LIB_DIR}/atm-notify.sh"

VERSIONS_DIR="${ATM_VERSIONS_DIR}"
LOG="${ATM_LOG}"
SUMMARY="${ATM_SUMMARY}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${LOG}" 2>/dev/null || true
}

log "[PRUNE] starting retention pass"

if [[ ! -d "${VERSIONS_DIR}" ]]; then
    log "[PRUNE] _versions dir does not exist, nothing to prune"
    exit 0
fi

deleted_count=0
now_epoch=$(date '+%s')
now_iso=$(date '+%Y-%m-%dT%H:%M:%S')

# Zone boundaries in seconds
threshold_24h=$(( 86400 ))
threshold_30d=$(( 30 * 86400 ))
threshold_180d=$(( 180 * 86400 ))
threshold_365d=$(( 365 * 86400 ))

# Reduce a zone-N file list to "latest per bucket per .als base name", deleting
# the rest. $1 = label, $2 = bucket regex (sed expr applied to filename to
# extract bucket key). Reads file paths from stdin.
#
# Bucket key examples:
#   per-hour : YYYYMMDD-HH       (sed: keep 11 chars of the timestamp tail)
#   per-day  : YYYYMMDD          (sed: keep 8 chars)
#   per-week : YYYYWW            (computed via date -j from filename timestamp)
prune_zone_keep_max_per_bucket() {
    local label="$1"
    local bucket_kind="$2"
    local tmp_in="${VERSIONS_DIR}/.atm-prune-${label}.$$"
    local tmp_winners="${VERSIONS_DIR}/.atm-prune-${label}-win.$$"
    : > "${tmp_in}"

    while IFS= read -r f; do
        [[ -f "${f}" ]] || continue
        local fname base ts day_str hour_str bucket key
        fname=$(basename "${f}")
        # base name = filename minus -YYYYMMDD-HHMMSS.als suffix
        base=$(printf '%s' "${fname}" | sed 's/-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]\.als$//')
        ts=$(printf '%s' "${fname}" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
        [[ -z "${ts}" ]] && continue

        case "${bucket_kind}" in
            hour)  bucket="${ts:0:11}" ;;                      # YYYYMMDD-HH
            day)   bucket="${ts:0:8}"  ;;                      # YYYYMMDD
            week)
                day_str="${ts:0:8}"
                # %V = ISO week number; %G = ISO week-numbering year
                bucket=$(date -j -f '%Y%m%d' "${day_str}" '+%G%V' 2>/dev/null) || bucket="${day_str:0:6}"
                ;;
            *)     bucket="${ts}" ;;
        esac
        key="${base}|${bucket}"
        printf '%s\t%s\n' "${key}" "${f}" >> "${tmp_in}"
    done

    # winners: max filepath per key (lex max == latest given YYYYMMDD-HHMMSS)
    awk -F'\t' '
        { if (!(($1) in best) || $2 > best[$1]) best[$1] = $2 }
        END { for (k in best) print best[k] }
    ' "${tmp_in}" | sort > "${tmp_winners}"

    while IFS= read -r line; do
        f="${line#*$'\t'}"
        [[ -f "${f}" ]] || continue
        if ! grep -qF "${f}" "${tmp_winners}" 2>/dev/null; then
            log "[PRUNE] [DELETE] ${f} (${label} non-latest in bucket)"
            rm -f "${f}"
            deleted_count=$(( deleted_count + 1 ))
        fi
    done < "${tmp_in}"

    rm -f "${tmp_in}" "${tmp_winners}"
}

# Collect all project dirs into an array (avoids subshell issues with while+pipe)
project_dirs=()
while IFS= read -r project_dir; do
    project_dirs+=("${project_dir}")
done < <(find "${VERSIONS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

for project_dir in "${project_dirs[@]}"; do
    project=$(basename "${project_dir}")
    log "[PRUNE] scanning project: ${project}"

    # Load tagged timestamps for this project (pinned, never pruned).
    tagged_timestamps=()
    tags_file="${project_dir}/_tags"
    if [[ -f "${tags_file}" ]]; then
        while IFS=$'\t' read -r tag_ts tag_label tag_created; do
            [[ -z "${tag_ts}" ]] && continue
            tagged_timestamps+=("${tag_ts}")
        done < "${tags_file}"
        [[ ${#tagged_timestamps[@]} -gt 0 ]] && \
            log "[PRUNE]   ${#tagged_timestamps[@]} pinned version(s) will be skipped"
    fi

    is_tagged() {
        # $1 = file path; returns 0 if its timestamp is in tagged_timestamps
        local fname ts
        fname=$(basename "$1")
        ts=$(printf '%s' "${fname}" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
        [[ -z "${ts}" ]] && return 1
        for t in "${tagged_timestamps[@]}"; do
            [[ "${t}" = "${ts}" ]] && return 0
        done
        return 1
    }

    # Collect all .als files in this project dir (skip _exports/, _bundles/
    # subdirs - those have their own retention policies).
    all_files=()
    while IFS= read -r f; do
        all_files+=("${f}")
    done < <(find "${project_dir}" -name '*.als' -maxdepth 1 2>/dev/null | sort)

    if [[ ${#all_files[@]} -eq 0 ]]; then
        continue
    fi

    # Classify files into zones by mtime, then dedup each zone by its bucket.
    zone1_files=()  # 24h - 30d  -> keep latest per HOUR
    zone2_files=()  # 30d - 180d -> keep latest per DAY
    zone3_files=()  # 180d - 365d -> keep latest per WEEK
    for f in "${all_files[@]}"; do
        [[ -f "${f}" ]] || continue
        # Tagged versions skip every zone, including >365d delete.
        if is_tagged "${f}"; then
            continue
        fi
        file_mtime=$(stat -f '%m' "${f}" 2>/dev/null || stat -c '%Y' "${f}" 2>/dev/null || echo 0)
        age=$(( now_epoch - file_mtime ))

        if [[ "${age}" -le "${threshold_24h}" ]]; then
            : # Zone 0: keep all
        elif [[ "${age}" -le "${threshold_30d}" ]]; then
            zone1_files+=("${f}")
        elif [[ "${age}" -le "${threshold_180d}" ]]; then
            zone2_files+=("${f}")
        elif [[ "${age}" -le "${threshold_365d}" ]]; then
            zone3_files+=("${f}")
        else
            # Zone 4: delete outright
            log "[PRUNE] [DELETE] ${f} (age $(( age / 86400 ))d > 365d)"
            rm -f "${f}"
            deleted_count=$(( deleted_count + 1 ))
        fi
    done

    [[ ${#zone1_files[@]} -gt 0 ]] && printf '%s\n' "${zone1_files[@]}" \
        | prune_zone_keep_max_per_bucket "zone1" "hour"
    [[ ${#zone2_files[@]} -gt 0 ]] && printf '%s\n' "${zone2_files[@]}" \
        | prune_zone_keep_max_per_bucket "zone2" "day"
    [[ ${#zone3_files[@]} -gt 0 ]] && printf '%s\n' "${zone3_files[@]}" \
        | prune_zone_keep_max_per_bucket "zone3" "week"
done

# Update summary with prune stats
if [[ -f "${SUMMARY}" ]]; then
    tmp_sum="${SUMMARY}.prune.tmp.$$"
    grep -v '^ATM_PRUNE_' "${SUMMARY}" > "${tmp_sum}" 2>/dev/null || true
    printf 'ATM_PRUNE_LAST_RUN=%s\n' "${now_iso}" >> "${tmp_sum}"
    printf 'ATM_PRUNE_DELETED_LAST_RUN=%d\n' "${deleted_count}" >> "${tmp_sum}"
    mv "${tmp_sum}" "${SUMMARY}"
fi

log "[PRUNE] done - deleted ${deleted_count} file(s)"

# Notification policy (kept deliberately quiet):
#   - Silent on every routine prune, even when files were deleted.
#     Routine pruning is expected; daily popups become wallpaper noise.
#   - Notify only on UNUSUAL events:
#       * deleted_count >= ATM_PRUNE_NOTIFY_THRESHOLD (default 25)
#         A large sweep is worth a heads-up in case it was unintended.
#       * weekly digest on Sundays summarising the week's deletions
#         (read from summary file; cheap and once-per-week).
ATM_PRUNE_NOTIFY_THRESHOLD="${ATM_PRUNE_NOTIFY_THRESHOLD:-25}"

if [[ "${deleted_count}" -ge "${ATM_PRUNE_NOTIFY_THRESHOLD}" ]]; then
    atm_notify_event "prune.large" "warn" "ATM pruner: large sweep" \
        "${deleted_count} versions removed today. Open the log if this looks wrong."
elif [[ "$(date '+%u')" = "7" ]] && [[ "${deleted_count}" -gt 0 ]]; then
    atm_notify_event "prune.weekly" "info" "ATM pruner: weekly digest" \
        "${deleted_count} version(s) pruned today."
fi

exit 0
