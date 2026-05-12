#!/usr/bin/env zsh
# atm-sync-setup.sh - one-time interactive setup for encrypted Google Drive sync
#
# Creates two rclone remotes:
#   atm-gdrive  - raw Google Drive remote (used ONLY for quota queries)
#   atm-crypt   - crypt remote wrapping atm-gdrive:atm-encrypted/
#                 (all file content goes here; Google sees only opaque blobs)
#
# Run this once. After it succeeds, the launchd sync agent will start syncing
# nightly at 04:30. Re-run any time to rotate or re-verify the configuration.

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"

RCLONE_BIN="${ATM_RCLONE:-rclone}"
QUOTA_REMOTE="${ATM_QUOTA_REMOTE}"
SYNC_REMOTE="${ATM_SYNC_REMOTE}"
RCLONE_CONFIG="${HOME}/.config/rclone/rclone.conf"
ENCRYPT="${ATM_ENCRYPT_BACKUP:-1}"

printf '\n=== Ableton Time Machine - Sync Setup ===\n\n'

if ! command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
    printf 'rclone is not installed.\n\n'
    printf 'Install it with:\n'
    printf '  brew install rclone\n\n'
    printf 'Then re-run this script.\n'
    exit 1
fi

printf 'rclone version: %s\n\n' "$("${RCLONE_BIN}" version | head -1)"

# ---------------------------------------------------------------------------
# Step 1: configure raw Google Drive remote
# ---------------------------------------------------------------------------
if "${RCLONE_BIN}" listremotes 2>/dev/null | grep -qx "${QUOTA_REMOTE}:"; then
    printf '[1/3] Raw Drive remote "%s:" already exists - skipping.\n' "${QUOTA_REMOTE}"
    printf '      To change which Google account this points at:\n'
    printf '        rclone config delete %s\n' "${QUOTA_REMOTE}"
    printf '        bin/atm-sync-setup.sh   (re-run to recreate)\n\n'
else
    printf '[1/3] Configuring Google Drive remote "%s:"...\n' "${QUOTA_REMOTE}"
    printf '\n'
    printf '      A browser window will open for Google OAuth.\n'
    printf '      In the Google account picker, choose the account whose Drive\n'
    printf '      storage you want to use for backups (this can be different\n'
    printf '      from your primary Google account - any account with enough\n'
    printf '      free space works).\n\n'
    printf '      When rclone asks "Scope that rclone should use", choose: 1\n'
    printf '      (full access) so rclone can manage the encrypted folder it\n'
    printf '      will create on your Drive.\n\n'
    read -r "?Press Return to launch rclone config..."
    "${RCLONE_BIN}" config create "${QUOTA_REMOTE}" drive scope=drive
fi

# Verify the raw remote works (this also surfaces any OAuth issues now,
# before we commit to crypt setup).
printf '\n      Testing quota query...\n'
if ! "${RCLONE_BIN}" about "${QUOTA_REMOTE}:" >/dev/null 2>&1; then
    printf '      FAILED. Could not query "%s:". Re-run rclone config:\n' "${QUOTA_REMOTE}"
    printf '        rclone config reconnect %s:\n' "${QUOTA_REMOTE}"
    exit 1
fi
"${RCLONE_BIN}" about "${QUOTA_REMOTE}:" | sed 's/^/      /'

