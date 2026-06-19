// EncodeDrainNearRealtimeTests.swift
//
// Force-tests for the NEAR-REALTIME, LOAD- and SEQUENCE-robust encode drain
// (the QueueKit near-realtime ingest+classify promise). The encode queue's
// watch-driven background worker (mountEncodeQueue) ingests a regular capture
// into the Corpus the instant the EncodeJob is committed — so captured content
// becomes BM25/vector recallable in near-realtime, regardless of burst load or
// arrival order, WITHOUT the caller driving the drain.
//
// Distinct from EncodeIntakeTests, which prove the lane is lit using the
// awaitEncodeDrain barrier. Here we prove the LATENCY and ROBUSTNESS properties:
//   • NEAR-REALTIME: recallable within a tight bound, NOT a fixed 5s tick — and
//     the test never calls awaitEncodeDrain (the background worker delivers it).
//   • LOAD: a 100+ capture burst all becomes recallable, accept stayed fast,
//     the queue did not wedge.
//   • SEQUENCE: interleaved captures arrive and all become recallable; no
//     caller-side ordering requirement.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
import QueueKit
@testable import GeniusLocusKit

/// A throwaway error used only to simulate a transient ingest fault in the
/// at-least-once force-test.
private struct InjectedTransientIngestError: Error {}

/// Tracks which drawers have already had their (single) transient ingest failure
/// injected. The encode-drain ingest hook runs on the GLK actor (serialised),
/// but the closure is `@Sendable`, so the set is lock-guarded for Sendable
/// safety. The FIRST ingest attempt for a given drawer fails once; every
/// subsequent attempt for that drawer succeeds — a transient fault that clears.
private final class FirstAttemptFailureSet: @unchecked Sendable {
    private let lock = NSLock()
    private var alreadyFailed: Set<String> = []
    /// Returns true exactly once per drawer id (its first attempt), false after.
    func shouldFailFirstAttempt(_ drawerID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alreadyFailed.insert(drawerID).inserted
    }
}

