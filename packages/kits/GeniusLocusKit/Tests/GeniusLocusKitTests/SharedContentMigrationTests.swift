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

@testable import GeniusLocusKit

@Suite("SharedContentMigration", .serialized)
struct SharedContentMigrationTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratchStorage() throws -> (any Storage, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-scm-\(UUID().uuidString).sqlite3")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        return (storage, url)
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
        let handle = try await kit.open(storage: storage, owner: owner)

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
        let handle = try await kit.open(storage: storage, owner: owner)

        let report = try await kit.runSharedContentMigration(handle: handle, now: now)
        #expect(report.state == .complete)
        #expect(report.legacyChunkCount == 0)
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
}
