# Ableton Lives

Automatic per-`.als` versioning and encrypted backup for Ableton Live projects on macOS. The watcher captures every save within 30 seconds as a content-addressed snapshot, stores it under an internal `_versions/` tree, optionally mirrors to an external drive, and optionally syncs nightly to Google Drive through `rclone crypt` so the cloud only ever sees opaque blobs. A SwiftUI menubar app reports state at a glance. Unlike folder-level rsync backups, every `.als` save is a discrete restorable version with verifiable integrity, and restore happens from a Finder right-click rather than a backup app.

## Screenshot

![menubar](docs/screenshots/menubar.png)

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (arm64)
- Ableton Live 11 or 12
- Optional: a Google account with spare Drive quota (for nightly cloud sync)
- Optional: an external USB or SSD drive (for an offline second copy)

Homebrew, Xcode Command Line Tools, `rclone`, and `zstd` are handled by the installer. You do not need to set them up beforehand.

## Quick install

```sh
git clone https://github.com/mord58562/ableton-lives.git
cd ableton-lives
zsh scripts/install.sh
```

The installer is interactive and tells you what it is about to do at each step. Run it with `--dry-run` first if you want to see every prompt and action without touching the system.

## What the installer does

1. **Preflight checks.** Confirms macOS, `zsh`, `shasum`, and the Xcode Command Line Tools are present. Triggers `xcode-select --install` if the CLT are missing.
2. **Homebrew.** If `brew` is missing, offers to run the official Homebrew installer. You can decline and stay local-only.
3. **rclone.** Installs `rclone` via Homebrew unless you opt out. Without `rclone` the tool runs in local-only mode and cloud sync stays disabled.
4. **zstd.** Installs `zstd` via Homebrew for compact project bundles. Falls back to `gzip` if you skip it.
5. **Folders to monitor.** Detects your Ableton projects folder (default `~/Music/Ableton`), confirms the path to your User Library, and asks whether you also want to watch an external drive. Missing folders can be created on the spot.
6. **Storage caps.** Asks for two numbers: the maximum size for the local version store (default 20 GB) and the free-space floor on your Drive (default 10 GB). Either limit pauses sync rather than overrunning your disk or Drive quota.
7. **Cloud sync intent.** Asks whether to enable nightly sync. If yes, asks whether to encrypt. Encrypted mode (recommended) hides filenames, directory names, and content from Google; unencrypted mode lets you browse the backup from `drive.google.com`.
8. **Review and confirm.** Shows every choice in one block before writing anything.
9. **Config file.** Writes `~/.config/ableton-lives/config` with the chosen values.
10. **Launch agents.** Renders the `launchd` plist templates with your paths and loads the watcher, pruner, verifier, and crash-watcher agents. The menubar agent loads once the app is built. The sync agent loads only after Drive setup finishes.
11. **Finder Quick Action.** Installs `Restore Ableton Version.workflow` into `~/Library/Services/` so the right-click menu on any `.als` shows a restore option.
12. **Existing backups import.** If Ableton has been writing its own `Backup/` folders, `lives-import-existing.sh` ingests them into `_versions/` with their original timestamps so no history is lost.
13. **Menubar app.** Calls `swift/build.sh`, which compiles `AbletonLives.app` with `swiftc` and ad-hoc signs the bundle. The agent loads it on success.
14. **Drive setup.** If cloud sync is enabled, offers to run `lives-sync-setup.sh` now. That script opens a browser for Google OAuth, generates two strong random passwords for the crypt layer, prints them once for you to save to a password manager, and dry-runs a sync before loading the nightly agent.

## What you get afterwards

A menubar app and a set of `lives-*` CLI tools under `bin/`. The watcher, pruner, verifier, and crash-watcher run on their own through `launchd`. You never need to invoke them by hand.

### Menubar app

`swift/AbletonLives.app` shows current state at a glance: last save time, version count, storage used, sync status, alerts, and a one-click "Sync now" action.

### Finder Quick Action

Right-click any `.als` file in Finder, choose **Restore Ableton Version**, and pick a timestamp. The current file is copied to `.als.bak` before the restore overwrites it, so a single undo is always available.

### CLI tools

