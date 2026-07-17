import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - DatasetHandleLifecycleTests

/// GLK-layer integration tests for the dataset handle lifecycle (MX-TAB-4).
///
/// Coverage:
///   - Erase cascade: `GeniusLocusKit.expunge` on a dataset handle drops the
///     backing dataset table (Step 2.5 of the §B-2a flow) and appends a
///     "datasetTableDrop" audit event.
///   - Tombstone semantics: the handle drawer is tombstoned as in any expunge;
///     the test verifies Step 2.5 runs without disturbing Step 3.
///
/// Withdraw semantics (resolveActiveDatasetHandle / withdrawnDatasetHandle) are
/// tested in LocusKit's `DatasetHandleTests.swift` because they live entirely
/// in the LocusKit layer. These tests focus on the GLK coordination path.
@Suite("DatasetHandleLifecycleTests")
struct DatasetHandleLifecycleTests {

    // MARK: - Fixture helpers

    /// Open a fresh GeniusLocusKit estate backed by an InMemoryStorage.
    ///
    /// Returns the kit, the handle, the storage, and the LocusKit estate
    /// so callers can call `captureDatasetHandle` and inspect the
    /// DatasetStore directly.
    private func openEstate() async throws -> (
        GeniusLocusKit,
        EstateHandle,
        InMemoryStorage,
        LocusKit.Estate
    ) {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let owner = OwnerCredentials(ownerIdentifier: "dataset-lifecycle-tests")
        // Initialise the LocusKit schema. The returned estate shares the same
        // InMemoryStorage as the kit, so rows captured via either are visible
        // to the other.
        let estate = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle, storage, estate)
    }

    // MARK: - Erase cascade: dataset table dropped on expunge

    @Test("GLK expunge on dataset handle drops the backing table")
    func expungeDropsDatasetTable() async throws {
        let (kit, handle, storage, estate) = try await openEstate()
        let datasetStore = storage.datasetStore

        // Create the dataset table in the DatasetStore.
        let datasetId = UUID()
        let schema = DatasetSchema(
            columns: [ColumnDeclaration(name: "val", type: .int)],
            primaryKeyColumn: nil
        )
        try await datasetStore.createDataset(id: datasetId, schema: schema, indexes: [])

        // Capture the dataset handle drawer via the shared LocusKit estate.
        let drawer = try await estate.captureDatasetHandle(
            datasetId:         datasetId,
            columns:           [DatasetColumnSummary(name: "val", dataType: "INTEGER")],
            rowCount:          0,
            sourceDescription: "erase-cascade test",
            room:              "test-room",
            addedBy:           "lifecycle-tests",
            sensitivity:       .normal,
            latticeAnchor:     LatticeAnchor(udcCode: "004")
        )

        // Verify the dataset table exists before expunge.
        let rowsBefore = try await datasetStore.queryRows(
            id: datasetId, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil
        )
        #expect(rowsBefore.isEmpty, "table exists but should be empty before expunge")

        // GLK expunge: Step 2.5 drops the dataset table; Step 3 seals the tombstone.
        try await kit.expunge(handle, ExpungeFrame(
            rowID: drawer.id, reason: "lifecycle-tests erase", confirmation: true
        ))

        // Verify the dataset table was dropped: queryRows must now throw.
        await #expect(throws: StorageError.self) {
            _ = try await datasetStore.queryRows(
                id: datasetId, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil
            )
        }
    }

    @Test("GLK expunge on dataset handle appends datasetTableDrop audit event")
    func expungeAppendsTableDropAudit() async throws {
        let (kit, handle, storage, estate) = try await openEstate()
        let datasetStore = storage.datasetStore

        // Create dataset + handle.
        let datasetId = UUID()
        let schema = DatasetSchema(
            columns: [ColumnDeclaration(name: "n", type: .int)],
            primaryKeyColumn: nil
        )
        try await datasetStore.createDataset(id: datasetId, schema: schema, indexes: [])

        let drawer = try await estate.captureDatasetHandle(
            datasetId:         datasetId,
            columns:           [DatasetColumnSummary(name: "n", dataType: "INTEGER")],
            rowCount:          0,
            sourceDescription: "audit-event test",
            room:              "audit-room",
            addedBy:           "lifecycle-tests",
            latticeAnchor:     LatticeAnchor(udcCode: "004")
        )

        try await kit.expunge(handle, ExpungeFrame(
            rowID: drawer.id, reason: "audit test", confirmation: true
        ))

        // The audit trail should contain a "datasetTableDrop" event for this row.
        // Use the shared estate to read the audit trail (both estates reference
        // the same InMemoryStorage so the audit log is the same underlying table).
        let auditRows = try await estate.auditTrail(rowID: drawer.id)
        let verbs = auditRows.map { $0.verb }
        #expect(
            verbs.contains("datasetTableDrop"),
            "expected 'datasetTableDrop' in audit trail; found verbs: \(verbs)"
        )
        // The tombstone event must also be present (Step 3 succeeded).
        #expect(
            verbs.contains("tombstone"),
            "expected 'tombstone' in audit trail; found verbs: \(verbs)"
        )
    }

    @Test("GLK expunge on non-dataset drawer skips dataset cascade cleanly")
    func expungeOnNonDatasetDrawerSkipsCascade() async throws {
        let (kit, handle, _, _) = try await openEstate()

        // Capture an ordinary drawer (no contentKind == .dataset).
        let frame = CaptureFrame(
            content: "ordinary drawer — no dataset",
            channel: .typed,
            room:    "test-room",
            latticeAnchor: .udc("004"),
            addedBy: "lifecycle-tests",
            embeddingModelID: "test-model-v1"
        )
        let stored = try await kit.capture(handle, frame)

        // Expunge should succeed normally; no dataset cascade fires.
        try await kit.expunge(handle, ExpungeFrame(
            rowID: stored.id, reason: "non-dataset expunge", confirmation: true
        ))

        // Verify the drawer is no longer in active recall (tombstone succeeded).
        let active = try await kit.recall(handle, RecallFrame(
            filterChain:    [.unconfirmed],
            hydrationLevel: .structured,
            ordering:       .byCaptureTimeDesc
        ))
        #expect(!active.contains { $0.id == stored.id },
                "expunged drawer should not appear in active recall")
    }

    @Test("GLK expunge on dataset handle with no backing table is a no-op for the drop")
    func expungeOnDatasetHandleWithMissingTableIsNoOp() async throws {
        let (kit, handle, _, estate) = try await openEstate()

        // Capture a dataset handle but do NOT create the backing table.
        // dropDataset uses DROP TABLE IF EXISTS semantics — a missing table
        // must not cause the expunge to fail.
        let datasetId = UUID()
        let drawer = try await estate.captureDatasetHandle(
            datasetId:         datasetId,
            columns:           [],
            rowCount:          0,
            sourceDescription: "no-table test",
            room:              "test-room",
            addedBy:           "lifecycle-tests",
            latticeAnchor:     LatticeAnchor(udcCode: "004")
        )

        // Expunge should succeed even with no backing dataset table.
        try await kit.expunge(handle, ExpungeFrame(
            rowID: drawer.id, reason: "no-table cascade", confirmation: true
        ))
    }
}
