// SchemaUpgradeTests.swift
//
// The v10 → v19 → v20 ladder against a
// schema-10 SQLite file. Twin of Rust `schema_upgrade_tests.rs`.
//
// The fixture is built here from the CE v1.0.37 declaration shape (schema
// 10: no subject trio, no kg_facts identity trio, no operationalAND, none
// of the v16–v18 objects), stamped 10 in the ledger by opening it with a
// version-10 declaration. Opening it again with the current LocusKit
// schema must land at 20 with the encoder and fact-extractor registries,
// surviving v11–v15 deltas present, and none of the retired objects.
//
// Failure modes pinned:
//   1. The ladder silently re-appearing: a `distilled` column or an
//      `adornments` table after the hop.
//   2. A missing surviving delta: `subject`, `addedBy`, `operationalAND`.
//   3. The refusal gate: `upgradePath` for 18 and 11 is `.unsupported`.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import LocusKit

@Suite("Schema upgrade v10 → v20")
struct SchemaUpgradeTests {

    /// The schema-10 shape of the tables the hop touches (CE v1.0.37
    /// `LocusKitSchema.swift`): drawers through `content_fingerprint`,
    /// kg_facts without the identity trio, container_fingerprints without
    /// `operationalAND`.
    private static let schema10 = SchemaDeclaration(
        kitID: "LocusKit",
        version: 10,
        tables: [
            TableDeclaration(name: "drawers", columns: [
                .text("id"), .text("content"), .text("parent_node_id"),
                .text("sourceFile", nullable: true), .int("chunkIndex", nullable: true),
                .text("addedBy"), .timestamp("filedAt"), .timestamp("eventTime", nullable: true),
                .text("embeddingModelID"), .timestamp("tombstonedAt", nullable: true),
                .text("removedByBatch", nullable: true),
                .bitmap("provenance"), .bitmap("adjectiveBitmap"), .bitmap("operationalBitmap"),
                ColumnDeclaration(name: "lineageID", type: .text, nullable: false, defaultValue: .text("")),
                ColumnDeclaration(name: "udcCode", type: .text, nullable: false, defaultValue: .text("")),
                .text("udcFacets", nullable: true), .text("wikidataQID", nullable: true),
                .text("wikidataQidsSecondary", nullable: true), .json("ext", nullable: true),
                .text("keyID", nullable: true), .blob("content_hash", nullable: true),
                .blob("content_fingerprint", nullable: true),
            ], primaryKey: ["id"]),
            TableDeclaration(name: "kg_facts", columns: [
                .text("id"), .text("subject"), .text("predicate"), .text("object"),
                .text("sourceDrawerID"), .bitmap("adjectiveBitmap"), .bitmap("operationalBitmap"),
                .bitmap("provenanceBitmap"), .timestamp("filedAt"), .json("ext", nullable: true),
            ], primaryKey: ["id"]),
            TableDeclaration(name: "container_fingerprints", columns: [
                .text("wing"), .text("room"), .bitmap("adjectiveOR"), .bitmap("operationalOR"),
                .bitmap("provenanceOR"), .timestamp("updatedAt"),
            ], primaryKey: ["wing", "room"]),
        ]
    )

    /// True when every column exists on `table`. Probed with an UPDATE whose
    /// predicate never matches: SQLite reads an unknown double-quoted
    /// identifier in a SELECT as a string literal and returns rows, so a
    /// projected read cannot tell a missing column apart; an UPDATE target
    /// must be a real column ("no such column") and the table must exist
    /// ("no such table").
    private func columnsExist(_ storage: any Storage, table: String, columns: [String]) async -> Bool {
        do {
            var values: [String: TypedValue] = [:]
            for column in columns { values[column] = .null }
            _ = try await storage.rowStore.update(table: table, values: values, where: .isFalse)
            return true
        } catch {
            return false
        }
    }

    @Test("a schema-10 estate lands at 20 with only the surviving deltas")
    func schema10LandsAt20() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        do {
            let stamp = TestStorage.sqlite(url)
            try await stamp.open(schema: Self.schema10)
            #expect(try await stamp.currentSchemaVersion(for: "LocusKit") == 10)
            await stamp.close()
        }
        let storage = TestStorage.sqlite(url)
        try await storage.open(schema: LocusKitSchema.schema)
        #expect(try await storage.currentSchemaVersion(for: "LocusKit") == LocusKitSchema.version)
        #expect(LocusKitSchema.version == 20)

        // v19 additions.
        #expect(await columnsExist(storage, table: "encoder_models", columns: ["model_id", "is_active"]))
        #expect(await columnsExist(storage, table: "drawers", columns: ["ssc_facts"]))
        #expect(await columnsExist(storage, table: "fact_extractor_models", columns: ["recipe_id", "is_active"]))
        #expect(await columnsExist(storage, table: "kg_facts", columns: [
            "evidenceQuote", "evidenceStart", "evidenceEnd", "sourceDigest",
            "extractorProviderID", "extractorModelID", "searchProjection",
            "searchProjectionVersion",
        ]))
        // Surviving v11–v15 deltas.
        #expect(await columnsExist(storage, table: "drawers", columns: ["subject", "subject_pipeline_version", "subject_at"]))
        #expect(await columnsExist(storage, table: "kg_facts", columns: ["addedBy", "foreignSourceKey", "foreignRecordID"]))
        #expect(await columnsExist(storage, table: "container_fingerprints", columns: ["operationalAND"]))
        #expect(await columnsExist(storage, table: "recall_trace", columns: ["door", "composition", "laneRanks"]))
        // Retired objects never created.
        #expect(!(await columnsExist(storage, table: "drawers", columns: ["distilled"])), "distilled must not appear")
        #expect(!(await columnsExist(storage, table: "drawers", columns: ["distilled_source_digest"])))
        #expect(!(await columnsExist(storage, table: "drawers", columns: ["adornment"])))
        #expect(!(await columnsExist(storage, table: "adornments", columns: ["drawer_id"])), "adornments must not appear")
        #expect(!(await columnsExist(storage, table: "adornment_minters", columns: ["id"])), "adornment_minters must not appear")

        // The upgraded file serves a DrawerStore round trip.
        let store = try await DrawerStore(storage: storage)
        let id = TestStorage.tid("after-upgrade")
        try await store.addDrawer(Drawer(id: id, content: "post-upgrade row",
                                         parentNodeId: TestStorage.tid("room-upgrade"),
                                         addedBy: "bilby", filedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                         embeddingModelID: "test-v1", udcCode: "001"))
        let loaded = try #require(try await store.getDrawer(id: id))
        #expect(loaded.sscFacts == nil && !loaded.isSpanIndexed && !loaded.areFactsExtracted)
        await storage.close()
    }

    @Test("upgradePath refuses every version but fresh, floor and current")
    func upgradePathGate() {
        #expect(LocusKitSchema.upgradePath(storedVersion: 0) == .fresh)
        #expect(LocusKitSchema.upgradePath(storedVersion: 10) == .upgrade(from: 10))
        #expect(LocusKitSchema.upgradePath(storedVersion: 19) == .upgrade(from: 19))
        #expect(LocusKitSchema.upgradePath(storedVersion: 20) == .current)
        for found in [1, 9, 11, 15, 18, 21] {
            #expect(LocusKitSchema.upgradePath(storedVersion: found) == .unsupported(found: found))
        }
    }
}
