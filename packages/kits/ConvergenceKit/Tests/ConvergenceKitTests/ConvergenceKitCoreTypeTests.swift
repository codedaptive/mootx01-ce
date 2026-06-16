// ConvergenceKitCoreTypeTests.swift

import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit
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

@Suite("ConvergenceKit core types")
struct ConvergenceKitCoreTypeTests {

    @Test("SyncManifest round-trips through Codable")
    func manifestRoundtripCodable() throws {
        let manifest = SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "test-zone",
            tables: [
                SyncedTable(name: "drawers", primaryKeyColumn: "row_id"),
                SyncedTable(name: "audit", direction: .bidirectional, primaryKeyColumn: "event_id", conflictPolicy: .appendOnly)
            ]
        )
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SyncManifest.self, from: encoded)
        #expect(decoded.kitID == "TestKit")
        #expect(decoded.tables.count == 2)
        #expect(decoded.tables[1].conflictPolicy == .appendOnly)
    }

    @Test("SyncRecord round-trips through Codable")
    func syncRecordRoundtrip() throws {
        let hlc = HLC(physicalTime: 1_700_000_000, logicalCount: 0, nodeID: 1)
        let record = SyncRecord(
            table: "drawers",
            event: .insert,
            rowKey: UUID(),
            values: SyncValueMap([
                "row_id": .uuid(UUID()),
                "adjective": .bitmap(0x07),
                "verbatim": .text("hello"),
                "captured_at": .timestamp(Date(timeIntervalSince1970: 1000))
            ]),
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit"
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SyncRecord.self, from: encoded)
        #expect(decoded.table == "drawers")
        #expect(decoded.event == .insert)
        #expect(decoded.kitID == "TestKit")

        guard let values = decoded.values?.asTypedValues else {
            Issue.record("values missing")
            return
        }
        #expect(values["adjective"] == .bitmap(0x07))
        #expect(values["verbatim"] == .text("hello"))
    }

    @Test("PackedHLC round-trips to HLC")
    func packedHLCRoundtrip() {
        let hlc = HLC(physicalTime: 12345, logicalCount: 67, nodeID: 8)
        let packed = PackedHLC(hlc)
        let back = packed.asHLC
        #expect(back.physicalTime == 12345)
        #expect(back.logicalCount == 67)
        #expect(back.nodeID == 8)
    }

    @Test("FingerprintWire round-trips to Fingerprint256")
    func fingerprintRoundtrip() {
        let fp = Fingerprint256(block0: 0xDEAD, block1: 0xBEEF, block2: 0xCAFE, block3: 0xBABE)
        let wire = FingerprintWire(fp)
        let back = wire.asFingerprint
        #expect(back == fp)
    }

    @Test("SyncError equality discriminates associated values")
    func syncErrorEquality() {
        #expect(
            SyncError.schemaMismatch(expected: 1, received: 2)
            == SyncError.schemaMismatch(expected: 1, received: 2)
        )
        #expect(
            SyncError.schemaMismatch(expected: 1, received: 2)
            != SyncError.schemaMismatch(expected: 1, received: 3)
        )
    }
}
