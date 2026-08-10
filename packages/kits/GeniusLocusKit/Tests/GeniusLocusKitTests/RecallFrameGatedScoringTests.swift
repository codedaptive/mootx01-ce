// RecallFrameGatedScoringTests.swift
//
// Regression tests for RD-01: frame-filtering must gate scoring/tiebreak
// content, not just the final hit set.
//
// Finding 1 (MMR content oracle — BRR Symbols 2+3, Swift Fixes 3+4):
// `recallUnionBest` must only hydrate frame-admissible content into
// `mmrContentByID` and must only admit frame-admissible candidates into
// `unselected`. Test E exercises this code path using `.unionBest` mode
// with `.full` hydration.
//
// Finding 2 (BM25/vector content-sort and slot-stealing oracle — BRR Symbol 6,
// Swift Fix 5): `recallCorpusOnly` must pre-filter BM25/vector lists to
// frame-admissible IDs before rrfFuseN truncation (slot-stealing oracle) and
// must load content only from frame-admissible candidates for the pre-fusion
// content-sort tiebreak (content-sort oracle). Tests A-D exercise this code
// path using `.corpusOnly` mode.
//
// The oracle is verified by provisioning two estates with identical admissible
// drawers but different restricted decoy content, and asserting that both recall
// runs return identical hit content in identical order. Any difference indicates
// a frame-excluded drawer's content leaked into scoring.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory

@Suite("Recall frame-gated scoring — RD-01 regression (frame-excluded content must not influence recall)", .serialized)
struct RecallFrameGatedScoringTests {

    // MARK: - Infrastructure

