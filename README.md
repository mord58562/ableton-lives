# Ableton Time Machine

Automatic versioning, encrypted cloud backup, and crash-recovery for Ableton
Live projects on macOS.

Every save of a `.als` file is captured within 30 seconds and stored as a
timestamped snapshot. Finished audio exports (`.wav`, `.aiff`, `.mp3`,
`.flac`, etc.) are mirrored too. A daily retention policy keeps storage
small. Optionally, the entire version store is mirrored nightly to Google
Drive with end-to-end encryption — Google sees only opaque blobs. When
Ableton crashes, the closest preceding version is automatically tagged
so the right snapshot is one click away.

Pure zsh + macOS built-ins. No Python, no Electron, no resident daemon
RAM. The only optional dependency is `rclone` (for cloud sync).

## Features

- **Versioning** — every `.als` save deduped and timestamped within 30s
- **Export capture** — finished audio renders are versioned alongside `.als`
- **Tiered retention** — 24h all / 30d hourly / 180d daily / 365d weekly / delete
- **Encrypted cloud sync** — `rclone crypt` to Google Drive (or any rclone backend)
- **Hard storage caps** — sync refuses if local or Drive limits would be breached
- **Crash recovery** — Ableton crash detected → closest pre-crash version pinned
- **Tag/pin** — mark `demo-v1`, `client-approved` etc.; tagged versions never pruned
- **Bundle snapshots** — archive an entire project folder including Samples/
- **Cloud-only restore** — pull the encrypted backup to a fresh machine
- **Restore previews** — Quick Action shows BPM, track count, size next to each timestamp
- **Integrity verifier** — weekly gzip-test on a random sample, catches bit-rot
- **Menu bar** — xbar / SwiftBar plugin showing status, alerts, recent saves
- **Smart notifications** — state-transition aware, deduplicated, with audit log

## Quick start

```bash
git clone https://github.com/<you>/ableton-time-machine.git
cd ableton-time-machine
zsh scripts/install.sh
```

The interactive installer asks where your Ableton folder is, whether you
have an external drive to monitor, your storage cap, and whether to set
up encrypted cloud sync. Sane defaults throughout — press Return to
accept any prompt.

To enable cloud sync later:

```bash
brew install rclone
bin/atm-sync-setup.sh    # walks you through OAuth + encryption keys
```

## Daily use

Right-click any `.als` in Finder → **Restore Ableton Version**. Pick a
timestamp from the list — each line shows the version's BPM, track count
and size for context. The current file is backed up to `.als.bak` before
overwrite, so a single undo is always available.

The menu bar plugin shows last save time, version count, Drive usage,
recent alerts, and a one-click action to run sync immediately.

## CLI tools

```text
bin/atm-config.sh            show or change settings (paths, caps, etc.)
bin/atm-sync.sh              run cloud sync now
bin/atm-bundle.sh snapshot   archive a whole project folder
bin/atm-bundle.sh restore    extract a project bundle
bin/atm-cloud-restore.sh     pull encrypted backup down (disaster recovery)
bin/atm-tag.sh add           pin a version so it survives forever
bin/atm-preview.sh           extract BPM / track count from a version
bin/atm-verify.sh            sample N versions and check integrity
```

## Storage caps

ATM has a hard ceiling on how much it will store, defaulting to **20 GB**.
If your version store grows past the cap, sync refuses rather than risk
filling your Drive. Tune any time:

```bash
bin/atm-config.sh set ATM_REMOTE_CAP_GB 50
bin/atm-config.sh set ATM_FREE_FLOOR_GB 5
```

A soft notification fires at 75% of the cap so you have time to react.

## Multi-machine

Point a second Mac at the same `atm-crypt:` remote (using the same
passwords), and both machines share one encrypted version store. For
true bidirectional sync, use `rclone bisync` in place of `rclone sync`
in `bin/atm-sync.sh`.

## Privacy

- Cloud content is encrypted client-side. Filenames, directory names,
  and `.als` content are never readable by Google.
- Encryption keys live in `~/.config/rclone/rclone.conf` only. They
  never leave your machine. **Lose them and your cloud backup is
  unrecoverable** — back them up to a password manager during setup.
- The crash watcher reads system crash logs at
  `~/Library/Logs/DiagnosticReports/`. Only filenames and mtimes are
  used; no crash content is uploaded.
- A local audit log of notifications is kept at
  `~/Library/Logs/ableton-time-machine-notifications.log`. Local only.

## Uninstall

```bash
zsh scripts/uninstall.sh
```

Removes all launchd agents, the Finder Quick Action, and menu bar
plugin links. Leaves your version store, config, cloud backup, and
rclone authentication intact. Delete those by hand if you really want
a full wipe.

## Development

Tests use [`bats-core`](https://github.com/bats-core/bats-core):

```bash
brew install bats-core
bats tests/
```

All tests run hermetically in `/tmp/` and never touch the real
`_versions/` store, real notifications, or any cloud account.

## License

MIT — see [LICENSE](LICENSE).
