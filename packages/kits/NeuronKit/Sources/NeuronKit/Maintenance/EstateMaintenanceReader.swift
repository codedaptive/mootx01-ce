import Foundation
import GeniusLocusKit
import LocusKit

/// Production adapter that binds `MaintenanceSubstrateReader` to a live
/// GeniusLocusKit estate (NEURONKIT_SPEC § 3.2).
///
/// `MaintenanceSubstrateReader` is the read seam the daemon uses during a
/// cycle. This adapter satisfies it by delegating to GLK estate reads that
/// are B-1-compliant calls through the public GeniusLocusKit verb surface.
///
/// ── Why this lives in NeuronKit, not GeniusLocusKit ──────────────────
/// `MaintenanceSubstrateReader` is declared here in NeuronKit. A conforming
/// type must import NeuronKit. GeniusLocusKit is a dependency of NeuronKit
/// (GLK sits below NK in the stack), so GLK cannot import NK without creating
/// a circular package dependency. NeuronKit is the only package that can see
/// both the protocol and the GLK estate surface, making it the natural home
/// for this adapter — the same constraint that placed `EstateDreamingReader`
/// here.
///
/// ── Bounded scan strategy ────────────────────────────────────────────
/// Active and tombstoned drawer reads delegate to
/// `GeniusLocusKit.allDrawers(in:limit:)` with a cap of `maintenanceScanCap`
/// (512) rows. The limit is applied at the storage tier so the I/O cost is
/// O(cap), not O(estate). B-10a: all reads are internal (no trace_limit set,
/// no recall-trace rows written).
///
/// ── Reference drift (real reads) ─────────────────────────────────────
/// `learnedReferences()` now reads all non-tombstoned `LearnedReference`
/// rows from the estate via `GeniusLocusKit.recallLearnedReferences(_:)`.
/// Each reference's `driftSeverity` operational-bitmap axis (bits 6–11,
/// cookbook § 2.4) is mapped to a drift fraction:
///
///   DriftSeverity.none     → 0.0
///   DriftSeverity.minor    → 0.25
///   DriftSeverity.major    → 0.50
///   DriftSeverity.critical → 1.0
///
/// The fraction is compared against `MaintenancePolicy.byReferenceDriftThreshold`
/// (spec default 0.25) by the daemon's pure decision core. A `.none`-severity
/// reference produces drift 0.0, which is below the default threshold — correctly
/// silent for freshly-learned references that have not yet drifted.
public struct EstateMaintenanceReader: MaintenanceSubstrateReader {

    /// Maximum number of drawers the maintenance reader fetches per scan.
    /// Bounded to keep each cycle O(cap) rather than O(estate). 512 covers
    /// typical small-to-medium estates fully; large estates get a representative
    /// health sample. The storage layer applies the LIMIT before any in-process
    /// filtering, so the I/O cost is O(cap). Matches the Rust reader's
    /// `MAINTENANCE_SCAN_CAP`.
    private static let maintenanceScanCap = 512

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    /// Construct an adapter over the addressed estate.
    ///
    /// - Parameters:
    ///   - handle: the estate to read from.
    ///   - kit: the GeniusLocusKit actor that owns the estate registry.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    // MARK: - MaintenanceSubstrateReader

    /// Non-tombstoned drawers in Cluster A (currently believed) across the estate.
    ///
    /// "Active" per the decay scan means not
    /// tombstoned (`tombstonedAt == nil`) and in Cluster A
    /// (`state.isClusterA`: active, pending, contested, or accepted).
    /// Uses the bounded `GeniusLocusKit.allDrawers(in:limit:)`, which applies
    /// the cap at the storage tier (O(cap) I/O) — the Swift parity of the Rust
    /// reader's bounded scan. The cluster/tombstone filter is applied here.
    /// B-10a: internal read, no trace_limit set.
    public func activeDrawers() async throws -> [Drawer] {
        let all = try await kit.allDrawers(in: handle, limit: Self.maintenanceScanCap)
        return all.filter { $0.tombstonedAt == nil && $0.state.isClusterA }
    }

