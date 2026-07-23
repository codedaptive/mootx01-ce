// StorageMaintenance.swift
//
// Physical storage maintenance — WAL checkpoint + page reclamation.
//
// The shared-content 1.1 migration retires legacy tables through declared
// schema migrations, which moves their pages to the SQLite freelist but does
// NOT shrink the database file. This surface is the substrate-level primitive
// that returns those pages to the filesystem (P5: `completeSharedContentReclaim`
// runs it during a maintenance window), and the general-purpose maintenance
// hook for the admin plane.
//
// Exposed as a distinct protocol (not merged into Storage) following the
// StorageIntrospection precedent: the addition is purely additive, existing
// Storage conformers are not broken, and consumers probe capability with
// `as? StorageMaintenance`.
//
// Per-backend contract:
//
// | Behaviour                | SQLite            | PostgreSQL       | InMemory |
// |--------------------------|-------------------|------------------|----------|
// | estimatedReclaimableBytes| freelist×pageSize | 0                | 0        |
// |                          |  + WAL file bytes |                  |          |
// | performMaintenance       | checkpoint+VACUUM | no-op (server-   | no-op    |
// |                          |                   |  managed)        |          |
// | quiescence check         | rejects when a    | n/a              | n/a      |
// |                          |  txn is open      |                  |          |
// | disk-capacity check      | preflight against | n/a              | n/a      |
// |                          |  live-page bytes  |                  |          |

import Foundation

// MARK: - Progress

/// The maintenance operation's phases, in execution order.
public enum StorageMaintenancePhase: String, Sendable, Codable, CaseIterable {
    /// Quiescence and disk-capacity verification; before/after baselines.
    case preflight
    /// `PRAGMA wal_checkpoint(TRUNCATE)` — flush and truncate the WAL.
    case walCheckpoint
    /// `VACUUM` — rewrite the database, returning freelist pages to the
    /// filesystem. Atomic at the SQLite level: cancellation is honoured
    /// BETWEEN phases, never mid-VACUUM.
    case vacuum
    /// Post-operation introspection (page counts, file sizes, report).
    case introspection
}

/// A progress event emitted at the START of each phase.
public struct StorageMaintenanceProgress: Sendable, Equatable {
    /// The phase now beginning.
    public let phase: StorageMaintenancePhase
    /// Number of phases already completed (0-based progress numerator).
    public let completedPhases: Int
    /// Total phases the operation will run (constant 4 for SQLite).
    public let totalPhases: Int

    public init(phase: StorageMaintenancePhase, completedPhases: Int, totalPhases: Int) {
        self.phase = phase
        self.completedPhases = completedPhases
        self.totalPhases = totalPhases
    }
}

// MARK: - Report

/// Post-operation introspection: what the maintenance pass found and freed.
///
/// `reclaimedBytes` is measured against the FILESYSTEM (database file + WAL
/// file before vs. after), not the logical page count — the exit contract of
/// the shared-content migration is that free pages are returned to the
/// filesystem, so the report proves exactly that.
public struct StorageMaintenanceReport: Sendable, Equatable, Codable {
    /// Backend discriminator: "sqlite", "postgresql", or "inmemory".
    public let backend: String
    /// True when a physical operation actually ran (SQLite). False for the
    /// explicit no-op backends (in-memory has no pages; PostgreSQL page
    /// reclamation is server-managed by autovacuum).
    public let performed: Bool
    /// Human-readable note for the no-op cases; nil when `performed`.
    public let note: String?
    public let pageSizeBytes: Int64
    public let pageCountBefore: Int64
    public let pageCountAfter: Int64
    public let freelistPagesBefore: Int64
    public let freelistPagesAfter: Int64
    /// Database file size on disk (bytes), before/after.
    public let fileSizeBytesBefore: Int64
    public let fileSizeBytesAfter: Int64
    /// WAL file size on disk (bytes), before/after. 0 when absent.
    public let walBytesBefore: Int64
    public let walBytesAfter: Int64
    /// Filesystem bytes released: (file+WAL before) − (file+WAL after),
    /// floored at 0.
    public let reclaimedBytes: Int64
    /// Wall-clock duration of the operation in seconds.
    public let durationSeconds: Double

