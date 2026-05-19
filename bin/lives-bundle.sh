#!/usr/bin/env zsh
# lives-bundle.sh - whole-project snapshot/restore.
#
# A versioned .als alone often isn't enough to reconstruct a project after
# disk failure - you also need Samples/, Project Info/, .alc clips, .adv
# device presets, etc. This tool bundles the entire project folder
# (excluding Backup/ and _versions/) into a single compressed archive.
#
# Usage:
#   lives-bundle.sh snapshot <project-folder-path> [--note "<note>"]
#   lives-bundle.sh list [<project>]
#   lives-bundle.sh restore <project> <bundle-ts> <destination-folder>
#   lives-bundle.sh size [<project>]
#
# Storage: _versions/<project>/_bundles/<YYYYMMDD-HHMMSS>.tar.<comp>
#          plus a sidecar .meta with original path, size, note.
#
# Compression: zstd if available (best ratio + speed), else gzip.

set -euo pipefail

LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${LIVES_LIB_DIR}/lives-config.sh"
VERSIONS_DIR="${LIVES_VERSIONS_DIR}"
LOG="${LIVES_LOG}"

log() {
    printf '[%s] [BUNDLE] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${LOG}" 2>/dev/null || true
}

usage() {
    cat <<USAGE
Usage:
  lives-bundle.sh snapshot <project-folder> [--note "text"]
  lives-bundle.sh list [<project>]
  lives-bundle.sh restore <project> <bundle-ts> <destination-folder>
  lives-bundle.sh size [<project>]

Examples:
  lives-bundle.sh snapshot "/Volumes/MyDrive/ableton/MyProject" --note "before mastering"
  lives-bundle.sh list "intro lessons"
  lives-bundle.sh restore "intro lessons" 20260512-093045 ~/Desktop/restored-intro
USAGE
    exit 1
}

# Pick compression: zstd preferred, gzip fallback.
pick_compressor() {
    if command -v zstd >/dev/null 2>&1; then
        printf 'zstd\tzst\t-T0 -3'
    else
        printf 'gzip\tgz\t-1'
    fi
}

