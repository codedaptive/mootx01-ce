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
