// FederationTombstoneGateLiveTests.swift
//
// Gap 6 headline test (Bob, D38.1): PROVE THE FEDERATION TOMBSTONE GATE LIVE.
//
// gap-2's stale-resurrect guard (readFedTombstoneHLC / the edit-beats-delete
// rule in FieldLWWMerge.tombstoneWins, and the equivalent
// `.lastWriterWinsByHLC` gate `decoded.hlc < localHLC`) was SUBSUMED by gap
// 6 on the Federation leg specifically, in a way it was NOT on the CloudKit
// leg — this file exists to prove exactly that distinction and to close it.
//
// WHY FEDERATION'S ROW-GRAIN GATE WAS ACTIVELY BROKEN (not just latently
// inconsistent, unlike CloudKit's):
// Federation's WIRE format (`SyncRecord.hlc: PackedHLC`, record.rs) has
// ALWAYS been lossless — a plain JSON-Codable struct, never routed through
// `HLC.packed`/`HLC::packed()` anywhere in the Federation transport path.
// `_fed_sync_meta.sync_hlc` (PERSISTED, pre-gap-6) WAS truncated via
// `hlc.packed()`/`hlc.packed` (the 40-bit mask, HLC.swift:99-104). So
// Federation's row-grain gate compared a LOSSLESS incoming HLC (from the
// wire) against a LOSSY persisted-local HLC — a genuine, ACTIVE mismatch at
// any real 2026-era magnitude, not a merely-latent one.
//
// CONTRAST — why CloudKit's row-grain gate was NOT actively broken the same
// way (see RowKeyDeterminismOrderingMoneyTests.swift and
// ColumnHLCStore.swift's file headers for the full history): CloudKit's
// OutboxEntry (pre-gap-6) ALSO truncated the HLC via `HLC.packed` BEFORE it
// ever reached CKRecordMapping's encoder, so the value entering the wire was
// ALREADY damaged upstream — CKRecordMapping's own 48-bit packing scheme
// (packed()/unpacked(), CKRecordMapping.swift:342-355) has plenty of
// headroom and does not itself truncate, but it cannot recover precision
// that was already discarded before it saw the value. Both sides of
// CloudKit's row-grain comparison were therefore CONSISTENTLY truncated
// (via the same 40-bit `HLC.packed`), which is why that specific gate
// (unlike Federation's) remained self-consistently correct within the same
// wrap band even before gap 6 — this is exactly why gap 5's money test
// used `.lastWriterWinsByHLC` to isolate its own claim from the
// column-grain defect, and CKRecordMapping.swift needed NO change for gap 6
// (verified explicitly during gap 6's implementation).
//
// THIS TEST proves, at REAL HLC magnitudes (not the small synthetic values
// every pre-gap-6 FederationLWWTests/FederationTombstoneTests vector used —
// the same "vectors starting below the real seam" pattern already called
// out for gap 5's rowKey vectors and gap 6's column-grain money test):
//   (a) a stale delete (tombstone) arriving with an OLDER HLC than a local
//       column edit is correctly REJECTED — edit-beats-delete, the row
//       survives (gap 2's tombstoneWins guard actually firing).
//   (b) a stale edit arriving with an OLDER HLC than an already-applied
//       tombstone does NOT resurrect the row — the gap-2 stale-resurrect
//       guard (`readFedTombstoneHLC` + the `decoded.hlc < tombstoneHLC`
//       reject in the `.fieldLevelLWW` normal-apply arm) actually firing.
//
// Both scenarios are red-before/green-after verified against the gap-6 fix
// via targeted `git stash` in the completion report.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Gap 6 headline — Federation tombstone gate LIVE at real magnitude (D38.1)")
struct FederationTombstoneGateLiveTests {

    // MARK: - Fixture

    /// Real-magnitude physicalTime vectors, matching the ones used
    /// throughout gap 6 (FieldLevelLWWFullWidthOrderingMoneyTests.swift,
    /// same_column_real_magnitude_* in field_lww_engine_tests.rs) for
    /// direct cross-test parity. Both exceed the old 40-bit truncation
    /// ceiling (`0xFF_FFFF_FFFF`, ~1.0995e12).
    static let truncationCeiling: Int64 = 0xFF_FFFF_FFFF
    static let olderMs: Int64 = 1_784_477_440_577
    static let newerMs: Int64 = 1_784_477_500_577

