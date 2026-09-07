#if GLK_MIGRATION_V1_6_TO_V1_7

// WholeRecordFloatVacuumMigrationTests.swift
//
// Verifies that GLKMigrationCatalog.prepare runs the 1.6→1.7 capsule, which
// vacuums the whole-record float rows (vectors kind 1) and the hnsw_graph
// rows from a populated estate, rebuilds the binary sidecar, releases the
// CorpusKit claim on vector_index 1 and stamps the estate format v1_7.
//
// Fixture: an estate stamped v1_6 whose vectors table carries binary rows
// (kind 0), whole-record float rows (kind 1) and Arctic span rows (kind 2),
// one hnsw_graph row, and the CorpusKit representation claims on lanes 0
// and 1.
//
// Tests:
//   1. After prepare: kind 1 and the graph rows are gone, the kind 0 and
//      kind 2 counts are unchanged, the lane-1 claim is released and the
//      lane-0 claim kept, the estate is stamped v1_7, and the binary lane
//      returns the same ordered ids as before.
//   2. The capsule's report carries the counts; a second run deletes
//      nothing, releases nothing and leaves the stamp at v1_7.
//   3. The format value is pinned: current is v1_7.
//   4. Fresh estate (nil stamp): prepare stamps v1_7 without running the
//      capsule.
//   5. On a SQLite estate the `.vec` sidecar is rewritten by the capsule and
//      a fresh store loads it without a rebuild.
//   6. v1_5-stamped estate: the chain runs the 1.5→1.6 capsule and then this
//      one, ending at v1_7 (gated on the 1.5→1.6 capsule being compiled).
//   7. Under WholeRecordDense an estate whose manifest names a whole-record
//      provider keeps its rows and is still stamped v1_7; the span encoder
//      value vacuums like the default ensemble.

import CorpusKit
import EngramLib
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import SynapseKit
import Testing
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_6ToV1_7

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig17")
private let testNow = Date(timeIntervalSince1970: 1_756_000_000)
private let model = "corpus-deterministic-v1"
private let version = "1.0.0"
private let probe = Engram(blocks: 0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F,
                           0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F)

private func binaryPayload(_ fill: UInt8) -> VectorPayload {
    VectorPayload(kind: .binary, dim: 256, bytes: [UInt8](repeating: fill, count: 32))
}

private func span(_ index: UInt32, _ int8: [Int8]) -> SpanVectorInput {
    SpanVectorInput(index: index, int8: int8, scale: 1, startWord: 0, endWord: 3, contentVersion: "cv")
}

/// Write the fixture rows through the store's own writers: two binary rows
/// (kind 0, lane 0), two float rows (kind 1, lane 1), two span rows (kind 2)
/// under the Arctic model id, one raw hnsw_graph row, and the CorpusKit
/// claims on lanes 0 and 1.
private func seedRows(_ storage: any Storage) async throws {
    try await storage.migrate(to: VectorStore.schemaDeclaration)
    try await storage.migrate(to: VectorRepresentationClaims.schemaDeclaration)
    let store = VectorStore(storage: storage)
    try await store.addPayload(itemID: "i1", vectorIndex: 0, payload: binaryPayload(0x0F),
                               modelID: model, modelVersion: version, filedAt: testNow)
    try await store.addPayload(itemID: "i2", vectorIndex: 0, payload: binaryPayload(0xF0),
                               modelID: model, modelVersion: version, filedAt: testNow)
    try await store.addPayload(itemID: "i1", vectorIndex: 1, payload: VectorPayload(floats: [1, 0]),
                               modelID: model, modelVersion: version, filedAt: testNow)
    try await store.addPayload(itemID: "i2", vectorIndex: 1, payload: VectorPayload(floats: [0, 1]),
                               modelID: model, modelVersion: version, filedAt: testNow)
    try await store.writeSpanVectors(itemID: "i1", modelID: "arctic-embed-s-w60", modelVersion: "1",
                                     spans: [span(0, [1, 2]), span(1, [3, 4])], filedAt: testNow)
    try await store.flush()
    _ = try await storage.rowStore.insert(table: "hnsw_graph", values: [
        "model_id": .text(model), "node_idx": .int(0), "node_id": .text("i1"),
        "layer": .int(0), "neighbours": .blob(Data([1, 0, 0, 0])), "generation": .int(0),
    ])
    let claims = VectorRepresentationClaims(storage: storage)
    for lane in [0, 1] {
        try await claims.registerClaim(
            consumer: CorpusContentEngine.claimsConsumer,
            key: VectorRepresentationKey(modelID: model, modelVersion: version, vectorIndex: lane),
            now: testNow)
    }
}

