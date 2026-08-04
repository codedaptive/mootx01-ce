import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
@testable import LocusKit

/// MXE-MI: the kg_facts identity backfill.
///
/// Two legs:
///   1. Schema: a pre-MXE-KH (v12) estate whose `kg_facts` table lacks
///      `addedBy`/`foreignSourceKey`/`foreignRecordID` gains them through
///      the v12 → v13 ladder entry when the backfill opens it.
///   2. Classification: every pre-KH `sourceDrawerID` shape lands in its
///      own column under the exactly-one-match rule; ambiguous values
///      stay put and are counted; a second run changes nothing.
///
/// The foreign-key resolver here is a test double keyed to fixed UUIDs —
/// LocusKit tests cannot (and must not) import VaultKit. The REAL
/// resolver (`DrawerMapping.lineageID(forStableSourceKey:)`) is injected
/// by `mootx01 upgrade` and exercised end-to-end by VaultKit's
/// `PalaceReimportAfterBackfillTests`.
@Suite("KGFactIdentityBackfillTests")
struct KGFactIdentityBackfillTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-kgbackfill-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    /// A resolver that never matches anything — for tests with no
    /// foreign-key class in play.
    private static let nullResolver: @Sendable (String) -> UUID = { _ in
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    /// The lineage the fake resolver mints for the one palace key the
    /// tests use — the estate-side drawer carries it, so rule B resolves.
    private static let palaceLineage = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private static let palaceResolver: @Sendable (String) -> UUID = { key in
        key == "drawer_alpha_0001" ? palaceLineage : nullResolver(key)
    }

    /// The v12 LocusKit schema shape: identical to the live declaration
    /// except `kg_facts` lacks the identity trio and the ladder is empty
    /// (so opening records exactly version 12, the way a pre-KH estate
    /// on disk is recorded).
    private func v12Schema() -> SchemaDeclaration {
        let live = LocusKitSchema.schema
        let identityTrio: Set<String> = ["addedBy", "foreignSourceKey", "foreignRecordID"]
        let v12KGFacts = TableDeclaration(
            name: "kg_facts",
            columns: LocusKitSchema.kgFactsTable.columns.filter {
                !identityTrio.contains($0.name)
            },
            primaryKey: LocusKitSchema.kgFactsTable.primaryKey,
            generatedColumns: LocusKitSchema.kgFactsTable.generatedColumns
        )
        return SchemaDeclaration(
            kitID: LocusKitSchema.kitID,
            version: 12,
            tables: live.tables.map { $0.name == "kg_facts" ? v12KGFacts : $0 },
            indices: live.indices,
            migrations: []
        )
    }

    /// Raw pre-KH kg_facts row: exactly the columns the v12 table has.
    private func preKHRowValues(
        id: String, subject: String, predicate: String, object: String,
        sourceDrawerID: String
    ) -> [String: TypedValue] {
        [
            "id": .text(id),
            "subject": .text(subject),
            "predicate": .text(predicate),
            "object": .text(object),
            "sourceDrawerID": .text(sourceDrawerID),
            "adjectiveBitmap": .bitmap(0),
            "operationalBitmap": .bitmap(0),
            "provenanceBitmap": .bitmap(0),
            "filedAt": .timestamp(t(1_700_000_000)),
        ]
    }

    // MARK: - Leg 1: the v12 → v13 column migration

    @Test("a v12 estate gains the identity columns and its rows migrate")
    func v12EstateGainsColumnsAndMigrates() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        // Build the pre-KH estate: v12 schema (no identity columns) with a
        // host-identity fact written the way pre-KH ToolDispatch wrote it.
        let v12Storage = TestStorage.sqlite(url)
        try await v12Storage.open(schema: v12Schema())
        _ = try await v12Storage.rowStore.insert(
            table: "kg_facts",
            values: preKHRowValues(
                id: "f-host", subject: "fleet", predicate: "works_with",
                object: "skippy", sourceDrawerID: "mootx01"))
        await v12Storage.close()

        // The backfill opens through the substrate path; the v12 → v13
        // ladder entry must add the columns BEFORE the row moves. Without
        // the migration this run dies with "no such column: addedBy"
        // (Smythe CRITICAL-1, the gap MXE-KH shipped).
        let storage = TestStorage.sqlite(url)
        let report = try await KGFactIdentityBackfill.run(
            storage: storage, resolveForeignKey: Self.nullResolver)

        #expect(report.scanned == 1)
        #expect(report.hostIdentities == 1)
        #expect(report.unclassified == 0)

        let store = try await DrawerStore(storage: storage)
        let fact = try #require(try await store.getKGFact(id: "f-host"))
        #expect(fact.addedBy == "mootx01")
        #expect(fact.sourceDrawerID.isEmpty,
            "host identity must leave sourceDrawerID after the move")
        await storage.close()
    }

    // MARK: - Leg 2: classification

    /// One estate carrying every pre-KH shape at once — the mission's
    /// fixture-estate requirement. Also proves idempotence: the second
    /// run scans only the unclassifiable leftover and changes nothing.
    @Test("every class lands in its own column; second run changes nothing")
    func everyClassLandsInItsOwnColumnAndSecondRunIsIdempotent() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)

        // A real local anchor drawer with nonzero bitmaps — the
        // inheritance source (MXE-KH's rule applied to migrated data).
        // Elevated sensitivity lives at bits 6–11 of the adjective bitmap
        // (scale-gapped raw 16); the write gate rejects any illegal field
        // value, so the composition matters.
        let anchorAdjective = Int64(AdjectiveSensitivity.elevated.rawValue) << 6
        let anchorID = TestStorage.tid("anchor-drawer")
        try await store.addDrawer(Drawer(
            id: anchorID, content: "anchor", parentNodeId: "test-parent",
            addedBy: "bilby", filedAt: t(1_000),
            embeddingModelID: "test-v1",
            provenance: 5, adjectiveBitmap: anchorAdjective))
        // The imported drawer a palace key resolves to (rule B evidence).
        try await store.addDrawer(Drawer(
            id: TestStorage.tid("imported-drawer"), content: "imported",
            parentNodeId: "test-parent", addedBy: "bilby", filedAt: t(1_001),
            embeddingModelID: "test-v1",
            lineageID: Self.palaceLineage))

        func fact(_ id: String, subject: String = "s", predicate: String = "p",
                  object: String = "o", source: String) -> KGFact {
            KGFact(id: id, subject: subject, predicate: predicate,
                   object: object, sourceDrawerID: source,
                   filedAt: t(1_700_000_000))
        }
        // Host identities — one per compiled-in value.
        try await store.addKGFact(fact("f-moot", source: "mootx01"))
        try await store.addKGFact(fact("f-aria", source: "aria-mcp-server"))
        try await store.addKGFact(fact("f-aria-old", source: "aria-mcp"))
        try await store.addKGFact(fact("f-gw", source: "Gateway"))
        // Foreign palace key (pre-KH Swift importer shape).
        try await store.addKGFact(fact("f-palace", source: "drawer_alpha_0001"))
        // Triple id (pre-KH Rust importer shape): main fact plus its
        // temporal sibling, both carrying the triple's own id.
        try await store.addKGFact(fact("f-triple", source: "t_fleet_0001"))
        try await store.addKGFact(fact(
            "f-triple-temporal", subject: "t_fleet_0001",
            predicate: "temporal:valid_from", object: "2020-01-01",
            source: "t_fleet_0001"))
        // Genuine local anchor, pre-KH verb-default bitmaps (all zero).
        try await store.addKGFact(fact("f-local", source: anchorID))
        // Unclassifiable: matches no rule.
        try await store.addKGFact(fact("f-mystery", source: "mystery-999"))

        let report = try await KGFactIdentityBackfill.run(
            storage: storage, resolveForeignKey: Self.palaceResolver)

        #expect(report.scanned == 9)
        #expect(report.hostIdentities == 4)
        #expect(report.foreignPalaceKeys == 1)
        #expect(report.tripleIDs == 2)
        #expect(report.localDrawerIDs == 1)
        #expect(report.inheritanceApplied == 1)
        #expect(report.unclassified == 1)

        // Column placement per class.
        for id in ["f-moot", "f-aria", "f-aria-old", "f-gw"] {
            let f = try #require(try await store.getKGFact(id: id))
            #expect(!f.addedBy.isEmpty && f.sourceDrawerID.isEmpty)
        }
        let palace = try #require(try await store.getKGFact(id: "f-palace"))
        #expect(palace.foreignSourceKey == "drawer_alpha_0001")
        #expect(palace.sourceDrawerID.isEmpty)
        let triple = try #require(try await store.getKGFact(id: "f-triple"))
        #expect(triple.foreignRecordID == "t_fleet_0001")
        #expect(triple.sourceDrawerID.isEmpty)
        // Local anchor kept, sensitivity inherited from the drawer.
        let local = try #require(try await store.getKGFact(id: "f-local"))
        #expect(local.sourceDrawerID == anchorID)
        #expect(local.adjectiveBitmap == anchorAdjective)
        #expect(local.provenanceBitmap == 5)
        // Unclassifiable untouched.
        let mystery = try #require(try await store.getKGFact(id: "f-mystery"))
        #expect(mystery.sourceDrawerID == "mystery-999")
        #expect(mystery.addedBy.isEmpty && mystery.foreignSourceKey.isEmpty
            && mystery.foreignRecordID.isEmpty)

        // Second run: moved rows have left the scan set; what remains is
        // the local anchor (kept by design, inheritance already applied
        // so it does not fire again) and the mystery row. Nothing changes.
        let before = try await store.allKGFactsIncludingRetired()
        let second = try await KGFactIdentityBackfill.run(
            storage: storage, resolveForeignKey: Self.palaceResolver)
        #expect(second.scanned == 2)
        #expect(second.localDrawerIDs == 1)
        #expect(second.unclassified == 1)
        #expect(second.hostIdentities == 0 && second.foreignPalaceKeys == 0
            && second.tripleIDs == 0 && second.inheritanceApplied == 0)
        let after = try await store.allKGFactsIncludingRetired()
        #expect(after == before, "a second run must change nothing")
        await storage.close()
    }

    @Test("a value matching two rules stays put and is counted")
    func multiMatchStaysPut() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)

        // "t_ambiguous_0001" is BOTH a temporal subject (rule C) and — via
        // this test's resolver — a key resolving to an existing lineage
        // (rule B). Two matches → the value must not move.
        try await store.addDrawer(Drawer(
            id: TestStorage.tid("imported-drawer"), content: "imported",
            parentNodeId: "test-parent", addedBy: "bilby", filedAt: t(1_000),
            embeddingModelID: "test-v1", lineageID: Self.palaceLineage))
        try await store.addKGFact(KGFact(
            id: "f-ambiguous", subject: "s", predicate: "p", object: "o",
            sourceDrawerID: "t_ambiguous_0001", filedAt: t(1_700_000_000)))
        try await store.addKGFact(KGFact(
            id: "f-ambiguous-temporal", subject: "t_ambiguous_0001",
            predicate: "temporal:valid_to", object: "2021-01-01",
            sourceDrawerID: "", filedAt: t(1_700_000_000)))

        let ambiguousResolver: @Sendable (String) -> UUID = { key in
            key == "t_ambiguous_0001" ? Self.palaceLineage : Self.nullResolver(key)
        }
        let report = try await KGFactIdentityBackfill.run(
            storage: storage, resolveForeignKey: ambiguousResolver)

        #expect(report.scanned == 1)
        #expect(report.unclassified == 1)
        let f = try #require(try await store.getKGFact(id: "f-ambiguous"))
        #expect(f.sourceDrawerID == "t_ambiguous_0001",
            "a multi-match value must never be moved on a guess")
        await storage.close()
    }

    @Test("nonzero fact bitmaps are never clobbered by inheritance")
    func nonzeroBitmapsAreNeverClobbered() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)

        let anchorID = TestStorage.tid("anchor-drawer")
        // Restricted sensitivity (scale-gapped raw 32) at bits 6–11 —
        // a legal composition the write gate accepts.
        try await store.addDrawer(Drawer(
            id: anchorID, content: "anchor", parentNodeId: "test-parent",
            addedBy: "bilby", filedAt: t(1_000), embeddingModelID: "test-v1",
            provenance: 7,
            adjectiveBitmap: Int64(AdjectiveSensitivity.restricted.rawValue) << 6))
        // A retired fact (RowState withdrawn raw = 18): its bitmap is real
        // state, not the pre-KH default — inheritance must not touch it.
        try await store.addKGFact(KGFact(
            id: "f-retired", subject: "s", predicate: "p", object: "o",
            sourceDrawerID: anchorID, adjectiveBitmap: 18,
            filedAt: t(1_700_000_000)))

        let report = try await KGFactIdentityBackfill.run(
            storage: storage, resolveForeignKey: Self.nullResolver)

        #expect(report.localDrawerIDs == 1)
        #expect(report.inheritanceApplied == 0)
        let f = try #require(try await store.getKGFact(id: "f-retired"))
        #expect(f.adjectiveBitmap == 18)
        #expect(f.provenanceBitmap == 0)
        await storage.close()
    }

    @Test("retired facts are still migrated — the scan includes them")
    func retiredFactsAreMigrated() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)

        try await store.addKGFact(KGFact(
            id: "f-retired-host", subject: "s", predicate: "p", object: "o",
            sourceDrawerID: "mootx01", filedAt: t(1_700_000_000)))
        try await store.withdrawKGFact(id: "f-retired-host")

        let report = try await KGFactIdentityBackfill.run(
            storage: storage, resolveForeignKey: Self.nullResolver)

        #expect(report.hostIdentities == 1)
        let f = try #require(try await store.getKGFact(id: "f-retired-host"))
        #expect(f.addedBy == "mootx01")
        #expect(f.sourceDrawerID.isEmpty)
        // Retirement state preserved through the move.
        #expect(f.adjectiveBitmap & 0x3F == 18)
        await storage.close()
    }
}
