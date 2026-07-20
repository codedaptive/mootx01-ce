// FieldLevelLWWDeleteRealMagnitudeTests.swift
//
// Gap 6 regression test for the CK-delete regression Kong found while
// auditing the narrow (column-store-only) version of this fix: a
// column-only widening makes local column HLCs full-width while the
// row-grain tombstone HLC arriving via the (then still-truncated)
// OutboxEntry/_ck_sync_meta carrier stays truncated — reproducing the
// truncated-vs-lossless mismatch one level up, in the OPPOSITE direction
// (a genuinely NEWER delete could look "not newer enough" against an
// artificially-inflated local column HLC, or the reverse). D38.1 widened
// the fix to every carrier atomically specifically to close this.
//
// This test proves, at REAL HLC magnitude, on `.fieldLevelLWW` tables:
//   (a) a genuinely NEWER tombstone correctly HARD-DELETES the row
//       (deletes actually apply — Kong's regression, now closed).
//   (b) a genuinely OLDER (stale) tombstone is correctly REJECTED —
//       edit-beats-delete still holds at real magnitude (not just always-
//       reject or always-accept from a magnitude mismatch).
//
// ISOLATION NOTE: both scenarios are gated by
// `FieldLWWMerge.tombstoneWins(tombstoneHLC:localColumnHLCs:)`, which
// compares against COLUMN-grain HLCs (`ColumnHLCStore.readAll`) — fixed
// earlier in this same pass, alongside CloudKit's ColumnHLCStore fix. That
// fix's own red-before/green-after proof lives in
// ColumnHLCFullWidthRoundTripTests.swift and
// FieldLevelLWWFullWidthOrderingMoneyTests.swift; this file was NOT
// independently re-verified via `git stash` (the `OutboxEntry.packedHLC` →
// `hlcWireBytes` struct rename spans the whole module, so a partial stash
// fails to compile rather than cleanly isolating one carrier) — it is a
// genuine, currently-passing regression test for the specific "does a
// delete actually apply / get correctly rejected under fieldLevelLWW at
// real magnitude" claim, layered on top of an already-proven fix.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

@Suite("Gap 6 — fieldLevelLWW delete correctness at real magnitude (Kong's CK-delete regression, D38.1)")
struct FieldLevelLWWDeleteRealMagnitudeTests {

    static let truncationCeiling: Int64 = 0xFF_FFFF_FFFF
    static let olderMs: Int64 = 1_784_477_440_577
    static let newerMs: Int64 = 1_784_477_500_577

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("note")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        try await CloudKitStateActor.ensureSyncMetaTable(storage: storage)
        return storage
    }

    let syncedTable = SyncedTable(
        name: "items",
        primaryKeyColumn: "id",
        conflictPolicy: .fieldLevelLWW
    )

    func makeUpsert(id: UUID, note: String, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return DecodedRecord(
            table: "items",
            rowKey: id,
            values: ["id": .uuid(id), "note": .text(note)],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit"),
            columnHLCs: ColumnHLCMap(entries: ["note": PackedHLC(hlc)])
        )
    }

    func makeTombstone(id: UUID, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        var decoded = DecodedRecord(
            table: "items",
            rowKey: id,
            values: [:],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
        decoded.isTombstone = true
        return decoded
    }

    @Test("(a) a genuinely newer tombstone hard-deletes the row on fieldLevelLWW, real magnitude")
    func newerTombstoneDeletesRealMagnitude() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "will-be-deleted", hlcTime: Self.olderMs),
            syncedTable: syncedTable, storage: storage)

        let seeded = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(seeded.count == 1, "test precondition: row seeded")

        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: Self.newerMs),
            syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rows.isEmpty,
                "gap 6 (Kong's CK-delete regression): a genuinely newer tombstone must hard-delete the row on fieldLevelLWW at real magnitude")
    }

    @Test("(b) a stale (older) tombstone is rejected on fieldLevelLWW, real magnitude (edit-beats-delete)")
    func staleTombstoneRejectedRealMagnitude() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "keep-me", hlcTime: Self.newerMs),
            syncedTable: syncedTable, storage: storage)

        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: Self.olderMs),
            syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rows.count == 1,
                "edit-beats-delete: a stale tombstone must not remove a row edited at a newer HLC, at real magnitude")
        #expect(rows.first?["note"] == .text("keep-me"))
    }
}