private func kindCount(_ storage: any Storage, _ kind: Int64) async throws -> Int {
    try await storage.rowStore.count(
        table: "vectors", where: .eq(Column(table: "vectors", name: "kind"), .int(kind)))
}

private func graphCount(_ storage: any Storage) async throws -> Int {
    try await storage.rowStore.count(table: "hnsw_graph", where: nil)
}

private func claimLanes(_ storage: any Storage) async throws -> [Int] {
    try await VectorRepresentationClaims(storage: storage)
        .claims(consumer: CorpusContentEngine.claimsConsumer)
        .map(\.vectorIndex)
}

private func orderedIDs(_ storage: any Storage, sidecarURL: URL? = nil) async throws -> [String] {
    let store = VectorStore(storage: storage, sidecarURL: sidecarURL)
    return try await store.findNearest(probe: probe, modelID: model, limit: 10).map(\.itemID)
}

/// An estate on `storage` stamped at `stamp` (or unstamped when nil) carrying
/// the fixture rows.
private func makeEstate(
    storage: any Storage,
    stampedAt stamp: EstateFormatVersion?
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
    _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
    try await seedRows(storage)
    if let stamp {
        try await EstateFormatStore(storage: storage).stamp(stamp, now: testNow)
    }
    let kit = GeniusLocusKit()
    let handle = try await kit.open(
        storage: storage, owner: testOwner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    return (kit, handle)
}

private func inMemory() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
}

@Suite("WholeRecordFloatVacuumMigration", .serialized)
struct WholeRecordFloatVacuumMigrationTests {

    // MARK: §1 The float and graph rows go, the binary and span rows stay, v1_7 stamped

