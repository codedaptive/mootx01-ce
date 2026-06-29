// MaintenanceSeams.swift
//
// The maintenance daemon's substrate seams (NEURONKIT_SPEC § 3.2) plus
// the scan-input value types and the cycle report. Mirrors the dreaming
// daemon's reader / sink / report split.
//
// ── Why the daemon talks to seams, not to GLK verbs ──────────────────
// MOOTx01 invariant B-1: NeuronKit never executes SQL and never calls
// LocusKit / VectorKit / CorpusKit directly; the estate handle is the only
// write surface. The seam protocols decouple the daemon from the GLK surface
// so the daemon can be constructed, tested, and reasoned about without a live
// estate. The production adapters (`EstateMaintenanceSink`,
// `EstateMaintenanceReader`) delegate through GLK's public verb surface (B-1):
// `propose` via `GeniusLocusKit.propose(_:_:)`, diary writes via
// `GeniusLocusKit.addDiaryEntry(in:_:)`, and drawer reads via
// `GeniusLocusKit.allDrawers(in:)` and `GeniusLocusKit.currentAuditLog(in:)`.
// The daemon references substrate VALUE types (`Drawer`, `UnifiedAuditLog`,
// `DiaryEntry`, `ProposeFrame`, `ProposalKind`) but calls no substrate
// method directly, so B-1 holds.

import Foundation
import GeniusLocusKit

// MARK: - Scan-input observation value types

/// One learned-reference observation, the input to the byReference
/// validity scan (NEURONKIT_SPEC § 3.2 scan category 5). A learned
/// reference (a `LearnedReference` source per architecture spec § 10
/// row 7) points at a source drawer; over time that source's content
/// can drift away from what the reference was learned against. The
/// adapter maps the reference's `driftSeverity` operational-bitmap value
/// (none → 0.0, minor → 0.25, major → 0.50, critical → 1.0) to
/// `sourceDriftFraction`; the daemon proposes once it crosses the threshold.
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
/// scan (NEURONKIT_SPEC § 3.2 scan category 4). A container node
/// (room-level per ADR-017) carries a rolled-up fingerprint OR-aggregate
/// of its drawers' bitmap lanes; the adapter computes `driftFraction` as
/// the set-bit density of the OR-aggregate over the three bitmap lanes
/// (192 bits; no baseline-persistence surface exists). The daemon proposes
/// a fingerprint-drift review once `driftFraction` crosses the threshold.
///
/// Value type. Carries the node ID (parentNodeId of the drawers) as the
/// scope key and the precomputed drift fraction.
public struct FingerprintDriftObservation: Sendable, Equatable {

    /// The parentNodeId (room-level container node per ADR-017) whose
    /// fingerprint has drifted. Used as the scope key for dedup and
    /// as the basis for the proposal target.
    public let scopeKey: String

    /// The node ID of the container. Equal to `scopeKey` in the current
    /// implementation; carried explicitly for forward compatibility with
    /// multi-level node hierarchies.
    public let nodeId: String

    /// Fraction in `[0, 1]` of fingerprint bits that have drifted from
    /// baseline (set-bit density / bit width). Compared to
    /// `MaintenancePolicy.fingerprintDriftThreshold`.
    public let driftFraction: Float

    public init(scopeKey: String, nodeId: String, driftFraction: Float) {
        self.scopeKey = scopeKey
        self.nodeId = nodeId
        self.driftFraction = driftFraction
    }
}

// MARK: - Read seam

/// Read surface the maintenance daemon scans (NEURONKIT_SPEC § 3.2). All
/// six reads are pure inputs — the daemon mutates nothing through this
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

    /// Drawers with enrichment status `qid_pending` (provenance bits 36-41 == 1,
    /// cookbook §2.5), bounded to `limit` rows for O(cap) scan cost. The
    /// maintenance daemon uses these as input to the QID-pending retry batch
    /// (Board item 14). The adapter returns active (non-tombstoned, Cluster-A)
    /// drawers only, in `filedAt` ascending order. B-10a: internal read,
    /// no trace_limit, no recall-trace rows written.
    func qidPendingDrawers(limit: Int) async throws -> [Drawer]
}

