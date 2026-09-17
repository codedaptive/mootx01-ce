import Foundation
import GeniusLocusKit
import PersistenceKit

/// Historical code, compiled only by upgrade-capable hosts. The matrices are
/// regenerated, not converted. Only calibration observations survive the BLOB.
public enum MatrixRecordMigration {
    public static let legacySchema = SchemaDeclaration(kitID: "GeniusLocusKitMatrix", version: 1, tables: [
        TableDeclaration(name: "matrix_snapshot", columns: [
            .text("estate_id"), .int("schema_version"), .blob("snapshot"),
            .text("last_hlc"), .timestamp("updated_at"), .json("ext", nullable: true)
        ], primaryKey: ["estate_id"])
    ])
    private static let retiredSchema = SchemaDeclaration(kitID: "GeniusLocusKitMatrix", version: 2,
        tables: [], migrations: [Migration(fromVersion: 1, toVersion: 2,
            operations: [.dropTable(name: "matrix_snapshot")])])

    /// Caller owns exclusive estate access for this entire operation. Normal
    /// serving remains disabled until the format stamp advances on success.
    /// Returns `true` when a legacy snapshot blob was found and retired — i.e.
    /// actual data migration occurred. Returns `false` for a no-op pass (no
    /// blob row, nothing to rebuild), which stamps the format without moving data.
    ///
    /// F5: `limits` is a FLOOR, not the working budget. `MatrixRefreshLimits`'
    /// 1,000,000-per-field defaults are sized for the LIVE resident's refresh
    /// admission gate (Bob's ruling: those defaults stay unchanged there).
    /// This is a ONE-TIME, quiesced, offline rebuild
    /// (`ResidentDaemonQuiesce.run` holds exclusive access for the whole
    /// operation) — an estate whose audit log or drawer count the disk
    /// already holds beyond that default must still migrate, not refuse with
    /// `MatrixRecordError.workingSetLimit` and strand the estate at v1.9
    /// forever. Before calling the worker, this counts the estate's actual
    /// audit-event and source-row totals and widens `limits` to cover them.
    @discardableResult
    public static func run(storage: any Storage, estateID: UUID, now: Date,
                           limits requestedLimits: MatrixRefreshLimits = .init()) async throws -> Bool {
        // Sized to what the disk actually holds, never smaller than the
        // caller-supplied floor. `cells` has no cheap exact count without
        // building the tier (chicken-and-egg — the worker computes it), so it
        // is bounded by a generous multiple of the two counts that DO have a
        // cheap COUNT(*): the F/O/C/T maps are keyed by field- and row-pairs
        // that co-occur within the audit trail, not by the full cross-product
        // of every row against every other row, so a small constant factor
        // over (audit events + source rows) covers real corpora with room to
        // spare. If a future estate's cell count grows faster than this
        // factor accounts for, that is itself a "the estate is absurd, not
        // that the migration is broken" backstop question — same posture as
        // `lsaRetrainingDocumentBackstop`.
        //
        // Security scanners flag this as memory amplification: the counts
        // come from the estate, the estate grows through ordinary writes,
        // so a large estate makes the next upgrade hold the whole audit log
        // in memory with no absolute ceiling. That is understood and it is
        // NOT going to be fixed. The estate is the operator's own data and
        // the upgrade is the operator's own action; a cap here would refuse
        // to migrate a real estate and strand it at v1.9, which is the
        // defect this sizing exists to remove. Ruled 2026-09-17; do not
        // reintroduce a fixed limit to satisfy the scanner.
        let auditRowCount = try await storage.auditLog.count()
        let sourceRowCount = try await storage.rowStore.count(table: "drawers", where: nil)
        let limits = MatrixRefreshLimits(
            auditEvents: max(requestedLimits.auditEvents, auditRowCount),
            cells: max(requestedLimits.cells, (auditRowCount + sourceRowCount) * 8),
            sourceRows: max(requestedLimits.sourceRows, sourceRowCount))
        let format = EstateFormatStore(storage: storage)
        let found = try await format.readIfPresent()
        if let found, found > .v1_10 { throw MatrixRecordError.corrupt("newer estate format") }
        if found == .v1_10 { return false }
        var didMigrate = false
        let store = MatrixRecordStore(storage: storage)
        try await store.prepare()
        var phase = try await store.state(estateID: estateID).map { MatrixRecordStore.text($0.values, "migration_phase") }

        let active = try await store.activeGeneration(estateID: estateID)
        if (phase != "reclaimPending" && phase != "complete") || active == nil {
            if try await storage.currentSchemaVersion(for: legacySchema.kitID) < 2 {
                // Also registers a legacy table created under a composite schema.
                // If absent, this creates it empty and immediately retires it.
                try await storage.migrate(to: legacySchema)
                let rows = try await storage.rowStore.query(table: "matrix_snapshot", where: nil,
                    orderBy: [], limit: 2, offset: nil)
                guard rows.count <= 1 else { throw MatrixRecordError.corrupt("legacy matrix table contains multiple estates") }
                if let row = rows.first {
                    guard case let .text(id)? = row["estate_id"], UUID(uuidString: id) == estateID,
                          case let .blob(bytes)? = row["snapshot"] else {
                        throw MatrixRecordError.corrupt("legacy matrix ownership or payload is invalid")
                    }
                    let calibration = try await Task.detached(priority: .utility) {
                        try LegacyMatrixCalibration.decode(bytes)
                    }.value
                    for model in calibration.curves.keys.sorted() {
                        try await store.saveCalibration(estateID: estateID, registry: calibration, modelID: model)
                    }
                    let restored = try await store.loadCalibration(estateID: estateID)
                    guard restored.curves == calibration.curves,
                          calibration.updateTimestamps.allSatisfy({ model, time in
                              restored.updateTimestamps[model].map { abs($0 - time) <= 0.000001 } == true
                          }) else { throw MatrixRecordError.corrupt("calibration verification failed; legacy snapshot retained") }
                    // A legacy blob was found and its calibration extracted; this
                    // pass migrated real data.
                    didMigrate = true
                }
                // This phase is durable BEFORE the destructive step. A crash
                // after DROP resumes a rebuild from source, never from the BLOB.
                try await store.setMigration(estateID: estateID, phase: "rebuilding")
                try await storage.migrate(to: retiredSchema)
            }
            try await store.setMigration(estateID: estateID, phase: "rebuilding")
            try await store.invalidate(estateID: estateID)
            let worker = MatrixRefreshWorker(storage: storage, estateID: estateID)
            do {
                _ = try await worker.request(now: now, frozen: false, limits: limits, publish: { _ in })
                let rebuilt = try await worker.wait()
                await worker.close()
                guard try await store.load(estateID: estateID, cellLimit: limits.cells) == rebuilt else {
                    throw MatrixRecordError.corrupt("rebuilt matrix verification failed")
                }
            } catch {
                await worker.close()
                throw error
            }
            try await store.prune(estateID: estateID, keeping: Set([try await store.activeGeneration(estateID: estateID)].compactMap { $0 }))
            try await store.setMigration(estateID: estateID, phase: "reclaimPending")
            phase = "reclaimPending"
        }
        if phase != "complete" {
            guard let maintenance = storage as? any StorageMaintenance else { throw MatrixRecordError.maintenanceUnavailable }
            let report = try await maintenance.performMaintenance(progress: nil, shouldCancel: { Task.isCancelled })
            guard report.backend != "unsupported", report.backend != "sqlite" || report.performed else {
                throw MatrixRecordError.maintenanceUnavailable
            }
            try await store.setMigration(estateID: estateID, phase: "complete", reclaimedBytes: report.reclaimedBytes)
        }
        try await format.stamp(.v1_10, now: now)
        return didMigrate
    }
}

