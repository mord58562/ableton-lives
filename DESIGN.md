# Ableton Time Machine - DESIGN.md
Date: 2026-05-12

---

## 1. File Layout

```
~/Downloads/ableton-time-machine/
  bin/
    atm-watch.sh          # launchd-spawned script: filter, dedup, copy, log, prune, emit summary
    atm-restore.sh        # CLI restore: list or copy one version back (called by Quick Action)
    atm-prune.sh          # retention pruner: keep-all-30d, 1-per-day-6mo, delete older
  launchd/
    com.atm.watch.plist      # file watcher (WatchPaths, KeepAlive)
    com.atm.prune.plist  # daily 04:00 pruner
  quickaction/
    Restore Ableton Version.workflow        # Automator Quick Action (Finder right-click)
  tests/
    fixtures/
      fake.als                              # minimal gzip-valid fixture for smoke + unit tests
    test_filter_mtime.bats                  # bats: mtime filter logic
    test_dedup.bats                         # bats: hash-based dedup
    test_restore_roundtrip.bats             # bats: write -> modify -> restore -> byte-equal
    test_prune.bats                         # bats: retention policy on synthetic version tree
    test_usb_absent.bats                    # bats: graceful handling when USB2 path missing
    smoke.sh                               # smoke: touch fake .als, confirm copy appears in 10s
  scripts/
    install.sh                             # load plists, cp workflow, run smoke, open log
    uninstall.sh                           # unload plists, remove workflow (leave _versions intact)
  RECON.md
  DESIGN.md
  README.md
```

Version store (on internal disk, not in this repo):
```
~/Music/Ableton/_versions/
  intro lessons/
    first beat-20260511-211042.als
    chord progression-20260511-173913.als
  first ever ideas Project/
    first real track-20260509-204251.als
```

Logs and summary:
```
~/Library/Logs/ableton-time-machine.log   # appended by atm-watch.sh; rotated weekly
~/Documents/.atm-summary                  # machine-readable summary for digest consumers
```

---

## 2. Architecture Decisions D1-D9

### D1 - Watcher plist (WatchPaths, KeepAlive, ThrottleInterval)

```xml
Label: com.atm.watch
ProgramArguments: [/bin/zsh, ~/Downloads/ableton-time-machine/bin/atm-watch.sh]
WatchPaths:
  - /Volumes/<external>/ableton
  - ~/Music/Ableton
KeepAlive: true
ThrottleInterval: 5
RunAtLoad: false
StandardOutPath: ~/Library/Logs/ableton-time-machine.log
StandardErrorPath: ~/Library/Logs/ableton-time-machine.log
```

`ThrottleInterval: 5` is launchd's minimum coalescing window. If Ableton saves twice within 5 seconds (autosave + manual save), launchd delivers one wakeup. The script compensates by scanning with a 30-second mtime window (D2) so neither save is lost. `KeepAlive: true` means launchd restarts `atm-watch.sh` on crash and on login - the script is intentionally short-lived (runs, copies, exits), so KeepAlive causes it to re-arm after each fire. That is correct behavior; the script must not loop internally.

WatchPaths fires on any filesystem event inside the path (create, modify, delete, rename). The script's mtime filter is the real gate - it ignores events on non-.als files.

### D2 - .als filtering by mtime + hash dedup

launchd passes no event metadata. The script scans both watched directories for `*.als` files with `mtime` within the last 30 seconds (chosen to be 6x the ThrottleInterval, providing coverage even if launchd delays a fire). For each candidate file, it computes a SHA-256 of the file content. A state file at `~/.atm-seen-hashes` records hashes already copied this session (cleared on each new calendar day). If the hash is already recorded, the file is skipped. If new, the script copies it and records the hash.

