// WordClassTable.swift
//
// The noun/verb fast-path table loaded from the committed reference
// data at Resources/WordClassTable.json (cookbook §1.3). A token
// present in this table is resolved to its WordClass in constant time
// with no platform tagger invoked — the fast path that covers the vast
// majority of tokens (cookbook §2.1).
//
// The table is produced at Seed-Generator time (cookbook §7.3) by
// running NLTagger over a large Wikipedia corpus and recording the
// deduplicated, lowercased noun and verb sets. LatticeLib only reads
// the pinned snapshot; it never tags at table-build scale itself.
//
// WRITABLE-ARTIFACT LOAD PRECEDENCE (cookbook §1.3/§2.2)
// The PoolReducer merges novel-token observations into a writable copy
// of the table at `NovelPoolSubmitter.tableArtifactURL()`.
// `WordClassTable.loadWithPrecedence()` checks that path first; if a
// merged artifact is present it is used, otherwise the bundled pristine
// table is the fallback.
//
// LIVE ATOMIC SWAP (cookbook §1.3/§2.2)
// `WordClassTableCache` is the process-wide swappable holder of the
// current parsed table and its derived membership sets. The initial
// snapshot is loaded once via `loadWithPrecedence()`. After the
// PoolReducer merges novel tokens into the writable artifact, the
// running process adopts the new table IN-SESSION via
// `WordClassTableCache.swap(_:)` — a thread-safe atomic publish behind a
// lock, version-tracked, with no torn reads (a reader copies the whole
// immutable snapshot out under the lock, releases, then tests
// membership; the snapshot is never mutated in place). No process
// restart is required. Tagging stays deterministic given
// (input, table-version).

import Foundation

/// The parsed word-class table with its pinned versioning metadata
/// (cookbook §1.3 schema). Byte-identical shape to the Rust port's
/// `WordClassTable` struct so both legs parse the same JSON.
public struct WordClassTable: Sendable, Codable {

    /// The table version. Pinned; it gates pool submission — the
    /// server discards submissions whose `table_version` does not
    /// match the current shipping table (cookbook §2.3).
    public let tableVersion: String

    /// The NLTagger OS version that produced this table (cookbook
    /// §1.3). A pinned parameter of the encoder contract: builds
    /// targeting an OS below this version use the table only and do
    /// not invoke an older tagger (cookbook §2.2).
    public let minOSVersion: String

    /// The cutoff date for local pool-cache purge on table update
    /// (cookbook §1.3, §2.2). On ingesting a newer table, a device
    /// purges accumulated novel tokens predating this date; they are
    /// retagged on next encounter.
    public let snapshotDate: String

    /// The lowercased noun surface forms.
    public let nouns: [String]

    /// The lowercased verb surface forms.
    public let verbs: [String]

    /// Public memberwise initializer so callers (and the live-swap path) can
    /// construct a table value — e.g. to publish a derived snapshot via
    /// `WordClassTableCache.swap(_:)` — without going through JSON decoding.
    public init(
        tableVersion: String,
        minOSVersion: String,
        snapshotDate: String,
        nouns: [String],
        verbs: [String]
    ) {
        self.tableVersion = tableVersion
        self.minOSVersion = minOSVersion
        self.snapshotDate = snapshotDate
        self.nouns = nouns
        self.verbs = verbs
    }

    enum CodingKeys: String, CodingKey {
        case tableVersion = "table_version"
        case minOSVersion = "min_os_version"
        case snapshotDate = "snapshot_date"
        case nouns
        case verbs
    }
}

extension WordClassTable {
    /// Loads the table from the module's bundled resource at
    /// Resources/WordClassTable.json. Returns nil if the resource is
    /// missing or malformed; production code should treat that as a
    /// build error since the JSON ships with the kit.
    public static func loadBundled() -> WordClassTable? {
        guard let url = Bundle.module.url(
            forResource: "WordClassTable",
            withExtension: "json"
        ) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(
            WordClassTable.self,
            from: data
        )
    }

