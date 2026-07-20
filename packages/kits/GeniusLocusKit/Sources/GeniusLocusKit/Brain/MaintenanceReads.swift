import Foundation
import LocusKit

/// Maintenance daemon read surface — the estate-handle-scoped audit-log
/// read the maintenance daemon's reader seam performs (NEURONKIT_SPEC
/// § 3.5). Follows the same B-1 pattern as `DreamingReads.swift`:
/// GLK resolves the handle, delegates to the in-memory log and the
/// LocusKit audit trail, returns the result. NeuronKit's
/// `EstateMaintenanceReader` calls this through the public GeniusLocusKit
/// surface rather than reaching LocusKit directly.
public extension GeniusLocusKit {

    /// Return a current snapshot of the unified audit log for an estate.
    ///
    /// The maintenance daemon calls this to supply `AuditChainVerifier.verify`
    /// with a current log snapshot (NEURONKIT_SPEC § 3.5 audit-chain integrity
    /// monitor).
    ///
    /// This no longer calls `feedAuditLog` (the removed N+1 per-drawer query
    /// pattern). It delegates to
    /// `auditLog(for:)` which issues a single bounded SQL query against
    /// `_storagekit_audit`. The returned `UnifiedAuditLog` is a value copy
    /// safe to use outside the actor.
    ///
    /// - Parameter handle: the estate whose audit log to return.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale;
    ///   any storage-tier error surfaced by `AuditLog.iterate`.
    func currentAuditLog(in handle: EstateHandle) async throws -> UnifiedAuditLog {
        return try await auditLog(for: handle)
    }
}
