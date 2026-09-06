#if MOOTX01_DENSE_FAMILIES
// Dense-family test — compiled only when DenseFamilies trait is on.
// Off by default (plan 70BC55F3, 2026-09-05). See Package.swift.
// DensePoolingConformanceTests.swift
//
// Cross-port conformance for the distributional pooling contract of the
// three families whose vectors used to collapse onto the corpus mean:
// random-indexing-v1, ppmi-v1, nmf-v1.
//
// ## What is pinned (shared fixture Tests/SharedVectors/dense_pooling_vectors.json)
//
//   (a) SPREAD — on the fixture corpus the mean pairwise cosine between the
//       document vectors of each family is below 0.5. The measured value is
//       recorded in the fixture (as float bits) and the Rust leg must
//       reproduce it exactly, because the vectors it is computed from are
//       bit-identical across ports.
//   (b) SELF-QUERY — each document's opening sentence, embedded through the
//       query path, ranks that document first (strictly nearest) under each
//       family.
//   (c) ONE POOLING FUNCTION — for the same text, the document path
//       (`embedPair`, what the index writes) and the query path
//       (`embedFloat`, what recall embeds) return byte-identical vectors.
//
// The fixture corpus is deliberately full of shared function words ("the",
// "and", "of", "is", "to") so the collapse mechanism is present: a plain
// token sum over these documents points every vector at the same direction.
//
// Swift is the canonical source. Set DENSE_POOLING_EMIT to regenerate the
// fixture; normal runs assert against the committed one.
//
// Rust twin: rust-providers/tests/dense_pooling_conformance_tests.rs

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import SubstrateKernel
import SynapseKit

// MARK: - Fixture corpus

/// Twelve short documents on distinct topics, every one carrying the same
/// function words. Kept in this order; the NMF factorization and the RI
/// accumulation depend on document order.
let densePoolingCorpus: [String] = [
    "The old lighthouse keeper climbed the spiral stairs every evening to light the lamp and watch the ships pass the rocky point in the dark.",
    "A sourdough starter is a living culture of wild yeast and bacteria, and the baker feeds it flour and water every day to keep the dough rising.",
    "The orchestra tuned to the oboe before the conductor raised the baton and the strings began the slow first movement of the symphony.",
    "Our garden tomatoes ripen in late summer, and the vines need a trellis, deep watering, and pruning of the lower leaves to stay healthy.",
    "The chess club meets on Thursdays; the opening theory lecture covered the Sicilian defence and the value of controlling the centre early.",
    "Glaciers carve the valley floor over thousands of years, leaving moraines of gravel and the polished granite walls hikers see today.",
    "The marathon course follows the river for ten miles before the long climb to the stadium, and the runners save energy for the final hill.",
    "A good espresso needs fresh beans, a fine grind, and about nine bars of pressure to pull the shot with a thick layer of crema on top.",
    "The library digitised the parish records, and the genealogists can now search the baptism registers by surname and by the year of the entry.",
    "Honeybees communicate the direction of a flower patch with the waggle dance, and the angle of the dance encodes the bearing to the sun.",
    "The sailing crew reefed the mainsail as the wind rose to thirty knots and the boat heeled hard on the beat toward the harbour entrance.",
    "The pottery kiln reaches over a thousand degrees, and the glaze on the bowls turns glassy as the silica melts during the long firing.",
]

/// The query for each document: its opening words, embedded through the
/// query path exactly as recall embeds a user query.
let densePoolingQueries: [String] = [
    "The old lighthouse keeper climbed the spiral stairs",
    "A sourdough starter is a living culture of wild yeast",
    "The orchestra tuned to the oboe before the conductor",
    "Our garden tomatoes ripen in late summer",
    "The chess club meets on Thursdays; the opening theory lecture",
    "Glaciers carve the valley floor over thousands of years",
    "The marathon course follows the river for ten miles",
    "A good espresso needs fresh beans, a fine grind",
    "The library digitised the parish records",
    "Honeybees communicate the direction of a flower patch",
    "The sailing crew reefed the mainsail as the wind rose",
    "The pottery kiln reaches over a thousand degrees",
]

