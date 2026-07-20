// ColumnHLCFullWidthRoundTripTests.swift
//
// Gap 6 regression tests, group (b): a column HLC with `physicalTime`
// above the old 40-bit `HLC.packed` truncation ceiling must survive
// persist→read through `ColumnHLCStore` byte-exact.
//
// THE DEFECT (gap 6): pre-fix, `ColumnHLCStore.writeAll`/`readAll` round-
// tripped column HLCs through `HLC.packed`/`HLC(packed:)`
// (`phys = UInt64(physicalTime) & 0xFF_FFFF_FFFF`, HLC.swift:99-104), which
// silently truncates any `physicalTime` above ~1.0995e12 ms — a ceiling
// real wall-clock time has exceeded since ~2004. This test proves the
// post-fix `col_hlc_wire` BLOB (`HLC.wireBytes`) preserves
// the full value with no truncation, using physicalTime magnitudes
// representative of real 2026 wall-clock time.
//
// This is the PERSIST half of gap 6's regression coverage; the WIRE half
// (JSON round-trip through the actual `_syncColumnHLCs` CKRecord field) is
// covered by `CKRecordMappingTests.columnHLCsRealMagnitudeWireRoundTrip`.

import Testing
import Foundation
@testable import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

@Suite("Gap 6 — ColumnHLCStore full-width persist round-trip (no truncation above 2^40)")
struct ColumnHLCFullWidthRoundTripTests {

    /// The old `HLC.packed` truncation ceiling: `physicalTime` values above
    /// this were silently wrapped down to a much smaller number pre-fix.
    static let truncationCeiling: Int64 = 0xFF_FFFF_FFFF // 2^40 - 1, ~1.0995e12

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(kitID: "TestApp", version: 1, tables: []))
        try await CKSideSchema.ensure(storage: storage)
        return storage
    }

    @Test("a single column HLC with physicalTime above the truncation ceiling round-trips byte-exact")
    func singleColumnRealMagnitudeRoundTrip() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID()
        // A real 2026-ish wall-clock ms-since-epoch value.
        let original = HLC(physicalTime: 1_784_477_500_577, logicalCount: 1, nodeID: 3)
        #expect(original.physicalTime > Self.truncationCeiling, "test precondition: real magnitude")

        try await ColumnHLCStore.writeAll(
            map: ColumnHLCMap(entries: ["note": PackedHLC(original)]),
            to: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "widgets", primaryKey: rowKey
        )
        let readBack = try await ColumnHLCStore.readAll(
            from: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "widgets", primaryKey: rowKey
        )
        let entry = try #require(readBack.entries["note"])
        #expect(entry.physicalTime == original.physicalTime,
                "physicalTime must survive persist→read byte-exact, got \(entry.physicalTime) expected \(original.physicalTime)")
        #expect(entry.logicalCount == original.logicalCount)
        #expect(entry.nodeID == original.nodeID)
    }

    @Test("multiple columns, all above the truncation ceiling, each round-trip independently byte-exact")
    func multiColumnRealMagnitudeRoundTrip() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID()
        let originals: [String: HLC] = [
            "title": HLC(physicalTime: 1_784_477_500_577, logicalCount: 1, nodeID: 1),
            "body":  HLC(physicalTime: 1_784_477_440_577, logicalCount: 0, nodeID: 2),
            "score": HLC(physicalTime: 1_900_000_000_000, logicalCount: 42, nodeID: 15),
        ]
        for hlc in originals.values {
            #expect(hlc.physicalTime > Self.truncationCeiling, "test precondition: real magnitude")
        }
        try await ColumnHLCStore.writeAll(
            map: ColumnHLCMap(entries: originals.mapValues { PackedHLC($0) }),
            to: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "widgets", primaryKey: rowKey
        )
        let readBack = try await ColumnHLCStore.readAll(
            from: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "widgets", primaryKey: rowKey
        )
        #expect(readBack.entries.count == originals.count)
        for (column, original) in originals {
            let entry = try #require(readBack.entries[column], "missing column \(column) after round-trip")
            #expect(entry.physicalTime == original.physicalTime, "\(column): physicalTime must be byte-exact")
            #expect(entry.logicalCount == original.logicalCount, "\(column): logicalCount must be byte-exact")
            #expect(entry.nodeID == original.nodeID, "\(column): nodeID must be byte-exact")
        }
    }

    @Test("a physicalTime that WOULD have wrapped under the old 40-bit mask stays distinct from its wrapped alias")
    func distinctFromLegacyWrappedAlias() async throws {
        let storage = try await makeStorage()
        let rowKeyHigh = UUID()
        let rowKeyLow = UUID()
        // `high` is the real value; `low` is what the OLD `HLC.packed` masking
        // would have collapsed it to (`high.physicalTime & 0xFF_FFFF_FFFF`).
        // Pre-fix, writing `high` and reading it back would have returned
        // `low`'s magnitude — this test proves that no longer happens.
        let high = HLC(physicalTime: 1_784_477_500_577, logicalCount: 1, nodeID: 1)
        let wrappedAlias = high.physicalTime & Self.truncationCeiling
        #expect(wrappedAlias != high.physicalTime, "test precondition: wrapping must actually change the value")

        try await ColumnHLCStore.writeAll(
            map: ColumnHLCMap(entries: ["note": PackedHLC(high)]),
            to: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "widgets", primaryKey: rowKeyHigh
        )
        let readBack = try await ColumnHLCStore.readAll(
            from: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "widgets", primaryKey: rowKeyHigh
        )
        let entry = try #require(readBack.entries["note"])
        #expect(entry.physicalTime == high.physicalTime,
                "must read back the REAL value, not the legacy 40-bit-wrapped alias \(wrappedAlias)")
        #expect(entry.physicalTime != wrappedAlias)
        _ = rowKeyLow
    }
}
