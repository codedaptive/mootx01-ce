// ColumnHLCCoalescingTests.swift
//
// Tests for outbox column HLC map coalescing (B-8 / CVK-ICLOUD P2-M1).
//
// When a newer outbox entry replaces a stale one for the same (table, row),
// the column HLC maps are MERGED rather than replaced. This ensures that
// columns present only in the stale entry are not silently discarded.
//
// The merge rule (highest HLC per column) is the same commutative merge
// used by ColumnHLCMap.merge(with:).
//
// WHY this matters:
// Consider a hot row written twice before the next push cycle:
//   Write 1 (T=100): columns {title, score} → outbox A has {title:T100, score:T100}
//   Write 2 (T=200): columns {title}        → outbox B has {title:T200}
// Replacing A's map entirely with B's would discard "score" from the
// CKRecord. The receiver would treat "score" as a first-write on the next
// update and potentially apply a stale value from a concurrent peer.
// Merging keeps {title:T200, score:T100} so the CKRecord carries the
// full column timeline.

import Testing
import Foundation
@testable import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

// MARK: - Helpers

private func makeStorage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory
    ))
    try await storage.open(schema: SchemaDeclaration(
        kitID: "TestApp",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("title"), .int("score"), .text("body")],
                primaryKey: ["id"]
            )
        ]
    ))
    try await CKSideSchema.ensure(storage: storage)
    return storage
}

private func makeEntry(
    rowKey: String = UUID().uuidString,
    packedHLC: Int64,
    columnHLCsData: Data? = nil,
    event: SyncEventKind = .update,
    valuesData: Data? = nil
) -> OutboxEntry {
    // Gap 6: `packedHLC` here is a plain logical ordinal (test convenience,
    // pre-existing param name kept so every call site below is unchanged) —
    // wrapped into a full-width HLC.wireBytes via HLC.zero-node convenience.
    let hlc = HLC(physicalTime: packedHLC, logicalCount: 0, nodeID: 1)
    return OutboxEntry(
        id: UUID(),
        tableName: "items",
        rowKey: rowKey,
        event: event,
        valuesData: valuesData,
        hlcWireBytes: Data(hlc.wireBytes),
        enqueuedAt: ISO8601DateFormatter().string(from: Date()),
        columnHLCsData: columnHLCsData
    )
}

private func columnData(_ entries: [String: PackedHLC]) throws -> Data {
    try JSONEncoder().encode(ColumnHLCMap(entries: entries))
}

private func hlc(physical: Int64, logical: Int32 = 0, node: Int32 = 1) -> PackedHLC {
    PackedHLC(HLC(physicalTime: physical, logicalCount: logical, nodeID: node))
}

// MARK: - Suite

@Suite("OutboxStore — column HLC coalescing (B-8)")
struct ColumnHLCCoalescingTests {

    // MARK: - Basic coalescing with column HLC merge

    @Test("coalesce: stale and incoming both have column HLCs → merge keeps highest per column")
    func coalesceColumnHLCsMerge() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        // Stale entry: columns {title:T100, score:T100}, hlc=100
        let staleColMap = try columnData([
            "title": hlc(physical: 100),
            "score": hlc(physical: 100),
        ])
        let staleEntry = makeEntry(rowKey: rowKey, packedHLC: 100, columnHLCsData: staleColMap)
        try await OutboxStore.append(entry: staleEntry, to: storage)

        // Incoming entry: only {title:T200}, hlc=200
        let incomingColMap = try columnData([
            "title": hlc(physical: 200),
        ])
        let incomingEntry = makeEntry(rowKey: rowKey, packedHLC: 200, columnHLCsData: incomingColMap)
        try await OutboxStore.append(entry: incomingEntry, to: storage)