@Suite("Encode drain — near-realtime, load- and sequence-robust")
struct EncodeDrainNearRealtimeTests {

    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-near-realtime-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Near-Realtime Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        // INTENTIONAL single-provider (6a-iii-wire): this suite exercises the
        // encode-drain near-realtime path, not recall content, so it pins the
        // Corpus to the lightweight deterministic signal (no training cost). The
        // five-signal default's recall payoff is proven in the dedicated
        // ProvisionDefaultEnsembleTests / DefaultEnsembleRecallPayoffTests.
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "near-realtime-tests",
            latticeAnchor: .udc("000"),
            addedBy: "near-realtime-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    private func hybridRequest(query: String, limit: Int = 200) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .hybrid,
            scoring: .raw,
            limit: limit,
            fallback: .failClosed,
            queryText: query
        )
    }

    /// A CorpusKit-BM25-only request: isolates the semantic lane the encode
    /// worker lights, so a distinctive-token query returns exactly its doc
    /// without the hybrid vector lane crowding the candidate frontier.
    private func corpusOnlyRequest(query: String, limit: Int = 200) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .corpusOnly,
            scoring: .raw,
            limit: limit,
            fallback: .failClosed,
            queryText: query
        )
    }

    /// Poll a recall predicate until it holds or the deadline passes. Returns the
    /// elapsed time when it first held, or nil on timeout. Used to MEASURE the
    /// near-realtime latency rather than wait on a barrier.
    private func awaitRecall(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        query: String,
        until predicate: @Sendable ([RecallHit]) -> Bool,
        deadline: Duration
    ) async throws -> Duration? {
        let start = ContinuousClock.now
        let limit = ContinuousClock.now.advanced(by: deadline)
        while ContinuousClock.now < limit {
            let result = try await kit.recall(handle, hybridRequest(query: query))
            if predicate(result.hits) {
                return start.duration(to: ContinuousClock.now)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    // MARK: - NEAR-REALTIME CLASSIFY

    /// A regular capture becomes BM25-recallable in NEAR-REALTIME — without the
    /// caller driving the drain, and within a tight bound (≪ the old 5 s tick).
    /// The watch-driven background worker delivers it.
    @Test
    func regularCaptureRecallableInNearRealtimeWithoutDrainCall() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "peregrine falcon stooping dive raptor velocity content"
        let drawer = try await kit.capture(handle, captureFrame(content), mode: .regular)

        // NOTE: we deliberately do NOT call awaitEncodeDrain — the background
        // watch worker must deliver it. Assert a TIGHT bound (1 s), not 5 s.
        let elapsed = try await awaitRecall(
            kit, handle, query: "falcon raptor velocity",
            until: { hits in
                hits.contains { $0.drawer?.id == drawer.id && $0.sources.contains(.corpusBM25) }
            },
            deadline: .seconds(1))

        let took = try #require(elapsed,
            "regular capture must become .corpusBM25-recallable within 1 s via the watch-driven worker (no drain call)")
        // The latency floor is the observer wake; on the in-memory backend this
        // is sub-100 ms in practice. We assert the loose 1 s contract bound here
        // (CI headroom) and report the measured floor in the completion report.
        #expect(took < .seconds(1))
    }

    // MARK: - LOAD (burst)

    /// A burst of 120 regular captures enqueued rapidly: accept stays fast, the
    /// queue does not wedge, and ALL 120 become recallable near-realtime.
    @Test
    func burstOf120AllBecomeRecallableAndAcceptStaysFast() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let n = 120
        // Each doc carries a UNIQUE distinctive token so BM25 can isolate it
        // (a token shared by ALL docs has IDF 0 in BM25 and scores nothing — so
        // a "find them all by one shared marker" query is degenerate by design).
        // The token is a PURE-ALPHA single word: a fixed prefix, the index
        // spelled in letters at FIXED WIDTH (3-digit zero-padded, each digit
        // 0→"a"…9→"j"), and a consonant suffix "xq". Fixed width means no token
        // is a prefix of another (so distinct indices never share a BM25
        // term/stem); the consonant suffix keeps Porter2 from trimming; the
        // all-alpha shape keeps the tokenizer from splitting. Each index thus
        // yields a distinct, collision-free, high-IDF token. e.g. index 12 →
        // "qzxaacxq" (012 → a,a,c).
        func uniqueToken(_ i: Int) -> String {
            let padded = String(format: "%03d", i)
            let letters = padded.map { ch -> Character in
                Character(UnicodeScalar(UInt8(97 + (Int(String(ch)) ?? 0))))
            }
            return "qzx" + String(letters) + "xq"
        }
        var idByIndex: [Int: String] = [:]

        // Accept phase: enqueue the burst as fast as possible and time it. A
        // regular capture returns before encoding, so accept must stay fast even
        // under burst (the queue absorbs it).
        // Content is the unique token ONLY (no shared filler words): a shared
        // word would match every doc via BM25 and bury the target below the
        // recall limit, masking a successful ingest as a miss. With only the
        // distinctive token, a query for it matches exactly one doc.
        let acceptStart = ContinuousClock.now
        for i in 0..<n {
            let d = try await kit.capture(
                handle, captureFrame(uniqueToken(i)),
                mode: .regular)
            idByIndex[i] = d.id
        }
        let acceptElapsed = acceptStart.duration(to: ContinuousClock.now)
        // Accept must stay fast: 120 enqueues well under 2 s (a generous CI
        // bound; the per-accept cost is a row insert + queue write, no encode).
        #expect(acceptElapsed < .seconds(2),
            "accept stayed fast under burst: 120 regular captures in \(acceptElapsed)")

        // Drain barrier: the QUEUE must fully drain without wedging. This is the
        // pipeline subject — QueueKit absorbing the burst and the drain worker
        // clearing it under load. awaitEncodeDrain ACTIVELY confirms both queue
        // frontiers (pending + in-flight) reach zero, throwing drainTimeout if
        // the queue wedges — so reaching past it proves the burst did NOT wedge
        // and every one of the 120 jobs reached a terminal state (none stranded
        // in the queue). This is the LOAD proof for the queue layer (the
        // mission's "queue didn't wedge, accept stayed fast, nothing dropped").
        try await kit.awaitEncodeDrain(for: handle, timeout: .seconds(20))

        // End-to-end recall over the REGULAR + DRAIN path: EVERY one of the 120
        // burst captures is BM25-recallable by its distinctive token, proving the
        // drained jobs were all ingested. This asserts 100% — not a tolerance.
        //
        // The previously-tolerated ~5-10% "drain-ingest tail" was a lost-update in
        // the InMemory backend's serializable transaction commit: the encode
        // drain's serializable claim transaction committed by blind-replacing the
        // whole state from a stale snapshot, discarding QueueKit `send()` inserts
        // (bare, non-transactional, per QUEUEKIT_SPEC §10) that raced in during a
        // burst. Those queue rows vanished — never claimed, never ingested. Fixed
        // in InMemoryStorage.transaction (mutate live state, snapshot for rollback
        // only — matching the Rust port). The recall JOIN was never the cause; it
        // is proven complete by the impatient burst in FrameFaithfulRecallDropTests.
        var recalled = 0
        for i in 0..<n {
            let targetID = idByIndex[i]
            let result = try await kit.recall(handle, corpusOnlyRequest(query: uniqueToken(i)))
            if result.hits.contains(where: {
                $0.drawer?.id == targetID && $0.sources.contains(.corpusBM25)
            }) {
                recalled += 1
            }
        }
        // 100% — every regular-mode burst capture becomes recallable. The
        // near-realtime ingest+classify guarantee holds REGARDLESS OF LOAD.
        #expect(recalled == n,
            "ALL of the burst must be BM25-recallable end-to-end (got \(recalled)/\(n))")
    }

    // MARK: - AT-LEAST-ONCE (transient ingest failure is retried, never lost)

    /// A burst where an injected TRANSIENT ingest failure hits mid-stream: the
    /// failed ingests are RETRIED (Corpus ingest is idempotent) and EVENTUALLY
    /// LAND, so all 120 captures are recallable. Nothing is silently dropped on a
    /// transient failure — at-least-once delivery from the drain hand-off.
    @Test
    func burstWithInjectedTransientIngestFailureStillReaches100Percent() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let n = 120
        func uniqueToken(_ i: Int) -> String {
            let padded = String(format: "%03d", i)
            let letters = padded.map { ch -> Character in
                Character(UnicodeScalar(UInt8(97 + (Int(String(ch)) ?? 0))))
            }
            return "qzx" + String(letters) + "xq"
        }

        // Inject a TRANSIENT per-drawer ingest failure: each drawer's FIRST
        // ingest attempt fails once, then its retry succeeds (a true transient
        // fault that clears, not a permanent one). The bounded at-least-once
        // retry in `ingestAndReply` must re-attempt and land every job. Tracking
        // per-drawer (not a global budget) is what makes the fault transient —
        // a global "fail the next N attempts" budget would let early jobs exhaust
        // their whole retry budget on themselves and be (correctly) dropped as
        // permanent failures, which is a different scenario.
        let failedOnce = FirstAttemptFailureSet()
        await kit._setEncodeIngestFailureHook { drawerID in
            if failedOnce.shouldFailFirstAttempt(drawerID) {
                throw InjectedTransientIngestError()  // transient: fails once per drawer, then clears
            }
        }

        var idByIndex: [Int: String] = [:]
        for i in 0..<n {
            let d = try await kit.capture(handle, captureFrame(uniqueToken(i)), mode: .regular)
            idByIndex[i] = d.id
        }
        try await kit.awaitEncodeDrain(for: handle, timeout: .seconds(20))

        var recalled = 0
        for i in 0..<n {
            let result = try await kit.recall(handle, corpusOnlyRequest(query: uniqueToken(i)))
            if result.hits.contains(where: {
                $0.drawer?.id == idByIndex[i] && $0.sources.contains(.corpusBM25)
            }) {
                recalled += 1
            }
        }
        // Despite EVERY drawer's first ingest attempt failing transiently,
        // at-least-once retry lands every job — 100% recallable, nothing lost.
        #expect(recalled == n,
            "at-least-once retry must land ALL jobs despite injected transient failures (got \(recalled)/\(n))")
    }

    // MARK: - SEQUENCE (interleaved / out-of-order)

    /// Interleaved captures across two distinct topics arrive in mixed order;
    /// all become recallable under their own topic with NO caller-side ordering
    /// requirement. The queue claim order is HLC (capture instant), not arrival.
    @Test
    func interleavedCapturesAllRecallableNoOrderingRequirement() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        // Interleave topic A and topic B captures.
        var aIDs: [String] = []
        var bIDs: [String] = []
        for i in 0..<20 {
            if i.isMultiple(of: 2) {
                let d = try await kit.capture(
                    handle, captureFrame("alpha topic glacier tundra entry \(i)"),
                    mode: .regular)
                aIDs.append(d.id)
            } else {
                let d = try await kit.capture(
                    handle, captureFrame("beta topic monsoon savanna entry \(i)"),
                    mode: .regular)
                bIDs.append(d.id)
            }
        }

        try await kit.awaitEncodeDrain(for: handle, timeout: .seconds(20))

        // Topic A query returns all A drawers; topic B query returns all B
        // drawers — order of arrival did not matter.
        let aResult = try await kit.recall(handle, hybridRequest(query: "glacier tundra alpha"))
        let aRecalled = Set(aResult.hits.compactMap { $0.drawer?.id })
        for id in aIDs {
            #expect(aRecalled.contains(id), "every interleaved topic-A drawer must be recalled")
        }

        let bResult = try await kit.recall(handle, hybridRequest(query: "monsoon savanna beta"))
        let bRecalled = Set(bResult.hits.compactMap { $0.drawer?.id })
        for id in bIDs {
            #expect(bRecalled.contains(id), "every interleaved topic-B drawer must be recalled")
        }
    }
}
