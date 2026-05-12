#!/usr/bin/env zsh
# atm-tag.sh - pin a version so it is never pruned.
#
# Usage:
#   atm-tag.sh add  <project> <timestamp> <label>
#   atm-tag.sh rm   <project> <timestamp>
#   atm-tag.sh list [<project>]
#
# Tags are stored in _versions/<project>/_tags as TSV:
#   <timestamp>\t<label>\t<iso-created>
#
# atm-prune.sh consults this file before deleting; any timestamp listed
# survives every retention zone, including >365d. Useful for "demo-v1",
# "client-approved", "before-mastering".

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"
VERSIONS_DIR="${ATM_VERSIONS_DIR}"

usage() {
    cat <<USAGE
Usage:
  atm-tag.sh add  <project> <timestamp> <label>
  atm-tag.sh rm   <project> <timestamp>
  atm-tag.sh list [<project>]

Examples:
  atm-tag.sh add "intro lessons" 20260512-093045 "demo-v1"
  atm-tag.sh list "intro lessons"
  atm-tag.sh rm  "intro lessons" 20260512-093045
USAGE
    exit 1
}

[[ $# -lt 1 ]] && usage
mode="$1"
shift

case "${mode}" in
    add)
        [[ $# -ne 3 ]] && usage
        project="$1" timestamp="$2" label="$3"
        project_dir="${VERSIONS_DIR}/${project}"
        [[ -d "${project_dir}" ]] || { printf 'No such project: %s\n' "${project}" >&2; exit 1; }
        # Verify the version exists
        match=$(find "${project_dir}" -maxdepth 1 -name "*-${timestamp}.als" 2>/dev/null | head -1)
        [[ -z "${match}" ]] && { printf 'No version at timestamp %s in %s\n' "${timestamp}" "${project}" >&2; exit 1; }
        tags_file="${project_dir}/_tags"
        # Refuse duplicate timestamps; user can rm then add to update label.
        if [[ -f "${tags_file}" ]] && grep -q "^${timestamp}	" "${tags_file}"; then
            printf 'Already tagged: %s\n' "${timestamp}" >&2
            exit 1
        fi
        printf '%s\t%s\t%s\n' "${timestamp}" "${label}" "$(date '+%Y-%m-%dT%H:%M:%S')" >> "${tags_file}"
        printf 'Tagged %s -> %s\n' "${match}" "${label}"
        ;;
    rm)
        [[ $# -ne 2 ]] && usage
        project="$1" timestamp="$2"
        tags_file="${VERSIONS_DIR}/${project}/_tags"
        [[ -f "${tags_file}" ]] || { printf 'No tags for %s\n' "${project}" >&2; exit 0; }
        tmp="${tags_file}.tmp.$$"
        grep -v "^${timestamp}	" "${tags_file}" > "${tmp}" || true
        mv "${tmp}" "${tags_file}"
        printf 'Removed tag for %s\n' "${timestamp}"
        ;;
    list)
        if [[ $# -eq 1 ]]; then
            project="$1"
            tags_file="${VERSIONS_DIR}/${project}/_tags"
            [[ -f "${tags_file}" ]] && cat "${tags_file}"
        else
            # All projects
            find "${VERSIONS_DIR}" -mindepth 2 -maxdepth 2 -name '_tags' 2>/dev/null \
                | while IFS= read -r f; do
                    project=$(basename "$(dirname "${f}")")
                    while IFS=$'\t' read -r ts label created; do
                        [[ -z "${ts}" ]] && continue
                        printf '%s\t%s\t%s\t%s\n' "${project}" "${ts}" "${label}" "${created}"
                    done < "${f}"
                done
        fi
        ;;
    *)
        usage
        ;;
esac
