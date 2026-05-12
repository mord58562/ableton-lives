#!/usr/bin/env bats
# test_prune.bats - Tests for atm-prune.sh tiered retention policy.
#
# Zones:
#   Zone 0  < 24h         keep all
#   Zone 1  24h-30d       keep latest per HOUR per .als name
#   Zone 2  30d-180d      keep latest per DAY  per .als name
#   Zone 3  180d-365d     keep latest per WEEK per .als name
#   Zone 4  > 365d        delete

FIXTURE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures/fake.als"
PRUNE_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/atm-prune.sh"

setup() {
    TEST_DIR="$(mktemp -d /tmp/atm-test-prune.XXXXXX)"
    export TEST_DIR
    export ATM_CONFIG=/dev/null
    export ATM_VERSIONS_DIR="${TEST_DIR}/_versions"
    export ATM_LOG="${TEST_DIR}/atm.log"
    export ATM_SUMMARY="${TEST_DIR}/.atm-summary"
    # Suppress real macOS notifications during tests
    export ATM_NO_NOTIFY=1
    mkdir -p "${ATM_VERSIONS_DIR}/myproject"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Helper: create a versioned .als file with mtime N days in the past.
# $1=name, $2=days_ago, $3=hour (00-23), $4=minute (00-59)
make_version() {
    local name="$1" days_ago="$2" hh="$3" mm="$4"
    local date_str
    date_str=$(date -v-${days_ago}d '+%Y%m%d' 2>/dev/null || date -d "-${days_ago} days" '+%Y%m%d')
    local ts="${date_str}-${hh}${mm}00"
    local f="${ATM_VERSIONS_DIR}/myproject/${name}-${ts}.als"
    cp "${FIXTURE}" "${f}"
    touch -m -t "${date_str}${hh}${mm}.00" "${f}" 2>/dev/null \
        || touch -m -t "$(date -v-${days_ago}d "+%Y%m%d${hh}${mm}.00" 2>/dev/null)" "${f}" 2>/dev/null \
        || true
    echo "${f}"
}

@test "zone0_keeps_all_under_24h - 5 saves in last 24h all survive" {
    # Use small days_ago so files are in last 24h. days_ago=0 with various
    # hour values: BSD date can't go negative on hours, so use 0d + early hour.
    for hh in 00 06 12 18; do
        make_version "fresh_track" 0 "${hh}" "30"
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]
    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'fresh_track-*.als' | wc -l | tr -d ' ')
    [ "${after}" -eq 4 ]
}

@test "zone1_collapses_to_one_per_hour - 12 saves in same hour 5d ago -> 1" {
    for mm in 00 05 10 15 20 25 30 35 40 45 50 55; do
        make_version "burst_track" 5 "14" "${mm}"
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]
    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'burst_track-*.als' | wc -l | tr -d ' ')
    [ "${after}" -eq 1 ]
}

@test "zone1_keeps_distinct_hours - 5 saves in different hours 5d ago -> 5" {
    for hh in 09 11 13 15 17; do
        make_version "spread_track" 5 "${hh}" "00"
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]
    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'spread_track-*.als' | wc -l | tr -d ' ')
    [ "${after}" -eq 5 ]
}

@test "zone2_keeps_one_per_day - 5 saves on each of 3 days (35-90d) -> 3" {
    for day in 35 60 90; do
        for hh in 09 11 13 15 17; do
            make_version "chord_prog" "${day}" "${hh}" "00"
        done
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]
    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'chord_prog-*.als' | wc -l | tr -d ' ')
    [ "${after}" -eq 3 ]
}

@test "zone3_keeps_one_per_week - 5 saves on the same day (~200d) -> 1" {
    # Same calendar day = always same ISO week, regardless of when test runs.
    # A 7-day span would straddle a week boundary roughly 6/7 of the time.
    for hh in 09 11 13 15 17; do
        make_version "old_track" 200 "${hh}" "00"
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]
    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'old_track-*.als' | wc -l | tr -d ' ')
    [ "${after}" -eq 1 ]
}

@test "zone3_keeps_one_per_week_across_consecutive_weeks - 14 daily saves -> at most 3" {
    # Spans roughly 2 ISO weeks (could be 2 or 3 depending on alignment).
    # Bound the assertion rather than chasing calendar arithmetic.
    for day in 200 201 202 203 204 205 206 207 208 209 210 211 212 213; do
        make_version "weekly_track" "${day}" "12" "00"
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]
    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'weekly_track-*.als' | wc -l | tr -d ' ')
    [ "${after}" -ge 2 ] && [ "${after}" -le 3 ]
}

@test "zone4_deletes_over_365d - 3 files at 400d are removed entirely" {
    for hh in 09 12 15; do
        make_version "ancient_track" 400 "${hh}" "00"
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]
    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'ancient_track-*.als' | wc -l | tr -d ' ')
    [ "${after}" -eq 0 ]
}

@test "logs_each_deletion - deleted filenames appear in log" {
    # 3 saves in the same hour 10d ago -> 2 should be deleted
    for mm in 00 20 40; do
        make_version "logged_track" 10 "14" "${mm}"
    done

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]

    run grep "logged_track" "${ATM_LOG}"
    [ "${status}" -eq 0 ]

    local delete_count
    delete_count=$(grep -c "\[DELETE\]" "${ATM_LOG}" || echo 0)
    [ "${delete_count}" -ge 2 ]
}

@test "mixed_zones - one file per zone, all kept; bursts collapsed" {
    # Zone 0: keep all 2
    make_version "mix" 0 "10" "00"
    make_version "mix" 0 "14" "00"
    # Zone 1: 3 in same hour -> 1
    make_version "mix" 10 "11" "00"
    make_version "mix" 10 "11" "30"
    make_version "mix" 10 "11" "45"
    # Zone 2: 2 same day -> 1
    make_version "mix" 60 "09" "00"
    make_version "mix" 60 "20" "00"
    # Zone 3: 2 same week -> 1
    make_version "mix" 200 "12" "00"
    make_version "mix" 201 "12" "00"
    # Zone 4: gone
    make_version "mix" 500 "12" "00"

    run zsh "${PRUNE_SCRIPT}"
    [ "${status}" -eq 0 ]

    local after
    after=$(find "${ATM_VERSIONS_DIR}" -name 'mix-*.als' | wc -l | tr -d ' ')
    # 2 (zone0) + 1 (zone1) + 1 (zone2) + 1 (zone3) + 0 (zone4) = 5
    [ "${after}" -eq 5 ]
}