The 30-second window is intentionally generous. False positives (copying a file that hasn't changed from the user's perspective but has a new mtime from Ableton's write pattern) are cheap - .als files are under 500 KB and storage is abundant. False negatives (missing a save) are expensive.

State file format: one `<hash> <YYYYMMDD>` per line. On script entry, lines with a date older than today are dropped (in-memory filter; file is rewritten only if lines are pruned). This prevents unbounded growth without requiring a separate cleanup job.

### D3 - Beyond-Ableton backup: sets/ is a sister project

ATM does .als versioning only. The sets/ directory (20.3 GB, 57 irreplaceable WAV recordings) is out of scope here. Reasons: different cadence (recordings happen occasionally, not on every Ableton save), different copy strategy (rsync mirror, not timestamped versions), different size budget (20 GB vs <2 GB for .als versions). A sister project - provisionally named "usb-mirror" - handles sets/ via a one-time rsync to internal disk plus an incremental watcher. Its recommended layout is shown in Section 8.

Keeping the scopes separate means each project has a single, clear invariant. ATM's invariant: "every .als save is in _versions/ within 30 seconds, with retention enforced." Mixing in 20 GB WAV mirroring would blur that invariant and complicate the prune logic.

### D4 - Retention pruning runs daily at 04:00

A second launchd plist - `com.atm.prune.plist` - fires `atm-prune.sh` at 04:00 daily (StartCalendarInterval: Hour=4, Minute=0). The pruner does not piggyback on saves because (a) prune is I/O-heavy and should not slow the save-time copy path, and (b) 04:00 is when Ableton is not running and the machine is idle.

Retention policy applied by `atm-prune.sh`:
- Files with mtime within the last 30 days: keep all.
- Files with mtime 30-180 days ago: keep the latest version per calendar day per .als name. "Latest" = lexicographic max of timestamp in filename, which equals chronological latest given the `YYYYMMDD-HHMMSS` format.
- Files with mtime older than 180 days: delete.

The pruner logs every deletion to the same log file.

### D5 - Restore UX via Finder Quick Action

The Automator workflow lives at `quickaction/Restore Ableton Version.workflow` in this repo and is installed by `install.sh` to `~/Library/Services/`. It appears in Finder's right-click menu as "Restore Ableton Version" when one or more `.als` files are selected.

The workflow calls a Run Shell Script action that:
1. Takes the selected .als file path from `$1`.
2. Derives the project directory name (parent folder name of the selected file).
3. Calls `atm-restore.sh --list "<project-name>"` to get the sorted list of available timestamps.
4. Passes that list to an AppleScript `choose from list` dialog.
5. Calls `atm-restore.sh --restore "<project-name>" "<chosen-timestamp>" "<destination-path>"` to copy the version back.

`atm-restore.sh --restore` writes to a `.als.bak` file alongside the original before overwriting, so a single undo-level is always available without ATM infrastructure.

AppleScript pseudo-flow:
```
set versions to paragraphs of (shell script "atm-restore.sh --list ...")
set chosen to choose from list versions with prompt "Select version to restore:"
if chosen is false then return   -- user cancelled
shell script "atm-restore.sh --restore ... " & quoted form of item 1 of chosen
display notification "Restored: " & item 1 of chosen
```

The workflow file is binary (Automator bundle). During `install.sh`, the script copies it with `cp -R`. If the Services folder does not exist it is created. The Finder picks up new services automatically on macOS 12+; no killall Finder is required.

### D6 - USB2-unmounted handling

Tested behavior of launchd WatchPaths on a path that does not exist at load time: launchd loads the plist without error and silently skips the missing path. It does not re-arm when the volume later mounts - the watch is established at load time only. This means if USB2 is mounted after login, new saves to `/Volumes/<external>/ableton/` will not be detected until the plist is reloaded.

Mitigation: `install.sh` also installs a lightweight DiskArbitration hook as a second launchd plist that fires on volume mount events. On mount, it checks whether the newly mounted volume matches `<external drive>`; if so, it runs `launchctl unload` then `launchctl load` on the ATM plist to re-arm WatchPaths. This hook is a separate plist with `LaunchOnlyOnce: false` and a mount-event trigger (via a small shell script polling `diskutil list` on mount events, or alternatively via `diskarbitrationd` notification).

Simpler fallback if the DiskArbitration hook adds complexity: the watcher script itself checks at the top whether the USB2 path exists. If not, it logs "USB2 not mounted - skipping USB2 scan" and continues with the internal path only. This handles the most common case (USB2 absent entirely) without the re-arm complexity. The re-arm is only needed when USB2 mounts mid-session and the user wants new saves picked up immediately without reloading the plist manually.

Default recommendation: implement the script-level check first (low complexity, handles absent-USB2 gracefully). Defer the DiskArbitration re-arm to a follow-up.

### D7 - Project name disambiguation

Version paths use the project folder name only: `_versions/<project-name>/<basename>-<YYYYMMDD-HHMMSS>.als`. No drive identifier or path hash is included.

Justification: current project names are unique across both locations ("intro lessons", "first ever ideas Project"). A path hash would make the _versions/ tree unreadable in Finder. If a name collision ever occurs (same project name on USB2 and internal disk), the later-saved version overwrites the earlier-saved version for the same timestamp bucket - this is acceptable given the collision is unlikely and the 30-second dedup window means they'd need to be modified at the exact same second to actually collide. The assumption is documented here so future maintainers can revisit if the project set grows.

If name collision becomes real: the mitigation is to prefix with a single letter for the source (`u-` for USB2, `i-` for internal). That is a one-line change to `atm-watch.sh`.

### D8 - Log rotation

`~/Library/Logs/ableton-time-machine.log` is appended by `atm-watch.sh` and `atm-prune.sh`. Rotation is handled by a weekly launchd timer (added to the prune plist as a secondary StartCalendarInterval) that runs `newsyslog`-style rotation in bash: if the log exceeds 5 MB or is older than 7 days, move it to `ableton-time-machine.log.1` (overwriting any prior `.log.1`) and start a fresh log. No `logrotate` dependency - bash `stat` gives file size; `find -mtime +7` gives age. The rotation runs at 04:05 daily (5 minutes after the pruner) so log and prune output from the same night land in the same file before rotation.

### D9 - Digest summary for downstream consumers

After every successful version copy, `atm-watch.sh` updates `~/Documents/.atm-summary` with:

```
ATM_LAST_UPDATED=2026-05-12T04:23:11
ATM_VERSION_COUNT_TOTAL=47
ATM_STORAGE_BYTES=19234816
ATM_RECENT_SAVES=first beat|2026-05-12T04:23:11,chord progression|2026-05-11T18:22:05
ATM_PRUNE_LAST_RUN=2026-05-12T04:00:03
ATM_PRUNE_DELETED_LAST_RUN=3
```

Format: shell-sourceable KEY=VALUE pairs. This lets any digest script (`source ~/.atm-summary`) read current state without parsing logs. A Filename Court Sunday digest or any future dashboard can consume this without touching ATM's internals. The file is written atomically (write to `.atm-summary.tmp`, then `mv`).

---

## 3. Watcher Script Logic (atm-watch.sh)

The script is invoked by launchd and must be short-lived. It exits after each run; launchd's KeepAlive re-invokes it on the next filesystem event.

Algorithm in prose:

1. **Guard: single instance.** Check for a lockfile at `/tmp/atm-watch.lock`. If present and the PID inside is still alive, log "already running" and exit 0. Write own PID to lockfile.

2. **Initialize paths.** Set `VERSIONS_DIR`, `LOG`, `SEEN_HASHES`, `SUMMARY` to their canonical locations. Create `_versions/` if it does not exist.

3. **Prune stale seen-hashes entries.** Read `~/.atm-seen-hashes`. Drop lines whose date field is not today. If any lines were dropped, rewrite the file.

4. **Build candidate list.** Run `find` on each watched path that currently exists on disk (check with `-d` test first; skip if path absent). Find `*.als` files with mtime within the last 30 seconds. USB2 path: `/Volumes/<external>/ableton`. Internal path: `~/Music/Ableton`. Exclude `_versions/` from the internal scan (avoid copying versions of versions).

5. **For each candidate .als file:**
   a. Verify it is readable and is a regular file.
   b. Compute SHA-256 with `shasum -a 256`.
   c. Check if hash appears in `~/.atm-seen-hashes`. If yes, log "dedup skip" and continue.
   d. Derive project name: the name of the directory that contains the .als file (use `basename $(dirname "$f")`). Handle the case where the .als is directly under a watched root (project name = basename of watched root).
   e. Build destination path: `$VERSIONS_DIR/<project-name>/<basename-without-ext>-<YYYYMMDD-HHMMSS>.als`.
   f. Create project subdir if needed.
   g. Copy with `cp -- "$f" "$dest"`. If copy fails (disk full, permission error), log the error and continue to next candidate - do not exit.
   h. Record hash + today's date in `~/.atm-seen-hashes`.
   i. Log: `[COPIED] <project>/<basename>-<timestamp>.als (<size> bytes)`.

6. **Update `.atm-summary`.** Recount total versions and storage bytes. Prepend the two most recent saves to the RECENT_SAVES field. Write atomically.

7. **Remove lockfile and exit 0.**

---

## 4. Restore Quick Action Workflow - AppleScript Pseudo-Flow

```
-- Finder passes selected file paths as input list
on run {input, parameters}
    set als_path to POSIX path of (item 1 of input)
    set project_name to last word of paragraphs of ...
    -- derive project name by calling shell
    set project_name to do shell script "basename $(dirname " & quoted form of als_path & ")"

    -- get sorted version list from atm-restore.sh
    set version_list to paragraphs of (do shell script \
        "~/Downloads/ableton-time-machine/bin/atm-restore.sh --list " & quoted form of project_name)

    if version_list is {} or version_list is {""} then
        display dialog "No versions found for project: " & project_name
        return
    end if

    -- user picks a version
    set chosen_list to choose from list version_list \
        with prompt "Select version to restore for \"" & project_name & "\":" \
        default items {item 1 of version_list}
    if chosen_list is false then return  -- cancelled

    set chosen_version to item 1 of chosen_list

    -- confirm before overwriting
    display dialog "Restore " & chosen_version & " over " & als_path & \
        "? A .bak copy of the current file will be saved first." \
        buttons {"Cancel", "Restore"} default button "Restore"

    do shell script "~/Downloads/ableton-time-machine/bin/atm-restore.sh --restore " \
        & quoted form of project_name & " " \
        & quoted form of chosen_version & " " \
        & quoted form of als_path

    display notification "Restored " & chosen_version with title "Ableton Time Machine"
end run
```

`atm-restore.sh --list <project>` prints one timestamp per line, newest first, format `YYYYMMDD-HHMMSS`, so the list dialog shows most-recent at top. `atm-restore.sh --restore` backs up the current file to `<original>.bak`, then copies the versioned file to the destination path.

---

## 5. Install / Uninstall Behaviour

### install.sh

1. Verify `~/Downloads/ableton-time-machine/bin/*.sh` are executable; chmod if not.
2. Create `~/Music/Ableton/_versions/` if absent.
3. Copy the launchd plists to `~/Library/LaunchAgents/` with `cp`.
4. Load both plists with `launchctl load`.
5. Copy the Automator workflow: `cp -R quickaction/"Restore Ableton Version.workflow" ~/Library/Services/`.
6. Run the smoke test (`tests/smoke.sh`) - exit non-zero if smoke fails, print instructions.
7. On smoke pass: open the log file with `open ~/Library/Logs/ableton-time-machine.log` (satisfies feedback_open_after_install - something tangible opens without the user having to ask).
8. Print a one-line summary: "ATM installed. Watching USB2 ableton/ and ~/Music/Ableton/. Versions -> ~/Music/Ableton/_versions/. Log open."

### uninstall.sh

1. Unload and remove both launchd plists.
2. Remove the Automator workflow from `~/Library/Services/`.
3. Remove `~/.atm-seen-hashes` and the lockfile if present.
4. Print: "ATM uninstalled. Version store at ~/Music/Ableton/_versions/ is UNTOUCHED. Delete manually if desired."

The version store is never touched by uninstall. Protecting the versions is the point.

---

## 6. Test Plan

Framework: `bats` (Bash Automated Testing System). Install: `brew install bats-core`. All tests run in a temp directory and clean up after themselves. No real `_versions/` or watched paths are touched.

### test_filter_mtime.bats

- **copies_file_modified_within_30s**: create a temp .als, `touch -m` to current time, run the filter logic, assert the file appears in the candidate list.
- **skips_file_modified_60s_ago**: create a temp .als, `touch -m -t` to 60 seconds ago, assert the file does not appear in the candidate list.
- **skips_non_als_file**: create a `.txt` file with fresh mtime, assert it is not in candidates.
- **skips_files_in_versions_subdir**: create a temp .als inside a path containing `_versions`, assert it is excluded.
- **handles_absent_usb2_path**: set the USB2 path to a nonexistent directory, assert the script exits 0 and logs a skip message rather than erroring.

### test_dedup.bats

- **skips_file_with_known_hash**: write a hash+today's date to the seen-hashes state file, create an .als file with that exact content, run the dedup check, assert no copy is made.
- **copies_file_with_new_hash**: seen-hashes is empty, run the check, assert a copy is made and hash is appended to seen-hashes.
- **prunes_stale_hash_entries**: write a hash with yesterday's date to seen-hashes, run the script, assert the stale entry is removed and the file with that hash is treated as new.
- **handles_empty_seen_hashes_file**: seen-hashes is absent, assert the script creates it and copies correctly.

### test_restore_roundtrip.bats

This is the most important test. It exercises the full data path without launchd.

1. **Arrange**: create a temp project directory, write a fixture .als (copy of `tests/fixtures/fake.als`). Record the SHA-256 of the original.
2. **Act (version 1)**: manually invoke the copy logic (sourcing the relevant function from `atm-watch.sh`, or calling it directly with overridden `VERSIONS_DIR`). Assert a versioned copy appears in the temp `_versions/`.
3. **Modify**: overwrite the temp .als with different content. Record new SHA-256.
4. **Act (version 2)**: invoke copy logic again. Assert a second versioned copy appears.
5. **Restore**: invoke `atm-restore.sh --restore` pointing at the first timestamp. Assert the destination .als SHA-256 matches the original (step 1).
6. **Assert .bak exists**: confirm the `.bak` file exists and its SHA-256 matches the modified content (step 3).

This test verifies: copy creates correct files, timestamps sort correctly, restore picks the right version, restore preserves the overwritten file.

### test_prune.bats

- **keeps_all_files_under_30_days**: create 20 versioned files with synthetic mtimes spread over the last 29 days. Run the pruner. Assert all 20 remain.
- **keeps_one_per_day_between_30_and_180_days**: create 5 versions per day for days 31-90 (via `touch -m`). Run pruner. Assert exactly 1 version per day per .als name survives.
- **deletes_files_older_than_180_days**: create files with mtimes 200 days ago. Run pruner. Assert all are deleted.
- **logs_each_deletion**: capture pruner log output. Assert each deleted filename appears in the log.
- **does_not_touch_files_in_30_day_window**: run pruner on a set spanning all three zones. Assert 30-day files are untouched.

### test_usb_absent.bats

- **exits_0_when_usb2_missing**: set `USB2_PATH` to a nonexistent path. Run `atm-watch.sh`. Assert exit code 0.
- **logs_skip_message**: assert log contains "USB2 not mounted" or equivalent.
- **still_scans_internal_path**: verify internal-path .als files are still processed when USB2 is absent.

---

## 7. Smoke Test

`tests/smoke.sh` - runs in under 10 seconds. Called by `install.sh` immediately after loading the plist.

Algorithm:
1. Copy `tests/fixtures/fake.als` to a temp directory inside `~/Music/Ableton/` (the watched internal path).
2. `touch` it to set mtime to now.
3. Sleep 1 second (give launchd time to fire).
4. Poll `~/Music/Ableton/_versions/` for a file matching the temp project name, up to 10 seconds total (`while` loop, 1s sleep, max 10 iterations).
5. If found: print "SMOKE PASS - version copy detected in Xs." Exit 0.
6. If not found within 10 seconds: print "SMOKE FAIL - no version copy detected. Check ~/Library/Logs/ableton-time-machine.log." Exit 1.
7. Clean up temp file.

The smoke test does not delete the versioned copy it creates - that is the first real entry in the version store, and it proves the store is writable.

Note: the smoke test depends on launchd having loaded the plist (step 4 in install.sh). If launchd has not yet fired `atm-watch.sh`, the smoke test uses the 10-second window to allow for the ThrottleInterval. In practice launchd fires within 1-3 seconds of a WatchPaths event.

---

## 8. Sister Project: sets/ Backup

ATM does not touch sets/. The sister project - working name `usb-mirror` - handles it. Recommended layout:

```
~/Downloads/usb-mirror/
  bin/
    mirror-sync.sh      # rsync from /Volumes/<external>/sets/ to ~/Music/Sets-Backup/
    mirror-check.sh     # report new files on USB2 not yet mirrored
  launchd/
    com.atm.usb-mirror.plist     # fires on USB2 mount via DiskArbitration hook
  scripts/
    install.sh
    uninstall.sh
  README.md
```

Strategy: one-time full rsync, then incremental on new files only (`rsync --ignore-existing`). The plist triggers on USB2 mount so new recordings are mirrored the moment the USB is plugged in. No versioning - sets/ files are named recordings that never change after creation; mirroring is sufficient.

PIONEER/ and User Library/ backups would also live in usb-mirror or as separate simple rsync jobs, not in ATM.

---

## 9. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| launchd WatchPaths misses saves while USB2 is unmounted | High (USB2 often not plugged in) | Low (internal saves still caught) | Script-level path existence check; internal-only mode works fine |
| WatchPaths does not re-arm after USB2 reconnects mid-session | Medium | Medium (misses USB2 saves until plist reload) | Document: `launchctl unload` then `launchctl load` re-arms; defer DiskArbitration hook to v2 |
| ThrottleInterval coalesces two rapid saves into one launchd fire | Low (5s window is short) | Low (30s mtime window catches both files) | 30s scan window is the mitigation; documented in D2 |
| Hash collision in seen-hashes causes a save to be skipped | Negligible (SHA-256) | High (version lost) | SHA-256 collision probability is cryptographically negligible; acceptable |
| _versions/ grows beyond 71 Gi free | Very low (budget math shows <2 GB / 6 months) | Medium | Pruner + storage alerting in .atm-summary (ATM_STORAGE_BYTES); add a check to smoke.sh if desired |
| Ableton writes .als as temp file then renames (mtime may be on temp name) | Medium | Medium (mtime filter may miss the rename) | Test specifically with real Ableton save behavior during implementation; may need to scan by ctime as fallback |
| atm-restore.sh overwrites .als with wrong version | Low (user-confirmed dialog) | High | .bak file created before every restore; one undo level always present |
| Project name collision (same folder name, different disks) | Very low (currently unique names) | Low (latest version wins for same timestamp) | Document assumption; one-line prefix fix if collision occurs |

---

## 10. Open Questions (with recommended defaults)

**Q1 - Should Live Recordings (~/Music/Ableton/Live Recordings/) also be watched?**
These 3 Temp Projects from May 2026 may contain valuable take-1 ideas. Recommended default: yes, include this path in WatchPaths and the internal scan. Cost: negligible. Risk of missing early ideas: real.

**Q2 - Should the Ableton's own Backup/ folders on USB2 be seeded into _versions/ on first install?**
There are 9 backup files already there (firtsecond [2026-05-08 003805].als etc.) with known timestamps. A one-time import script could ingest them into the version store with the correct timestamps. Recommended default: yes, include a `bin/atm-import-existing.sh` step in install.sh so history is not lost.

**Q3 - What is the target restore latency - Finder Quick Action only, or also a terminal alias?**
Recommended default: ship the Quick Action (MVP, zero new tools). Add a shell alias `restore-als` for terminal use in a follow-up if the Quick Action feels slow or context-switching out of Finder is annoying.

**Q4 - Should USB4 (17 Gi free, removable) be used as a mirror of _versions/ when mounted?**
Internal disk is the primary store. USB4 mirroring would add redundancy at the cost of some complexity in the watcher script. Recommended default: no mirroring in v1. If USB2 eventually becomes available again for writing, revisit.

**Q5 - Should the pruner send a macOS notification when it runs and how many files it pruned?**
Recommended default: notify only if it deleted more than 0 files, using `osascript -e 'display notification ...'`. Silent pruner runs are noise; a deletion notification gives users visibility without spam.