// MARK: - Write seam

/// Write surface the maintenance daemon emits through (NEURONKIT_SPEC
/// § 3.2). This is the daemon's ONLY write path. It exposes exactly three
/// operations — emit a proposal, record the cycle diary entry, and update
/// enrichment status — and
/// deliberately has NO remediation method (no expunge, no withdraw, no
/// mutate). That absence is how the never-remediate invariant (§ 3.2) is
/// enforced structurally: the daemon cannot remediate because nothing it
/// can reach does. It can only propose, exactly as the dreaming sink can
/// only propose and never creates a Tunnel.
///
/// `EstateMaintenanceSink` is the production adapter; it implements
/// `propose(_:)` by forwarding to the estate handle's `propose` verb
/// (the legal B-1 write path), `recordCycleDiary(_:)` by forwarding
/// to `addDiaryEntry`, and `updateEnrichmentStatus(_:newProvenance:now:)` by
/// forwarding to `GeniusLocusKit.updateEnrichmentStatus(in:rowID:…)`.
public protocol MaintenanceProposalSink: Sendable {

    /// Emit a remediation proposal. Maps to the estate `propose` verb in
    /// production. The daemon proposes; the human confirms via the verb
    /// surface. The daemon never applies the change itself.
    func propose(_ frame: ProposeFrame) async throws

    /// Record exactly one diary entry summarising the cycle (§ 3.2).
    func recordCycleDiary(_ entry: DiaryEntry) async throws

    /// Update a drawer's provenance bitmap after a QID-pending retry
    /// (Board item 14, NEURONKIT_SPEC § 3.2). The caller supplies the
    /// new full provenance value with the enrichment-status field
    /// (bits 36-41) set to the result of the retry (qid_completed on
    /// success, qid_pending unchanged on failure). Routes through
    /// `GeniusLocusKit.updateEnrichmentStatus(in:rowID:…)`, which calls
    /// `Estate.mutateProvenance` and writes an audit row atomically.
    ///
    /// Determinism: `now` is the caller-supplied timestamp.
    func updateEnrichmentStatus(
        rowID: RowID,
        newProvenance: Int64,
        now: Date
    ) async throws
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

    // MARK: - QID-pending retry telemetry (Board item 14)

    /// Number of drawers with enrichment-status `qid_pending` that the
    /// daemon attempted to retry this cycle (the retry batch size, capped
    /// at `QID_RETRY_SCAN_CAP`). Emitted as the
    /// `neuronkit.enrichment.qid_retry` counter.
    public let qidRetried: Int

    /// Number of retried drawers for which Q-ID resolution succeeded this
    /// cycle (enrichment status flipped to `qid_completed`). Emitted as
    /// the `neuronkit.enrichment.qid_resolved` counter.
    public let qidResolved: Int

    /// Number of retried drawers that deterministic re-inference could not
    /// resolve this cycle and for which the daemon therefore filed an
    /// enrichment proposal and flipped the status to the terminal
    /// in-workflow state `qid_proposed`. These leave the retry backlog.
    /// Emitted as the `neuronkit.enrichment.qid_proposed` counter.
    public let qidProposed: Int

    /// Number of retried drawers that remain `qid_pending` after this cycle
    /// SOLELY because the substrate write failed (a real runtime failure) —
    /// never a deterministic re-inference miss, which now terminates as
    /// `qid_proposed`. Emitted as the
    /// `neuronkit.enrichment.qid_still_pending` counter.
    public let qidStillPending: Int

    // MARK: - ADR-017 node invariant verification telemetry

    /// Number of ADR-017 node-tree invariant violations detected this
    /// cycle. Covers I-NT-3 (empty parentNodeId) and sibling display-name
    /// consistency. Emitted as the
    /// `neuronkit.node_invariant.violations` counter.
    public let nodeInvariantViolations: Int
}
