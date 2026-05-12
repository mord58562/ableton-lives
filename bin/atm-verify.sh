#!/usr/bin/env zsh
# atm-verify.sh - sample N random versions and verify gzip integrity.
#
# Catches silent disk corruption (bit-rot) before you need the file.
# Runs weekly via launchd (Sunday 04:15). Manual invocation:
#
#   atm-verify.sh           # default 20 random samples
#   atm-verify.sh 100       # check 100
#   atm-verify.sh --all     # check every .als (slow on large stores)
#
# Failures are logged AND notified (state-transition aware).

set -euo pipefail

ATM_LIB_DIR="${ATM_LIB_DIR:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${ATM_LIB_DIR}/atm-config.sh"
source "${ATM_LIB_DIR}/atm-notify.sh"

VERSIONS_DIR="${ATM_VERSIONS_DIR}"
LOG="${ATM_LOG}"
SUMMARY="${ATM_SUMMARY}"

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
done < <(find "${VERSIONS_DIR}" -name '*.als' -not -path '*/_exports/*' -not -path '*/_bundles/*' 2>/dev/null)

total=${#all[@]}
if [[ ${total} -eq 0 ]]; then
    log "no .als files in ${VERSIONS_DIR}"
    exit 0
fi

# Pick the sample
if [[ "${mode}" = "all" ]]; then
    samples=("${all[@]}")
else
    [[ ${n} -gt ${total} ]] && n=${total}
    # Shuffle via awk + sort -R (BSD has -R via gsort, fall back to perl)
    if command -v gsort >/dev/null 2>&1; then
        samples=($(printf '%s\n' "${all[@]}" | gsort -R | head -${n}))
    else
        samples=($(printf '%s\n' "${all[@]}" | perl -MList::Util=shuffle -e 'print shuffle(<>)' | head -${n}))
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
    grep -v '^ATM_VERIFY_' "${SUMMARY}" > "${tmp_sum}" 2>/dev/null || true
    {
        printf 'ATM_VERIFY_LAST_RUN=%s\n' "${now_iso}"
        printf 'ATM_VERIFY_LAST_SAMPLED=%d\n' "${#samples[@]}"
        printf 'ATM_VERIFY_LAST_FAILED=%d\n' "${fail_count}"
    } >> "${tmp_sum}"
    mv "${tmp_sum}" "${SUMMARY}"
fi

if [[ ${fail_count} -gt 0 ]]; then
    # Use a fingerprint that includes the count so going from N to N+1 fires
    atm_notify_event "verify" "error" "ATM verify: corruption detected" \
        "${fail_count} of ${#samples[@]} sampled .als files failed gzip integrity. See log."
    exit 1
else
    atm_notify_event "verify" "ok" "ATM verify: all clear" \
        "${#samples[@]} samples, no corruption detected."
    exit 0
fi
