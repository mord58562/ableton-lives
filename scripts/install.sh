#!/usr/bin/env zsh
# install.sh - Ableton Lives interactive installer.
#
# Detects the source location, walks the user through configuration,
# renders launchd templates with their values, loads agents, and offers
# to run cloud-sync setup. Re-runnable: existing config is shown as the
# default for each prompt.
#
# When run on a TTY: full interactive wizard.
# When run non-interactively (piped, CI): uses defaults from presets/local.preset
# if present, otherwise standard Ableton defaults.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
    case "${arg}" in
        --dry-run|-n)  DRY_RUN=1 ;;
        -h|--help)
            cat <<HELP
Usage: install.sh [--dry-run]

  --dry-run    Walk through every prompt and show what *would* happen.
               No files are written, no agents loaded, no brew install.
               Safe to run on any machine without consequences.
HELP
            exit 0 ;;
    esac
done

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
LIVES_HOME="$(cd "$(dirname "$0")/.." && pwd)"
PRESET_FILE="${LIVES_HOME}/presets/local.preset"
LIB_DIR="${LIVES_HOME}/lib"
BIN_DIR="${LIVES_HOME}/bin"
LAUNCHD_DIR="${LIVES_HOME}/launchd"
QUICKACTION_DIR="${LIVES_HOME}/quickaction"
TESTS_DIR="${LIVES_HOME}/tests"

LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
SERVICES_DIR="${HOME}/Library/Services"
CONFIG_DIR="${HOME}/.config/ableton-lives"
CONFIG_FILE="${CONFIG_DIR}/config"

WORKFLOW="Restore Ableton Version.workflow"
PLIST_NAMES=(com.mord58562.ableton-lives.watch com.mord58562.ableton-lives.prune com.mord58562.ableton-lives.sync com.mord58562.ableton-lives.verify com.mord58562.ableton-lives.crash com.mord58562.ableton-lives.menubar)

# Colour helpers (no-op on non-TTY)
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'
    C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
    C_CYAN=$'\e[36m'
    INTERACTIVE=1
else
    C_BOLD=""; C_DIM=""; C_RESET=""
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
    INTERACTIVE=0
fi

