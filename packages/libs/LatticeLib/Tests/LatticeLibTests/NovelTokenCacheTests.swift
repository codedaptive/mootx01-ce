// NovelTokenCacheTests.swift
//
// Tests for NovelTokenCache, PoolEntry, PoolSubmission, and the WordClass pool
// tag extension (cookbook §2.2, §2.3, canonical §3 Step 1).
//
// These tests are the canonical behavioral specification for the submit-and-purge
// cycle. The Rust port (novel_token_cache.rs) mirrors this suite with identical
// test semantics so both ports are verified against the same contract.

import Foundation
import Testing
@testable import LatticeLib

// ─── Thread-safe submission collector ────────────────────────────────────────
//
// The NovelTokenCache.Submitter closure is @Sendable (required because
// NovelTokenCache is @unchecked Sendable and captures it). To record
// submissions from inside that closure, we use a lock-protected collector.
// Marked @unchecked Sendable because the mutable state is protected by NSLock.

private final class SubmissionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _submissions: [PoolSubmission] = []

    func append(_ s: PoolSubmission) {
        lock.lock(); defer { lock.unlock() }
        _submissions.append(s)
    }

    var submissions: [PoolSubmission] {
        lock.lock(); defer { lock.unlock() }
        return _submissions
    }

    var count: Int { submissions.count }
}

// ─── PoolEntry ────────────────────────────────────────────────────────────────

@Suite("PoolEntry")
struct PoolEntryTests {

    @Test("fields stored correctly")
    func fieldsStoredCorrectly() {
        let entry = PoolEntry(token: "running", tag: "VERB")
        #expect(entry.token == "running")
        #expect(entry.tag == "VERB")
    }

    @Test("equality")
    func equality() {
        let a = PoolEntry(token: "dog", tag: "NOUN")
        let b = PoolEntry(token: "dog", tag: "NOUN")
        #expect(a == b)
        let c = PoolEntry(token: "cat", tag: "NOUN")
        #expect(a != c)
    }

    @Test("codable round-trip")
    func codableRoundTrip() throws {
        let entry = PoolEntry(token: "cat", tag: "NOUN")
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(PoolEntry.self, from: data)
        #expect(back == entry)
    }
}

// ─── PoolSubmission ───────────────────────────────────────────────────────────

@Suite("PoolSubmission")
struct PoolSubmissionTests {

    @Test("fields stored correctly")
    func fieldsStoredCorrectly() {
        let entries = [PoolEntry(token: "dog", tag: "NOUN")]
        let sub = PoolSubmission(
            tableVersion: "v1.0",
            platform: "apple",
            taggerVersion: "15.0.0",
            entries: entries
        )
        #expect(sub.tableVersion == "v1.0")
        #expect(sub.platform == "apple")
        #expect(sub.taggerVersion == "15.0.0")
        #expect(sub.entries == entries)
    }

    @Test("JSON round-trip uses snake_case keys (CodingKeys contract)")
    func jsonRoundTripUsesSnakeCaseKeys() throws {
        // The CodingKeys enum maps tableVersion -> table_version,
        // taggerVersion -> tagger_version. Verify the wire format matches.
        let entries = [PoolEntry(token: "run", tag: "VERB")]
        let sub = PoolSubmission(
            tableVersion: "v2.0",
            platform: "other",
            taggerVersion: "hmm-viterbi-stub-0",
            entries: entries
        )
        let data = try JSONEncoder().encode(sub)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"table_version\""))
        #expect(json.contains("\"tagger_version\""))
        let back = try JSONDecoder().decode(PoolSubmission.self, from: data)
        #expect(back == sub)
    }
}

// ─── WordClass.poolTag ────────────────────────────────────────────────────────

@Suite("WordClass.poolTag")
struct WordClassPoolTagTests {

    @Test(".noun maps to NOUN")
    func nounMapsToNOUN() {
        #expect(WordClass.noun.poolTag == "NOUN")
    }

    @Test(".verb maps to VERB")
    func verbMapsToVERB() {
        #expect(WordClass.verb.poolTag == "VERB")
    }

    @Test(".other maps to OTHER")
    func otherMapsToOTHER() {
        #expect(WordClass.other.poolTag == "OTHER")
    }
}

// ─── NovelTokenCache ──────────────────────────────────────────────────────────

