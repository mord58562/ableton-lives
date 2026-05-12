#!/usr/bin/env zsh
# atm-cloud-restore.sh - pull the encrypted backup from Google Drive.
#
# Use this when the local _versions/ store is gone (disk failure, fresh
# machine, accidentally deleted). Requires that the rclone crypt remote
# is configured with the SAME passwords as the original sync.
#
# Usage:
#   atm-cloud-restore.sh                      Full restore -> ~/Music/Ableton/_versions/
#   atm-cloud-restore.sh --to <path>          Alternate destination
#   atm-cloud-restore.sh --project <name>     One project only
#   atm-cloud-restore.sh --dry-run            Show what would happen
#   atm-cloud-restore.sh --resume             Skip files that already exist locally

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"
VERSIONS_DIR="${ATM_VERSIONS_DIR}"
LOG="${ATM_LOG}"
SYNC_REMOTE="${ATM_SYNC_REMOTE}"
SYNC_PATH="${ATM_SYNC_PATH}"
RCLONE="${ATM_RCLONE:-rclone}"

dest="${VERSIONS_DIR}"
project=""
dry_run=0
resume=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)       dest="$2"; shift 2 ;;
        --project)  project="$2"; shift 2 ;;
        --dry-run)  dry_run=1; shift ;;
        --resume)   resume=1; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

if ! command -v "${RCLONE}" >/dev/null 2>&1; then
    printf 'rclone not installed. brew install rclone\n' >&2
    exit 1
fi

if ! "${RCLONE}" listremotes 2>/dev/null | grep -qx "${SYNC_REMOTE}:"; then
    printf 'Crypt remote "%s:" not configured. Run atm-sync-setup.sh.\n' "${SYNC_REMOTE}" >&2
    printf 'You will need the SAME passwords as the original backup.\n' >&2
    exit 1
fi

src="${SYNC_REMOTE}:${SYNC_PATH}"
if [[ -n "${project}" ]]; then
    src="${src}/${project}"
    dest="${dest}/${project}"
fi

mkdir -p "${dest}"

# Pre-flight: refuse to clobber a non-empty existing destination unless --resume.
if [[ "${resume}" -eq 0 ]] && [[ -d "${dest}" ]] && [[ -n "$(ls -A "${dest}" 2>/dev/null)" ]]; then
    printf 'Destination %s is not empty.\n' "${dest}" >&2
    printf 'Re-run with --resume to merge (skips files that already exist),\n' >&2
    printf 'or pick a fresh --to path.\n' >&2
    exit 1
fi

printf '\n'
printf 'Cloud restore plan:\n'
printf '  Source:      %s\n' "${src}"
printf '  Destination: %s\n' "${dest}"
[[ "${dry_run}" -eq 1 ]] && printf '  Mode:        DRY RUN (no files written)\n'
[[ "${resume}" -eq 1 ]] && printf '  Mode:        resume (existing files preserved)\n'
printf '\n'

# Show size first so the user knows what they are committing to.
printf 'Querying remote size...\n'
"${RCLONE}" size "${src}" 2>/dev/null | sed 's/^/  /'
printf '\n'

if [[ "${dry_run}" -ne 1 ]]; then
    printf 'Continue? [y/N] '
    read -r answer
    [[ "${answer}" != "y" && "${answer}" != "Y" ]] && { printf 'Aborted.\n'; exit 0; }
fi

printf '\nDownloading...\n'
flags=( --transfers 8 --checksum --progress )
[[ "${dry_run}" -eq 1 ]] && flags+=( --dry-run )
[[ "${resume}" -eq 1 ]] && flags+=( --ignore-existing )

if "${RCLONE}" copy "${src}" "${dest}" "${flags[@]}"; then
    printf '\nRestore complete.\n'
    printf '  Files restored to: %s\n' "${dest}"
    printf '\nNext steps:\n'
    printf '  1. Verify with: ls "%s"\n' "${dest}"
    printf '  2. To resume normal sync: ensure atm-sync.sh runs nightly.\n'
else
    printf '\nRestore FAILED. Partial download may be in: %s\n' "${dest}" >&2
    printf 'Re-run with --resume to continue.\n' >&2
    exit 1
fi
