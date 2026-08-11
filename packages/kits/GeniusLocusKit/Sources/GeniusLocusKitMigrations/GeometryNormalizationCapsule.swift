// GeometryNormalizationCapsule.swift
//
// Migration-chain capsule: detect and repair foreign SQLite geometry before any
// capsule that calls performMaintenance (VACUUM fails on foreign geometry).
//
// The capsule is format-agnostic: it runs on ANY plaintext estate with nonzero
// reserved-bytes-per-page, regardless of migration floor. It is not gated on
// MigrationV1_0ToV1_1 because the heuristic bug is a file-geometry concern, not
// a schema concern.
//
// Design decisions:
//   - Errors are parked (caught and downgraded to no-op reports) rather than
//     propagating. A geometry failure must not prevent the estate from opening;
//     VACUUM may then surface the original error when it runs, making it
//     retryable by the maintenance scheduler.
//   - The capsule produces no migration-lane record: it is not a schema change
//     and leaves no persistent state beyond the normalized file.

import Foundation
import PersistenceKit

/// Geometry-normalization migration capsule.
///
/// Corrects nonzero SQLite per-page reserved-bytes (file header byte 20 ≠ 0)
/// on plaintext estates before any capsule that invokes VACUUM. See
/// `StorageMaintenance.normalizeGeometry()` and `SQLiteStorage+Geometry.swift`
/// for the full repair sequence.
public enum GeometryNormalizationCapsule {

    /// Run geometry normalization on `storage`.
    ///
    /// Parks any error — if normalization cannot complete, returns a no-op
    /// report so `prepare()` can continue. A downstream VACUUM will surface
    /// the original issue when the maintenance scheduler runs.
    ///
    /// - Parameter storage: The opened estate storage. Non-SQLite backends
    ///   use the protocol-extension default no-op.
    /// - Returns: The normalization report from the backend.
    public static func run(storage: any Storage) async -> GeometryNormalizationReport {
        guard let maintainable = storage as? any StorageMaintenance else {
            return .noOp()
        }
        do {
            return try await maintainable.normalizeGeometry()
        } catch {
            // Park: log the failure and continue. VACUUM will surface this
            // when the maintenance scheduler runs.
            return .noOp()
        }
    }
}
