// FieldLevelLWWFullWidthOrderingMoneyTests.swift
//
// Gap 6 money test — reproduces and fixes the fieldLevelLWW column-grain
// HLC truncation defect discovered while building gap 5's money test.
//
// THE DEFECT (gap 6, found during gap 5, fixed here):
// `ColumnHLCStore` persisted per-column HLCs via `HLC.packed`/`HLC(packed:)`
// (ColumnHLCStore.swift, pre-fix), which bit-packs `physicalTime` into 40
// bits (`HLC.swift:99-104`, max ~1.0995e12 ms since epoch — a ceiling real
// wall-clock time exceeded around 2004). The WIRE format for the same value
// (`SyncRecord.swift`'s `PackedHLC`) stores `physicalTime` losslessly.
// `FieldLWWMerge.merge` compared the lossy-persisted "local" HLC against the
// lossless "incoming" HLC with no normalization — since real wall-clock
// `physicalTime` (~1.78e12 in 2026) always exceeds the 40-bit ceiling, the
// persisted "local" value was ALWAYS a much smaller number than the
// lossless "incoming" value, so `incomingColumnHLC >= local` evaluated
// TRUE unconditionally — whichever column edit arrived last always won,
// regardless of true HLC order.
//
// THE FIX (D38.1 — widened to full-width, atomic, every HLC carrier, both
// legs, after Kong found a column-only fix regresses CloudKit deletes):
// ColumnHLCStore now persists/reads the full-width `col_hlc_wire` BLOB —
// `HLC.wireBytes`, the already Swift/Rust lockstep-audited 16-byte lossless
// wire format — directly from HLC's own fields, no bit-packing, so no
// truncation. The SAME encoding is now used uniformly for every other gap-6
// carrier too (row-grain `_ck_sync_meta`/`_fed_sync_meta`, the CK/Federation
// outbox carriers). See ColumnHLCStore.swift's file header and
// SideSchema.swift's v10 migration for the full writeup.
//
// This test uses `.fieldLevelLWW` (unlike gap 5's money test, which
// deliberately used `.lastWriterWinsByHLC` to isolate the rowKey-convergence
// fix from this then-unfixed defect) and a `.uuid` PK (gap 6 has nothing to
// do with rowKey minting — using `.uuid` keeps this test focused purely on
// the column-HLC comparison fix, no gap-5 entanglement). REAL HLC magnitudes
// are used throughout (via `HLCGenerator`'s real wall-clock stamping plus
// `advanceClock`), NOT the small synthetic 0-300 values every pre-gap-6
// `FieldLWWMergeTests`/`field_lww_engine_tests` vector used — those synthetic
// values never crossed the 40-bit boundary, which is exactly why this defect
// survived undetected until gap 5's money test happened to use real
// magnitudes.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

@Suite("Gap 6 money test — fieldLevelLWW column edit, older-HLC arrives LAST (real magnitudes, HLC-order not pull-order)")
struct FieldLevelLWWFullWidthOrderingMoneyTests {

    // MARK: - Fixture

