// MaintenanceSeams.swift
//
// The maintenance daemon's substrate seams (NEURONKIT_SPEC § 3.2) plus
// the scan-input value types and the cycle report. Mirrors the dreaming
// daemon's reader / sink / report split.
//
// ── Why the daemon talks to seams, not to GLK verbs ──────────────────
// MOOTx01 invariant B-1: NeuronKit never executes SQL and never calls
// LocusKit / VectorKit / CorpusKit directly; the estate handle is the only
// write surface. But the current GLK verb surface cannot satisfy this
// daemon's substrate needs: the `propose` verb raises
// `VerbError.notSupportedByEstate` (Brain layer absent), and there is
// no estate verb that reads `Drawer` rows, reads a `UnifiedAuditLog`,
// or writes a `DiaryEntry`. So the maintenance daemon depends on
// NeuronKit-owned seam protocols — exactly as the dreaming daemon
// depends on `DreamingSubstrateReader` / `DreamingProposalSink` /
// `DreamingPolicyStore`. The production adapter that binds these seams
// to real estate verbs lands when the GLK Brain layer ships. The daemon
// references substrate VALUE types (`Drawer`, `UnifiedAuditLog`,
// `DiaryEntry`, `ProposeFrame`, `ProposalKind`) but calls no substrate
// method, so B-1 holds.

import Foundation
import GeniusLocusKit
import LocusKit

// MARK: - Scan-input observation value types

/// One learned-reference observation, the input to the byReference
/// validity scan (NEURONKIT_SPEC § 3.2 scan category 5). A learned
/// reference (a `LearnedReference` source per architecture spec § 10
/// row 7) points at a source drawer; over time that source's content
/// can drift away from what the reference was learned against. The
/// adapter computes `sourceDriftFraction` as the fraction of the
/// reference's source content that has changed; the daemon proposes a
/// byReference-drift confirmation once it crosses the policy threshold.
///
/// Value type. Carries the reference drawer's RowID (the
/// proposal target) and the precomputed drift fraction; the daemon does
/// not recompute drift, it only thresholds and proposes.
public struct LearnedReferenceObservation: Sendable, Equatable {

    /// The reference drawer's RowID. Used as the proposal target so the
    /// human can locate the reference whose source has drifted.
    public let referenceRowID: RowID

    /// Fraction in `[0, 1]` of the reference's source content that has
    /// drifted from what the reference was learned against. Compared to
    /// `MaintenancePolicy.byReferenceDriftThreshold`.
    public let sourceDriftFraction: Float

    public init(referenceRowID: RowID, sourceDriftFraction: Float) {
        self.referenceRowID = referenceRowID
        self.sourceDriftFraction = sourceDriftFraction
    }
}

/// One fingerprint-drift observation, the input to the fingerprint-drift
/// scan (NEURONKIT_SPEC § 3.2 scan category 4). A room or wing carries a
/// rolled-up fingerprint; as content is added the live fingerprint
/// drifts from the recorded baseline by some Hamming-distance fraction.
/// The adapter computes `driftFraction`; the daemon proposes a
/// fingerprint-drift review once it crosses the policy threshold.
///
/// Value type. Carries the room/wing key (the basis for a
/// stable proposal target) and the precomputed drift fraction.
public struct FingerprintDriftObservation: Sendable, Equatable {

    /// The room or wing key whose fingerprint has drifted. The basis
    /// for the proposal target RowID.
    public let scopeKey: String

    /// Fraction in `[0, 1]` of fingerprint bits that have drifted from
    /// baseline (Hamming distance / bit width). Compared to
    /// `MaintenancePolicy.fingerprintDriftThreshold`.
    public let driftFraction: Float

    public init(scopeKey: String, driftFraction: Float) {
        self.scopeKey = scopeKey
        self.driftFraction = driftFraction
    }
}

// MARK: - Read seam

