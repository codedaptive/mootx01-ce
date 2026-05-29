// GLK03_AuditIntegrationTests.swift
//
// Mission GLK-03 — Unified Audit Log Integration. Seven integration
// tests covering the four deliverables: the per-estate UnifiedAuditLog
// registry on the GeniusLocusKit actor, the LocusKit AuditRow →
// UnifiedAuditEntry bridge fed through `feedAuditLog`, the
// `verifyAuditChain` verb / AuditChainVerifier integrity check
// (NEURONKIT_SPEC §3.5 / invariant C-12), and the four federation
// verb cases on UnifiedAuditVerb.
//
// Tests 1–2 drive a live composed estate: capture files a drawer and
// `withdraw` flips its state axis, which is what writes a bitmap_audit
// row (capture itself is an INSERT — see EstateAudit.swift). The
// remaining tests build synthetic UnifiedAuditLog values directly so
// the verifier, asOf projection, recovery, and new-verb hashing are
// exercised in isolation.

import XCTest
import Foundation
import LocusKit
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
import SubstrateLib
@testable import GeniusLocusKit

final class GLK03_AuditIntegrationTests: XCTestCase {

    // MARK: - Estate helpers (mirror VerbSurfaceTests)

    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-glk03")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func captureFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "glk03-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "glk03-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    // MARK: - Synthetic-entry helpers

    private let rowA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let rowB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    private func entry(time: Int64,
                       row: UUID,
                       verb: UnifiedAuditVerb = .mutate,
                       field: String = "operationalBitmap",
                       after: UnifiedAuditValue = .bitmap(0b1)) -> UnifiedAuditEntry {
        UnifiedAuditEntry(
            tier: .locus,
            hlc: HLC(physicalTime: time, logicalCount: 0, nodeID: 0),
            verb: verb,
            rowID: row,
            fieldPath: field,
            beforeValue: .null,
            afterValue: after
        )
    }

    // MARK: - Test 1 — registry present

    /// Opening an estate mints an empty UnifiedAuditLog in the registry;
    /// `auditLog(for:)` returns it (non-nil) rather than throwing.
    func testRegistryPresentAfterOpen() async throws {
        let (kit, handle) = try await openOneEstate()
        let log = try await kit.auditLog(for: handle)
        XCTAssertEqual(log.count, 0, "a freshly opened estate's audit log is empty")
    }

    // MARK: - Test 2 — bridge produces entries

    /// Capturing then withdrawing a drawer produces at least one
    /// bitmap_audit row; `feedAuditLog` bridges those rows into the
    /// registry's log so `count > 0`.
    func testFeedAuditLogBridgesRows() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "bridge target"))
        try await kit.withdraw(handle, WithdrawFrame(rowID: stored.id, reason: "glk03"))

        try await kit.feedAuditLog(for: handle)
        let log = try await kit.auditLog(for: handle)
        XCTAssertGreaterThan(log.count, 0, "bridged audit rows should populate the log")
        XCTAssertTrue(log.orderedEntries.allSatisfy { $0.tier == .locus },
                      "all bridged entries are .locus tier")
    }

    // MARK: - Test 3 — verify clean chain

    /// A freshly populated, uncorrupted log verifies as valid with a
    /// nil firstBrokenAt.
    func testVerifyCleanChain() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "clean chain"))
        try await kit.withdraw(handle, WithdrawFrame(rowID: stored.id, reason: "glk03"))

        let report = try await kit.verifyAuditChain(handle)
        XCTAssertTrue(report.valid, "an uncorrupted chain is valid")
        XCTAssertNil(report.firstBrokenAt, "no break on a clean chain")
        XCTAssertGreaterThan(report.entryCount, 0)
    }

    // MARK: - Test 4 — C-12 invariant (corrupted entry)

    /// Corrupting an entry's stored id (flipping a byte) breaks the
    /// content-hash check: the report is invalid and firstBrokenAt is
    /// set. NEURONKIT_SPEC invariant C-12.
    func testCorruptedEntryFailsVerification() {
        let good = entry(time: 1_000, row: rowA)
        // Flip one byte of the stored id while keeping the 32-byte
        // SHA-256 width the explicit-id initializer requires. The
        // recomputed hash over the fields no longer matches the stored
        // id, so the verifier must flag the break.
        var corruptedID = good.id
        corruptedID[0] ^= 0xFF
        let corrupted = UnifiedAuditEntry(
            id: corruptedID,
            tier: good.tier,
            hlc: good.hlc,
            verb: good.verb,
            rowID: good.rowID,
            fieldPath: good.fieldPath,
            beforeValue: good.beforeValue,
            afterValue: good.afterValue,
            originRowID: good.originRowID
        )
        let log = UnifiedAuditLog(entries: [corrupted])
        let report = AuditChainVerifier.verify(log)
        XCTAssertFalse(report.valid, "a corrupted id must fail verification")
        XCTAssertNotNil(report.firstBrokenAt, "firstBrokenAt set on break (C-12)")
    }

    // MARK: - Test 5 — asOf projection

    /// Projecting asOf an HLC earlier than some entries yields fewer
    /// rows than the full projection.
    func testAsOfProjectionHasFewerRows() {
        let log = UnifiedAuditLog(entries: [
            entry(time: 1, row: rowA),
            entry(time: 5, row: rowB),
        ])
        let full = AuditProjectionFold.project(log)
        let asOf = AuditProjectionFold.project(
            log, asOf: HLC(physicalTime: 3, logicalCount: 0, nodeID: 0))
        XCTAssertEqual(full.count, 2)
        XCTAssertLessThan(asOf.count, full.count, "asOf cutoff excludes the later row")
        XCTAssertEqual(asOf.count, 1)
    }

    // MARK: - Test 6 — recovery round-trip

    /// Rebuild from the log and verify against the reference projection:
    /// no divergence.
    func testRecoveryRoundTrip() {
        let log = UnifiedAuditLog(entries: [
            entry(time: 1, row: rowA),
            entry(time: 2, row: rowB),
        ])
        let reference = AuditProjectionFold.project(log)
        let result = AuditRecovery.rebuild(from: log)
        let divergence = AuditRecovery.verify(rebuilt: result.projection,
                                              against: reference)
        XCTAssertTrue(divergence.isEmpty, "rebuilt projection matches reference")
    }

    // MARK: - Test 7 — new federation verbs

    /// The four federation verbs construct valid content-addressed
    /// entries (32-byte SHA-256 id), distinct per verb.
    func testFederationVerbsCompileAndHash() {
        let verbs: [UnifiedAuditVerb] = [
            .grantIssued, .grantRevoked, .keyDecayed, .physicalKeyDecayed,
        ]
        var ids = Set<[UInt8]>()
        for v in verbs {
            let e = entry(time: 100, row: rowA, verb: v, field: "grant")
            XCTAssertEqual(e.id.count, 32, "content hash is 32-byte SHA-256")
            ids.insert(e.id)
        }
        XCTAssertEqual(ids.count, 4, "each verb produces a distinct content hash")
    }
}