@Suite("NovelTokenCache (cookbook §2.2)")
struct NovelTokenCacheTests {

    @Test("count is zero on init")
    func countIsZeroOnInit() {
        let cache = NovelTokenCache(
            tableVersion: "v1",
            platform: "apple",
            taggerVersion: "15.0.0"
        )
        #expect(cache.count == 0)
    }

    @Test("accumulates below threshold without submitting")
    func accumulatesBelowThresholdWithoutSubmitting() {
        let collector = SubmissionCollector()
        let cache = NovelTokenCache(
            tableVersion: "v1",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: { collector.append($0) }
        )
        // Record 49 tokens — one below the threshold.
        for i in 0..<49 {
            cache.record(token: "noveltoken\(i)", wordClass: .other)
        }
        #expect(cache.count == 49)
        #expect(collector.count == 0, "no submission must occur before reaching the threshold")
    }

    @Test("POOL_SUBMIT_THRESHOLD is 50")
    func poolSubmitThresholdIs50() {
        #expect(NovelTokenCache.poolSubmitThreshold == 50)
    }

    @Test("drains at exactly 50 entries")
    func drainsAtExactlyFiftyEntries() {
        let collector = SubmissionCollector()
        let cache = NovelTokenCache(
            tableVersion: "v1.0",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: { collector.append($0) }
        )
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "token\(i)", wordClass: .other)
        }
        #expect(cache.count == 0, "pending must be empty after draining")
        #expect(collector.count == 1, "submitter must be called exactly once at threshold")
        #expect(collector.submissions[0].entries.count == NovelTokenCache.poolSubmitThreshold)
    }

    @Test("submission carries correct metadata")
    func submissionCarriesCorrectMetadata() {
        let collector = SubmissionCollector()
        let cache = NovelTokenCache(
            tableVersion: "v2.0",
            platform: "apple",
            taggerVersion: "16.1.0",
            submitter: { collector.append($0) }
        )
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "w\(i)", wordClass: .verb)
        }
        let sub = collector.submissions[0]
        #expect(sub.tableVersion == "v2.0")
        #expect(sub.platform == "apple")
        #expect(sub.taggerVersion == "16.1.0")
        // Every entry should carry the VERB tag.
        #expect(sub.entries.allSatisfy { $0.tag == "VERB" })
    }

    @Test("resets and accumulates again after drain")
    func resetsAndAccumulatesAgainAfterDrain() {
        let collector = SubmissionCollector()
        let cache = NovelTokenCache(
            tableVersion: "v1",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: { collector.append($0) }
        )
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "batch1_\(i)", wordClass: .noun)
        }
        #expect(collector.count == 1)
        #expect(cache.count == 0)
        // Second batch should accumulate fresh.
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "batch2_\(i)", wordClass: .other)
        }
        #expect(collector.count == 2)
        #expect(cache.count == 0)
    }

    @Test("entries below threshold are preserved across records")
    func entriesBelowThresholdPreservedAcrossRecords() {
        let collector = SubmissionCollector()
        let cache = NovelTokenCache(
            tableVersion: "v1",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: { collector.append($0) }
        )
        cache.record(token: "alpha", wordClass: .noun)
        cache.record(token: "beta", wordClass: .verb)
        #expect(cache.count == 2)
        // Fill up to the threshold with remaining entries.
        for i in 0..<(NovelTokenCache.poolSubmitThreshold - 2) {
            cache.record(token: "filler\(i)", wordClass: .other)
        }
        #expect(collector.count == 1)
        // The first two entries in the submission must be alpha/beta in order.
        let sub = collector.submissions[0]
        #expect(sub.entries[0].token == "alpha")
        #expect(sub.entries[0].tag == "NOUN")
        #expect(sub.entries[1].token == "beta")
        #expect(sub.entries[1].tag == "VERB")
    }

    @Test("default submitter is a no-op (does not crash)")
    func defaultSubmitterIsNoOp() {
        // A cache created without an explicit submitter uses the default no-op.
        // Filling it to the threshold must not crash.
        let cache = NovelTokenCache(
            tableVersion: "v1",
            platform: "apple",
            taggerVersion: "15.0.0"
        )
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "x\(i)", wordClass: .other)
        }
        // After drain, count resets.
        #expect(cache.count == 0)
    }
}
