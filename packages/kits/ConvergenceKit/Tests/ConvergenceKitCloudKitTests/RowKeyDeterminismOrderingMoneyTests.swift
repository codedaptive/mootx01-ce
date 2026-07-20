// RowKeyDeterminismOrderingMoneyTests.swift
//
// Gap 5 fix verification — END-TO-END, at the layer where the bug actually
// manifested: two INDEPENDENT federation spokes editing the SAME logical
// `.text`-PK row, an older-HLC edit arriving LAST (pull-order reversed from
// HLC-order).
//
// THE DEFECT (gap 5): `drawers.id`/`kg_facts.id`-shaped tables use a
// single-column `.text` primary key. `InMemoryStorage.resolveOrAllocateKey`
// (pre-fix) minted a fresh RANDOM UUID as the internal `RowKey` for any
// `.text`-typed PK — so two independent storage instances (two spokes)
// locally writing the SAME logical row (same `.text` id VALUE) resolved
// two DIFFERENT, unrelated `RowKey`s. `recordOutbound` ships that RowKey on
// the wire as `SyncRecord.rowKey`; `ApplyInbound`'s fieldLevelLWW/
// lastWriterWinsByHLC gates key their HLC bookkeeping
// (`_ck_sync_meta`/`_ck_sync_meta_cols`) by THAT RowKey. Mismatched RowKeys
// mean the gate compares against an unrelated (or absent) side-table entry
// — the "no local HLC recorded" fallback fires every time, so whichever
// record simply arrives LAST wins, regardless of true HLC order.
//
// THE FIX (RowKeyDerivation.deterministicRowKey, wired into
// resolveOrAllocateKey / extractRowKey): every spoke resolves the SAME
// RowKey for the SAME `.text` PK value, so the HLC gate compares against
// the RIGHT side-table entry and correctly rejects a stale edit — HLC-order,
// not pull-order.
//
// This test builds TWO independent, fully-`enable()`d CloudKitSyncEngine +
// storage pairs (the direct model of two spokes), captures each spoke's
// REAL outbound SyncRecord (via its `_ck_outbox` entry — the actual wire
// unit `recordOutbound` produces, not a hand-built DecodedRecord), asserts
// their `rowKey`s AGREE, then applies them to a third "hub" storage in
// PULL order (newer arrives first, older arrives LAST) and proves the
// older edit is correctly rejected.
//
// POLICY CHOICE — `.lastWriterWinsByHLC`, NOT `.fieldLevelLWW` (IMPORTANT):
// The fixture below uses the row-grain `.lastWriterWinsByHLC` conflict
// policy rather than `.fieldLevelLWW`, even though LocusKit's real
// drawers/kg_facts tables use `.fieldLevelLWW`. This is a deliberate,
// documented substitution, not an oversight:
//
// While building this test with `.fieldLevelLWW` (real HLC magnitudes,
// i.e. actual wall-clock ms-since-epoch from `HLCGenerator`, not the small
// synthetic values `FieldLWWMergeTests`/`field_lww_merge` unit tests use),
// it surfaced a SEPARATE, SEVERE, PRE-EXISTING, gap-5-UNRELATED defect:
// `ColumnHLCStore.writeAll`/`readAll` (ColumnHLCStore.swift:75,144;
// federation.rs:2555,2580 on the Rust side) persist per-column HLCs via
// `HLC.packed`/`HLC(packed:)`, which truncates `physicalTime` to 40 bits
// (`HLC.swift:99-104`, `phys = UInt64(self.physicalTime) & 0xFF_FFFF_FFFF`,
// max ~1.0995e12 ms). The WIRE format for the same value
// (`SyncRecord.swift:149-169`'s `PackedHLC`, used for `SyncRecord.columnHLCs`
// / `decoded.columnHLCs`) stores `physicalTime` LOSSLESSLY (a plain Codable
// Int64 field, no truncation). `FieldLWWMerge.merge` (FieldLWWMerge.swift:106)
// compares `incomingColumnHLC` (from the lossless wire format) against
// `local` (read back from the lossy-truncated `ColumnHLCStore`) with no
// normalization. Real wall-clock `physicalTime` in 2026 (~1.78e12 ms since
// epoch) ALWAYS exceeds the 40-bit truncation ceiling, so the persisted
// "local" value is ALWAYS a much smaller number than the lossless
// "incoming" value — `incomingColumnHLC >= local` is therefore ALWAYS
// true, REGARDLESS of true chronological HLC order. This means
// `.fieldLevelLWW`'s column-grain gate currently accepts whichever edit
// arrives last, unconditionally, for EVERY table using that policy, today,
// in production — a much larger and more severe defect than gap 5 itself.
// It has evaded every existing `FieldLWWMergeTests`/`field_lww_merge` unit
// test because all of them use small synthetic HLC values (0-300) that
// never cross the 40-bit boundary — the exact "vectors starting below the
// real seam" pattern already called out for gap 5's own rowKey vectors.
//
// This was OUT OF SCOPE for gap 5 (which is rowKey minting only) and was
// NOT fixed there — see the gap-5 completion report for the full writeup.
// `.lastWriterWinsByHLC`'s row-grain gate was NOT affected by the original
// defect: `decoded.hlc` (the incoming comparator, from
// `OutboxEntry.hlcWireBytes`) and the persisted `_ck_sync_meta.sync_hlc`
// were BOTH already the truncated `.packed` form on both sides of the
// comparison at the time gap 5 landed, so the row-grain gate was
// self-consistently truncated and correctly ordered — which is exactly why
// this test uses `.lastWriterWinsByHLC` to isolate gap 5's rowKey claim
// from the (then still-open) column-grain defect below.
//
// GAP 6 UPDATE (2026-07, D38.1): the column-grain defect described above
// is now FIXED — full-width HLC persistence across every carrier, both
// legs (see `ColumnHLCStore.swift`'s file header for the current writeup).
// `OutboxEntry.packedHLC: Int64` was renamed to `hlcWireBytes: Data`
// (`HLC.wireBytes`, lossless) as part of that fix — this file's helper
// below was updated to match, but the test itself still deliberately uses
// `.lastWriterWinsByHLC` (unchanged) since that was always gap 5's actual
// claim; the money test for gap 6's `.fieldLevelLWW` column-grain fix
// lives in `FieldLevelLWWFullWidthOrderingMoneyTests.swift`.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

