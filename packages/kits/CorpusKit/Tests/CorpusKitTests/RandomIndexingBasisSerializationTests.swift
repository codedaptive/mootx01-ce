// RandomIndexingBasisSerializationTests.swift
//
// Mission 6a-i: round-trip + cross-port conformance for RI basis
// serialization.
//
// ## What is tested
//
//   1. Round-trip law: train → serialize → deserialize → embed(text) is
//      bit-identical to train → embed(text), for every probe text.
//   2. Versioned framing: the blob starts with the "RIB1" magic and the
//      format-version byte; a truncated blob and an unknown-version blob
//      both throw CorpusKitError.decodingFailure (no crash).
//   3. Canonical fixture emission: when RI_BASIS_EMIT is set, the Swift
//      leg (canonical source) writes the shared fixture
//      Tests/SharedVectors/ri_basis_blob.json — the canonical blob bytes
//      (base64) plus the embedding bit patterns the Rust leg must reproduce.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import VectorKit

// MARK: - Shared canonical fixture corpus

/// Fixed mini-corpus for RI basis serialization conformance. Same 5-doc
/// corpus as the RI embedding conformance suite so the trained state is
/// the established canonical one.
private let riBasisCorpus: [[String]] = [
    ["car", "engine", "drive", "road", "vehicle"],
    ["vehicle", "road", "transport", "car", "fuel"],
    ["engine", "fuel", "combustion", "power", "car"],
    ["dog", "bark", "run", "fetch", "animal"],
    ["animal", "run", "cat", "dog", "pet"],
]

/// Probe texts whose embeddings pin the cross-port contract.
private let riBasisProbeTexts: [String] = ["car engine", "vehicle road", "dog animal", ""]

/// Build and train an RI provider on the canonical corpus.
private func buildTrainedRIProvider() -> RandomIndexingProvider {
    let provider = RandomIndexingProvider()
    for doc in riBasisCorpus {
        provider.train(terms: doc, window: riWindow)
    }
    return provider
}

// MARK: - Fixture model (shared with the Rust leg)

/// One probe-text embedding expectation.
struct BasisEmbeddingEntry: Codable {
    let text: String
    let block0: UInt64
    let block1: UInt64
    let block2: UInt64
    let block3: UInt64
    let floatBits: [UInt32]
}

/// The canonical RI basis fixture: blob bytes (base64) + embedding pins.
struct RIBasisFixture: Codable {
    /// Base64 of the canonical serialized basis blob. The Rust leg decodes
    /// this and asserts its own serialize_basis() produces identical bytes.
    let blobBase64: String
    let corpus: [[String]]
    let embeddings: [BasisEmbeddingEntry]
}

@Suite("RandomIndexingBasisSerialization")
struct RandomIndexingBasisSerializationTests {

    // MARK: §1 — Round-trip law