    func makeStorage() async throws -> any Storage {
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
                    columns: [.uuid("id"), .text("note")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        try await FederationStateActor.ensureFedSyncMetaTable(storage: storage)
        return storage
    }

    static let fieldLWWTable = SyncedTable(
        name: "items",
        direction: .bidirectional,
        primaryKeyColumn: "id",
        conflictPolicy: .fieldLevelLWW
    )

    static let lwwTable = SyncedTable(
        name: "items",
        direction: .bidirectional,
        primaryKeyColumn: "id",
        conflictPolicy: .lastWriterWinsByHLC
    )

    func makeUpsert(id: UUID, note: String, hlcTime: Int64, columnHLC: Bool) -> SyncRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return SyncRecord(
            table: "items",
            event: .update,
            rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note)]),
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit",
            columnHLCs: columnHLC ? ColumnHLCMap(entries: ["note": PackedHLC(hlc)]) : nil
        )
    }

    func makeTombstone(id: UUID, hlcTime: Int64) -> SyncRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return SyncRecord(
            table: "items",
            event: .delete,
            rowKey: id,
            values: nil,
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit"
        )
    }

    // MARK: - (a) edit-beats-delete at real magnitude, fieldLevelLWW
    //
    // NOTE on isolation: this scenario is gated by
    // `FieldLWWMerge.tombstoneWins(tombstoneHLC:localColumnHLCs:)`, which
    // compares against COLUMN-grain HLCs (`ColumnHLCStore.readAll`) — the
    // part of gap 6 fixed earlier in this same pass, alongside the CloudKit
    // column-grain fix. Verified red-before/green-after in isolation from
    // (b)/(c) below: stashing ONLY FederationSyncEngine.swift's row-grain
    // changes (sync_hlc_wire) leaves this test GREEN (column-grain fix is
    // in a separate file and unaffected), while (b) and (c) — gated by the
    // ROW-grain `readFedTombstoneHLC`/`sync_hlc_wire` — correctly go RED.
    // This test's value is proving edit-beats-delete holds for Federation
    // specifically at real magnitude, not isolating the row-grain fix.
    @Test("(a) stale tombstone (older HLC) does not delete a row edited at a newer HLC — fieldLevelLWW, real magnitude")
    func staleDeleteRejectedRealMagnitudeFieldLWW() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        #expect(Self.olderMs > Self.truncationCeiling, "test precondition: real magnitude")
        #expect(Self.newerMs > Self.truncationCeiling, "test precondition: real magnitude")

        // Local column edit at the NEWER real-magnitude HLC.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "keep-me", hlcTime: Self.newerMs, columnHLC: true),
            syncedTable: Self.fieldLWWTable, storage: storage)

        let rowsAfterEdit = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rowsAfterEdit.first?["note"] == .text("keep-me"), "test precondition: edit applied")

        // A STALE delete at the OLDER real-magnitude HLC arrives.
        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: Self.olderMs),
            syncedTable: Self.fieldLWWTable, storage: storage)

        // THE MONEY ASSERTION: edit-beats-delete — the row must survive.
        let rowsAfterTombstone = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rowsAfterTombstone.count == 1,
                "gap 6 federation tombstone gate LIVE: stale delete (older HLC) must be rejected — row must survive (edit-beats-delete)")
        #expect(rowsAfterTombstone.first?["note"] == .text("keep-me"),
                "surviving row must retain its edited value")
    }

    // MARK: - (b) stale edit does not resurrect, lastWriterWinsByHLC

    @Test("(b) stale edit (older HLC) does not resurrect a row already tombstoned at a newer HLC — lastWriterWinsByHLC, real magnitude")
    func staleEditDoesNotResurrectRealMagnitudeLWW() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed the row, then delete it at the NEWER real-magnitude HLC.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "temp", hlcTime: Self.olderMs, columnHLC: false),
            syncedTable: Self.lwwTable, storage: storage)
        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: Self.newerMs),
            syncedTable: Self.lwwTable, storage: storage)

        let rowsAfterDelete = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rowsAfterDelete.isEmpty, "test precondition: row must be deleted")

        // A STALE edit at an HLC OLDER than the tombstone arrives (pull-order
        // reversed from HLC-order — the row's delete has already synced).
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "STALE-must-not-resurrect", hlcTime: Self.olderMs, columnHLC: false),
            syncedTable: Self.lwwTable, storage: storage)

        // THE MONEY ASSERTION: the stale-resurrect guard must fire — no
        // ghost row appears at real magnitude.
        let rowsAfterStaleEdit = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rowsAfterStaleEdit.isEmpty,
                "gap 6 federation tombstone gate LIVE: stale edit (older HLC) arriving after a tombstone must NOT resurrect the row")
    }

    // MARK: - (c) same scenario as (b) but under fieldLevelLWW (gap 2's actual arm)

    @Test("(c) stale edit (older HLC) does not resurrect a row already tombstoned at a newer HLC — fieldLevelLWW, real magnitude")
    func staleEditDoesNotResurrectRealMagnitudeFieldLWW() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "temp", hlcTime: Self.olderMs, columnHLC: true),
            syncedTable: Self.fieldLWWTable, storage: storage)
        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: Self.newerMs),
            syncedTable: Self.fieldLWWTable, storage: storage)

        let rowsAfterDelete = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rowsAfterDelete.isEmpty, "test precondition: row must be deleted")

        // Gap 2's specific guard: a stale edit older than the row-grain
        // tombstone HLC, in the .fieldLevelLWW normal-apply arm.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "STALE-must-not-resurrect", hlcTime: Self.olderMs, columnHLC: true),
            syncedTable: Self.fieldLWWTable, storage: storage)

        let rowsAfterStaleEdit = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rowsAfterStaleEdit.isEmpty,
                "gap 6 federation tombstone gate LIVE (gap 2 arm): stale edit (older HLC) must NOT resurrect the row under fieldLevelLWW")
    }
}