@Suite("Gap 5 money test — two spokes, .text PK, older-HLC edit arrives LAST (HLC-order not pull-order)")
struct RowKeyDeterminismOrderingMoneyTests {

    // MARK: - Fixture

    static let manifest = SyncManifest(
        kitID: "TestKit",
        schemaVersion: 1,
        zoneIdentifier: "GAP5-CK",
        tables: [
            SyncedTable(
                name: "widgets",
                direction: .bidirectional,
                primaryKeyColumn: "id",
                conflictPolicy: .lastWriterWinsByHLC
            )
        ]
    )
    static let syncedTable = manifest.tables[0]

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "widgets",
                    // Single-column .text PK, NON-UUID values — the exact shape
                    // LocusKit's drawers/kg_facts are documented to (eventually)
                    // use for content-addressed deterministic ids.
                    columns: [.text("id"), .text("note")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return storage
    }

    func makeEngine(storage: any Storage, cloud: CloudZoneFake) async throws -> CloudKitSyncEngine {
        let engine = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)
        try await engine.enable(manifest: Self.manifest, storage: storage)
        return engine
    }

    func pollUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            await Task.yield()
            if try await condition() { return true }
        }
        return false
    }

    /// Read the (single, most-recent) outbox entry for `storage` and
    /// reconstruct the `DecodedRecord` `applyInbound` would receive on the
    /// wire — the SAME decode path `PushCycle.push()` uses
    /// (`PushCycle.swift:91,100,110,120`). This is the REAL wire unit
    /// `recordOutbound` produced, not a hand-built stand-in.
    func latestOutboundRecord(from storage: any Storage) async throws -> DecodedRecord {
        let batch = try await OutboxStore.readBatch(from: storage)
        let entry = try #require(batch.last, "expected at least one outbox entry")
        let rowKey = try #require(UUID(uuidString: entry.rowKey), "outbox entry rowKey must be a valid UUID string")
        let hlc = try HLC(wireBytes: [UInt8](entry.hlcWireBytes))
        let valuesData = try #require(entry.valuesData, "expected values for an insert/update entry")
        let valueMap = try JSONDecoder().decode(SyncValueMap.self, from: valuesData)
        let columnHLCs: ColumnHLCMap? = try entry.columnHLCsData.map { try JSONDecoder().decode(ColumnHLCMap.self, from: $0) }
        return DecodedRecord(
            table: entry.tableName,
            rowKey: rowKey,
            values: valueMap.asTypedValues,
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit"),
            columnHLCs: columnHLCs
        )
    }

    @Test("two spokes' independently-minted rowKeys for the SAME .text PK value AGREE")
    func twoSpokesAgreeOnRowKey() async throws {
        let cloud = CloudZoneFake()
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = try await makeEngine(storage: storageA, cloud: cloud)
        let engineB = try await makeEngine(storage: storageB, cloud: cloud)
        let idValue = "widget-alpha"

        let beforeA = try await OutboxStore.readBatch(from: storageA).count
        _ = try await storageA.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("from A")], conflictColumns: ["id"]
        )
        _ = try await pollUntil { try await OutboxStore.readBatch(from: storageA).count > beforeA }

        let beforeB = try await OutboxStore.readBatch(from: storageB).count
        _ = try await storageB.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("from B")], conflictColumns: ["id"]
        )
        _ = try await pollUntil { try await OutboxStore.readBatch(from: storageB).count > beforeB }

        let recordA = try await latestOutboundRecord(from: storageA)
        let recordB = try await latestOutboundRecord(from: storageB)

        #expect(recordA.rowKey == recordB.rowKey,
                "gap 5: two independent spokes must mint the SAME rowKey for the same .text PK value")
        _ = (engineA, engineB)
    }

    /// THE MONEY TEST.
    ///
    /// Uses a UUID-SHAPED `.text` id (matching LocusKit's CURRENT production
    /// reality — Finding #1 of the gap-5 decision memo: every drawer/kg_fact
    /// id is a UUID string in every code path exercised today). This is
    /// deliberate, not incidental: `ApplyInbound`'s primary-key coercion
    /// (`ApplyInbound.swift:212`, `inboundValues[syncedTable.primaryKeyColumn]
    /// = .uuid(decoded.rowKey)`) rewrites the stored PK column to a `.uuid`
    /// TypedValue equal to the resolved `rowKey` on every apply — a
    /// CloudKit-specific belt-and-braces coercion that predates gap 5 and is
    /// out of its scope. For a UUID-SHAPED `.text` PK this coercion is a
    /// no-op in substance (the derived `rowKey` parses BACK to the exact
    /// same UUID string), so it does not interfere with this test. A
    /// genuinely non-UUID `.text` id would round-trip through that same
    /// coercion to a DIFFERENT stored value — a separate, pre-existing
    /// PK-coercion behavior this test does not exercise (see gap-5 decision
    /// memo Finding #3 for why this is safe: no production caller supplies
    /// a non-UUID id today). Before gap 5, InMemoryStorage's
    /// `resolveOrAllocateKey` had NO `.text` handling AT ALL (not even
    /// UUID-string parsing), so this exact UUID-shaped case still failed
    /// pre-fix — see the red-before verification in the completion report.
    @Test("older-HLC edit arriving LAST is rejected — HLC-order, not pull-order")
    func olderEditArrivingLastIsRejectedByHLCOrder() async throws {
        let cloud = CloudZoneFake()
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = try await makeEngine(storage: storageA, cloud: cloud)
        let engineB = try await makeEngine(storage: storageB, cloud: cloud)
        let idValue = UUID().uuidString

        // Spoke B writes FIRST in wall-clock time but we force its HLC OLDER
        // than spoke A's by advancing A's clock forward before A writes —
        // this is the "clock skew" scenario (P4.5), not a crash.
        let beforeB = try await OutboxStore.readBatch(from: storageB).count
        _ = try await storageB.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("OLDER-must-not-win")], conflictColumns: ["id"]
        )
        _ = try await pollUntil { try await OutboxStore.readBatch(from: storageB).count > beforeB }
        let recordB = try await latestOutboundRecord(from: storageB)

        // Spoke A: advance its HLC generator well past B's, then write.
        await engineA.stateActor.advanceClock(by: 60_000)
        let beforeA = try await OutboxStore.readBatch(from: storageA).count
        _ = try await storageA.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("NEWER-must-win")], conflictColumns: ["id"]
        )
        _ = try await pollUntil { try await OutboxStore.readBatch(from: storageA).count > beforeA }
        let recordA = try await latestOutboundRecord(from: storageA)

        #expect(recordA.rowKey == recordB.rowKey, "test precondition: both spokes must agree on rowKey")
        #expect(recordA.syncMeta.hlc > recordB.syncMeta.hlc, "test precondition: A's HLC must be strictly newer than B's")

        // Apply to a THIRD "hub" storage in PULL order: A (newer) arrives
        // FIRST, B (older) arrives LAST — pull-order reversed from HLC-order.
        let hub = try await makeStorage()
        let hubEngine = try await makeEngine(storage: hub, cloud: CloudZoneFake())
        try await hubEngine.stateActor.applyInbound(recordA, syncedTable: Self.syncedTable, storage: hub)
        try await hubEngine.stateActor.applyInbound(recordB, syncedTable: Self.syncedTable, storage: hub)

        // THE MONEY ASSERTION: the hub must still show A's (newer) value —
        // B's older edit, arriving last, must be rejected by the HLC gate
        // (`ApplyInbound.swift:223-234`, `.lastWriterWinsByHLC`: `if let
        // localHLC, decoded.hlc < localHLC { return }`).
        // Before gap 5, InMemoryStorage's `resolveOrAllocateKey` had NO
        // `.text` PK handling AT ALL — A and B would have minted DIFFERENT
        // RANDOM rowKeys even for this UUID-shaped id, so B's apply would
        // find no local `_ck_sync_meta` entry under ITS rowKey and win via
        // the `localHLC == nil` first-write-wins fallback, silently
        // overwriting A's newer value with B's stale one (see the
        // completion report's red-before proof).
        // Query by rowKey (the .uuid value ApplyInbound's PK coercion stores),
        // not by the original .text idValue — see the coercion note above.
        let rows = try await hub.rowStore.query(
            table: "widgets", where: .eq(Column(table: "widgets", name: "id"), .uuid(recordA.rowKey))
        )
        #expect(rows.first?["note"] == .text("NEWER-must-win"),
                "gap 5 money test: older-HLC edit arriving last must be rejected (HLC-order, not pull-order) — got \(String(describing: rows.first?["note"]))")
        _ = engineB
    }
}
