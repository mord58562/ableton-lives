#!/usr/bin/env zsh
# uninstall.sh - removes ATM agents, Quick Action, and menu bar plugin.
#
# Leaves untouched:
#   - The version store at <ATM_VERSIONS_DIR>/_versions/    (your data)
#   - The config file at ~/.config/atm/config                (your settings)
#   - The encrypted backup at atm-crypt:                     (your cloud copy)
#   - The rclone config at ~/.config/rclone/rclone.conf      (your auth)
#
# Delete those by hand if you really want to wipe everything.

set -euo pipefail

LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
SERVICES_DIR="${HOME}/Library/Services"
WORKFLOW="Restore Ableton Version.workflow"

PLIST_NAMES=(com.atm.watch com.atm.prune com.atm.sync com.atm.verify com.atm.crash com.atm.menubar)

printf '\n=== Ableton Time Machine - Uninstaller ===\n\n'

printf '[1/4] Unloading and removing launch agents...\n'
for label in "${PLIST_NAMES[@]}"; do
    plist="${LAUNCH_AGENTS}/${label}.plist"
    if [[ -f "${plist}" ]]; then
        launchctl unload "${plist}" 2>/dev/null || true
        rm -f "${plist}"
        printf '      Removed: %s.plist\n' "${label}"
    fi
done

printf '[2/4] Removing Finder Quick Action...\n'
if [[ -d "${SERVICES_DIR}/${WORKFLOW}" ]]; then
    rm -rf "${SERVICES_DIR}/${WORKFLOW}"
    printf '      Removed: %s\n' "${WORKFLOW}"
fi

printf '[3/4] Cleaning up legacy menu bar plugin symlinks (if any)...\n'
# Legacy from the SwiftBar/xbar shell-plugin era. The current menu bar is
# a real Swift .app launched by launchd; nothing to remove here in fresh
# installs, but harmless to attempt for users upgrading.
for d in "${HOME}/Library/Application Support/xbar/plugins" \
         "${HOME}/Library/Application Support/SwiftBar/plugins"; do
    if [[ -L "${d}/atm-menubar.5m.sh" ]]; then
        rm -f "${d}/atm-menubar.5m.sh"
        printf '      Unlinked legacy plugin from: %s\n' "${d}"
    fi
done

printf '[4/4] Cleaning ephemeral state...\n'
rm -f /tmp/atm-watch.lock /tmp/atm-sync.lock 2>/dev/null || true
rm -f "${HOME}/.atm-seen-hashes" 2>/dev/null || true
printf '      Removed lockfiles + seen-hashes cache.\n'

cat <<DONE

=== Uninstall complete. ===

Preserved (delete by hand if you really want them gone):
  • Versions:        ~/Music/Ableton/_versions/      (or wherever your config points)
  • Settings:        ~/.config/atm/config
  • Notify state:    ~/.atm-notify-state, ~/.atm-last-crash, ~/.atm-crash-seen
  • Cloud backup:    atm-crypt: in your Drive (folder "atm-encrypted")
  • rclone auth:     ~/.config/rclone/rclone.conf

To wipe the local version store:
  rm -rf ~/Music/Ableton/_versions/

To remove the rclone remotes only:
  rclone config delete atm-crypt
  rclone config delete atm-gdrive

DONE
