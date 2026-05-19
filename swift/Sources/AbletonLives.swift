// AbletonLives.swift
//
// Single-file menubar app for Ableton Lives.
// Architecture: NSStatusItem + borderless NSPanel hosting SwiftUI.
// Lazy: state is read from disk on every panel open. No timers.
//
// Build: see swift/build.sh in the source tree.
//
// Design constraints (held throughout):
//   - Compact: ~300pt wide, target ~280pt tall in the typical state.
//   - Plain labels. The character is in the palette + the icon, not the words.
//     "All clear", not "Vault sealed".
//   - Easter eggs only in places they cannot delay use:
//       * empty-state messages (only seen when there's nothing to do)
//       * About panel (only seen when explicitly opened)
//   - Zero idle CPU between user interactions.
//
// macOS 13+. NSPanel chosen over NSPopover because on macOS 26 the popover
// frame applies a wallpaper-tinted "liquid glass" with no opt-out.

import AppKit
import SwiftUI

// =============================================================================
// MARK: - Palette
// =============================================================================
//
// One opaque palette. Surface is a near-flat dark slate with a subtle vertical
// gradient (~3% lightness delta). Signal colours (green/amber/red) live
// outside the theme so they always read the same way.

enum Palette {
    // Surface: dark slate with a quiet warm tilt so it doesn't feel clinical.
    static let bgTop      = Color(red: 0.135, green: 0.143, blue: 0.165)
    static let bgBottom   = Color(red: 0.105, green: 0.115, blue: 0.135)
    static let cardBg     = Color(red: 0.165, green: 0.175, blue: 0.200)
    static let divider    = Color.white.opacity(0.07)

    // Text
    static let text       = Color(red: 0.92, green: 0.92, blue: 0.90)
    static let textDim    = Color(red: 0.60, green: 0.62, blue: 0.65)
    static let textFaint  = Color(red: 0.42, green: 0.44, blue: 0.47)

    // Brand accent. Slightly desaturated TARDIS-adjacent blue: reads as
    // "console panel light" on a dark surface, never says "Doctor Who"
    // out loud. Carries the sci-fi tilt without being on-the-nose.
    static let accent     = Color(red: 0.34, green: 0.62, blue: 0.92)

    // Signal colours - identical to anywhere else in the system. These are
    // the meanings, not the theme.
    static let success    = Color(red: 0.42, green: 0.78, blue: 0.56)
    static let warn       = Color(red: 0.95, green: 0.69, blue: 0.31)
    static let error      = Color(red: 0.92, green: 0.45, blue: 0.43)
    static let info       = Color(red: 0.45, green: 0.62, blue: 0.93)
}

// =============================================================================
// MARK: - State snapshot
// =============================================================================

struct LivesSnapshot {
    enum OverallStatus { case allClear, warn, error, crashRecent, notSetUp }

    var overall: OverallStatus = .notSetUp
    var statusLabel: String = "Not set up"

    var snapshotCount: Int? = nil       // total .als snapshots Ableton Lives has stored
    var localBytes: Int64? = nil        // size of Ableton Lives' local store

    // Ableton Lives' own cap (from config) and what's currently in the cloud.
    var livesRemoteBytes: Int64? = nil    // bytes Ableton Lives has uploaded
    var livesCapBytes: Int64? = nil       // user's configured cap

    var driveUsedBytes: Int64? = nil    // entire Google Drive used
    var driveTotalBytes: Int64? = nil   // entire Google Drive plan

    var lastSyncStatus: String? = nil
    var lastSyncAge: String? = nil

    var crash: CrashInfo? = nil
    var recentSaves: [RecentSave] = []
    var alerts: [AlertEntry] = []
}

struct CrashInfo {
    let projectName: String
    let preVersionTimestamp: String
    let preVersionPath: String
    let crashAge: String
}

struct RecentSave {
    let projectName: String
    let basename: String
    let savedAge: String     // when the underlying .als was last modified in Ableton
    let backedUpAge: String  // when Ableton Lives took the snapshot we're showing
    let path: String         // snapshot file path (for "reveal in Finder")
}

struct AlertEntry {
    let timeLabel: String       // "09:32"
    let title: String
    let message: String
    let severity: Severity
    enum Severity { case info, warn, error }
}

// =============================================================================
// MARK: - Paths (resolved from ~/.config/ableton-lives/config or sane defaults)
// =============================================================================

struct LivesPaths {
    let home: String          // source tree (where bin/lives-sync.sh lives)
    let internalPath: String  // Ableton projects folder
    let usbPath: String       // optional external drive mount; "" if none
    let versionsDir: String
    let log: String
    let summary: String
    let notifyLog: String
    let crashMarker: String
    let alertsClearedAt: String  // cutoff file; alerts <= this ISO ts are hidden
    let livesCapBytes: Int64    // hard ceiling from LIVES_REMOTE_CAP_GB

