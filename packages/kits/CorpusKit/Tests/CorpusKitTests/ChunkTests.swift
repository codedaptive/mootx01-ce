// ChunkTests.swift
//
// Peer suite for Chunk and ScoredChunk (Sources/CorpusKit/Chunk.swift).
// The cross-language deriveID ground-truth vectors are asserted in
// BundleStoreTests (left there on conversion); this suite covers the
// two initializers, content-addressed identity, Equatable, Codable
// round-trip, and the ScoredChunk result wrapper.

import Testing
import Foundation
import SubstrateTypes
import CorpusKit

@Suite("Chunk / ScoredChunk")
struct ChunkTests {

    private func hlc() -> HLC { HLC(physicalTime: 100, logicalCount: 0, nodeID: 1) }

    @Test func contentAddressedInitDerivesID() {
        let c = Chunk(
            sourceID: "doc-A", startOffset: 0, length: 11, text: "hello world",
            hlc: hlc())
        #expect(c.id == Chunk.deriveID(sourceID: "doc-A", startOffset: 0, text: "hello world"))
    }

    @Test func explicitIDInitPreservesID() {
        let id = UUID()
        let c = Chunk(
            id: id, sourceID: "doc-A", startOffset: 0, length: 5, text: "hello",
            hlc: hlc())
        #expect(c.id == id)
    }

    @Test func defaultMetadataIsEmpty() {
        let c = Chunk(
            sourceID: "doc-A", startOffset: 0, length: 5, text: "hello", hlc: hlc())
        #expect(c.metadata.isEmpty)
    }

    @Test func equalChunksCompareEqual() {
        let a = Chunk(sourceID: "doc-A", startOffset: 0, length: 5, text: "hello", hlc: hlc())
        let b = Chunk(sourceID: "doc-A", startOffset: 0, length: 5, text: "hello", hlc: hlc())
        #expect(a == b)
    }

    @Test func codableRoundTripPreservesFields() throws {
        let original = Chunk(
            sourceID: "doc-B", startOffset: 7, length: 5, text: "hello",
            hlc: hlc(), metadata: ["author": "bob"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Chunk.self, from: data)
        #expect(decoded == original)
        #expect(decoded.metadata["author"] == "bob")
    }

    @Test func scoredChunkDefaultsSubScoresToNil() {
        let c = Chunk(sourceID: "doc-A", startOffset: 0, length: 5, text: "hello", hlc: hlc())
        let scored = ScoredChunk(chunk: c, score: 0.5)
        #expect(scored.score == 0.5)
        #expect(scored.vectorScore == nil)
        #expect(scored.keywordScore == nil)
    }

    @Test func scoredChunkStoresSubScores() {
        let c = Chunk(sourceID: "doc-A", startOffset: 0, length: 5, text: "hello", hlc: hlc())
        let scored = ScoredChunk(chunk: c, score: 0.9, vectorScore: 0.7, keywordScore: 0.2)
        #expect(scored.chunk == c)
        #expect(scored.vectorScore == 0.7)
        #expect(scored.keywordScore == 0.2)
    }
}
