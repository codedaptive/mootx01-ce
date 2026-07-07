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

import Testing
import SubstrateTypes
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
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

@Suite("GLK-03 unified audit log integration")
struct GLK03_AuditIntegrationTests {

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
            latticeAnchor: .udc("000"),
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
    @Test
    func registryPresentAfterOpen() async throws {
        let (kit, handle) = try await openOneEstate()
        let log = try await kit.auditLog(for: handle)
        #expect(log.count == 0, "a freshly opened estate's audit log is empty")
    }

    // MARK: - Test 2 — bridge produces entries

    /// Capturing then withdrawing a drawer produces at least one
    /// bitmap_audit row; `feedAuditLog` bridges those rows into the
    /// registry's log so `count > 0`.
    @Test
    func feedAuditLogBridgesRows() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "bridge target"))
        try await kit.withdraw(handle, WithdrawFrame(rowID: stored.id, reason: "glk03"))

        // feedAuditLog removed (ADR-026): auditLog(for:) reads directly from storage.
        let log = try await kit.auditLog(for: handle)
        #expect(log.count > 0, "bridged audit rows should populate the log")
        #expect(log.orderedEntries.allSatisfy { $0.tier == .locus },
                "all bridged entries are .locus tier")
    }

    // MARK: - Test 3 — verify clean chain

    /// A freshly populated, uncorrupted log verifies as valid with a
    /// nil firstBrokenAt.
    @Test
    func verifyCleanChain() async throws {
        let (kit, handle) = try await openOneEstate()
        let stored = try await kit.capture(handle, captureFrame(content: "clean chain"))
        try await kit.withdraw(handle, WithdrawFrame(rowID: stored.id, reason: "glk03"))

        let report = try await kit.verifyAuditChain(handle)
        #expect(report.valid, "an uncorrupted chain is valid")
        #expect(report.firstBrokenAt == nil, "no break on a clean chain")
        #expect(report.entryCount > 0)
    }

    // MARK: - Test 4 — C-12 invariant (corrupted entry rejection at ingress)

    /// A corrupted entry (stored id does not match SHA-256 of wire encoding)
    /// is rejected at the add boundary — the verify-on-ingress defence in
    /// `UnifiedAuditLog` (codex a477800) catches the mismatch before the
    /// entry reaches the log. The chain verifier therefore sees an empty log
    /// and reports vacuously valid. This is the correct outcome: the
    /// defence happens at ingress rather than post-hoc. The chain verifier
    /// remains defence-in-depth for any entry that might bypass `add` in the
    /// future. NEURONKIT_SPEC invariant C-12.
    @Test
    func corruptedEntryRejectedAtAddBoundary() {
        let good = entry(time: 1_000, row: rowA)
        // Flip one byte of the stored id so it no longer matches the
        // SHA-256 of the entry's wire encoding. The verify-on-ingress
        // check in add / init(entries:) will reject this entry.
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
        // The log rejects the corrupted entry at the init(entries:) / add
        // boundary — it never reaches the verifier.
        let log = UnifiedAuditLog(entries: [corrupted])
        #expect(log.count == 0,
                "corrupted entry rejected at add boundary (codex a477800)")

        // The chain verifier (defence-in-depth) reports vacuously valid on
        // the empty log — consistent with the ingress defence.
        let report = AuditChainVerifier.verify(log)
        #expect(report.valid,
                "empty log after corrupted-entry rejection is vacuously valid")
        #expect(report.firstBrokenAt == nil)
        #expect(report.entryCount == 0)
    }

    // MARK: - Test 5 — asOf projection

    /// Projecting asOf an HLC earlier than some entries yields fewer
    /// rows than the full projection.
    @Test
    func asOfProjectionHasFewerRows() {
        let log = UnifiedAuditLog(entries: [
            entry(time: 1, row: rowA),
            entry(time: 5, row: rowB),
        ])
        let full = AuditProjectionFold.project(log)
        let asOf = AuditProjectionFold.project(
            log, asOf: HLC(physicalTime: 3, logicalCount: 0, nodeID: 0))
        #expect(full.count == 2)
        #expect(asOf.count < full.count, "asOf cutoff excludes the later row")
        #expect(asOf.count == 1)
    }

    // MARK: - Test 6 — recovery round-trip

    /// Rebuild from the log and verify against the reference projection:
    /// no divergence.
    @Test
    func recoveryRoundTrip() {
        let log = UnifiedAuditLog(entries: [
            entry(time: 1, row: rowA),
            entry(time: 2, row: rowB),
        ])
        let reference = AuditProjectionFold.project(log)
        let result = AuditRecovery.rebuild(from: log)
        let divergence = AuditRecovery.verify(rebuilt: result.projection,
                                              against: reference)
        #expect(divergence.isEmpty, "rebuilt projection matches reference")
    }

    // MARK: - Test 7 — new federation verbs

    /// The four federation verbs construct valid content-addressed
    /// entries (32-byte SHA-256 id), distinct per verb.
    @Test
    func federationVerbsCompileAndHash() {
        let verbs: [UnifiedAuditVerb] = [
            .grantIssued, .grantRevoked, .keyDecayed, .physicalKeyDecayed,
        ]
        var ids = Set<[UInt8]>()
        for v in verbs {
            let e = entry(time: 100, row: rowA, verb: v, field: "grant")
            #expect(e.id.count == 32, "content hash is 32-byte SHA-256")
            ids.insert(e.id)
        }
        #expect(ids.count == 4, "each verb produces a distinct content hash")
    }
}
