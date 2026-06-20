// NodeAuditEntries.swift
//
// The public audit-data accessor the diffusion node lens (NeuronKit) folds.
// GLK owns the audit log and the AuditBridge (which is internal); NeuronKit owns
// the motion-model algorithm. So GLK exposes the bridged per-node entries and
// NeuronKit reads them through `kit` — the same NeuronKit→GLK direction the
// recall lenses use (`Anticipate.run(kit:handle:)`, etc.).

import Foundation

public extension GeniusLocusKit {

    /// A node's bridged `.locus` audit entries, read FRESH from the live per-row
    /// trail — `estate.auditTrail` includes the just-written event, unlike the
    /// `UnifiedAuditLog` which is only fed on dream/open. This is the data the
    /// diffusion node-motion lens folds for a write-time-accurate verdict.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - rowID: the node's drawer id (UUID string).
    /// - Returns: the node's bridged audit entries, HLC-ordered by the trail.
    func nodeAuditEntries(
        for handle: EstateHandle,
        rowID: String
    ) async throws -> [UnifiedAuditEntry] {
        let estate = try estate(for: handle)
        let events = try await estate.auditTrail(rowID: rowID)
        return events.flatMap { AuditBridge.bridge($0) }
    }
}
