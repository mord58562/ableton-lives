#!/usr/bin/env zsh
# lives-config.sh - shared configuration loader for every Ableton Lives script.
#
# Source from any script:
#   LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
#   source "${LIVES_LIB_DIR}/lives-config.sh"
#
# Config file is ~/.config/ableton-lives/config (overridable via LIVES_CONFIG env var).
# Format: simple shell key=value, sourced directly. Created by install.sh
# on first install. Users may edit it freely - one knob per line.
#
# Every value can also be overridden by an env var of the same name, which
# is what the test suite uses to isolate state.

LIVES_CONFIG="${LIVES_CONFIG:-${HOME}/.config/ableton-lives/config}"

# Source the user's config if it exists. Failures are non-fatal so a fresh
# install (no config yet) still gets sane defaults.
if [[ -f "${LIVES_CONFIG}" ]]; then
    source "${LIVES_CONFIG}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Defaults (only applied if config + env both unset)
# ---------------------------------------------------------------------------
: "${LIVES_INTERNAL_PATH:=${HOME}/Music/Ableton}"
: "${LIVES_VERSIONS_DIR:=${LIVES_INTERNAL_PATH}/_versions}"
: "${LIVES_LOG:=${HOME}/Library/Logs/ableton-lives.log}"
: "${LIVES_SUMMARY:=${HOME}/Documents/.ableton-lives-summary}"
: "${LIVES_SEEN_HASHES:=${HOME}/.ableton-lives-seen-hashes}"
: "${LIVES_USB_PATH:=}"           # empty = no external drive watched
# Ableton User Library (presets, samples, templates, clips). Can be
# anywhere - Live > Preferences > Library > Browser content lets you
# relocate it. Recorded here so bundle snapshots and future features
# know where to find it. NOT actively versioned (it contains big binary
# samples that rarely change in ways .als versioning would capture).
: "${LIVES_LIBRARY_PATH:=${LIVES_INTERNAL_PATH}/User Library}"
: "${LIVES_QUOTA_REMOTE:=lives-gdrive}"
# LIVES_ENCRYPT_BACKUP controls which sync remote is used:
#   1 (default) - encrypted: LIVES_SYNC_REMOTE=lives-crypt (rclone crypt layer
#                 wrapping lives-gdrive). Google sees only opaque blobs.
#   0           - unencrypted: LIVES_SYNC_REMOTE=lives-gdrive directly. Files
#                 are visible/downloadable from drive.google.com. No
#                 password to lose; suitable for sharing with collaborators.
: "${LIVES_ENCRYPT_BACKUP:=1}"
if [[ "${LIVES_ENCRYPT_BACKUP}" = "1" ]]; then
    : "${LIVES_SYNC_REMOTE:=lives-crypt}"
else
    : "${LIVES_SYNC_REMOTE:=lives-gdrive}"
fi
: "${LIVES_SYNC_PATH:=versions}"

# ---------------------------------------------------------------------------
# Storage caps (user-tunable in ~/.config/ableton-lives/config)
#
#   LIVES_REMOTE_CAP_GB     Hard ceiling on local _versions/ AND cloud storage.
#                         Sync refuses if exceeded. Default 20 GB.
#   LIVES_FREE_FLOOR_GB     Sync refuses if Drive free space < this. Default 10.
#   LIVES_CAP_WARN_PCT      Soft warning at this % of cap. Default 75.
#   LIVES_WARN_USED_PCT     Soft warning when Drive % full crosses this. Default 80.
#
# To raise the cap, edit ~/.config/ableton-lives/config and set:
#   LIVES_REMOTE_CAP_GB=50
# Lowering it triggers more aggressive prune; the next sync will refuse
# until local _versions/ is back under the new ceiling.
# ---------------------------------------------------------------------------
: "${LIVES_REMOTE_CAP_GB:=20}"
: "${LIVES_FREE_FLOOR_GB:=10}"
: "${LIVES_CAP_WARN_PCT:=75}"
: "${LIVES_WARN_USED_PCT:=80}"

export LIVES_CONFIG LIVES_INTERNAL_PATH LIVES_VERSIONS_DIR LIVES_LOG LIVES_SUMMARY \
       LIVES_SEEN_HASHES LIVES_USB_PATH LIVES_QUOTA_REMOTE LIVES_SYNC_REMOTE LIVES_SYNC_PATH \
       LIVES_REMOTE_CAP_GB LIVES_FREE_FLOOR_GB LIVES_CAP_WARN_PCT LIVES_WARN_USED_PCT
