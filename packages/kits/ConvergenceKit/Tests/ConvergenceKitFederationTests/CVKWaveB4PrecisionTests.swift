// CVKWaveB4PrecisionTests.swift
//
// Force-tests for CVK-WB4 precision behaviors:
//
//   1. Mixed-column storm-kill (Scorandum Q1): when changedColumns is present
//      and every changed column is excluded, recordOutbound returns without
//      enqueuing — even when the merged row snapshot carries non-changed sync
//      columns that survive the strip. Zero outbox entries.
//
//   2. fieldLevelLWW column stamp precision: when the sender stamps ONLY
//      changedColumns in columnHLCs, the receiver applies ONLY those columns.
//      Columns present in the row snapshot but not in columnHLCs retain their
//      local values (the precision stamp prevents false HLC advancement).
//
// CVK-WB4 summary:
//   - PersistenceKit backends now stamp changedColumns on TableChange.
//   - ConvergenceKit uses changedColumns to kill mixed-column derived-value
//     rewrites and to stamp only actually-changed columns in fieldLevelLWW records.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Test 1: Mixed-column storm-kill precision (Scorandum Q1)

@Suite("CVK-WB4: mixed-column storm-kill precision (Scorandum Q1)")
struct MixedColumnStormKillTests {

    /// Schema: id (PK), title (sync — NOT excluded), score (excluded derived).
    /// The mixed-column case: a score recompute emits the full merged row including
    /// title (which was not actually changed). Old behavior: isStormKill returns false
    /// because title survived the strip → outbox polluted. New behavior: changedColumns
    /// = {"score"} → allSatisfy(excluded) → precision kill → zero outbox entries.
    func makeMixedStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ScoranoumQ1Kit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("title"), .float("score")],
                    primaryKey: ["id"]
                )
            ]
        ))
        return storage
    }

    /// Manifest: score is excluded; title is a sync column.
    func makeMixedManifest() -> SyncManifest {
        SyncManifest(
            kitID: "ScoranoumQ1Kit",
            schemaVersion: 1,
            zoneIdentifier: "q1-zone",
            tables: [
                SyncedTable(
                    name: "items",
                    primaryKeyColumn: "id",
                    conflictPolicy: .lastWriterWinsByHLC,
                    excludedColumns: ["score"]
                )
            ]
        )
    }

    func pushUntilNonzero(_ engine: FederationSyncEngine, deadline: TimeInterval = 2.0) async throws -> Int {
        let cutoff = Date().addingTimeInterval(deadline)
        while true {
            let pushed = try await engine.push().pushed
            if pushed > 0 || Date() >= cutoff { return pushed }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("score-only update on mixed-column table is storm-killed (Scorandum Q1)")
    func mixedColumnScoreOnlyUpdateIsStormKilled() async throws {
        let storage = try await makeMixedStorage()
        let manifest = makeMixedManifest()
        let relay = FederationRelay()
        let engine = FederationSyncEngine(relay: relay)
        let peer = FederationSyncEngine(relay: relay)
        let peerStorage = try await makeMixedStorage()
        try await peer.enable(manifest: manifest, storage: peerStorage)
        try await engine.enable(manifest: manifest, storage: storage)
        try await engine.pair(with: peer, family: HyperplaneFamilySpec(seed: 0xC1))
        defer { Task { try? await engine.disable(); try? await peer.disable() } }

        let rowID = UUID()

        // Insert with both title and score. Observer fires; outbox gets the entry.
        // title is stripped from the outbox? No — only score is excluded. title ships.
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "title": .text("Hello"), "score": .float(0.5)],
            conflictColumns: ["id"]
        )
        let insertPushed = try await pushUntilNonzero(engine)
        #expect(insertPushed >= 1, "initial insert must push at least one record")

        // Now update ONLY score (derived recompute pattern — Scorandum Q1).
        // InMemory backend stamps changedColumns = {"score"} on this notification.
        // The precision storm-kill checks: changedColumns.allSatisfy(excluded.contains)
        // → {"score"}.allSatisfy(["score"].contains) → true → storm kill.
        //
        // OLD behavior (pre-CVK-WB4): the merged row has {id, title, score}; after
        // stripping ["score"] → {id, title}; isStormKill(pk: "id") returns false
        // because title survived → entry would be enqueued (WRONG for a pure-score recompute).
        _ = try await storage.rowStore.update(
            table: "items",
            values: ["score": .float(0.99)],
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )

        // Give the observer 150ms to run. If storm-kill is broken, the update will be queued.
        try await Task.sleep(nanoseconds: 150_000_000)

        let updatePushed = try await engine.push().pushed
        #expect(updatePushed == 0,
            "score-only update must be storm-killed by changedColumns precision (Scorandum Q1) — got \(updatePushed) pushed")
    }

    @Test("update with both changed score AND changed title still enqueues (no false kill)")
    func mixedChangedUpdateStillEnqueues() async throws {
        // Regression: when BOTH an excluded AND a non-excluded column change,
        // the entry must NOT be storm-killed — the sync column change must propagate.
        let storage = try await makeMixedStorage()
        let manifest = makeMixedManifest()
        let relay = FederationRelay()
        let engine = FederationSyncEngine(relay: relay)
        let peer = FederationSyncEngine(relay: relay)
        let peerStorage = try await makeMixedStorage()
        try await peer.enable(manifest: manifest, storage: peerStorage)
        try await engine.enable(manifest: manifest, storage: storage)
        try await engine.pair(with: peer, family: HyperplaneFamilySpec(seed: 0xC2))
        defer { Task { try? await engine.disable(); try? await peer.disable() } }

        let rowID = UUID()
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "title": .text("Original"), "score": .float(0.5)],
            conflictColumns: ["id"]
        )
        _ = try await pushUntilNonzero(engine)

        // Update BOTH title (sync) and score (excluded). changedColumns = {"title", "score"}.
        // changedColumns.allSatisfy(excluded.contains) → false (title is not excluded)
        // → NOT storm-killed. The entry ships with title included.
        _ = try await storage.rowStore.update(
            table: "items",
            values: ["title": .text("Updated"), "score": .float(0.99)],
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )

        let updatePushed = try await pushUntilNonzero(engine)
        #expect(updatePushed >= 1,
            "update with a non-excluded sync column must NOT be storm-killed — got \(updatePushed) pushed")
    }
}

