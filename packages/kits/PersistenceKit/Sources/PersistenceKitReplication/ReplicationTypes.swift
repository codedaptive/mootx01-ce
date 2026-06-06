// ReplicationTypes.swift
//
// Public types for the PersistenceKitReplication module.
//
// ReplicationMode governs the scope of a replicate() call.
// ReplicationCursor carries the HLC high-water mark after a flush
// or hydrate; upstream callers use it to resume incremental runs
// (§6, not yet implemented here).
// ReplicationError is the closed error enum for this module; it
// wraps StorageError where needed but adds schema-gate failures that
// are specific to the replication primitive.

import Foundation
import PersistenceKit
import SubstrateTypes

// MARK: - ReplicationMode

/// Controls the scope of a single replicate() call.
///
/// Only `.full` is implemented in this module (§5). The `.incremental`
/// case is defined for forward-compatibility but throws
/// `ReplicationError.notImplemented` when used — §6 is a separate track.
public enum ReplicationMode: Sendable {
    /// Copy every row in every schema-declared table, all audit events,
    /// and all blobs (if any). Idempotent: a second full flush with no
    /// changes writes zero new rows. Wraps the entire destination write
    /// in a serializable transaction for atomicity.
    case full

    /// Incremental copy driven by a StorageObserver dirty-set (§6).
    /// NOT YET IMPLEMENTED — throws `ReplicationError.notImplemented`.
    ///
    /// NOTE: The §6 incremental path MUST drive its dirty-set off
    /// StorageObserver.observe (fires on every rowStore write), NOT
    /// auditLog.iterate. The GLK AuditGate is drawer-only today; several
    /// noun inserts bypass it, so an audit-driven incremental flush would
    /// silently miss them (silent data loss). This case is present here
    /// only to stake out the API; the implementation is a follow-on mission.
    case incremental(cursor: ReplicationCursor)
}

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

    public init(hlcWatermark: HLC?, rowsWritten: Int, auditEventsWritten: Int) {
        self.hlcWatermark = hlcWatermark
        self.rowsWritten = rowsWritten
        self.auditEventsWritten = auditEventsWritten
    }
}

// MARK: - ReplicationError

/// Errors specific to the replication primitive.
public enum ReplicationError: Error, Sendable, Equatable {
    /// The source and destination schema versions differ, or their kitIDs
    /// differ. Replication refuses to auto-migrate — upgrade both estates
    /// to the same schema version before replicating.
    case schemaMismatch(sourceVersion: Int, destinationVersion: Int, sourceKitID: String, destinationKitID: String)

    /// The requested ReplicationMode is not yet implemented.
    /// Currently only `.full` is implemented; `.incremental` throws this.
    case notImplemented(reason: String)

    /// A StorageError surfaced during source reads or destination writes.
    /// Wraps the underlying error as a string so ReplicationError stays Equatable.
    case storageFailure(detail: String)
}
