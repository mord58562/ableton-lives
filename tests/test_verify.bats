#!/usr/bin/env bats
# test_verify.bats - regression tests for lives-verify.sh.
#
# Covers two bugs that previously made it cry "corruption detected" on a
# completely healthy backup tree:
#   1. samples=($(... | head -n)) shredded paths containing spaces into
#      fragments because zsh word-splits on default IFS. A 16-file tree
#      with space-containing paths reported "checking 54 of 16" and every
#      fragment failed gzip -t.
#   2. find -name '*.als' picked up macOS AppleDouble sidecars (._foo.als).
#      They are 4 KB resource-fork metadata, never gzip, so they always
#      failed gzip -t even though the real .als next to them was fine.

FIXTURE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures/fake.als"
VERIFY_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/lives-verify.sh"

setup() {
    TEST_DIR="$(mktemp -d /tmp/lives-test-verify.XXXXXX)"
    export TEST_DIR
    export LIVES_CONFIG=/dev/null
    export LIVES_VERSIONS_DIR="${TEST_DIR}/_versions"
    export LIVES_LOG="${TEST_DIR}/atm.log"
    export LIVES_SUMMARY="${TEST_DIR}/.ableton-lives-summary"
    # Full notify isolation: LIVES_NO_NOTIFY suppresses osascript, but the
    # audit log + state file still get written - point both into TEST_DIR.
    export LIVES_NO_NOTIFY=1
    export LIVES_NOTIFY_LOG="${TEST_DIR}/notifications.log"
    export LIVES_NOTIFY_STATE="${TEST_DIR}/.ableton-lives-notify-state"
    mkdir -p "${LIVES_VERSIONS_DIR}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Drop a gzip-valid .als at the given relative path under _versions/.
seed_als() {
    local rel="$1"
    local dst="${LIVES_VERSIONS_DIR}/${rel}"
    mkdir -p "$(dirname "${dst}")"
    cp "${FIXTURE}" "${dst}"
}

@test "paths_with_spaces_do_not_shred_into_fragments - bug #1 regression" {
    # Mirror the real layout that triggered the bug.
    seed_als "intro lessons/first beat-20260511-211042.als"
    seed_als "intro lessons/chord progression-20260511-173913.als"
    seed_als "first ever ideas Project/first real track-20260509-204251.als"

    run zsh "${VERIFY_SCRIPT}" --all
    [ "${status}" -eq 0 ]
    grep -q 'checking 3 of 3 .als files' "${LIVES_LOG}"
    grep -q 'done: 0 corrupt of 3 sampled' "${LIVES_LOG}"
    ! grep -q '\[CORRUPT\]' "${LIVES_LOG}"
}

@test "appledouble_sidecars_are_ignored - bug #2 regression" {
    # A real .als plus its AppleDouble sidecar. The sidecar is junk bytes,
    # not gzip - if it gets sampled, verify will mis-report corruption.
    seed_als "intro lessons/first beat-20260511-211042.als"
    printf 'Mac OS X        \x00\x05\x16\x07' \
        > "${LIVES_VERSIONS_DIR}/intro lessons/._first beat-20260511-211042.als"

    run zsh "${VERIFY_SCRIPT}" --all
    [ "${status}" -eq 0 ]
    grep -q 'checking 1 of 1 .als files' "${LIVES_LOG}"
    grep -q 'done: 0 corrupt of 1 sampled' "${LIVES_LOG}"
    ! grep -q '\[CORRUPT\]' "${LIVES_LOG}"
}

@test "random_sample_with_n_smaller_than_total - bug #1 in random mode" {
    # Bug #1 also fired in the random-shuffle path (lines 60/62). Seed many
    # space-containing paths and ask for a sample of 5 - none should appear
    # as fragments and none should be reported corrupt.
    for i in 1 2 3 4 5 6 7 8 9 10; do
        seed_als "intro lessons/first beat-2026051${i}-203000.als"
    done

    run zsh "${VERIFY_SCRIPT}" 5
    [ "${status}" -eq 0 ]
    grep -q 'checking 5 of 10 .als files' "${LIVES_LOG}"
    grep -q 'done: 0 corrupt of 5 sampled' "${LIVES_LOG}"
    ! grep -q '\[CORRUPT\]' "${LIVES_LOG}"
}

@test "real_corruption_is_still_detected" {
    # Sanity check the happy bug-fix didn't blunt the actual detector.
    seed_als "intro lessons/first beat-20260511-211042.als"
    printf 'not gzip at all' > "${LIVES_VERSIONS_DIR}/intro lessons/broken-20260511-211042.als"

    run zsh "${VERIFY_SCRIPT}" --all
    [ "${status}" -eq 1 ]
    grep -q 'done: 1 corrupt of 2 sampled' "${LIVES_LOG}"
    grep -q '\[CORRUPT\].*broken-20260511-211042.als' "${LIVES_LOG}"
}
