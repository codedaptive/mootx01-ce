import Foundation
import GeniusLocusKit

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
/// ── v1 stubs ─────────────────────────────────────────────────────────
/// Two of the five reads return empty arrays in v1:
///
/// - `learnedReferences()`: requires `DrawerStore.allLearnedReferences()`,
///   which does not exist in the current LocusKit DrawerStore API
///   (`learnedReferences(forSourceCatalogID:)` is source-scoped). A
///   follow-on mission adds the full-corpus scan. v1 returns `[]`, so the
///   byReference-validity scan proposes nothing, which is safe.
///
/// - `fingerprintBaselines()`: requires persisted fingerprint baselines for
///   rooms and wings (computed from `ContainerFingerprintStore`). Baseline
///   persistence is a follow-on. v1 returns `[]`, so the fingerprint-drift
///   scan proposes nothing, which is safe.
public struct EstateMaintenanceReader: MaintenanceSubstrateReader {

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
    /// "Active" per the decay and forbidden-combination scans means not
    /// tombstoned (`tombstonedAt == nil`) and in Cluster A
    /// (`state.isClusterA`: active, pending, contested, or accepted).
    /// Uses `GeniusLocusKit.allDrawers(in:)`, which returns a full-corpus
    /// snapshot (including tombstoned rows); the filter is applied here.
    public func activeDrawers() async throws -> [Drawer] {
        let all = try await kit.allDrawers(in: handle)
        return all.filter { $0.tombstonedAt == nil && $0.state.isClusterA }
    }

    /// Tombstoned drawers (`tombstonedAt != nil`) across the estate.
    ///
    /// Used by the tombstone/expunge-candidate scan to find rows past the
    /// grace window. Uses the same `allDrawers(in:)` full-corpus snapshot
    /// as `activeDrawers()`; a single GLK round-trip for both reads would
    /// be a follow-on optimisation.
    public func tombstonedDrawers() async throws -> [Drawer] {
        let all = try await kit.allDrawers(in: handle)
        return all.filter { $0.tombstonedAt != nil }
    }

    /// Learned-reference observations for the byReference-validity scan.
    ///
    /// v1: returns `[]`. Full implementation requires `DrawerStore.allLearnedReferences()`
    /// (full-corpus scan with no source filter), which does not exist in
    /// the current DrawerStore API. Follow-on mission adds the scan and
    /// the sourceDriftFraction computation.
    public func learnedReferences() async throws -> [LearnedReferenceObservation] {
        []
    }

    /// Fingerprint-drift observations for the fingerprint-drift scan.
    ///
    /// v1: returns `[]`. Full implementation reads room/wing baseline
    /// fingerprints from `ContainerFingerprintStore`, computes Hamming
    /// distance against live fingerprints, and returns one
    /// `FingerprintDriftObservation` per scope that has drifted past
    /// threshold. Baseline persistence is a follow-on mission.
    public func fingerprintBaselines() async throws -> [FingerprintDriftObservation] {
        []
    }

    /// The current unified audit log, fed from the estate's LocusKit audit
    /// trail and returned as a value-type snapshot.
    ///
    /// Delegates to `GeniusLocusKit.currentAuditLog(in:)`, which calls
    /// `feedAuditLog(for:)` to pull latest audit rows into the in-memory
    /// G-Set and then returns a snapshot. `AuditChainVerifier.verify`
    /// consumes the snapshot in the daemon's audit-integrity monitor (§ 3.5).
    public func currentAuditLog() async throws -> UnifiedAuditLog {
        try await kit.currentAuditLog(in: handle)
    }
}
