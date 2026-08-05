#if GLK_MIGRATION_V1_0_TO_V1_1

// SharedContentMigrationTests.swift
//
// Resumable legacy-migration coverage (GLK shared-content 1.1, P4).
//
// Builds a REAL legacy estate shape in place — captured Drawers plus the
// pre-cutover copy lane (chunks + corpus_metadata + chunk-keyed vectors,
// with the legacy "CorpusKit" schema version recorded) — then proves:
// selective deletion (protected rows survive byte-identically), declared
// schema retirement, streamed Drawer-keyed rebuild, verification, orphan
// fail-dark, fault-injected resume equivalence, and the dark-lane gate.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import VectorKit
import EngramLib
import SubstrateTypes
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_0ToV1_1

@Suite("SharedContentMigration", .serialized)
struct SharedContentMigrationTests {

    @Test func trainingCapacityRefusesBeforeDestructiveBudget() throws {
        let required = SharedContentTrainingCapacity.requiredBytes(contentCount: 98_118)
        #expect(required > 24 * 1_024 * 1_024 * 1_024)
        #expect(throws: SharedContentMigrationError.self) {
            try SharedContentTrainingCapacity.require(
                contentCount: 98_118, budgetBytes: 24 * 1_024 * 1_024 * 1_024)
        }
        try SharedContentTrainingCapacity.require(
            contentCount: 2_000, budgetBytes: 4 * 1_024 * 1_024 * 1_024)
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratchStorage() throws -> (any Storage, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-scm-\(UUID().uuidString).sqlite3")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        return (storage, url)
    }

