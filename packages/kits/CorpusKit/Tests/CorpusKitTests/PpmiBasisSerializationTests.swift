// PpmiBasisSerializationTests.swift
//
// Mission 6a-i: round-trip + cross-port conformance for PPMI basis
// serialization. Mirrors the RI suite; the fixture is the cross-port
// contract consumed by the Rust leg.
//
// PPMI is a two-phase provider (train then finalize); the serialized
// basis is the finalized ppmiVectors map. The round-trip law concerns
// embedding identity, which depends only on that finalized state.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import VectorKit

private let ppmiBasisCorpus: [[String]] = [
    ["car", "engine", "drive", "road", "vehicle"],
    ["vehicle", "road", "transport", "car", "fuel"],
    ["engine", "fuel", "combustion", "power", "car"],
    ["dog", "bark", "run", "fetch", "animal"],
    ["animal", "run", "cat", "dog", "pet"],
]

private let ppmiBasisProbeTexts: [String] = ["car engine", "vehicle road", "dog animal", ""]

private func buildTrainedPpmiProvider() -> PpmiProvider {
    let provider = PpmiProvider()
    for doc in ppmiBasisCorpus { provider.train(terms: doc, window: ppmiWindow) }
    provider.finalize()
    return provider
}

/// The canonical PPMI basis fixture. Reuses `BasisEmbeddingEntry` (defined
/// in the RI suite) for the per-text embedding pins.
struct PpmiBasisFixture: Codable {
    let blobBase64: String
    let corpus: [[String]]
    let embeddings: [BasisEmbeddingEntry]
}

@Suite("PpmiBasisSerialization")
struct PpmiBasisSerializationTests {

