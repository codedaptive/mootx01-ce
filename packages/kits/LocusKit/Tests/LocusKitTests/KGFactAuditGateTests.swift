// KGFactAuditGateTests.swift
//
// Gate: `DrawerStore.withdrawKGFact` routes through `AuditGate.admit`
// (verb `.retract`, active → withdrawn) and writes a sealed audit row.
//
// Four cases, exercising the two key derivation branches and the two
// lattice-anchor branches. Cases 1 and 3 run on both InMemory and SQLite
// backends (persistence parity); Cases 2 and 4 run on InMemory (the code
// path under test is backend-agnostic).
//
//  Case 1 (InMemory + SQLite): NON-UUID id, ANCHORED — exercises the SHA-256
//    branch of deterministicRowKey and the udcQid lattice-anchor branch.
//    UUID(uuidString:) returning nil is asserted in the test body so a reader
//    can see the SHA-256 branch is the one under test. A regression in either
//    branch makes this RED.
//
//  Case 2 (InMemory): UUID id — exercises the UUID passthrough branch of
//    deterministicRowKey. rowId must equal the original UUID unchanged.
//
//  Case 3 (InMemory + SQLite): UNANCHORED — empty sourceDrawerID produces a
//    null anchor; both halves must be 0.
//
//  Case 4 (InMemory): Anchor drawer absent — sourceDrawerID names a drawer
//    not in the estate; retirement must succeed with a null anchor rather
//    than throwing.
//
//  Validation (InMemory): empty changedBy is rejected by the input guard.
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
import Testing
@testable import LocusKit

/// Gate tests proving `DrawerStore.withdrawKGFact` emits a correctly keyed
/// and correctly populated audit row on both backends, with discrimination
/// proofs for the SHA-256 row-key branch, the udcQid anchor branch, the
/// null-anchor branch, and the absent-drawer fallback.
@Suite("KGFactAuditGateTests")
struct KGFactAuditGateTests {

    // MARK: - Constants

    private let actor    = "kgfact-audit-gate-test"
    private let reason   = "gate-test-retirement"
    private let filedAt  = Date(timeIntervalSince1970: 1_700_000_000)
    private let now      = Date(timeIntervalSince1970: 1_700_000_100)

    // Non-UUID fact id for Case 1 — exercises the SHA-256 branch of
    // deterministicRowKey. Must not parse as UUID (asserted in each test).
    private let nonUUIDFactID = "fact-not-a-uuid-2"

    // UDC and QID used to build the source drawer for Cases 1 and 4.
    private let drawerUDC = "gate-test-udc-001"
    private let drawerQID = "Q99999"

    // MARK: - Helpers

    private func makeInMemoryStore() async throws -> DrawerStore {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        return try await DrawerStore(storage: storage)
    }

    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locuskit-kgfact-audit-gate-\(UUID().uuidString).sqlite")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeSQLiteStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    /// Insert an anchored source drawer (udcCode + wikidataQID) into the store.
    /// Returns the drawer's id so the caller can use it as sourceDrawerID on a fact.
    private func insertAnchoredDrawer(
        id: String = UUID().uuidString,
        into store: DrawerStore
    ) async throws -> String {
        let drawer = Drawer(
            id: id,
            content: "anchor drawer content",
            parentNodeId: "test-parent",
            addedBy: "gate-test",
            filedAt: filedAt,
            embeddingModelID: "test-model-v1",
            udcCode: drawerUDC,
            wikidataQID: drawerQID
        )
        try await store.addDrawer(drawer, now: filedAt)
        return id
    }

    // MARK: - Case 1: NON-UUID id, ANCHORED (InMemory)

    /// Case 1A — InMemory: a fact whose id is NOT a UUID string produces a
    /// SHA-256-derived rowId; a fact linked to an anchored drawer produces a
    /// non-null udcQid lattice anchor on the emitted audit event.
    ///
    /// Each assertion is a separate #expect so a failure names the field:
    ///  - UUID(uuidString: nonUUIDFactID) == nil  (SHA-256 branch confirmation)
    ///  - rowId == deterministicRowKey(from: nonUUIDFactID)
    ///  - verb == "retract"
    ///  - afterLatticeAnchor.udcCode == expected
    ///  - afterLatticeAnchor.qidPointer == expected (and != 0)
    ///  - reason == the string passed in
    ///  - actor == changedBy
    ///  - afterBitmaps.adjective & 0x3F == 18 (State.withdrawn)
    ///  - exactly one event for the row key
    @Test("KGFactAuditGate Case1A InMemory: non-UUID id + anchored drawer")
    func testCase1A_inMemory_nonUUIDIdAnchored() async throws {
        let store = try await makeInMemoryStore()
        let drawerID = try await insertAnchoredDrawer(into: store)

        // Confirm the id is NOT a UUID — proves the SHA-256 branch is exercised.
        #expect(UUID(uuidString: nonUUIDFactID) == nil,
                "fact-not-a-uuid-2 must not parse as a UUID string — SHA-256 branch is the one under test")