    @Test func estateFormatDistinguishesUnstampedFromRegisteredMissingRow() async throws {
        let (storage, url) = try scratchStorage()
        defer { try? FileManager.default.removeItem(at: url) }
        // Production calls the catalog after LocusKit has opened the estate,
        // so the per-kit schema registry exists even when the format does not.
        try await storage.migrate(to: SchemaDeclaration(
            kitID: "EstateFormatTestFixture", version: 1, tables: []))
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == nil)
        try await storage.migrate(to: EstateFormatStore.schemaDeclaration)
        await #expect(throws: EstateFormatError.self) {
            _ = try await EstateFormatStore(storage: storage).readIfPresent()
        }
    }

    @Test func belowCompiledFloorRefusesBeforeLegacyDeletion() async throws {
        let (kit, handle, storage, _, url) = try await makeLegacyEstate(
            drawerContents: ["below-floor estate remains untouched"])
        defer { try? FileManager.default.removeItem(at: url) }
        try await EstateFormatStore(storage: storage).stamp(
            EstateFormatVersion(major: 0, minor: 9), now: now)
        await #expect(throws: GLKMigrationCatalogError.self) {
            try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: now)
        }
        #expect(try await storage.rowStore.count(table: "chunks", where: nil) == 1)
    }

    /// Open a GLK estate (no engine registered — kit.open wires none),
    /// capture drawers, and overlay the LEGACY copy lane exactly as the
    /// pre-cutover engine produced it.
    private func makeLegacyEstate(
        drawerContents: [String],
        includeOrphanChunk: Bool = false,
        seedProtectedVector: Bool = true
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle,
                       storage: any Storage, drawerIDs: [String], url: URL) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scm-owner")
        let (storage, url) = try scratchStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        // In-memory identity key store: keep this file-backed estate's signing
        // key out of the Keychain (test-loop key-residue fix). File deletion does
        // not dispose Keychain items, so the default store would orphan one entry.
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

        var drawerIDs: [String] = []
        for content in drawerContents {
            let frame = CaptureFrame(
                content: content, channel: .typed, room: "scm",
                latticeAnchor: LatticeAnchor(udcCode: "004"),
                addedBy: "scm-test", embeddingModelID: "scm-v1")
            let drawer = try await kit.capture(handle, frame)
            drawerIDs.append(drawer.id)
        }

        // Overlay the legacy copy lane: BundleStore schema (registers the
        // legacy "CorpusKit" v3), one chunk row per drawer with VERBATIM
        // text, and one chunk-keyed vector row per chunk.
        try await storage.migrate(to: BundleStore.schemaDeclaration)
        try await storage.migrate(to: RemovedSourceStore.schemaDeclaration)
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        for (index, content) in drawerContents.enumerated() {
            let chunkID = Chunk.deriveID(
                sourceID: drawerIDs[index], startOffset: 0, text: content)
            _ = try await storage.rowStore.insert(table: "chunks", values: [
                "id": .uuid(chunkID),
                "source_id": .text(drawerIDs[index]),
                "start_offset": .int(0),
                "length": .int(Int64(content.count)),
                "text": .text(content),
                "hlc": .hlc(HLC(physicalTime: Int64(index + 1), logicalCount: 0, nodeID: 1)),
                "metadata": .json(Data("{}".utf8)),
                "created_at": .timestamp(now),
                "ext": .null
            ])
            _ = try await storage.rowStore.insert(table: "vectors", values: [
                "id": .uuid(UUID()),
                "item_id": .text(chunkID.uuidString),
                "vector_index": .int(0),
                "model_id": .text("corpus-deterministic-v1"),
                "model_version": .text("1.0.0"),
                "kind": .int(0),
                "dim": .int(256),
                "payload": .blob(Data(repeating: UInt8(index + 1), count: 32)),
                "scale": .null,
                "filed_at": .timestamp(now)
            ])
        }
        if includeOrphanChunk {
            let orphanID = Chunk.deriveID(
                sourceID: "ghost-drawer", startOffset: 0, text: "orphaned text")
            _ = try await storage.rowStore.insert(table: "chunks", values: [
                "id": .uuid(orphanID),
                "source_id": .text("ghost-drawer"),
                "start_offset": .int(0),
                "length": .int(13),
                "text": .text("orphaned text"),
                "hlc": .hlc(HLC(physicalTime: 99, logicalCount: 0, nodeID: 1)),
                "metadata": .json(Data("{}".utf8)),
                "created_at": .timestamp(now),
                "ext": .null
            ])
        }
        if seedProtectedVector {
            // An UNRELATED lane's representation, keyed by a Drawer ID under
            // a model the corpus never claims — must survive byte-identically.
            _ = try await storage.rowStore.insert(table: "vectors", values: [
                "id": .uuid(UUID()),
                "item_id": .text(drawerIDs[0]),
                "vector_index": .int(0),
                "model_id": .text("unrelated-lane-v1"),
                "model_version": .text("1.0.0"),
                "kind": .int(0),
                "dim": .int(256),
                "payload": .blob(Data(repeating: 0xEE, count: 32)),
                "scale": .null,
                "filed_at": .timestamp(now)
            ])
        }
        return (kit, handle, storage, drawerIDs, url)
    }

    private func protectedVectorPayload(_ storage: any Storage, itemID: String) async throws -> Data? {
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
                .eq(Column(table: "vectors", name: "model_id"), .text("unrelated-lane-v1"))
            ]),
            orderBy: [], limit: nil, offset: nil)
        guard let row = rows.first, case let .blob(data)? = row["payload"] else { return nil }
        return data
    }

    // MARK: - Fresh estates bypass

    @Test func freshEstateBypassesAndNeverCreatesLegacyTables() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scm-fresh")
        let (storage, url) = try scratchStorage()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        // In-memory identity key store: keep this file-backed estate's signing
        // key out of the Keychain (test-loop key-residue fix). File deletion does
        // not dispose Keychain items, so the default store would orphan one entry.
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

        let report = try await kit.runSharedContentMigration(handle: handle, now: now)
        #expect(report.state == .complete)
        #expect(report.legacyChunkCount == 0)
        // A current estate has no historical record. Installing the current
        // attached schema must not make the missing legacy chunks table look
        // like corruption on reopen.
        try await storage.migrate(to: CorpusSchemaProfile.attachedDeclaration)
        #expect(!(await kit.sharedContentLaneMustStayDark(storage: storage)))
        let reopened = try await kit.runSharedContentMigration(handle: handle, now: now)
        #expect(reopened.state == .complete)
        // Bypass creates no legacy tables.
        await #expect(throws: (any Error).self) {
            _ = try await storage.rowStore.count(table: "chunks", where: nil)
        }
    }

    // MARK: - Happy path

    @Test func legacyEstateMigratesSelectivelyAndVerifies() async throws {
        let contents = [
            "The migration must keep this drawer intact.",
            "A second drawer with distinct content for recall.",
            "Third drawer about physical page reclamation."
        ]
        let (kit, handle, storage, drawerIDs, url) =
            try await makeLegacyEstate(drawerContents: contents)
        defer { try? FileManager.default.removeItem(at: url) }

        let protectedBefore = try await protectedVectorPayload(storage, itemID: drawerIDs[0])
        #expect(protectedBefore != nil)

        let report = try await kit.runSharedContentMigration(handle: handle, now: now)
        #expect(report.state == .reclaimPending)
        #expect(report.legacyChunkCount == 3)
        #expect(report.legacyVectorKeyCount == 3)
        #expect(report.rebuiltContentCount == 3)

        // Copy-lane tables are GONE (declared dropTable retirement).
        await #expect(throws: (any Error).self) {
            _ = try await storage.rowStore.count(table: "chunks", where: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await storage.rowStore.count(table: "corpus_metadata", where: nil)
        }

        // No chunk-keyed vector survives; Drawer-keyed rows exist for every
        // drawer; the unrelated lane's row survived BYTE-IDENTICALLY.
        let vectorRows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        var itemIDs: Set<String> = []
        for row in vectorRows {
            if case let .text(item)? = row["item_id"] { itemIDs.insert(item) }
        }
        for id in drawerIDs { #expect(itemIDs.contains(id)) }
        #expect(try await protectedVectorPayload(storage, itemID: drawerIDs[0])
            == protectedBefore)

        // The rebuilt lane hydrates directly: BM25 hits ARE drawer IDs.
        let estateObj = try await kit.estate(for: handle)
        let engine = try await CorpusContentEngine(
            storage: storage,
            configuration: CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent),
            source: LocusDrawerCorpusContentSource(estate: estateObj))
        let hits = try await engine.bm25TopK(query: "page reclamation", limit: 5)
        #expect(hits.first?.id == drawerIDs[2])

        // Idempotent re-run: same terminal state, nothing re-deleted.
        let rerun = try await kit.runSharedContentMigration(handle: handle, now: now)
        #expect(rerun.state == .reclaimPending)

        // Reclaim completion runs the PHYSICAL reclamation (WAL checkpoint
        // + VACUUM): the retired legacy tables' pages must actually leave
        // the filesystem, and the status surface must report the outcome.
        let statusBefore = try await kit.sharedContentReclaimStatus(handle: handle)
        #expect(statusBefore.state == .reclaimPending)
        let maintenance = try #require(
            try await kit.completeSharedContentReclaim(handle: handle, now: now))
        #expect(maintenance.performed)
        #expect(maintenance.backend == "sqlite")
        #expect(maintenance.freelistPagesAfter == 0)
        #expect(maintenance.reclaimedBytes > 0)
        #expect(maintenance.fileSizeBytesAfter + maintenance.walBytesAfter
            < maintenance.fileSizeBytesBefore + maintenance.walBytesBefore)
        #expect(try await kit.sharedContentMigrationState(handle: handle) == .complete)
        let statusAfter = try await kit.sharedContentReclaimStatus(handle: handle)
        #expect(statusAfter.state == .complete)
        #expect(statusAfter.reclaimedBytes == maintenance.reclaimedBytes)

        // Recall still works over the vacuumed file: the reclamation freed
        // pages, never derived state.
        let postHits = try await engine.bm25TopK(query: "page reclamation", limit: 5)
        #expect(postHits.first?.id == drawerIDs[2])
    }

    @Test func mxTabularBackingTableAndHandleSurviveMigrationReclaimAndReopen() async throws {
        let (kit, handle, storage, _, url) = try await makeLegacyEstate(
            drawerContents: ["ordinary drawer beside a protected dataset"])
        defer { try? FileManager.default.removeItem(at: url) }

        let datasetID = UUID()
        let tableName = datasetTableName(datasetID)
        let datasetStore = try storage.datasetStore
        let columns = [
            ColumnDeclaration(name: "id", type: .int, nullable: false),
            ColumnDeclaration(name: "label", type: .text, nullable: false),
            ColumnDeclaration(name: "score", type: .float, nullable: true),
            ColumnDeclaration(name: "note", type: .text, nullable: true),
        ]
        try await datasetStore.createDataset(
            id: datasetID,
            schema: DatasetSchema(columns: columns, primaryKeyColumn: "id"),
            indexes: [DatasetIndexDeclaration(column: "label")])
        try await datasetStore.appendRows(id: datasetID, rows: [
            ["id": .int(2), "label": .text("beta"), "score": .float(2.5), "note": .null],
            ["id": .int(1), "label": .text("alpha"), "score": .float(1.25), "note": .text("kept")],
        ])
        let estate = try await kit.estate(for: handle)
        let summaries = [
            DatasetColumnSummary(name: "id", dataType: "INTEGER"),
            DatasetColumnSummary(name: "label", dataType: "TEXT"),
            DatasetColumnSummary(name: "score", dataType: "REAL"),
            DatasetColumnSummary(name: "note", dataType: "TEXT"),
        ]
        let datasetDrawer = try await estate.captureDatasetHandle(
            datasetId: datasetID, columns: summaries, rowCount: 2,
            sourceDescription: "migration preservation fixture", room: "datasets",
            addedBy: "SharedContentMigrationTests",
            latticeAnchor: LatticeAnchor(udcCode: "004"))
        let order = [OrderClause(
            column: Column(table: "", name: "id"), direction: .ascending)]
        let rowsBefore = try await datasetStore.queryRows(
            id: datasetID, predicate: nil, orderBy: order,
            limit: nil, offset: nil, columns: nil)
        func rowSnapshot(_ rows: [StorageRow]) -> [String] {
            rows.map { DatabaseInventory.canonicalRowEncoding($0) }
        }
        var statsBefore: [String: ColumnStats] = [:]
        for column in summaries {
            statsBefore[column.name] = try await datasetStore.columnStats(
                id: datasetID, column: column.name)
        }
        let signedDrawer = try await kit.computeDatasetSignatures(
            handle: handle, drawerId: datasetDrawer.id,
            columns: summaries, columnStats: statsBefore,
            sampledRows: rowsBefore, now: now)
        let handleJSONBefore = signedDrawer.content

        func schemaRows(_ target: any Storage) async throws -> [StorageRow] {
            try await target.rowStore.query(
                table: "sqlite_master",
                where: .and([
                    .in(Column(table: "sqlite_master", name: "type"), [.text("table"), .text("index")]),
                    .or([
                        .eq(Column(table: "sqlite_master", name: "name"), .text(tableName)),
                        .eq(
                            Column(table: "sqlite_master", name: "name"),
                            .text(datasetIndexName(datasetID, column: "label")))
                    ])
                ]),
                orderBy: [OrderClause(
                    column: Column(table: "sqlite_master", name: "name"),
                    direction: .ascending)],
                limit: nil, offset: nil, columns: ["type", "name", "sql"])
        }
        let ddlBefore = try await schemaRows(storage)
        #expect(ddlBefore.count == 2)

        _ = try await kit.runSharedContentMigration(handle: handle, now: now)
        _ = try await kit.completeSharedContentReclaim(handle: handle, now: now)

        // Dataset handles are explicitly excluded from CorpusKit: their JSON
        // is compact schema/provenance metadata, not agentic text to vectorize.
        let datasetVectors = try await storage.rowStore.query(
            table: "vectors",
            where: .eq(
                Column(table: "vectors", name: "item_id"), .text(datasetDrawer.id)),
            orderBy: [], limit: nil, offset: nil)
        #expect(datasetVectors.isEmpty)

        let configuration = storage.configuration
        try await kit.close(handle)
        await storage.close()
        let reopened = try SQLiteStorage(configuration: configuration)
        let reopenedDataset = reopened.datasetStore
        let rowsAfter = try await reopenedDataset.queryRows(
            id: datasetID, predicate: nil, orderBy: order,
            limit: nil, offset: nil, columns: nil)
        #expect(rowSnapshot(rowsAfter) == rowSnapshot(rowsBefore))
        for column in summaries {
            #expect(try await reopenedDataset.columnStats(
                id: datasetID, column: column.name) == statsBefore[column.name])
        }
        #expect(rowSnapshot(try await schemaRows(reopened)) == rowSnapshot(ddlBefore))
        let handleRows = try await reopened.rowStore.query(
            table: "drawers",
            where: .eq(
                Column(table: "drawers", name: "id"), .text(datasetDrawer.id)),
            orderBy: [], limit: 1, offset: nil)
        #expect(handleRows.count == 1)
        #expect(handleRows.first?["content"] == .text(handleJSONBefore))
        let decoded = try DatasetHandleContent.decode(from: handleJSONBefore)
        #expect(decoded.tableSignature != nil)
        #expect(decoded.columnSignatures?.count == summaries.count)
        await reopened.close()
    }

    @Test func reclaimCompactsLargeInventoryBeforeVacuum() async throws {
        let (kit, handle, storage, _, url) = try await makeLegacyEstate(
            drawerContents: ["inventory compaction fixture"])
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await kit.runSharedContentMigration(handle: handle, now: now)

        // Model the large qualification record without making the fast suite
        // carry the full million-row inventory.
        let store = SharedContentMigrationStore(storage: storage)
        var record = try #require(try await store.load())
        let padding = String(repeating: "x", count: 120)
        record.legacyChunkIDs = (0..<25_000).map {
            String(format: "chunk-%08d-%@", $0, padding)
        }
        record.legacyVectorKeys = (0..<25_000).map {
            String(format: "vector-%08d-%@", $0, padding)
        }
        try await store.save(record, now: now)

        let report = try #require(
            try await kit.completeSharedContentReclaim(handle: handle, now: now))
        #expect(report.freelistPagesAfter == 0)
        let completed = try #require(try await store.load())
        #expect(completed.legacyChunkCount == 25_000)
        #expect(completed.legacyVectorKeyCount == 25_000)
        #expect(completed.legacyChunkIDs.isEmpty)
        #expect(completed.legacyVectorKeys.isEmpty)

        // The post-maintenance completion save must not recreate the removed
        // inventory as freelist. This fails when compaction occurs after the
        // VACUUM even though the maintenance report itself said zero.
        let maintenance = try #require(storage as? any StorageMaintenance)
        let remainingReclaimableBytes = try await maintenance.estimatedReclaimableBytes()
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let walBytes = (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        #expect(remainingReclaimableBytes == walBytes,
                "post-completion reclaimable bytes must be WAL only, never freelist pages")
    }

    // MARK: - Ensemble upgrade (add a provider to a migrated estate)

    @Test func ensembleUpgradeCoversAddedProviderAndStaysDarkUntilThen() async throws {
        let contents = [
            "Upgrade fixture drawer one about estates.",
            "Upgrade fixture drawer two about coverage."
        ]
        let (kit, handle, storage, drawerIDs, url) =
            try await makeLegacyEstate(drawerContents: contents)
        defer { try? FileManager.default.removeItem(at: url) }

        // Migrate under a ONE-provider configuration and finish reclaim.
        let small: [EmbeddingModel] = [.deterministic]
        let first = try await kit.runSharedContentMigration(
            handle: handle, now: now, embeddingModels: small)
        #expect(first.state == .reclaimPending)
        _ = try await kit.completeSharedContentReclaim(handle: handle, now: now)
        let smallFP = CorpusContentEngine.configurationFingerprint(
            mode: .attached, models: small)
        #expect(!(await kit.sharedContentLaneMustStayDark(
            storage: storage, wiredFingerprint: smallFP)))

        // Wire a LARGER ensemble: the completed record is NOT trusted —
        // the lane goes dark and the estate enters a follow-on upgrade.
        let big: [EmbeddingModel] = [
            .deterministic,
            .randomIndexing(provider: RandomIndexingProvider())
        ]
        let bigFP = CorpusContentEngine.configurationFingerprint(
            mode: .attached, models: big)
        #expect(await kit.sharedContentLaneMustStayDark(
            storage: storage, wiredFingerprint: bigFP))

        // The upgrade trains the ADDED provider, backfills ONLY its missing
        // coverage, re-verifies, and restamps the fingerprint.
        let upgraded = try await kit.runSharedContentMigration(
            handle: handle, now: now, embeddingModels: big)
        #expect(upgraded.state == .reclaimPending)
        _ = try await kit.completeSharedContentReclaim(handle: handle, now: now)
        #expect(!(await kit.sharedContentLaneMustStayDark(
            storage: storage, wiredFingerprint: bigFP)))

        // Every provider covers every drawer, and BM25 still serves.
        let estateObj = try await kit.estate(for: handle)
        let engine = try await CorpusContentEngine(
            storage: storage,
            configuration: CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent),
            source: LocusDrawerCorpusContentSource(estate: estateObj),
            models: big)
        #expect(try await engine.coveredCount(modelID: "corpus-deterministic-v1")
            == drawerIDs.count)
        #expect(try await engine.coveredCount(modelID: "random-indexing-v1")
            == drawerIDs.count)
        let hits = try await engine.bm25TopK(query: "coverage", limit: 5)
        #expect(hits.first?.id == drawerIDs[1])
    }

    // MARK: - Orphan fail-dark

    @Test func orphanedLegacySourceStopsDarkBeforeAnyDeletion() async throws {
        let (kit, handle, storage, _, url) = try await makeLegacyEstate(
            drawerContents: ["Content with a valid drawer."],
            includeOrphanChunk: true)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: SharedContentMigrationError.self) {
            try await kit.runSharedContentMigration(handle: handle, now: now)
        }
        // NOTHING was dropped — the copy lane is intact for diagnosis.
        #expect(try await storage.rowStore.count(table: "chunks", where: nil) == 2)
        // And the lane stays dark.
        #expect(await kit.sharedContentLaneMustStayDark(storage: storage))
    }

    // MARK: - Fault-injected resume equivalence

    @Test func faultAfterEveryStateResumesToTheSameOutcome() async throws {
        let contents = ["Resume drawer one.", "Resume drawer two."]

        // Uninterrupted reference run.
        let (kitRef, handleRef, storageRef, _, urlRef) =
            try await makeLegacyEstate(drawerContents: contents)
        defer { try? FileManager.default.removeItem(at: urlRef) }
        let reference = try await kitRef.runSharedContentMigration(handle: handleRef, now: now)
        let referenceInventory = try await DatabaseInventory.capture(
            storage: storageRef, tables: ["vectors", "corpus_index_state"],
            excludingColumns: ["vectors": ["id"]])

        let faultStates: [SharedContentMigrationState] = [
            .discovered, .canonicalValidated, .legacyInventoryCaptured,
            .legacyDerivedCleared, .legacySchemaRetired, .drawerIndexRebuilt,
            .verified
        ]
        for fault in faultStates {
            let (kit, handle, storage, _, url) =
                try await makeLegacyEstate(drawerContents: contents)
            defer { try? FileManager.default.removeItem(at: url) }

            await kit._setSharedContentFault(fault)
            await #expect(throws: SharedContentMigrationError.self) {
                try await kit.runSharedContentMigration(handle: handle, now: now)
            }
            // Resume: the rerun continues from the persisted state and
            // reaches the SAME outcome as the uninterrupted run.
            let resumed = try await kit.runSharedContentMigration(handle: handle, now: now)
            #expect(resumed.state == reference.state,
                    "fault after \(fault.rawValue) must resume to the reference state")
            #expect(resumed.legacyChunkCount == reference.legacyChunkCount)
            #expect(resumed.rebuiltContentCount == reference.rebuiltContentCount)
            let inventory = try await DatabaseInventory.capture(
                storage: storage, tables: ["vectors", "corpus_index_state"],
                excludingColumns: ["vectors": ["id"]])
            // Logical derived bytes match the uninterrupted run (surrogate
            // vector ids and drawer UUIDs differ per estate, so compare
            // counts, not folds, across DIFFERENT estates; folds prove
            // intra-estate stability elsewhere).
            #expect(inventory.map(\.rowCount) == referenceInventory.map(\.rowCount),
                    "fault after \(fault.rawValue): row populations must match the uninterrupted run")
        }
    }

    // MARK: - Dark-lane gate

    @Test func legacyEstateKeepsCorpusLaneDarkUntilMigrated() async throws {
        let (kit, handle, storage, _, url) = try await makeLegacyEstate(
            drawerContents: ["Dark lane drawer."])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await kit.sharedContentLaneMustStayDark(storage: storage))
        _ = try await kit.runSharedContentMigration(handle: handle, now: now)
        #expect(!(await kit.sharedContentLaneMustStayDark(storage: storage)))
        _ = handle
    }

    // MARK: - Circuit-breaker

    /// An orphan chunk causes `canonicalValidated` to fail with
    /// `orphanedLegacySources` on every call (the state is never advanced
    /// because the error fires BEFORE `record.state = .canonicalValidated` is
    /// saved). After `sharedContentCircuitBreakerThreshold` (= 3) identical
    /// failures the circuit breaker parks the migration, and the 4th call
    /// returns `migrationParked` instead of repeating the same work.
    @Test func circuitBreakerParksAfterThreeIdenticalFailures() async throws {
        let (kit, handle, _, _, url) = try await makeLegacyEstate(
            drawerContents: ["cb-park fixture"], includeOrphanChunk: true)
        defer { try? FileManager.default.removeItem(at: url) }

        // Calls 1–2: each must fail with orphanedLegacySources; not yet parked.
        for i in 0..<2 {
            await #expect(
                throws: SharedContentMigrationError.self,
                "call \(i + 1) must fail with orphanedLegacySources"
            ) {
                try await kit.runSharedContentMigration(handle: handle, now: now)
            }
            let isParked = await kit.sharedContentMigrationIsParked(handle: handle)
            #expect(!isParked, "not yet parked after only \(i + 1) failure(s)")
        }

        // Call 3: threshold reached — circuit breaker parks after this failure.
        await #expect(throws: SharedContentMigrationError.self) {
            try await kit.runSharedContentMigration(handle: handle, now: now)
        }
        #expect(
            await kit.sharedContentMigrationIsParked(handle: handle),
            "migration must be parked after 3 identical failures"
        )

        // Call 4: the park guard fires immediately, returning migrationParked.
        do {
            _ = try await kit.runSharedContentMigration(handle: handle, now: now)
            Issue.record("expected migrationParked on the 4th call but no error was thrown")
        } catch SharedContentMigrationError.migrationParked {
            // Expected: the parked guard returned before running any state-machine
            // step, so moot-mgr can detect this case and idle the respawn loop.
        } catch {
            Issue.record("expected migrationParked on 4th call, got \(error)")
        }
    }

    /// After an explicit `clearParkedSharedContentMigration`, the circuit-breaker
    /// failure count resets. A single subsequent failure does NOT re-park —
    /// only another CIRCUIT_BREAKER_THRESHOLD identical failures would.
    @Test func circuitBreakerExplicitClearResetsFailureCount() async throws {
        let (kit, handle, _, _, url) = try await makeLegacyEstate(
            drawerContents: ["cb-clear fixture"], includeOrphanChunk: true)
        defer { try? FileManager.default.removeItem(at: url) }

        // Drive to a parked state (3 identical failures).
        for _ in 0..<3 {
            _ = try? await kit.runSharedContentMigration(handle: handle, now: now)
        }
        #expect(await kit.sharedContentMigrationIsParked(handle: handle))

        // Explicit clear resets the circuit breaker.
        try await kit.clearParkedSharedContentMigration(handle: handle, now: now)
        #expect(
            !(await kit.sharedContentMigrationIsParked(handle: handle)),
            "migration must not be parked after explicit clear"
        )

        // One failure after clear: failure count = 1, below the threshold.
        _ = try? await kit.runSharedContentMigration(handle: handle, now: now)
        #expect(
            !(await kit.sharedContentMigrationIsParked(handle: handle)),
            "single failure after clear must not re-park (threshold is 3)"
        )
    }

    /// A park recorded by an EARLIER build auto-clears on the next run, so a
    /// binary carrying the fix gets a fresh attempt with no operator action.
    ///
    /// This is the guarantee `sharedContentMigrationVersion` exists to provide,
    /// and it had no test. beta-08 shipped the ee#49 repair without bumping the
    /// token, so every estate parked by the beta-07 failure stayed parked on the
    /// fixed binary and had to be unparked by hand with SQL — the fix was
    /// withheld from exactly the estates it was written for. This test fails if
    /// the auto-clear comparison is removed or inverted; it does NOT (and
    /// cannot) verify that a future author remembers to bump the constant, so
    /// the file-level doc comment on `sharedContentMigrationVersion` carries
    /// that instruction.
    @Test func circuitBreakerParkFromAnEarlierBuildAutoClears() async throws {
        let (kit, handle, _, _, url) = try await makeLegacyEstate(
            drawerContents: ["cb-version fixture"], includeOrphanChunk: true)
        defer { try? FileManager.default.removeItem(at: url) }

        // Drive to a parked state under the CURRENT token.
        for _ in 0..<3 {
            _ = try? await kit.runSharedContentMigration(handle: handle, now: now)
        }
        #expect(await kit.sharedContentMigrationIsParked(handle: handle))

        // Rewrite the stored token to simulate a park left behind by an older
        // build — exactly the on-disk state of a beta-07-parked estate opened
        // by a later binary.
        let storage = try await kit.migrationStorage(for: handle)
        let store = SharedContentMigrationStore(storage: storage)
        var record = try #require(await store.load())
        record.circuitBreaker?.parkedUnderMigrationVersion = "some-earlier-build"
        try await store.save(record, now: now)

        // The park no longer applies: the new build owns a fresh attempt.
        #expect(
            !(await kit.sharedContentMigrationIsParked(handle: handle)),
            "a park recorded under an earlier token must not gate the current build"
        )

        // And the next run must actually ATTEMPT the migration rather than
        // short-circuiting on the parked guard. This fixture still fails (the
        // orphan chunk is unresolved), which is the proof it ran: a parked
        // guard returns .migrationParked without touching the state machine.
        do {
            _ = try await kit.runSharedContentMigration(handle: handle, now: now)
            Issue.record("fixture is expected to fail on orphanedLegacySources")
        } catch SharedContentMigrationError.migrationParked {
            Issue.record("auto-clear failed: the parked guard fired under a stale token")
        } catch {
            // Expected: a real migration attempt that failed on its own merits.
        }
    }
}

#endif
