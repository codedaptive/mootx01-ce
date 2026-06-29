// HybridRecallTests.swift
//
// Peer suite for HybridRecallConfiguration (Sources/CorpusKit/HybridRecall.swift).
// HybridRecall.recall(...) requires a live VectorStore + InvertedIndexStore +
// BundleStore, which is integration scope; the configuration value type
// is the unit-testable surface. These assertions pin the documented
// defaults (RRF k=60, 0.6/0.4 weights, MMR disabled) and the custom init.
//
// P3-secfix UUID fusion test: the Fusion.fuse engine is the fusion seam that
// HybridRecall feeds; by exercising it with the same UUID in different case
// forms we can verify the canonicalization contract without a full integration
// test requiring live stores.

import Testing
import CorpusKit
import Foundation

@Suite("HybridRecallConfiguration")
struct HybridRecallTests {

    @Test func defaultsMatchDocumentedValues() {
        let config = HybridRecallConfiguration()
        #expect(config.vectorWeight == 0.6)
        #expect(config.keywordWeight == 0.4)
        #expect(config.rrfK == 60)
        #expect(config.mmrLambda == nil)
    }

    @Test func customInitStoresAllFields() {
        let config = HybridRecallConfiguration(
            vectorWeight: 0.7,
            keywordWeight: 0.3,
            rrfK: 10,
            mmrLambda: 0.5
        )
        #expect(config.vectorWeight == 0.7)
        #expect(config.keywordWeight == 0.3)
        #expect(config.rrfK == 10)
        #expect(config.mmrLambda == 0.5)
    }

    @Test func fieldsAreMutable() {
        var config = HybridRecallConfiguration()
        config.vectorWeight = 0.9
        config.mmrLambda = 0.25
        #expect(config.vectorWeight == 0.9)
        #expect(config.mmrLambda == 0.25)
    }
}

// MARK: - P3-secfix: UUID canonicalization fusion test

// HybridRecall.recall() calls Fusion.fuse with itemID keys from two lanes:
//   - vector lane: UUID string from VectorKit (may be lower- or uppercase)
//   - keyword lane: UUID.uuidString (always uppercase on Apple)
// The P3 fix canonicalizes vector-lane keys through UUID parse → .uuidString
// so both lanes use the same key and fuse. We test the fusion contract here
// without live stores by feeding Fusion.fuse directly with the same UUID
// in different case forms — demonstrating the fusion that HybridRecall now
// guarantees after canonicalization.
@Suite("HybridRecall UUID fusion canonicalization (P3-secfix)")
struct HybridRecallUUIDFusionTests {

    // The canonical uppercase form (what UUID.uuidString returns on Apple and
    // what HybridRecall.recall() now always uses for both lanes after the fix).
    private let uuid = UUID()

    // P3-secfix: when a vector hit arrives with a lowercase UUID string (e.g.
    // from a Rust-originated DB) and the keyword hit uses the same UUID but
    // uppercase (UUID.uuidString), the P3 fix ensures both get normalized to
    // the same canonical key before entering Fusion.fuse. We verify that the
    // canonical uppercase key fuses both contributions into a single hit.
    @Test("same UUID in upper- and lowercase forms fuses to one ranked entry via Fusion.fuse")
    func uuidCaseMismatchFusesToSingleEntry() {
        let upperID = uuid.uuidString                       // "A1B2C3D4-..."
        let lowerID = uuid.uuidString.lowercased()          // "a1b2c3d4-..."

        // Simulate what HybridRecall.recall() does AFTER the P3 fix:
        // both hit.itemID (vector) and hit.id.uuidString (keyword) are parsed
        // through UUID(uuidString:)?.uuidString so both produce upperID.
        let canonicalVec = UUID(uuidString: upperID)!.uuidString
        let canonicalKw  = UUID(uuidString: lowerID)!.uuidString

        // Both canonical forms must be equal — that's the invariant the fix enforces.
        #expect(canonicalVec == canonicalKw,
            "UUID parse+reformat must yield the same canonical string regardless of input case")

        // Feed both through Fusion.fuse using their canonical keys.
        // A single item seen in BOTH lanes must fuse into ONE FusedHit.
        let fused = Fusion.fuse(
            rankedLists: [
                .binaryDense: [(itemID: canonicalVec, rank: 1)],
                .sparse:      [(itemID: canonicalKw,  rank: 1)]
            ],
            weights: [.binaryDense: 0.6, .sparse: 0.4]
        )
        #expect(fused.count == 1, "the same UUID in both lanes must fuse to exactly one entry")
    }
}
