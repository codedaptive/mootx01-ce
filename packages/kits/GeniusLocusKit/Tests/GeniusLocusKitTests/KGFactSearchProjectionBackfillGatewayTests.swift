// KGFactSearchProjectionBackfillGatewayTests.swift
//
// Gate C: KGFactSearchProjectionBackfillGateway injects the real
// FactSearchProjection symbols. After the gateway runs, the stored
// searchProjection must equal FactSearchProjection.build(s,p,o,aliases:[])
// and the searchProjectionVersion must equal FactSearchProjection.version —
// both referenced as Swift symbols, not string literals.
//
// Discrimination: temporarily replacing FactSearchProjection.version in
// KGFactSearchProjectionBackfillGateway.swift with a wrong string makes the
// searchProjectionVersion assertion fail (test goes red). Restoring the
// gateway returns it to green.
//
// Rust twin: rust/tests/kg_fact_search_projection_backfill_gateway_tests.rs.

import Foundation
import FactExtractionKit
@testable import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

@Suite("KGFact search-projection backfill gateway")
struct KGFactSearchProjectionBackfillGatewayTests {

    // Schema-19 shape: drawers + kg_facts WITHOUT the v20 extraction columns.
    //
    // Redeclared here because SchemaUpgradeTests lives in the LocusKitTests
    // target and cannot be imported from GeniusLocusKitTests. The shape is
    // identical to SchemaUpgradeTests.schema19 (LocusKit) — any divergence
    // from that source is a defect.
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
                // v19: enrichment column.
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

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: — Gate C

    /// Gate C: the gateway injects the real FactSearchProjection build function
    /// and version constant into the LocusKit backfill. After the gateway runs:
    ///   - searchProjection == FactSearchProjection.build(s,p,o,aliases:[])
    ///   - searchProjectionVersion == FactSearchProjection.version (the symbol)
    ///
    /// Also confirms that the backfilled fact is returned by FactFirstRecallStage.
    ///
    /// Discrimination: temporarily replacing `FactSearchProjection.version` with a
    /// wrong string in KGFactSearchProjectionBackfillGateway.swift causes the
    /// searchProjectionVersion #expect to fail (red). Restoring it returns green.
    @Test("Gate C: gateway injects real FactSearchProjection symbols; backfilled fact wins recall")
    func gateCSearchProjectionGateway() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-gateway-\(UUID().uuidString).sqlite")
        defer {
            // Remove the database file and its WAL/SHM sidecars.
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
        }

        let drawerID = "d-gateway"
        let factID   = "f-gateway"
        let subject   = "Jack"
        let predicate = "birthday"
        let object    = "June"