    static let manifest = SyncManifest(
        kitID: "TestKit",
        schemaVersion: 1,
        zoneIdentifier: "GAP6-CK",
        tables: [
            SyncedTable(
                name: "widgets",
                direction: .bidirectional,
                primaryKeyColumn: "id",
                conflictPolicy: .fieldLevelLWW
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
                    columns: [.uuid("id"), .text("note")],
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
    /// wire — the SAME decode path `PushCycle.push()` uses. This is the REAL
    /// wire unit `recordOutbound` produced, not a hand-built stand-in.
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

    /// THE MONEY TEST.
    ///
    /// Two independent spokes write to the SAME logical row (same literal
    /// `.uuid` id — no rowKey-derivation involved, unlike gap 5). Spoke A's
    /// HLC is forced strictly newer via `advanceClock`. Applied to a fresh
    /// hub in PULL order (A first, B last — pull-order reversed from HLC
    /// order). Post-fix, the hub must retain A's (newer) value: the
    /// `.fieldLevelLWW` column-grain gate must correctly reject B's
    /// older-but-arrived-last edit.
    @Test("older-HLC column edit arriving LAST is rejected — HLC-order, not pull-order (real magnitudes)")
    func olderColumnEditArrivingLastIsRejectedByHLCOrder() async throws {
        let cloud = CloudZoneFake()
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = try await makeEngine(storage: storageA, cloud: cloud)
        let engineB = try await makeEngine(storage: storageB, cloud: cloud)
        let id = UUID()

        // Spoke B writes FIRST in wall-clock time but B's HLC ends up OLDER
        // than A's because A's clock is advanced forward before A writes —
        // the "clock skew" scenario (P4.5), not a crash.
        let beforeB = try await OutboxStore.readBatch(from: storageB).count
        _ = try await storageB.rowStore.upsert(
            table: "widgets", values: ["id": .uuid(id), "note": .text("OLDER-must-not-win")], conflictColumns: ["id"]
        )
        _ = try await pollUntil { try await OutboxStore.readBatch(from: storageB).count > beforeB }
        let recordB = try await latestOutboundRecord(from: storageB)

        // Spoke A: advance its HLC generator well past B's, then write.
        await engineA.stateActor.advanceClock(by: 60_000)
        let beforeA = try await OutboxStore.readBatch(from: storageA).count
        _ = try await storageA.rowStore.upsert(
            table: "widgets", values: ["id": .uuid(id), "note": .text("NEWER-must-win")], conflictColumns: ["id"]
        )
        _ = try await pollUntil { try await OutboxStore.readBatch(from: storageA).count > beforeA }
        let recordA = try await latestOutboundRecord(from: storageA)

        #expect(recordA.syncMeta.hlc > recordB.syncMeta.hlc, "test precondition: A's HLC must be strictly newer than B's")

        // Both records must carry REAL-MAGNITUDE column HLCs (> the old
        // 40-bit truncation ceiling) — otherwise this test would not
        // actually exercise the defect (see file header: the 0-300
        // synthetic values in the pre-gap-6 unit tests never crossed this
        // boundary, which is why the bug went undetected).
        let truncationCeiling: Int64 = 0xFF_FFFF_FFFF // 2^40 - 1, ~1.0995e12
        let noteAHLC = try #require(recordA.columnHLCs?.entries["note"])
        let noteBHLC = try #require(recordB.columnHLCs?.entries["note"])
        #expect(noteAHLC.physicalTime > truncationCeiling,
                "test precondition: record A's column HLC must exceed the old 40-bit truncation ceiling to exercise the defect")
        #expect(noteBHLC.physicalTime > truncationCeiling,
                "test precondition: record B's column HLC must exceed the old 40-bit truncation ceiling to exercise the defect")

        // Apply to a THIRD "hub" storage in PULL order: A (newer) arrives
        // FIRST, B (older) arrives LAST — pull-order reversed from HLC-order.
        let hub = try await makeStorage()
        let hubEngine = try await makeEngine(storage: hub, cloud: CloudZoneFake())
        try await hubEngine.stateActor.applyInbound(recordA, syncedTable: Self.syncedTable, storage: hub)
        try await hubEngine.stateActor.applyInbound(recordB, syncedTable: Self.syncedTable, storage: hub)

        // THE MONEY ASSERTION: the hub must still show A's (newer) value —
        // B's older column edit, arriving last, must be rejected by the
        // fieldLevelLWW column-grain HLC gate (FieldLWWMerge.merge, gated on
        // ColumnHLCStore's now-full-width persisted local HLC).
        //
        // Pre-fix (gap 6 defect): ColumnHLCStore.readAll returned A's
        // persisted "local" HLC 40-bit-TRUNCATED (a small number, since
        // `HLC.packed` masks physicalTime to `& 0xFF_FFFF_FFFF`), while
        // B's incoming HLC (from the lossless wire PackedHLC) retained its
        // full real magnitude. The truncated-local-vs-lossless-incoming
        // comparison made `incomingColumnHLC >= local` evaluate true
        // unconditionally — B's older edit always won. See the red-before
        // proof in the gap-6 completion report.
        let rows = try await hub.rowStore.query(
            table: "widgets", where: .eq(Column(table: "widgets", name: "id"), .uuid(id))
        )
        #expect(rows.first?["note"] == .text("NEWER-must-win"),
                "gap 6 money test: older-HLC column edit arriving last must be rejected (HLC-order, not pull-order) — got \(String(describing: rows.first?["note"]))")
        _ = (engineB)
    }
}
