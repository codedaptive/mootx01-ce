// NovelPoolSubmitter.swift
//
// The real pool submitter: writes each PoolSubmission as a dated JSON file
// into a local directory for the pool-reducer (`PoolReducer.reduce`) to
// consume (cookbook §2.2, §2.3).
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
// PARITY, exactly: the Rust port agrees on Apple and only on Apple. A Mac runs
// both ports, so both must reduce into one writable WordClassTable.json or
// learned word-class rows diverge while the bundled artifacts and input bytes
// match. Swift ships no Linux or Windows target, so on those platforms Rust
// resolves the pool inside the install's own base directory instead
// (<configuration>/lattice/pool) and there is no Swift path to compare. The
// two rules are `applePoolDirectory` and `configuredPoolDirectory` below,
// pinned by NovelPoolSubmitterTests against the Rust twins
// `apple_pool_directory` and `configured_pool_directory`.
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
import MootProductIdentity
import OSLog

private let log = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "LatticeLib")

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
    /// Maximum pool files before new submissions are discarded. Each file is
    /// one drain cycle's worth of novel tokens (~50 entries, a few KB). 500
    /// files ≈ 25k entries ≈ a few MB — generous for any realistic estate
    /// while preventing unbounded disk growth from sustained injection (#45).
    static let maxPoolFiles = 500

    static func writeSubmission(_ submission: PoolSubmission, to directory: URL) {
        // Enforcement point for the trusted-location rule — parity with the
        // Rust `write_submission` guard. Pool files carry plaintext novel
        // tokens; a relative directory resolves against the process working
        // directory, which the process does not own. Fire-and-forget: log and
        // discard, never throw.
        guard directory.path.hasPrefix("/") else {
            log.error("novel pool: refusing relative pool dir \(directory.path); submission discarded")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            // Cap check: count existing pool files and skip if at capacity.
            let existing = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.count ?? 0
            if existing >= maxPoolFiles {
                log.warning("novel pool: \(existing) files at cap (\(maxPoolFiles)); discarding submission until reducer drains")
                return
            }
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

    /// The folder that holds the pool and the merged table inside an
    /// install's own base directory, on the platforms that resolve it that
    /// way. Distinct from `MootProductIdentity.Storage.latticeFolder`
    /// (`com.mootx01.lattice`): that one sits BESIDE the install's folder
    /// under Application Support, because on Apple the pool is machine-wide,
    /// shared across installs. Twin of Rust
    /// `CONFIGURATION_LATTICE_FOLDER`.
    static let configurationLatticeFolder = "lattice"

    /// The pool folder inside whichever lattice folder applies. Twin of Rust
    /// `POOL_FOLDER`.
    static let poolFolder = "pool"

    /// The Apple rule: `<Application Support>/com.mootx01.lattice/pool`. Pure
    /// path arithmetic; touches nothing. Twin of Rust
    /// `apple_pool_directory(application_support)`, which both ports resolve
    /// to the same bytes on a Mac.
    static func applePoolDirectory(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent(MootProductIdentity.Storage.latticeFolder, isDirectory: true)
            .appendingPathComponent(poolFolder, isDirectory: true)
    }

    /// The rule for a platform that keeps the pool inside the install's own
    /// base directory: `<configuration>/lattice/pool`. Pure path arithmetic.
    /// Twin of Rust `configured_pool_directory(configuration_directory)`,
    /// which is what the Rust port resolves on Linux and Windows.
    static func configuredPoolDirectory(configurationDirectory: URL) -> URL {
        configurationDirectory
            .appendingPathComponent(configurationLatticeFolder, isDirectory: true)
            .appendingPathComponent(poolFolder, isDirectory: true)
    }

    /// The non-Apple base directory: `${XDG_DATA_HOME:-<home>/.local/share}/
    /// mootx01`. The folder name is the product identity's `unixDataFolder`,
    /// the same value the Rust port's configuration directory uses on Linux,
    /// so the two ports name one directory rather than two spellings of it.
    static func unixConfigurationDirectory(dataHome: URL) -> URL {
        dataHome.appendingPathComponent(
            MootProductIdentity.Storage.unixDataFolder, isDirectory: true)
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
        return applePoolDirectory(applicationSupport: appSupport)
        #else
        // Non-Apple: XDG_DATA_HOME or ~/.local/share
        let dataHome: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            dataHome = xdg
        } else {
            dataHome = "\(NSHomeDirectory())/.local/share"
        }
        return configuredPoolDirectory(
            configurationDirectory: unixConfigurationDirectory(
                dataHome: URL(fileURLWithPath: dataHome, isDirectory: true)))
        #endif
    }
}