    @Test("train+finalize → serialize → deserialize → embed is bit-identical")
    func roundTripEmbeddingIdentity() async throws {
        let original = buildTrainedPpmiProvider()
        let restored = try PpmiProvider(deserializing: original.serializeBasis())
        for text in ppmiBasisProbeTexts {
            let e0 = try await original.embed(text)
            let e1 = try await restored.embed(text)
            #expect(e0 == e1, "Engram must match after round-trip for '\(text)'")
            let f0 = try await original.embedFloat(text)
            let f1 = try await restored.embedFloat(text)
            #expect(f0.map { $0.bitPattern } == f1.map { $0.bitPattern },
                    "float vector must match bit-for-bit after round-trip for '\(text)'")
        }
    }

    @Test("restored vocabulary size equals the original")
    func roundTripVocabularySize() throws {
        let original = buildTrainedPpmiProvider()
        let restored = try PpmiProvider(deserializing: original.serializeBasis())
        #expect(restored.vocabularySize == original.vocabularySize)
    }

    @Test("blob begins with the PPB1 magic and the v1 format byte")
    func blobHeaderIsVersioned() {
        let bytes = [UInt8](buildTrainedPpmiProvider().serializeBasis())
        #expect(bytes.count >= 5)
        #expect(Array(bytes[0..<4]) == Array("PPB1".utf8))
        #expect(bytes[4] == basisFormatVersion)
    }

    @Test("truncated blob throws decodingFailure, never crashes")
    func truncatedBlobThrows() {
        let blob = buildTrainedPpmiProvider().serializeBasis()
        #expect(throws: CorpusKitError.self) {
            _ = try PpmiProvider(deserializing: Data(blob.prefix(blob.count / 2)))
        }
    }

    @Test("unknown format version throws decodingFailure")
    func unknownVersionThrows() {
        var bytes = [UInt8](buildTrainedPpmiProvider().serializeBasis())
        bytes[4] = 0xFF
        #expect(throws: CorpusKitError.self) {
            _ = try PpmiProvider(deserializing: Data(bytes))
        }
    }

    @Test("emit canonical PPMI basis fixture when PPMI_BASIS_EMIT is set")
    func emitCanonicalFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["PPMI_BASIS_EMIT"],
              !path.isEmpty else { return }
        let provider = buildTrainedPpmiProvider()
        let blob = provider.serializeBasis()
        var embeddings: [BasisEmbeddingEntry] = []
        for text in ppmiBasisProbeTexts {
            let engram = try await provider.embed(text)
            let floatVec = try await provider.embedFloat(text)
            embeddings.append(BasisEmbeddingEntry(
                text: text,
                block0: engram.block0, block1: engram.block1,
                block2: engram.block2, block3: engram.block3,
                floatBits: floatVec.map { $0.bitPattern }))
        }
        let fixture = PpmiBasisFixture(
            blobBase64: blob.base64EncodedString(),
            corpus: ppmiBasisCorpus, embeddings: embeddings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Counts codec (incremental-counts change set)

    @Test("train → serializeCounts → restore → finalize re-derives identical embeddings")
    func countsRoundTripReDerives() async throws {
        let original = PpmiProvider()
        for doc in ppmiBasisCorpus { original.train(terms: doc, window: ppmiWindow) }
        // Serialize counts before finalize. finalize() rebuilds ppmiVectors but does not clear the raw count tables.
        let countsBlob = original.serializeCounts()
        original.finalize()
        let restored = try PpmiProvider(deserializingCounts: countsBlob)
        restored.finalize()
        for text in ppmiBasisProbeTexts {
            let f0 = try await original.embedFloat(text)
            let f1 = try await restored.embedFloat(text)
            #expect(f0.map { $0.bitPattern } == f1.map { $0.bitPattern },
                    "re-derived float vector must match after counts round-trip for '\(text)'")
        }
    }

    /// The core promise of the counts table: persisted counts can be EXTENDED
    /// incrementally after restore, and the result equals a from-scratch train
    /// over the full corpus. This is what lets a maintained table replace the
    /// rebuild-from-scratch reindex.
    @Test("counts extend incrementally after restore (== from-scratch over all docs)")
    func countsIncrementalExtendEqualsFromScratch() async throws {
        // Maintain: train the first three docs, persist, restore, extend with the rest.
        let head = PpmiProvider()
        for doc in ppmiBasisCorpus.prefix(3) { head.train(terms: doc, window: ppmiWindow) }
        let restored = try PpmiProvider(deserializingCounts: head.serializeCounts())
        for doc in ppmiBasisCorpus.dropFirst(3) { restored.train(terms: doc, window: ppmiWindow) }
        restored.finalize()
        // From-scratch over the full corpus.
        let scratch = PpmiProvider()
        for doc in ppmiBasisCorpus { scratch.train(terms: doc, window: ppmiWindow) }
        scratch.finalize()
        for text in ppmiBasisProbeTexts {
            let a = try await restored.embedFloat(text)
            let b = try await scratch.embedFloat(text)
            #expect(a.map { $0.bitPattern } == b.map { $0.bitPattern },
                    "incrementally-extended counts must equal from-scratch for '\(text)'")
        }
    }

    @Test("counts blob begins with the PPMC magic and the v1 format byte")
    func countsBlobHeaderIsVersioned() {
        let p = PpmiProvider()
        for doc in ppmiBasisCorpus { p.train(terms: doc, window: ppmiWindow) }
        let bytes = [UInt8](p.serializeCounts())
        #expect(bytes.count >= 5)
        #expect(Array(bytes[0..<4]) == Array("PPMC".utf8))
        #expect(bytes[4] == basisFormatVersion)
    }

    @Test("truncated counts blob throws decodingFailure, never crashes")
    func countsTruncatedBlobThrows() {
        let p = PpmiProvider()
        for doc in ppmiBasisCorpus { p.train(terms: doc, window: ppmiWindow) }
        let blob = p.serializeCounts()
        #expect(throws: CorpusKitError.self) {
            _ = try PpmiProvider(deserializingCounts: Data(blob.prefix(blob.count / 2)))
        }
    }

    @Test("committed PPMI fixture blob reproduces its pinned embeddings")
    func committedFixtureIsSelfConsistent() async throws {
        let url = sharedVectorsURL(for: "ppmi_basis_blob.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let fixture = try JSONDecoder().decode(PpmiBasisFixture.self, from: data)
        let restored = try PpmiProvider(deserializing: Data(base64Encoded: fixture.blobBase64)!)
        for entry in fixture.embeddings {
            let v = try await restored.embedFloat(entry.text)
            #expect(v.map { $0.bitPattern } == entry.floatBits,
                    "fixture float bits must match for '\(entry.text)'")
        }
    }
}
