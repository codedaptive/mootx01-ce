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

    /// The schema-19 shape of the tables the v19 → v20 hop modifies: drawers
    /// with the v12 subject trio and the v19 ssc_facts column; kg_facts with the
    /// v13 identity trio but none of the v20 extraction columns. Used to prove
    /// the hop preserves pre-existing rows and stamps the declared defaults on
    /// all twelve new columns.
    private static let schema19 = SchemaDeclaration(
        kitID: "LocusKit",
        version: 19,
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
                // v12: subject trio added by the v10 → v19 hop.
                .text("subject", nullable: true),
                .text("subject_pipeline_version", nullable: true),
                .timestamp("subject_at", nullable: true),
                // v19: enrichment column added by the v10 → v19 hop.
                .text("ssc_facts", nullable: true),
            ], primaryKey: ["id"]),
            TableDeclaration(name: "kg_facts", columns: [
                .text("id"), .text("subject"), .text("predicate"), .text("object"),
                .text("sourceDrawerID"), .bitmap("adjectiveBitmap"), .bitmap("operationalBitmap"),
                .bitmap("provenanceBitmap"), .timestamp("filedAt"), .json("ext", nullable: true),
                // v13: identity trio added by the v10 → v19 hop.
                ColumnDeclaration(name: "addedBy", type: .text, nullable: false, defaultValue: .text("")),
                ColumnDeclaration(name: "foreignSourceKey", type: .text, nullable: false, defaultValue: .text("")),
                ColumnDeclaration(name: "foreignRecordID", type: .text, nullable: false, defaultValue: .text("")),
            ], primaryKey: ["id"]),
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

    @Test("a populated schema-19 estate lands at 20 preserving data and applying extraction schema defaults")
    func schema19LandsAt20() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let drawerID = "d-v19-1"
        let factID   = "f-v19-1"

        // 1. Stamp the database at schema 19 and insert one row in each table
        //    using only the v19 columns — the twelve v20 extraction columns do
        //    not exist yet in this fixture.
        do {
            let stamp = TestStorage.sqlite(url)
            try await stamp.open(schema: Self.schema19)
            #expect(try await stamp.currentSchemaVersion(for: "LocusKit") == 19)
            _ = try await stamp.rowStore.insert(table: "drawers", values: [
                "id": .text(drawerID), "content": .text("v19 drawer"),
                "parent_node_id": .text("n1"), "addedBy": .text("test"),
                "filedAt": .text("2024-01-01T00:00:00Z"), "embeddingModelID": .text("t1"),
                "provenance": .int(0), "adjectiveBitmap": .int(0), "operationalBitmap": .int(0),
                "lineageID": .text(""), "udcCode": .text(""),
            ])
            _ = try await stamp.rowStore.insert(table: "kg_facts", values: [
                "id": .text(factID), "subject": .text("sky"), "predicate": .text("is"),
                "object": .text("blue"), "sourceDrawerID": .text(drawerID),
                "adjectiveBitmap": .int(0), "operationalBitmap": .int(0),
                "provenanceBitmap": .int(0), "filedAt": .text("2024-01-01T00:00:00Z"),
                "addedBy": .text(""), "foreignSourceKey": .text(""), "foreignRecordID": .text(""),
            ])
            // Confirm both rows landed before the hop.
            #expect(try await stamp.rowStore.count(table: "drawers", where: nil) == 1)
            #expect(try await stamp.rowStore.count(table: "kg_facts", where: nil) == 1)
            await stamp.close()
        }
        // 2. Confirm the upgrade path routes v19 to a hop — the same decision the
        //    upgrade command makes before opening the schema.
        #expect(LocusKitSchema.upgradePath(storedVersion: 19) == .upgrade(from: 19))

        // 3. Reopen through the full schema: applies the v19 → v20 hop.
        let storage = TestStorage.sqlite(url)
        try await storage.open(schema: LocusKitSchema.schema)

        // a. Schema version is 20 after the hop.
        #expect(try await storage.currentSchemaVersion(for: "LocusKit") == LocusKitSchema.version)
        #expect(LocusKitSchema.version == 20)

        // b. Both pre-existing rows survived the hop unchanged in count.
        #expect(try await storage.rowStore.count(table: "drawers", where: nil) == 1)
        #expect(try await storage.rowStore.count(table: "kg_facts", where: nil) == 1)

        // c. All twelve new kg_facts extraction columns carry their declared
        //    defaults on the pre-existing row.
        let factRows = try await storage.rowStore.query(
            table: "kg_facts", where: nil, orderBy: [], limit: nil, offset: nil)
        let row = try #require(factRows.first)
        // Text columns: declared DEFAULT ''.
        #expect(row["evidenceQuote"] == .some(.text("")))
        #expect(row["sourceDigest"] == .some(.text("")))
        #expect(row["extractorProviderID"] == .some(.text("")))
        #expect(row["extractorModelID"] == .some(.text("")))
        #expect(row["extractorModelVersion"] == .some(.text("")))
        #expect(row["extractionSchemaVersion"] == .some(.text("")))
        #expect(row["searchProjection"] == .some(.text("")))
        #expect(row["searchProjectionVersion"] == .some(.text("")))
        // Int columns: declared DEFAULT -1.
        #expect(row["evidenceStart"] == .some(.int(-1)))
        #expect(row["evidenceEnd"] == .some(.int(-1)))
        #expect(row["evidenceStartUTF8Byte"] == .some(.int(-1)))
        #expect(row["evidenceEndUTF8Byte"] == .some(.int(-1)))

        // d. fact_extractor_models was created by the hop and holds zero rows.
        #expect(await columnsExist(storage, table: "fact_extractor_models", columns: ["recipe_id", "is_active"]))
        #expect(try await storage.rowStore.count(table: "fact_extractor_models", where: nil) == 0)

        // e. A value written at v19 into an existing column reads back unchanged.
        #expect(row["predicate"] == .some(.text("is")))
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
