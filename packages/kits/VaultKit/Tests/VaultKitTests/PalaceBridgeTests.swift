import Testing
import Foundation
import SQLite3
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

// PalaceBridge direct-import tests.
//
// Uses the same fixture palace as MemPalaceChromaAdapterTests:
// `Fixtures/mempalace/` (palace/chroma.sqlite3 + tunnels.json +
// knowledge_graph.sqlite3). Verifies that PalaceBridge lands drawers and
// tunnels from the fixture (count lower-bounds checked, not exact), respects
// all four import guards (idempotence, tombstone, tunnel dedup, receipt),
// and files a diary receipt entry. KGFact landing is not independently
// asserted; KG rows land as drawers and are included in the drawersWritten >= 3
// lower bound.
@Suite("PalaceBridge direct import")
struct PalaceBridgeTests {

    static var fixturePalaceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mempalace")
    }

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "palacebridge-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    // MARK: - Basic import

    @Test("fixture palace: drawers, tunnels, and KG items land in the estate")
    func fixtureImportBasic() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        let report = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )

        // Fixture has 3 mempalace_drawers chroma rows + 2 mempalace_closets rows
        // + 2 KG entities. All land as drawers. If this is 0, the chroma
        // collection names don't match the fixture (regression guard).
        #expect(report.drawersWritten >= 3, "chroma rows must land as drawers")
        // At least one tunnel created (fixture has 2 tunnel records).
        #expect(report.tunnelsCreated > 0)
        // No update on a fresh estate.
        #expect(report.drawersUpdated == 0)
    }

    // MARK: - Idempotence (content-idempotent guard)

    @Test("re-import of fixture palace is idempotent: no writes, all unchanged")
    func fixtureImportIdempotent() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        let first = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )
        let second = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )

        // Second import writes nothing new.
        #expect(second.drawersWritten == 0)
        #expect(second.drawersUpdated == 0)
        // All previously-written drawers count as unchanged on re-import.
        #expect(second.drawersSkippedUnchanged == first.drawersWritten + first.drawersUpdated)
    }

    // MARK: - Tombstone guard

    @Test("tombstoned lineage is not resurrected on re-import")
    func tombstoneGuard() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        // First import to get the lineage IDs into the estate.
        let first = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )
        #expect(first.drawersWritten > 0)

        // Withdraw one drawer (moves lineage to usedToBelieve).
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 1)
        )
        let targetDrawer = try #require(drawers.first)
        let targetLineage = targetDrawer.lineageID
        try await kit.withdraw(handle, WithdrawFrame(rowID: targetDrawer.id, reason: "test-withdrawal"))

        // Second import must not resurrect the withdrawn lineage.
        let second = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )
        #expect(second.drawersSkippedTombstoned >= 1)

        // Confirm the drawer is still withdrawn after re-import.
        let stillWithdrawn = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [.usedToBelieve],
                hydrationLevel: .structured,
                limit: 1_000
            )
        )
        #expect(stillWithdrawn.contains { $0.lineageID == targetLineage })
    }

    // MARK: - Tunnel dedup guard

    @Test("tunnel signatures are deduplicated on re-import: no duplicate tunnels")
    func tunnelDedup() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        let first = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )
        let second = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )

        // Re-import creates zero additional tunnels.
        #expect(second.tunnelsCreated == 0)
        // Total tunnel count across both imports equals the first import's count.
        #expect(first.tunnelsCreated > 0)
    }

    // MARK: - CAND-042: Foreign-anchor rejection

    @Test("CAND-042: KG fact with a sourceDrawerID that has no corresponding lineage in the estate is rejected")
    func foreignAnchorFactRejected() async throws {
        // Import the fixture palace first so the estate has some drawers.
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        _ = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )

        // Capture the count of KG facts after the first (real) import.
        let kgFactsBefore = try await kit.recallKGFacts(handle)

        // Build a synthetic palace directory with a knowledge_graph.sqlite3
        // whose single triple references a source_drawer_id that does not
        // correspond to any lineage in the estate. The foreign ID can never
        // map to an existing lineage because DrawerMapping.lineageID is
        // deterministic (UUIDv5 from the source key), so a random string
        // will never collide with an imported drawer's lineageID.
        //
        // Note: PalaceBridge reads the KG store from
        // `<palaceRoot>/knowledge_graph.sqlite3` (MemPalaceChromaAdapter.knowledgeGraphRelativePath),
        // so the file must be at the root of the synthetic palace directory.
        let syntheticPalace = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-palace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: syntheticPalace) }
        try FileManager.default.createDirectory(
            at: syntheticPalace, withIntermediateDirectories: true)
        let kgPath = syntheticPalace.appendingPathComponent("knowledge_graph.sqlite3").path

        // Create the KG SQLite file directly with the C sqlite3 API (no
        // write-capable wrapper is available in the test target).
        var dbHandle: OpaquePointer?
        #expect(sqlite3_open(kgPath, &dbHandle) == SQLITE_OK, "cannot create temp KG db")
        let createSQL = """
            CREATE TABLE triples (
                id TEXT PRIMARY KEY,
                subject TEXT NOT NULL DEFAULT '',
                predicate TEXT NOT NULL DEFAULT '',
                object TEXT NOT NULL DEFAULT '',
                valid_from TEXT,
                valid_to TEXT,
                confidence REAL,
                source_drawer_id TEXT NOT NULL DEFAULT ''
            );
            INSERT INTO triples (id, subject, predicate, object, source_drawer_id)
            VALUES ('t-foreign', 'alien:subject', 'alien:predicate', 'alien:object',
                    'totally-foreign-drawer-id-not-in-estate');
            CREATE TABLE entities (id TEXT PRIMARY KEY, name TEXT, type TEXT,
                                   properties TEXT, created_at TEXT);
            """
        sqlite3_exec(dbHandle, createSQL, nil, nil, nil)
        sqlite3_close(dbHandle)

        // importPalace of the synthetic palace. The foreign-anchor triple
        // must be rejected (itemsSkipped incremented) by CAND-042.
        let second = try await bridge.importPalace(
            at: syntheticPalace, into: handle, now: now
        )
        let kgFactsAfter = try await kit.recallKGFacts(handle)

        // The foreign-anchor triple must be counted as skipped.
        #expect(second.itemsSkipped >= 1,
            "CAND-042 regression: foreign-anchor KG fact must be rejected (itemsSkipped >= 1)")
        // The KG fact count must not grow — the foreign-anchor fact was rejected.
        #expect(kgFactsAfter.count == kgFactsBefore.count,
            "CAND-042 regression: foreign-anchor KG fact must not land in the estate")
    }

    // MARK: - CAND-049: KG fact deduplication on re-import

    @Test("CAND-049: re-importing an identical KG fact does not create a duplicate")
    func kgFactDeduplicationOnReimport() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        // First import brings KG facts in from the fixture.
        let first = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )
        let kgFactsAfterFirst = try await kit.recallKGFacts(handle)
        let countAfterFirst = kgFactsAfterFirst.count

        // Re-import the same fixture. Without dedup, every triple would create
        // a new KGFact row, doubling the count each time.
        let second = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )
        let kgFactsAfterSecond = try await kit.recallKGFacts(handle)
        let countAfterSecond = kgFactsAfterSecond.count

        // The first import must have written some KG facts (fixture guard).
        #expect(first.fdcUnclassified > 0,
            "fixture must produce at least one KG fact on first import")
        // The second import's itemsSkipped must account for the duplicate facts.
        #expect(second.itemsSkipped > 0,
            "CAND-049 regression: re-import should skip duplicate KG facts")
        // KG fact count must not grow on re-import — all identical facts must be deduped.
        #expect(countAfterSecond == countAfterFirst,
            "CAND-049 regression: re-import must not duplicate KG facts (count must be stable)")
    }

    // MARK: - Exportability-change security regression (codex 7c952932)

    /// Build a minimal synthetic palace containing a single chroma document with
    /// the given exportability label. The document body is intentionally stable
    /// across calls; only the label changes, isolating the exportability-change
    /// detection path under test.
    private func makePalaceDir(exportabilityLabel: String) throws -> URL {
        let palace = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultkit-exportability-\(UUID().uuidString)")
        let palaceSubdir = palace.appendingPathComponent("palace")
        try FileManager.default.createDirectory(
            at: palaceSubdir, withIntermediateDirectories: true)
        let chromaPath = palaceSubdir.appendingPathComponent("chroma.sqlite3").path

        var db: OpaquePointer?
        guard sqlite3_open(chromaPath, &db) == SQLITE_OK else {
            throw NSError(domain: "PalaceBridgeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open temp chroma db"])
        }
        defer { sqlite3_close(db) }

        // Schema mirrors the real MemPalace chroma.sqlite3 structure.
        let schema = """
            CREATE TABLE collections (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, dimension INTEGER,
                database_id TEXT NOT NULL, config_json_str TEXT, schema_str TEXT
            );
            CREATE TABLE segments (
                id TEXT PRIMARY KEY, type TEXT NOT NULL,
                scope TEXT NOT NULL, collection TEXT NOT NULL
            );
            CREATE TABLE embeddings (
                id INTEGER PRIMARY KEY, segment_id TEXT NOT NULL,
                embedding_id TEXT NOT NULL, seq_id BLOB NOT NULL,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (segment_id, embedding_id)
            );
            CREATE TABLE embedding_metadata (
                id INTEGER REFERENCES embeddings(id), key TEXT NOT NULL,
                string_value TEXT, int_value INTEGER, float_value REAL,
                bool_value INTEGER, PRIMARY KEY (id, key)
            );
            INSERT INTO collections (id, name, database_id)
            VALUES ('col-1', 'mempalace_drawers', 'db-1');
            INSERT INTO segments (id, type, scope, collection)
            VALUES ('seg-1', 'urn:chroma:segment/sqlite-metadata', 'METADATA', 'col-1');
            INSERT INTO embeddings (id, segment_id, embedding_id, seq_id)
            VALUES (1, 'seg-1', 'exportability-regression-doc-001', x'00');
            INSERT INTO embedding_metadata (id, key, string_value)
            VALUES (1, 'chroma:document',
                    'Stable content that never changes between imports.');
            """
        sqlite3_exec(db, schema, nil, nil, nil)

        // Insert the exportability label as a separate statement so it can vary
        // per call without affecting the schema setup above.
        let labelSQL = """
            INSERT INTO embedding_metadata (id, key, string_value)
            VALUES (1, 'exportability', '\(exportabilityLabel)');
            """
        sqlite3_exec(db, labelSQL, nil, nil, nil)

        return palace
    }

    /// Recall all currently-believed drawers (cluster A), sensitivity ceiling
    /// extended to Secret so all tiers are visible. Mirrors `current_drawers_all`
    /// in the Rust test suite.
    private func currentDrawersAll(
        kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> [LocusKit.Drawer] {
        try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [
                    .currentlyBelieve,
                    .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                    .any([.trustworthy, .requiresConfirmation]),
                    .sensitivityAtMost(.secret),
                ],
                hydrationLevel: .full,
                limit: 10_000_000
            )
        )
    }

    /// Security regression (codex 7c952932): a public→private exportability change
    /// on otherwise-unchanged content must NOT be suppressed by the
    /// content-idempotent skip guard.
    ///
    /// Step 1: Import with exportability=public → drawer written, exportability=public_.
    /// Step 2: Re-import, same body, exportability=private → must NOT skip; must
    ///         update the drawer and flip its exportability bit to private_.
    ///
    /// Mirrors Rust `palace_bridge::tests::exportability_change_not_skipped`.
    @Test("exportability public→private change on unchanged content is not skipped (codex 7c952932)")
    func exportabilityChangeNotSkipped() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        // Step 1: import with exportability=public.
        let publicPalace = try makePalaceDir(exportabilityLabel: "public")
        defer { try? FileManager.default.removeItem(at: publicPalace) }

        let first = try await bridge.importPalace(at: publicPalace, into: handle, now: now)
        #expect(first.drawersWritten == 1, "first import must write the drawer")
        #expect(first.drawersSkippedUnchanged == 0)

        let drawersAfterFirst = try await currentDrawersAll(kit: kit, handle: handle)
        #expect(drawersAfterFirst.count == 1)
        #expect(
            drawersAfterFirst[0].exportability == .public_,
            "drawer must be public_ after first import (exportability:public)"
        )

        // Step 2: re-import with same content but exportability=private.
        // The skip guard must NOT suppress this update.
        let privatePalace = try makePalaceDir(exportabilityLabel: "private")
        defer { try? FileManager.default.removeItem(at: privatePalace) }

        let second = try await bridge.importPalace(at: privatePalace, into: handle, now: now)
        #expect(
            second.drawersSkippedUnchanged == 0,
            "exportability public→private must NOT be skipped: \(second)"
        )
        #expect(
            second.drawersUpdated == 1,
            "exportability-only change must produce drawersUpdated=1"
        )

        // Verify the exportability bit flipped to private_.
        let drawersAfterSecond = try await currentDrawersAll(kit: kit, handle: handle)
        #expect(drawersAfterSecond.count == 1)
        #expect(
            drawersAfterSecond[0].exportability == .private_,
            "drawer must be private_ after re-import with exportability:private"
        )
    }

    /// Idempotency companion to `exportabilityChangeNotSkipped`: when both content
    /// and exportability are truly unchanged on re-import the skip guard must fire.
    ///
    /// This test uses a fresh two-step estate (no superseded predecessors) so the
    /// tombstone set is empty and `drawersSkippedUnchanged` is the only path that
    /// can absorb the row.
    ///
    /// Mirrors Rust `palace_bridge::tests::unchanged_exportability_skipped`.
    @Test("re-import with unchanged exportability is counted as skipped-unchanged")
    func unchangedExportabilitySkipped() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        // Step 1: import with exportability=private.
        let palace = try makePalaceDir(exportabilityLabel: "private")
        defer { try? FileManager.default.removeItem(at: palace) }

        let first = try await bridge.importPalace(at: palace, into: handle, now: now)
        #expect(first.drawersWritten == 1, "first import must write the drawer")

        // Step 2: re-import same palace (same content, same exportability=private).
        // Nothing changed — the skip guard must fire. The estate has exactly one
        // active drawer and no superseded predecessors, so the tombstone set is
        // empty and the unchanged guard is the only matching path.
        let second = try await bridge.importPalace(at: palace, into: handle, now: now)
        #expect(
            second.drawersSkippedUnchanged == 1,
            "truly-unchanged re-import must be counted as skipped-unchanged: \(second)"
        )
        #expect(second.drawersUpdated == 0)
    }

    // MARK: - Report receipt

    @Test("importPalace files a diary receipt entry under VaultBridge.receiptAgentName")
    func receiptEntry() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        _ = try await bridge.importPalace(
            at: Self.fixturePalaceURL, into: handle, now: now
        )

        // Verify a diary entry was filed under the vault receipt agent name.
        let entries = try await kit.readDiaryEntries(
            in: handle, agentName: VaultBridge.receiptAgentName
        )
        #expect(entries.contains { $0.topic == "vault-receipt" })
    }
}