    static func resolve() -> LivesPaths {
        let home = NSHomeDirectory()
        let configFile = "\(home)/.config/ableton-lives/config"
        var values: [String: String] = [:]
        if let raw = try? String(contentsOfFile: configFile, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s.hasPrefix("#") { continue }
                if let eq = s.firstIndex(of: "=") {
                    let k = String(s[..<eq])
                    var v = String(s[s.index(after: eq)...])
                    // Strip surrounding quotes if present (zsh %q output)
                    if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                        v = String(v.dropFirst().dropLast())
                    }
                    values[k] = v
                }
            }
        }
        let internalPath = values["LIVES_INTERNAL_PATH"] ?? "\(home)/Music/Ableton"
        let usbPath = values["LIVES_USB_PATH"] ?? ""
        let versions = values["LIVES_VERSIONS_DIR"] ?? "\(internalPath)/_versions"
        let log = values["LIVES_LOG"] ?? "\(home)/Library/Logs/ableton-lives.log"
        let summary = values["LIVES_SUMMARY"] ?? "\(home)/Documents/.ableton-lives-summary"
        let notify = values["LIVES_NOTIFY_LOG"]
            ?? "\(home)/Library/Logs/ableton-lives-notifications.log"
        let crashMk = values["LIVES_CRASH_MARKER"] ?? "\(home)/.ableton-lives-last-crash"
        let clearedAt = values["LIVES_ALERTS_CLEARED_AT"] ?? "\(home)/.ableton-lives-alerts-cleared-at"
        let capGB = Int64(values["LIVES_REMOTE_CAP_GB"] ?? "") ?? 20
        let capBytes = capGB * 1_073_741_824
        // LIVES_HOME isn't always written to config; fall back to the parent of
        // this binary's bundle (build.sh installs the .app inside the source
        // tree, so this resolves to the repo root).
        let resolvedHome: String = {
            if let h = values["LIVES_HOME"], !h.isEmpty { return h }
            // .app/../.. walks up out of swift/AbletonLives.app/ to the repo.
            // URL.deletingLastPathComponent() is the modern, type-correct path.
            let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
            return bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        }()
        return LivesPaths(home: resolvedHome,
                        internalPath: internalPath,
                        usbPath: usbPath,
                        versionsDir: versions,
                        log: log,
                        summary: summary,
                        notifyLog: notify,
                        crashMarker: crashMk,
                        alertsClearedAt: clearedAt,
                        livesCapBytes: capBytes)
    }
}

// =============================================================================
// MARK: - Snapshot reading
// =============================================================================

extension LivesSnapshot {
    static func read(paths: LivesPaths) -> LivesSnapshot {
        var s = LivesSnapshot()

        // ---- Summary KEY=VALUE (drive quota + last-sync info only; the
        // version count + local bytes are derived from the disk walk
        // below so we never disagree with what's actually on disk).
        let summary = parseKeyValueFile(paths.summary)

        if let used = summary["LIVES_SYNC_DRIVE_USED_BYTES"].flatMap(Int64.init),
           used > 0 {
            s.driveUsedBytes = used
        }
        if let total = summary["LIVES_SYNC_DRIVE_TOTAL_BYTES"].flatMap(Int64.init),
           total > 0 {
            s.driveTotalBytes = total
        }
        if let remote = summary["LIVES_SYNC_REMOTE_BYTES"].flatMap(Int64.init),
           remote > 0 {
            s.livesRemoteBytes = remote
        }
        s.livesCapBytes = paths.livesCapBytes
        if let st = summary["LIVES_SYNC_LAST_STATUS"], !st.isEmpty {
            s.lastSyncStatus = st
        }
        if let runIso = summary["LIVES_SYNC_LAST_RUN"],
           let date = isoDate(runIso) {
            s.lastSyncAge = humanAge(from: date)
        }

        // ---- Single disk walk: count + bytes + top-3 saves with both
        // "saved in Ableton" mtime (from the original .als if findable)
        // and "backed up by Ableton Lives" mtime (from the snapshot itself).
        let walk = walkVersions(under: paths.versionsDir,
                                internalPath: paths.internalPath,
                                usbPath: paths.usbPath)
        s.snapshotCount = walk.count > 0 ? walk.count : nil
        s.localBytes    = walk.bytes > 0 ? walk.bytes : nil
        s.recentSaves   = walk.recent

        // ---- Crash marker
        let crashKV = parseKeyValueFile(paths.crashMarker)
        if let epochStr = crashKV["LIVES_CRASH_EPOCH"],
           let epoch = TimeInterval(epochStr) {
            let crashDate = Date(timeIntervalSince1970: epoch)
            // Only treat as actionable if within 24h
            if Date().timeIntervalSince(crashDate) < 86_400 {
                s.crash = CrashInfo(
                    projectName: crashKV["LIVES_CRASH_PROJECT"] ?? "(unknown)",
                    preVersionTimestamp: crashKV["LIVES_CRASH_PRE_VERSION_TS"] ?? "",
                    preVersionPath: crashKV["LIVES_CRASH_PRE_VERSION_PATH"] ?? "",
                    crashAge: humanAge(from: crashDate)
                )
            }
        }

        // ---- Recent alerts that fired (last 5)
        s.alerts = recentAlerts(notifyLog: paths.notifyLog,
                                clearedAtFile: paths.alertsClearedAt,
                                limit: 5)

        // ---- Overall status
        // Canary for "ever saved" is presence of any version on disk.
        // versionCount being nil means the disk walk found zero .als files
        // (genuinely no saves yet), not just "summary file wasn't populated".
        if let crash = s.crash {
            s.overall = .crashRecent
            s.statusLabel = "Recovery ready · crashed \(crash.crashAge) ago"
        } else if s.lastSyncStatus == "failed" {
            s.overall = .error
            s.statusLabel = "Sync failed"
        } else if let used = s.driveUsedBytes, let total = s.driveTotalBytes,
                  total > 0, (used * 100 / total) >= 80 {
            s.overall = .warn
            s.statusLabel = "Drive almost full"
        } else if s.snapshotCount == nil {
            s.overall = .notSetUp
            s.statusLabel = "Waiting for first save"
        } else {
            s.overall = .allClear
            s.statusLabel = "All clear"
        }

        return s
    }
}

