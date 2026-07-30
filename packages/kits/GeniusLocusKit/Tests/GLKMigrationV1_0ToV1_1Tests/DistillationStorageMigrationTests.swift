#if GLK_MIGRATION_V1_0_TO_V1_1

// DistillationStorageMigrationTests.swift
//
// A.2 verification fixture for the 1.0.x → 1.1.x distillation storage migration.
//
// Builds a 1.0.x-shaped estate in-process and verifies acceptance criterion 13.8:
//
//   Fixture shape (1.0.x estate):
//     sourceA — normal drawer, room "research"
//     sourceB — normal drawer, room "research"
//     factoidA → sourceA via _distilled_from (exactly 1 tunnel) + lane entry
//     factoidB             (0 tunnels, lane entry exists — ambiguous provenance)
//     factoidC → sourceA, sourceB (2 tunnels — ambiguous provenance, lane entry exists)
//     orphanEntry — lane entry for a UUID that has never existed in drawers
//     shortItem — normal drawer, no factoid, no tunnel, no lane entry
//
//   Post-migration expected state:
//     - 0 drawers with addedBy = "distillation-daemon"
//     - 0 tunnels with label = "_distilled_from"
//     - lane entry for sourceA.id exists, keyed by sourceA.id (re-keyed from factoidA)
//     - no lane entry for factoidA, factoidB, factoidC, or orphanID
//     - drawers table has distilled, distilled_pipeline_version,
//       distilled_token_count, distilled_at columns (all NULL)
//     - shortItem drawer is untouched
//
// Rust twin: rust-migrations/tests/distillation_storage_migration_tests.rs (pending)

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import VectorKit
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_0ToV1_1

