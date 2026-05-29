// NovelTokenCache.swift
//
// The local accumulation cache for novel-token tags (cookbook §2.2,
// §2.3, canonical §3 Step 1). When a token is not in the static
// word-class table, the platform tagger tags it and the result is
// recorded here. The cache flushes to the shared pool at exactly
// POOL_SUBMIT_THRESHOLD (50) entries and drains; entries below the
// threshold are kept indefinitely at negligible cost and are NOT aged
// or cleaned up (canonical §3 Step 1).
//
// Submission is fire-and-forget: no retry obligation, never on the hot
// path of a wordClass call's return value (it does not change the
// returned WordClass). The submitter closure is injected so tests can
// assert the drain without a network call; the default is a no-op
// until the pool endpoint is wired (cookbook §2.2).
//
// Snapshot-date purge: on ingesting a newer WordClassTable, a device
// purges accumulation predating the new table's snapshot_date
// (cookbook §1.3, §2.2; canonical §3). That purge is driven by table
// distribution (a later mission); this type owns the in-process
// accumulate-and-submit half of the cycle.

import Foundation

/// One entry in a pool submission: a token and the tag the platform
/// tagger assigned it. The `tag` is the uppercase Penn-style form
/// (`"NOUN"` / `"VERB"` / `"OTHER"`) per the wire format (cookbook
/// §2.3).
public struct PoolEntry: Equatable, Sendable, Codable {
    public let token: String
    public let tag: String

    public init(token: String, tag: String) {
        self.token = token
        self.tag = tag
    }
}

/// The pool submission wire format (cookbook §2.3). The server
/// validates `tableVersion` against the current shipping table and
/// discards submissions made against a stale table version.
public struct PoolSubmission: Equatable, Sendable, Codable {
    public let tableVersion: String
    public let platform: String
    public let taggerVersion: String
    public let entries: [PoolEntry]

    enum CodingKeys: String, CodingKey {
        case tableVersion = "table_version"
        case platform
        case taggerVersion = "tagger_version"
        case entries
    }

    public init(
        tableVersion: String,
        platform: String,
        taggerVersion: String,
        entries: [PoolEntry]
    ) {
        self.tableVersion = tableVersion
        self.platform = platform
        self.taggerVersion = taggerVersion
        self.entries = entries
    }
}

extension WordClass {
    /// The uppercase Penn-style tag string used in the pool wire
    /// format (cookbook §2.3): `.noun`→`"NOUN"`, `.verb`→`"VERB"`,
    /// `.other`→`"OTHER"`.
    var poolTag: String {
        switch self {
        case .noun: return "NOUN"
        case .verb: return "VERB"
        case .other: return "OTHER"
        }
    }
}

/// The local novel-token accumulation cache with the submit-and-purge
/// cycle (cookbook §2.2). Thread-safe: a single process-wide instance
/// is recorded into from the synchronous `wordClass` fallback path, so
/// access is guarded by a lock. Marked `@unchecked Sendable` because
/// the mutable state is protected by `lock`.
public final class NovelTokenCache: @unchecked Sendable {

    /// The novel-token cache flush trigger (cookbook §9). Pinned
    /// constant of the encoder contract — do not change without a new
    /// table version and a conformance vector regeneration.
    public static let poolSubmitThreshold = 50

    /// A pool submitter. Fire-and-forget; no retry obligation.
    public typealias Submitter = @Sendable (PoolSubmission) -> Void

    private let lock = NSLock()
    private var pending: [PoolEntry] = []

    private let tableVersion: String
    private let platform: String
    private let taggerVersion: String
    private let submitter: Submitter

    /// Creates a cache that builds submissions stamped with the given
    /// table version, platform (`"apple"` / `"other"`), and tagger
    /// version (cookbook §2.3).
    ///
    /// - Parameter submitter: invoked with the drained submission when
    ///   the cache reaches the threshold. Defaults to a no-op until the
    ///   pool endpoint is wired.
    public init(
        tableVersion: String,
        platform: String,
        taggerVersion: String,
        submitter: @escaping Submitter = { _ in }
    ) {
        self.tableVersion = tableVersion
        self.platform = platform
        self.taggerVersion = taggerVersion
        self.submitter = submitter
    }

    /// Records a tagged novel token. When the count reaches
    /// `poolSubmitThreshold` (50), the cache builds the §2.3 wire
    /// payload, drains, and hands the payload to the injected
    /// submitter — exactly at 50, not before.
    public func record(token: String, wordClass: WordClass) {
        lock.lock()
        pending.append(PoolEntry(token: token, tag: wordClass.poolTag))
        let submission: PoolSubmission?
        if pending.count >= Self.poolSubmitThreshold {
            submission = PoolSubmission(
                tableVersion: tableVersion,
                platform: platform,
                taggerVersion: taggerVersion,
                entries: pending
            )
            pending.removeAll(keepingCapacity: true)
        } else {
            submission = nil
        }
        lock.unlock()

        // Submit outside the lock: fire-and-forget, off the caller's
        // critical section.
        if let submission {
            submitter(submission)
        }
    }

    /// The number of entries currently held below the threshold.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}