    @Test
    func v1_6EstateLosesFloatAndGraphRowsAndKeepsTheRest() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_6)
        #expect(try await kindCount(storage, 0) == 2)
        #expect(try await kindCount(storage, 1) == 2)
        #expect(try await kindCount(storage, 2) == 2)
        #expect(try await graphCount(storage) == 1)
        #expect(try await claimLanes(storage) == [0, 1])
        let before = try await orderedIDs(storage)
        #expect(before == ["i1", "i2"])

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_7)
        #expect(prep.format == .current)
        #expect(prep.migrated == false)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_7)
        #expect(try await kindCount(storage, 0) == 2)
        #expect(try await kindCount(storage, 1) == 0)
        #expect(try await kindCount(storage, 2) == 2)
        #expect(try await graphCount(storage) == 0)
        #expect(try await claimLanes(storage) == [0])
        #expect(try await orderedIDs(storage) == before)
    }

    // MARK: §2 The report carries the counts; a second run is a no-op

    @Test
    func reportCarriesTheCountsAndASecondRunIsANoOp() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_6)
        let first = try await kit.runWholeRecordFloatVacuumMigration(handle: handle, now: testNow)
        #expect(first == WholeRecordFloatVacuumMigrationReport(
            floatRows: 2, graphRows: 1, claimsReleased: 1, vacuumed: true, format: .v1_7))
        let second = try await kit.runWholeRecordFloatVacuumMigration(handle: handle, now: testNow)
        #expect(second == WholeRecordFloatVacuumMigrationReport(
            floatRows: 0, graphRows: 0, claimsReleased: 0, vacuumed: true, format: .v1_7))
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_7)
        #expect(prep.migrated == false)
        #expect(try await kindCount(storage, 0) == 2)
        #expect(try await kindCount(storage, 2) == 2)
        #expect(try await claimLanes(storage) == [0])
    }

    // MARK: §3 The format value is pinned

    @Test
    func currentFormatIsV1_7() {
        #expect(EstateFormatVersion.current == .v1_7)
        #expect(EstateFormatVersion.v1_7 == EstateFormatVersion(major: 1, minor: 7))
        #expect(EstateFormatVersion.v1_6 < EstateFormatVersion.v1_7)
    }

    // MARK: §4 Fresh estate (nil stamp)

    @Test
    func freshEstateStampsCurrentWithoutRunningTheCapsule() async throws {
        let storage = inMemory()
        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage, owner: testOwner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_7)
        #expect(prep.migrated == false)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_7)
        // The capsule never ran: no SynapseKit ledger row was created by it.
        #expect(try await storage.currentSchemaVersion(for: VectorStore.kitID) == 0)
    }

    // MARK: §5 SQLite: the sidecar is rewritten and a fresh store loads it as current

    @Test
    func sqliteEstateSidecarIsRebuiltAndLoadsWithoutARebuild() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-mig17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("estate.sqlite")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_6)
        let before = try await orderedIDs(storage)
        let sidecar = try #require(VectorStore.defaultSidecarURL(for: storage))

        let report = try await kit.runWholeRecordFloatVacuumMigration(handle: handle, now: testNow)
        #expect(report.floatRows == 2 && report.graphRows == 1 && report.claimsReleased == 1)
        #expect(FileManager.default.fileExists(atPath: sidecar.path), "the capsule rewrites the binary sidecar")

        // A fresh store over the vacuumed table finds the sidecar current: no
        // stale-sidecar rebuild, and the binary lane serves the same order.
        let fresh = VectorStore(storage: storage, sidecarURL: sidecar)
        let after = try await fresh.findNearest(probe: probe, modelID: model, limit: 10).map(\.itemID)
        #expect(after == before)
        #expect(await fresh.sidecarRebuildCount == 0, "the sidecar the capsule wrote is current")
        #expect(try await kindCount(storage, 1) == 0)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_7)
        try await kit.close(handle)
        await storage.close()
    }

    // MARK: §6 Chain from v1_5 ends at v1_7

    #if GLK_MIGRATION_V1_5_TO_V1_6
    @Test
    func v1_5EstateRunsBothCapsulesToCurrent() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_5)
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_7)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_7)
        #expect(try await kindCount(storage, 1) == 0)
        #expect(try await graphCount(storage) == 0)
        #expect(try await kindCount(storage, 0) == 2)
        #expect(try await kindCount(storage, 2) == 2)
    }
    #endif

    // MARK: §7 The audition build keeps a whole-record provider's rows

    #if MOOTX01_WHOLE_RECORD_DENSE
    @Test
    func wholeRecordProviderInTheManifestKeepsTheRows() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_6)
        try await kit.provisionEmbeddingProvider("apple-nl-v1", for: handle)
        let report = try await kit.runWholeRecordFloatVacuumMigration(handle: handle, now: testNow)
        #expect(report == WholeRecordFloatVacuumMigrationReport(
            floatRows: 0, graphRows: 0, claimsReleased: 0, vacuumed: false, format: .v1_7))
        #expect(try await kindCount(storage, 1) == 2)
        #expect(try await graphCount(storage) == 1)
        #expect(try await claimLanes(storage) == [0, 1])
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_7)
    }

    @Test
    func spanEncoderInTheManifestStillVacuums() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_6)
        try await kit.provisionEmbeddingProvider(GeniusLocusKit.encoderProviderID, for: handle)
        let report = try await kit.runWholeRecordFloatVacuumMigration(handle: handle, now: testNow)
        #expect(report.vacuumed)
        #expect(try await kindCount(storage, 1) == 0)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_7)
    }
    #endif
}

#endif // GLK_MIGRATION_V1_6_TO_V1_7