# ---------------------------------------------------------------------------
# Step 2: configure encryption layer (only in encrypted mode)
# ---------------------------------------------------------------------------
if [[ "${ENCRYPT}" = "1" ]]; then
    printf '\n[2/3] Configuring encryption layer "%s:"...\n' "${SYNC_REMOTE}"

    if "${RCLONE_BIN}" listremotes 2>/dev/null | grep -qx "${SYNC_REMOTE}:"; then
        # Sanity-check that the existing crypt remote actually has passwords
        # set. The earlier broken setup created a passwordless remote that
        # silently fails every sync.
        existing_pw=$("${RCLONE_BIN}" config show "${SYNC_REMOTE}" 2>/dev/null \
                      | awk -F'= *' '$1=="password"{print $2}')
        if [[ -z "${existing_pw}" ]]; then
            printf '      Existing crypt remote is missing passwords - recreating.\n'
            "${RCLONE_BIN}" config delete "${SYNC_REMOTE}" 2>/dev/null || true
        else
            printf '      Crypt remote "%s:" already exists - skipping.\n' "${SYNC_REMOTE}"
            printf '      (To rotate keys: rclone config delete %s, then re-run setup.)\n' "${SYNC_REMOTE}"
        fi
    fi

    if ! "${RCLONE_BIN}" listremotes 2>/dev/null | grep -qx "${SYNC_REMOTE}:"; then
        printf '\n'
        printf '      Creating an encrypted layer that wraps:\n'
        printf '        %s:atm-encrypted/\n\n' "${QUOTA_REMOTE}"
        printf '      Encryption: filename + directory-name + content. Google\n'
        printf '      sees only opaque encrypted blobs.\n\n'
        printf '      Two strong random passwords will be generated below.\n'
        printf '      *** SAVE BOTH IMMEDIATELY *** to your password manager.\n'
        printf '      If you lose either, the cloud backup is UNRECOVERABLE.\n'
        printf '      (Your local _versions/ store is unaffected.)\n\n'
        read -r "?Press Return to generate the passwords..."

        # Generate two cryptographically strong passwords.
        # openssl rand -hex 24 = 48 hex chars = 192 bits of entropy each.
        # Using openssl (not `tr ... | head`) because `head -c` closes the
        # pipe early, which sends SIGPIPE to `tr`, which (with set -e +
        # pipefail) silently kills this script. openssl is a single command
        # with no pipeline, so the failure mode doesn't apply.
        PW1=$(openssl rand -hex 24)
        PW2=$(openssl rand -hex 24)

        printf '\n  ============================================================\n'
        printf '  *** SAVE THESE NOW - they will only be shown once. ***\n'
        printf '  ============================================================\n\n'
        printf '  password   (file encryption key):\n'
        printf '    %s\n\n' "${PW1}"
        printf '  password2  (salt; mixes with password):\n'
        printf '    %s\n\n' "${PW2}"
        printf '  ============================================================\n\n'
        read -r "?Have you saved BOTH to your password manager? Type 'yes' to continue: " confirm
        if [[ "${confirm}" != "yes" ]]; then
            printf 'Aborted. No remote created. Re-run when ready.\n' >&2
            unset PW1 PW2
            exit 1
        fi

        # Obscure them as rclone expects (reversible, but standard format).
        OBS1=$("${RCLONE_BIN}" obscure "${PW1}")
        OBS2=$("${RCLONE_BIN}" obscure "${PW2}")

        "${RCLONE_BIN}" config create "${SYNC_REMOTE}" crypt \
            remote="${QUOTA_REMOTE}:atm-encrypted" \
            filename_encryption=standard \
            directory_name_encryption=true \
            password="${OBS1}" \
            password2="${OBS2}" >/dev/null

        # Wipe from this shell's memory ASAP. They still live in the rclone
        # config file (in obscured form), which is the unavoidable trade-off
        # for unattended nightly sync.
        unset PW1 PW2 OBS1 OBS2

        printf 'Crypt remote "%s:" created with strong random passwords.\n' "${SYNC_REMOTE}"
    fi
else
    printf '\n[2/3] Unencrypted mode selected - skipping crypt layer.\n'
    printf '      Files will sync directly to "%s:%s/".\n' "${QUOTA_REMOTE}" "${ATM_SYNC_PATH}"
    printf '      You can browse them at https://drive.google.com.\n'
    printf '      To switch to encrypted later: bin/atm-config.sh set ATM_ENCRYPT_BACKUP 1\n'
    printf '      then re-run this setup script.\n'
fi

# ---------------------------------------------------------------------------
# Step 3: dry-run smoke
# ---------------------------------------------------------------------------
printf '\n[3/3] Dry-run sync (no files will be uploaded)...\n'
VERSIONS_DIR="${ATM_VERSIONS_DIR}"
if [[ ! -d "${VERSIONS_DIR}" ]]; then
    printf '      _versions/ does not exist yet - skipping dry-run.\n'
    printf '      Sync will start working as soon as the watcher captures a save.\n'
else
    "${RCLONE_BIN}" sync "${VERSIONS_DIR}" "${SYNC_REMOTE}:${ATM_SYNC_PATH}" \
        --dry-run --checksum --max-delete 0 2>&1 | sed 's/^/      /' | head -20
fi

# ---------------------------------------------------------------------------
# Load the sync launchd agent now that we know setup is complete.
# install.sh deliberately stages the plist but does NOT load it until both
# remotes exist. Loading it here means the user gets a working sync the
# very first nightly cycle after setup, with zero "not configured" pings.
# ---------------------------------------------------------------------------
SYNC_PLIST_NAME="com.atm.sync.plist"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
if [[ -f "${LAUNCH_AGENTS_DIR}/${SYNC_PLIST_NAME}" ]]; then
    launchctl unload "${LAUNCH_AGENTS_DIR}/${SYNC_PLIST_NAME}" 2>/dev/null || true
    launchctl load "${LAUNCH_AGENTS_DIR}/${SYNC_PLIST_NAME}"
    printf '\n      Sync agent loaded. Runs nightly at 04:30.\n'
else
    printf '\n      NOTE: sync plist not staged. Run scripts/install.sh first.\n'
fi

# ---------------------------------------------------------------------------
# Reminder
# ---------------------------------------------------------------------------
printf '\n=== Setup complete. ===\n'
printf 'Config file: %s\n' "${RCLONE_CONFIG}"
printf '\n'
if [[ "${ENCRYPT}" = "1" ]]; then
    printf 'Recovery checklist (do this NOW if you have not):\n'
    printf '  1. Save BOTH crypt passwords to your password manager.\n'
    printf '  2. Back up %s to the same vault.\n' "${RCLONE_CONFIG}"
    printf '     (rclone obscures passwords in the file but they are recoverable\n'
    printf '      with the rclone binary - treat the file as secret.)\n'
else
    printf 'Backup is unencrypted. To switch to encrypted later:\n'
    printf '  bin/atm-config.sh set ATM_ENCRYPT_BACKUP 1\n'
    printf '  bin/atm-sync-setup.sh\n'
fi
printf '\n'
printf 'The launchd sync agent will run nightly at 04:30. To trigger now:\n'
printf '  zsh %s/atm-sync.sh\n' "$(cd "$(dirname "$0")" && pwd)"
printf '\n'