```text
bin/lives-config.sh           Read or change configuration values (paths, caps, remotes).
bin/lives-watch.sh            The watcher. Invoked by launchd; scans for recent saves and copies versioned snapshots.
bin/lives-prune.sh            The retention pruner. Tiered policy keeps storage small.
bin/lives-restore.sh          List versions for a project or restore one back over the current file.
bin/lives-tag.sh              Pin a version with a label so it is never pruned.
bin/lives-preview.sh          Extract BPM, track count, and size from a versioned .als.
bin/lives-verify.sh           Sample N random versions and check gzip integrity. Catches bit-rot.
bin/lives-bundle.sh           Snapshot or restore a whole project folder (Samples/, presets, clips, devices).
bin/lives-sync.sh             Run cloud sync now instead of waiting for the nightly agent.
bin/lives-sync-setup.sh       One-time interactive Google Drive + encryption setup.
bin/lives-cloud-restore.sh    Pull the encrypted backup down to a fresh machine.
bin/lives-crash-watch.sh      Detect Ableton crashes and tag the closest preceding version.
bin/lives-import-existing.sh  Ingest Ableton's own Backup/ files into _versions/ on first install.
```

## How it works

- Every `.als` save is detected by a `launchd` watcher within roughly 30 seconds, deduplicated by SHA-256, and copied to `~/Music/Ableton/_versions/<project>/<basename>-YYYYMMDD-HHMMSS.als`.
- A daily pruner keeps storage bounded: all versions for the last 24 hours, hourly for 30 days, daily for 6 months, weekly for a year, then deleted. Tagged versions are never pruned.
- A weekly verifier picks random versions and re-tests their gzip integrity to catch silent disk corruption.
- A crash watcher reads `~/Library/Logs/DiagnosticReports/` and, on a new Ableton crash, automatically pins the closest preceding version with a `crash-recovery` label.
- Cloud sync runs nightly at 04:30 with `rclone sync` against an `rclone crypt` remote. Filenames, directory names, and content are encrypted client-side; the keys live only in `~/.config/rclone/rclone.conf` on your machine.
- Configuration lives at `~/.config/ableton-lives/config` and is editable by hand or through `bin/lives-config.sh set KEY VALUE`.
- Logs go to `~/Library/Logs/ableton-lives.log` (rotated weekly).

## Storage caps

Two limits, both adjustable.

```sh
bin/lives-config.sh set LIVES_REMOTE_CAP_GB 50
bin/lives-config.sh set LIVES_FREE_FLOOR_GB 5
```

If the local version store exceeds `LIVES_REMOTE_CAP_GB`, sync stops uploading until the pruner shrinks it. If your Drive free space drops below `LIVES_FREE_FLOOR_GB`, sync pauses so the rest of your Drive is not squeezed.

## Cloud restore

On a fresh Mac, after installing Ableton Lives and re-creating the same `rclone crypt` remote with the same two passwords:

```sh
bin/lives-cloud-restore.sh
```

The backup downloads, decrypts, and lands at `~/Music/Ableton/_versions/`. From there the Finder Quick Action restores any `.als` to any location.

## Privacy

- Cloud content is encrypted client-side. Filenames, directory names, and `.als` content are never visible to Google.
- Encryption keys live only in `~/.config/rclone/rclone.conf`. They never leave your machine. **Lose them and the cloud backup is unrecoverable.** The setup script prints them once so you can save them to a password manager.
- The crash watcher reads system crash logs at `~/Library/Logs/DiagnosticReports/`. Only filenames and modification times are used; no crash content is uploaded.
- A local notification audit log lives at `~/Library/Logs/ableton-lives-notifications.log`. Local only.

## Uninstall

```sh
zsh scripts/uninstall.sh
```

Removes the launch agents, the Quick Action, and the menubar binary. Leaves your version store, config file, cloud backup, and `rclone` authentication intact. Pass `--purge` to also wipe `~/.config/ableton-lives/`, the local `_versions/` tree, and the rclone remotes.

## Development

Tests use [`bats-core`](https://github.com/bats-core/bats-core):

```sh
brew install bats-core
bats tests/
```

All tests run hermetically in `/tmp/` and never touch the real version store, real notifications, or any cloud account.

## License

MIT. See [LICENSE](LICENSE).
