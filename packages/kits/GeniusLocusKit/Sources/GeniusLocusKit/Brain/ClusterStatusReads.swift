// ClusterStatusReads.swift
//
// Read-only cluster status queries for GeniusLocusKit.
//
// Exposes the cluster status surface that Consolidate (CognitionKit) and
// other callers need to populate Output.heldClusterIDs and
// Output.failedClusterIDs after a distillation sweep. All queries are
// read-only on the existing memory_clusters schema — no schema change.

import Foundation
import OSLog
import PersistenceKit

private let logger = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

public extension GeniusLocusKit {

    // MARK: - Cluster status reads

    /// Return the UUIDs of all clusters with the given status in this estate.
    ///
    /// Queries `memory_clusters` for rows whose `status` column matches
    /// `status`. Returns an empty array when no clusters match, when the
    /// estate has no GLK schema applied (locus-only estates do not have a
    /// memory_clusters table), or when no VectorStore is registered (estates
    /// that do not participate in the cluster distillation cycle).
    ///
    /// - Parameters:
    ///   - status: the status string to filter on (e.g. "held", "failed",
    ///     "open", "distilled").
    ///   - handle: the estate. Must be open.
    /// - Returns: array of cluster UUID strings, in insertion order.
    func clusterIDs(withStatus status: String, handle: EstateHandle) async throws -> [String] {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        // Locus-only estates (no VectorStore registered) do not participate in
        // the distillation cycle and have no memory_clusters table. Return []
        // rather than propagating a "table not found" StorageError.
        guard vectorStores[handle] != nil else {
            return []
        }
        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(
                Column(table: "memory_clusters", name: "status"),
                .text(status)
            ),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { row in
            guard case .text(let id) = row["id"] else { return nil }
            return id
        }
    }

    /// Return the UUIDs of all clusters with `status = 'held'` in this estate.
    ///
    /// Convenience wrapper over `clusterIDs(withStatus:handle:)`.
    /// Held clusters were gated by the SNR threshold (SNR < 2.0) during the
    /// last distillation sweep; they are candidates for re-distillation once
    /// more members have arrived.
    ///
    /// - Parameter handle: the estate. Must be open.
    /// - Returns: array of held cluster UUID strings.
    func heldClusterIDs(handle: EstateHandle) async throws -> [String] {
        try await clusterIDs(withStatus: "held", handle: handle)
    }

    /// Return the UUIDs of all clusters with `status = 'failed'` in this estate.
    ///
    /// Convenience wrapper over `clusterIDs(withStatus:handle:)`.
    /// Failed clusters had confidence below the 0.4 threshold or suffered an
    /// explicit pipeline error during the last distillation sweep.
    ///
    /// - Parameter handle: the estate. Must be open.
    /// - Returns: array of failed cluster UUID strings.
    func failedClusterIDs(handle: EstateHandle) async throws -> [String] {
        try await clusterIDs(withStatus: "failed", handle: handle)
    }
}
