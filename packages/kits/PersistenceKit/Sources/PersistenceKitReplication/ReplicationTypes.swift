// ReplicationTypes.swift
//
// Public types for the PersistenceKitReplication module.
//
// ReplicationCursor carries the HLC high-water mark after a full flush.
// Callers that need §6 incremental replication use IncrementalReplicationSession
// directly — it maintains its own dirty-set and cursor bookkeeping outside
// of the StorageReplicator full-snapshot primitive.
// ReplicationError is the closed error enum for this module; it
// wraps StorageError where needed but adds schema-gate failures that
// are specific to the replication primitive.

import Foundation
import PersistenceKit
import SubstrateTypes

// MARK: - ReplicationCursor

/// Opaque watermark returned from replicate(). Records the maximum HLC
/// observed across all copied rows and audit events. Consumers that
/// implement §6 incremental replication store this cursor in the durable
/// backend and pass it back on the next call to resume from where the
/// last flush ended.
public struct ReplicationCursor: Sendable, Equatable {
    /// The highest HLC seen across all copied rows' timestamp/hlc columns
    /// and all copied audit events. Used as the lower-bound cursor for
    /// the §6 incremental path.
    public let hlcWatermark: HLC?

    /// Number of rows written across all tables during this run.
    public let rowsWritten: Int

    /// Number of audit events copied during this run.
    public let auditEventsWritten: Int

    /// Number of blobs copied during this run (full-snapshot only;
    /// incremental reports blob put/delete operations as blobsWritten).
    public let blobsWritten: Int

    public init(hlcWatermark: HLC?, rowsWritten: Int, auditEventsWritten: Int, blobsWritten: Int = 0) {
        self.hlcWatermark = hlcWatermark
        self.rowsWritten = rowsWritten
        self.auditEventsWritten = auditEventsWritten
        self.blobsWritten = blobsWritten
    }
}

// MARK: - ReplicationError

/// Errors specific to the replication primitive.
public enum ReplicationError: Error, Sendable, Equatable {
    /// The source and destination schema versions differ, or their kitIDs
    /// differ. Replication refuses to auto-migrate — upgrade both estates
    /// to the same schema version before replicating.
    case schemaMismatch(sourceVersion: Int, destinationVersion: Int, sourceKitID: String, destinationKitID: String)

    /// A StorageError surfaced during source reads or destination writes.
    /// Wraps the underlying error as a string so ReplicationError stays Equatable.
    case storageFailure(detail: String)
}
