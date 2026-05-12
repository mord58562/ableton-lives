#!/usr/bin/env zsh
# atm-preview.sh - extract metadata from a versioned .als
#
# Ableton .als files are gzip-compressed XML. This pulls a few high-signal
# fields so the restore picker can show "120 BPM · 8 tracks" alongside
# each timestamp instead of bare numbers.
#
# Usage:
#   atm-preview.sh <project> <timestamp>
#       Prints one line: BPM=120 TRACKS=8 LIVE=12.0.5 SIZE=4.2M
#
#   atm-preview.sh --file <path-to-als>
#       Same but for any .als file directly.
#
#   atm-preview.sh --label <project> <timestamp>
#       Prints a human-readable label ready for AppleScript:
#       "20260512-093045  ·  120 BPM  ·  8 tracks  ·  4.2M"
#
# No external XML library required; uses gunzip + grep -oE patterns.
# A small in-tree cache at _versions/<project>/_meta-cache makes
# repeated calls fast (Quick Action loops over many timestamps).

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"
VERSIONS_DIR="${ATM_VERSIONS_DIR}"

extract_meta() {
    local als="$1"
    local size_bytes
    size_bytes=$(stat -f '%z' "${als}" 2>/dev/null || echo 0)
    local size_h
    size_h=$(printf '%d' "${size_bytes}" | awk '{
        if ($1 >= 1073741824) printf "%.1fG", $1/1073741824
        else if ($1 >= 1048576) printf "%.1fM", $1/1048576
        else printf "%dK", $1/1024
    }')

    # Decompress the head of the file - first ~256KB is enough for tempo +
    # track count headers in any realistic .als. Avoids decompressing GBs
    # for projects with huge embedded sample chunks.
    local xml
    xml=$(gunzip -c "${als}" 2>/dev/null | head -c 524288 || true)

    # Tempo: <Tempo ...><Manual Value="120.000" /></Tempo>
    # Be lenient about whitespace and attribute ordering.
    local bpm
    bpm=$(printf '%s' "${xml}" | grep -oE '<Tempo[^>]*>.*?<Manual[[:space:]]+Value="[0-9.]+"' \
        | grep -oE 'Value="[0-9.]+"' | head -1 | grep -oE '[0-9.]+' | head -1)
    [[ -z "${bpm}" ]] && bpm=$(printf '%s' "${xml}" \
        | grep -oE '<Manual[[:space:]]+Value="[0-9]+\.[0-9]+"[[:space:]]*/>' \
        | head -1 | grep -oE '[0-9]+\.[0-9]+')

    # Tracks: count <MidiTrack> + <AudioTrack> + <ReturnTrack>
    local tracks
    tracks=$(printf '%s' "${xml}" \
        | grep -oE '<(MidiTrack|AudioTrack|ReturnTrack)[[:space:]]' | wc -l | tr -d ' ')

    # Creator: <Creator>Ableton Live 12.0.5</Creator>
    local live_ver
    live_ver=$(printf '%s' "${xml}" | grep -oE 'Ableton Live [0-9.]+' | head -1 \
        | sed 's/Ableton Live //')

    printf 'BPM=%s\tTRACKS=%s\tLIVE=%s\tSIZE=%s\n' \
        "${bpm:-?}" "${tracks:-?}" "${live_ver:-?}" "${size_h}"
}

# Cache lookup/store. Cache key = sha256 of the .als content (so cache
# stays valid across renames and survives version-store rebuilds).
cache_get_or_compute() {
    local als="$1"
    local project_dir
    project_dir=$(dirname "${als}")
    local cache="${project_dir}/_meta-cache"
    local hash
    hash=$(shasum -a 256 "${als}" 2>/dev/null | awk '{print $1}')
    [[ -z "${hash}" ]] && { extract_meta "${als}"; return; }

    if [[ -f "${cache}" ]]; then
        local cached
        cached=$(grep "^${hash}	" "${cache}" 2>/dev/null | head -1 | cut -f2-)
        if [[ -n "${cached}" ]]; then
            printf '%s\n' "${cached}"
            return
        fi
    fi
    local meta
    meta=$(extract_meta "${als}")
    printf '%s\t%s\n' "${hash}" "${meta}" >> "${cache}"
    printf '%s\n' "${meta}"
}

resolve_als() {
    local project="$1" ts="$2"
    find "${VERSIONS_DIR}/${project}" -maxdepth 1 -name "*-${ts}.als" 2>/dev/null | head -1
}

mode="${1:-}"
case "${mode}" in
    --file)
        [[ $# -ne 2 ]] && { printf 'Usage: atm-preview.sh --file <path>\n' >&2; exit 1; }
        cache_get_or_compute "$2"
        ;;
    --label)
        [[ $# -ne 3 ]] && { printf 'Usage: atm-preview.sh --label <project> <ts>\n' >&2; exit 1; }
        als=$(resolve_als "$2" "$3")
        [[ -z "${als}" ]] && { printf '%s  ·  (missing)\n' "$3"; exit 0; }
        meta=$(cache_get_or_compute "${als}")
        # Strip key= prefixes for human display
        bpm=$(printf '%s' "${meta}" | grep -oE 'BPM=[^	]+' | cut -d= -f2)
        tracks=$(printf '%s' "${meta}" | grep -oE 'TRACKS=[^	]+' | cut -d= -f2)
        size=$(printf '%s' "${meta}" | grep -oE 'SIZE=[^	]+' | cut -d= -f2)
        printf '%s  ·  %s BPM  ·  %s tracks  ·  %s\n' "$3" "${bpm}" "${tracks}" "${size}"
        ;;
    "")
        printf 'Usage: atm-preview.sh <project> <ts> | --file <path> | --label <project> <ts>\n' >&2
        exit 1
        ;;
    *)
        [[ $# -ne 2 ]] && { printf 'Usage: atm-preview.sh <project> <ts>\n' >&2; exit 1; }
        als=$(resolve_als "$1" "$2")
        [[ -z "${als}" ]] && { printf 'No version: %s @ %s\n' "$1" "$2" >&2; exit 1; }
        cache_get_or_compute "${als}"
        ;;
esac
