// KeyedCommitmentTests.swift
//
// Conformance tests for the keyed-commitment API.
// These vectors are shared with the Rust port; both must produce
// byte-identical output.

import Testing
import Foundation
import SubstrateLib
import SubstrateTypes

private let testUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
private let testKey: [UInt8] = [UInt8](repeating: 0xAB, count: 32)

@Suite("KeyedCommitment — commitment API")
struct KeyedCommitmentTests {

    @Test("deterministic")
    func commitmentDeterministic() {
        let c1 = KeyedCommitment.commit(key: testKey, keyVersion: 1,
                                         drawerId: testUUID,
                                         content: Array("hello".utf8),
                                         vectors: [])
        let c2 = KeyedCommitment.commit(key: testKey, keyVersion: 1,
                                         drawerId: testUUID,
                                         content: Array("hello".utf8),
                                         vectors: [])
        #expect(c1.hmacBytes == c2.hmacBytes, "commitment must be deterministic")
        #expect(c1.keyVersion == 1)
    }

    @Test("domain separation: commitment vs content hash")
    func domainSeparation() {
        let commitment = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID,
            content: Array("data".utf8),
            vectors: [])
        let contentHash = MerkleHash.leaf(
            drawerId: testUUID,
            content: Array("data".utf8),
            vectors: [])
        #expect(commitment.hmacBytes != contentHash.bytes,
                "commitment and content hash must differ")
    }

    @Test("different key produces different commitment")
    func differentKey() {
        let c1 = KeyedCommitment.commit(
            key: [UInt8](repeating: 0x01, count: 32), keyVersion: 1,
            drawerId: testUUID, content: Array("data".utf8), vectors: [])
        let c2 = KeyedCommitment.commit(
            key: [UInt8](repeating: 0x02, count: 32), keyVersion: 1,
            drawerId: testUUID, content: Array("data".utf8), vectors: [])
        #expect(c1.hmacBytes != c2.hmacBytes,
                "different key = different commitment")
    }

    @Test("key version preserved")
    func keyVersionPreserved() {
        let c = KeyedCommitment.commit(key: testKey, keyVersion: 42,
                                        drawerId: testUUID,
                                        content: [], vectors: [])
        #expect(c.keyVersion == 42)
    }

    @Test("commitment with vectors")
    func commitmentWithVectors() {
        let vecs = [
            MerkleVectorInput(modelID: "model-a", vectorIndex: 0,
                              floats: [1.0, 2.0]),
        ]
        let c1 = KeyedCommitment.commit(key: testKey, keyVersion: 1,
                                         drawerId: testUUID,
                                         content: Array("content".utf8),
                                         vectors: vecs)
        let c2 = KeyedCommitment.commit(key: testKey, keyVersion: 1,
                                         drawerId: testUUID,
                                         content: Array("content".utf8),
                                         vectors: vecs)
        #expect(c1.hmacBytes == c2.hmacBytes, "deterministic with vectors")

        let c3 = KeyedCommitment.commit(key: testKey, keyVersion: 1,
                                         drawerId: testUUID,
                                         content: Array("content".utf8),
                                         vectors: [])
        #expect(c1.hmacBytes != c3.hmacBytes, "vectors change the commitment")
    }

    @Test("KeyedCommitmentValue hex string")
    func hexString() {
        let value = KeyedCommitmentValue(
            hmacBytes: [UInt8](repeating: 0xAB, count: 32),
            keyVersion: 1)
        #expect(value.hexString == String(repeating: "ab", count: 32))
    }
}

@Suite("KeyedCommitmentAuditEntry — expunge provenance record")
struct KeyedCommitmentAuditEntryTests {

    @Test("round-trip: append and read back with all fields intact")
    func roundTrip() {
        let commitment = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID,
            content: Array("expunged data".utf8),
            vectors: [])
        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 42)
        let entry = KeyedCommitmentAuditEntry(
            drawerId: testUUID,
            commitment: commitment,
            tombstoneHLC: hlc,
            reason: "GDPR request #12345")

        var log = CommitmentAuditLog()
        log.add(entry)

        #expect(log.count == 1)
        let entries = log.entries(forDrawer: testUUID)
        #expect(entries.count == 1)

        let recovered = entries[0]
        #expect(recovered.drawerId == testUUID)
        #expect(recovered.commitment == commitment)
        #expect(recovered.tombstoneHLC == hlc)
        #expect(recovered.reason == "GDPR request #12345")
    }

    @Test("idempotent add")
    func idempotentAdd() {
        let commitment = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID, content: [], vectors: [])
        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 42)
        let entry = KeyedCommitmentAuditEntry(
            drawerId: testUUID,
            commitment: commitment,
            tombstoneHLC: hlc,
            reason: "test")

        var log = CommitmentAuditLog()
        log.add(entry)
        log.add(entry) // idempotent
        #expect(log.count == 1, "re-adding same entry is a no-op")
    }

    @Test("merge two logs")
    func mergeLogs() {
        let c1 = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID, content: Array("a".utf8), vectors: [])
        let c2 = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID, content: Array("b".utf8), vectors: [])

        let hlc1 = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 42)
        let hlc2 = HLC(physicalTime: 2_000_000, logicalCount: 1, nodeID: 42)

        var log1 = CommitmentAuditLog()
        log1.add(KeyedCommitmentAuditEntry(
            drawerId: testUUID, commitment: c1,
            tombstoneHLC: hlc1, reason: "first"))

        var log2 = CommitmentAuditLog()
        log2.add(KeyedCommitmentAuditEntry(
            drawerId: testUUID, commitment: c2,
            tombstoneHLC: hlc2, reason: "second"))

        log1.merge(log2)
        #expect(log1.count == 2, "merged log has entries from both")
    }

    @Test("deterministic content ID")
    func deterministicID() {
        let commitment = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID, content: [], vectors: [])
        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 42)
        let e1 = KeyedCommitmentAuditEntry(
            drawerId: testUUID, commitment: commitment,
            tombstoneHLC: hlc, reason: "test")
        let e2 = KeyedCommitmentAuditEntry(
            drawerId: testUUID, commitment: commitment,
            tombstoneHLC: hlc, reason: "test")
        #expect(e1.id == e2.id, "same fields = same deterministic ID")
        // Cross-port conformance vector: Rust must produce the same ID.
        let expectedHex = "8a0cbc8846dcdbd7d60032f55278bbc3ef5aa5575c584d248036d46e08c0a7c6"
        let actualHex = e1.id.map { String(format: "%02x", $0) }.joined()
        #expect(actualHex == expectedHex, "cross-port conformance: content-ID must match Rust")
    }

    @Test("ordered entries returns by tombstone HLC")
    func orderedEntries() {
        let c1 = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID, content: Array("a".utf8), vectors: [])
        let c2 = KeyedCommitment.commit(
            key: testKey, keyVersion: 1,
            drawerId: testUUID, content: Array("b".utf8), vectors: [])

        let hlcEarly = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 42)
        let hlcLate = HLC(physicalTime: 2_000_000, logicalCount: 1, nodeID: 42)

        var log = CommitmentAuditLog()
        // Add later entry first.
        log.add(KeyedCommitmentAuditEntry(
            drawerId: testUUID, commitment: c2,
            tombstoneHLC: hlcLate, reason: "late"))
        log.add(KeyedCommitmentAuditEntry(
            drawerId: testUUID, commitment: c1,
            tombstoneHLC: hlcEarly, reason: "early"))

        let ordered = log.orderedEntries
        #expect(ordered[0].reason == "early")
        #expect(ordered[1].reason == "late")
    }
}
