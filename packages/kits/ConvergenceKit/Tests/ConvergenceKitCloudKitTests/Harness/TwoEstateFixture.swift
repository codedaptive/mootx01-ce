// TwoEstateFixture.swift
//
// Two-estate concurrent simulation fixture for CVK-ICLOUD P4-M1.
// Provisions two CloudKitSyncEngines backed by separate InMemoryStorage
// instances and a shared CloudZoneFake that acts as the common "cloud".
//
// Injection pattern:
//   CloudKitStateActor._testDatabase is set (via the actor extension below)
//   BEFORE enable() is called on each engine. enable() then uses the injected
//   fake instead of resolving container.privateCloudDatabase.
//
// Poll-deadline pattern (no Task.sleep):
//   writeLocal waits for the outbox to grow using a ContinuousClock deadline
//   + Task.yield() loop. This is the same pattern used throughout the test
//   suite to avoid flakiness from timing dependencies.
//
// HLC ordering for LWW scenarios:
//   advanceClock(by:) on CloudKitStateActor advances the HLC generator
//   without sleeping, establishing happens-before ordering between estates.
//   Used by scenario (b) to ensure estate A writes with a strictly higher HLC.
//
// Converged state assertion:
//   assertSyncMetaMatch(table:) reads _ck_sync_meta on both estates and
//   verifies both have the same set of (primary_key, sync_hlc, is_deleted)
//   tuples — the definitive convergence proof because the meta table
//   persists HLCs for all synced rows (including tombstone entries, A6).

import Foundation
import CloudKit
import Testing
import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import ConvergenceKitCloudKit

// MARK: - CloudKitStateActor test extensions

/// Extensions that expose test-only seams on CloudKitStateActor.
/// These run on the actor's executor (actor isolation preserved) so
/// property mutations are safe without additional locking.
extension CloudKitStateActor {

    /// Inject a test database before enable(). Must be called before enable().
    func setTestDatabase(_ db: any CloudKitDatabaseProtocol) {
        _testDatabase = db
    }

    /// Advance the HLC generator by `millis` milliseconds without sleeping.
    /// Used to establish HLC ordering between writes on different estates
    /// (e.g. scenario (b): estate A writes with a higher HLC than estate B).
    func advanceClock(by millis: Int64) {
        _ = hlcGenerator.send(now: nowMillis() + millis)
    }
}

// MARK: - ConvergenceReport

/// Summary of push/pull counts across a runConvergence() call.
struct ConvergenceReport: Sendable {
    let pushedA: Int
    let pushedB: Int
    let pulledA: Int
    let pulledB: Int
    var totalPushed: Int { pushedA + pushedB }
    var totalPulled: Int { pulledA + pulledB }
}

// MARK: - FixtureError

/// Errors thrown by TwoEstateFixture helpers.
enum FixtureError: Error {
    /// writeLocal timed out waiting for the outbox to reflect the write.
    case outboxTimeoutAfterWrite(table: String)
    /// assertConverged found mismatched sync-meta entries.
    case convergenceMismatch(detail: String)
}

// MARK: - TwoEstateFixture

