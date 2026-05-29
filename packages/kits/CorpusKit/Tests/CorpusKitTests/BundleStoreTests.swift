// BundleStoreTests.swift

import XCTest
import SubstrateTypes
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

final class BundleStoreTests: XCTestCase {

    func makeStore() async throws -> BundleStore {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: BundleStore.schemaDeclaration)
        return BundleStore(storage: storage)
    }

    func makeChunk(_ text: String) -> Chunk {
        Chunk(
            sourceID: "doc-A",
            startOffset: 0,
            length: text.count,
            text: text,
            hlc: HLC(physicalTime: 100, logicalCount: 0, nodeID: 1)
        )
    }

    func testInsertAndGet() async throws {
        let store = try await makeStore()
        let chunk = makeChunk("hello world")
        try await store.insert([chunk])
        let fetched = try await store.get(id: chunk.id)
        XCTAssertEqual(fetched?.text, "hello world")
        XCTAssertEqual(fetched?.sourceID, "doc-A")
    }

    func testGetMany() async throws {
        let store = try await makeStore()
        let chunks = (0..<5).map { makeChunk("chunk \($0)") }
        try await store.insert(chunks)
        let ids = chunks.map { $0.id }
        let fetched = try await store.getMany(ids: ids)
        XCTAssertEqual(fetched.count, 5)
    }

    func testChunksForSource() async throws {
        let store = try await makeStore()
        let chunks = (0..<3).map { makeChunk("chunk \($0)") }
        try await store.insert(chunks)
        let forDoc = try await store.chunksForSource("doc-A")
        XCTAssertEqual(forDoc.count, 3)
    }

    func testMetadataRoundtrip() async throws {
        let store = try await makeStore()
        let c = Chunk(
            sourceID: "doc-B",
            startOffset: 0,
            length: 5,
            text: "hello",
            hlc: HLC(physicalTime: 100, logicalCount: 0, nodeID: 1),
            metadata: ["author": "bob", "topic": "test"]
        )
        try await store.insert([c])
        let fetched = try await store.get(id: c.id)
        XCTAssertEqual(fetched?.metadata["author"], "bob")
        XCTAssertEqual(fetched?.metadata["topic"], "test")
    }

    func testReinsertSameIDIsIdempotentNoOp() async throws {
        // The chunks table is append-only and content-addressed by id.
        // Re-inserting a chunk with an id already present is a no-op,
        // not an error: the first write wins and the duplicate is
        // silently dropped. This is the invariant the sync layer's
        // .appendOnly conflict policy relies on.
        let store = try await makeStore()
        let c = makeChunk("original text")
        try await store.insert([c])

        // A second chunk carrying the same id but different content.
        let dup = Chunk(
            id: c.id,
            sourceID: "doc-A",
            startOffset: 0,
            length: 12,
            text: "changed text",
            hlc: HLC(physicalTime: 200, logicalCount: 0, nodeID: 1)
        )
        // Must not throw, and must not mutate the stored row.
        try await store.insert([dup])

        let fetched = try await store.get(id: c.id)
        XCTAssertEqual(fetched?.text, "original text")
        let n = try await store.count()
        XCTAssertEqual(n, 1)
    }

    func testCount() async throws {
        let store = try await makeStore()
        let chunks = (0..<7).map { makeChunk("c\($0)") }
        try await store.insert(chunks)
        let n = try await store.count()
        XCTAssertEqual(n, 7)
    }
    // MARK: - Content-addressed id (Step 3.5 follow-up)

    func testDeriveIDMatchesCrossLanguageGroundTruth() {
        // These expected values are the RFC 4122 v5 UUIDs computed by
        // the reference (Python uuid5 / Rust Uuid::new_v5) over the same
        // namespace and name encoding. Asserting the literal values here
        // and in the Rust parity test guarantees byte-identity across
        // the Swift and Rust ports by construction.
        XCTAssertEqual(
            Chunk.deriveID(sourceID: "doc-A", startOffset: 0, text: "hello world").uuidString.lowercased(),
            "e12ecb90-0ba9-588d-8d83-c0266f6aa2d5")
        XCTAssertEqual(
            Chunk.deriveID(sourceID: "doc-A", startOffset: 800, text: "second").uuidString.lowercased(),
            "6f3a935a-cd10-5083-b143-f330be4d81da")
        XCTAssertEqual(
            Chunk.deriveID(sourceID: "src-E", startOffset: 0, text: "original").uuidString.lowercased(),
            "dc121d31-5fec-5404-9208-01a11d044191")
    }

    func testDeriveIDIsContentSensitive() {
        // Different offset or different text yields a different id.
        XCTAssertNotEqual(
            Chunk.deriveID(sourceID: "doc-A", startOffset: 0, text: "x"),
            Chunk.deriveID(sourceID: "doc-A", startOffset: 1, text: "x"))
        XCTAssertNotEqual(
            Chunk.deriveID(sourceID: "doc-A", startOffset: 0, text: "x"),
            Chunk.deriveID(sourceID: "doc-A", startOffset: 0, text: "y"))
    }

    func testReingestionIsIdempotent() async throws {
        // Re-chunking the same source text and re-inserting must not
        // grow the store: content-addressed ids make the second pass a
        // batch of duplicate-key no-ops. This is the guarantee the
        // sync layer's .appendOnly conflict policy depends on.
        let store = try await makeStore()
        let c = Chunk(
            sourceID: "doc-Z", startOffset: 0, length: 5, text: "hello",
            hlc: HLC(physicalTime: 100, logicalCount: 0, nodeID: 1))
        try await store.insert([c])

        // A fresh Chunk built from identical content gets the same id,
        // even with a different HLC tag (hlc is not part of identity).
        let again = Chunk(
            sourceID: "doc-Z", startOffset: 0, length: 5, text: "hello",
            hlc: HLC(physicalTime: 999, logicalCount: 0, nodeID: 2))
        XCTAssertEqual(c.id, again.id)
        try await store.insert([again])

        let n = try await store.count()
        XCTAssertEqual(n, 1)
    }

}
