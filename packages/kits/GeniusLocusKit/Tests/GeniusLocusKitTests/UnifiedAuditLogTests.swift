// UnifiedAuditLogTests.swift
//
// Mission GLK-03. Verifies the unified audit log's CRDT properties
// (convergence under set union, deterministic projection), the
// asOf reconstruction across both tiers, and the rebuild-from-audit
// recovery path. Cross-tier scenarios interleave entries from
// `.locus` and `.rag` tiers so each test exercises the unification
// the mission is delivering.

import Testing
import SubstrateTypes
import Foundation
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
@testable import GeniusLocusKit

@Suite("Unified audit log")
struct UnifiedAuditLogTests {

    // MARK: - SHA-256 vector (FIPS 180-4)
    //
    // Guards the in-module SHA-256 against drift. The "abc" vector is
    // the FIPS 180-4 §B.1 published test value.
    @Test
    func sha256AbcVector() {
        let hash = UnifiedAuditSHA256.hash(Array("abc".utf8))
        let expected: [UInt8] = [
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
            0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
            0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
            0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
        ]
        #expect(hash == expected)
    }

    @Test
    func sha256EmptyVector() {
        let hash = UnifiedAuditSHA256.hash([])
        let expected: [UInt8] = [
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
            0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
            0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
            0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
        ]
        #expect(hash == expected)
    }

    // MARK: - Entry ID determinism

