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
// assert the drain without a network call; the bare-init default is a
// no-op (explicit fallback for tests and isolated construction). The
// production shared cache in `WordClassTagger` is wired to
// `NovelPoolSubmitter.makeDefault()` (cookbook §2.2).
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

    // TEST-ONLY witness bookkeeping (WORDCLASS-CACHE-RACE mission,
    // 2026-07-09). `count` alone cannot prove a SPECIFIC token was
    // recorded when this instance is `sharedNovelCache` — a process-wide
    // singleton other parallel test suites also record into and drain
    // concurrently, so a before/after global-count delta is racy. These
    // two sets let a test register interest in one token (`watch`) and
    // later confirm, race-immune, whether THAT token was recorded
    // (`wasRecorded`) — regardless of whether a concurrent drain (from
    // another suite's record() calls hitting the 50-entry threshold)
    // has since removed it from `pending`. Both sets are empty unless a
    // test explicitly calls `watch(token:)`, so production behavior
    // (buffering, threshold check, submission) is completely unchanged;
    // `record()` only pays one `isEmpty` check per call when unused.
    private var watchedTokens: Set<String> = []
    private var confirmedTokens: Set<String> = []

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
        // Witness bookkeeping (see `watchedTokens` docs above): cheap
        // no-op for the overwhelmingly common case where no test is
        // watching. Marking `confirmedTokens` inside this same lock
        // acquisition — before any drain below can occur — is what
        // makes `wasRecorded` race-immune to a concurrent drain.
        if !watchedTokens.isEmpty, watchedTokens.remove(token) != nil {
            confirmedTokens.insert(token)
        }
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

    // MARK: - Test-only witness seam (WORDCLASS-CACHE-RACE, 2026-07-09)

    /// Registers `token` for witness tracking ahead of a `record` call a
    /// test expects (or expects NOT) to happen. Call this BEFORE
    /// triggering the code path under test, then read back
    /// `wasRecorded(token:)` after — never the reverse, or the
    /// registration can race the `record` call it is meant to observe.
    ///
    /// Test-only: no production call site uses this. Safe to call on
    /// `sharedNovelCache` from a parallel test suite because it only
    /// ever affects observability of the exact token string given, not
    /// buffering/threshold/submission behavior for any token.
    public func watch(token: String) {
        lock.lock()
        defer { lock.unlock() }
        watchedTokens.insert(token)
    }

    /// True if `token` was passed to `record(token:wordClass:)` at any
    /// point after `watch(token:)` registered it — regardless of
    /// whether it is still in `pending` or has already been
    /// drained/submitted by this or a concurrent call. Race-immune to
    /// concurrent drains: the witness mark is written inside the same
    /// lock acquisition `record` uses to append the entry, strictly
    /// before that call's drain check.
    public func wasRecorded(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return confirmedTokens.contains(token)
    }
}
