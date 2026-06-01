// TheoremsTests.swift
//
// Mission GLK-08 — demonstrations of Theorems 4, 6, 7, and 8 over the
// composed GeniusLocusKit substrate. The demonstrations are
// conformance fixtures, not production code. Each test exercises the
// substrate primitives that close out the named theorem's
// done-definition per `docs/specs/GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md`
// section 7.
//
// The vocabulary used here:
//
//   Theorem 4 (Graceful degradation under model versioning)
//     — model upgrade triggers regeneration; queries during the
//       regeneration window return correct results filtered by
//       model+version tag; audit trail preserves the transition.
//
//   Theorem 6 (Empirically-tunable storage fidelity)
//     — round-trip reversibility holds: materialised state can be
//       discarded and exactly recovered from the audit log because
//       the substrate's audit log is the source of truth (paper §6.5).
//
//   Theorem 7 (First-class memory corrections)
//     — a four-version drawer lifecycle (capture, user-confirm,
//       correction, agent-contest) preserves every version with
//       provenance bits and audit entries; historical asOf queries
//       reconstruct the version active at that point.
//
//   Theorem 8 (First-class memory provenance)
//     — an actor presented with mixed unconfirmed observations and
//       confirmed directives acts only on the confirmed set; the rest
//       surface as suggestions. The provenance bitmap bit separates
//       the two and the projection's filter selects exactly the
//       confirmed set.
//
// The theorems each have a paper §13 / §13.4 long-form derivation;
// these fixtures restate the demonstration over the substrate
// primitives the kit actually ships today (UnifiedAuditLog,
// AuditProjectionFold, the verb vocabulary). Theorem 5 lives in
// `PerformanceGateTests.swift` because its evidence is a measurement
// rather than a behavioural assertion.

import Testing
import SubstrateTypes
import Foundation
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
@testable import GeniusLocusKit

@Suite("Theorems 4, 6, 7, 8")
struct TheoremsTests {

    // MARK: - Test fixtures

    /// Build an HLC at a given monotonic step. Tests use steps rather
    /// than wall-clock so the asOf cuts are exact integer comparisons.
    private func hlc(_ step: Int64, node: Int32 = 1) -> HLC {
        HLC(physicalTime: step, logicalCount: 0, nodeID: node)
    }

