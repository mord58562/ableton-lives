#!/usr/bin/env zsh
# lives-config.sh - read or change Ableton Lives configuration values.
#
# Usage:
#   lives-config.sh                       # show current effective values
#   lives-config.sh get <key>             # print one value
#   lives-config.sh set <key> <value>     # write/update one value
#   lives-config.sh unset <key>           # remove an override (revert to default)
#   lives-config.sh edit                  # open the file in $EDITOR
#   lives-config.sh path                  # print the config file path
#
# Storage cap example:
#   lives-config.sh set LIVES_REMOTE_CAP_GB 50
#   lives-config.sh set LIVES_FREE_FLOOR_GB 5
#
# Path examples:
#   lives-config.sh set LIVES_USB_PATH "/Volumes/MyDrive/ableton"
#   lives-config.sh unset LIVES_USB_PATH
#
# After changing storage caps, the change takes effect on the next sync run.
# After changing watched paths, run:
#   launchctl unload ~/Library/LaunchAgents/com.mord58562.ableton-lives.watch.plist
#   launchctl load   ~/Library/LaunchAgents/com.mord58562.ableton-lives.watch.plist
# (the menu bar's "Reload watcher" action does this for you).

set -euo pipefail

LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${LIVES_LIB_DIR}/lives-config.sh"

# Whitelist of keys users may set, with one-line descriptions for `show`.
typeset -A KEYS
KEYS=(
    LIVES_INTERNAL_PATH       "Folder containing your Ableton projects (default: ~/Music/Ableton)"
    LIVES_VERSIONS_DIR        "Where versioned snapshots are stored"
    LIVES_LIBRARY_PATH        "Ableton User Library path (presets, samples, templates)"
    LIVES_USB_PATH            "Optional external drive path to also watch (empty = none)"
    LIVES_LOG                 "Main log file"
    LIVES_SUMMARY             "KEY=VALUE state file consumed by the menu bar"
    LIVES_QUOTA_REMOTE        "rclone remote name for Drive quota queries"
    LIVES_SYNC_REMOTE         "rclone crypt remote name for encrypted sync"
    LIVES_SYNC_PATH           "Top-level path inside the crypt remote"
    LIVES_REMOTE_CAP_GB       "Hard ceiling on local + cloud storage in GB (default 20)"
    LIVES_FREE_FLOOR_GB       "Sync refuses if Drive free space drops below this (default 10)"
    LIVES_CAP_WARN_PCT        "Soft warning at this % of the cap (default 75)"
    LIVES_WARN_USED_PCT       "Soft warning when Drive overall usage crosses this % (default 80)"
)

ensure_config_dir() {
    mkdir -p "$(dirname "${LIVES_CONFIG}")"
    [[ -f "${LIVES_CONFIG}" ]] || : > "${LIVES_CONFIG}"
}

set_key() {
    local key="$1" value="$2"
    [[ -z "${KEYS[$key]:-}" ]] && { printf 'Unknown key: %s\n' "${key}" >&2; exit 1; }
    ensure_config_dir
    local tmp="${LIVES_CONFIG}.tmp.$$"
    grep -v "^${key}=" "${LIVES_CONFIG}" > "${tmp}" 2>/dev/null || true
    # Quote the value so spaces/special chars survive sourcing.
    printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
    mv "${tmp}" "${LIVES_CONFIG}"
    printf 'Set %s = %s\n' "${key}" "${value}"
    printf 'File: %s\n' "${LIVES_CONFIG}"
}

unset_key() {
    local key="$1"
    [[ -f "${LIVES_CONFIG}" ]] || return 0
    local tmp="${LIVES_CONFIG}.tmp.$$"
    grep -v "^${key}=" "${LIVES_CONFIG}" > "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${LIVES_CONFIG}"
    printf 'Unset %s (will use default)\n' "${key}"
}

show_all() {
    printf 'Config file: %s\n' "${LIVES_CONFIG}"
    [[ -f "${LIVES_CONFIG}" ]] || printf '  (file does not exist yet - all defaults in effect)\n'
    printf '\n%-22s %s\n' "KEY" "VALUE"
    printf '%-22s %s\n' "----" "-----"
    for key in "${(@k)KEYS}"; do
        local value="${(P)key}"
        printf '%-22s %s\n' "${key}" "${value}"
    done
    printf '\nDescriptions:\n'
    for key in "${(@k)KEYS}"; do
        printf '  %-22s %s\n' "${key}" "${KEYS[$key]}"
    done
}

mode="${1:-show}"
case "${mode}" in
    show|"")        show_all ;;
    get)            [[ -z "${2:-}" ]] && exit 1; printf '%s\n' "${(P)2:-}" ;;
    set)            [[ $# -ne 3 ]] && { printf 'Usage: lives-config.sh set KEY VALUE\n' >&2; exit 1; }
                    set_key "$2" "$3" ;;
    unset)          [[ -z "${2:-}" ]] && exit 1; unset_key "$2" ;;
    edit)           ensure_config_dir; "${EDITOR:-nano}" "${LIVES_CONFIG}" ;;
    path)           printf '%s\n' "${LIVES_CONFIG}" ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *)              printf 'Unknown command: %s. Try --help.\n' "${mode}" >&2; exit 1 ;;
esac
