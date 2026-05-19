#!/usr/bin/env zsh
# lives-import-existing.sh - One-time import of Ableton's own Backup/ files
# into the Ableton Lives _versions/ store.
#
# Ableton names its backups: "<name> [YYYY-MM-DD HHMMSS].als"
# Ableton Lives names versions:        "<name>-YYYYMMDD-HHMMSS.als"
#
# This script converts and imports them on first install (Q2 default: yes).
# Safe to re-run: skips files already present.

set -euo pipefail

LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${LIVES_LIB_DIR}/lives-config.sh"

VERSIONS_DIR="${LIVES_VERSIONS_DIR}"
LOG="${LIVES_LOG}"
USB_ABLETON="${LIVES_USB_PATH}"
INTERNAL_ABLETON="${LIVES_INTERNAL_PATH}"

# Regex for "name [YYYY-MM-DD HHMMSS].als" - zsh chokes if the pattern is
# inlined into [[ =~ ]] because of the literal parens; assigning to a
# variable first sidesteps the parser issue.
ABLETON_BACKUP_RE='\[([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{6})\]'

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${LOG}" 2>/dev/null || true
    printf '%s\n' "$*"
}

import_backup_dir() {
    local backup_dir="$1"
    local project_name="$2"

    if [[ ! -d "${backup_dir}" ]]; then
        return
    fi

    local dest_dir="${VERSIONS_DIR}/${project_name}"
    mkdir -p "${dest_dir}"

    while IFS= read -r f; do
        # Ableton format: "name [YYYY-MM-DD HHMMSS].als"
        filename=$(basename "${f}")
        # Extract timestamp portion: "YYYY-MM-DD HHMMSS"
        if [[ "${filename}" =~ ${ABLETON_BACKUP_RE} ]]; then
            yr="${match[1]}"
            mo="${match[2]}"
            dy="${match[3]}"
            time="${match[4]}"
            lives_ts="${yr}${mo}${dy}-${time}"
            # Extract base name (before the bracket)
            base_name=$(printf '%s' "${filename}" | sed 's/ \[.*\]\.als$//')
            dest="${dest_dir}/${base_name}-${lives_ts}.als"
            if [[ ! -f "${dest}" ]]; then
                cp -- "${f}" "${dest}"
                log "[IMPORT] ${project_name}/${base_name}-${lives_ts}.als"
            else
                log "[IMPORT-SKIP] already exists: ${dest}"
            fi
        else
            log "[IMPORT-WARN] could not parse timestamp from: ${filename}"
        fi
    done < <(find "${backup_dir}" -name '*.als' -not -name '._*' -maxdepth 1 2>/dev/null)
}

log "[IMPORT] scanning for Ableton Backup/ directories"

# Scan optional external drive's ableton/ directory (if configured + mounted).
if [[ -n "${USB_ABLETON}" ]] && [[ -d "${USB_ABLETON}" ]]; then
    while IFS= read -r project_dir; do
        backup_dir="${project_dir}/Backup"
        project_name=$(basename "${project_dir}")
        import_backup_dir "${backup_dir}" "${project_name}"
    done < <(find "${USB_ABLETON}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
elif [[ -n "${USB_ABLETON}" ]]; then
    log "[IMPORT] external drive not mounted, skipping external scan"
fi

# Scan internal Ableton/ directory
if [[ -d "${INTERNAL_ABLETON}" ]]; then
    while IFS= read -r project_dir; do
        backup_dir="${project_dir}/Backup"
        project_name=$(basename "${project_dir}")
        import_backup_dir "${backup_dir}" "${project_name}"
    done < <(find "${INTERNAL_ABLETON}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

log "[IMPORT] done"
exit 0
