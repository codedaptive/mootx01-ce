// MerkleHashTests.swift
//
// Conformance tests for the Merkle content-integrity hash pipeline.
// These vectors are shared with the Rust port; both must produce
// byte-identical output.

import Testing
import Foundation
import SubstrateLib
import SubstrateTypes

/// The test UUID used across conformance vectors.
/// 12345678-1234-1234-1234-123456789ABC
private let testUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

@Suite("MerkleHash — leaf hash pipeline")
struct MerkleHashLeafTests {

    @Test("empty content, no vectors")
    func leafEmptyContentNoVectors() {
        let hash = MerkleHash.leaf(drawerId: testUUID, content: [], vectors: [])
        let hash2 = MerkleHash.leaf(drawerId: testUUID, content: [], vectors: [])
        #expect(hash == hash2, "leaf hash must be deterministic")
    }

    @Test("domain separation: leaf vs tombstone")
    func leafVsTombstone() {
        let leafHash = MerkleHash.leaf(drawerId: testUUID, content: [], vectors: [])
        let tombstoneHash = MerkleHash.tombstone(drawerId: testUUID)
        #expect(leafHash != tombstoneHash,
                "leaf and tombstone must differ (domain separation)")
    }

    @Test("different content produces different hash")
    func differentContent() {
        let h1 = MerkleHash.leaf(drawerId: testUUID,
                                  content: Array("hello".utf8), vectors: [])
        let h2 = MerkleHash.leaf(drawerId: testUUID,
                                  content: Array("world".utf8), vectors: [])
        #expect(h1 != h2, "different content = different hash")
    }

    @Test("with vectors — deterministic")
    func leafWithVectors() {
        let vecs = [
            MerkleVectorInput(modelID: "model-a", vectorIndex: 0,
                              floats: [1.0, 2.0, 3.0]),
            MerkleVectorInput(modelID: "model-a", vectorIndex: 1,
                              floats: [4.0, 5.0, 6.0]),
        ]
        let h1 = MerkleHash.leaf(drawerId: testUUID,
                                  content: Array("test".utf8), vectors: vecs)
        let h2 = MerkleHash.leaf(drawerId: testUUID,
                                  content: Array("test".utf8), vectors: vecs)
        #expect(h1 == h2, "deterministic with vectors")
    }

    @Test("vector sort order independent")
    func vectorSortOrderIndependent() {
        let v1 = [
            MerkleVectorInput(modelID: "model-b", vectorIndex: 0, floats: [1.0]),
            MerkleVectorInput(modelID: "model-a", vectorIndex: 0, floats: [2.0]),
        ]
        let v2 = [
            MerkleVectorInput(modelID: "model-a", vectorIndex: 0, floats: [2.0]),
            MerkleVectorInput(modelID: "model-b", vectorIndex: 0, floats: [1.0]),
        ]
        let h1 = MerkleHash.leaf(drawerId: testUUID,
                                  content: Array("x".utf8), vectors: v1)
        let h2 = MerkleHash.leaf(drawerId: testUUID,
                                  content: Array("x".utf8), vectors: v2)
        #expect(h1 == h2, "vector sort order must not affect hash")
    }

    @Test("vectors change the hash")
    func vectorsChangeHash() {
        let noVecs = MerkleHash.leaf(drawerId: testUUID,
                                     content: Array("data".utf8), vectors: [])
        let withVecs = MerkleHash.leaf(
            drawerId: testUUID,
            content: Array("data".utf8),
            vectors: [MerkleVectorInput(modelID: "m", vectorIndex: 0,
                                         floats: [1.0])])
        #expect(noVecs != withVecs, "adding vectors must change the hash")
    }

    // WS2-F4 security regression tests — v2 identity binding.
    // These tests verify that the v2 canonical leaf encoding binds vector
    // identity (modelID + vectorIndex) into the preimage, so swapping a
    // vector from a different model or slot changes the leaf hash.

    @Test("v2 binding: different modelID produces different hash")
    func v2BindingModelIDChangesHash() {
        // Same floats, different modelID — must produce different hash.
        let h1 = MerkleHash.leaf(
            drawerId: testUUID,
            content: Array("test".utf8),
            vectors: [MerkleVectorInput(modelID: "model-a", vectorIndex: 0,
                                         floats: [1.0, 2.0, 3.0])])
        let h2 = MerkleHash.leaf(
            drawerId: testUUID,
            content: Array("test".utf8),
            vectors: [MerkleVectorInput(modelID: "model-b", vectorIndex: 0,
                                         floats: [1.0, 2.0, 3.0])])
        #expect(h1 != h2,
                "v2 identity binding: same floats with different modelID must change the hash")
    }

    @Test("v2 binding: different vectorIndex produces different hash")
    func v2BindingVectorIndexChangesHash() {
        // Same floats, same modelID, different vectorIndex — must produce different hash.
        let h1 = MerkleHash.leaf(
            drawerId: testUUID,
            content: Array("test".utf8),
            vectors: [MerkleVectorInput(modelID: "model-a", vectorIndex: 0,
                                         floats: [1.0, 2.0, 3.0])])
        let h2 = MerkleHash.leaf(
            drawerId: testUUID,
            content: Array("test".utf8),
            vectors: [MerkleVectorInput(modelID: "model-a", vectorIndex: 1,
                                         floats: [1.0, 2.0, 3.0])])
        #expect(h1 != h2,
                "v2 identity binding: same floats with different vectorIndex must change the hash")
    }

    @Test("v2 binding: cross-port conformance vector (pinned)")
    func v2CrossPortConformanceVector() {
        // Pinned SHA-256 of v2 canonical leaf encoding for the shared
        // cross-port conformance vector. Both Swift and Rust must produce
        // this exact value. Seed: drawer 12345678-1234-1234-1234-123456789ABC,
        // content "hello", one vector model-a/idx=0/[1.0, 2.0].
        //
        // Derivation (v2 layout):
        //   domain tag: 0x00
        //   drawer id: 12 34 56 78 12 34 12 34 12 34 12 34 56 78 9a bc
        //   content len: 00 00 00 00 00 00 00 05
        //   content: 68 65 6c 6c 6f
        //   vector count: 00 00 00 01
        //   model_id len: 00 00 00 07
        //   model_id: 6d 6f 64 65 6c 2d 61
        //   vector_index: 00 00 00 00
        //   float count: 00 00 00 02
        //   float[0] 1.0f: 00 00 80 3f (LE)
        //   float[1] 2.0f: 00 00 00 40 (LE)
        //
        // The expected hex is computed by sha256(above preimage).
        // Run `swift test --filter v2CrossPortConformanceVector -- dump` to capture.
        // Pinned hash value: SHA-256 of v2 preimage described above.
        // Identical to Rust test v2_cross_port_conformance_vector — byte-identical
        // across ports is the conformance gate.
        let expectedHex = "cb18e8a5dcff4eb955f731bf75c078b9390a175ff225cc67a1ff0f1d3fa192dc"
        let hash = MerkleHash.leaf(
            drawerId: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            content: Array("hello".utf8),
            vectors: [MerkleVectorInput(modelID: "model-a", vectorIndex: 0,
                                         floats: [1.0, 2.0])])
        let hex = hash.bytes.map { String(format: "%02x", $0) }.joined()
        #expect(hex == expectedHex,
                "v2 cross-port conformance vector mismatch — Swift and Rust must agree byte-for-byte")
    }
}