// =============================================================================
// MARK: - Disk reads (lightweight, on-demand)
// =============================================================================

private func parseKeyValueFile(_ path: String) -> [String: String] {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return [:]
    }
    var out: [String: String] = [:]
    for line in raw.split(separator: "\n") {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("#") { continue }
        guard let eq = s.firstIndex(of: "=") else { continue }
        out[String(s[..<eq])] = String(s[s.index(after: eq)...])
    }
    return out
}

/// Single-pass walk over `_versions/` collecting count, bytes, and
/// the top-N most recent saves. Each save row carries TWO timestamps:
///   - "saved": mtime of the original .als in the user's project folder
///              (so they can see when they last hit save in Ableton).
///   - "backed up": mtime of the snapshot we wrote (when Ableton Lives captured it).
/// Looks the original up under the configured internal path AND optional
/// external drive path - whichever exists wins.
private struct VersionsWalk {
    var count: Int = 0
    var bytes: Int64 = 0
    var recent: [RecentSave] = []
}

private func walkVersions(under root: String,
                          internalPath: String,
                          usbPath: String,
                          recentLimit: Int = 3) -> VersionsWalk {
    var w = VersionsWalk()
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: [
            .contentModificationDateKey,
            .isRegularFileKey,
            .fileSizeKey,
        ],
        options: [.skipsPackageDescendants]
    ) else { return w }

    // Group snapshots by (project, basename) so each row is one
    // logical .als file rather than a list of every snapshot ever taken.
    struct Latest { var url: URL; var mtime: Date }
    var latestByKey: [String: Latest] = [:]

    for case let url as URL in enumerator {
        let p = url.path
        if !p.hasSuffix(".als") { continue }
        if p.contains("/_exports/") || p.contains("/_bundles/") { continue }
        guard let v = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .fileSizeKey,
            ]),
            v.isRegularFile == true,
            let mt = v.contentModificationDate else { continue }
        w.count += 1
        if let sz = v.fileSize { w.bytes += Int64(sz) }

        let project = url.deletingLastPathComponent().lastPathComponent
        var trimmed = url.lastPathComponent
        if let r = trimmed.range(of: #"-\d{8}-\d{6}\.als$"#,
                                 options: .regularExpression) {
            trimmed = String(trimmed[..<r.lowerBound])
        }
        let key = "\(project)/\(trimmed)"
        if let prev = latestByKey[key] {
            if mt > prev.mtime { latestByKey[key] = Latest(url: url, mtime: mt) }
        } else {
            latestByKey[key] = Latest(url: url, mtime: mt)
        }
    }

    // Top-N most-recently-backed-up unique projects/files.
    let sorted = latestByKey.sorted { $0.value.mtime > $1.value.mtime }
    w.recent = sorted.prefix(recentLimit).map { (key, latest) in
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        let project = parts.count > 0 ? parts[0] : "(unknown)"
        let basename = parts.count > 1 ? parts[1] : key

        // Look up the original .als to discover when the user last saved.
        let originalMtime: Date? = {
            for root in [internalPath, usbPath] where !root.isEmpty {
                let candidate = "\(root)/\(project)/\(basename).als"
                if let attrs = try? fm.attributesOfItem(atPath: candidate),
                   let mt = attrs[.modificationDate] as? Date {
                    return mt
                }
            }
            return nil
        }()

        return RecentSave(
            projectName: project,
            basename: basename,
            savedAge: originalMtime.map { humanAge(from: $0) }
                ?? humanAge(from: latest.mtime),  // fall back to backup time
            backedUpAge: humanAge(from: latest.mtime),
            path: latest.url.path
        )
    }
    return w
}

