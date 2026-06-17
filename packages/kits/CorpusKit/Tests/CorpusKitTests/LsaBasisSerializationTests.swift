// LsaBasisSerializationTests.swift
//
// Mission 6a-i: round-trip + cross-port conformance for LSA basis
// serialization. The blob serializes the raw SVD factors U/σ/Vᵀ plus the
// TF-IDF support (vocab, idfWeights, document count). Both query embeddings
// (fold-in) and training-document embeddings must survive the round trip.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import VectorKit

private let lsaBasisCorpus: [String] = [
    "car engine drive road vehicle",
    "vehicle road transport car fuel",
    "engine fuel combustion power car",
    "dog bark run fetch animal",
    "animal run cat dog pet",
]

private let lsaBasisProbeTexts: [String] = ["car engine", "vehicle road", "dog animal", ""]

/// Rank 3 (matches the established LSA conformance suite's small-corpus rank).
private func buildTrainedLsaProvider() -> LsaProvider {
    let provider = LsaProvider(rank: 3, svdSweeps: 30)
    for doc in lsaBasisCorpus { provider.train(document: doc) }
    provider.finalize()
    return provider
}

/// Canonical LSA basis fixture. Pins both query embeddings and the doc-0
/// training-document embedding (which exercises the U factor on restore).
struct LsaBasisFixture: Codable {
    let blobBase64: String
    let corpus: [String]
    let embeddings: [BasisEmbeddingEntry]
    /// L2-normalised document embedding for training doc 0 (bit patterns).
    let doc0FloatBits: [UInt32]
}

@Suite("LsaBasisSerialization")
struct LsaBasisSerializationTests {

    @Test("train+finalize → serialize → deserialize → embed is bit-identical")
    func roundTripEmbeddingIdentity() async throws {
        let original = buildTrainedLsaProvider()
        let restored = try LsaProvider(deserializing: original.serializeBasis())
        for text in lsaBasisProbeTexts {
            let e0 = try await original.embed(text)
            let e1 = try await restored.embed(text)
            #expect(e0 == e1, "Engram must match after round-trip for '\(text)'")
            let f0 = try await original.embedFloat(text)
            let f1 = try await restored.embedFloat(text)
            #expect(f0.map { $0.bitPattern } == f1.map { $0.bitPattern },
                    "float vector must match bit-for-bit after round-trip for '\(text)'")
        }
    }

    @Test("documentEmbedding survives the round trip bit-for-bit")
    func roundTripDocumentEmbedding() throws {
        let original = buildTrainedLsaProvider()
        let restored = try LsaProvider(deserializing: original.serializeBasis())
        for d in 0..<original.documentCount {
            let o = original.documentEmbedding(at: d)
            let r = restored.documentEmbedding(at: d)
            #expect(o?.map { $0.bitPattern } == r?.map { $0.bitPattern },
                    "documentEmbedding[\(d)] must match after round-trip")
        }
    }

    @Test("restored provider reports finalized state and matching rank")
    func roundTripFinalizedState() throws {
        let original = buildTrainedLsaProvider()
        let restored = try LsaProvider(deserializing: original.serializeBasis())
        #expect(restored.isFinalized == original.isFinalized)
        #expect(restored.effectiveRank == original.effectiveRank)
        #expect(restored.vocabularySize == original.vocabularySize)
        #expect(restored.documentCount == original.documentCount)
    }

    @Test("blob begins with the LSB1 magic and the v1 format byte")
    func blobHeaderIsVersioned() {
        let bytes = [UInt8](buildTrainedLsaProvider().serializeBasis())
        #expect(bytes.count >= 5)
        #expect(Array(bytes[0..<4]) == Array("LSB1".utf8))
        #expect(bytes[4] == basisFormatVersion)
    }

    @Test("truncated blob throws decodingFailure, never crashes")
    func truncatedBlobThrows() {
        let blob = buildTrainedLsaProvider().serializeBasis()
        #expect(throws: CorpusKitError.self) {
            _ = try LsaProvider(deserializing: Data(blob.prefix(blob.count / 2)))
        }
    }

    @Test("unknown format version throws decodingFailure")
    func unknownVersionThrows() {
        var bytes = [UInt8](buildTrainedLsaProvider().serializeBasis())
        bytes[4] = 0xFF
        #expect(throws: CorpusKitError.self) {
            _ = try LsaProvider(deserializing: Data(bytes))
        }
    }

    @Test("emit canonical LSA basis fixture when LSA_BASIS_EMIT is set")
    func emitCanonicalFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["LSA_BASIS_EMIT"],
              !path.isEmpty else { return }
        let provider = buildTrainedLsaProvider()
        let blob = provider.serializeBasis()
        var embeddings: [BasisEmbeddingEntry] = []
        for text in lsaBasisProbeTexts {
            let engram = try await provider.embed(text)
            let floatVec = try await provider.embedFloat(text)
            embeddings.append(BasisEmbeddingEntry(
                text: text,
                block0: engram.block0, block1: engram.block1,
                block2: engram.block2, block3: engram.block3,
                floatBits: floatVec.map { $0.bitPattern }))
        }
        let doc0 = provider.documentEmbedding(at: 0) ?? []
        let fixture = LsaBasisFixture(
            blobBase64: blob.base64EncodedString(),
            corpus: lsaBasisCorpus, embeddings: embeddings,
            doc0FloatBits: doc0.map { $0.bitPattern })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: path))
    }

    @Test("committed LSA fixture blob reproduces its pinned embeddings")
    func committedFixtureIsSelfConsistent() async throws {
        let url = sharedVectorsURL(for: "lsa_basis_blob.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let fixture = try JSONDecoder().decode(LsaBasisFixture.self, from: data)
        let restored = try LsaProvider(deserializing: Data(base64Encoded: fixture.blobBase64)!)
        for entry in fixture.embeddings {
            let v = try await restored.embedFloat(entry.text)
            #expect(v.map { $0.bitPattern } == entry.floatBits,
                    "fixture float bits must match for '\(entry.text)'")
        }
        let doc0 = restored.documentEmbedding(at: 0) ?? []
        #expect(doc0.map { $0.bitPattern } == fixture.doc0FloatBits,
                "fixture doc-0 embedding must match")
    }
}