    /// Convenience wrapper around `UnifiedAuditEntry.init` that lets the
    /// theorem demonstrations read like spec prose. Every entry lands in
    /// the `locus` tier; the unified log is tier-uniform across these
    /// fixtures because the demonstrations care about projection
    /// behaviour, not cross-tier folding (that property is covered in
    /// `UnifiedAuditLogTests`).
    private func entry(
        hlcStep: Int64,
        verb: UnifiedAuditVerb,
        row: UUID,
        fieldPath: String,
        after: UnifiedAuditValue
    ) -> UnifiedAuditEntry {
        UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc(hlcStep),
            verb: verb,
            rowID: row,
            fieldPath: fieldPath,
            beforeValue: .null,
            afterValue: after
        )
    }

    // MARK: - Theorem 4: Graceful degradation under model versioning

    /// Demonstrates that a model upgrade preserves every transition in
    /// the audit log and that asOf projection during the regeneration
    /// window returns the version-correct state per row.
    ///
    /// The dataset is three rows enriched at `model.version = v1`. A
    /// model upgrade interleaves three `migrate` entries that retag each
    /// row's `provenance.model_version` field path from `v1` to `v2`.
    /// asOf cuts at three points in the upgrade window observe the
    /// substrate mid-flight; the final projection observes the
    /// post-completion state. Every transition appears in the audit log
    /// regardless of the asOf cut — the log is grow-only (I-20).
    @Test
    func theorem4_ModelVersionUpgradePreservesEveryTransition() {
        let rowA = UUID()
        let rowB = UUID()
        let rowC = UUID()
        var log = UnifiedAuditLog()

        // Phase 1: three captures at v1. Steps 1, 2, 3.
        log.add(entry(hlcStep: 1, verb: .capture, row: rowA,
                      fieldPath: "provenance.model_version",
                      after: .string("v1")))
        log.add(entry(hlcStep: 2, verb: .capture, row: rowB,
                      fieldPath: "provenance.model_version",
                      after: .string("v1")))
        log.add(entry(hlcStep: 3, verb: .capture, row: rowC,
                      fieldPath: "provenance.model_version",
                      after: .string("v1")))

        // Phase 2: maintenance daemon flips each row to v2 in turn.
        // Steps 10, 11, 12 — a regeneration "window" the asOf cuts can
        // land inside of.
        log.add(entry(hlcStep: 10, verb: .migrate, row: rowA,
                      fieldPath: "provenance.model_version",
                      after: .string("v2")))
        log.add(entry(hlcStep: 11, verb: .migrate, row: rowB,
                      fieldPath: "provenance.model_version",
                      after: .string("v2")))
        log.add(entry(hlcStep: 12, verb: .migrate, row: rowC,
                      fieldPath: "provenance.model_version",
                      after: .string("v2")))

        // Pre-upgrade snapshot: every live row is at v1.
        let preUpgrade = AuditProjectionFold.project(log, asOf: hlc(9))
        #expect(preUpgrade.liveRows.count == 3,
                "all three rows are visible pre-upgrade")
        for row in [rowA, rowB, rowC] {
            let proj = preUpgrade.row(tier: .locus, rowID: row)
            #expect(proj?.fields["provenance.model_version"] == .string("v1"),
                    "row \(row) reads v1 pre-upgrade")
        }

        // Mid-upgrade cut: row A has migrated, B and C have not. This is
        // the "during regeneration window" the implementation plan §7
        // requires — the substrate returns version-correct results per
        // row, not a global blocked state.
        let midUpgrade = AuditProjectionFold.project(log, asOf: hlc(10))
        #expect(midUpgrade.row(tier: .locus, rowID: rowA)?
                    .fields["provenance.model_version"] == .string("v2"))
        #expect(midUpgrade.row(tier: .locus, rowID: rowB)?
                    .fields["provenance.model_version"] == .string("v1"))
        #expect(midUpgrade.row(tier: .locus, rowID: rowC)?
                    .fields["provenance.model_version"] == .string("v1"))

        // Post-upgrade snapshot: every live row reads v2.
        let postUpgrade = AuditProjectionFold.project(log)
        #expect(postUpgrade.liveRows.count == 3)
        for row in [rowA, rowB, rowC] {
            #expect(postUpgrade.row(tier: .locus, rowID: row)?
                        .fields["provenance.model_version"] == .string("v2"),
                    "row \(row) reads v2 post-upgrade")
        }

        // Audit trail preserves every transition. The grow-only set
        // (I-20) records all six events regardless of the asOf cut a
        // caller projects against. This is the load-bearing fact behind
        // the theorem: the audit log is not lossy on regeneration.
        #expect(log.count == 6,
                "audit log retains capture and migrate events for every row")
        for row in [rowA, rowB, rowC] {
            let rowEntries = log.entries(forRow: row, tier: .locus)
            #expect(rowEntries.count == 2,
                    "row \(row) carries both the v1 capture and the v2 migrate")
            #expect(rowEntries.map(\.verb) == [.capture, .migrate])
        }
    }

    // MARK: - Theorem 6: Empirically-tunable storage fidelity

    /// Demonstrates round-trip reversibility on the substrate's source
    /// of truth. The materialised projection can be discarded and
    /// exactly recovered from the audit log alone; this is the
    /// substrate-level statement of the implementation plan's
    /// "round-trip Q1 → Q0" property. Storage-fidelity modes are the
    /// application-level surface this property enables; the substrate
    /// guarantee is reconstruction from the log.
    ///
    /// Dataset: 16 rows captured into the audit log with varied bitmap
    /// payloads. The fixture projects the full state, discards it,
    /// reprojects from the same log, and asserts the projections are
    /// identical. Equality of the two `UnifiedProjection` values is
    /// what reversibility means in the substrate's vocabulary.
    @Test
    func theorem6_StorageFidelityRoundTripReversibility() {
        var log = UnifiedAuditLog()
        var rowIDs: [UUID] = []

        for i in 0..<16 {
            let row = UUID()
            rowIDs.append(row)
            log.add(entry(hlcStep: Int64(i + 1),
                          verb: .capture,
                          row: row,
                          fieldPath: "tag_bits",
                          after: .bitmap(UInt64(1) << (i % 8))))
        }

        // First projection: the materialised state the substrate would
        // serve to a recall request at full fidelity.
        let fullFidelity = AuditProjectionFold.project(log)
        #expect(fullFidelity.liveRows.count == 16)

        // Simulate a fidelity-mode change that "discards" the cached
        // materialised state. The audit log is unaffected — it is the
        // source of truth (paper §6.5). Reprojection from the same log
        // must yield byte-identical state.
        let reprojected = AuditProjectionFold.project(log)
        #expect(fullFidelity == reprojected,
                "discarding and reprojecting must be bit-for-bit reversible")
        #expect(reprojected.liveRows.count == 16)

        // Round-trip a different fidelity mode by re-folding the log
        // entries in a permuted order. Convergence (cookbook §5.4)
        // states the projection depends only on the set of entries.
        // We rebuild the log by adding the entries in reverse and
        // assert the result is the same projection. This is the
        // "reprojection after compression/decompression" claim
        // restated as a CRDT property.
        var permuted = UnifiedAuditLog()
        for entry in log.orderedEntries.reversed() {
            permuted.add(entry)
        }
        let permutedProjection = AuditProjectionFold.project(permuted)
        #expect(fullFidelity == permutedProjection,
                "projection depends only on the entry set, not insertion order")
    }

    // MARK: - Theorem 7: First-class memory corrections

    /// Demonstrates the four-version drawer lifecycle. A single row
    /// transits capture → user-confirm → correction → agent-contest;
    /// each transition has a distinct field payload. asOf projection at
    /// each transition's HLC reads back exactly the version active at
    /// that point.
    ///
    /// The verb sequence uses `mutate` for the three post-capture
    /// transitions because mutate is the cookbook verb the substrate
    /// emits for user-confirm, corrections, and contests (cookbook
    /// §10.3). The `provenance` field-path varies per transition to
    /// expose which version a reader sees.
    @Test
    func theorem7_FirstClassCorrectionsFourVersionLifecycle() {
        let row = UUID()
        var log = UnifiedAuditLog()

        // Step 1: initial capture, provenance reads "captured".
        log.add(entry(hlcStep: 1, verb: .capture, row: row,
                      fieldPath: "provenance",
                      after: .string("captured")))
        // Step 2: user confirms the capture.
        log.add(entry(hlcStep: 2, verb: .mutate, row: row,
                      fieldPath: "provenance",
                      after: .string("user-confirmed")))
        // Step 3: user corrects the content.
        log.add(entry(hlcStep: 3, verb: .mutate, row: row,
                      fieldPath: "provenance",
                      after: .string("user-corrected")))
        // Step 4: an agent contests the correction.
        log.add(entry(hlcStep: 4, verb: .mutate, row: row,
                      fieldPath: "provenance",
                      after: .string("agent-contested")))

        // All four versions present in storage.
        #expect(log.count == 4)
        #expect(log.entries(forRow: row, tier: .locus).count == 4)

        // Default (current) query returns the active (most recent)
        // version.
        let current = AuditProjectionFold.project(log)
        #expect(current.row(tier: .locus, rowID: row)?
                    .fields["provenance"] == .string("agent-contested"))

        // Historical asOf queries reconstruct each prior state.
        let asOfStep1 = AuditProjectionFold.project(log, asOf: hlc(1))
        #expect(asOfStep1.row(tier: .locus, rowID: row)?
                    .fields["provenance"] == .string("captured"))

        let asOfStep2 = AuditProjectionFold.project(log, asOf: hlc(2))
        #expect(asOfStep2.row(tier: .locus, rowID: row)?
                    .fields["provenance"] == .string("user-confirmed"))

        let asOfStep3 = AuditProjectionFold.project(log, asOf: hlc(3))
        #expect(asOfStep3.row(tier: .locus, rowID: row)?
                    .fields["provenance"] == .string("user-corrected"))

        let asOfStep4 = AuditProjectionFold.project(log, asOf: hlc(4))
        #expect(asOfStep4.row(tier: .locus, rowID: row)?
                    .fields["provenance"] == .string("agent-contested"))

        // Audit entries cover every state change. The verbs partition
        // into the one capture and three mutates the lifecycle demands.
        let verbs = log.entries(forRow: row, tier: .locus).map(\.verb)
        #expect(verbs == [.capture, .mutate, .mutate, .mutate])
    }

    // MARK: - Theorem 8: First-class memory provenance

    /// The provenance bitmap bit that distinguishes user-confirmed
    /// content from unconfirmed observations. The substrate has no
    /// reserved bit for "confirmed"; this fixture allocates bit 0 of a
    /// row's `provenance.bits` bitmap value for the demonstration. A
    /// production deployment would document the assignment in the
    /// bitmap-patterns skill; for the conformance fixture the bit is
    /// scoped to this test file.
    private static let confirmedBit: UInt64 = 0x1

    /// Demonstrates that a query filter over the confirmed bit selects
    /// exactly the user-confirmed rows. The dataset matches the
    /// implementation plan's setup: 10 unconfirmed observations and 10
    /// user-confirmed directives. The "actor acts on the confirmed set"
    /// is restated here as "the projection filtered by the confirmed
    /// bit returns exactly the 10 confirmed rows."
    @Test
    func theorem8_ProvenanceConfirmedBitSelectsExactlyConfirmedRows() {
        var log = UnifiedAuditLog()
        var confirmedRows: Set<UUID> = []
        var unconfirmedRows: Set<UUID> = []

        // Ten unconfirmed observations — provenance bitmap has the
        // confirmed bit clear.
        for i in 0..<10 {
            let row = UUID()
            unconfirmedRows.insert(row)
            log.add(entry(hlcStep: Int64(i + 1),
                          verb: .capture,
                          row: row,
                          fieldPath: "provenance.bits",
                          after: .bitmap(0)))
        }
        // Ten user-confirmed directives — provenance bitmap has the
        // confirmed bit set. Mutate after capture so the audit trail
        // reflects "captured, then confirmed" rather than a one-shot
        // capture with confirmation already baked in.
        for i in 0..<10 {
            let row = UUID()
            confirmedRows.insert(row)
            log.add(entry(hlcStep: Int64(100 + i * 2),
                          verb: .capture,
                          row: row,
                          fieldPath: "provenance.bits",
                          after: .bitmap(0)))
            log.add(entry(hlcStep: Int64(100 + i * 2 + 1),
                          verb: .mutate,
                          row: row,
                          fieldPath: "provenance.bits",
                          after: .bitmap(Self.confirmedBit)))
        }

        let projection = AuditProjectionFold.project(log)
        #expect(projection.liveRows.count == 20)

        // Filter by the confirmed bit at the projection layer. This is
        // the substrate-level statement of the implementation plan's
        // "agent issues actions; verify actions taken only on confirmed
        // directives" criterion.
        let confirmedHits = projection.liveRows.filter { row in
            guard case .bitmap(let bits) = row.fields["provenance.bits"]
            else { return false }
            return (bits & Self.confirmedBit) != 0
        }
        #expect(confirmedHits.count == 10,
                "exactly the ten confirmed rows match the bitmap predicate")
        #expect(Set(confirmedHits.map(\.rowID)) == confirmedRows)

        let unconfirmedHits = projection.liveRows.filter { row in
            guard case .bitmap(let bits) = row.fields["provenance.bits"]
            else { return true }
            return (bits & Self.confirmedBit) == 0
        }
        #expect(unconfirmedHits.count == 10,
                "exactly the ten unconfirmed rows match the inverse predicate")
        #expect(Set(unconfirmedHits.map(\.rowID)) == unconfirmedRows)
    }
}