private func recentAlerts(notifyLog: String,
                          clearedAtFile: String,
                          limit: Int) -> [AlertEntry] {
    guard let raw = try? String(contentsOfFile: notifyLog, encoding: .utf8)
    else { return [] }
    // "Cleared" cutoff: alerts whose ISO timestamp is <= the cutoff are
    // hidden. String comparison works because the schema is fixed-width
    // ISO-8601 ("2026-05-18T15:16:14"). Missing file = no cutoff = show all.
    let cutoff: String = {
        guard let raw = try? String(contentsOfFile: clearedAtFile,
                                    encoding: .utf8) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    var out: [AlertEntry] = []
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
    // Walk from the end so we get the most recent first.
    for line in lines.reversed() {
        if out.count >= limit { break }
        let parts = line.split(separator: "\t",
                               omittingEmptySubsequences: false)
        // Schema: ts \t category \t status \t fired/suppressed \t title \t msg
        guard parts.count >= 6 else { continue }
        if parts[3] != "fired" { continue }
        let ts = String(parts[0])
        if !cutoff.isEmpty && ts <= cutoff { continue }
        let timeLabel: String = {
            // ISO "2026-05-12T10:33:17" -> "10:33"
            if let t = ts.range(of: "T") {
                let after = ts[t.upperBound...]
                return String(after.prefix(5))
            }
            return ts
        }()
        let status = String(parts[2])
        let sev: AlertEntry.Severity = {
            switch status {
            case "error": return .error
            case "warn":  return .warn
            default:      return .info
            }
        }()
        out.append(AlertEntry(
            timeLabel: timeLabel,
            title: String(parts[4]),
            message: String(parts[5]),
            severity: sev
        ))
    }
    return out
}

// =============================================================================
// MARK: - Time / size formatting
// =============================================================================

private func isoDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
    if let d = f.date(from: s) { return d }
    // Fallback for our log format "2026-05-12T10:33:17" (no zone)
    let g = DateFormatter()
    g.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    g.timeZone = TimeZone.current
    return g.date(from: s)
}

private func humanAge(from date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}

private func humanBytes(_ b: Int64) -> String {
    // Match Google Drive's web display exactly: 1 GB = 1024^3 bytes
    // (so a 100 GiB-provisioned plan shows as "100 GB" in the panel,
    // matching the Drive UI). Up to 2 decimals for GB, dropping trailing
    // zeros so "100.00" becomes "100" and "42.36" stays "42.36".
    let d = Double(b)
    if d >= 1_073_741_824 { return trimZeros(d / 1_073_741_824, unit: "GB") }
    if d >= 1_048_576 { return trimZeros(d / 1_048_576,    unit: "MB") }
    if d >= 1_024     { return String(format: "%d KB",  Int((d / 1_024).rounded())) }
    return "\(b) B"
}

/// Format `value` with up to 2 decimals. Drops trailing zeros so an exact
/// integer prints as "20 GB" rather than "20.00 GB".
private func trimZeros(_ value: Double, unit: String) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() {
        return String(format: "%.0f %@", rounded, unit)
    }
    if (rounded * 10).rounded() / 10 == rounded {
        return String(format: "%.1f %@", rounded, unit)
    }
    return String(format: "%.2f %@", rounded, unit)
}

// =============================================================================
// MARK: - Hand-drawn template icon
// =============================================================================
//
// Three offset rounded rectangles, suggesting a stack of versioned snapshots
// captured over time. ≥1.3pt strokes; integer geometry; isTemplate so AppKit
// tints to the menubar context (light/dark mode).

// Hand-drawn rewind-to-start glyph (⏮). Bold filled vertical bar on the
// left, big filled left-pointing triangle to its right. The universal
// "jump back to the beginning" UI element, instantly recognisable, no
// internal strokes that can pixel-snap away at @1x. Reads at menubar
// scale as "restore from earlier", which is what the app does.
enum LivesIcon {
    static let template: NSImage = {
        let canvas = NSSize(width: 22, height: 16)
        let img = NSImage(size: canvas, flipped: false) { _ in
            NSColor.black.setFill()

            // Vertical bar (the "wall" the triangle butts up against).
            // Fat enough to read; full canvas height minus 2pt margin.
            let bar = NSBezierPath(rect: NSRect(
                x: 4, y: 3, width: 2.5, height: 10))
            bar.fill()

            // Left-pointing triangle. Tip at the bar, base at the right.
            // Same vertical extent as the bar so the two shapes feel
            // balanced. Big and chunky on purpose - fills always survive.
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: 7,  y: 8))   // tip touching the bar
            tri.line(to: NSPoint(x: 17, y: 13))  // top-right
            tri.line(to: NSPoint(x: 17, y: 3))   // bottom-right
            tri.close()
            tri.fill()

            return true
        }
        img.isTemplate = true
        return img
    }()
}

// =============================================================================
// MARK: - SwiftUI views
// =============================================================================

enum PanelAction {
    case syncNow
    case openVersions
    case openLog
    case openAlerts
    case clearAlerts
    case revealCrashVersion(path: String)
    case dismissCrashBanner
    case quit
}

struct StatsView: View {
    let snapshot: LivesSnapshot
    /// When set, replaces the normal status pill text - used to show
    /// "Syncing..." or similar transient state immediately on click so the
    /// panel reacts even though the underlying job is still in flight.
    let transientStatus: String?
    let onAction: (PanelAction) -> Void

