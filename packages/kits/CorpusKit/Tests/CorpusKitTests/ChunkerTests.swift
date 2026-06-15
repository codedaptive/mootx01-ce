// ChunkerTests.swift

import Testing
import SubstrateTypes
@testable import CorpusKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

@Suite("Chunker")
struct ChunkerTests {

    @Test func chunkerProducesNonEmptyChunks() {
        let text = String(repeating: "This is a test sentence. ", count: 50)
        var gen = HLCGenerator(nodeID: 1)
        let chunks = Chunker.chunk(
            text: text,
            sourceID: "doc-1",
            configuration: ChunkerConfiguration(targetChars: 200, overlapChars: 20),
            hlcGenerator: &gen
        )
        #expect(!chunks.isEmpty)
        for c in chunks {
            #expect(!c.text.isEmpty)
            #expect(c.sourceID == "doc-1")
        }
    }

    @Test func chunkerRespectsTargetSize() {
        let text = String(repeating: "Sentence. ", count: 200)  // ~2000 chars
        var gen = HLCGenerator(nodeID: 1)
        let chunks = Chunker.chunk(
            text: text,
            sourceID: "doc-2",
            configuration: ChunkerConfiguration(targetChars: 300, overlapChars: 0),
            hlcGenerator: &gen
        )
        #expect(chunks.count > 1)
        // Allow some slack since chunker respects sentence boundaries.
        for c in chunks {
            #expect(c.text.count < 600, "chunk grossly oversized: \(c.text.count)")
        }
    }

    @Test func chunkerHLCMonotonic() {
        let text = String(repeating: "One. Two. Three. ", count: 30)
        var gen = HLCGenerator(nodeID: 1)
        let chunks = Chunker.chunk(
            text: text,
            sourceID: "doc-3",
            configuration: ChunkerConfiguration(targetChars: 100, overlapChars: 10),
            hlcGenerator: &gen
        )
        for i in 0..<(chunks.count - 1) {
            #expect(chunks[i].hlc < chunks[i + 1].hlc,
                    "HLCs not monotonic at chunk \(i)")
        }
    }
}
