#!/usr/bin/env zsh
# atm-restore.sh - Ableton Time Machine restore tool
# Usage:
#   atm-restore.sh --list <project-name>
#     Prints available version timestamps for the project, newest first.
#     One entry per line in format: YYYYMMDD-HHMMSS
#
#   atm-restore.sh --restore <project-name> <timestamp> <destination-als-path>
#     Backs up destination to <destination>.bak, then copies the versioned
#     file to destination.
#
# D5 invariant: .als.bak is ALWAYS written before any overwrite.
#
# VERSIONS_DIR can be overridden via ATM_VERSIONS_DIR for testing.

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"
VERSIONS_DIR="${ATM_VERSIONS_DIR}"

usage() {
    printf 'Usage:\n'
    printf '  atm-restore.sh --list <project-name>\n'
    printf '  atm-restore.sh --restore <project-name> <timestamp> <dest-als-path>\n'
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

mode="$1"
project="$2"
project_dir="${VERSIONS_DIR}/${project}"

case "${mode}" in

    --list)
        if [[ ! -d "${project_dir}" ]]; then
            exit 0
        fi
        find "${project_dir}" -name '*.als' -maxdepth 1 \
            | sed 's|.*/||' \
            | grep -oE '[0-9]{8}-[0-9]{6}' \
            | sort -r \
            | uniq
        ;;

    --list-meta)
        # Like --list but each line is enriched with BPM, track count and
        # size via atm-preview. Used by the Quick Action so the user sees
        # context next to each timestamp.
        if [[ ! -d "${project_dir}" ]]; then
            exit 0
        fi
        preview="$(cd "$(dirname "$0")" && pwd)/atm-preview.sh"
        find "${project_dir}" -name '*.als' -maxdepth 1 \
            | sed 's|.*/||' \
            | grep -oE '[0-9]{8}-[0-9]{6}' \
            | sort -r \
            | uniq \
            | while IFS= read -r ts; do
                if [[ -x "${preview}" ]]; then
                    "${preview}" --label "${project}" "${ts}" 2>/dev/null \
                        || printf '%s\n' "${ts}"
                else
                    printf '%s\n' "${ts}"
                fi
            done
        ;;

    --restore)
        if [[ $# -lt 4 ]]; then
            usage
        fi
        timestamp="$3"
        dest_path="$4"

        # Find the versioned file matching this timestamp
        versioned_file=$(find "${project_dir}" -name "*-${timestamp}.als" -maxdepth 1 | head -1)
        if [[ -z "${versioned_file}" ]]; then
            printf 'ERROR: no version found for project "%s" at timestamp %s\n' "${project}" "${timestamp}" >&2
            exit 1
        fi

        # D5 invariant: always write .bak before overwriting
        bak_path="${dest_path}.bak"
        if [[ -f "${dest_path}" ]]; then
            cp -- "${dest_path}" "${bak_path}"
        fi

        # Copy versioned file to destination
        cp -- "${versioned_file}" "${dest_path}"
        printf 'Restored: %s -> %s\n' "${versioned_file}" "${dest_path}"
        printf 'Backup:   %s\n' "${bak_path}"
        ;;

    *)
        usage
        ;;
esac

exit 0