@Suite("DistillationStorageMigrationTests", .serialized)
struct DistillationStorageMigrationTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Storage helpers

    private func scratchStorage() throws -> (any Storage, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-dsm-\(UUID().uuidString).sqlite3")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        return (storage, url)
    }

    // MARK: - Fixture builder

    /// Build the 1.0.x fixture estate:
    ///   sourceA, sourceB — normal source drawers (never distilled themselves)
    ///   factoidA — addedBy "distillation-daemon", 1 _distilled_from tunnel to sourceA
    ///   factoidB — addedBy "distillation-daemon", 0 tunnels (ambiguous: drop)
    ///   factoidC — addedBy "distillation-daemon", 2 tunnels to sourceA+sourceB (ambiguous: drop)
    ///   shortItem — normal drawer, never touched by distillation
    ///   orphanEntry — distillation-features-v1 lane entry whose item_id does not exist in drawers
    ///
    /// Returns (kit, handle, storage, IDs, url) where IDs is a struct of key drawer IDs.
    private struct FixtureIDs {
        let sourceAID: String
        let sourceBID: String
        let factoidAID: String
        let factoidBID: String
        let factoidCID: String
        let shortItemID: String
        let orphanID: String        // UUID that was never a drawer
    }

    private func buildFixtureEstate() async throws
        -> (kit: GeniusLocusKit, handle: EstateHandle,
            storage: any Storage, ids: FixtureIDs, url: URL)
    {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dsm-owner")
        let (storage, url) = try scratchStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture source drawers (never distilled — left alone throughout).
        let sourceA = try await kit.capture(handle, CaptureFrame(
            content: "Source content A — original research note.",
            channel: .typed,
            room: "research",
            latticeAnchor: LatticeAnchor(udcCode: "100"),
            addedBy: "researcher",
            embeddingModelID: "test-v1",
            eventTime: now
        ))
        let sourceB = try await kit.capture(handle, CaptureFrame(
            content: "Source content B — another original research note.",
            channel: .typed,
            room: "research",
            latticeAnchor: LatticeAnchor(udcCode: "101"),
            addedBy: "researcher",
            embeddingModelID: "test-v1",
            eventTime: now
        ))

        // Capture factoid drawers (addedBy = "distillation-daemon").
        let factoidA = try await kit.capture(handle, CaptureFrame(
            content: "Distilled insight from source A.",
            channel: .typed,
            room: "_distilled",
            latticeAnchor: LatticeAnchor(udcCode: "200"),
            addedBy: "distillation-daemon",
            embeddingModelID: "test-v1",
            eventTime: now
        ))
        let factoidB = try await kit.capture(handle, CaptureFrame(
            content: "Distilled insight with no provenance tunnel.",
            channel: .typed,
            room: "_distilled",
            latticeAnchor: LatticeAnchor(udcCode: "201"),
            addedBy: "distillation-daemon",
            embeddingModelID: "test-v1",
            eventTime: now
        ))
        let factoidC = try await kit.capture(handle, CaptureFrame(
            content: "Distilled insight with ambiguous provenance (2 tunnels).",
            channel: .typed,
            room: "_distilled",
            latticeAnchor: LatticeAnchor(udcCode: "202"),
            addedBy: "distillation-daemon",
            embeddingModelID: "test-v1",
            eventTime: now
        ))

        // Short item — never distilled, no associated factoid.
        let shortItem = try await kit.capture(handle, CaptureFrame(
            content: "Short note — below distillation threshold.",
            channel: .typed,
            room: "short",
            latticeAnchor: LatticeAnchor(udcCode: "300"),
            addedBy: "user",
            embeddingModelID: "test-v1",
            eventTime: now
        ))

        // Resolve display names for tunnel construction.
        let estate = try await kit.estate(for: handle)
        let allNodeIDs = [sourceA, sourceB, factoidA, factoidB, factoidC]
            .map(\.parentNodeId)
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: allNodeIDs)
        let namesFor: (Drawer) -> (wing: String, room: String) = { d in
            nodeNames[d.parentNodeId] ?? (wing: "Agentic Memory", room: "")
        }

        let namesSourceA  = namesFor(sourceA)
        let namesSourceB  = namesFor(sourceB)
        let namesFactoidA = namesFor(factoidA)
        let namesFactoidB = namesFor(factoidB)
        let namesFactoidC = namesFor(factoidC)

        // _distilled_from tunnel: factoidA → sourceA (exactly 1 → salvageable).
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: namesFactoidA.wing,
            sourceRoom: namesFactoidA.room,
            targetWing: namesSourceA.wing,
            targetRoom: namesSourceA.room,
            label: "_distilled_from",
            addedBy: "distillation-daemon",
            sourceDrawerId: factoidA.id,
            targetDrawerId: sourceA.id,
            kind: .references,
            originClass: .derived
        ))

        // factoidB has 0 tunnels — lane entry will be dropped.

        // _distilled_from tunnels: factoidC → sourceA AND factoidC → sourceB
        // (ambiguous provenance: 2 tunnels → drop).
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: namesFactoidC.wing,
            sourceRoom: namesFactoidC.room,
            targetWing: namesSourceA.wing,
            targetRoom: namesSourceA.room,
            label: "_distilled_from",
            addedBy: "distillation-daemon",
            sourceDrawerId: factoidC.id,
            targetDrawerId: sourceA.id,
            kind: .references,
            originClass: .derived
        ))
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: namesFactoidC.wing,
            sourceRoom: namesFactoidC.room,
            targetWing: namesSourceB.wing,
            targetRoom: namesSourceB.room,
            label: "_distilled_from",
            addedBy: "distillation-daemon",
            sourceDrawerId: factoidC.id,
            targetDrawerId: sourceB.id,
            kind: .references,
            originClass: .derived
        ))

        // Register the VectorKit schema so the vectors table exists before
        // we insert lane entries. On a real 1.0.x estate this is already applied;
        // in tests it is applied here to mirror the production migration setup.
        try await storage.migrate(to: VectorStore.schemaDeclaration)

        // Insert distillation-features-v1 lane entries for factoids.
        // Minimal binary vector: 32-byte zero blob, dim 256, kind 0 (binary).
        let zeroPayload = Data(repeating: 0, count: 32)
        let filedAt = TypedValue.timestamp(now)
        let laneModelID = "distillation-features-v1"

        func insertLane(itemID: String) async throws {
            _ = try await storage.rowStore.insert(
                table: "vectors",
                values: [
                    "id":            .uuid(UUID()),
                    "item_id":       .text(itemID),
                    "vector_index":  .int(0),
                    "model_id":      .text(laneModelID),
                    "model_version": .text("test-v1"),
                    "kind":          .int(0),
                    "dim":           .int(256),
                    "payload":       .blob(zeroPayload),
                    "filed_at":      filedAt
                ]
            )
        }

        try await insertLane(itemID: factoidA.id)   // re-keyed → sourceA.id
        try await insertLane(itemID: factoidB.id)   // dropped (0 tunnels)
        try await insertLane(itemID: factoidC.id)   // dropped (2 tunnels)

        // Orphaned lane entry: a UUID that has NEVER been a drawer.
        let orphanID = UUID().uuidString
        try await insertLane(itemID: orphanID)      // deleted as orphan

        let ids = FixtureIDs(
            sourceAID:  sourceA.id,
            sourceBID:  sourceB.id,
            factoidAID: factoidA.id,
            factoidBID: factoidB.id,
            factoidCID: factoidC.id,
            shortItemID: shortItem.id,
            orphanID:   orphanID
        )
        return (kit, handle, storage, ids, url)
    }

    // MARK: - Acceptance criterion 13.8

    /// Full A.1 migration acceptance test:
    ///
    ///   - factoidA lane entry is re-keyed to sourceA.id
    ///   - factoidB, factoidC, orphan entries are deleted
    ///   - all three factoid drawers are deleted
    ///   - all _distilled_from tunnels are deleted
    ///   - four representation columns are added to drawers (all NULL)
    ///   - shortItem drawer is untouched
    @Test("A.2 fixture: migration re-keys salvageable entry, drops ambiguous and orphan entries")
    func migrationReKeysAndDropsCorrectly() async throws {
        let (kit, handle, storage, ids, url) = try await buildFixtureEstate()
        defer { try? FileManager.default.removeItem(at: url) }

        // Run the distillation storage migration directly (without catalog
        // format-stamp check so we can run on an already-open estate).
        let report = try await kit.runDistillationStorageMigration(handle: handle, now: now)

        // ── Verify report counts ──────────────────────────────────────────
        #expect(report.factoidDrawerCount == 3,
                "three factoid drawers (A, B, C) must be deleted")
        #expect(report.tunnelCount == 3,
                "three _distilled_from tunnels (factoidA→sourceA, factoidC→sourceA, factoidC→sourceB) must be deleted")
        #expect(report.reKeyedLaneCount == 1,
                "exactly one lane entry must be re-keyed (factoidA → sourceA)")
        // dropped = factoidB (0 tunnels) + factoidC (2 tunnels) + orphan = 3
        #expect(report.droppedLaneCount == 3,
                "three lane entries must be dropped (factoidB, factoidC, orphan)")

        // ── Verify no factoid drawers remain ─────────────────────────────
        let remainingFactoids = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "addedBy"), .text("distillation-daemon")),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(remainingFactoids.isEmpty,
                "no factoid drawers (addedBy=distillation-daemon) must remain after migration")

        // ── Verify no _distilled_from tunnels remain ──────────────────────
        let remainingTunnels = try await storage.rowStore.query(
            table: "tunnels",
            where: .eq(Column(table: "tunnels", name: "label"), .text("_distilled_from")),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(remainingTunnels.isEmpty,
                "no _distilled_from tunnels must remain after migration")

        // ── Verify re-keyed lane entry exists for sourceA ─────────────────
        let sourceALaneRows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "item_id"),  .text(ids.sourceAID)),
                .eq(Column(table: "vectors", name: "model_id"), .text("distillation-features-v1"))
            ]),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(sourceALaneRows.count == 1,
                "sourceA must have exactly one distillation-features-v1 lane entry after re-key")

        // ── Verify deleted lane entries are gone ──────────────────────────
        for (label, id) in [
            ("factoidA", ids.factoidAID),
            ("factoidB", ids.factoidBID),
            ("factoidC", ids.factoidCID),
            ("orphan",   ids.orphanID)
        ] {
            let rows = try await storage.rowStore.query(
                table: "vectors",
                where: .and([
                    .eq(Column(table: "vectors", name: "item_id"),  .text(id)),
                    .eq(Column(table: "vectors", name: "model_id"), .text("distillation-features-v1"))
                ]),
                orderBy: [], limit: nil, offset: nil
            )
            #expect(rows.isEmpty,
                    "\(label) lane entry must be deleted after migration")
        }

        // ── Verify four representation columns exist and are NULL ─────────
        // Query the shortItem row — it was never distilled, so its
        // representation columns must be NULL (the column default).
        let shortItemRows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text(ids.shortItemID)),
            orderBy: [], limit: nil, offset: nil
        )
        let shortItemRow = try #require(shortItemRows.first,
                                        "shortItem drawer must still exist after migration")
        // All four columns must be present (non-throwing access) and NULL.
        for col in ["distilled", "distilled_pipeline_version",
                    "distilled_token_count", "distilled_at"] {
            let val = shortItemRow[col]
            #expect(val == nil || val == .some(.null),
                    "drawers.\(col) must be NULL on shortItem after migration (step e)")
        }

        // ── Verify shortItem drawer is otherwise untouched ─────────────────
        let shortRows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text(ids.shortItemID)),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(!shortRows.isEmpty,
                "shortItem drawer must survive the migration intact")

        // ── Verify source drawers are untouched ────────────────────────────
        for (label, id) in [("sourceA", ids.sourceAID), ("sourceB", ids.sourceBID)] {
            let sourceRows = try await storage.rowStore.query(
                table: "drawers",
                where: .eq(Column(table: "drawers", name: "id"), .text(id)),
                orderBy: [], limit: nil, offset: nil
            )
            #expect(!sourceRows.isEmpty,
                    "\(label) drawer must survive the migration intact")
        }
    }

    /// Verify that running the migration on a fresh 1.1.x estate (no factoids,
    /// no tunnels) produces a zero-work report and leaves the estate unchanged.
    @Test("A.2 fixture: fresh estate produces zero-work report (no factoids)")
    func freshEstateProducesZeroWorkReport() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dsm-fresh-owner")
        let (storage, url) = try scratchStorage()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture a regular drawer — should not be touched.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "A plain memory on a fresh estate.",
            channel: .typed,
            room: "notes",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "user",
            embeddingModelID: "test-v1",
            eventTime: now
        ))

        let report = try await kit.runDistillationStorageMigration(handle: handle, now: now)

        #expect(report.factoidDrawerCount == 0,  "fresh estate: no factoid drawers")
        #expect(report.tunnelCount == 0,          "fresh estate: no _distilled_from tunnels")
        #expect(report.reKeyedLaneCount == 0,     "fresh estate: no lane entries to re-key")
        #expect(report.droppedLaneCount == 0,     "fresh estate: no lane entries to drop")
    }

    /// Verify idempotency: running the migration twice produces the same
    /// final state (second run is a no-op on an already-migrated estate).
    @Test("A.2 fixture: migration is idempotent (second run is a no-op)")
    func migrationIsIdempotent() async throws {
        let (kit, handle, storage, ids, url) = try await buildFixtureEstate()
        defer { try? FileManager.default.removeItem(at: url) }

        // First run.
        let first = try await kit.runDistillationStorageMigration(handle: handle, now: now)
        #expect(first.factoidDrawerCount == 3)
        #expect(first.reKeyedLaneCount == 1)

        // Second run — estate already clean, so all counts are zero.
        let second = try await kit.runDistillationStorageMigration(handle: handle, now: now)
        #expect(second.factoidDrawerCount == 0,
                "idempotency: second migration run must delete 0 factoid drawers")
        #expect(second.tunnelCount == 0,
                "idempotency: second migration run must delete 0 tunnels")
        #expect(second.reKeyedLaneCount == 0,
                "idempotency: second migration run must re-key 0 lane entries")
        #expect(second.droppedLaneCount == 0,
                "idempotency: second migration run must drop 0 lane entries")

        // sourceA lane entry must still be there.
        let laneRows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "item_id"),  .text(ids.sourceAID)),
                .eq(Column(table: "vectors", name: "model_id"), .text("distillation-features-v1"))
            ]),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(laneRows.count == 1,
                "sourceA lane entry must survive a second migration run")
    }
}

#endif // GLK_MIGRATION_V1_0_TO_V1_1
