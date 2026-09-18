import Foundation
import PersistenceKit
import Testing
@testable import LocusKit

@Suite("FactExtractorModelStore")
struct FactExtractorModelStoreTests {
    private func row(_ recipeID: String, modelVersion: String = "r1") -> FactExtractorModelRow {
        FactExtractorModelRow(
            recipeID: recipeID, providerID: "test-provider", modelID: "test-model",
            modelVersion: modelVersion, schemaVersion: "kgfact-extraction-v1",
            extractorKind: "closure", maximumInputCharacters: 16_384,
            maximumFactsPerSource: 16)
    }

    @Test("upsert, activate, and read one active recipe")
    func upsertActivateReadBack() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        _ = try await DrawerStore(storage: storage)
        let registry = FactExtractorModelStore(storage: storage)

        #expect(try await registry.active() == nil)
        try await registry.upsert(row("apple-system-v1"))
        try await registry.upsert(row("nuextract-b1-q8-v1"))
        #expect(try await registry.active() == nil, "upsert never activates implicitly")

        _ = try await registry.activate(recipeID: "apple-system-v1")
        #expect(try await registry.active()?.recipeID == "apple-system-v1")
        _ = try await registry.activate(recipeID: "nuextract-b1-q8-v1")
        #expect(try await registry.all().filter(\.isActive).map(\.recipeID) == ["nuextract-b1-q8-v1"])

        try await registry.upsert(FactExtractorModelRow(
            recipeID: "nuextract-b1-q8-v1", providerID: "test-provider", modelID: "test-model",
            modelVersion: "r2", schemaVersion: "kgfact-extraction-v1", extractorKind: "closure",
            maximumInputCharacters: 32_768, maximumFactsPerSource: 24, isActive: true))
        #expect(try await registry.active()?.modelVersion == "r2")

        await #expect(throws: LocusKitError.self) {
            try await registry.activate(recipeID: "missing")
        }
        await #expect(throws: LocusKitError.self) {
            try await registry.upsert(row(""))
        }
    }

    @Test("activation and content writes maintain bit-28 extraction debt")
    func activationAndContentWriteMaintainDebt() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)
        let registry = FactExtractorModelStore(storage: storage)
        try await registry.upsert(row("apple-system-v1"))
        try await registry.upsert(row("nuextract-b1-q8-v1"))

        let ids = [TestStorage.tid("fact-a"), TestStorage.tid("fact-b")]
        for id in ids { try await store.addDrawer(sampleDrawer(id: id)) }
        #expect(try await store.countFactExtractionDebt() == 2)

        // A valid zero-fact extraction is settled by the bit, not a KGFact row.
        _ = try await store.setFactsExtracted(drawerId: ids[0])
        #expect(try await store.countFactExtractionDebt() == 1)
        #expect(try await store.getDrawer(id: ids[0])?.areFactsExtracted == true)

        let cleared = try await registry.activate(recipeID: "nuextract-b1-q8-v1")
        #expect(cleared == 1)
        #expect(try await store.countFactExtractionDebt() == 2)

        _ = try await store.setFactsExtracted(drawerId: ids[0])
        try await registry.upsert(FactExtractorModelRow(
            recipeID: "nuextract-b1-q8-v1", providerID: "replacement-provider",
            modelID: "replacement-model", modelVersion: "r2",
            schemaVersion: "kgfact-extraction-v2", extractorKind: "closure",
            maximumInputCharacters: 32_768, maximumFactsPerSource: 24,
            isActive: true))
        #expect(try await store.countFactExtractionDebt() == 2,
                "changing an active recipe identity clears bit 28")
        #expect(try await registry.all().filter(\.isActive).map(\.recipeID)
                == ["nuextract-b1-q8-v1"], "active upsert preserves a single active recipe")

        _ = try await store.setFactsExtracted(drawerId: ids[0])
        let inactive = FactExtractorModelRow(
            recipeID: "nuextract-b1-q8-v1", providerID: "replacement-provider",
            modelID: "replacement-model", modelVersion: "r2",
            schemaVersion: "kgfact-extraction-v2", extractorKind: "closure",
            maximumInputCharacters: 32_768, maximumFactsPerSource: 24,
            isActive: false)
        try await registry.upsert(inactive)
        #expect(try await store.countFactExtractionDebt() == 2,
                "changing recipe activation clears bit 28")

        _ = try await store.setFactsExtracted(drawerId: ids[0])
        _ = try await store.expungeGated(
            drawerId: ids[0], changedBy: "bilby", reason: "derived fact erasure",
            now: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(try await store.getDrawer(id: ids[0])?.areFactsExtracted == false,
                "destructive content writes clear bit 28")
    }

    private func sampleDrawer(id: String) -> Drawer {
        Drawer(id: id, content: "Jack's birthday is June 20th.",
               parentNodeId: TestStorage.tid("room-facts"), addedBy: "bilby",
               filedAt: Date(timeIntervalSince1970: 1_700_000_000),
               embeddingModelID: "test-v1", udcCode: "001")
    }
}