    var body: some View {
        // Jury-style anchor arrow at the top, pointing up to the menu bar
        // icon. Drawn as a small triangle in the same fill as the panel.
        // The triangle sits OUTSIDE the rounded body but INSIDE the
        // overall view bounds, so its shadow renders cleanly with the
        // body shadow.
        VStack(spacing: 0) {
            ArrowTip()
                .fill(Palette.bgTop)
                .frame(width: 14, height: 7)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(Palette.divider)

                statRows
                    .padding(.vertical, 8)

                if let crash = snapshot.crash {
                    Divider().background(Palette.divider)
                    crashCard(crash)
                        .padding(.vertical, 8)
                }

                Divider().background(Palette.divider)
                recentSavesSection
                    .padding(.vertical, 8)

                if !snapshot.alerts.isEmpty {
                    Divider().background(Palette.divider)
                    alertsSection
                        .padding(.vertical, 8)
                }

                Divider().background(Palette.divider)
                actionBar
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .frame(width: 300, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Palette.bgTop, Palette.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        // No SwiftUI shadow - macOS draws it natively via panel.hasShadow.
        // SwiftUI shadows clip at the NSPanel frame and produce visible
        // hard edges no matter how the padding is tuned. Native shadow is
        // tight, faded, and respects the rounded clip path automatically.
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // ---- Header
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: LivesIcon.template)
                .renderingMode(.template)
                .foregroundStyle(Palette.accent)
                .frame(width: 22, height: 16)
            Text("Ableton Lives")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer()
        }
        .padding(.bottom, 8)
    }

    // ---- Status pill + stat rows
    @ViewBuilder
    private var statRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Single state line - status + when last verified, no labels
            // needed. Reads naturally left to right. Transient overrides
            // (e.g. "Syncing… (5s)") replace the status text in place.
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(transientStatus ?? snapshot.statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                if transientStatus == nil {
                    Text(snapshot.lastSyncAge.map { "synced \($0) ago" }
                         ?? "never synced")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textFaint)
                }
            }

            // Two storage progress bars. Bars do the visual work;
            // numbers below are the precise readout. No grid alignment
            // to fight - each block stands on its own.
            let livesUsed = snapshot.livesRemoteBytes ?? snapshot.localBytes ?? 0
            let livesCap  = snapshot.livesCapBytes ?? 0
            storageBar(title: "Ableton Lives",
                       used: livesUsed,
                       total: livesCap)

            if let dUsed = snapshot.driveUsedBytes,
               let dTotal = snapshot.driveTotalBytes, dTotal > 0 {
                storageBar(title: "Google Drive",
                           used: dUsed,
                           total: dTotal)
            }

            // Snapshot count - single understated line, no row chrome.
            if let n = snapshot.snapshotCount {
                Text("\(n) snapshot\(n == 1 ? "" : "s") stored")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textFaint)
            }
        }
    }

    /// Storage usage bar. Title + percent on top line, coloured fill on
    /// a thin track, exact bytes below. The bar is the at-a-glance
    /// readout; the numbers are for when you want exact figures.
    private func storageBar(title: String, used: Int64, total: Int64) -> some View {
        let frac = total > 0 ? min(1.0, max(0.0, Double(used) / Double(total))) : 0
        let pct  = Int((frac * 100).rounded())
        let fill: Color = {
            if frac >= 0.9 { return Palette.error }
            if frac >= 0.75 { return Palette.warn }
            return Palette.accent
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 11, weight: .medium,
                                  design: .monospaced))
                    .foregroundStyle(Palette.textDim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Palette.cardBg)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fill)
                        .frame(width: max(2, geo.size.width * frac))
                }
            }
            .frame(height: 5)
            HStack {
                Text("\(humanBytes(used)) of \(humanBytes(total))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.textDim)
                Spacer()
            }
        }
    }

    private var statusColor: Color {
        if transientStatus != nil { return Palette.accent }
        switch snapshot.overall {
        case .allClear:    return Palette.success
        case .warn:        return Palette.warn
        case .error:       return Palette.error
        case .crashRecent: return Palette.info
        case .notSetUp:    return Palette.textFaint
        }
    }

    // ---- Crash card
    private func crashCard(_ crash: CrashInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.info)
                Text("Ableton crashed \(crash.crashAge) ago")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.text)
            }
            Text("Pinned: \(crash.projectName) · \(crash.preVersionTimestamp)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Button("Reveal version") {
                    onAction(.revealCrashVersion(path: crash.preVersionPath))
                }
                .buttonStyle(SmallButton(tint: Palette.info))
                Button("Dismiss") {
                    onAction(.dismissCrashBanner)
                }
                .buttonStyle(SmallButton(tint: Palette.textFaint))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.cardBg)
        )
    }

    // ---- Recent saves
    // Each row shows: filename · last-saved-in-Ableton · last-backed-up
    // The two times answer "is my last work backed up?" - if backed-up
    // is roughly the same as saved, Ableton Lives is current. If backed-up is
    // older, the watcher missed something.
    @ViewBuilder
    private var recentSavesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header column widths must match the data row widths exactly
            // or the labels float untethered from the values they describe.
            HStack(spacing: 6) {
                Text("Recent files")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textDim)
                    .textCase(.uppercase)
                Spacer(minLength: 6)
                Text("saved")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .frame(width: 36, alignment: .trailing)
                Text(" ")  // invisible spacer matching the "·" in the rows
                    .font(.system(size: 10))
                Text("backup")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .frame(width: 36, alignment: .trailing)
            }
            if snapshot.recentSaves.isEmpty {
                Text("No coordinates logged yet. Save in Ableton to begin.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textFaint)
            } else {
                ForEach(snapshot.recentSaves.indices, id: \.self) { i in
                    let s = snapshot.recentSaves[i]
                    Button(action: {
                        NSWorkspace.shared.selectFile(s.path,
                            inFileViewerRootedAtPath: "")
                    }) {
                        HStack(spacing: 6) {
                            Text(s.basename)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(s.savedAge)
                                .font(.system(size: 10,
                                              design: .monospaced))
                                .foregroundStyle(Palette.textDim)
                                .frame(width: 36, alignment: .trailing)
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textFaint)
                            Text(s.backedUpAge)
                                .font(.system(size: 10,
                                              design: .monospaced))
                                .foregroundStyle(Palette.textDim)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(s.projectName)/\(s.basename).als")
                }
            }
        }
    }

    // ---- Alerts
    @ViewBuilder
    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent alerts")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textDim)
                    .textCase(.uppercase)
                Spacer()
                Button(action: { onAction(.clearAlerts) }) {
                    Text("clear")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textFaint)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Hide every alert at or before now. Audit log is preserved; new alerts after this moment still appear.")
                Button(action: { onAction(.openAlerts) }) {
                    Text("history")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textFaint)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Open the full alert history")
            }
            ForEach(snapshot.alerts.indices.prefix(3), id: \.self) { i in
                let a = snapshot.alerts[i]
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(severityColor(a.severity))
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                    Text(a.timeLabel)
                        .font(.system(size: 10, weight: .regular,
                                      design: .monospaced))
                        .foregroundStyle(Palette.textFaint)
                    Text(a.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .help(a.message)
            }
        }
    }

    private func severityColor(_ s: AlertEntry.Severity) -> Color {
        switch s {
        case .error: return Palette.error
        case .warn:  return Palette.warn
        case .info:  return Palette.info
        }
    }

    // ---- Action bar
    private var actionBar: some View {
        HStack(spacing: 6) {
            Button("Sync now") { onAction(.syncNow) }
                .buttonStyle(SmallButton(tint: Palette.accent))
            Button("Snapshots") { onAction(.openVersions) }
                .buttonStyle(SmallButton(tint: Palette.textDim))
            Button("Log") { onAction(.openLog) }
                .buttonStyle(SmallButton(tint: Palette.textDim))
            Spacer()
            Button("Quit") { onAction(.quit) }
                .buttonStyle(SmallButton(tint: Palette.textFaint))
                .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

// Upward-pointing triangle that anchors the panel to the menu bar icon.
// Drawn with a flat base and a sharp apex; same fill as the panel body
// so it reads as one piece.
struct ArrowTip: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// Compact pill button. Tints text + background based on intent.
struct SmallButton: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.25 : 0.12))
            )
            .contentShape(Rectangle())
    }
}

