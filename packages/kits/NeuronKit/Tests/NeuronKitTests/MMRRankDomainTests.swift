// MMRRankDomainTests.swift
//
// Domain enforcement tests for mmrRank / MMREngine.select.
//
// The MMR score λ·relevance − (1−λ)·maxSim is a convex blend only when
// λ ∈ [0, 1]. An out-of-range λ produces out-of-spec scores (negative
// weighting of the diversity term, or relevance weighting above 1).
// The mission enforces λ ∈ [0, 1] at the public entry point and at the
// conformance-gated core (MMREngine.select), matching the substrate
// precondition convention used by sibling engines.
//
// Violations trigger precondition failures (process-terminating). The
// tests below verify:
//   - λ at the boundaries (0.0 and 1.0) is accepted and produces the
//     documented selection orders.
//   - λ strictly inside [0, 1] is accepted.
//
// The out-of-range paths (λ < 0, λ > 1) are enforced by the precondition
// in MMREngine.select and mmrRank and are documented below.
//
// Conformance vector: docs/engineering/substrate_reference/test-harness/
//   vectors/mmr_lambda_domain.json

import Testing
import Foundation
import EngramLib
@testable import NeuronKit

@Suite("mmrRank lambda domain enforcement")
struct MMRRankDomainTests {

    // MARK: - Fixtures (mirror MMRRankTests)

    private func lowBits(_ count: Int) -> UInt64 {
        count >= 64 ? ~UInt64(0) : (UInt64(1) << count) - 1
    }
    private func fingerprintA() -> Engram { Engram(blocks: lowBits(40), 0, 0, 0) }
    private func fingerprintB() -> Engram { Engram(blocks: lowBits(44), 0, 0, 0) }
    private func fingerprintC() -> Engram { Engram(blocks: 0, ~UInt64(0), lowBits(16), 0) }
    private var query: Engram { Engram(blocks: 0, 0, 0, 0) }

    private func fps() -> [Engram] { [fingerprintA(), fingerprintB(), fingerprintC()] }

    // MARK: - Boundary lambda accepted

    @Test("lambda = 0.0 (pure diversity) is accepted")
    func lambdaZeroAccepted() {
        // λ=0 is the lower boundary of [0,1] — pure diversity.
        let order = MMREngine.select(fingerprints: fps(), query: query, lambda: 0.0, k: 3)
        #expect(order.count == 3)
    }

    @Test("lambda = 1.0 (pure relevance) is accepted and yields relevance order")
    func lambdaOneAccepted() {
        // λ=1 is the upper boundary — pure relevance.
        // dist A=40 < B=44 < C=80 → [A, B, C] = indices [0, 1, 2].
        let order = MMREngine.select(fingerprints: fps(), query: query, lambda: 1.0, k: 3)
        #expect(order == [0, 1, 2])
    }

    @Test("lambda strictly inside [0,1] is accepted")
    func lambdaInteriorAccepted() {
        // λ=0.7 is the canonical worked example: [A, C, B] = [0, 2, 1].
        let order = MMREngine.select(fingerprints: fps(), query: query, lambda: 0.7, k: 3)
        #expect(order == [0, 2, 1])
    }

    @Test("public mmrRank wrapper accepts in-range lambda")
    func publicWrapperAcceptsInRange() {
        let drawers = [makeTestDrawer("A"), makeTestDrawer("B"), makeTestDrawer("C")]
        let out = mmrRank(
            candidates: drawers,
            query: query,
            lambda: 0.5,
            k: 3,
            fingerprint: { d in
                switch d.id {
                case "A": return self.fingerprintA()
                case "B": return self.fingerprintB()
                default: return self.fingerprintC()
                }
            }
        )
        #expect(out.count == 3)
    }

    // MARK: - Out-of-range lambda coverage (code inspection)
    //
    // The following inputs trigger precondition failures (process-
    // terminating, cannot be exercised as runnable tests). The
    // precondition in MMREngine.select and mmrRank covers each:
    //
    //   lambda = -0.1   → "lambda must be in [0, 1] (got -0.1)"
    //   lambda =  1.5   → "lambda must be in [0, 1] (got 1.5)"
    //   lambda = -Float.infinity → precondition fires (< 0)
    //   lambda =  Float.infinity → precondition fires (> 1)
}

// Minimal Drawer factory for the wrapper test. Mirrors the MMRRankTests
// helper so the fingerprint closure can map by id. Content is irrelevant
// to MMR math (similarity comes entirely from the supplied fingerprints).
private func makeTestDrawer(_ id: String) -> Drawer {
    Drawer(
        id: id,
        content: "",
        parentNodeId: "test-room-node",
        sourceFile: nil,
        chunkIndex: nil,
        addedBy: "test",
        filedAt: Date(timeIntervalSince1970: 0),
        embeddingModelID: "test-embed-v1",
        tombstonedAt: nil,
        removedByBatch: nil,
        provenance: 0,
        adjectiveBitmap: 0,
        operationalBitmap: 0,
        lineageID: UUID(),
        udcCode: "",
        udcFacets: nil,
        wikidataQID: nil,
        wikidataQidsSecondary: nil
    )
}