/// The spread ceiling the brief sets: the mean pairwise cosine of a family
/// that no longer collapses must sit below this.
let densePoolingSpreadCeiling: Float = 0.5

// MARK: - Fixture model (shared with the Rust leg)

struct DensePoolingFamilyFixture: Codable {
    let modelID: String
    /// Mean pairwise cosine between the document vectors (float bits).
    let meanPairwiseCosineBits: UInt32
    /// documentVectors[i] = float bits of embedFloat(corpus[i]).
    let documentVectors: [[UInt32]]
    /// queryVectors[i] = float bits of embedFloat(queries[i]).
    let queryVectors: [[UInt32]]
    /// selfQueryRanks[i] = 1-based rank of document i for query i.
    let selfQueryRanks: [Int]
}

struct DensePoolingFixture: Codable {
    let corpus: [String]
    let queries: [String]
    let spreadCeiling: Float
    let families: [DensePoolingFamilyFixture]
}

// MARK: - Measurement helpers

/// Mean of cos(v_i, v_j) over all unordered pairs i < j, accumulated in
/// index order (the Rust leg accumulates in the same order).
func meanPairwiseCosine(_ vectors: [[Float]]) -> Float {
    var sum: Float = 0
    var pairs = 0
    for i in 0..<vectors.count {
        for j in (i + 1)..<vectors.count {
            sum += FloatVecOps.dot(vectors[i], vectors[j])
            pairs += 1
        }
    }
    return pairs == 0 ? 0 : sum / Float(pairs)
}

/// 1-based rank of `target` among `documents` by cosine to `query`
/// (1 = strictly nearest; ties count against the target).
func selfQueryRank(query: [Float], documents: [[Float]], target: Int) -> Int {
    let own = FloatVecOps.dot(query, documents[target])
    var better = 0
    for (index, document) in documents.enumerated() where index != target {
        if FloatVecOps.dot(query, document) >= own { better += 1 }
    }
    return better + 1
}

// MARK: - Suite

@Suite("DensePoolingConformance")
struct DensePoolingConformanceTests {

    /// The three families under contract, trained through the seam on the
    /// fixture corpus (the same call the corpus makes).
    private func trainedFamilies() -> [(modelID: String, provider: any EmbeddingProvider & TrainableEmbeddingBasis)] {
        let ri = RandomIndexingProvider()
        let ppmi = PpmiProvider()
        let nmf = NmfProvider()
        ri.trainOnCorpus(texts: densePoolingCorpus)
        ppmi.trainOnCorpus(texts: densePoolingCorpus)
        nmf.trainOnCorpus(texts: densePoolingCorpus)
        return [("random-indexing-v1", ri), ("ppmi-v1", ppmi), ("nmf-v1", nmf)]
    }

    private func measure(_ provider: any EmbeddingProvider) async throws -> DensePoolingFamilyFixture {
        var documentVectors: [[Float]] = []
        for text in densePoolingCorpus {
            // The document path: what the index writes.
            let pair = try await provider.embedPair(text)
            documentVectors.append(pair.floats)
        }
        var queryVectors: [[Float]] = []
        for text in densePoolingQueries {
            // The query path: what recall embeds.
            queryVectors.append(try await provider.embedFloat(text))
        }
        let ranks = (0..<densePoolingCorpus.count).map { i in
            selfQueryRank(query: queryVectors[i], documents: documentVectors, target: i)
        }
        return DensePoolingFamilyFixture(
            modelID: provider.modelID,
            meanPairwiseCosineBits: meanPairwiseCosine(documentVectors).bitPattern,
            documentVectors: documentVectors.map { $0.map(\.bitPattern) },
            queryVectors: queryVectors.map { $0.map(\.bitPattern) },
            selfQueryRanks: ranks)
    }