// MARK: - Test 2: changedColumns propagation through recordOutbound

@Suite("CVK-WB4: changedColumns propagation through recordOutbound")
struct ChangedColumnsPropagationTests {

    /// changedColumns must be passed through strippedChange in recordOutbound
    /// so push() can use it for precision fieldLevelLWW stamping.
    /// This test verifies the propagation via the FederationStateActor's
    /// pendingOutbound queue.
    @Test("recordOutbound propagates changedColumns to strippedChange")
    func recordOutboundPropagatesChangedColumns() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "PropKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("title"), .text("body")],
                    primaryKey: ["id"]
                )
            ]
        ))

        let manifest = SyncManifest(
            kitID: "PropKit",
            schemaVersion: 1,
            zoneIdentifier: "prop-zone",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id",
                                 conflictPolicy: .fieldLevelLWW)]
        )

        let actor = FederationStateActor()
        try await actor.enable(manifest: manifest, storage: storage, relay: FederationRelay())
        defer { Task { await actor.disable() } }

        let rowID = UUID()

        // Inject a TableChange with changedColumns = {"title"} directly into
        // the actor's recordOutbound method. This simulates what PersistenceKit
        // emits after a title-only update (CVK-WB4).
        let change = TableChange(
            table: "items",
            event: .update,
            rowKey: rowID,
            values: ["id": .uuid(rowID), "title": .text("new-title"), "body": .text("old-body")],
            hlc: nil,
            origin: .local,
            changedColumns: Set(["title"])
        )

        await actor.recordOutbound(change)

        // WC2: changedColumns now manifests in the durable outbox (_fed_outbox) as
        // the columnHLCs map on the stored SyncRecord — only "title" is stamped,
        // not "body". The old assertion checked pendingOutbound[0].changedColumns;
        // the new assertion checks the SyncRecord's columnHLCs.entries.
        //
        // Because recordOutbound is `async` and FedOutboxStore.append is awaited
        // inside it, the outbox entry is present by the time this await returns.
        let outboxCount = try await FedOutboxStore.count(
            from: storage, table: "_fed_outbox")
        #expect(outboxCount == 1, "one outbox entry must be appended for the change")

        // Decode the stored SyncRecord and verify columnHLCs covers only "title".
        let entries = try await FedOutboxStore.readBatch(from: storage, table: "_fed_outbox")
        let firstEntry = try #require(entries.first, "outbox entry must be readable")
        let record = try JSONDecoder().decode(SyncRecord.self, from: firstEntry.payload)
        let columnKeys = record.columnHLCs.map { Set($0.entries.keys) } ?? Set<String>()
        #expect(columnKeys == Set(["title"]),
            "precision fieldLevelLWW stamping must stamp only 'title', not 'body' (changedColumns propagated)")
    }
}
