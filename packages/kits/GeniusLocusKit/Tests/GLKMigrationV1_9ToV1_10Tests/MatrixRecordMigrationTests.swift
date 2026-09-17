#if GLK_MIGRATION_V1_9_TO_V1_10
import Foundation
import Testing
import GeniusLocusKit
import GLKMigrationV1_9ToV1_10
import PersistenceKit
import PersistenceKitSQLite
import LocusKit

@Suite("Matrix offline migration")
struct MatrixOfflineMigrationTests {
    @Test
    func corruptCalibrationBlocksRetirementThenRetryPreservesAndReclaims() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matrix-migration-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = try SQLiteStorage(configuration: EstateConfiguration(estateID: UUID(),
            backend: .sqlite(url: folder.appendingPathComponent("estate.sqlite"), busyTimeout: 5)))
        let estate = try await LocusKit.Estate.create(storage: storage, owner: .init(ownerIdentifier: "test"))
        // The UUID is owned by the persisted manifest, not the configuration.
        let manifest = try await estate.manifest
        let id = try #require(UUID(uuidString: manifest.estateUUID))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let format = EstateFormatStore(storage: storage)
        try await format.stamp(.v1_9, now: now)
        try await storage.migrate(to: MatrixRecordMigration.legacySchema)
        func legacy(_ bytes: Data) async throws {
            try await storage.rowStore.upsert(table: "matrix_snapshot", values: [
                "estate_id": .text(id.uuidString), "schema_version": .int(1),
                "snapshot": .blob(bytes), "last_hlc": .text("0.0.0"), "updated_at": .timestamp(now)
            ], conflictColumns: ["estate_id"])
        }
        try await legacy(Data([0]))
        do {
            try await MatrixRecordMigration.run(storage: storage, estateID: id, now: now)
            Issue.record("corrupt calibration allowed retirement")
        } catch {}
        #expect(try await storage.currentSchemaVersion(for: "GeniusLocusKitMatrix") == 1)
        #expect(try await format.readIfPresent() == .v1_9)
        var calibration = MatrixCalibrationRegistry()
        calibration.recordWithDecay(modelID: "model", claimedConfidence: 0.8, outcome: .success, now: now)
        struct Legacy: Encodable { let schemaVersion = 1; let calibration: MatrixCalibrationRegistry; let ignored: String }
        try await legacy(JSONEncoder().encode(Legacy(calibration: calibration, ignored: String(repeating: "x", count: 262_144))))
        try await MatrixRecordMigration.run(storage: storage, estateID: id, now: now)
        let records = MatrixRecordStore(storage: storage)
        #expect(try await records.loadCalibration(estateID: id) == calibration)
        #expect(try await records.load(estateID: id) != nil)
        #expect(try await storage.currentSchemaVersion(for: "GeniusLocusKitMatrix") == 2)
        #expect(try await format.readIfPresent() == .v1_10)
        let state = try await records.state(estateID: id)
        if case let .int(bytes)? = state?["reclaimed_bytes"] { #expect(bytes > 0) }
        else { Issue.record("missing measured reclamation") }
        try await MatrixRecordMigration.run(storage: storage, estateID: id, now: now)
        #expect(try await records.loadCalibration(estateID: id) == calibration)
        await storage.close()
    }

    /// F5: the migration must not refuse when the estate's actual audit-event
    /// or source-row count exceeds the CALLER-SUPPLIED `limits` floor — it
    /// widens `limits` to the estate's real counts before calling the
    /// worker. A fixture with literally 1,000,001 rows would be
    /// impractically slow for a unit test; passing an artificially tiny
    /// floor (`1` for every field) against a small real fixture (a handful
    /// of drawers, each with its own capture audit event) exercises the
    /// exact same widening code path deterministically and fast — the
    /// mechanism under test is "does `limits` get raised to cover the actual
    /// count", not the literal magnitude of the default.
    ///
    /// Before the fix this refused with `MatrixRecordError.workingSetLimit`
    /// on the very first audit-replay page, because the un-widened floor of
    /// 1 event/row is below the handful this fixture writes.
    @Test
    func fixtureOverTheRequestedFloorStillMigrates() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matrix-migration-oversize-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = try SQLiteStorage(configuration: EstateConfiguration(estateID: UUID(),
            backend: .sqlite(url: folder.appendingPathComponent("estate.sqlite"), busyTimeout: 5)))
        let estate = try await LocusKit.Estate.create(storage: storage, owner: .init(ownerIdentifier: "test"))
        let manifest = try await estate.manifest
        let id = try #require(UUID(uuidString: manifest.estateUUID))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let format = EstateFormatStore(storage: storage)
        try await format.stamp(.v1_9, now: now)

        // Real drawers (and their capture audit events) so the estate's
        // audit log and drawers table both carry more rows than the tiny
        // floor below.
        for i in 0..<6 {
            _ = try await estate.capture(CaptureFrame(
                content: "F5 fixture drawer \(i)", channel: .typed, room: "facts",
                latticeAnchor: LatticeAnchor(udcCode: "000"), addedBy: "f5-fixture",
                embeddingModelID: "test-v1", eventTime: now))
        }

        // A floor of 1 for every field is far below the 6 drawers (and
        // their matching audit events) actually on disk.
        let tinyFloor = MatrixRefreshLimits(auditEvents: 1, cells: 1, sourceRows: 1)
        try await MatrixRecordMigration.run(storage: storage, estateID: id, now: now, limits: tinyFloor)

        #expect(try await format.readIfPresent() == .v1_10,
            "the format must advance to v1.10 on a successful migration")
        await storage.close()
    }
}
#endif
