import Foundation
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import LocusKit

struct FrozenEstateFingerprintTests {
    @Test("frozen open preserves persisted aggregates and prunes using current span bits")
    func frozenOpenUsesPrivateCurrentAggregates() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let owner = OwnerCredentials(ownerIdentifier: "frozen-test")
        let live = try await Estate.create(storage: storage, owner: owner)
        let drawer = try await live.capture(CaptureFrame(
            content: "current span candidate", channel: .typed, room: "room",
            latticeAnchor: LatticeAnchor(udcCode: "004"), addedBy: "test",
            embeddingModelID: "test", kind: .prose))
        let names = try await live.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        let wing = try #require(names[drawer.parentNodeId]?.wing)
        let store = try await DrawerStore(storage: storage)
        let persistent = try await ContainerFingerprintStore(storage: storage)
        let roomBefore = try await persistent.get(wing: wing, room: "room")
        let wingBefore = try await persistent.get(wing: wing, room: "")
        _ = try await store.setSpanIndexed(drawerId: drawer.id)
        let manifestBefore = try await store.readManifest()
        let memory = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let frozen = try await Estate.open(
            storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore(),
            federate: true, frozen: true, fingerprintStorage: memory)
        #expect(try await persistent.get(wing: wing, room: "room") == roomBefore)
        #expect(try await persistent.get(wing: wing, room: "") == wingBefore)
        #expect(try await store.readManifest().ed25519PublicKey == manifestBefore.ed25519PublicKey)
        let current = try #require(try await frozen.containerFP.get(wing: wing, room: "room"))
        #expect(current.operational & (1 << 27) != 0)
        let stale = try #require(roomBefore)
        #expect(!BitmapEvaluator.containerSurvives(chain: [.hasFeatureFlag(.spanIndexed)], fingerprint: stale))
        #expect(BitmapEvaluator.containerSurvives(chain: [.hasFeatureFlag(.spanIndexed)], fingerprint: current))
        let stream = await frozen.recall(RecallFrame(filterChain: [.currentlyBelieve], hydrationLevel: .full))
        var ids: [String] = []
        for await page in stream { ids.append(contentsOf: page.rows.map(\.id)) }
        #expect(ids.contains(drawer.id))
        #expect(try await persistent.get(wing: wing, room: "room") == roomBefore)
    }

    @Test("existing-schema admission rejects migrations and missing tables without repairing them")
    func existingSchemaAdmissionDoesNotRepair() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        _ = try await Estate.create(storage: storage, owner: OwnerCredentials(ownerIdentifier: "schema-test"))
        let schema = LocusKitSchema.schema
        try await storage.openExisting(schema: schema)
        let tooNew = SchemaDeclaration(kitID: schema.kitID, version: schema.version + 1, tables: schema.tables)
        await #expect(throws: (any Error).self) { try await storage.openExisting(schema: tooNew) }
        let missing = SchemaDeclaration(kitID: schema.kitID, version: schema.version, tables: [
            TableDeclaration(name: "frozen_must_not_create", columns: [ColumnDeclaration(name: "id", type: .text)], primaryKey: ["id"])
        ])
        await #expect(throws: (any Error).self) { try await storage.openExisting(schema: missing) }
        await #expect(throws: (any Error).self) { try await storage.openExisting(schema: missing) }
        #expect(try await storage.currentSchemaVersion(for: schema.kitID) == schema.version)
    }

}
