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
}
#endif
