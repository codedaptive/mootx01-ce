// ProjectionTests.swift
//
// Column projection contract tests (R2, CVK-ICLOUD P2-M2).
//
// Coverage:
//   1. Projection.outboundStrip: pure strip semantics
//   2. Projection.isAllExcluded: predicate semantics
//   3. All-excluded update does NOT enqueue (storm kill)
//   4. Partial exclusion enqueues (update with a non-excluded column goes out)
//   5. Delete is unaffected by projection (always enqueues)
//   6. Inbound excluded columns are dropped before apply (peer on old manifest)
//   7. Manifest round-trip: excludedColumns survives JSON encode/decode

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Pure helper tests

@Suite("Projection.outboundStrip")
struct OutboundStripTests {

    @Test("strips listed columns from values")
    func stripsExcludedColumns() {
        let id = UUID()
        let values: [String: TypedValue] = [
            "id":    .uuid(id),
            "score": .float(0.9),
            "label": .text("hello"),
            "cache": .text("cached"),
        ]
        let result = Projection.outboundStrip(values: values, excluded: ["score", "cache"])
        #expect(result["id"] != nil)
        #expect(result["label"] != nil)
        #expect(result["score"] == nil)
        #expect(result["cache"] == nil)
    }

    @Test("empty excluded set returns values unchanged")
    func emptyExcludedReturnsOriginal() {
        let values: [String: TypedValue] = ["id": .uuid(UUID()), "body": .text("x")]
        let result = Projection.outboundStrip(values: values, excluded: [])
        #expect(result.count == values.count)
        #expect(result["body"] != nil)
    }

    @Test("absent excluded keys are silently ignored")
    func absentExcludedKeysIgnored() {
        let values: [String: TypedValue] = ["id": .uuid(UUID())]
        let result = Projection.outboundStrip(values: values, excluded: ["nonexistent"])
        #expect(result.count == 1)
        #expect(result["id"] != nil)
    }

    @Test("all columns stripped yields empty map")
    func allColumnsStripped() {
        let values: [String: TypedValue] = ["score": .float(0.8), "cache": .text("x")]
        let result = Projection.outboundStrip(values: values, excluded: ["score", "cache"])
        #expect(result.isEmpty)
    }
}

@Suite("Projection.isAllExcluded")
struct IsAllExcludedTests {

    @Test("returns true when every key is excluded")
    func allExcludedReturnsTrue() {
        let values: [String: TypedValue] = ["score": .float(0.8), "cache": .text("x")]
        #expect(Projection.isAllExcluded(values: values, excluded: ["score", "cache"]))
    }

    @Test("returns false when some keys are not excluded")
    func partialExclusionReturnsFalse() {
        let values: [String: TypedValue] = ["id": .uuid(UUID()), "score": .float(0.8)]
        #expect(!Projection.isAllExcluded(values: values, excluded: ["score"]))
    }

    @Test("returns false when excluded set is empty")
    func emptyExcludedReturnsFalse() {
        let values: [String: TypedValue] = ["score": .float(0.8)]
        #expect(!Projection.isAllExcluded(values: values, excluded: []))
    }

    @Test("returns false when values map is empty")
    func emptyValuesReturnsFalse() {
        #expect(!Projection.isAllExcluded(values: [:], excluded: ["score"]))
    }

    @Test("returns true even when excluded set is a superset of values")
    func supersetExcludedReturnsTrue() {
        let values: [String: TypedValue] = ["score": .float(0.8)]
        #expect(Projection.isAllExcluded(values: values, excluded: ["score", "cache", "derived"]))
    }
}

@Suite("Projection.isStormKill")
struct IsStormKillTests {

    @Test("returns true when only PK remains after strip")
    func onlyPKRemainsIsStormKill() {
        // Full-row observer scenario: storage emits {id, score, cache}.
        // After outboundStrip(excluded: ["score", "cache"]) → {id}.
        let stripped: [String: TypedValue] = ["id": .uuid(UUID())]
        #expect(Projection.isStormKill(stripped: stripped, primaryKeyColumn: "id"))
    }

    @Test("returns false when non-PK content remains after strip")
    func nonPKContentIsNotStormKill() {
        // Non-excluded 'body' survived the strip.
        let stripped: [String: TypedValue] = ["id": .uuid(UUID()), "body": .text("hello")]
        #expect(!Projection.isStormKill(stripped: stripped, primaryKeyColumn: "id"))
    }

    @Test("returns true when stripped map is empty")
    func emptyStrippedIsStormKill() {
        #expect(Projection.isStormKill(stripped: [:], primaryKeyColumn: "id"))
    }

