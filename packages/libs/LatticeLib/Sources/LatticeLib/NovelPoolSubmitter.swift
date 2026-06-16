// NovelPoolSubmitter.swift
//
// The real pool submitter: writes each PoolSubmission as a dated JSON file
// into a local directory so the (future) pool-reducer process can consume it
// (cookbook §2.2, §2.3).
//
// DESIGN: The cookbook states the pool endpoint is a config value and
// submission is fire-and-forget with no retry obligation. The reducer that
// consumes these files (`PoolReducer.reduce`) is driven on a low cadence by
// the resident Autonomic Governor (packages/kits/AriaMcpKit). The durable landing zone is
// a local directory configured via:
//   1. LATTICE_POOL_DIR environment variable (takes priority).
//   2. Application Support/com.mootx01.lattice/pool/ on Apple platforms.
//   3. XDG_DATA_HOME/mootx01/lattice/pool/ (or ~/.local/share/...) elsewhere.
//
// Terminal state: token drained → JSON file written to pool directory →
// file observable at endpoint → future pool-reducer consumes files and
// merges novel tokens back into the WordClassTable.
//
// Use in production: call `NovelPoolSubmitter.make()` to get a Submitter
// closure that writes files to the resolved pool directory. Wire it into
// NovelTokenCache at construction time.
//
// Test / embedded-host fallback: call `NovelTokenCache(... submitter: { _ in })`
// (the default no-op) — documented explicitly so future agents know the
// no-op is intentional there, not a bug.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "LatticeLib")

/// Factory for the production novel-token pool submitter (cookbook §2.2).
///
/// Each drained `PoolSubmission` is serialised as a JSON file in the
/// configured pool directory. File names are `pool_<ISO8601 timestamp>.json`
/// so the future pool-reducer can process them in chronological order without
/// a database.
///
/// Submission is fire-and-forget: if the directory cannot be created or the
/// write fails, the failure is logged at `error` level and the token data is
/// discarded for this drain cycle. No retry. No crash.
public enum NovelPoolSubmitter {

    /// Returns a `Submitter` closure that writes pool payloads to
    /// `poolDirectory` as individual JSON files.
    ///
    /// - Parameter poolDirectory: the directory that receives pool files.
    ///   Must be writable. Created lazily on first submission.
    /// - Returns: a `@Sendable` closure suitable for
    ///   `NovelTokenCache.init(tableVersion:platform:taggerVersion:submitter:)`.
    public static func make(poolDirectory: URL) -> NovelTokenCache.Submitter {
        return { @Sendable submission in
            writeSubmission(submission, to: poolDirectory)
        }
    }

    /// Returns a `Submitter` that writes to the process-resolved default pool
    /// directory:
    ///   1. `LATTICE_POOL_DIR` env var, if set.
    ///   2. `Application Support/com.mootx01.lattice/pool/` (Apple platforms).
    ///   3. `XDG_DATA_HOME/mootx01/lattice/pool/` or
    ///      `~/.local/share/mootx01/lattice/pool/` (non-Apple).
    ///
    /// Resolves the directory once and captures it in the closure.
    public static func makeDefault() -> NovelTokenCache.Submitter {
        let dir = resolvePoolDirectory()
        return make(poolDirectory: dir)
    }

    // MARK: - Path resolution (public — consumed by the Autonomic Governor)

    /// Resolves the pool directory from environment or platform default.
    ///
    ///   1. `LATTICE_POOL_DIR` env var, if set and non-empty.
    ///   2. `Application Support/com.mootx01.lattice/pool/` (Apple platforms).
    ///   3. `XDG_DATA_HOME/mootx01/lattice/pool/` or
    ///      `~/.local/share/mootx01/lattice/pool/` (non-Apple).
    ///
    /// Public so the resident Autonomic Governor can resolve the same directory
    /// the submitter writes to when it drives `PoolReducer.reduce`. The
    /// submitter (write side) and the reducer trigger (read side) MUST agree on
    /// this path, so it lives here as the single source of truth.
    public static func poolDirectory() -> URL {
        resolvePoolDirectory()
    }

    /// Resolves the writable WordClassTable artifact the reducer merges into.
    ///
    /// This is the SIBLING of the pool directory — `WordClassTable.json` in the
    /// pool dir's parent (the `…/lattice/` root). It is the writable artifact
    /// `PoolReducer.reduce` updates in place; it is NOT the read-only bundled
    /// `Resources/WordClassTable.json` that `WordClassTable.loadBundled` reads.
    /// The reducer cannot write into the app bundle, so the merged artifact
    /// lands here for a future table load to consume (cookbook §1.3/§2.2: the
    /// table is a pinned snapshot; the reducer produces the next snapshot).
    ///
    /// Override the whole location with `LATTICE_POOL_DIR` (the artifact then
    /// sits beside that directory).
    public static func tableArtifactURL() -> URL {
        // The pool dir is `…/lattice/pool`; the artifact is `…/lattice/WordClassTable.json`.
        resolvePoolDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("WordClassTable.json", isDirectory: false)
    }

    // MARK: - Internal

    /// Writes one pool submission as a JSON file into `directory`.
    /// File name: `pool_<ISO8601>_<UUID short>.json` to avoid collisions
    /// when multiple processes write concurrently.
    static func writeSubmission(_ submission: PoolSubmission, to directory: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let timestamp = ISO8601DateFormatter().string(from: Date())
            // Sanitize: ISO8601 colons are illegal on some file systems.
            let safe = timestamp.replacingOccurrences(of: ":", with: "-")
            let shortID = UUID().uuidString.prefix(8)
            let name = "pool_\(safe)_\(shortID).json"
            let dest = directory.appendingPathComponent(name)
            let data = try JSONEncoder().encode(submission)
            try data.write(to: dest, options: .atomic)
            log.debug(
                "novel pool: wrote \(submission.entries.count) entries to \(dest.lastPathComponent)"
            )
        } catch {
            // Fire-and-forget: log and discard. Never crash. The token data is
            // lost for this drain cycle; it will be re-collected from future
            // novel-token observations.
            log.error("novel pool: write failed — \(error.localizedDescription)")
        }
    }

    /// Resolves the pool directory from environment or platform default.
    static func resolvePoolDirectory() -> URL {
        if let envDir = ProcessInfo.processInfo.environment["LATTICE_POOL_DIR"],
           !envDir.isEmpty {
            return URL(fileURLWithPath: envDir, isDirectory: true)
        }
        #if canImport(AppKit) || canImport(UIKit)
        // Apple platforms: Application Support container.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("com.mootx01.lattice/pool", isDirectory: true)
        #else
        // Non-Apple: XDG_DATA_HOME or ~/.local/share
        let dataHome: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            dataHome = xdg
        } else {
            dataHome = "\(NSHomeDirectory())/.local/share"
        }
        return URL(fileURLWithPath: dataHome)
            .appendingPathComponent("mootx01/lattice/pool", isDirectory: true)
        #endif
    }
}
