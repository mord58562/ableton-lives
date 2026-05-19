#!/usr/bin/env zsh
# uninstall.sh - removes Ableton Lives agents, Quick Action, and menu bar app.
#
# Default mode leaves your data and credentials untouched:
#   - The version store at <LIVES_VERSIONS_DIR>/_versions/    (your data)
#   - The config file at ~/.config/ableton-lives/config       (your settings)
#   - The encrypted backup at lives-crypt:                    (your cloud copy)
#   - The rclone config at ~/.config/rclone/rclone.conf       (your auth)
#
# Pass --purge to also remove the config dir, the local _versions/ tree,
# the menubar app bundle, the in-tree built app, and the rclone remotes,
# leaving the source checkout as if it had never been installed.

set -euo pipefail

PURGE=0
for arg in "$@"; do
    case "${arg}" in
        --purge) PURGE=1 ;;
        -h|--help)
            cat <<HELP
Usage: uninstall.sh [--purge]

  (default)    Removes launch agents, Quick Action, and menubar binary.
               Leaves your version store, config file, cloud backup,
               and rclone authentication intact.

  --purge      Also removes:
                 ~/.config/ableton-lives/
                 ~/Music/Ableton/_versions/  (your local version store)
                 swift/AbletonLives.app/     (the built menubar binary)
                 rclone remotes lives-gdrive and lives-crypt
               The cloud backup folder in Drive itself is NOT touched.
HELP
            exit 0 ;;
    esac
done

LIVES_HOME="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
SERVICES_DIR="${HOME}/Library/Services"
CONFIG_DIR="${HOME}/.config/ableton-lives"
CONFIG_FILE="${CONFIG_DIR}/config"
WORKFLOW="Restore Ableton Version.workflow"
LOG_FILE="${HOME}/Library/Logs/ableton-lives.log"
NOTIFY_LOG="${HOME}/Library/Logs/ableton-lives-notifications.log"

PLIST_NAMES=(
    com.mord58562.ableton-lives.watch
    com.mord58562.ableton-lives.prune
    com.mord58562.ableton-lives.sync
    com.mord58562.ableton-lives.verify
    com.mord58562.ableton-lives.crash
    com.mord58562.ableton-lives.menubar
)

# Resolve the version store path from the config (falls back to default
# if config is gone or unreadable). Done before we wipe the config so
# --purge can still find _versions/.
VERSIONS_DIR=""
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}" 2>/dev/null || true
    VERSIONS_DIR="${LIVES_VERSIONS_DIR:-}"
fi
[[ -z "${VERSIONS_DIR}" ]] && VERSIONS_DIR="${HOME}/Music/Ableton/_versions"

printf '\n=== Ableton Lives - Uninstaller ===\n\n'

lc_uid="gui/$(id -u)"
lc_bootout() {
    local plist="$1"
    local label="$(basename "${plist}" .plist)"
    launchctl bootout "${lc_uid}/${label}" 2>/dev/null \
        || launchctl unload "${plist}" 2>/dev/null \
        || true
}

printf '[1/5] Unloading and removing launch agents...\n'
for label in "${PLIST_NAMES[@]}"; do
    plist="${LAUNCH_AGENTS}/${label}.plist"
    if [[ -e "${plist}" ]]; then
        lc_bootout "${plist}"
        rm -f "${plist}"
        printf '      Removed: %s.plist\n' "${label}"
    fi
done

printf '[2/5] Removing Finder Quick Action...\n'
if [[ -d "${SERVICES_DIR}/${WORKFLOW}" ]]; then
    rm -rf "${SERVICES_DIR}/${WORKFLOW}"
    printf '      Removed: %s\n' "${WORKFLOW}"
fi

printf '[3/5] Cleaning up legacy menubar plugin symlinks (if any)...\n'
# Legacy from the SwiftBar/xbar shell-plugin era. The current menubar is
# a Swift .app launched by launchd; nothing to remove here in fresh
# installs, but harmless to attempt for users upgrading.
for d in "${HOME}/Library/Application Support/xbar/plugins" \
         "${HOME}/Library/Application Support/SwiftBar/plugins"; do
    # Use -e not -L so regular files left behind by an older installer
    # also get cleaned up, not just symlinks.
    if [[ -e "${d}/ableton-lives-menubar.5m.sh" ]]; then
        rm -f "${d}/ableton-lives-menubar.5m.sh"
        printf '      Unlinked legacy plugin from: %s\n' "${d}"
    fi
done

printf '[4/5] Cleaning ephemeral state...\n'
rm -f /tmp/ableton-lives-watch.lock /tmp/ableton-lives-sync.lock 2>/dev/null || true
rm -f "${HOME}/.ableton-lives-seen-hashes" 2>/dev/null || true
rm -f "${HOME}/.ableton-lives-notify-state" 2>/dev/null || true
rm -f "${HOME}/.ableton-lives-last-crash" 2>/dev/null || true
rm -f "${HOME}/.ableton-lives-crash-seen" 2>/dev/null || true
printf '      Removed lockfiles, hash cache, notify state.\n'

printf '[5/5] Removing in-tree built menubar app...\n'
if [[ -d "${LIVES_HOME}/swift/AbletonLives.app" ]]; then
    rm -rf "${LIVES_HOME}/swift/AbletonLives.app"
    printf '      Removed: %s/swift/AbletonLives.app\n' "${LIVES_HOME}"
fi

if [[ ${PURGE} -eq 1 ]]; then
    printf '\n--- --purge: wiping data, config, and rclone remotes ---\n'
    if [[ -d "${CONFIG_DIR}" ]]; then
        rm -rf "${CONFIG_DIR}"
        printf '      Removed: %s\n' "${CONFIG_DIR}"
    fi
    if [[ -d "${VERSIONS_DIR}" ]]; then
        rm -rf "${VERSIONS_DIR}"
        printf '      Removed: %s\n' "${VERSIONS_DIR}"
    fi
    rm -f "${LOG_FILE}" "${NOTIFY_LOG}" 2>/dev/null || true
    if command -v rclone >/dev/null 2>&1; then
        # Delete the lives-* remotes only. atm-* (legacy) and any user-named
        # remotes are intentionally left alone.
        for remote in lives-crypt lives-gdrive; do
            if rclone listremotes 2>/dev/null | grep -qx "${remote}:"; then
                rclone config delete "${remote}" 2>/dev/null \
                    && printf '      Removed rclone remote: %s\n' "${remote}"
            fi
        done
    fi
    printf '\n--purge complete. The cloud backup folder in Drive itself is untouched.\n'
fi

cat <<DONE

=== Uninstall complete. ===

DONE

if [[ ${PURGE} -eq 0 ]]; then
    cat <<KEPT
Preserved (delete by hand or rerun with --purge if you really want them gone):
  • Versions:        ${VERSIONS_DIR}
  • Settings:        ${CONFIG_FILE}
  • Cloud backup:    lives-crypt: in your Drive (folder "lives-encrypted")
  • rclone auth:     ~/.config/rclone/rclone.conf

To wipe the local version store:
  rm -rf ${VERSIONS_DIR}

To remove the rclone remotes only:
  rclone config delete lives-crypt
  rclone config delete lives-gdrive

KEPT
fi