        // After coalescing, one entry in the outbox.
        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)

        let coalescedEntry = try #require(batch.first)
        let colData = try #require(coalescedEntry.columnHLCsData)
        let colMap = try JSONDecoder().decode(ColumnHLCMap.self, from: colData)

        // title: incoming T200 > stale T100 → T200 wins
        #expect(colMap.entries["title"] == hlc(physical: 200),
                "title should be T200 (incoming wins)")
        // score: only in stale entry → T100 must be preserved
        #expect(colMap.entries["score"] == hlc(physical: 100),
                "score was only in stale entry; must survive merge")
    }

    @Test("coalesce: body column in stale not overwritten by incoming which has newer title")
    func coalesceBodySurvives() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        // Stale: {title:T50, body:T80}
        let staleColMap = try columnData([
            "title": hlc(physical: 50),
            "body":  hlc(physical: 80),
        ])
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 80, columnHLCsData: staleColMap),
            to: storage
        )

        // Incoming: {title:T200} only, higher row-grain HLC
        let incomingColMap = try columnData(["title": hlc(physical: 200)])
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 200, columnHLCsData: incomingColMap),
            to: storage
        )

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        let colData = try #require(batch.first?.columnHLCsData)
        let colMap = try JSONDecoder().decode(ColumnHLCMap.self, from: colData)

        #expect(colMap.entries["title"] == hlc(physical: 200))
        #expect(colMap.entries["body"]  == hlc(physical: 80), "body must survive from stale entry")
    }

    @Test("coalesce: incoming has no column HLCs → incoming columnHLCsData used as-is (nil)")
    func coalesceIncomingNoColumnHLCs() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        // Stale: has column HLCs
        let staleColMap = try columnData(["title": hlc(physical: 100)])
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 100, columnHLCsData: staleColMap),
            to: storage
        )

        // Incoming: no column HLCs (non-fieldLevelLWW write), higher HLC
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 200, columnHLCsData: nil),
            to: storage
        )

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        // Incoming had nil columnHLCsData; only one side has data so no merge:
        // incoming's nil is used as-is per "// No merge needed if only one side has column HLC data"
        #expect(batch.first?.columnHLCsData == nil)
    }

    @Test("coalesce: stale has no column HLCs → incoming columnHLCsData used as-is")
    func coalesceStaleNoColumnHLCs() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        // Stale: no column HLCs
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 50, columnHLCsData: nil),
            to: storage
        )

        // Incoming: has column HLCs, higher HLC
        let incomingColMap = try columnData(["score": hlc(physical: 200)])
        let incomingEntry = makeEntry(rowKey: rowKey, packedHLC: 200, columnHLCsData: incomingColMap)
        try await OutboxStore.append(entry: incomingEntry, to: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        // Stale had nil; incoming's data used as-is
        let colData = try #require(batch.first?.columnHLCsData)
        let colMap = try JSONDecoder().decode(ColumnHLCMap.self, from: colData)
        #expect(colMap.entries["score"] == hlc(physical: 200))
    }

    // MARK: - Standard coalescing still works (not regressed by column HLC changes)

    @Test("coalesce: without column HLCs, stale-wins still no-ops")
    func standardCoalesceStaleHigherHLCPreserved() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        // First entry with higher HLC
        let first = makeEntry(rowKey: rowKey, packedHLC: 999)
        try await OutboxStore.append(entry: first, to: storage)

        // Second entry with lower HLC → should be no-op
        let second = makeEntry(rowKey: rowKey, packedHLC: 1)
        try await OutboxStore.append(entry: second, to: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        #expect(batch.first?.id == first.id, "first entry (higher HLC) must be preserved")
    }

    @Test("coalesce: three sequential writes → only newest survives, column HLCs merged progressively")
    func coalesceThreeWrites() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        // Write 1: {title:T100}
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 100,
                             columnHLCsData: try columnData(["title": hlc(physical: 100)])),
            to: storage
        )
        // Write 2: {score:T200}
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 200,
                             columnHLCsData: try columnData(["score": hlc(physical: 200)])),
            to: storage
        )
        // Write 3: {title:T300}
        try await OutboxStore.append(
            entry: makeEntry(rowKey: rowKey, packedHLC: 300,
                             columnHLCsData: try columnData(["title": hlc(physical: 300)])),
            to: storage
        )

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        let colData = try #require(batch.first?.columnHLCsData)
        let colMap = try JSONDecoder().decode(ColumnHLCMap.self, from: colData)

        #expect(colMap.entries["title"] == hlc(physical: 300), "title: T300 from write 3")
        #expect(colMap.entries["score"] == hlc(physical: 200), "score: T200 from write 2")
    }
}