    @Test("returns false when PK is absent (non-PK-keyed row)")
    func pkAbsentIsNotStormKill() {
        // PK is not in the stripped map — non-PK values remain.
        let stripped: [String: TypedValue] = ["body": .text("hello")]
        #expect(!Projection.isStormKill(stripped: stripped, primaryKeyColumn: "id"))
    }
}

// MARK: - Enforcement tests (Federation engine, single-engine outbound focus)

@Suite("Projection enforcement — outbound (Federation)")
struct FederationOutboundProjectionTests {

    // MARK: Helpers

    /// Storage for the "all-excluded storm kill" test: schema has only id + excluded cols.
    /// After stripping ["score", "cache"], only the PK ("id") remains → storm kill fires.
    func makeStorageExcludedOnly() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ProjStormKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .float("score"), .text("cache")],
                    primaryKey: ["id"]
                )
            ]
        ))
        return storage
    }

    func makeManifestExcludedOnly() -> SyncManifest {
        SyncManifest(
            kitID: "ProjStormKit",
            schemaVersion: 1,
            zoneIdentifier: "proj-zone",
            tables: [
                SyncedTable(
                    name: "items",
                    primaryKeyColumn: "id",
                    conflictPolicy: .lastWriterWinsByHLC,
                    excludedColumns: ["score", "cache"]
                )
            ]
        )
    }

    /// Storage for partial-exclusion and delete tests: 4-column schema with a non-excluded "body" col.
    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ProjTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("body"), .float("score"), .text("cache")],
                    primaryKey: ["id"]
                )
            ]
        ))
        return storage
    }

    func makeManifest(excludedColumns: Set<String> = []) -> SyncManifest {
        SyncManifest(
            kitID: "ProjTestKit",
            schemaVersion: 1,
            zoneIdentifier: "proj-zone",
            tables: [
                SyncedTable(
                    name: "items",
                    primaryKeyColumn: "id",
                    conflictPolicy: .lastWriterWinsByHLC,
                    excludedColumns: excludedColumns
                )
            ]
        )
    }

    /// Push until a non-zero pushed count is seen or the deadline passes.
    /// Needed because the storage observer fires asynchronously; the outbox
    /// is populated across at least one Task hop after a write.
    func pushUntilNonzero(_ engine: FederationSyncEngine, deadline: TimeInterval = 2.0) async throws -> Int {
        let cutoff = Date().addingTimeInterval(deadline)
        while true {
            let pushed = try await engine.push().pushed
            if pushed > 0 || Date() >= cutoff { return pushed }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: All-excluded update → storm kill

    @Test("update with all-excluded columns does not enter the outbox")
    func allExcludedUpdateDoesNotEnqueue() async throws {
        // Schema: id (PK) + score (excluded) + cache (excluded).
        // After stripping ["score", "cache"], only id remains → isStormKill fires.
        // A 4-column schema with a non-excluded "body" col would NOT storm-kill
        // because after stripping, "body" would remain as non-PK content.
        let storage = try await makeStorageExcludedOnly()
        let manifest = makeManifestExcludedOnly()
        let relay = FederationRelay()
        let engine = FederationSyncEngine(relay: relay)
        let peer = FederationSyncEngine(relay: relay)
        let peerStorage = try await makeStorageExcludedOnly()
        try await peer.enable(manifest: manifest, storage: peerStorage)
        try await engine.enable(manifest: manifest, storage: storage)
        try await engine.pair(with: peer, family: HyperplaneFamilySpec(seed: 0xA1))
        defer { Task { try? await engine.disable(); try? await peer.disable() } }

        let rowID = UUID()
        // Full insert: observer fires, outbox populated.
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "score": .float(0.5), "cache": .text("c1")],
            conflictColumns: ["id"]
        )
        let insertPushed = try await pushUntilNonzero(engine)
        #expect(insertPushed >= 1, "initial insert must push at least one record")

        // Update ONLY excluded columns: score and cache.
        // Storage emits the full merged row {id, score, cache}. After stripping
        // ["score", "cache"], only {id} remains. isStormKill(stripped: {id}, pk: "id")
        // returns true → recordOutbound returns without enqueue.
        _ = try await storage.rowStore.update(
            table: "items",
            values: ["score": .float(0.99), "cache": .text("c2")],
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )

        // Give the observer Task 150ms to run — if the storm kill is broken,
        // the update will appear in the outbox; if it works, nothing will.
        try await Task.sleep(nanoseconds: 150_000_000)

        let updatePushed = try await engine.push().pushed
        #expect(updatePushed == 0,
            "all-excluded update must not enter the outbox (storm kill) — got \(updatePushed) pushed")
    }

    // MARK: Partial exclusion still enqueues

    @Test("update with some non-excluded columns still enqueues a stripped record")
    func partialExclusionStillEnqueues() async throws {
        let storage = try await makeStorage()
        let manifest = makeManifest(excludedColumns: ["score", "cache"])
        let relay = FederationRelay()
        let engine = FederationSyncEngine(relay: relay)
        let peer = FederationSyncEngine(relay: relay)
        let peerStorage = try await makeStorage()
        try await peer.enable(manifest: manifest, storage: peerStorage)
        try await engine.enable(manifest: manifest, storage: storage)
        try await engine.pair(with: peer, family: HyperplaneFamilySpec(seed: 0xA2))
        defer { Task { try? await engine.disable(); try? await peer.disable() } }

        let rowID = UUID()
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "body": .text("original"), "score": .float(0.5), "cache": .text("c1")],
            conflictColumns: ["id"]
        )
        let insertPushed = try await pushUntilNonzero(engine)
        #expect(insertPushed >= 1)

        // Update 'body' (non-excluded) + 'score' (excluded).
        // The record enters the outbox because body is non-excluded; score is stripped.
        _ = try await storage.rowStore.update(
            table: "items",
            values: ["body": .text("updated"), "score": .float(0.99)],
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        let updatePushed = try await pushUntilNonzero(engine)
        #expect(updatePushed >= 1,
            "update with a non-excluded column must still enqueue — partial exclusion only strips, not suppresses")
    }

    // MARK: Delete unaffected

    @Test("delete is enqueued even when excludedColumns covers all app columns")
    func deleteUnaffectedByProjection() async throws {
        let storage = try await makeStorage()
        // Exclude everything except the PK — as aggressive as possible.
        let manifest = makeManifest(excludedColumns: ["body", "score", "cache"])
        let relay = FederationRelay()
        let engine = FederationSyncEngine(relay: relay)
        let peer = FederationSyncEngine(relay: relay)
        let peerStorage = try await makeStorage()
        try await peer.enable(manifest: manifest, storage: peerStorage)
        try await engine.enable(manifest: manifest, storage: storage)
        try await engine.pair(with: peer, family: HyperplaneFamilySpec(seed: 0xA3))
        defer { Task { try? await engine.disable(); try? await peer.disable() } }

        let rowID = UUID()
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "body": .text("x"), "score": .float(1.0), "cache": .text("y")],
            conflictColumns: ["id"]
        )
        _ = try await pushUntilNonzero(engine)

        // Delete the row.
        _ = try await storage.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )

        // The delete must appear in the outbox — tombstones must propagate
        // regardless of excludedColumns (storm kill only applies to updates).
        let deletePushed = try await pushUntilNonzero(engine)
        #expect(deletePushed >= 1,
            "delete must enter the outbox and push regardless of excludedColumns — tombstone propagation required for GC")
    }
}