        // 1. Stamp the database at schema 19 and insert one drawer and one fact.
        //    The kg_facts row has no searchProjection columns — they don't exist
        //    yet in the schema-19 shape.
        do {
            let stamp = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: url)))
            try await stamp.open(schema: Self.schema19)
            _ = try await stamp.rowStore.insert(table: "drawers", values: [
                "id": .text(drawerID), "content": .text("Jack's birthday is in June."),
                "parent_node_id": .text("n1"), "addedBy": .text("test"),
                "filedAt": .text("2024-01-01T00:00:00Z"), "embeddingModelID": .text("t1"),
                "provenance": .int(0), "adjectiveBitmap": .int(0),
                // factsExtracted bit (1 << 28) set so FactFirstRecallStage can
                // score this drawer's facts in the recall step below.
                "operationalBitmap": .int(DrawerFeatureFlags.factsExtracted.rawValue),
                "lineageID": .text(""), "udcCode": .text(""),
            ])
            _ = try await stamp.rowStore.insert(table: "kg_facts", values: [
                "id": .text(factID), "subject": .text(subject),
                "predicate": .text(predicate), "object": .text(object),
                "sourceDrawerID": .text(drawerID),
                "adjectiveBitmap": .int(0), "operationalBitmap": .int(0),
                "provenanceBitmap": .int(0), "filedAt": .text("2024-01-01T00:00:00Z"),
                "addedBy": .text(""), "foreignSourceKey": .text(""), "foreignRecordID": .text(""),
            ])
            await stamp.close()
        }

        // 2. Reopen through the full LocusKitSchema (applies the v19 → v20 hop).
        //    The hop adds searchProjection and searchProjectionVersion columns with
        //    DEFAULT '' on all pre-existing rows.
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url)))
        try await storage.open(schema: LocusKitSchema.schema)

        // 3. Pre-state assertion: both new columns carry the schema DEFAULT ('').
        let rowsBefore = try await storage.rowStore.query(
            table: "kg_facts", where: nil, orderBy: [], limit: nil, offset: nil)
        #expect(rowsBefore.count == 1, "one fact before gateway")
        #expect(rowsBefore.first?["searchProjection"] == .some(.text("")),
                "searchProjection must be empty before the gateway runs")
        #expect(rowsBefore.first?["searchProjectionVersion"] == .some(.text("")),
                "searchProjectionVersion must be empty before the gateway runs")

        // 4. Run the gateway. It injects the real FactSearchProjection.build and
        //    FactSearchProjection.version — not a test double and not a string literal.
        let report = try await KGFactSearchProjectionBackfillGateway.run(storage: storage)
        #expect(report.scanned == 1, "gateway must scan the one unprojected fact")
        #expect(report.updated == 1, "gateway must update the one unprojected fact")

        // 5. Post-state: stored values match the real FactSearchProjection symbols.
        //    Assertions reference the Swift symbols, not string literals. If the
        //    gateway were to inject a wrong version string, the second assertion
        //    would fail → the test goes red without touching this file.
        let rowsAfter = try await storage.rowStore.query(
            table: "kg_facts", where: nil, orderBy: [], limit: nil, offset: nil)
        let row = try #require(rowsAfter.first)
        let expectedProjection = FactSearchProjection.build(
            subject: subject, predicate: predicate, object: object, aliases: [])
        #expect(row["searchProjection"] == .some(.text(expectedProjection)),
                "searchProjection must equal FactSearchProjection.build(s,p,o,aliases:[])")
        #expect(row["searchProjectionVersion"] == .some(.text(FactSearchProjection.version)),
                "searchProjectionVersion must equal FactSearchProjection.version (the symbol)")

        // 6. Feed the gateway-backfilled fact to FactFirstRecallStage and confirm
        //    it is returned. This closes the loop: the gateway writes exactly what
        //    FactFirstRecall's version guard (FactFirstRecall.swift lines 79-80)
        //    requires for the fact to participate in scoring.
        //
        //    Crucially, searchProjection and searchProjectionVersion are read back
        //    from the database row — not recomputed from the symbols the test
        //    already has. If the gateway had written nothing (or written wrong
        //    bytes), this recall assertion would fail, not only the step-5 equality
        //    assertions. That is what "closing the loop" means: the recall step is
        //    testing the bytes the gateway actually stored.
        guard case let .text(storedProjection) = row["searchProjection"] else {
            Issue.record("searchProjection must be present and text in the stored row after gateway run")
            return
        }
        guard case let .text(storedVersion) = row["searchProjectionVersion"] else {
            Issue.record("searchProjectionVersion must be present and text in the stored row after gateway run")
            return
        }
        let sourceDrawer = Drawer(
            id: drawerID, content: "Jack's birthday is in June.",
            parentNodeId: "n1", addedBy: "test", filedAt: now,
            embeddingModelID: "t1",
            // factsExtracted bit required by FactFirstRecall's settled-source guard.
            operationalBitmap: DrawerFeatureFlags.factsExtracted.rawValue)
        let backfilledFact = KGFact(
            id: factID, subject: subject, predicate: predicate, object: object,
            sourceDrawerID: drawerID,
            searchProjection: storedProjection,
            searchProjectionVersion: storedVersion,
            filedAt: now)
        let decision = FactFirstRecallStage.decide(
            query: "jack birthday", queryEntities: ["Jack"],
            facts: [backfilledFact], sourceDrawers: [drawerID: sourceDrawer])
        guard case let .solid(family) = decision else {
            Issue.record(
                "gateway-backfilled fact must win recall; got \(decision). Check that FactSearchProjection.build produces high coverage for the query.")
            return
        }
        #expect(family.fact.id == factID,
                "the gateway-backfilled fact must be the one returned by FactFirstRecallStage")

        await storage.close()
    }
}