@Suite("MerkleHash — interior hash pipeline")
struct MerkleHashInteriorTests {

    @Test("empty children returns MerkleRoot.empty")
    func interiorEmpty() {
        let root = MerkleHash.interior(childHashes: [])
        #expect(root == MerkleRoot.empty)
    }

    @Test("order-independent")
    func interiorOrderIndependent() {
        let id1 = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let id2 = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let h1 = ContentHash(bytes: [UInt8](repeating: 0x11, count: 32))
        let h2 = ContentHash(bytes: [UInt8](repeating: 0x22, count: 32))

        let root1 = MerkleHash.interior(childHashes: [(id1, h1), (id2, h2)])
        let root2 = MerkleHash.interior(childHashes: [(id2, h2), (id1, h1)])
        #expect(root1 == root2, "interior hash must be order-independent")
    }

    @Test("single child produces non-empty root")
    func singleChild() {
        let root = MerkleHash.interior(childHashes: [
            (testUUID, ContentHash(bytes: [UInt8](repeating: 0xAB, count: 32)))
        ])
        #expect(root != MerkleRoot.empty)
    }
}

@Suite("MerkleHash — interior hash pipeline (MerkleRoot overload)")
struct MerkleHashInteriorRootsTests {

    @Test("empty children returns MerkleRoot.empty")
    func interiorRootsEmpty() {
        let root = MerkleHash.interior(childRoots: [])
        #expect(root == MerkleRoot.empty)
    }