// MARK: - Inbound projection (peer sends columns we exclude)

@Suite("Projection enforcement — inbound (Federation)")
struct FederationInboundProjectionTests {

    func makeStorage(kitID: String) async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: kitID,
            version: 1,
            tables: [
                TableDeclaration(
                    name: "records",
                    columns: [.uuid("id"), .text("name"), .float("derived")],
                    primaryKey: ["id"]
                )
            ]
        ))
        return storage
    }

    func pushUntilCount(_ engine: FederationSyncEngine, target: Int, deadline: TimeInterval = 2.0) async throws -> Int {
        let cutoff = Date().addingTimeInterval(deadline)
        var total = 0
        while total < target, Date() < cutoff {
            total += try await engine.push().pushed
            if total < target { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        return total
    }

    @Test("inbound excluded columns are dropped — peer-sent derived value does not overwrite local")
    func inboundExcludedColumnNotWritten() async throws {
        // Sender: no exclusions — it pushes every column including 'derived'.
        let senderStorage = try await makeStorage(kitID: "InboundProjKit")
        let senderManifest = SyncManifest(
            kitID: "InboundProjKit",
            schemaVersion: 1,
            zoneIdentifier: "inbound-zone",
            tables: [SyncedTable(
                name: "records",
                primaryKeyColumn: "id",
                conflictPolicy: .lastWriterWinsByHLC
            )]
        )

        // Receiver: excludes 'derived' — it recomputes that column locally.
        let receiverStorage = try await makeStorage(kitID: "InboundProjKit")
        let receiverManifest = SyncManifest(
            kitID: "InboundProjKit",
            schemaVersion: 1,
            zoneIdentifier: "inbound-zone",
            tables: [SyncedTable(
                name: "records",
                primaryKeyColumn: "id",
                conflictPolicy: .lastWriterWinsByHLC,
                excludedColumns: ["derived"]
            )]
        )

        let relay = FederationRelay()
        let sender = FederationSyncEngine(relay: relay)
        let receiver = FederationSyncEngine(relay: relay)

        try await sender.enable(manifest: senderManifest, storage: senderStorage)
        try await receiver.enable(manifest: receiverManifest, storage: receiverStorage)
        try await sender.pair(with: receiver, family: HyperplaneFamilySpec(seed: 0xB1))
        defer { Task { try? await sender.disable(); try? await receiver.disable() } }

        let rowID = UUID()

        // Receiver pre-populates its row with a locally-computed derived value (99.0).
        // Use the sync-tagged write so it does NOT enter the outbox — this row is
        // receiver-local and should not be pushed back to sender.
        _ = try await receiverStorage.rowStore.upsertSync(
            table: "records",
            values: ["id": .uuid(rowID), "name": .text(""), "derived": .float(99.0)],
            conflictColumns: ["id"]
        )

        // Sender inserts the row with name="Alice" and derived=42.0.
        // Because sender writes AFTER receiver's syncApply-tagged write, sender's
        // HLC will be newer — LWW will favour sender's 'name' value. But the
        // inbound projection must drop 'derived' before the policy switch, so
        // receiver's 'derived' stays at 99.0.
        _ = try await senderStorage.rowStore.upsert(
            table: "records",
            values: ["id": .uuid(rowID), "name": .text("Alice"), "derived": .float(42.0)],
            conflictColumns: ["id"]
        )

        let pushed = try await pushUntilCount(sender, target: 1)
        #expect(pushed >= 1, "sender must push the row")

        _ = try await receiver.pull()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify receiver's state:
        //   'name'    must be "Alice" (non-excluded, inbound value applied by LWW)
        //   'derived' must remain 99.0 (excluded, inbound value was dropped before apply)
        let rows = try await receiverStorage.rowStore.query(
            table: "records",
            where: .eq(Column(table: "records", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "receiver must have the row")
        if let row = rows.first {
            if case .text(let name) = row["name"] {
                #expect(name == "Alice",
                    "non-excluded column 'name' must be applied from inbound record")
            } else {
                Issue.record("'name' column missing or wrong type in receiver row")
            }
            if case .float(let derived) = row["derived"] {
                #expect(derived == 99.0,
                    "excluded column 'derived' must not be overwritten by inbound record; expected 99.0, got \(derived)")
            } else {
                Issue.record("'derived' column missing or wrong type in receiver row")
            }
        }
    }
}

// MARK: - Manifest round-trip

@Suite("SyncedTable.excludedColumns — Codable round-trip")
struct ExcludedColumnsRoundTripTests {

    @Test("excludedColumns survives JSON encode/decode")
    func roundTripWithExcludedColumns() throws {
        let table = SyncedTable(
            name: "items",
            primaryKeyColumn: "id",
            excludedColumns: ["score", "cache", "derived"]
        )
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(SyncedTable.self, from: data)
        #expect(decoded.excludedColumns == ["score", "cache", "derived"])
        #expect(decoded.name == "items")
    }

    @Test("JSON without excludedColumns decodes with empty set (backward compat)")
    func missingExcludedColumnsDecodesAsEmpty() throws {
        // JSON from before excludedColumns was added — key absent entirely.
        let json = """
        {"name":"notes","direction":"bidirectional","primaryKeyColumn":"id","conflictPolicy":"lastWriterWinsByHLC"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SyncedTable.self, from: json)
        #expect(decoded.excludedColumns.isEmpty,
            "a legacy JSON payload without excludedColumns must decode to an empty set, not fail")
    }

    @Test("empty excludedColumns is omitted from JSON (wire compaction)")
    func emptyExcludedColumnsOmittedFromJSON() throws {
        let table = SyncedTable(name: "notes", primaryKeyColumn: "id")
        let data = try JSONEncoder().encode(table)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("excludedColumns"),
            "empty excludedColumns must not appear in the JSON payload — reduces wire size for the common case")
    }

    // SyncManifest is no longer Codable (P2-M3: the postApplyIntegrityHook
    // closure cannot be encoded), so the round-trip contract lives on
    // SyncedTable, which remains Codable and carries excludedColumns.
    @Test("synced tables with excludedColumns round-trip through JSON")
    func syncedTableRoundTrip() throws {
        let tables = [
            SyncedTable(
                name: "items",
                primaryKeyColumn: "id",
                excludedColumns: ["score"]
            ),
            SyncedTable(name: "log", primaryKeyColumn: "event_id"),
        ]
        let data = try JSONEncoder().encode(tables)
        let decoded = try JSONDecoder().decode([SyncedTable].self, from: data)
        let manifest = SyncManifest(
            kitID: "TestKit",
            schemaVersion: 3,
            zoneIdentifier: "zone-1",
            tables: decoded
        )
        #expect(manifest.table(named: "items")?.excludedColumns == ["score"])
        #expect(manifest.table(named: "log")?.excludedColumns.isEmpty == true)
    }
}
