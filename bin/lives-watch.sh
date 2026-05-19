#!/usr/bin/env zsh
# lives-watch.sh - Ableton Lives watcher
# Invoked by launchd WatchPaths. Scans for recently-modified .als files,
# deduplicates by SHA-256, copies versioned snapshots to _versions/.
# Short-lived: runs once, copies, exits. KeepAlive in the plist re-arms it.
#
# Architecture: see DESIGN.md D1-D2.
#
# NOTE: In zsh, 'path' is a special tied variable that maps to PATH.
# Do NOT use 'local path=...' in any function - it zeroes PATH and breaks
# command lookups. Use 'local dir_path=...' or 'local scan_dir=...' instead.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (loaded from ~/.config/ableton-lives/config; env vars take precedence)
# ---------------------------------------------------------------------------
LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${LIVES_LIB_DIR}/lives-config.sh"

VERSIONS_DIR="${LIVES_VERSIONS_DIR}"
LOG="${LIVES_LOG}"
SEEN_HASHES="${LIVES_SEEN_HASHES}"
SUMMARY="${LIVES_SUMMARY}"
# USB_PATH may be empty (no external drive watched); script handles that.
USB_PATH="${LIVES_USB_PATH}"
INTERNAL_PATH="${LIVES_INTERNAL_PATH}"
LOCKFILE="${LIVES_LOCKFILE:-/tmp/ableton-lives-watch.lock}"
MTIME_WINDOW="${LIVES_MTIME_WINDOW:-30}"  # seconds

# Audio export capture: any audio file appearing in a project, but NOT in
# Samples/, Backup/, or _versions/, is treated as a finished render and
# mirrored into _versions/<project>/_exports/. Live Recordings/ counts as
# a project named "Live Recordings" so takes are preserved too.
EXPORT_EXTS="${LIVES_EXPORT_EXTS:-wav aiff aif flac mp3 m4a ogg}"

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${LOG}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 1: Single-instance guard via lockfile
# ---------------------------------------------------------------------------
if [[ -f "${LOCKFILE}" ]]; then
    existing_pid=$(cat "${LOCKFILE}" 2>/dev/null || true)
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
        log "[GUARD] already running (pid ${existing_pid}), exiting"
        exit 0
    fi
fi
printf '%d' "$$" > "${LOCKFILE}"

