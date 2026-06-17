// NmfBasisSerializationTests.swift
//
// Mission 6a-i: round-trip + cross-port conformance for NMF basis
// serialization. The blob serializes the raw factors W (vocabSize × k) and
// H (k × numDocs) plus the term-document support (vocab, document count).
// Both query embeddings (fold-in via W) and training-document embeddings
// (column of H) must survive the round trip.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import VectorKit

private let nmfBasisCorpus: [String] = [
    "car engine drive road vehicle",
    "vehicle road transport car fuel",
    "engine fuel combustion power car",
    "dog bark run fetch animal",
    "animal run cat dog pet",
]

private let nmfBasisProbeTexts: [String] = ["car engine", "vehicle road", "dog animal", ""]

/// Rank 3, 100 iterations (matches the established NMF conformance suite).
private func buildTrainedNmfProvider() -> NmfProvider {
    let provider = NmfProvider(rank: 3, maxIterations: 100)
    for doc in nmfBasisCorpus { provider.train(document: doc) }
    provider.finalize()
    return provider
}

/// Canonical NMF basis fixture. Pins both query embeddings and the doc-0
/// training-document embedding (which exercises the H factor on restore).
struct NmfBasisFixture: Codable {
    let blobBase64: String
    let corpus: [String]
    let embeddings: [BasisEmbeddingEntry]
    let doc0FloatBits: [UInt32]
}

@Suite("NmfBasisSerialization")
struct NmfBasisSerializationTests {

    @Test("train+finalize → serialize → deserialize → embed is bit-identical")
    func roundTripEmbeddingIdentity() async throws {
        let original = buildTrainedNmfProvider()
        let restored = try NmfProvider(deserializing: original.serializeBasis())
        for text in nmfBasisProbeTexts {
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
        let original = buildTrainedNmfProvider()
        let restored = try NmfProvider(deserializing: original.serializeBasis())
        for d in 0..<original.documentCount {
            let o = original.documentEmbedding(at: d)
            let r = restored.documentEmbedding(at: d)
            #expect(o?.map { $0.bitPattern } == r?.map { $0.bitPattern },
                    "documentEmbedding[\(d)] must match after round-trip")
        }
    }

    @Test("restored provider reports finalized state and matching rank")
    func roundTripFinalizedState() throws {
        let original = buildTrainedNmfProvider()
        let restored = try NmfProvider(deserializing: original.serializeBasis())
        #expect(restored.isFinalized == original.isFinalized)
        #expect(restored.effectiveRank == original.effectiveRank)
        #expect(restored.vocabularySize == original.vocabularySize)
        #expect(restored.documentCount == original.documentCount)
    }

    @Test("blob begins with the NMB1 magic and the v1 format byte")
    func blobHeaderIsVersioned() {
        let bytes = [UInt8](buildTrainedNmfProvider().serializeBasis())
        #expect(bytes.count >= 5)
        #expect(Array(bytes[0..<4]) == Array("NMB1".utf8))
        #expect(bytes[4] == basisFormatVersion)
    }

    @Test("truncated blob throws decodingFailure, never crashes")
    func truncatedBlobThrows() {
        let blob = buildTrainedNmfProvider().serializeBasis()
        #expect(throws: CorpusKitError.self) {
            _ = try NmfProvider(deserializing: Data(blob.prefix(blob.count / 2)))
        }
    }

    @Test("unknown format version throws decodingFailure")
    func unknownVersionThrows() {
        var bytes = [UInt8](buildTrainedNmfProvider().serializeBasis())
        bytes[4] = 0xFF
        #expect(throws: CorpusKitError.self) {
            _ = try NmfProvider(deserializing: Data(bytes))
        }
    }

    @Test("emit canonical NMF basis fixture when NMF_BASIS_EMIT is set")
    func emitCanonicalFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["NMF_BASIS_EMIT"],
              !path.isEmpty else { return }
        let provider = buildTrainedNmfProvider()
        let blob = provider.serializeBasis()
        var embeddings: [BasisEmbeddingEntry] = []
        for text in nmfBasisProbeTexts {
            let engram = try await provider.embed(text)
            let floatVec = try await provider.embedFloat(text)
            embeddings.append(BasisEmbeddingEntry(
                text: text,
                block0: engram.block0, block1: engram.block1,
                block2: engram.block2, block3: engram.block3,
                floatBits: floatVec.map { $0.bitPattern }))
        }
        let doc0 = provider.documentEmbedding(at: 0) ?? []
        let fixture = NmfBasisFixture(
            blobBase64: blob.base64EncodedString(),
            corpus: nmfBasisCorpus, embeddings: embeddings,
            doc0FloatBits: doc0.map { $0.bitPattern })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: path))
    }

    @Test("committed NMF fixture blob reproduces its pinned embeddings")
    func committedFixtureIsSelfConsistent() async throws {
        let url = sharedVectorsURL(for: "nmf_basis_blob.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let fixture = try JSONDecoder().decode(NmfBasisFixture.self, from: data)
        let restored = try NmfProvider(deserializing: Data(base64Encoded: fixture.blobBase64)!)
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