        let fact = KGFact(
            id: nonUUIDFactID,
            subject: "gate-test-subject",
            predicate: "is_about",
            object: "gate-test-object",
            sourceDrawerID: drawerID,
            addedBy: "gate-test-setup",
            filedAt: filedAt
        )
        try await store.addKGFact(fact)
        try await store.withdrawKGFact(
            id: nonUUIDFactID, changedBy: actor, reason: reason, now: now
        )

        let rowKey = RowKeyDerivation.deterministicRowKey(from: nonUUIDFactID)
        let events = try await store.auditEventsForRow(rowKey)

        #expect(events.count == 1,
                "exactly one audit event must be written for the SHA-256-derived row key")
        let event = try #require(events.first)
        #expect(event.rowId == rowKey,
                "rowId must equal deterministicRowKey(from: non-UUID id) — SHA-256 branch")
        #expect(event.verb == "retract",
                "verb must be 'retract' (RowVerb.retract rawValue)")

        // Lattice anchor: both halves must match the expected udcQid anchor.
        // qidPointer must be non-zero so the null-anchor branch cannot pass silently.
        let expectedAnchor = LatticeAnchor.udcQid(drawerUDC, qid: drawerQID)
        #expect(event.afterLatticeAnchor.udcCode == expectedAnchor.udcCode,
                "afterLatticeAnchor.udcCode must equal LatticeAnchor.udcQid(drawerUDC, qid: drawerQID).udcCode")
        #expect(event.afterLatticeAnchor.qidPointer == expectedAnchor.qidPointer,
                "afterLatticeAnchor.qidPointer must equal LatticeAnchor.udcQid anchor's qidPointer")
        #expect(event.afterLatticeAnchor.qidPointer != 0,
                "qidPointer must be non-zero for a drawer with a non-empty wikidataQID — confirms udcQid branch, not null-anchor branch")

        #expect(event.reason == reason,
                "reason must be threaded through to the audit row")
        #expect(event.actor == actor,
                "actor must equal the changedBy parameter")
        #expect(event.afterBitmaps.adjective & 0x3F == 18,
                "adjective bits 0-5 must equal State.withdrawn.rawValue (18)")
    }

    // MARK: - Case 1: NON-UUID id, ANCHORED (SQLite)

    /// Case 1B — SQLite: same assertions as Case 1A, verifying that the
    /// PersistenceKit SQLite backend durably stores the event and that the
    /// SHA-256 row key and udcQid anchor survive the SQLite round-trip.
    @Test("KGFactAuditGate Case1B SQLite: non-UUID id + anchored drawer")
    func testCase1B_sqlite_nonUUIDIdAnchored() async throws {
        let (store, url) = try await makeSQLiteStore()
        defer { cleanup(url) }
        let drawerID = try await insertAnchoredDrawer(into: store)

        #expect(UUID(uuidString: nonUUIDFactID) == nil,
                "fact-not-a-uuid-2 must not parse as a UUID string — SHA-256 branch is the one under test")

        let fact = KGFact(
            id: nonUUIDFactID,
            subject: "gate-test-subject",
            predicate: "is_about",
            object: "gate-test-object",
            sourceDrawerID: drawerID,
            addedBy: "gate-test-setup",
            filedAt: filedAt
        )
        try await store.addKGFact(fact)
        try await store.withdrawKGFact(
            id: nonUUIDFactID, changedBy: actor, reason: reason, now: now
        )

        let rowKey = RowKeyDerivation.deterministicRowKey(from: nonUUIDFactID)
        let events = try await store.auditEventsForRow(rowKey)

        #expect(events.count == 1,
                "exactly one audit event must be written (SQLite backend)")
        let event = try #require(events.first)
        #expect(event.rowId == rowKey,
                "rowId must equal deterministicRowKey(from: non-UUID id) — SHA-256 branch (SQLite)")
        #expect(event.verb == "retract",
                "verb must be 'retract' (SQLite backend)")

        let expectedAnchor = LatticeAnchor.udcQid(drawerUDC, qid: drawerQID)
        #expect(event.afterLatticeAnchor.udcCode == expectedAnchor.udcCode,
                "afterLatticeAnchor.udcCode must equal udcQid anchor (SQLite)")
        #expect(event.afterLatticeAnchor.qidPointer == expectedAnchor.qidPointer,
                "afterLatticeAnchor.qidPointer must equal udcQid anchor's qidPointer (SQLite)")
        #expect(event.afterLatticeAnchor.qidPointer != 0,
                "qidPointer must be non-zero for a drawer with a non-empty wikidataQID (SQLite)")

        #expect(event.reason == reason,
                "reason must be threaded through (SQLite)")
        #expect(event.actor == actor,
                "actor must equal changedBy (SQLite)")
        #expect(event.afterBitmaps.adjective & 0x3F == 18,
                "adjective bits 0-5 must equal State.withdrawn.rawValue (SQLite)")
    }

    // MARK: - Case 2: UUID id (UUID passthrough)

    /// Case 2 — UUID id: when the fact's id IS a well-formed UUID string,
    /// `deterministicRowKey` must return that UUID unchanged (UUID passthrough
    /// branch, no SHA-256 derivation). The rowId in the audit event must equal
    /// the original UUID, not a re-derived value.
    @Test("KGFactAuditGate Case2: UUID id — rowId equals original UUID unchanged")
    func testCase2_uuidIdPassthrough() async throws {
        let store = try await makeInMemoryStore()

        let uuidFactID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        // Confirm the id IS a UUID — UUID passthrough branch is the one under test.
        let parsedUUID = try #require(UUID(uuidString: uuidFactID),
                                      "test setup: uuidFactID must be a valid UUID string")

        let fact = KGFact(
            id: uuidFactID,
            subject: "uuid-passthrough-subject",
            predicate: "is_about",
            object: "uuid-passthrough-object",
            sourceDrawerID: "",
            addedBy: "gate-test-setup",
            filedAt: filedAt
        )
        try await store.addKGFact(fact)
        try await store.withdrawKGFact(
            id: uuidFactID, changedBy: actor, reason: nil, now: now
        )

        let rowKey = RowKeyDerivation.deterministicRowKey(from: uuidFactID)
        let events = try await store.auditEventsForRow(rowKey)

        #expect(events.count == 1,
                "exactly one audit event must be written")
        let event = try #require(events.first)
        // UUID passthrough: rowId must equal the parsed UUID, not a SHA-256 derivative.
        #expect(event.rowId == parsedUUID,
                "rowId must equal the original UUID unchanged (UUID passthrough branch)")
    }

    // MARK: - Case 3: UNANCHORED (InMemory)

    /// Case 3A — InMemory: a fact with an empty sourceDrawerID takes the
    /// null-anchor branch; the audit event must carry udcCode 0 and
    /// qidPointer 0. The retirement must succeed (null anchors are valid).
    @Test("KGFactAuditGate Case3A InMemory: empty sourceDrawerID — null anchor, both halves 0")
    func testCase3A_inMemory_unanchored() async throws {
        let store = try await makeInMemoryStore()

        let factID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let fact = KGFact(
            id: factID,
            subject: "unanchored-subject",
            predicate: "is_about",
            object: "unanchored-object",
            sourceDrawerID: "",   // empty → null anchor
            addedBy: "gate-test-setup",
            filedAt: filedAt
        )
        try await store.addKGFact(fact)
        try await store.withdrawKGFact(
            id: factID, changedBy: actor, reason: nil, now: now
        )

        let rowKey = RowKeyDerivation.deterministicRowKey(from: factID)
        let events = try await store.auditEventsForRow(rowKey)

        #expect(events.count == 1,
                "exactly one audit event must be written (unanchored fact)")
        let event = try #require(events.first)
        #expect(event.afterLatticeAnchor.udcCode == 0,
                "afterLatticeAnchor.udcCode must be 0 (null anchor — empty sourceDrawerID)")
        #expect(event.afterLatticeAnchor.qidPointer == 0,
                "afterLatticeAnchor.qidPointer must be 0 (null anchor — empty sourceDrawerID)")
    }

    // MARK: - Case 3: UNANCHORED (SQLite)

    /// Case 3B — SQLite: same null-anchor assertions as Case 3A, verifying
    /// that the SQLite backend stores and retrieves the null anchor correctly.
    @Test("KGFactAuditGate Case3B SQLite: empty sourceDrawerID — null anchor, both halves 0")
    func testCase3B_sqlite_unanchored() async throws {
        let (store, url) = try await makeSQLiteStore()
        defer { cleanup(url) }

        let factID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let fact = KGFact(
            id: factID,
            subject: "unanchored-subject-sqlite",
            predicate: "is_about",
            object: "unanchored-object-sqlite",
            sourceDrawerID: "",
            addedBy: "gate-test-setup",
            filedAt: filedAt
        )
        try await store.addKGFact(fact)
        try await store.withdrawKGFact(
            id: factID, changedBy: actor, reason: nil, now: now
        )

        let rowKey = RowKeyDerivation.deterministicRowKey(from: factID)
        let events = try await store.auditEventsForRow(rowKey)

        #expect(events.count == 1,
                "exactly one audit event must be written (unanchored fact, SQLite)")
        let event = try #require(events.first)
        #expect(event.afterLatticeAnchor.udcCode == 0,
                "afterLatticeAnchor.udcCode must be 0 (null anchor — empty sourceDrawerID, SQLite)")
        #expect(event.afterLatticeAnchor.qidPointer == 0,
                "afterLatticeAnchor.qidPointer must be 0 (null anchor — empty sourceDrawerID, SQLite)")
    }

    // MARK: - Case 4: Anchor drawer absent

    /// Case 4 — the anchor drawer is absent: `sourceDrawerID` names a drawer
    /// id not present in the estate. The retirement must succeed (graceful
    /// fallback to null anchor) rather than throwing. Both anchor halves must
    /// be 0, matching the null-anchor fallback branch in `withdrawKGFact`.
    @Test("KGFactAuditGate Case4: sourceDrawerID names absent drawer — null anchor, succeeds")
    func testCase4_absentSourceDrawer() async throws {
        let store = try await makeInMemoryStore()

        let factID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let absentDrawerID = UUID().uuidString   // never inserted into the estate
        let fact = KGFact(
            id: factID,
            subject: "absent-drawer-subject",
            predicate: "is_about",
            object: "absent-drawer-object",
            sourceDrawerID: absentDrawerID,
            addedBy: "gate-test-setup",
            filedAt: filedAt
        )
        try await store.addKGFact(fact)

        // Must succeed: absent drawer falls back to null anchor, does not throw.
        try await store.withdrawKGFact(
            id: factID, changedBy: actor, reason: nil, now: now
        )

        let rowKey = RowKeyDerivation.deterministicRowKey(from: factID)
        let events = try await store.auditEventsForRow(rowKey)

        #expect(events.count == 1,
                "exactly one audit event must be written (absent source drawer)")
        let event = try #require(events.first)
        // Absent drawer → null anchor fallback.
        #expect(event.afterLatticeAnchor.udcCode == 0,
                "afterLatticeAnchor.udcCode must be 0 (absent drawer fallback to null anchor)")
        #expect(event.afterLatticeAnchor.qidPointer == 0,
                "afterLatticeAnchor.qidPointer must be 0 (absent drawer fallback to null anchor)")
    }

    // MARK: - Validation: empty changedBy

    /// Input-validation test: passing an empty changedBy is rejected by the
    /// pre-gate input guard before the transaction opens. No audit row is written
    /// and the fact remains active (adjective bits 0-5 == 0).
    @Test("KGFactAuditGate Validation: empty changedBy throws LocusKitError")
    func testValidation_emptyChangedByThrows() async throws {
        let store = try await makeInMemoryStore()
        let factID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let fact = KGFact(
            id: factID,
            subject: "validation-subject",
            predicate: "is_about",
            object: "validation-object",
            sourceDrawerID: "",
            addedBy: "gate-test-setup",
            filedAt: filedAt
        )
        try await store.addKGFact(fact)

        await #expect(throws: LocusKitError.self) {
            try await store.withdrawKGFact(id: factID, changedBy: "", reason: nil, now: now)
        }

        let loaded = try #require(try await store.getKGFact(id: factID))
        #expect(loaded.adjectiveBitmap & 0x3F == 0,
                "adjective bits 0-5 must remain 0 (active) after a rejected withdrawal")
    }
}