    /// Loads the writable artifact produced by `PoolReducer.reduce`,
    /// located at `NovelPoolSubmitter.tableArtifactURL()`. Returns nil
    /// if the file does not exist (no reduce run has occurred yet) or
    /// if it is malformed. Callers must fall back to `loadBundled()`.
    ///
    /// Prefer `loadWithPrecedence()` over calling this directly; it
    /// handles the fallback automatically and is the canonical load
    /// path for the `WordClassTableCache` holder.
    public static func loadWritable() -> WordClassTable? {
        let url = NovelPoolSubmitter.tableArtifactURL()
        // Fail closed on a relative artifact path — parity with the Rust
        // `load_writable_table` guard. This table takes precedence over the
        // bundled one and seeds the process-global classifier, so a
        // CWD-relative path would let anyone who can influence the working
        // directory plant a WordClassTable.json and steer classification.
        guard url.path.hasPrefix("/") else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(WordClassTable.self, from: data)
    }

    /// Returns the best available table for this process, implementing
    /// writable-artifact load precedence (cookbook §1.3/§2.2):
    ///   1. Writable merged artifact at `tableArtifactURL()`, if present.
    ///   2. Bundled pristine resource, as fallback.
    ///
    /// Used to seed the initial `WordClassTableCache` snapshot at
    /// process start, and again by the live-swap path to re-resolve the
    /// table after the reducer writes a merged artifact. This is the
    /// canonical load path — do not call `loadBundled` or `loadWritable`
    /// directly for cache population.
    ///
    /// A table written by the reducer during this process's lifetime is
    /// adopted IN-SESSION via `WordClassTableCache.swap(_:)` (live atomic
    /// swap, cookbook §1.3/§2.2); it is also picked up by the
    /// loadWithPrecedence seed on any future process start. Both paths
    /// resolve the same writable-first precedence.
    public static func loadWithPrecedence() -> WordClassTable? {
        // Check the writable artifact first. If present and parseable,
        // this is a previously-merged table from PoolReducer.reduce —
        // it contains learned tokens beyond the bundled pristine table.
        if let merged = loadWritable() {
            return merged
        }
        // No merged artifact yet: fall back to the bundled pristine table.
        return loadBundled()
    }
}

/// One immutable snapshot of the word-class table and its derived
/// membership sets. A snapshot is never mutated in place; a live swap
/// publishes a NEW snapshot, so a reader that has copied the snapshot
/// reference out cannot observe a torn read.
///
/// The noun and verb membership sets are `Set<String>` of lowercased
/// tokens, giving constant-time fast-path lookup (cookbook §2.1).
final class WordClassTableSnapshot: Sendable {
    /// The parsed table, or nil on a corrupted install.
    let table: WordClassTable?
    /// Lowercased noun surface forms for constant-time membership.
    let nounSet: Set<String>
    /// Lowercased verb surface forms for constant-time membership.
    let verbSet: Set<String>

    init(table: WordClassTable?) {
        self.table = table
        self.nounSet = Set(table?.nouns ?? [])
        self.verbSet = Set(table?.verbs ?? [])
    }
}

/// The process-wide, LIVE-SWAPPABLE holder of the current word-class
/// table snapshot (cookbook §1.3/§2.2).
///
/// SEED: the initial snapshot is resolved once via
/// `WordClassTable.loadWithPrecedence()` (writable merged artifact if a
/// prior reduce ran, else the bundled pristine table).
///
/// LIVE ATOMIC SWAP: after `PoolReducer.reduce` merges novel tokens into
/// the writable artifact, the running process calls `swap(_:)` (or
/// `reloadFromPrecedence()`) to adopt the new table IN-SESSION — no
/// process restart. The swap is a single locked publish of a new
/// immutable `WordClassTableSnapshot` plus a version bump. Readers
/// (`current`, `nounSet`, `verbSet`, `table`) take the lock only long
/// enough to copy the snapshot reference out, then test membership
/// against the immutable snapshot outside the lock — no torn read, and
/// concurrent reads never block each other for longer than a reference
/// copy.
///
/// The `static let`-shaped accessors (`table`, `nounSet`, `verbSet`) are
/// retained so the tagger fast-path call sites read the LIVE snapshot
/// transparently. The swap API (`swap`, `reloadFromPrecedence`, `version`) is
/// public so the resident Autonomic Governor can publish the live swap at its
/// post-reduce safe point.
public enum WordClassTableCache {