    @Test
    func entryIDIsDeterministic() {
        let row = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 7)
        let a = UnifiedAuditEntry(
            tier: .locus, hlc: hlc, verb: .capture, rowID: row,
            fieldPath: "adjective.state",
            beforeValue: .null,
            afterValue: .bitmap(0x01)
        )
        let b = UnifiedAuditEntry(
            tier: .locus, hlc: hlc, verb: .capture, rowID: row,
            fieldPath: "adjective.state",
            beforeValue: .null,
            afterValue: .bitmap(0x01)
        )
        #expect(a.id == b.id)
        #expect(a.id.count == 32)
    }

    @Test
    func entryIDDiffersWhenTierDiffers() {
        let row = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 7)
        let locus = UnifiedAuditEntry(
            tier: .locus, hlc: hlc, verb: .capture, rowID: row,
            fieldPath: "adjective.state",
            beforeValue: .null, afterValue: .bitmap(0x01)
        )
        let rag = UnifiedAuditEntry(
            tier: .rag, hlc: hlc, verb: .capture, rowID: row,
            fieldPath: "adjective.state",
            beforeValue: .null, afterValue: .bitmap(0x01)
        )
        #expect(locus.id != rag.id)
    }

    // MARK: - G-Set CRDT properties

    @Test
    func addIsIdempotent() {
        var log = UnifiedAuditLog()
        let e = makeEntry(tier: .locus, time: 1, row: rowA, field: "f", value: .integer(1))
        log.add(e)
        log.add(e)
        log.add(e)
        #expect(log.count == 1)
    }

    @Test
    func mergeIsCommutativeAndIdempotent() {
        let e1 = makeEntry(tier: .locus, time: 1, row: rowA, field: "f", value: .integer(1))
        let e2 = makeEntry(tier: .rag,   time: 2, row: rowB, field: "g", value: .integer(2))
        let e3 = makeEntry(tier: .locus, time: 3, row: rowA, field: "f", value: .integer(3))
        var a = UnifiedAuditLog(entries: [e1, e2])
        let b = UnifiedAuditLog(entries: [e2, e3])
        var aPlusB = a
        aPlusB.merge(b)
        var bPlusA = b
        bPlusA.merge(a)
        #expect(aPlusB == bPlusA)
        // Idempotent: merging in the union of both does not grow either.
        a.merge(b)
        a.merge(b)
        #expect(a.count == 3)
    }

    // MARK: - Cross-tier convergence (mission test requirement #1)

    @Test
    func crossTierConvergence() {
        // Two replicas hold overlapping events from both tiers.
        // Replica 1: locus capture(rowA), rag capture(rowB), rag mutate(rowB)
        // Replica 2: locus capture(rowA) [same], locus mutate(rowA), rag capture(rowB) [same]
        // After union, both must project to identical state.
        let locusCapA = makeEntry(tier: .locus, time: 10, row: rowA,
                                    field: "adjective.state",
                                    value: .bitmap(0b0001), verb: .capture)
        let ragCapB = makeEntry(tier: .rag, time: 20, row: rowB,
                                  field: "chunk.tokens",
                                  value: .integer(512), verb: .capture)
        let ragMutB = makeEntry(tier: .rag, time: 30, row: rowB,
                                  field: "chunk.tokens",
                                  value: .integer(384), verb: .mutate)
        let locusMutA = makeEntry(tier: .locus, time: 25, row: rowA,
                                    field: "adjective.state",
                                    value: .bitmap(0b0011), verb: .mutate)

        var r1 = UnifiedAuditLog()
        r1.add(locusCapA); r1.add(ragCapB); r1.add(ragMutB)
        var r2 = UnifiedAuditLog()
        r2.add(locusCapA); r2.add(locusMutA); r2.add(ragCapB)

        r1.merge(r2)
        r2.merge(r1)

        let p1 = AuditProjectionFold.project(r1)
        let p2 = AuditProjectionFold.project(r2)
        #expect(p1 == p2)

        // Sanity check: post-fold state matches the latest per-field.
        let locusRow = p1.row(tier: .locus, rowID: rowA)
        #expect(locusRow != nil)
        #expect(locusRow?.fields["adjective.state"] == .bitmap(0b0011))
        #expect(locusRow?.lastVerb == .mutate)

        let ragRow = p1.row(tier: .rag, rowID: rowB)
        #expect(ragRow != nil)
        #expect(ragRow?.fields["chunk.tokens"] == .integer(384))
        #expect(ragRow?.lastVerb == .mutate)
    }

    @Test
    func projectionIndependentOfArrivalOrder() {
        // Add the same set of events in three different orders;
        // projection must be identical (cookbook §5.4).
        let events = [
            makeEntry(tier: .locus, time: 10, row: rowA, field: "f", value: .integer(1), verb: .capture),
            makeEntry(tier: .rag,   time: 20, row: rowB, field: "g", value: .integer(2), verb: .capture),
            makeEntry(tier: .locus, time: 30, row: rowA, field: "f", value: .integer(3), verb: .mutate),
            makeEntry(tier: .rag,   time: 40, row: rowB, field: "g", value: .integer(4), verb: .mutate),
        ]
        let p1 = AuditProjectionFold.project(UnifiedAuditLog(entries: events))
        let p2 = AuditProjectionFold.project(UnifiedAuditLog(entries: events.reversed()))
        let shuffled: [UnifiedAuditEntry] = [events[2], events[0], events[3], events[1]]
        let p3 = AuditProjectionFold.project(UnifiedAuditLog(entries: shuffled))
        #expect(p1 == p2)
        #expect(p2 == p3)
    }

    // MARK: - asOf reconstruction (mission test requirement #2)

    @Test
    func asOfReconstructionSpansBothTiers() {
        let t10 = HLC(physicalTime: 10, logicalCount: 0, nodeID: 1)
        let t20 = HLC(physicalTime: 20, logicalCount: 0, nodeID: 1)
        let t30 = HLC(physicalTime: 30, logicalCount: 0, nodeID: 1)

        let events = [
            makeEntry(tier: .locus, hlc: t10, row: rowA,
                       field: "adjective.state",
                       value: .bitmap(0b0001), verb: .capture),
            makeEntry(tier: .rag, hlc: t20, row: rowB,
                       field: "chunk.tokens",
                       value: .integer(100), verb: .capture),
            makeEntry(tier: .locus, hlc: t30, row: rowA,
                       field: "adjective.state",
                       value: .bitmap(0b0011), verb: .mutate),
        ]
        let log = UnifiedAuditLog(entries: events)

        // asOf t20: locus row visible at initial value, rag row visible
        // at its capture value, no mutate yet applied to locus.
        let asOf20 = AuditProjectionFold.project(log, asOf: t20)
        #expect(asOf20.row(tier: .locus, rowID: rowA)?.fields["adjective.state"] == .bitmap(0b0001))
        #expect(asOf20.row(tier: .rag, rowID: rowB)?.fields["chunk.tokens"] == .integer(100))

        // asOf t30: locus row visible at mutated value.
        let asOf30 = AuditProjectionFold.project(log, asOf: t30)
        #expect(asOf30.row(tier: .locus, rowID: rowA)?.fields["adjective.state"] == .bitmap(0b0011))

        // asOf at HLC zero: nothing visible yet.
        let asOfZero = AuditProjectionFold.project(log, asOf: .zero)
        #expect(asOfZero.isEmpty)
    }

    // MARK: - Recovery (mission test requirement #3)

    @Test
    func recoveryReproducesLiveProjection() {
        let events = [
            makeEntry(tier: .locus, time: 10, row: rowA, field: "f", value: .integer(1), verb: .capture),
            makeEntry(tier: .rag,   time: 15, row: rowB, field: "g", value: .integer(2), verb: .capture),
            makeEntry(tier: .locus, time: 20, row: rowA, field: "f", value: .integer(3), verb: .mutate),
            makeEntry(tier: .rag,   time: 25, row: rowB, field: "g", value: .integer(7), verb: .mutate),
        ]
        let log = UnifiedAuditLog(entries: events)
        let live = AuditProjectionFold.project(log)

        let result = AuditRecovery.rebuild(from: log)
        #expect(result.entriesReplayed == 4)
        #expect(result.rowsRebuilt == 2)
        #expect(result.locusRows == 1)
        #expect(result.ragRows == 1)
        #expect(result.projection == live)

        let divergence = AuditRecovery.verify(rebuilt: result.projection, against: live)
        #expect(divergence.isEmpty)
    }

    @Test
    func recoveryStreamingReplayMatchesBatch() {
        let events = [
            makeEntry(tier: .locus, time: 10, row: rowA, field: "f", value: .integer(1), verb: .capture),
            makeEntry(tier: .rag,   time: 20, row: rowB, field: "g", value: .integer(2), verb: .capture),
            makeEntry(tier: .locus, time: 30, row: rowA, field: "f", value: .integer(3), verb: .mutate),
        ]
        let batch = AuditRecovery.rebuild(from: UnifiedAuditLog(entries: events))
        let streamed = AuditRecovery.rebuildStreaming(from: events)
        #expect(streamed.projection == batch.projection)
    }

    @Test
    func recoveryAsOfReconstructsHistoricalState() {
        let t10 = HLC(physicalTime: 10, logicalCount: 0, nodeID: 1)
        let t30 = HLC(physicalTime: 30, logicalCount: 0, nodeID: 1)
        let events = [
            makeEntry(tier: .locus, hlc: t10, row: rowA, field: "f", value: .integer(1), verb: .capture),
            makeEntry(tier: .rag,   hlc: t30, row: rowB, field: "g", value: .integer(2), verb: .capture),
        ]
        let log = UnifiedAuditLog(entries: events)
        let asOfT20 = AuditRecovery.rebuild(from: log,
                                              asOf: HLC(physicalTime: 20,
                                                                 logicalCount: 0,
                                                                 nodeID: 1))
        #expect(asOfT20.entriesReplayed == 1)
        #expect(asOfT20.rowsRebuilt == 1)
        #expect(asOfT20.locusRows == 1)
        #expect(asOfT20.ragRows == 0)
    }

    @Test
    func withdrawAndExpungeAreStickyTombstones() {
        let events = [
            makeEntry(tier: .locus, time: 10, row: rowA, field: "f", value: .bitmap(1), verb: .capture),
            makeEntry(tier: .locus, time: 20, row: rowA, field: "f", value: .bitmap(2), verb: .withdraw),
            makeEntry(tier: .locus, time: 30, row: rowA, field: "f", value: .bitmap(3), verb: .expunge),
            makeEntry(tier: .locus, time: 40, row: rowA, field: "f", value: .bitmap(9), verb: .mutate),
        ]
        let p = AuditProjectionFold.project(UnifiedAuditLog(entries: events))
        let row = p.row(tier: .locus, rowID: rowA)
        #expect(row?.withdrawn ?? false)
        #expect(row?.expunged ?? false)
    }

    // MARK: - Tier scoping

    @Test
    func entriesByTierFiltering() {
        let events = [
            makeEntry(tier: .locus, time: 10, row: rowA, field: "f", value: .integer(1), verb: .capture),
            makeEntry(tier: .rag,   time: 20, row: rowB, field: "g", value: .integer(2), verb: .capture),
            makeEntry(tier: .locus, time: 30, row: rowA, field: "f", value: .integer(3), verb: .mutate),
        ]
        let log = UnifiedAuditLog(entries: events)
        #expect(log.entries(tier: .locus).count == 2)
        #expect(log.entries(tier: .rag).count == 1)
    }

    @Test
    func rowScopingHonorsTier() {
        // Pathological case: a LocusKit row and a CorpusKit row sharing
        // the same UUID. Projection must keep them disjoint.
        let shared = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let events = [
            makeEntry(tier: .locus, time: 10, row: shared, field: "f", value: .integer(1)),
            makeEntry(tier: .rag,   time: 20, row: shared, field: "g", value: .integer(2)),
        ]
        let p = AuditProjectionFold.project(UnifiedAuditLog(entries: events))
        #expect(p.count == 2)
        #expect(p.row(tier: .locus, rowID: shared) != nil)
        #expect(p.row(tier: .rag, rowID: shared) != nil)
    }

    // MARK: - HLC ordering

    @Test
    func hlcLexicographicOrder() {
        let a = HLC(physicalTime: 1, logicalCount: 0, nodeID: 0)
        let b = HLC(physicalTime: 1, logicalCount: 1, nodeID: 0)
        let c = HLC(physicalTime: 1, logicalCount: 1, nodeID: 5)
        let d = HLC(physicalTime: 2, logicalCount: 0, nodeID: 0)
        #expect(a < b)
        #expect(b < c)
        #expect(c < d)
        #expect(a.wireBytes.count == 16)
    }

    // MARK: - Security regression (codex a477800)

    @Test
    func auditLogRejectsForgedContentID() {
        // Construct an honest entry; its id is SHA-256 of its wire encoding.
        let row = UUID(uuidString: "ffff0000-0000-0000-0000-000000000001")!
        let hlc = HLC(physicalTime: 9999, logicalCount: 0, nodeID: 42)
        let honest = UnifiedAuditEntry(
            tier: .locus, hlc: hlc, verb: .capture, rowID: row,
            fieldPath: "sec.test", beforeValue: .null, afterValue: .integer(42)
        )

        var log = UnifiedAuditLog()
        log.add(honest)
        #expect(log.count == 1, "honest entry must be inserted")

        // Construct a forged entry: steal the honest id but inject a
        // different afterValue. The recomputed SHA-256 will not match
        // the stolen id, so the log must reject the entry.
        let forged = UnifiedAuditEntry(
            id: honest.id,          // stolen — does NOT match wire encoding below
            tier: .locus, hlc: hlc, verb: .capture, rowID: row,
            fieldPath: "sec.test", beforeValue: .null,
            afterValue: .integer(999)   // different content
        )

        // add path: forged entry must be silently rejected.
        log.add(forged)
        #expect(log.count == 1, "forged entry on add must not increase count")

        // The honest entry's value is retained — not overwritten by forged.
        let retained = log.entries.values.first
        #expect(retained?.afterValue == .integer(42),
                "honest entry value must be preserved after forged-add attempt")

        // merge path: a log that tries to merge the forged entry must
        // also reject it (merge routes through add).
        // Build a second log and attempt to add the forged entry there,
        // then merge into the main log — the forged entry never reaches
        // the main log's backing store.
        var otherLog = UnifiedAuditLog()
        otherLog.add(forged)    // rejected at source log too
        #expect(otherLog.count == 0, "forged entry rejected in source log before merge")
        log.merge(otherLog)     // merging an empty log is a no-op
        #expect(log.count == 1, "count unchanged after merging log with forged entry")
        #expect(log.entries.values.first?.afterValue == .integer(42),
                "honest entry value must be preserved after forged-merge attempt")

        // Idempotent add of the honest entry leaves count unchanged.
        log.add(honest)
        #expect(log.count == 1, "re-adding honest entry must remain idempotent")
    }

    // MARK: - Helpers

    private let rowA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let rowB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    private func makeEntry(tier: AuditTier,
                            time: Int64,
                            row: UUID,
                            field: String,
                            value: UnifiedAuditValue,
                            verb: UnifiedAuditVerb = .capture) -> UnifiedAuditEntry {
        return UnifiedAuditEntry(
            tier: tier,
            hlc: HLC(physicalTime: time, logicalCount: 0, nodeID: 1),
            verb: verb,
            rowID: row,
            fieldPath: field,
            beforeValue: .null,
            afterValue: value
        )
    }

    private func makeEntry(tier: AuditTier,
                            hlc: HLC,
                            row: UUID,
                            field: String,
                            value: UnifiedAuditValue,
                            verb: UnifiedAuditVerb = .capture) -> UnifiedAuditEntry {
        return UnifiedAuditEntry(
            tier: tier,
            hlc: hlc,
            verb: verb,
            rowID: row,
            fieldPath: field,
            beforeValue: .null,
            afterValue: value
        )
    }
}
