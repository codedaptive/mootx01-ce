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

    /// Feed the in-memory audit log from the estate's LocusKit audit trail
    /// and return a snapshot of the unified log.
    ///
    /// The maintenance daemon calls this to supply `AuditChainVerifier.verify`
    /// with a current log snapshot (NEURONKIT_SPEC § 3.5 audit-chain integrity
    /// monitor). The feed step is idempotent: the G-Set deduplicates entries by
    /// content-addressed id, so repeated calls over the same estate history are
    /// no-ops. The snapshot is a value copy safe to use outside the actor.
    ///
    /// - Parameter handle: the estate whose audit log to refresh and return.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale;
    ///   any LocusKit failure surfaced by `feedAuditLog`.
    func currentAuditLog(in handle: EstateHandle) async throws -> UnifiedAuditLog {
        // Pull the latest audit rows from LocusKit into the in-memory G-Set.
        try await feedAuditLog(for: handle)
        // Return a value-type snapshot; the G-Set copy is safe outside the actor.
        return try auditLog(for: handle)
    }
}