    /// Guards the current snapshot and the version counter. A plain lock
    /// is sufficient: reads copy a class reference out and release; the
    /// publish replaces the whole reference. There is no read-modify-write
    /// on shared mutable state inside the critical section.
    nonisolated(unsafe) private static var lock = os_unfair_lock()

    /// The live snapshot. `nonisolated(unsafe)` because all access is
    /// serialised through `lock`; Swift cannot verify the lock discipline
    /// statically.
    nonisolated(unsafe) private static var snapshot =
        WordClassTableSnapshot(table: WordClassTable.loadWithPrecedence())

    /// Monotonic version counter, bumped on every successful swap. Starts
    /// at 0 for the seed snapshot. Exposed so callers/tests can observe
    /// that a live swap happened and so tagging determinism can be keyed
    /// on (input, table-version) — see `WordClassTagger`.
    nonisolated(unsafe) private static var versionCounter: UInt64 = 0

    /// The current immutable snapshot. Copies the reference out under the
    /// lock, then returns it; membership tests run on the returned
    /// snapshot outside the lock.
    static var current: WordClassTableSnapshot {
        os_unfair_lock_lock(&lock)
        let s = snapshot
        os_unfair_lock_unlock(&lock)
        return s
    }

    /// The current parsed table (live).
    static var table: WordClassTable? { current.table }

    /// Lowercased noun surface forms for constant-time membership (live).
    static var nounSet: Set<String> { current.nounSet }

    /// Lowercased verb surface forms for constant-time membership (live).
    static var verbSet: Set<String> { current.verbSet }

    /// The current live-swap version. 0 is the seed snapshot; each
    /// successful `swap`/`reloadFromPrecedence` increments it.
    public static var version: UInt64 {
        os_unfair_lock_lock(&lock)
        let v = versionCounter
        os_unfair_lock_unlock(&lock)
        return v
    }

    /// Atomically publish a new table snapshot IN-SESSION and bump the
    /// version. The running tagger adopts the new membership sets on its
    /// next `wordClass` call. Safe to call from the governor's post-reduce
    /// safe point while taggers read concurrently — readers either see the
    /// old whole snapshot or the new whole snapshot, never a mix.
    public static func swap(_ newTable: WordClassTable?) {
        let next = WordClassTableSnapshot(table: newTable)
        os_unfair_lock_lock(&lock)
        snapshot = next
        versionCounter &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// Re-resolve the table via `loadWithPrecedence()` (writable-first, using
    /// `NovelPoolSubmitter.tableArtifactURL()`) and publish it as the new live
    /// snapshot. Returns the new version. Use this when the reducer wrote to the
    /// default artifact path.
    @discardableResult
    public static func reloadFromPrecedence() -> UInt64 {
        swap(WordClassTable.loadWithPrecedence())
        return version
    }

    /// Re-resolve the table from a SPECIFIC writable artifact URL (writable-
    /// first, bundled fallback) and publish it as the new live snapshot. This is
    /// the canonical post-reduce swap when the caller drove the reduce into an
    /// explicit artifact path (e.g. the resident governor's configured
    /// `poolTableArtifactURL`): re-resolving from that exact path picks up the
    /// just-merged tokens so the running tagger learns them in-session. Returns
    /// the new version. Falls back to the bundled table if the artifact is
    /// absent/malformed/relative (never publishes an empty table over a good one
    /// silently — a missing artifact yields the bundled pristine set).
    ///
    /// The leading absolute-path test is the same guard `loadWritable()` applies.
    /// This path decodes the caller's URL directly rather than going through
    /// `loadWritable()`, so without it the live in-session swap would still adopt
    /// a table from a CWD-relative path that the startup seed already refuses.
    @discardableResult
    public static func reload(fromArtifact artifactURL: URL) -> UInt64 {
        let resolved: WordClassTable?
        if artifactURL.path.hasPrefix("/"),
           FileManager.default.fileExists(atPath: artifactURL.path),
           let data = try? Data(contentsOf: artifactURL),
           let merged = try? JSONDecoder().decode(WordClassTable.self, from: data) {
            resolved = merged
        } else {
            resolved = WordClassTable.loadBundled()
        }
        swap(resolved)
        return version
    }
}
