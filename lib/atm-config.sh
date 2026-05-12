#!/usr/bin/env zsh
# atm-config.sh - shared configuration loader for every ATM script.
#
# Source from any script:
#   ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
#   source "${ATM_LIB_DIR}/atm-config.sh"
#
# Config file is ~/.config/atm/config (overridable via ATM_CONFIG env var).
# Format: simple shell key=value, sourced directly. Created by install.sh
# on first install. Users may edit it freely - one knob per line.
#
# Every value can also be overridden by an env var of the same name, which
# is what the test suite uses to isolate state.

ATM_CONFIG="${ATM_CONFIG:-${HOME}/.config/atm/config}"

# Source the user's config if it exists. Failures are non-fatal so a fresh
# install (no config yet) still gets sane defaults.
if [[ -f "${ATM_CONFIG}" ]]; then
    source "${ATM_CONFIG}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Defaults (only applied if config + env both unset)
# ---------------------------------------------------------------------------
: "${ATM_INTERNAL_PATH:=${HOME}/Music/Ableton}"
: "${ATM_VERSIONS_DIR:=${ATM_INTERNAL_PATH}/_versions}"
: "${ATM_LOG:=${HOME}/Library/Logs/ableton-time-machine.log}"
: "${ATM_SUMMARY:=${HOME}/Documents/.atm-summary}"
: "${ATM_SEEN_HASHES:=${HOME}/.atm-seen-hashes}"
: "${ATM_USB_PATH:=}"           # empty = no external drive watched
# Ableton User Library (presets, samples, templates, clips). Can be
# anywhere - Live > Preferences > Library > Browser content lets you
# relocate it. Recorded here so bundle snapshots and future features
# know where to find it. NOT actively versioned (it contains big binary
# samples that rarely change in ways .als versioning would capture).
: "${ATM_LIBRARY_PATH:=${ATM_INTERNAL_PATH}/User Library}"
: "${ATM_QUOTA_REMOTE:=atm-gdrive}"
# ATM_ENCRYPT_BACKUP controls which sync remote is used:
#   1 (default) - encrypted: ATM_SYNC_REMOTE=atm-crypt (rclone crypt layer
#                 wrapping atm-gdrive). Google sees only opaque blobs.
#   0           - unencrypted: ATM_SYNC_REMOTE=atm-gdrive directly. Files
#                 are visible/downloadable from drive.google.com. No
#                 password to lose; suitable for sharing with collaborators.
: "${ATM_ENCRYPT_BACKUP:=1}"
if [[ "${ATM_ENCRYPT_BACKUP}" = "1" ]]; then
    : "${ATM_SYNC_REMOTE:=atm-crypt}"
else
    : "${ATM_SYNC_REMOTE:=atm-gdrive}"
fi
: "${ATM_SYNC_PATH:=versions}"

# ---------------------------------------------------------------------------
# Storage caps (user-tunable in ~/.config/atm/config)
#
#   ATM_REMOTE_CAP_GB     Hard ceiling on local _versions/ AND cloud storage.
#                         Sync refuses if exceeded. Default 20 GB.
#   ATM_FREE_FLOOR_GB     Sync refuses if Drive free space < this. Default 10.
#   ATM_CAP_WARN_PCT      Soft warning at this % of cap. Default 75.
#   ATM_WARN_USED_PCT     Soft warning when Drive % full crosses this. Default 80.
#
# To raise the cap, edit ~/.config/atm/config and set:
#   ATM_REMOTE_CAP_GB=50
# Lowering it triggers more aggressive prune; the next sync will refuse
# until local _versions/ is back under the new ceiling.
# ---------------------------------------------------------------------------
: "${ATM_REMOTE_CAP_GB:=20}"
: "${ATM_FREE_FLOOR_GB:=10}"
: "${ATM_CAP_WARN_PCT:=75}"
: "${ATM_WARN_USED_PCT:=80}"

export ATM_CONFIG ATM_INTERNAL_PATH ATM_VERSIONS_DIR ATM_LOG ATM_SUMMARY \
       ATM_SEEN_HASHES ATM_USB_PATH ATM_QUOTA_REMOTE ATM_SYNC_REMOTE ATM_SYNC_PATH \
       ATM_REMOTE_CAP_GB ATM_FREE_FLOOR_GB ATM_CAP_WARN_PCT ATM_WARN_USED_PCT