    @Test("train → serialize → deserialize → embed is bit-identical to train → embed")
    func roundTripEmbeddingIdentity() async throws {
        let original = buildTrainedRIProvider()
        let blob = original.serializeBasis()
        let restored = try RandomIndexingProvider(deserializing: blob)

        for text in riBasisProbeTexts {
            let e0 = try await original.embed(text)
            let e1 = try await restored.embed(text)
            #expect(e0 == e1, "Engram must match after round-trip for text '\(text)'")

            let f0 = try await original.embedFloat(text)
            let f1 = try await restored.embedFloat(text)
            #expect(f0.map { $0.bitPattern } == f1.map { $0.bitPattern },
                    "float vector must match bit-for-bit after round-trip for text '\(text)'")
        }
    }

    @Test("restored vocabulary size equals the original")
    func roundTripVocabularySize() throws {
        let original = buildTrainedRIProvider()
        let restored = try RandomIndexingProvider(deserializing: original.serializeBasis())
        #expect(restored.vocabularySize == original.vocabularySize)
    }

    // MARK: §2 — Versioned framing + error paths

    @Test("blob begins with the RIB1 magic and the v1 format byte")
    func blobHeaderIsVersioned() {
        let blob = buildTrainedRIProvider().serializeBasis()
        let bytes = [UInt8](blob)
        #expect(bytes.count >= 5, "blob must carry at least magic + version")
        #expect(Array(bytes[0..<4]) == Array("RIB1".utf8), "first 4 bytes must be the RIB1 magic")
        #expect(bytes[4] == basisFormatVersion, "5th byte must be the format version")
    }

    @Test("truncated blob throws decodingFailure, never crashes")
    func truncatedBlobThrows() {
        let blob = buildTrainedRIProvider().serializeBasis()
        let truncated = blob.prefix(blob.count / 2)
        #expect(throws: CorpusKitError.self) {
            _ = try RandomIndexingProvider(deserializing: Data(truncated))
        }
    }

    @Test("unknown format version throws decodingFailure")
    func unknownVersionThrows() {
        var bytes = [UInt8](buildTrainedRIProvider().serializeBasis())
        bytes[4] = 0xFF // corrupt the version byte
        #expect(throws: CorpusKitError.self) {
            _ = try RandomIndexingProvider(deserializing: Data(bytes))
        }
    }

    @Test("wrong-provider magic throws decodingFailure")
    func wrongMagicThrows() {
        var bytes = [UInt8](buildTrainedRIProvider().serializeBasis())
        bytes[0] = UInt8(ascii: "X")
        #expect(throws: CorpusKitError.self) {
            _ = try RandomIndexingProvider(deserializing: Data(bytes))
        }
    }

    // MARK: §3 — Canonical fixture (cross-port contract)

    /// Emit the shared RI basis fixture when RI_BASIS_EMIT is set. Swift is
    /// the canonical source; the Rust leg consumes the committed JSON.
    @Test("emit canonical RI basis fixture when RI_BASIS_EMIT is set")
    func emitCanonicalFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["RI_BASIS_EMIT"],
              !path.isEmpty else { return }

        let provider = buildTrainedRIProvider()
        let blob = provider.serializeBasis()

        var embeddings: [BasisEmbeddingEntry] = []
        for text in riBasisProbeTexts {
            let engram = try await provider.embed(text)
            let floatVec = try await provider.embedFloat(text)
            embeddings.append(BasisEmbeddingEntry(
                text: text,
                block0: engram.block0, block1: engram.block1,
                block2: engram.block2, block3: engram.block3,
                floatBits: floatVec.map { $0.bitPattern }))
        }

        let fixture = RIBasisFixture(
            blobBase64: blob.base64EncodedString(),
            corpus: riBasisCorpus,
            embeddings: embeddings)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: path))
    }

    /// Verify the committed fixture's blob deserializes and reproduces its
    /// own pinned embeddings on the Swift side (guards against fixture drift).
    @Test("committed RI fixture blob reproduces its pinned embeddings")
    func committedFixtureIsSelfConsistent() async throws {
        let url = sharedVectorsURL(for: "ri_basis_blob.json")
        guard let data = try? Data(contentsOf: url) else {
            // Fixture is emitted/committed by this same suite; skip if absent
            // (first-run bootstrap before the emit step has produced it).
            return
        }
        let fixture = try JSONDecoder().decode(RIBasisFixture.self, from: data)
        let blob = Data(base64Encoded: fixture.blobBase64)!
        let restored = try RandomIndexingProvider(deserializing: blob)
        for entry in fixture.embeddings {
            let v = try await restored.embedFloat(entry.text)
            #expect(v.map { $0.bitPattern } == entry.floatBits,
                    "fixture float bits must match for text '\(entry.text)'")
            let e = try await restored.embed(entry.text)
            #expect(e.block0 == entry.block0 && e.block1 == entry.block1
                    && e.block2 == entry.block2 && e.block3 == entry.block3,
                    "fixture Engram blocks must match for text '\(entry.text)'")
        }
    }
}

// MARK: - SharedVectors path helper

/// Resolve a file in Tests/SharedVectors relative to this source file.
/// The fixture lives two directories up from Tests/CorpusKitTests.
func sharedVectorsURL(for name: String) -> URL {
    // #filePath → .../Tests/CorpusKitTests/<thisFile>.swift
    let thisFile = URL(fileURLWithPath: #filePath)
    return thisFile
        .deletingLastPathComponent()          // CorpusKitTests/
        .deletingLastPathComponent()          // Tests/
        .appendingPathComponent("SharedVectors")
        .appendingPathComponent(name)
}