    public init(
        backend: String, performed: Bool, note: String?,
        pageSizeBytes: Int64, pageCountBefore: Int64, pageCountAfter: Int64,
        freelistPagesBefore: Int64, freelistPagesAfter: Int64,
        fileSizeBytesBefore: Int64, fileSizeBytesAfter: Int64,
        walBytesBefore: Int64, walBytesAfter: Int64,
        reclaimedBytes: Int64, durationSeconds: Double
    ) {
        self.backend = backend
        self.performed = performed
        self.note = note
        self.pageSizeBytes = pageSizeBytes
        self.pageCountBefore = pageCountBefore
        self.pageCountAfter = pageCountAfter
        self.freelistPagesBefore = freelistPagesBefore
        self.freelistPagesAfter = freelistPagesAfter
        self.fileSizeBytesBefore = fileSizeBytesBefore
        self.fileSizeBytesAfter = fileSizeBytesAfter
        self.walBytesBefore = walBytesBefore
        self.walBytesAfter = walBytesAfter
        self.reclaimedBytes = reclaimedBytes
        self.durationSeconds = durationSeconds
    }

    /// The canonical no-op report for backends with nothing to reclaim.
    public static func noOp(backend: String, note: String) -> StorageMaintenanceReport {
        StorageMaintenanceReport(
            backend: backend, performed: false, note: note,
            pageSizeBytes: 0, pageCountBefore: 0, pageCountAfter: 0,
            freelistPagesBefore: 0, freelistPagesAfter: 0,
            fileSizeBytesBefore: 0, fileSizeBytesAfter: 0,
            walBytesBefore: 0, walBytesAfter: 0,
            reclaimedBytes: 0, durationSeconds: 0)
    }
}

// MARK: - Error

public enum StorageMaintenanceError: Error, Equatable, Sendable {
    /// A transaction is open on the maintenance connection. VACUUM cannot
    /// run inside a transaction; the caller must retry when the estate is
    /// quiescent.
    case notQuiescent(reason: String)
    /// VACUUM rewrites the live pages into a temporary copy, so the volume
    /// needs at least the live-content size free. Preflight refuses rather
    /// than failing mid-rewrite with a half-written temp file.
    case insufficientDiskCapacity(requiredBytes: Int64, availableBytes: Int64)
    /// `shouldCancel` returned true at a phase boundary. No partial state:
    /// each phase is atomic, so a cancelled operation leaves the database
    /// exactly as the last completed phase left it.
    case cancelled(atPhase: StorageMaintenancePhase)
    /// The underlying backend operation failed.
    case backendFailure(reason: String)
}

// MARK: - Protocol

/// Physical maintenance capability. Probe with `storage as? StorageMaintenance`.
public protocol StorageMaintenance: Sendable {
    /// Estimate of the filesystem bytes `performMaintenance` would release:
    /// freelist pages × page size, plus the current WAL file size. Cheap
    /// (read-only PRAGMAs + one file stat); safe to poll for status surfaces.
    func estimatedReclaimableBytes() async throws -> Int64

    /// Run the maintenance pass (SQLite: WAL checkpoint + VACUUM).
    ///
    /// - Parameters:
    ///   - progress: Invoked at the start of each phase. Optional.
    ///   - shouldCancel: Polled at each phase boundary; returning true
    ///     aborts with `.cancelled(atPhase:)` BEFORE the next phase starts.
    ///     VACUUM itself is atomic and is never interrupted mid-flight.
    /// - Returns: The post-operation introspection report.
    /// - Throws: `StorageMaintenanceError`.
    func performMaintenance(
        progress: (@Sendable (StorageMaintenanceProgress) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async throws -> StorageMaintenanceReport
}

extension StorageMaintenance {
    /// Convenience: run with no progress reporting and no cancellation.
    public func performMaintenance() async throws -> StorageMaintenanceReport {
        try await performMaintenance(progress: nil, shouldCancel: nil)
    }
}