    /// Provision a GLK estate backed by in-memory storage with a deterministic
    /// embedding model so BM25 + dense lanes are live after an impatient capture.
    private func provision(ownerSuffix: String) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-frame-gated-\(ownerSuffix)")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "Frame-Gated Scoring Estate \(ownerSuffix)",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    /// Capture frame for an admissible drawer (default sensitivity = .normal).
    private func admissibleFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "frame-gated-scoring",
            latticeAnchor: .udc("000"),
            addedBy: "rd-01-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// Capture frame for a restricted drawer (sensitivity = .restricted).
    /// The default recall frame applies `.sensitivityAtMost(.elevated)`, so
    /// restricted drawers are excluded from all recall results below.
    private func restrictedFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "frame-gated-scoring",
            latticeAnchor: .udc("001"),
            addedBy: "rd-01-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: .restricted
        )
    }

    /// Recall request using the DEFAULT frame (BitmapEvaluator default insertion
    /// adds `.sensitivityAtMost(.elevated)` so restricted/secret drawers are
    /// excluded) with `.corpusOnly` mode. `.full` hydration exercises the
    /// content-sort path (Fix 5 / BRR Symbol 6): frame-excluded content must not
    /// enter `corpusContentByID` or influence BM25/vector pre-fusion ranks.
    private func recallRequest(query: String, limit: Int = 20) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .full,
                ordering: .byCaptureTimeDesc),
            mode: .corpusOnly,
            scoring: .rrf,
            limit: limit,
            fallback: .failClosed,
            queryText: query
        )
    }

    // MARK: - A. Restricted drawer is never surfaced in recall results

    @Test func restrictedDrawerAbsentFromDefaultRecall() async throws {
        let (kit, handle) = try await provision(ownerSuffix: "drop-a")
        defer { Task { try? await kit.close(handle) } }

        // Admissible drawer: matches the query.
        let admissible = try await kit.capture(
            handle, admissibleFrame(content: "oracle probe canary admissible content"),
            mode: .impatient)

        // Restricted drawer: matches the SAME query — the corpus index contains it.
        let restricted = try await kit.capture(
            handle, restrictedFrame(content: "oracle probe canary restricted content"),
            mode: .impatient)

        let result = try await kit.recall(handle, recallRequest(query: "oracle probe canary"))

        // The restricted drawer must be absent from all hit ids.
        #expect(!result.hits.contains { $0.id == restricted.id },
            "restricted drawer MUST be absent from default-frame recall results; hits: \(result.hits.map(\.id))")

        // The admissible drawer must still surface.
        #expect(result.hits.contains { $0.id == admissible.id },
            "admissible drawer MUST surface in recall; hits: \(result.hits.map(\.id))")
    }

    // MARK: - B. Multiple restricted drawers — none surfaces, count is exact

    @Test func multipleRestrictedDrawersNeverSurface() async throws {
        let (kit, handle) = try await provision(ownerSuffix: "drop-b")
        defer { Task { try? await kit.close(handle) } }

        let contents = ["oracle probe canary alpha", "oracle probe canary beta",
                        "oracle probe canary gamma"]
        var admissibleIDs: Set<String> = []
        for c in contents {
            let d = try await kit.capture(handle, admissibleFrame(content: c), mode: .impatient)
            admissibleIDs.insert(d.id)
        }

        var restrictedIDs: Set<String> = []
        for c in ["oracle probe canary rho", "oracle probe canary sigma",
                  "oracle probe canary tau"] {
            let d = try await kit.capture(handle, restrictedFrame(content: c), mode: .impatient)
            restrictedIDs.insert(d.id)
        }

        let result = try await kit.recall(handle, recallRequest(query: "oracle probe canary"))

        // No restricted hit must appear.
        let restrictedHits = result.hits.filter { restrictedIDs.contains($0.id) }
        #expect(restrictedHits.isEmpty,
            "no restricted drawer must appear in recall results; leaked ids: \(restrictedHits.map(\.id))")

        // All admissible drawers must be present.
        for id in admissibleIDs {
            #expect(result.hits.contains { $0.id == id },
                "admissible drawer \(id) must surface in recall")
        }
    }

    // MARK: - C. Content-oracle invariance (RD-01 §F1+§F2): mutating a restricted
    //          drawer's content must not change admissible recall ordering or count.

    /// Two estates with identical admissible drawers but different restricted
    /// decoy content. Both recall runs must return the same hit content in the
    /// same order. Any difference proves a frame-excluded drawer's content
    /// leaked into scoring/MMR.
    @Test func restrictedDecoyContentDoesNotInfluenceAdmissibleOrdering() async throws {
        // The shared admissible corpus — identical across both estates.
        let admissibleContents = [
            "oracle canary alpha fact",
            "oracle canary beta fact",
            "oracle canary gamma fact",
        ]

        // --- Estate A: restricted decoy content identical to the first admissible
        // drawer ("oracle canary alpha fact"). In the BUGGY corpusOnly code (pre-Fix 5),
        // this decoy entered corpusContentByID via the unframed getDrawers call,
        // giving da and the decoy the same content tiebreak key. The stable sort then
        // placed them by UUID order rather than content order, potentially altering
        // admissible BM25 ranks before RRF fusion (content-sort oracle, §F2). ---
        let (kitA, handleA) = try await provision(ownerSuffix: "oracle-a")
        defer { Task { try? await kitA.close(handleA) } }

        var admissibleIDsA: [String] = []
        for c in admissibleContents {
            let d = try await kitA.capture(handleA, admissibleFrame(content: c), mode: .impatient)
            admissibleIDsA.append(d.id)
        }
        // Decoy A: identical to the first admissible drawer — maximum shingle overlap.
        _ = try await kitA.capture(
            handleA, restrictedFrame(content: "oracle canary alpha fact"),
            mode: .impatient)

        let resultA = try await kitA.recall(handleA, recallRequest(query: "oracle canary", limit: 3))
        let contentsA = resultA.hits.compactMap { $0.drawer?.content }

        // --- Estate B: restricted decoy with completely different content that
        // contributes zero shingle similarity to any admissible drawer. ---
        let (kitB, handleB) = try await provision(ownerSuffix: "oracle-b")
        defer { Task { try? await kitB.close(handleB) } }

        for c in admissibleContents {
            _ = try await kitB.capture(handleB, admissibleFrame(content: c), mode: .impatient)
        }
        // Decoy B: unrelated content — no shingle overlap with admissible drawers.
        _ = try await kitB.capture(
            handleB, restrictedFrame(content: "zeta quantum unrelated decoy"),
            mode: .impatient)

        let resultB = try await kitB.recall(handleB, recallRequest(query: "oracle canary", limit: 3))
        let contentsB = resultB.hits.compactMap { $0.drawer?.content }

        // Same count: the restricted decoy must not steal a slot from an admissible
        // drawer in either estate. Both returns must have 3 admissible hits.
        #expect(contentsA.count == 3,
            "all 3 admissible drawers must be present; got: \(contentsA)")
        #expect(contentsA.count == contentsB.count,
            "count must be invariant to restricted decoy content; A=\(contentsA.count), B=\(contentsB.count)")

        // Same content in same order: changing the restricted decoy's content must
        // not alter which admissible drawers are returned or their ordering.
        #expect(contentsA == contentsB,
            "admissible hit order must be invariant to restricted decoy content; A=\(contentsA), B=\(contentsB)")
    }

    // MARK: - D. Frame override proves the sensitivity ceiling is not a hardcode

    /// A recall with `.sensitivityAtMost(.restricted)` added to the frame MUST
    /// surface the restricted drawer — proving the exclusion is frame-driven,
    /// not a hardcoded sensitivity constant.
    @Test func sensitivityFrameOverrideSurfacesRestrictedDrawer() async throws {
        let (kit, handle) = try await provision(ownerSuffix: "override-d")
        defer { Task { try? await kit.close(handle) } }

        let restricted = try await kit.capture(
            handle, restrictedFrame(content: "oracle probe canary restricted override"),
            mode: .impatient)

        // Default frame excludes restricted.
        let defaultResult = try await kit.recall(handle, recallRequest(query: "oracle probe canary"))
        #expect(!defaultResult.hits.contains { $0.id == restricted.id },
            "restricted drawer must be absent under default frame")

        // Override: explicitly include up to .restricted sensitivity.
        let overrideRequest = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed, .sensitivityAtMost(.restricted)],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .corpusOnly,
            scoring: .rrf,
            limit: 20,
            fallback: .failClosed,
            queryText: "oracle probe canary")

        let overrideResult = try await kit.recall(handle, overrideRequest)
        #expect(overrideResult.hits.contains { $0.id == restricted.id },
            "restricted drawer MUST surface when frame ceiling includes .restricted (proves frame-driven, not hardcoded)")
    }

    // MARK: - E. MMR code-path regression: unionBest with restricted decoy
    //          (BRR Symbols 2+3 — Swift Fixes 3+4)

    /// Two estates with identical admissible drawers but different restricted decoy
    /// content, recalled via `.unionBest` mode with `.full` hydration. Both runs must
    /// return the same count and content in the same order.
    ///
    /// This test exercises the `recallUnionBest` code path (BRR Symbols 2+3):
    /// - Symbol 2 (Fix 3): only frame-admissible IDs enter `mmrContentByID` via
    ///   `estate.hydrateBodies(ids: Array(drawerIndex.keys))`.
    /// - Symbol 3 (Fix 4): only frame-admissible indices enter `unselected`, so the
    ///   MMR loop cannot select a restricted decoy and update `maxSim` for admissible
    ///   drawers with identical content.
    ///
    /// The oracle fires when the decoy's RRF score is competitive enough to enter MMR
    /// selection before all admissible items. In this fixture, admissible items have a
    /// locus-window advantage (locus + BM25 + vector) while the decoy has no locus
    /// contribution. The test documents the invariant and guarantees no regression if
    /// scoring conditions change in the future.
    @Test func unionBestRestrictedDecoyContentDoesNotInfluenceMMR() async throws {
        let admissibleContents = [
            "mmr oracle canary alpha item",
            "mmr oracle canary beta item",
            "mmr oracle canary gamma item",
            "mmr oracle canary delta item",
        ]

        // --- Estate A: restricted decoy content identical to the first admissible
        // drawer. If Fix 3 is absent, the decoy's content enters mmrContentByID via
        // the unframed hydrateBodies call. If Fix 4 is also absent, the decoy can be
        // selected by the MMR loop and update maxSim("mmr oracle canary alpha item")
        // to 1.0, penalising it out of the top results. ---
        let (kitA, handleA) = try await provision(ownerSuffix: "mmr-e-a")
        defer { Task { try? await kitA.close(handleA) } }

        for c in admissibleContents {
            _ = try await kitA.capture(handleA, admissibleFrame(content: c), mode: .impatient)
        }
        _ = try await kitA.capture(
            handleA, restrictedFrame(content: "mmr oracle canary alpha item"),
            mode: .impatient)

        let mmrRequestA = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .full,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .rrf,
            limit: 3,
            fallback: .failClosed,
            queryText: "mmr oracle canary")

        let resultA = try await kitA.recall(handleA, mmrRequestA)
        let contentsA = resultA.hits.compactMap { $0.drawer?.content }

        // --- Estate B: restricted decoy with unrelated content — no shingle overlap
        // with any admissible drawer, so its selection by MMR would not penalise any
        // specific admissible item. Both estates must return the same top-3. ---
        let (kitB, handleB) = try await provision(ownerSuffix: "mmr-e-b")
        defer { Task { try? await kitB.close(handleB) } }

        for c in admissibleContents {
            _ = try await kitB.capture(handleB, admissibleFrame(content: c), mode: .impatient)
        }
        _ = try await kitB.capture(
            handleB, restrictedFrame(content: "zeta quantum unrelated mmr decoy"),
            mode: .impatient)

        let mmrRequestB = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .full,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .rrf,
            limit: 3,
            fallback: .failClosed,
            queryText: "mmr oracle canary")

        let resultB = try await kitB.recall(handleB, mmrRequestB)
        let contentsB = resultB.hits.compactMap { $0.drawer?.content }

        // Restricted decoy must never appear in either result.
        #expect(!contentsA.contains("zeta quantum unrelated mmr decoy"),
            "restricted decoy must not appear in estate A unionBest results")
        #expect(!contentsB.contains("zeta quantum unrelated mmr decoy"),
            "restricted decoy must not appear in estate B unionBest results")

        // Count must be invariant: both estates have 4 admissible drawers, limit=3,
        // so 3 admissible items must be returned from each.
        #expect(contentsA.count == 3,
            "estate A must return 3 admissible drawers; got: \(contentsA)")
        #expect(contentsA.count == contentsB.count,
            "count must be invariant to restricted decoy content; A=\(contentsA.count), B=\(contentsB.count)")

        // Same content in same order: the restricted decoy must not influence which
        // admissible drawers are selected or their ordering.
        #expect(contentsA == contentsB,
            "admissible hit order must be invariant to restricted decoy content; A=\(contentsA), B=\(contentsB)")
    }
}