/// Two CloudKit sync estates sharing one CloudZoneFake "cloud".
///
/// Estate A and Estate B each have their own InMemoryStorage and
/// CloudKitSyncEngine. Both engines inject the same CloudZoneFake so
/// all push and pull cycles go through a single in-process record store.
///
/// Lifecycle: call setUp() once before tests, then writeLocal / runConvergence
/// / assertSyncMetaMatch in any combination.
actor TwoEstateFixture {

    // MARK: - Manifest and schema

    /// The sync manifest shared by both estates.
    /// kitID="TestKit", zone="CVK-ICLOUD-P4", table="items" (bidirectional, LWW).
    static let manifest = SyncManifest(
        kitID: "TestKit",
        schemaVersion: 1,
        zoneIdentifier: "CVK-ICLOUD-P4",
        tables: [
            SyncedTable(
                name: "items",
                direction: .bidirectional,
                primaryKeyColumn: "id",
                conflictPolicy: .lastWriterWinsByHLC
            )
        ]
    )

    /// The zone identifier used by both estates.
    static let zoneID = CKRecordZone.ID(
        zoneName: manifest.zoneIdentifier,
        ownerName: CKCurrentUserDefaultName
    )

    /// Open InMemoryStorage with the test app schema (items table + side tables).
    static func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        ColumnDeclaration(name: "title",  type: .text, nullable: true),
                        ColumnDeclaration(name: "value",  type: .int,  nullable: true),
                    ],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return storage
    }

    // MARK: - Estates

    let cloud: CloudZoneFake
    let engineA: CloudKitSyncEngine
    let storageA: any Storage
    let engineB: CloudKitSyncEngine
    let storageB: any Storage

    // MARK: - Init and setUp

    /// Create a fresh fixture with two engines sharing a new CloudZoneFake.
    /// Call setUp() after creating to inject fakes and call enable().
    init(storageA: any Storage, storageB: any Storage, cloud: CloudZoneFake) {
        self.cloud = cloud
        self.storageA = storageA
        self.storageB = storageB
        // Both engines use nil containerIdentifier — the real container is never
        // resolved because _testDatabase overrides it before enable().
        self.engineA = CloudKitSyncEngine(containerIdentifier: nil)
        self.engineB = CloudKitSyncEngine(containerIdentifier: nil)
    }

    /// Inject the shared fake and call enable() on both engines.
    func setUp() async throws {
        // Inject the fake BEFORE enable() so enable()'s `let db = _testDatabase ?? ...`
        // picks up the fake instead of resolving the real container.
        await engineA.stateActor.setTestDatabase(cloud)
        try await engineA.enable(manifest: Self.manifest, storage: storageA)

        await engineB.stateActor.setTestDatabase(cloud)
        try await engineB.enable(manifest: Self.manifest, storage: storageB)
    }

    // MARK: - Convenience factory

    /// Build a fresh, fully-enabled TwoEstateFixture.
    static func make() async throws -> TwoEstateFixture {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let cloud    = CloudZoneFake()
        let fixture  = TwoEstateFixture(storageA: storageA, storageB: storageB, cloud: cloud)
        try await fixture.setUp()
        return fixture
    }

    // MARK: - writeLocal

    /// Write (upsert) a row into an estate's local storage and wait (poll-deadline,
    /// no Task.sleep) for the outbox entry to appear.
    ///
    /// The observer in CloudKitStateActor fires asynchronously after the upsert.
    /// The poll loop yields the executor and re-checks until the outbox grows
    /// (indicating the observer ran and appended the entry) or 5 seconds pass.
    func writeLocal(
        to engine: CloudKitSyncEngine,
        storage: any Storage,
        table: String = "items",
        row: [String: TypedValue]
    ) async throws {
        let before = try await OutboxStore.readBatch(from: storage).count

        // Local write (non-sync origin): triggers the storage observer which
        // calls recordOutbound on the engine's actor, appending to the outbox.
        _ = try await storage.rowStore.upsert(
            table: table,
            values: row,
            conflictColumns: ["id"]
        )

        // Poll-deadline: wait for the outbox to reflect the write.
        // ContinuousClock.now < deadline satisfies the "no Task.sleep" constraint.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            await Task.yield()
            let current = try await OutboxStore.readBatch(from: storage).count
            if current > before { return }
        }
        throw FixtureError.outboxTimeoutAfterWrite(table: table)
    }

    /// Convenience: write to estate A.
    func writeA(table: String = "items", row: [String: TypedValue]) async throws {
        try await writeLocal(to: engineA, storage: storageA, table: table, row: row)
    }

    /// Convenience: write to estate B.
    func writeB(table: String = "items", row: [String: TypedValue]) async throws {
        try await writeLocal(to: engineB, storage: storageB, table: table, row: row)
    }

    // MARK: - runConvergence

    /// Run `rounds` push-push-pull-pull cycles (A pushes, B pushes, A pulls, B pulls).
    /// Yields briefly before each push to let observer tasks process pending writes.
    /// Returns a ConvergenceReport with per-estate push/pull counts.
    @discardableResult
    func runConvergence(rounds: Int = 2) async throws -> ConvergenceReport {
        var pushedA = 0, pushedB = 0, pulledA = 0, pulledB = 0

        for _ in 0..<rounds {
            // Yield multiple times to let the storage observer tasks run before push.
            // The observer appends outbox entries asynchronously after each upsert;
            // these yields let it complete before we drain the outbox via push().
            for _ in 0..<20 { await Task.yield() }

            let rA = try await engineA.push()
            let rB = try await engineB.push()
            let pA = try await engineA.pull()
            let pB = try await engineB.pull()

            pushedA += rA.pushed
            pushedB += rB.pushed
            pulledA += pA.pulled
            pulledB += pB.pulled
        }

        return ConvergenceReport(pushedA: pushedA, pushedB: pushedB,
                                 pulledA: pulledA, pulledB: pulledB)
    }

    // MARK: - outbox helpers

    /// Current outbox entry count for estate A (excludes parked entries).
    func outboxCountA() async throws -> Int {
        try await OutboxStore.readBatch(from: storageA).count
    }

    /// Current outbox entry count for estate B (excludes parked entries).
    func outboxCountB() async throws -> Int {
        try await OutboxStore.readBatch(from: storageB).count
    }

    // MARK: - _ck_sync_meta helpers

    /// Read _ck_sync_meta rows for `table` on estate A.
    /// Returns [StorageRow] — the native PersistenceKit row type.
    func syncMetaA(table: String) async throws -> [StorageRow] {
        try await storageA.rowStore.query(
            table: "_ck_sync_meta",
            where: .eq(Column(table: "_ck_sync_meta", name: "table_name"), .text(table))
        )
    }

    /// Read _ck_sync_meta rows for `table` on estate B.
    func syncMetaB(table: String) async throws -> [StorageRow] {
        try await storageB.rowStore.query(
            table: "_ck_sync_meta",
            where: .eq(Column(table: "_ck_sync_meta", name: "table_name"), .text(table))
        )
    }

    // MARK: - User-table helpers

    /// Query a specific row from estate A's user table by primary key.
    ///
    /// CKRecord round-trip caveat: `CKRecordMapping.assign(.uuid(u))` stores
    /// the UUID as an NSString. `typedValue(from:)` decodes it back as
    /// `.text(u.uuidString)`, not `.uuid(u)`. So:
    ///   • locally-written rows  → `id: .uuid(id)` (PersistenceKit stores the
    ///                              TypedValue as written)
    ///   • pulled rows           → `id: .text(id.uuidString)` (CKRecord loss)
    /// Try `.text` first (the typical case for pulled rows in harness tests),
    /// then fall back to `.uuid` for locally-written rows.
    func queryA(table: String = "items", id: UUID) async throws -> StorageRow? {
        let textRows = try await storageA.rowStore.query(
            table: table,
            where: .eq(Column(table: table, name: "id"), .text(id.uuidString))
        )
        if !textRows.isEmpty { return textRows.first }
        return try await storageA.rowStore.query(
            table: table,
            where: .eq(Column(table: table, name: "id"), .uuid(id))
        ).first
    }

    /// Query a specific row from estate B's user table by primary key.
    /// See `queryA(table:id:)` for the CKRecord UUID→text round-trip caveat.
    func queryB(table: String = "items", id: UUID) async throws -> StorageRow? {
        let textRows = try await storageB.rowStore.query(
            table: table,
            where: .eq(Column(table: table, name: "id"), .text(id.uuidString))
        )
        if !textRows.isEmpty { return textRows.first }
        return try await storageB.rowStore.query(
            table: table,
            where: .eq(Column(table: table, name: "id"), .uuid(id))
        ).first
    }

    // MARK: - Crash / restart simulation

    /// Simulate an estate crash and restart by disabling the given engine
    /// and creating a fresh CloudKitSyncEngine backed by the same Storage instance.
    ///
    /// Models process death and restart:
    ///   - engine.disable() cancels observer tasks and clears in-memory state.
    ///   - A fresh CloudKitSyncEngine is constructed (no retained in-memory queue).
    ///   - enable(manifest:storage:) on the fresh engine re-loads the durable outbox
    ///     leftovers (drainLeftovers), restores the server change token, and re-claims
    ///     a slot — exactly what production does on process restart.
    ///   - InMemoryStorage keeps its actor's in-memory tables alive across the
    ///     disable/enable cycle, equivalent to disk-backed storage surviving a restart.
    ///
    /// Returns the fresh engine. Callers substitute it for the old engine reference.
    func restartEngine(_ engine: CloudKitSyncEngine, storage: any Storage) async throws -> CloudKitSyncEngine {
        try await engine.disable()
        let fresh = CloudKitSyncEngine(containerIdentifier: nil)
        await fresh.stateActor.setTestDatabase(cloud)
        try await fresh.enable(manifest: Self.manifest, storage: storage)
        return fresh
    }

    // MARK: - assertSyncMetaMatch

    /// Assert that both estates have identical _ck_sync_meta entries for `table`.
    ///
    /// Convergence proof: the side table records the HLC of every synced row on
    /// each estate. Identical side tables mean both estates applied the same
    /// records in the same LWW order. Comparison is by primary_key sort so
    /// insertion order does not affect the result.
    func assertSyncMetaMatch(table: String) async throws {
        let metaA = try await syncMetaA(table: table)
        let metaB = try await syncMetaB(table: table)

        func primaryKey(of row: StorageRow) -> String {
            if case .text(let s) = row["primary_key"] { return s }
            return ""
        }
        let sortedA = metaA.sorted { primaryKey(of: $0) < primaryKey(of: $1) }
        let sortedB = metaB.sorted { primaryKey(of: $0) < primaryKey(of: $1) }

        #expect(sortedA.count == sortedB.count,
                "sync-meta row counts differ: A=\(sortedA.count) B=\(sortedB.count)")

        for (a, b) in zip(sortedA, sortedB) {
            #expect(a["primary_key"] == b["primary_key"],
                    "sync-meta primary_key mismatch: \(String(describing: a["primary_key"])) vs \(String(describing: b["primary_key"]))")
            #expect(a["sync_hlc"] == b["sync_hlc"],
                    "sync-meta HLC mismatch for key \(primaryKey(of: a)): A=\(String(describing: a["sync_hlc"])) B=\(String(describing: b["sync_hlc"]))")
            #expect(a["is_deleted"] == b["is_deleted"],
                    "sync-meta is_deleted mismatch for key \(primaryKey(of: a))")
        }
    }
}