public extension GeniusLocusKit {
    /// Runs the 1.9 → 1.10 matrix-records upgrade capsule. Returns `true` when
    /// a legacy snapshot blob was found and retired (actual data migration);
    /// returns `false` for a no-op pass that only stamps the new format.
    @discardableResult
    func runMatrixRecordMigration(handle: EstateHandle, now: Date) async throws -> Bool {
        let storage = try migrationStorage(for: handle)
        return try await MatrixRecordMigration.run(storage: storage, estateID: handle.estateUUID, now: now)
    }
}

/// Read only the non-rebuildable portion. Neither a legacy matrix object nor a
/// legacy writer is retained in the current runtime.
enum LegacyMatrixCalibration {
    private struct Envelope: Decodable {
        let schemaVersion: Int
        let calibration: MatrixCalibrationRegistry
    }
    static func decode(_ bytes: Data) throws -> MatrixCalibrationRegistry {
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.schemaVersion == 1 else { throw MatrixRecordError.corrupt("unsupported legacy matrix version") }
        for (model, curve) in envelope.calibration.curves {
            guard curve.buckets.count == 20,
                  curve.buckets.allSatisfy({ $0.count >= 0 && $0.successRate.isFinite && (0...1).contains($0.successRate) }),
                  envelope.calibration.updateTimestamps[model]?.isFinite != false else {
                throw MatrixRecordError.corrupt("unreadable legacy calibration; refusing retirement")
            }
        }
        guard Set(envelope.calibration.updateTimestamps.keys).isSubset(of: Set(envelope.calibration.curves.keys)) else {
            throw MatrixRecordError.corrupt("orphan legacy calibration timestamp")
        }
        return envelope.calibration
    }
}