    @Test("order-independent")
    func interiorRootsOrderIndependent() {
        let id1 = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let id2 = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let r1 = MerkleRoot(bytes: [UInt8](repeating: 0x11, count: 32))
        let r2 = MerkleRoot(bytes: [UInt8](repeating: 0x22, count: 32))

        let root1 = MerkleHash.interior(childRoots: [(id1, r1), (id2, r2)])
        let root2 = MerkleHash.interior(childRoots: [(id2, r2), (id1, r1)])
        #expect(root1 == root2, "interior hash must be order-independent")
    }

    @Test("same raw bytes produce identical hash regardless of type wrapper")
    func interiorRootsMatchesContentHashOverload() {
        let id1 = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let id2 = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let bytes1 = [UInt8](repeating: 0x11, count: 32)
        let bytes2 = [UInt8](repeating: 0x22, count: 32)

        let fromContent = MerkleHash.interior(childHashes: [
            (id1, ContentHash(bytes: bytes1)),
            (id2, ContentHash(bytes: bytes2)),
        ])
        let fromRoots = MerkleHash.interior(childRoots: [
            (id1, MerkleRoot(bytes: bytes1)),
            (id2, MerkleRoot(bytes: bytes2)),
        ])
        #expect(fromContent.bytes == fromRoots.bytes,
                "same raw bytes must produce the same hash regardless of type wrapper")
    }
}

@Suite("MerkleHash — tombstone hash pipeline")
struct MerkleHashTombstoneTests {

    @Test("deterministic")
    func tombstoneDeterministic() {
        let ts1 = MerkleHash.tombstone(drawerId: testUUID)
        let ts2 = MerkleHash.tombstone(drawerId: testUUID)
        #expect(ts1 == ts2, "tombstone must be deterministic")
    }

    @Test("different drawer id produces different hash")
    func tombstoneDifferentDrawer() {
        let other = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let ts1 = MerkleHash.tombstone(drawerId: testUUID)
        let ts2 = MerkleHash.tombstone(drawerId: other)
        #expect(ts1 != ts2, "different drawer id = different tombstone hash")
    }
}

@Suite("MerkleHash — domain separation")
struct MerkleHashDomainSeparationTests {

    @Test("leaf vs interior always different")
    func leafVsInterior() {
        let leafHash = MerkleHash.leaf(drawerId: testUUID, content: [], vectors: [])
        let root = MerkleHash.interior(childHashes: [(testUUID, leafHash)])
        #expect(leafHash.bytes != root.bytes,
                "leaf hash and interior root must differ")
    }

    @Test("all three functions produce distinct hashes for same input")
    func allThreeDistinct() {
        let leafH = MerkleHash.leaf(drawerId: testUUID, content: [], vectors: [])
        let tombH = MerkleHash.tombstone(drawerId: testUUID)
        let intH = MerkleHash.interior(childHashes: [(testUUID, leafH)])

        #expect(leafH != tombH, "leaf != tombstone")
        #expect(leafH.bytes != intH.bytes, "leaf != interior")
        #expect(tombH.bytes != intH.bytes, "tombstone != interior")
    }
}