// =============================================================================
// MARK: - Panel controller (NSStatusItem + NSPanel)
// =============================================================================

final class PanelController: NSObject {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var statusButtonClickMonitor: Any?
    private let paths = LivesPaths.resolve()

    /// Set when Sync now is clicked. While set, status pill shows live
    /// progress (% if rclone reports it, else elapsed seconds).
    private var syncTriggeredAt: Date?
    /// Set when the lockfile clears (sync just finished). Drives a brief
    /// "Sync complete (Xs)" toast so the user sees confirmation, not just
    /// silent revert to the normal status.
    private var lastSyncFinishedAt: Date?
    private var lastSyncDurationSecs: Int = 0

    /// Parse the most recent rclone stats line from the log to get a real
    /// percentage. rclone with --stats 1s --stats-one-line emits:
    ///   ... NOTICE: Transferred:  500 MiB / 1 GiB, 50%, 50 MiB/s, ETA 5s
    /// Returns nil if no recent stats line OR the line doesn't carry a %
    /// (which happens when there's nothing to transfer - empty syncs).
    private func currentSyncProgress() -> Int? {
        guard let raw = try? String(contentsOfFile: paths.log,
                                    encoding: .utf8) else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        // Walk recent lines back-to-front; first stats line wins.
        for line in lines.suffix(60).reversed() {
            let s = String(line)
            guard s.contains("Transferred:") else { continue }
            if let r = s.range(of: #",\s*(\d+)%,"#,
                               options: .regularExpression) {
                let chunk = String(s[r])
                let digits = chunk.filter { $0.isNumber }
                return Int(digits)
            }
            // Found a transfer line but no % - means "0/0" (nothing to do).
            return nil
        }
        return nil
    }

    private func currentTransientStatus() -> String? {
        if let started = syncTriggeredAt {
            if let pct = currentSyncProgress() {
                return "Syncing… (\(pct)%)"
            }
            let secs = Int(Date().timeIntervalSince(started))
            return "Syncing… (\(secs)s)"
        }
        // Confirmation toast: 5 seconds after the sync ends, regardless of
        // whether the user reopens the panel or it stays open.
        if let done = lastSyncFinishedAt,
           Date().timeIntervalSince(done) < 5 {
            return "Sync complete (\(lastSyncDurationSecs)s) ✓"
        }
        return nil
    }

    // Tiny stderr logger - lands in ableton-lives.log via the
    // LaunchAgent's StandardErrorPath. Useful when something silently
    // fails (e.g., panel opening off-screen, hosting controller crash).
    private func logf(_ msg: String) {
        FileHandle.standardError.write(Data("[ableton-lives-menubar] \(msg)\n".utf8))
    }