    /// Tombstoned drawers (`tombstonedAt != nil`) across the estate.
    ///
    /// Used by the tombstone/expunge-candidate scan to find rows past the
    /// grace window. Uses the same bounded `allDrawers(in:limit:)` scan as
    /// `activeDrawers()`.
    /// B-10a: internal read, no trace_limit set.
    public func tombstonedDrawers() async throws -> [Drawer] {
        let all = try await kit.allDrawers(in: handle, limit: Self.maintenanceScanCap)
        return all.filter { $0.tombstonedAt != nil }
    }

    /// Learned-reference observations for the byReference-validity scan.
    ///
    /// Reads all non-tombstoned `LearnedReference` rows from the estate via
    /// `GeniusLocusKit.recallLearnedReferences(_:)` and maps each reference's
    /// `driftSeverity` (bits 6–11 of `operationalBitmap`, cookbook § 2.4) to a
    /// drift fraction in `[0, 1]`:
    ///
    ///   - `.none`     → 0.0  (below default threshold — no proposal)
    ///   - `.minor`    → 0.25 (at default threshold → proposal emitted)
    ///   - `.major`    → 0.50
    ///   - `.critical` → 1.0
    ///
    /// The `referenceRowID` is the reference's stable row id, used as the
    /// proposal target so the human can locate the drifted reference.
    /// Tombstoned references are excluded — they are no longer active.
    public func learnedReferences() async throws -> [LearnedReferenceObservation] {
        let refs = try await kit.recallLearnedReferences(handle)
        return refs
            .filter { $0.tombstonedAt == nil }
            .map { lr in
                LearnedReferenceObservation(
                    referenceRowID: lr.id,
                    sourceDriftFraction: driftFractionForSeverity(lr.driftSeverity)
                )
            }
    }

    /// Active drawers with enrichment-status `qid_pending`, bounded to
    /// `limit` rows (B-10a: internal read, no trace). Scans the full
    /// drawer corpus at the GLK tier — `limit` caps the output count,
    /// not the scan cost.
    ///
    /// Delegates to `GeniusLocusKit.qidPendingDrawers(in:limit:)`, which
    /// filters the full drawer corpus to non-tombstoned Cluster-A rows with
    /// enrichment-status == `.qidPending` (provenance bits 36-41 == 1,
    /// cookbook §2.5) and truncates to `limit`.
    public func qidPendingDrawers(limit: Int) async throws -> [Drawer] {
        try await kit.qidPendingDrawers(in: handle, limit: limit)
    }

    /// The current unified audit log, fed from the estate's LocusKit audit
    /// trail and returned as a value-type snapshot.
    ///
    /// Delegates to `GeniusLocusKit.currentAuditLog(in:)`, which delegates to
    /// `auditLog(for:)` — a single bounded SQL query against
    /// `_storagekit_audit`, replacing the removed N+1 per-drawer
    /// `feedAuditLog` walk. `AuditChainVerifier.verify`
    /// consumes the returned snapshot in the daemon's audit-integrity monitor
    /// (§ 3.5); the snapshot's `rejectedEntryCount` (AUDIT-ALERT-RESTORE,
    /// 2026-07-09) feeds the same monitor's ingress-rejection alert.
    public func currentAuditLog() async throws -> UnifiedAuditLog {
        try await kit.currentAuditLog(in: handle)
    }

    // MARK: - Pure helpers

    /// Map a `DriftSeverity` to a drift fraction in `[0, 1]`.
    ///
    /// The mapping is anchored at the default policy threshold (0.25) so that
    /// `.minor` severity exactly triggers a proposal with the default policy —
    /// matching the spec's intent that Minor is actionable.
    private func driftFractionForSeverity(_ severity: DriftSeverity) -> Float {
        switch severity {
        case .none:     return 0.0
        case .minor:    return 0.25
        case .major:    return 0.50
        case .critical: return 1.0
        }
    }
}