/// Read surface the maintenance daemon scans (NEURONKIT_SPEC § 3.2). All
/// five reads are pure inputs — the daemon mutates nothing through this
/// protocol. Dependency seam; the production adapter binds each method to
/// the corresponding estate read when the GLK surface exposes them.
public protocol MaintenanceSubstrateReader: Sendable {

    /// Active drawers, for the decay scan and the forbidden-combination
    /// (invariant I-3) scan. "Active" means not tombstoned and in the
    /// currently-believed state cluster; the adapter applies that
    /// filter, the daemon consumes the result.
    func activeDrawers() async throws -> [Drawer]

    /// Tombstoned drawers (rows with `tombstonedAt != nil`), for the
    /// tombstone/expunge scan.
    func tombstonedDrawers() async throws -> [Drawer]

    /// Learned-reference observations, for the byReference validity scan.
    func learnedReferences() async throws -> [LearnedReferenceObservation]

    /// Fingerprint-drift observations, for the fingerprint-drift scan.
    func fingerprintBaselines() async throws -> [FingerprintDriftObservation]

    /// The current unified audit log, fed to `AuditChainVerifier.verify`
    /// for the audit-chain integrity monitor (NEURONKIT_SPEC § 3.5).
    func currentAuditLog() async throws -> UnifiedAuditLog
}

// MARK: - Write seam

/// Write surface the maintenance daemon emits through (NEURONKIT_SPEC
/// § 3.2). This is the daemon's ONLY write path. It exposes exactly two
/// operations — emit a proposal, and record the cycle diary entry — and
/// deliberately has NO remediation method (no expunge, no withdraw, no
/// mutate). That absence is how the never-remediate invariant (§ 3.2) is
/// enforced structurally: the daemon cannot remediate because nothing it
/// can reach does. It can only propose, exactly as the dreaming sink can
/// only propose and never creates a Tunnel.
///
/// The production adapter implements `propose(_:)` by forwarding to the
/// estate handle's `propose` verb (the legal B-1 write path) once the
/// GLK Brain layer makes that verb live.
public protocol MaintenanceProposalSink: Sendable {

    /// Emit a remediation proposal. Maps to the estate `propose` verb in
    /// production. The daemon proposes; the human confirms via the verb
    /// surface. The daemon never applies the change itself.
    func propose(_ frame: ProposeFrame) async throws

    /// Record exactly one diary entry summarising the cycle (§ 3.2).
    func recordCycleDiary(_ entry: DiaryEntry) async throws
}

// MARK: - Cycle report

/// What one maintenance cycle did. Returned by `triggerMaintenanceCycle`
/// and `pump` so callers (and conformance tests) can inspect the cycle
/// without reading the substrate back. Mirrors `DreamingCycleReport`.
public struct MaintenanceCycleReport: Sendable, Equatable {

    /// The `now` the cycle ran at.
    public let tickedAt: Date

    /// Whether the audit chain was verified this cycle (the audit-check
    /// interval had elapsed, or this was the first run).
    public let auditChecked: Bool

    /// The audit-chain integrity report, when the chain was checked this
    /// cycle; `nil` when the audit-check interval had not yet elapsed.
    public let auditReport: AuditChainReport?

    /// Proposals emitted this cycle, in emission order, across all scan
    /// categories and the audit-integrity monitor.
    public let proposalsEmitted: [ProposeFrame]

    /// Active drawers that crossed the decay window this cycle.
    public let decayCandidates: Int

    /// Tombstoned drawers past the expunge grace window this cycle.
    public let tombstoneCandidates: Int

    /// Active drawers violating the forbidden-combination invariant
    /// (I-3: secret AND public) this cycle.
    public let forbiddenCombinations: Int

    /// Fingerprint-drift observations at or above threshold this cycle.
    public let fingerprintDrifts: Int

    /// byReference-drift observations at or above threshold this cycle.
    public let byReferenceDrifts: Int

    /// Candidates suppressed because an identical proposal was already
    /// emitted in a prior cycle (B-4 idempotency).
    public let suppressedDuplicates: Int

    /// The single diary entry written this cycle.
    public let diaryEntry: DiaryEntry
}
