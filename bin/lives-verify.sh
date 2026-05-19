#!/usr/bin/env zsh
# lives-verify.sh - sample N random versions and verify gzip integrity.
#
# Catches silent disk corruption (bit-rot) before you need the file.
# Runs weekly via launchd (Sunday 04:15). Manual invocation:
#
#   lives-verify.sh           # default 20 random samples
#   lives-verify.sh 100       # check 100
#   lives-verify.sh --all     # check every .als (slow on large stores)
#
# Failures are logged AND notified (state-transition aware).

set -euo pipefail

LIVES_LIB_DIR="${LIVES_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${LIVES_LIB_DIR}/lives-config.sh"
source "${LIVES_LIB_DIR}/lives-notify.sh"

VERSIONS_DIR="${LIVES_VERSIONS_DIR}"
LOG="${LIVES_LOG}"
SUMMARY="${LIVES_SUMMARY}"

log() {
    printf '[%s] [VERIFY] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${LOG}" 2>/dev/null || true
}

mkdir -p "$(dirname "${LOG}")"
touch "${LOG}"

[[ ! -d "${VERSIONS_DIR}" ]] && { log "no _versions/ to verify"; exit 0; }

mode="random"
n=20
if [[ "${1:-}" = "--all" ]]; then
    mode="all"
elif [[ -n "${1:-}" ]]; then
    n="$1"
fi

# Collect all .als under _versions/ (skip _exports/ which holds audio,
# and _bundles/ which holds tar archives).
all=()
while IFS= read -r f; do
    all+=("${f}")
done < <(find "${VERSIONS_DIR}" -name '*.als' -not -name '._*' -not -path '*/_exports/*' -not -path '*/_bundles/*' 2>/dev/null)

total=${#all[@]}
if [[ ${total} -eq 0 ]]; then
    log "no .als files in ${VERSIONS_DIR}"
    exit 0
fi

# Pick the sample. Build the array via a read-loop so paths containing
# spaces (e.g. "_versions/intro lessons/first beat-...als") stay intact -
# `arr=($(cmd))` would split on default IFS and shred them into fragments.
if [[ "${mode}" = "all" ]]; then
    samples=("${all[@]}")
else
    [[ ${n} -gt ${total} ]] && n=${total}
    samples=()
    if command -v gsort >/dev/null 2>&1; then
        while IFS= read -r f; do
            samples+=("${f}")
        done < <(printf '%s\n' "${all[@]}" | gsort -R | head -n "${n}")
    else
        while IFS= read -r f; do
            samples+=("${f}")
        done < <(printf '%s\n' "${all[@]}" | perl -MList::Util=shuffle -e 'print shuffle(<>)' | head -n "${n}")
    fi
fi

log "checking ${#samples[@]} of ${total} .als files"

failed=()
for f in "${samples[@]}"; do
    if ! gzip -t "${f}" 2>/dev/null; then
        log "[CORRUPT] ${f}"
        failed+=("${f}")
    fi
done

now_iso=$(date '+%Y-%m-%dT%H:%M:%S')
fail_count=${#failed[@]}
log "done: ${fail_count} corrupt of ${#samples[@]} sampled"

# Update summary
if [[ -f "${SUMMARY}" ]]; then
    tmp_sum="${SUMMARY}.verify.tmp.$$"
    grep -v '^LIVES_VERIFY_' "${SUMMARY}" > "${tmp_sum}" 2>/dev/null || true
    {
        printf 'LIVES_VERIFY_LAST_RUN=%s\n' "${now_iso}"
        printf 'LIVES_VERIFY_LAST_SAMPLED=%d\n' "${#samples[@]}"
        printf 'LIVES_VERIFY_LAST_FAILED=%d\n' "${fail_count}"
    } >> "${tmp_sum}"
    mv "${tmp_sum}" "${SUMMARY}"
fi

if [[ ${fail_count} -gt 0 ]]; then
    # Use a fingerprint that includes the count so going from N to N+1 fires
    lives_notify_event "verify" "error" "Ableton Lives verify: corruption detected" \
        "${fail_count} of ${#samples[@]} sampled .als files failed gzip integrity. See log."
    exit 1
else
    lives_notify_event "verify" "ok" "Ableton Lives verify: all clear" \
        "${#samples[@]} samples, no corruption detected."
    exit 0
fi