ok()    { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()  { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
info()  { printf '%s•%s %s\n' "${C_CYAN}" "${C_RESET}" "$*"; }
step()  { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }
hr()    { printf '%s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..64})" "${C_RESET}"; }

# ---------------------------------------------------------------------------
# Audit log (only enabled in dry-run; one structured line per event).
# Format: ISO_TS \t EVENT_TYPE \t DETAIL
# Event types:
#   PROMPT       a question was shown
#   ANSWER       the user's response (or default if Enter)
#   WOULD_RUN    a command we'd execute
#   WOULD_WRITE  a file we'd create / overwrite
#   WOULD_LOAD   a launchctl operation
#   WOULD_LINK   a symlink we'd create
#   PREFLIGHT    a check result
#   STATE        wizard state transition (e.g., WANT_ENCRYPT=1)
# ---------------------------------------------------------------------------
AUDIT_LOG=""
if [[ ${DRY_RUN} -eq 1 ]]; then
    AUDIT_LOG="/tmp/lives-dryrun-$(date '+%Y%m%d-%H%M%S').log"
    : > "${AUDIT_LOG}"
    {
        printf '# Ableton Lives install.sh dry-run audit log\n'
        printf '# Started: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
        printf '# Source:  %s\n' "${LIVES_HOME:-(not yet detected)}"
        printf '# User:    %s\n' "$(whoami)"
        printf '# Host:    %s\n' "$(hostname -s)"
        printf '# Args:    %s\n' "$*"
        printf '# ---------------------------------------------------------------\n'
    } >> "${AUDIT_LOG}"
fi

audit() {
    [[ -z "${AUDIT_LOG}" ]] && return 0
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" >> "${AUDIT_LOG}"
}

# In dry-run mode every "would have" is announced in yellow AND audited.
dry_say() {
    printf '%s[dry-run]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"
    audit "WOULD" "$*"
}

# Prompt with default.  prompt VAR "Question" "default-value"
# Sets VAR to user input or default.
#
# Hint format (used everywhere - prompt() and prompt_yn()):
#   "Question (↵ = <thing Enter does>): "
#
# Empty default is shown as "(↵ = none)" rather than "(required)" because in
# this wizard an empty string is a valid answer meaning "no external drive".
prompt() {
    local var="$1" question="$2" default="${3-__NO_DEFAULT__}"
    if [[ ${INTERACTIVE} -eq 0 ]]; then
        local effective="${default}"
        [[ "${effective}" = "__NO_DEFAULT__" ]] && effective=""
        eval "${var}=\"\${effective}\""
        return
    fi
    local shown_default
    if [[ "${default}" = "__NO_DEFAULT__" ]]; then
        shown_default=""
        printf '  %s %s(required)%s: ' \
            "${question}" "${C_DIM}" "${C_RESET}"
    else
        if [[ -z "${default}" ]]; then
            shown_default="none"
        else
            shown_default="${default}"
        fi
        printf '  %s %s(↵ = %s)%s: ' \
            "${question}" "${C_DIM}" "${shown_default}" "${C_RESET}"
    fi
    local answer
    read -r answer
    if [[ -z "${answer}" ]]; then
        # Sentinel substitution: empty input on a no-default prompt yields ""
        if [[ "${default}" = "__NO_DEFAULT__" ]]; then
            answer=""
        else
            answer="${default}"
        fi
    fi
    # Sanitise common path-input mistakes:
    #   1. Trim leading/trailing whitespace.
    #   2. Drop surrounding single or double quotes if the user pasted them.
    #   3. Collapse `\<space>` (shell-style escape) into a literal space, since
    #      `read -r` keeps the backslash and confuses every downstream
    #      command.  Users routinely escape paths copied from a terminal.
    answer="${answer## }"; answer="${answer%% }"
    answer="${answer#\"}"; answer="${answer%\"}"
    answer="${answer#\'}"; answer="${answer%\'}"
    answer="${answer//\\ / }"
    audit "PROMPT" "${question} [default=${default}]"
    audit "ANSWER" "${var}=${answer}"
    eval "${var}=\"\${answer}\""
}

# Yes/no prompt. Same hint convention as prompt():
#   "Question (↵ = Yes): "  or  "Question (↵ = No): "
prompt_yn() {
    local question="$1" default="${2:-y}"
    if [[ ${INTERACTIVE} -eq 0 ]]; then
        [[ "${default}" = "y" ]] && return 0 || return 1
    fi
    local default_word
    [[ "${default}" = "y" ]] && default_word="Yes" || default_word="No"
    while true; do
        printf '  %s %s(↵ = %s, or y/n)%s: ' \
            "${question}" "${C_DIM}" "${default_word}" "${C_RESET}"
        local answer; read -r answer
        [[ -z "${answer}" ]] && answer="${default}"
        case "${answer}" in
            y|Y|yes|YES)
                audit "PROMPT" "${question} [default=${default}]"
                audit "ANSWER" "yes"
                return 0 ;;
            n|N|no|NO)
                audit "PROMPT" "${question} [default=${default}]"
                audit "ANSWER" "no"
                return 1 ;;
            *)  printf '    %sPlease answer y or n.%s\n' "${C_YELLOW}" "${C_RESET}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
cat <<BANNER

${C_BOLD}${C_BLUE}╭──────────────────────────────────────────────────────────────╮
│                                                              │
│    Ableton Lives                                      │
│    Automatic versioning + encrypted cloud backup for .als    │
│                                                              │
╰──────────────────────────────────────────────────────────────╯${C_RESET}
BANNER

if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '%s%s>>> DRY-RUN MODE <<<%s\n' "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
    printf '%sNo files will be written, no agents loaded, no brew install.%s\n\n' "${C_DIM}" "${C_RESET}"
fi

cat <<BANNER

This installer will:
  • Watch your Ableton folder for saves and version every change
  • Capture finished audio exports (.wav .aiff .mp3 .flac)
  • Run a daily retention pruner so storage stays small
  • Optionally sync to Google Drive with end-to-end encryption
  • Tag the closest version before any Ableton crash, automatically
  • Install a menu-bar status item (xbar / SwiftBar)

Source location: ${C_DIM}${LIVES_HOME}${C_RESET}

BANNER

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
step "Preflight"
audit "STATE" "LIVES_HOME=${LIVES_HOME}"
audit "STATE" "PRESET_FILE=${PRESET_FILE} (exists=$([[ -f ${PRESET_FILE} ]] && echo yes || echo no))"
audit "STATE" "CONFIG_FILE=${CONFIG_FILE} (exists=$([[ -f ${CONFIG_FILE} ]] && echo yes || echo no))"

if [[ "$(uname)" = "Darwin" ]]; then
    ok "macOS detected"
    audit "PREFLIGHT" "uname=Darwin OK"
else
    fail "Ableton Lives is macOS-only (uname is $(uname))."; exit 1
fi
command -v zsh >/dev/null && { ok "zsh present"; audit "PREFLIGHT" "zsh=$(command -v zsh)"; } \
    || { fail "zsh required."; exit 1; }
command -v shasum >/dev/null && { ok "shasum present"; audit "PREFLIGHT" "shasum=$(command -v shasum)"; } \
    || { fail "shasum required."; exit 1; }
audit "PREFLIGHT" "rclone=$(command -v rclone 2>/dev/null || echo MISSING)"
audit "PREFLIGHT" "brew=$(command -v brew 2>/dev/null || echo MISSING)"
audit "PREFLIGHT" "zstd=$(command -v zstd 2>/dev/null || echo MISSING)"

# ---------------------------------------------------------------------------
# Homebrew + rclone + zstd: install if missing.
#
# rclone is treated as required: encrypted cloud backup is the headline
# feature and the local-only mode is only a fallback for users who
# explicitly opt out at the prompt below. zstd is strongly preferred
# (small + fast bundles) but gzip is a fine fallback.
# ---------------------------------------------------------------------------

ensure_brew() {
    if command -v brew >/dev/null; then
        ok "Homebrew present"
        return 0
    fi
    warn "Homebrew not installed - it's the easiest way to install rclone + zstd."
    if ! prompt_yn "Install Homebrew now? (runs the official Homebrew installer)" y; then
        return 1
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        dry_say "would run the official Homebrew installer (curl | bash)"
        dry_say "would add brew to PATH for the rest of this run"
        return 0   # pretend it worked so downstream dry-run logic continues
    fi
    info "Launching the Homebrew installer (you may be asked for your password)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || { fail "Homebrew install failed."; return 1; }
    # Add brew to PATH for the rest of this run (Apple Silicon vs Intel)
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    command -v brew >/dev/null && ok "Homebrew installed" || return 1
}

WANT_LOCAL_ONLY=0
if command -v rclone >/dev/null; then
    ok "rclone present"
else
    info "rclone is required for cloud backup. The installer will install it"
    info "for you (via Homebrew) unless you specifically opt out below."
    info "Opting out gives you local-only versioning - you can add cloud sync"
    info "later by re-running this installer."
    if prompt_yn "Install rclone automatically?" y; then
        if ensure_brew; then
            if [[ ${DRY_RUN} -eq 1 ]]; then
                dry_say "would run: brew install rclone"
            else
                info "Installing rclone via Homebrew (this can take a minute)..."
                if brew install rclone 2>&1 | sed 's/^/    /'; then
                    ok "rclone installed"
                else
                    fail "brew install rclone failed - falling back to local-only mode."
                    WANT_LOCAL_ONLY=1
                fi
            fi
        else
            warn "Could not install Homebrew, so rclone install was skipped."
            info "To enable cloud sync later: install Homebrew, then 'brew install rclone'"
            info "                           and run bin/lives-sync-setup.sh"
            WANT_LOCAL_ONLY=1
        fi
    else
        info "Opted out. Local-only mode active; cloud sync stays disabled."
        WANT_LOCAL_ONLY=1
    fi
fi

if command -v zstd >/dev/null; then
    ok "zstd present"
else
    info "zstd missing (used for compact project bundles; gzip is a fallback)."
    if command -v brew >/dev/null && prompt_yn "Install zstd now?" y; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            dry_say "would run: brew install zstd"
        else
            brew install zstd 2>&1 | sed 's/^/    /' && ok "zstd installed" \
                || warn "zstd install failed - bundles will fall back to gzip."
        fi
    fi
fi

command -v bats >/dev/null && ok "bats-core present (dev dependency)" \
    || info "bats-core not installed (only needed if you run the test suite)"

# ---------------------------------------------------------------------------
# Load defaults: existing config > preset > standard Ableton
# ---------------------------------------------------------------------------
DEF_INTERNAL="${HOME}/Music/Ableton"
DEF_LIBRARY="${HOME}/Music/Ableton/User Library"
DEF_USB=""
DEF_CAP="20"
DEF_FLOOR="10"

# Standard Ableton folder existence check - friendlier message if missing.
if [[ ! -d "${DEF_INTERNAL}" ]]; then
    info "Standard Ableton folder ${DEF_INTERNAL} not found - that's fine, you'll choose one below."
fi

# Layer in preset (local-only file, gitignored from public release)
if [[ -f "${PRESET_FILE}" ]]; then
    info "Local preset detected at presets/local.preset - using its values as defaults"
    source "${PRESET_FILE}"
    DEF_INTERNAL="${LIVES_INTERNAL_PATH:-${DEF_INTERNAL}}"
    DEF_LIBRARY="${LIVES_LIBRARY_PATH:-${DEF_INTERNAL}/User Library}"
    DEF_USB="${LIVES_USB_PATH:-${DEF_USB}}"
    DEF_CAP="${LIVES_REMOTE_CAP_GB:-${DEF_CAP}}"
    DEF_FLOOR="${LIVES_FREE_FLOOR_GB:-${DEF_FLOOR}}"
fi

# Existing config wins over preset (re-install case)
if [[ -f "${CONFIG_FILE}" ]]; then
    info "Existing config at ${CONFIG_FILE} - its values will be the defaults"
    source "${CONFIG_FILE}"
    DEF_INTERNAL="${LIVES_INTERNAL_PATH:-${DEF_INTERNAL}}"
    DEF_LIBRARY="${LIVES_LIBRARY_PATH:-${DEF_INTERNAL}/User Library}"
    DEF_USB="${LIVES_USB_PATH:-${DEF_USB}}"
    DEF_CAP="${LIVES_REMOTE_CAP_GB:-${DEF_CAP}}"
    DEF_FLOOR="${LIVES_FREE_FLOOR_GB:-${DEF_FLOOR}}"
fi
# DEF_LIBRARY follows the chosen INTERNAL by default; we recompute it
# right after the INTERNAL prompt below in case the user changed paths.

# ---------------------------------------------------------------------------
# Folders to monitor
# ---------------------------------------------------------------------------
step "Folders to monitor"
hr
# Validate a chosen folder path. Distinguishes three cases:
#   1. Path exists                          -> OK
#   2. Path is on an external volume that
#      isn't currently mounted              -> warn, accept (watcher handles
#                                              missing paths gracefully)
#   3. Path doesn't exist anywhere else     -> offer to create (real install
#                                              only; dry-run just announces)
validate_path() {
    local p="$1" label="$2"
    [[ -d "${p}" ]] && { ok "${label} exists"; return 0; }

    # External volume detection: anything under /Volumes/<MOUNT>/...
    # macOS will only let you create folders inside an already-mounted volume.
    if [[ "${p}" == /Volumes/* ]]; then
        local mount="/Volumes/${${p#/Volumes/}%%/*}"
        if [[ ! -d "${mount}" ]]; then
            warn "${label} is on an external drive that isn't plugged in right now."
            info "  Volume:   ${mount}  (not mounted)"
            info "  Ableton Lives will start watching it the moment you plug it in and reload"
            info "  the watcher: launchctl unload && load ~/Library/LaunchAgents/com.mord58562.ableton-lives.watch.plist"
            return 0
        fi
        # Volume mounted but subfolder missing - rare; offer to create.
    fi

    warn "${label} does not exist: ${p}"
    if prompt_yn "  Create it now?" y; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            dry_say "would mkdir -p ${p}"
        else
            if mkdir -p "${p}" 2>/dev/null; then
                ok "Created ${p}"
            else
                fail "Could not create ${p} (permission denied?). Path will still be saved; create it manually before the watcher fires."
            fi
        fi
    fi
}

info "${C_DIM}Tip: drag the folder from Finder into this window to autofill.${C_RESET}"
prompt INTERNAL "Path to your Ableton projects folder" "${DEF_INTERNAL}"
validate_path "${INTERNAL}" "Projects folder"

# Recompute the User Library default in case INTERNAL changed
[[ "${DEF_LIBRARY}" == */User\ Library ]] && DEF_LIBRARY="${INTERNAL}/User Library"

printf '\n'
info "Your Ableton User Library (presets, samples, devices, templates)"
info "is recorded so future bundle snapshots can include it. It is NOT"
info "actively versioned - that's only useful for project .als files."
info "If you've moved your library elsewhere via Live > Preferences > Library,"
info "point this at the new location."
prompt LIBRARY "Path to your Ableton User Library" "${DEF_LIBRARY}"
[[ -n "${LIBRARY}" ]] && validate_path "${LIBRARY}" "User Library"

printf '\n'
info "You can also monitor an external drive (USB / SSD / network share)."
info "Leave blank if you only work from the internal drive."
prompt USB "Optional external folder to also monitor" "${DEF_USB}"
[[ -n "${USB}" ]] && validate_path "${USB}" "External path"

# ---------------------------------------------------------------------------
# Storage caps
# ---------------------------------------------------------------------------
step "Storage caps"
hr
info "Two safety limits. Both are conservative defaults you can change later"
info "with ${C_BOLD}bin/lives-config.sh set <KEY> <number>${C_RESET}."
info ""
info "  ${C_BOLD}1. Ableton Lives size limit${C_RESET} - if your version store ever grows beyond this,"
info "     sync stops uploading until it shrinks (via the daily pruner)."
info "     Stops a runaway watcher from ever filling your drive."
info ""
info "  ${C_BOLD}2. Drive free-space floor${C_RESET} - if your Google Drive's free space"
info "     ever drops below this, sync pauses. Protects your other Drive"
info "     files from being squeezed by Ableton Lives."
info ""
prompt CAP "Maximum size for Ableton Lives' version store (GB)" "${DEF_CAP}"
prompt FLOOR "Pause sync if Google Drive free space drops below (GB)" "${DEF_FLOOR}"

# ---------------------------------------------------------------------------
# Cloud sync intent
# ---------------------------------------------------------------------------
step "Cloud sync"
hr

WANT_SYNC=0
WANT_ENCRYPT=1
if [[ ${WANT_LOCAL_ONLY} -eq 1 ]] || ! command -v rclone >/dev/null; then
    info "Skipping cloud sync (rclone not available)."
else
    info "Ableton Lives can mirror your version store to Google Drive every night."
    info ""
    if prompt_yn "Enable cloud sync?" y; then
        WANT_SYNC=1
        printf '\n'
        info "${C_BOLD}Two ways to back up:${C_RESET}"
        info ""
        info "  ${C_BOLD}1) Encrypted${C_RESET} (recommended)"
        info "     ✓ Google can read nothing - no filenames, no project names, no audio"
        info "     ✓ Files in Drive look like opaque blobs"
        info "     ✗ Requires two passwords; lose them and the cloud copy is unrecoverable"
        info "     ✗ Cannot browse or download from drive.google.com (must use rclone)"
        info ""
        info "  ${C_BOLD}2) Unencrypted${C_RESET}"
        info "     ✓ Files are visible/downloadable from drive.google.com"
        info "     ✓ Easy to share specific versions with collaborators via Drive links"
        info "     ✓ No password to manage or lose"
        info "     ✗ Google has full access to your project files"
        info ""
        if prompt_yn "Encrypt the backup so Google can't read it?" y; then
            WANT_ENCRYPT=1
            info "Encrypted mode selected. You'll set passwords during sync setup."
        else
            WANT_ENCRYPT=0
            warn "Unencrypted mode selected. Anyone with access to your Google"
            warn "account (including Google staff under court order) can read your files."
            if ! prompt_yn "Are you sure?" y; then
                WANT_ENCRYPT=1
                info "Switched back to encrypted."
            fi
        fi
        printf '\n'
        info "Setup is interactive: you'll authorize Google in your browser"
        info "(you choose which Google account to use)."
        if [[ ${WANT_ENCRYPT} -eq 1 ]]; then
            info "You'll then enter two strong passwords."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary + confirm
# ---------------------------------------------------------------------------
step "Review"
hr
printf '  %sSource:%s         %s\n' "${C_BOLD}" "${C_RESET}" "${LIVES_HOME}"
printf '  %sProjects:%s       %s\n' "${C_BOLD}" "${C_RESET}" "${INTERNAL}"
printf '  %sUser Library:%s   %s\n' "${C_BOLD}" "${C_RESET}" "${LIBRARY:-(none)}"
printf '  %sExternal:%s       %s\n' "${C_BOLD}" "${C_RESET}" "${USB:-(none)}"
printf '  %sAbleton Lives size cap:%s   %s GB\n' "${C_BOLD}" "${C_RESET}" "${CAP}"
printf '  %sDrive floor:%s    %s GB free\n' "${C_BOLD}" "${C_RESET}" "${FLOOR}"
if [[ ${WANT_SYNC} -eq 1 ]]; then
    if [[ ${WANT_ENCRYPT} -eq 1 ]]; then
        cloud_label="yes, encrypted (set up after install)"
    else
        cloud_label="yes, unencrypted (set up after install)"
    fi
else
    cloud_label="no (local-only)"
fi
printf '  %sCloud sync:%s     %s\n' "${C_BOLD}" "${C_RESET}" "${cloud_label}"
printf '  %sConfig file:%s    %s\n' "${C_BOLD}" "${C_RESET}" "${CONFIG_FILE}"
printf '\n'
prompt_yn "Proceed with install?" y || { info "Aborted. No changes made."; exit 0; }

# ---------------------------------------------------------------------------
# Write config
# ---------------------------------------------------------------------------
step "Writing configuration"
config_body=$(cat <<EOF
# Ableton Lives configuration - written by install.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Edit by hand, or use: bin/lives-config.sh set KEY VALUE
# Path values must be quoted (some Ableton folders contain spaces, e.g.
# "User Library"); without quotes the next source-of-this-file would fail.
LIVES_INTERNAL_PATH="${INTERNAL}"
LIVES_VERSIONS_DIR="${INTERNAL}/_versions"
LIVES_LIBRARY_PATH="${LIBRARY}"
LIVES_USB_PATH="${USB}"
LIVES_REMOTE_CAP_GB=${CAP}
LIVES_FREE_FLOOR_GB=${FLOOR}
LIVES_ENCRYPT_BACKUP=${WANT_ENCRYPT}
EOF
)
if [[ ${DRY_RUN} -eq 1 ]]; then
    dry_say "would mkdir -p ${CONFIG_DIR}"
    line_count=$(printf '%s\n' "${config_body}" | wc -l | tr -d ' ')
    dry_say "would write ${CONFIG_FILE} (${line_count} lines)"
    audit "WOULD_WRITE" "${CONFIG_FILE}"
    printf '%s---%s\n%s\n%s---%s\n' "${C_DIM}" "${C_RESET}" "${config_body}" "${C_DIM}" "${C_RESET}"
else
    mkdir -p "${CONFIG_DIR}"
    printf '%s\n' "${config_body}" > "${CONFIG_FILE}"
    ok "Wrote ${CONFIG_FILE}"
fi

# ---------------------------------------------------------------------------
# chmod scripts
# ---------------------------------------------------------------------------
step "Preparing scripts"
if [[ ${DRY_RUN} -eq 1 ]]; then
    dry_say "would chmod +x ${BIN_DIR}/*.sh"
else
    chmod +x "${BIN_DIR}"/*.sh
    ok "Marked all bin/*.sh executable"
fi

# ---------------------------------------------------------------------------
# Render plist templates and install to LaunchAgents
# ---------------------------------------------------------------------------
step "Installing launch agents"
LOG_PATH="${HOME}/Library/Logs/ableton-lives.log"
if [[ ${DRY_RUN} -eq 1 ]]; then
    dry_say "would mkdir -p ${LAUNCH_AGENTS}"
    dry_say "would mkdir -p $(dirname "${LOG_PATH}") and touch ${LOG_PATH}"
else
    mkdir -p "${LAUNCH_AGENTS}"
    mkdir -p "$(dirname "${LOG_PATH}")"
    touch "${LOG_PATH}"
fi

render_template() {
    local name="$1"
    local src="${LAUNCHD_DIR}/${name}.plist.template"
    local dst="${LAUNCH_AGENTS}/${name}.plist"
    [[ -f "${src}" ]] || { warn "Missing template: ${src}"; return 1; }

    local lr_block=""
    if [[ -d "${INTERNAL}/Live Recordings" ]]; then
        lr_block="        <string>${INTERNAL}/Live Recordings</string>"
    fi
    local usb_block=""
    if [[ -n "${USB}" ]]; then
        usb_block="        <string>${USB}</string>"
    fi

    if [[ ${DRY_RUN} -eq 1 ]]; then
        dry_say "would render ${src} -> ${dst}"
        audit "WOULD_WRITE" "${dst} (template-rendered from ${src})"
        # Show the substitutions that would happen
        audit "WOULD_WRITE" "  LIVES_HOME=${LIVES_HOME}"
        audit "WOULD_WRITE" "  LIVES_INTERNAL_PATH=${INTERNAL}"
        audit "WOULD_WRITE" "  LIVES_LOG=${LOG_PATH}"
        [[ -n "${lr_block}" ]] && audit "WOULD_WRITE" "  +LiveRecordings WatchPath"
        [[ -n "${usb_block}" ]] && audit "WOULD_WRITE" "  +USB WatchPath: ${USB}"
    else
        sed -e "s|{{LIVES_HOME}}|${LIVES_HOME}|g" \
            -e "s|{{LIVES_INTERNAL_PATH}}|${INTERNAL}|g" \
            -e "s|{{LIVES_LOG}}|${LOG_PATH}|g" \
            -e "s|{{WATCHPATH_INTERNAL_LIVE_RECORDINGS}}|${lr_block}|g" \
            -e "s|{{WATCHPATH_USB}}|${usb_block}|g" \
            "${src}" > "${dst}"
        ok "Rendered ${name}.plist"
    fi
}

for name in "${PLIST_NAMES[@]}"; do
    render_template "${name}"
done

if [[ ${DRY_RUN} -eq 1 ]]; then
    for name in "${PLIST_NAMES[@]}"; do
        dry_say "would: launchctl unload ${LAUNCH_AGENTS}/${name}.plist (clean re-install)"
        audit "WOULD_LOAD" "unload ${name}"
    done
    for name in com.mord58562.ableton-lives.watch com.mord58562.ableton-lives.prune com.mord58562.ableton-lives.verify com.mord58562.ableton-lives.crash com.mord58562.ableton-lives.menubar; do
        dry_say "would: launchctl load ${LAUNCH_AGENTS}/${name}.plist"
        audit "WOULD_LOAD" "load ${name}"
    done
    if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qx "${LIVES_SYNC_REMOTE:-lives-crypt}:"; then
        dry_say "would: launchctl load ${LAUNCH_AGENTS}/com.mord58562.ableton-lives.sync.plist (sync remote already configured)"
        audit "WOULD_LOAD" "load com.mord58562.ableton-lives.sync"
    else
        dry_say "would NOT load com.mord58562.ableton-lives.sync.plist yet (sync remote not configured; lives-sync-setup.sh handles it)"
    fi
else
    for name in "${PLIST_NAMES[@]}"; do
        launchctl unload "${LAUNCH_AGENTS}/${name}.plist" 2>/dev/null || true
    done
    launchctl load "${LAUNCH_AGENTS}/com.mord58562.ableton-lives.watch.plist"
    launchctl load "${LAUNCH_AGENTS}/com.mord58562.ableton-lives.prune.plist"
    launchctl load "${LAUNCH_AGENTS}/com.mord58562.ableton-lives.verify.plist"
    launchctl load "${LAUNCH_AGENTS}/com.mord58562.ableton-lives.crash.plist"
    ok "Loaded watch, prune, verify, crash agents"
    if [[ -d "${LIVES_HOME}/swift/AbletonLives.app" ]]; then
        launchctl load "${LAUNCH_AGENTS}/com.mord58562.ableton-lives.menubar.plist"
        ok "Loaded menubar agent"
    else
        info "Menubar app not built; skipping its agent."
    fi
    if rclone listremotes 2>/dev/null | grep -qx 'lives-crypt:'; then
        launchctl load "${LAUNCH_AGENTS}/com.mord58562.ableton-lives.sync.plist"
        ok "Loaded sync agent (rclone crypt remote already configured)"
    fi
fi

# ---------------------------------------------------------------------------
# Quick Action workflow
# ---------------------------------------------------------------------------
step "Installing Finder Quick Action"
if [[ ${DRY_RUN} -eq 1 ]]; then
    dry_say "would mkdir -p ${SERVICES_DIR}"
    dry_say "would cp -R ${QUICKACTION_DIR}/${WORKFLOW} -> ${SERVICES_DIR}/${WORKFLOW}"
    audit "WOULD_WRITE" "${SERVICES_DIR}/${WORKFLOW} (Automator workflow bundle)"
else
    mkdir -p "${SERVICES_DIR}"
    cp -R "${QUICKACTION_DIR}/${WORKFLOW}" "${SERVICES_DIR}/${WORKFLOW}"
    ok "Installed: System Settings -> Privacy & Security -> Extensions -> Finder"
fi

# ---------------------------------------------------------------------------
# Seed existing Ableton Backup/ folders (if the script exists)
# ---------------------------------------------------------------------------
if [[ -x "${BIN_DIR}/lives-import-existing.sh" ]]; then
    step "Importing any existing Ableton Backup/ files"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        dry_say "would run: ${BIN_DIR}/lives-import-existing.sh"
    else
        "${BIN_DIR}/lives-import-existing.sh" 2>&1 | sed 's/^/  /' || warn "Import partial - see log"
    fi
fi

# ---------------------------------------------------------------------------
# Menu bar plugin
# ---------------------------------------------------------------------------
step "Menu bar app"
# Native menu bar app: small Swift binary + .app bundle launched by
# launchd. No SwiftBar/xbar dependency. Build needs Xcode CLI tools.
APP_PATH="${LIVES_HOME}/swift/AbletonLives.app"

if ! command -v swiftc >/dev/null 2>&1; then
    warn "swiftc not found - menu bar app will be skipped."
    info "To enable later:"
    info "  xcode-select --install      # one-time, ~few minutes"
    info "  zsh swift/build.sh          # builds the app"
    info "  zsh scripts/install.sh      # re-run to load the agent"
elif [[ -d "${APP_PATH}" ]] && [[ "${1:-}" != "--rebuild-app" ]]; then
    ok "Menu bar app already built at swift/AbletonLives.app"
else
    if [[ ${DRY_RUN} -eq 1 ]]; then
        dry_say "would run: zsh ${LIVES_HOME}/swift/build.sh"
        audit "WOULD" "build menubar app"
    else
        info "Building menu bar app (one-time, ~10 seconds)..."
        if zsh "${LIVES_HOME}/swift/build.sh" 2>&1 | sed 's/^/    /'; then
            ok "Built ${APP_PATH}"
        else
            warn "Menu bar app build failed - the rest of Ableton Lives is unaffected."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Optional: launch cloud sync setup now
# ---------------------------------------------------------------------------
if [[ ${WANT_SYNC} -eq 1 ]] && command -v rclone >/dev/null; then
    step "Cloud sync setup"
    if [[ ${INTERACTIVE} -eq 0 ]]; then
        # Non-interactive run can't drive the OAuth browser flow or
        # password prompts. Always defer to the user.
        info "Sync setup needs an interactive shell (OAuth + passwords)."
        info "Run this when ready:"
        info "  ${C_BOLD}zsh ${BIN_DIR}/lives-sync-setup.sh${C_RESET}"
    elif prompt_yn "Run Google Drive setup now?" y; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            dry_say "would run: ${BIN_DIR}/lives-sync-setup.sh"
            dry_say "  (interactive: opens browser for Google OAuth account picker)"
            [[ ${WANT_ENCRYPT} -eq 1 ]] && \
                dry_say "  (interactive: prompts for two crypt passwords)"
        else
            "${BIN_DIR}/lives-sync-setup.sh" || warn "Setup did not complete - re-run any time: bin/lives-sync-setup.sh"
        fi
    else
        info "When ready, run: ${C_BOLD}bin/lives-sync-setup.sh${C_RESET}"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
hr
if [[ ${DRY_RUN} -eq 1 ]]; then
    audit "STATE" "dry-run finished cleanly - no files written, no agents loaded"
    printf '\n%s%sDry-run complete.%s No changes were made to your system.\n\n' \
        "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
    printf '  Audit log: %s%s%s\n' "${C_BOLD}" "${AUDIT_LOG}" "${C_RESET}"
    printf '  Lines:     %d\n' "$(wc -l < "${AUDIT_LOG}" | tr -d ' ')"
    printf '\n'
    printf 'Open it to review every prompt + every action that would have run:\n'
    printf '  %sopen %s%s\n' "${C_BOLD}" "${AUDIT_LOG}" "${C_RESET}"
    printf '\nTo do the real install, re-run without --dry-run.\n\n'
else
    printf '\n%s%sInstall complete.%s\n\n' "${C_BOLD}" "${C_GREEN}" "${C_RESET}"
    printf '  Versions store:  %s/_versions\n' "${INTERNAL}"
    printf '  Log file:        %s\n' "${LOG_PATH}"
    printf '  Config:          %s\n' "${CONFIG_FILE}"
    printf '\n'
    printf 'Useful commands:\n'
    printf '  %sbin/lives-config.sh%s              show or change settings\n' "${C_BOLD}" "${C_RESET}"
    printf '  %sbin/lives-sync.sh%s                run a sync now\n' "${C_BOLD}" "${C_RESET}"
    printf '  %sbin/lives-bundle.sh snapshot ...%s archive a whole project folder\n' "${C_BOLD}" "${C_RESET}"
    printf '  %sbin/lives-cloud-restore.sh%s       restore from Drive after disk failure\n' "${C_BOLD}" "${C_RESET}"
    printf '  %sbin/lives-tag.sh add ...%s         pin a version so it survives forever\n' "${C_BOLD}" "${C_RESET}"
    printf '\nRight-click any %s.als%s file in Finder to restore a previous version.\n' "${C_BOLD}" "${C_RESET}"
    printf '\n'
fi