[[ $# -lt 1 ]] && usage
mode="$1"
shift

case "${mode}" in
    snapshot)
        [[ $# -lt 1 ]] && usage
        src="$1"
        shift
        note=""
        if [[ "${1:-}" = "--note" ]]; then
            note="${2:-}"
            shift 2
        fi
        [[ -d "${src}" ]] || { printf 'Not a directory: %s\n' "${src}" >&2; exit 1; }

        project=$(basename "${src}")
        ts=$(date '+%Y%m%d-%H%M%S')
        dest_dir="${VERSIONS_DIR}/${project}/_bundles"
        mkdir -p "${dest_dir}"

        IFS=$'\t' read -r comp_bin comp_ext comp_flags < <(pick_compressor)
        archive="${dest_dir}/${ts}.tar.${comp_ext}"
        meta="${dest_dir}/${ts}.meta"

        printf 'Snapshotting %s\n' "${src}"
        printf '  -> %s\n' "${archive}"
        log "snapshot start: ${src} -> ${archive}"

        # Run tar with explicit excludes. -C parent_of_src so the archive
        # contains the project folder name as the top-level entry, making
        # restore a single extract.
        parent=$(dirname "${src}")
        proj_basename=$(basename "${src}")
        if ! tar --exclude="${proj_basename}/Backup" \
                 --exclude="${proj_basename}/_versions" \
                 -C "${parent}" -cf - "${proj_basename}" 2>>"${LOG}" \
            | "${comp_bin}" ${=comp_flags} > "${archive}" 2>>"${LOG}"; then
            log "snapshot FAILED"
            rm -f "${archive}"
            printf 'Snapshot failed. See log: %s\n' "${LOG}" >&2
            exit 1
        fi

        size_bytes=$(stat -f '%z' "${archive}" 2>/dev/null || echo 0)
        size_h=$(printf '%d' "${size_bytes}" | awk '{
            if ($1 >= 1073741824) printf "%.1fG", $1/1073741824
            else if ($1 >= 1048576) printf "%.1fM", $1/1048576
            else if ($1 >= 1024) printf "%.1fK", $1/1024
            else printf "%dB", $1
        }')

        # Sidecar metadata
        cat > "${meta}" <<META
ts=${ts}
src=${src}
size_bytes=${size_bytes}
compressor=${comp_bin}
note=${note}
created=$(date '+%Y-%m-%dT%H:%M:%S')
META

        printf 'Done: %s (%s)\n' "${archive}" "${size_h}"
        [[ -n "${note}" ]] && printf 'Note: %s\n' "${note}"
        log "snapshot ok: ${archive} (${size_bytes} bytes)"
        ;;

    list)
        if [[ $# -eq 1 ]]; then
            project="$1"
            bundles_dir="${VERSIONS_DIR}/${project}/_bundles"
            [[ -d "${bundles_dir}" ]] || exit 0
            find "${bundles_dir}" -maxdepth 1 -type f \( -name '*.tar.zst' -o -name '*.tar.gz' \) \
                | sort -r \
                | while IFS= read -r f; do
                    fname=$(basename "${f}")
                    ts=$(printf '%s' "${fname}" | grep -oE '^[0-9]{8}-[0-9]{6}')
                    sz=$(stat -f '%z' "${f}" 2>/dev/null || echo 0)
                    sz_h=$(printf '%d' "${sz}" | awk '{
                        if ($1 >= 1073741824) printf "%.1fG", $1/1073741824
                        else if ($1 >= 1048576) printf "%.1fM", $1/1048576
                        else printf "%dK", $1/1024
                    }')
                    note=""
                    [[ -f "${VERSIONS_DIR}/${project}/_bundles/${ts}.meta" ]] && \
                        note=$(grep '^note=' "${VERSIONS_DIR}/${project}/_bundles/${ts}.meta" | cut -d= -f2-)
                    printf '%s\t%s\t%s\n' "${ts}" "${sz_h}" "${note}"
                done
        else
            find "${VERSIONS_DIR}" -mindepth 3 -maxdepth 3 -type f \
                \( -name '*.tar.zst' -o -name '*.tar.gz' \) 2>/dev/null \
                | sort -r \
                | while IFS= read -r f; do
                    project=$(basename "$(dirname "$(dirname "${f}")")")
                    fname=$(basename "${f}")
                    ts=$(printf '%s' "${fname}" | grep -oE '^[0-9]{8}-[0-9]{6}')
                    printf '%s\t%s\n' "${project}" "${ts}"
                done
        fi
        ;;

    restore)
        [[ $# -ne 3 ]] && usage
        project="$1" ts="$2" dest_parent="$3"
        bundles_dir="${VERSIONS_DIR}/${project}/_bundles"
        archive=$(find "${bundles_dir}" -maxdepth 1 \
            \( -name "${ts}.tar.zst" -o -name "${ts}.tar.gz" \) 2>/dev/null | head -1)
        [[ -z "${archive}" ]] && { printf 'No bundle for %s @ %s\n' "${project}" "${ts}" >&2; exit 1; }

        mkdir -p "${dest_parent}"
        # Refuse to clobber if the project folder already exists at the dest
        if [[ -e "${dest_parent}/${project}" ]]; then
            printf 'Refusing to overwrite existing folder: %s/%s\n' "${dest_parent}" "${project}" >&2
            printf 'Move or rename it first.\n' >&2
            exit 1
        fi

        printf 'Restoring %s @ %s\n  -> %s/%s\n' "${project}" "${ts}" "${dest_parent}" "${project}"
        log "restore start: ${archive} -> ${dest_parent}"
        case "${archive}" in
            *.zst)  zstd -dc "${archive}" | tar -C "${dest_parent}" -xf - ;;
            *.gz)   gzip -dc "${archive}" | tar -C "${dest_parent}" -xf - ;;
        esac
        log "restore ok: ${archive} -> ${dest_parent}/${project}"
        printf 'Done. Project restored to: %s/%s\n' "${dest_parent}" "${project}"
        ;;

    size)
        if [[ $# -eq 1 ]]; then
            project="$1"
            du -sh "${VERSIONS_DIR}/${project}/_bundles" 2>/dev/null || printf 'No bundles for %s\n' "${project}"
        else
            find "${VERSIONS_DIR}" -mindepth 3 -maxdepth 3 -type f \
                \( -name '*.tar.zst' -o -name '*.tar.gz' \) -exec du -k {} + 2>/dev/null \
                | awk '{s+=$1} END {printf "Total bundles: %.1f MB across %d files\n", s/1024, NR}'
        fi
        ;;

    *)
        usage
        ;;
esac