# Ensure lockfile is removed on exit
cleanup() {
    rm -f "${LOCKFILE}" "${ref_file:-}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 2: Initialize paths
# ---------------------------------------------------------------------------
mkdir -p "${VERSIONS_DIR}"
mkdir -p "$(dirname "${LOG}")"
touch "${LOG}"

log "[START] lives-watch invoked"

# ---------------------------------------------------------------------------
# Step 3: Prune stale seen-hashes entries (keep only today's)
# ---------------------------------------------------------------------------
today=$(date '+%Y%m%d')

if [[ -f "${SEEN_HASHES}" ]]; then
    # Filter: keep only lines whose date field equals today
    tmp_hashes="${SEEN_HASHES}.tmp.$$"
    grep " ${today}$" "${SEEN_HASHES}" > "${tmp_hashes}" 2>/dev/null || true
    stale_count=$(( $(wc -l < "${SEEN_HASHES}" 2>/dev/null || echo 0) - $(wc -l < "${tmp_hashes}" 2>/dev/null || echo 0) ))
    if [[ "${stale_count}" -gt 0 ]]; then
        mv "${tmp_hashes}" "${SEEN_HASHES}"
        log "[HASH-PRUNE] removed ${stale_count} stale hash entries from previous days"
    else
        rm -f "${tmp_hashes}"
    fi
else
    touch "${SEEN_HASHES}"
fi

# ---------------------------------------------------------------------------
# Step 4: Build candidate list
# ---------------------------------------------------------------------------
# Create a reference file with mtime = now - MTIME_WINDOW seconds.
# find -newer ref_file will match files modified in the last MTIME_WINDOW seconds.
# IMPORTANT: Do NOT name the local variable 'path' in any function - in zsh,
# 'path' is tied to PATH and 'local path=...' would zero out PATH, breaking
# command lookups (date, shasum, etc.).
ref_file="/tmp/lives-mtime-ref.$$"
touch -m -t "$(date -v-${MTIME_WINDOW}S '+%Y%m%d%H%M.%S')" "${ref_file}" 2>/dev/null || true

candidates=()

scan_path_mtime() {
    local scan_dir="$1"
    local label="$2"
    if [[ ! -d "${scan_dir}" ]]; then
        log "[SKIP] ${label} not mounted or absent: ${scan_dir}"
        return 0
    fi
    while IFS= read -r -d '' f; do
        candidates+=("${f}")
    done < <(find "${scan_dir}" -name '*.als' -not -name '._*' -newer "${ref_file}" -not -path '*/_versions/*' -print0 2>/dev/null || true)
}

[[ -n "${USB_PATH}" ]] && scan_path_mtime "${USB_PATH}" "external"
scan_path_mtime "${INTERNAL_PATH}" "internal"

# Build a parallel candidate list for audio exports. Same mtime window,
# but expanded extensions and excluding paths that hold inputs/auto-backups
# rather than user-finalised renders.
export_candidates=()

scan_path_exports() {
    local scan_dir="$1"
    local label="$2"
    if [[ ! -d "${scan_dir}" ]]; then
        return 0
    fi
    local find_args=(-type f -newer "${ref_file}")
    # Exclude input/auto-backup folders so we capture outputs only.
    find_args+=(-not -path '*/Samples/*')
    find_args+=(-not -path '*/Backup/*')
    find_args+=(-not -path '*/_versions/*')
    # Build the OR of extension matches
    local ext first=1
    find_args+=( '(' )
    for ext in ${=EXPORT_EXTS}; do
        if [[ ${first} -eq 1 ]]; then
            find_args+=(-iname "*.${ext}")
            first=0
        else
            find_args+=(-o -iname "*.${ext}")
        fi
    done
    find_args+=( ')' )
    while IFS= read -r -d '' f; do
        export_candidates+=("${f}")
    done < <(find "${scan_dir}" "${find_args[@]}" -print0 2>/dev/null || true)
}

[[ -n "${USB_PATH}" ]] && scan_path_exports "${USB_PATH}" "external"
scan_path_exports "${INTERNAL_PATH}" "internal"

rm -f "${ref_file}"
ref_file=""

# ---------------------------------------------------------------------------
# Step 5: Process each candidate
# ---------------------------------------------------------------------------
copied_count=0
recent_saves=()
now_ts=$(date '+%Y%m%d-%H%M%S')
now_iso=$(date '+%Y-%m-%dT%H:%M:%S')

for f in "${candidates[@]}"; do
    # 5a: Verify readable regular file
    if [[ ! -f "${f}" ]] || [[ ! -r "${f}" ]]; then
        log "[SKIP] not a readable file: ${f}"
        continue
    fi

    # 5b: Compute SHA-256
    file_hash=$(shasum -a 256 "${f}" 2>/dev/null | awk '{print $1}')
    if [[ -z "${file_hash}" ]]; then
        log "[ERROR] could not hash: ${f}"
        continue
    fi

    # 5c: Dedup check
    if grep -q "^${file_hash} " "${SEEN_HASHES}" 2>/dev/null; then
        log "[DEDUP] skipping already-seen: $(basename "${f}")"
        continue
    fi

    # 5d: Derive project name
    # parent_dir is the directory containing the .als file
    parent_dir=$(dirname "${f}")
    project=$(basename "${parent_dir}")
    # If the .als is directly under a watched root, use the root's basename
    if [[ -n "${USB_PATH}" && "${parent_dir}" == "${USB_PATH}" ]] || [[ "${parent_dir}" == "${INTERNAL_PATH}" ]]; then
        project=$(basename "${parent_dir}")
    fi

    # 5e: Build destination
    base=$(basename "${f}" .als)
    dest_dir="${VERSIONS_DIR}/${project}"
    dest="${dest_dir}/${base}-${now_ts}.als"

    # 5f: Create project subdir
    mkdir -p "${dest_dir}"

    # 5g: Copy
    if ! cp -- "${f}" "${dest}" 2>>"${LOG}"; then
        log "[ERROR] copy failed: ${f} -> ${dest}"
        continue
    fi

    # 5h: Record hash
    printf '%s %s\n' "${file_hash}" "${today}" >> "${SEEN_HASHES}"

    # 5i: Log
    file_size=$(stat -f '%z' "${dest}" 2>/dev/null || stat -c '%s' "${dest}" 2>/dev/null || echo '?')
    log "[COPIED] ${project}/${base}-${now_ts}.als (${file_size} bytes)"
    copied_count=$(( copied_count + 1 ))
    recent_saves+=("${base}|${now_iso}")
done

# ---------------------------------------------------------------------------
# Step 5b: Process audio export candidates
#
# Stored at: _versions/<project>/_exports/<basename>-<YYYYMMDD-HHMMSS>.<ext>
# Same SHA-256 dedup as .als (single seen-hashes pool; collisions across
# .als and audio content are cryptographically impossible). Project name
# is the parent directory of the file. Files directly under a watched root
# get the root's basename as project (e.g., "Live Recordings").
# ---------------------------------------------------------------------------
exported_count=0
for f in "${export_candidates[@]}"; do
    if [[ ! -f "${f}" ]] || [[ ! -r "${f}" ]]; then
        continue
    fi

    # Skip files still being written: if size changes between two checks
    # 1s apart, the export isn't done. Cheap and avoids partial uploads.
    size1=$(stat -f '%z' "${f}" 2>/dev/null || echo 0)
    sleep 1
    size2=$(stat -f '%z' "${f}" 2>/dev/null || echo 0)
    if [[ "${size1}" != "${size2}" ]] || [[ "${size1}" -eq 0 ]]; then
        log "[EXPORT-WAIT] still writing or empty, will catch next fire: $(basename "${f}")"
        continue
    fi

    file_hash=$(shasum -a 256 "${f}" 2>/dev/null | awk '{print $1}')
    if [[ -z "${file_hash}" ]]; then
        log "[ERROR] could not hash export: ${f}"
        continue
    fi

    if grep -q "^${file_hash} " "${SEEN_HASHES}" 2>/dev/null; then
        log "[DEDUP] export already seen today: $(basename "${f}")"
        continue
    fi

    parent_dir=$(dirname "${f}")
    project=$(basename "${parent_dir}")
    if [[ -n "${USB_PATH}" && "${parent_dir}" == "${USB_PATH}" ]] || [[ "${parent_dir}" == "${INTERNAL_PATH}" ]]; then
        project=$(basename "${parent_dir}")
    fi

    base="${f:t:r}"            # filename without path, without extension
    ext="${f:e}"               # extension only
    dest_dir="${VERSIONS_DIR}/${project}/_exports"
    dest="${dest_dir}/${base}-${now_ts}.${ext}"
    mkdir -p "${dest_dir}"

    if ! cp -- "${f}" "${dest}" 2>>"${LOG}"; then
        log "[ERROR] export copy failed: ${f} -> ${dest}"
        continue
    fi

    printf '%s %s\n' "${file_hash}" "${today}" >> "${SEEN_HASHES}"
    file_size=$(stat -f '%z' "${dest}" 2>/dev/null || echo '?')
    log "[EXPORT] ${project}/_exports/${base}-${now_ts}.${ext} (${file_size} bytes)"
    exported_count=$(( exported_count + 1 ))
done

# ---------------------------------------------------------------------------
# Step 6: Update .ableton-lives-summary atomically
# ---------------------------------------------------------------------------
update_summary() {
    local summary_dir
    summary_dir=$(dirname "${SUMMARY}")
    mkdir -p "${summary_dir}"

    local total_count
    total_count=$(find "${VERSIONS_DIR}" -name '*.als' -not -name '._*' 2>/dev/null | wc -l | tr -d ' ')

    local total_bytes
    total_bytes=$(du -sb "${VERSIONS_DIR}" 2>/dev/null | awk '{print $1}' || \
                  du -sk "${VERSIONS_DIR}" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)

    # Build recent saves string from new + existing
    local new_recent=""
    if [[ ${#recent_saves[@]} -gt 0 ]]; then
        new_recent=$(printf '%s,' "${recent_saves[@]}")
        new_recent="${new_recent%,}"
    fi

    # Read existing recent saves
    local existing_recent=""
    if [[ -f "${SUMMARY}" ]]; then
        existing_recent=$(grep '^LIVES_RECENT_SAVES=' "${SUMMARY}" 2>/dev/null | cut -d= -f2- || true)
    fi

    # Merge and keep only 2 most recent
    local merged_saves
    if [[ -n "${new_recent}" ]] && [[ -n "${existing_recent}" ]]; then
        merged_saves="${new_recent},${existing_recent}"
    elif [[ -n "${new_recent}" ]]; then
        merged_saves="${new_recent}"
    else
        merged_saves="${existing_recent}"
    fi
    # Trim to 2 entries
    merged_saves=$(printf '%s' "${merged_saves}" | tr ',' '\n' | head -2 | tr '\n' ',' | sed 's/,$//')

    local prune_last=""
    local prune_deleted=""
    if [[ -f "${SUMMARY}" ]]; then
        prune_last=$(grep '^LIVES_PRUNE_LAST_RUN=' "${SUMMARY}" 2>/dev/null | cut -d= -f2- || true)
        prune_deleted=$(grep '^LIVES_PRUNE_DELETED_LAST_RUN=' "${SUMMARY}" 2>/dev/null | cut -d= -f2- || true)
    fi

    local tmp_summary="${SUMMARY}.tmp.$$"
    cat > "${tmp_summary}" <<EOF
LIVES_LAST_UPDATED=${now_iso}
LIVES_VERSION_COUNT_TOTAL=${total_count}
LIVES_STORAGE_BYTES=${total_bytes}
LIVES_RECENT_SAVES=${merged_saves}
LIVES_PRUNE_LAST_RUN=${prune_last}
LIVES_PRUNE_DELETED_LAST_RUN=${prune_deleted}
EOF
    mv "${tmp_summary}" "${SUMMARY}"
}

if [[ "${copied_count}" -gt 0 ]]; then
    update_summary 2>/dev/null || log "[WARN] summary update failed"
fi

log "[DONE] copied ${copied_count} version(s), ${exported_count} export(s) this run"
exit 0