    @Test("(a) spread: mean pairwise cosine of every fixed family is below 0.5")
    func spreadBelowCeiling() async throws {
        for family in trainedFamilies() {
            let measured = try await measure(family.provider)
            for vector in measured.documentVectors {
                #expect(!vector.isEmpty, "\(family.modelID): every fixture document must embed")
            }
            let cosine = Float(bitPattern: measured.meanPairwiseCosineBits)
            #expect(cosine < densePoolingSpreadCeiling,
                    "\(family.modelID): mean pairwise cosine \(cosine) must be below \(densePoolingSpreadCeiling)")
        }
    }

    @Test("(b) self-query: a document's opening sentence ranks that document first")
    func openingSentenceRanksOwnDocumentFirst() async throws {
        for family in trainedFamilies() {
            let measured = try await measure(family.provider)
            for (i, rank) in measured.selfQueryRanks.enumerated() {
                #expect(rank == 1, "\(family.modelID): query \(i) ranks its document at \(rank), not 1")
            }
        }
    }

    @Test("(c) one pooling function: document path and query path are byte-identical")
    func documentAndQueryPathsAgree() async throws {
        for family in trainedFamilies() {
            for text in densePoolingCorpus + densePoolingQueries {
                let viaDocumentPath = try await family.provider.embedPair(text).floats
                let viaQueryPath = try await family.provider.embedFloat(text)
                #expect(viaDocumentPath.map(\.bitPattern) == viaQueryPath.map(\.bitPattern),
                        "\(family.modelID): embedPair and embedFloat must agree bit-for-bit for '\(text.prefix(32))'")
            }
        }
    }

    @Test("the fitted basis survives serialization: reconstructed vectors are bit-identical")
    func reconstructedBasisPoolsIdentically() async throws {
        for family in trainedFamilies() {
            let restored = try family.provider.reconstructBasis(from: family.provider.serializeBasis())
            for text in densePoolingQueries {
                let a = try await family.provider.embedFloat(text)
                let b = try await restored.embedFloat(text)
                #expect(a.map(\.bitPattern) == b.map(\.bitPattern),
                        "\(family.modelID): the IDF table and mean direction must travel in the basis")
            }
        }
    }

    /// Emit the shared fixture when DENSE_POOLING_EMIT names a path. Swift is
    /// the canonical source; the Rust leg consumes the committed JSON.
    @Test("emit the dense pooling fixture when DENSE_POOLING_EMIT is set")
    func emitFixtureIfRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["DENSE_POOLING_EMIT"],
              !path.isEmpty else { return }
        var families: [DensePoolingFamilyFixture] = []
        for family in trainedFamilies() {
            families.append(try await measure(family.provider))
        }
        let fixture = DensePoolingFixture(
            corpus: densePoolingCorpus,
            queries: densePoolingQueries,
            spreadCeiling: densePoolingSpreadCeiling,
            families: families)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: path))
    }

    @Test("the committed fixture matches the live measurement bit-for-bit")
    func committedFixtureMatches() async throws {
        let url = sharedVectorsURL(for: "dense_pooling_vectors.json")
        let fixture = try JSONDecoder().decode(DensePoolingFixture.self, from: Data(contentsOf: url))
        #expect(fixture.corpus == densePoolingCorpus, "fixture corpus must be the canonical corpus")
        #expect(fixture.queries == densePoolingQueries, "fixture queries must be the canonical queries")
        let measuredFamilies = trainedFamilies()
        #expect(fixture.families.count == measuredFamilies.count)
        for (expected, family) in zip(fixture.families, measuredFamilies) {
            let measured = try await measure(family.provider)
            #expect(measured.modelID == expected.modelID)
            #expect(measured.meanPairwiseCosineBits == expected.meanPairwiseCosineBits,
                    "\(expected.modelID): mean pairwise cosine pin")
            #expect(measured.documentVectors == expected.documentVectors,
                    "\(expected.modelID): document vectors pin")
            #expect(measured.queryVectors == expected.queryVectors,
                    "\(expected.modelID): query vectors pin")
            #expect(measured.selfQueryRanks == expected.selfQueryRanks,
                    "\(expected.modelID): self-query ranks pin")
        }
    }
}

#endif // MOOTX01_DENSE_FAMILIES