    override init() {
        super.init()
        // .variableLength sizes the item to the image (22×16 here, so the
        // item lands ~22pt wide). Earlier we tried .squareLength + image
        // and clicks weren't dispatching - that combo was the culprit, not
        // the image. With .variableLength + image-only, clicks work and
        // the item still looks square in the menu bar.
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        // Persist menubar position across launches; also lets users (and
        // `defaults write`) reorder the icon out from under the notch.
        item.autosaveName = "AbletonLives"
        if let button = item.button {
            button.image = LivesIcon.template
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
            // Default behaviour: NSButton dispatches on mouseUp. DO NOT
            // call sendAction(on:) - it overrides the cell mask and can
            // swallow clicks entirely.
            logf("button wired: target set, action=togglePanel:")
            // Defer position-logging to next runloop tick - the button's
            // window isn't fully attached during init.
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let b = self.statusItem.button,
                      let win = b.window else { return }
                let inWin = b.convert(b.bounds, to: nil)
                let onScreen = win.convertToScreen(inWin)
                self.logf("button on-screen rect: \(onScreen)")
            }
        } else {
            logf("WARN: status item has no button")
        }
        statusItem = item

        // Belt-and-braces: install a local event monitor that fires when
        // a click lands inside our status item's window. This routes around
        // any target/action dispatch issues - the call is unconditional.
        statusButtonClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] event in
            guard let self = self,
                  let buttonWindow = self.statusItem.button?.window,
                  event.window === buttonWindow else { return event }
            self.logf("local-monitor click on status button window")
            self.togglePanel(nil)
            return event
        }

        logf("status item ready")
    }

    // -- Toggle main panel
    @objc func togglePanel(_ sender: Any?) {
        logf("togglePanel fired (panel currently \(panel == nil ? "closed" : "open"))")
        if panel != nil { closePanel(); return }
        openPanel()
    }

    private func openPanel() {
        let snapshot = LivesSnapshot.read(paths: paths)
        let view = StatsView(snapshot: snapshot,
                             transientStatus: currentTransientStatus()) { [weak self] action in
            self?.handle(action)
        }

        // Use NSHostingView (not NSHostingController). The controller-based
        // path needs to be added to a window before its view sizes itself,
        // which is a chicken-and-egg with creating the panel from the size.
        // NSHostingView.fittingSize works as long as we force a layout pass.
        let hostingView = NSHostingView(rootView: view)
        // Pin a width first so SwiftUI can compute a stable height.
        // 316 = 300pt content width + 8pt panel-shadow padding on each side.
        let preferredWidth: CGFloat = 316
        hostingView.frame = NSRect(x: 0, y: 0, width: preferredWidth, height: 100)
        hostingView.layoutSubtreeIfNeeded()
        let measured = hostingView.fittingSize
        let height = max(measured.height, 200)   // floor for safety
        let size = NSSize(width: preferredWidth, height: height)
        hostingView.frame = NSRect(origin: .zero, size: size)
        logf("hostingView measured=\(measured) -> using \(size)")

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.contentView = hostingView   // direct assignment, not via controller
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        positionUnder(panel: p, size: size)
        p.makeKeyAndOrderFront(nil)
        panel = p
        installClickOutsideMonitor()
        logf("panel opened at \(p.frame)")
    }

    private func closePanel() {
        panel?.orderOut(nil); panel = nil
        removeMonitor()
    }

    private func positionUnder(panel: NSPanel, size: NSSize) {
        guard let button = statusItem.button,
              let win = button.window else { return }
        let inWin = button.convert(button.bounds, to: nil)
        var onScreen = win.convertToScreen(inWin)

        // Defensive: convertToScreen has been observed to return negative-y
        // rects on macOS 14+ when the status item's window is still settling.
        // Snap to the actual menu bar of the screen the cursor is on so the
        // panel always lands somewhere visible.
        if onScreen.minY < 0,
           let screen = NSScreen.screens.first(where: {
               NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
           }) ?? NSScreen.main {
            let menubarHeight = NSStatusBar.system.thickness  // ~24pt
            // Use the cursor's x as a reasonable estimate of where the
            // user clicked (status item buttons live near the menu bar).
            let cursorX = NSEvent.mouseLocation.x
            onScreen = NSRect(
                x: cursorX - 11,                                 // half-button
                y: screen.frame.maxY - menubarHeight,
                width: 22, height: menubarHeight
            )
            logf("convertToScreen returned negative y; using fallback rect \(onScreen)")
        }

        // The arrow tip sits flush at the top of the SwiftUI view (no top
        // padding), so the panel's top edge IS the tip location. Place it
        // just below the menu bar item.
        panel.setFrameOrigin(NSPoint(
            x: onScreen.midX - size.width / 2,
            y: onScreen.minY - size.height
        ))
    }

    private func installClickOutsideMonitor() {
        removeMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.closePanel() }
    }

    private func removeMonitor() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m); eventMonitor = nil
        }
    }

    // -- Action dispatch.
    // None of these auto-close the panel. The global click-outside monitor
    // already dismisses on click outside, and "Open in Finder" actions
    // naturally shift focus (which triggers the same monitor). Letting the
    // panel persist means a Sync now / Dismiss banner / etc. doesn't yank
    // the surface out from under the user mid-interaction.
    private func handle(_ action: PanelAction) {
        switch action {
        case .syncNow:
            // Mark sync as in-flight, refresh panel immediately so the
            // user sees "Syncing…" feedback, then poll the lockfile every
            // second to update the elapsed counter. When the lockfile is
            // gone we clear the transient state and refresh once more so
            // the real "Last sync" row reflects the result.
            syncTriggeredAt = Date()
            runShell(paths.home + "/bin/lives-sync.sh")
            refreshPanel()
            scheduleSyncStatusPoll()
        case .openVersions:
            NSWorkspace.shared.open(URL(fileURLWithPath: paths.versionsDir))
        case .openLog:
            NSWorkspace.shared.open(URL(fileURLWithPath: paths.log))
        case .openAlerts:
            NSWorkspace.shared.open(URL(fileURLWithPath: paths.notifyLog))
        case .clearAlerts:
            // Write current ISO timestamp; recentAlerts() filters anything
            // at-or-before this. Audit log is left intact for forensics.
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            df.timeZone = TimeZone.current
            let stamp = df.string(from: Date())
            try? stamp.write(toFile: paths.alertsClearedAt,
                             atomically: true, encoding: .utf8)
            refreshPanel()
        case .revealCrashVersion(let path):
            NSWorkspace.shared.selectFile(
                path, inFileViewerRootedAtPath: "")
        case .dismissCrashBanner:
            try? FileManager.default.removeItem(atPath: paths.crashMarker)
            // Refresh the panel so the banner disappears without dismissal.
            refreshPanel()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// Poll the sync state every second. The lockfile-only check from the
    /// previous version was unreliable because lives-sync.sh's EXIT trap
    /// occasionally fails to fire (e.g., process killed mid-run), leaving
    /// a stale lockfile pointing at a dead PID. We now treat sync as
    /// "still running" only if BOTH the lockfile exists AND its PID is
    /// alive. Stale locks are cleaned up so the next click works.
    private func scheduleSyncStatusPoll() {
        let lockPath = "/tmp/ableton-lives-sync.lock"
        let started = syncTriggeredAt ?? Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(started)

            var stillRunning = false
            if let pidStr = try? String(contentsOfFile: lockPath,
                                        encoding: .utf8),
               let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) == 0 {
                stillRunning = true
            } else if FileManager.default.fileExists(atPath: lockPath) {
                // Lockfile present but PID dead: clean it up so future
                // sync clicks can take the lock.
                try? FileManager.default.removeItem(atPath: lockPath)
                self.logf("cleaned stale sync lockfile")
            }

            if !stillRunning || elapsed > 300 {
                // Sync just finished. Capture duration for the toast, then
                // start a 5-second "complete" indicator that shows in place
                // of the normal status pill.
                self.lastSyncDurationSecs = Int(elapsed)
                self.lastSyncFinishedAt = Date()
                self.syncTriggeredAt = nil
                self.refreshPanel()
                // One more refresh after 5s to clear the toast.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    [weak self] in
                    self?.refreshPanel()
                }
                return
            }
            self.refreshPanel()
            self.scheduleSyncStatusPoll()
        }
    }

    /// Re-read state and rebuild the panel content in place.
    private func refreshPanel() {
        guard let p = panel else { return }
        let snapshot = LivesSnapshot.read(paths: paths)
        let view = StatsView(snapshot: snapshot,
                             transientStatus: currentTransientStatus()) { [weak self] action in
            self?.handle(action)
        }
        let hostingView = NSHostingView(rootView: view)
        let preferredWidth: CGFloat = 316
        hostingView.frame = NSRect(x: 0, y: 0, width: preferredWidth, height: 100)
        hostingView.layoutSubtreeIfNeeded()
        let measured = hostingView.fittingSize
        let size = NSSize(width: preferredWidth, height: max(measured.height, 200))
        hostingView.frame = NSRect(origin: .zero, size: size)
        p.contentView = hostingView
        p.setContentSize(size)
        positionUnder(panel: p, size: size)
    }

    private func runShell(_ command: String) {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = [command]

        // The menubar app inherits whatever PATH it was launched with, which
        // typically does NOT include /opt/homebrew/bin (where rclone lives
        // on Apple Silicon). The sync LaunchAgent sets PATH explicitly in
        // its plist; we replicate that here so menubar-triggered runs see
        // the same tools.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let cur = env["PATH"], !cur.contains("/opt/homebrew/bin") {
            env["PATH"] = "\(extra):\(cur)"
        } else if env["PATH"] == nil {
            env["PATH"] = extra
        }
        task.environment = env

        do {
            try task.run()
            logf("spawned: \(command)  (pid \(task.processIdentifier))")
        } catch {
            logf("ERROR spawning \(command): \(error)")
        }
    }
}

// =============================================================================
// MARK: - App delegate + main
// =============================================================================

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PanelController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(
            Data("[ableton-lives-menubar] applicationDidFinishLaunching\n".utf8))
        controller = PanelController()
    }
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
