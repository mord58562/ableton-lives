#!/usr/bin/env zsh
# atm-config.sh - read or change ATM configuration values.
#
# Usage:
#   atm-config.sh                       # show current effective values
#   atm-config.sh get <key>             # print one value
#   atm-config.sh set <key> <value>     # write/update one value
#   atm-config.sh unset <key>           # remove an override (revert to default)
#   atm-config.sh edit                  # open the file in $EDITOR
#   atm-config.sh path                  # print the config file path
#
# Storage cap example:
#   atm-config.sh set ATM_REMOTE_CAP_GB 50
#   atm-config.sh set ATM_FREE_FLOOR_GB 5
#
# Path examples:
#   atm-config.sh set ATM_USB_PATH "/Volumes/MyDrive/ableton"
#   atm-config.sh unset ATM_USB_PATH
#
# After changing storage caps, the change takes effect on the next sync run.
# After changing watched paths, run:
#   launchctl unload ~/Library/LaunchAgents/com.atm.watch.plist
#   launchctl load   ~/Library/LaunchAgents/com.atm.watch.plist
# (the menu bar's "Reload watcher" action does this for you).

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"

# Whitelist of keys users may set, with one-line descriptions for `show`.
typeset -A KEYS
KEYS=(
    ATM_INTERNAL_PATH       "Folder containing your Ableton projects (default: ~/Music/Ableton)"
    ATM_VERSIONS_DIR        "Where versioned snapshots are stored"
    ATM_LIBRARY_PATH        "Ableton User Library path (presets, samples, templates)"
    ATM_USB_PATH            "Optional external drive path to also watch (empty = none)"
    ATM_LOG                 "Main log file"
    ATM_SUMMARY             "KEY=VALUE state file consumed by the menu bar"
    ATM_QUOTA_REMOTE        "rclone remote name for Drive quota queries"
    ATM_SYNC_REMOTE         "rclone crypt remote name for encrypted sync"
    ATM_SYNC_PATH           "Top-level path inside the crypt remote"
    ATM_REMOTE_CAP_GB       "Hard ceiling on local + cloud storage in GB (default 20)"
    ATM_FREE_FLOOR_GB       "Sync refuses if Drive free space drops below this (default 10)"
    ATM_CAP_WARN_PCT        "Soft warning at this % of the cap (default 75)"
    ATM_WARN_USED_PCT       "Soft warning when Drive overall usage crosses this % (default 80)"
)

ensure_config_dir() {
    mkdir -p "$(dirname "${ATM_CONFIG}")"
    [[ -f "${ATM_CONFIG}" ]] || : > "${ATM_CONFIG}"
}

set_key() {
    local key="$1" value="$2"
    [[ -z "${KEYS[$key]:-}" ]] && { printf 'Unknown key: %s\n' "${key}" >&2; exit 1; }
    ensure_config_dir
    local tmp="${ATM_CONFIG}.tmp.$$"
    grep -v "^${key}=" "${ATM_CONFIG}" > "${tmp}" 2>/dev/null || true
    # Quote the value so spaces/special chars survive sourcing.
    printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
    mv "${tmp}" "${ATM_CONFIG}"
    printf 'Set %s = %s\n' "${key}" "${value}"
    printf 'File: %s\n' "${ATM_CONFIG}"
}

unset_key() {
    local key="$1"
    [[ -f "${ATM_CONFIG}" ]] || return 0
    local tmp="${ATM_CONFIG}.tmp.$$"
    grep -v "^${key}=" "${ATM_CONFIG}" > "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${ATM_CONFIG}"
    printf 'Unset %s (will use default)\n' "${key}"
}

show_all() {
    printf 'Config file: %s\n' "${ATM_CONFIG}"
    [[ -f "${ATM_CONFIG}" ]] || printf '  (file does not exist yet - all defaults in effect)\n'
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
    set)            [[ $# -ne 3 ]] && { printf 'Usage: atm-config.sh set KEY VALUE\n' >&2; exit 1; }
                    set_key "$2" "$3" ;;
    unset)          [[ -z "${2:-}" ]] && exit 1; unset_key "$2" ;;
    edit)           ensure_config_dir; "${EDITOR:-nano}" "${ATM_CONFIG}" ;;
    path)           printf '%s\n' "${ATM_CONFIG}" ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *)              printf 'Unknown command: %s. Try --help.\n' "${mode}" >&2; exit 1 ;;
esac
