// FedOutboxStoreFullWidthTests.swift
//
// Gap 6 Kong-verify follow-up (D38.1): the Swift Federation outbox
// (`FedOutboxStore`/`FedOutboxEntry`) was the one sibling gap 6's initial
// full-width-atomic pass missed — the Rust twin (federation.rs's
// `FedOutboxEntry`/`fed_outbox_append`/`fed_outbox_read_batch`) was widened
// correctly, but this Swift leg still minted `Int64(bitPattern: hlc.packed)`
// and read/wrote/ordered by the legacy `packed_hlc` column. Caught in Kong's
// adversarial verify.
//
// This test proves, at REAL HLC magnitude (parity with the Rust twin's
// vectors used throughout gap 6):
//   (a) `hlc_wire` persists and reads back byte-exact through
//       `FedOutboxStore.append`/`readBatch` — no truncation.
//   (b) coalescing (newest-wins) is decided correctly at real magnitude —
//       a newer entry for the same (table, rowKey) replaces an older one,
//       and a stale (older) append is correctly rejected.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Gap 6 Kong-verify — Swift _fed_outbox full-width round-trip + coalescing (D38.1)")
struct FedOutboxStoreFullWidthTests {

    static let truncationCeiling: Int64 = 0xFF_FFFF_FFFF
    static let olderMs: Int64 = 1_784_477_440_577
    static let newerMs: Int64 = 1_784_477_500_577

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(kitID: "TestApp", version: 1, tables: []))
        try await FederationStateActor.ensureFedSyncMetaTable(storage: storage)
        return storage
    }

    func makeEntry(rowKey: String, hlcTime: Int64, note: String) -> FedOutboxEntry {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        let payload = Data(note.utf8)
        return FedOutboxEntry(
            id: UUID(),
            tableName: "items",
            rowKey: rowKey,
            hlcWireBytes: Data(hlc.wireBytes),
            payload: payload,
            enqueuedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    @Test("(a) hlc_wire persists and reads back byte-exact at real magnitude")
    func hlcWireRoundTripsRealMagnitude() async throws {
        let storage = try await makeStorage()
        #expect(Self.newerMs > Self.truncationCeiling, "test precondition: real magnitude")

        let entry = makeEntry(rowKey: UUID().uuidString, hlcTime: Self.newerMs, note: "hello")
        try await FedOutboxStore.append(entry: entry, to: storage, table: FederationStateActor.fedOutboxTable)

        let batch = try await FedOutboxStore.readBatch(from: storage, table: FederationStateActor.fedOutboxTable)
        let recovered = try #require(batch.first)
        let decodedHLC = try HLC(wireBytes: [UInt8](recovered.hlcWireBytes))

        #expect(decodedHLC.physicalTime == Self.newerMs,
                "hlc_wire physicalTime must survive persist->read byte-exact, got \(decodedHLC.physicalTime) expected \(Self.newerMs)")
        #expect(decodedHLC.logicalCount == 0)
        #expect(decodedHLC.nodeID == 1)
        #expect(recovered.payload == Data("hello".utf8))
    }

    @Test("(b) coalescing: a newer entry replaces an older one for the same (table, rowKey), real magnitude")
    func coalescingNewerWinsRealMagnitude() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        let older = makeEntry(rowKey: rowKey, hlcTime: Self.olderMs, note: "OLDER")
        let newer = makeEntry(rowKey: rowKey, hlcTime: Self.newerMs, note: "NEWER")

        try await FedOutboxStore.append(entry: older, to: storage, table: FederationStateActor.fedOutboxTable)
        try await FedOutboxStore.append(entry: newer, to: storage, table: FederationStateActor.fedOutboxTable)

        let batch = try await FedOutboxStore.readBatch(from: storage, table: FederationStateActor.fedOutboxTable)
        #expect(batch.count == 1, "coalescing must collapse both entries into one")
        #expect(batch.first?.payload == Data("NEWER".utf8), "the newer (higher HLC) entry must survive coalescing")
    }

    @Test("(c) coalescing: a stale (older) append does not replace an existing newer entry, real magnitude")
    func coalescingStaleRejectedRealMagnitude() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        let newer = makeEntry(rowKey: rowKey, hlcTime: Self.newerMs, note: "NEWER")
        let stale = makeEntry(rowKey: rowKey, hlcTime: Self.olderMs, note: "STALE")

        try await FedOutboxStore.append(entry: newer, to: storage, table: FederationStateActor.fedOutboxTable)
        try await FedOutboxStore.append(entry: stale, to: storage, table: FederationStateActor.fedOutboxTable)

        let batch = try await FedOutboxStore.readBatch(from: storage, table: FederationStateActor.fedOutboxTable)
        #expect(batch.count == 1, "stale append must not create a second entry")
        #expect(batch.first?.payload == Data("NEWER".utf8),
                "gap 6 Kong-verify money test: a stale (older HLC) append must not overwrite a newer existing entry, at real magnitude")
    }

    @Test("(d) readBatch orders entries by HLC ascending, not insertion order, real magnitude")
    func readBatchOrdersByHLCAscending() async throws {
        let storage = try await makeStorage()

        // Insert out of HLC order to prove readBatch's Swift-side sort (not
        // SQL ORDER BY on the LE-bytes hlc_wire BLOB, which would NOT
        // preserve numeric order) — three distinct rows, distinct rowKeys.
        let a = makeEntry(rowKey: UUID().uuidString, hlcTime: Self.newerMs, note: "third")
        let b = makeEntry(rowKey: UUID().uuidString, hlcTime: Self.olderMs, note: "first")
        let c = makeEntry(rowKey: UUID().uuidString, hlcTime: (Self.olderMs + Self.newerMs) / 2, note: "second")

        try await FedOutboxStore.append(entry: a, to: storage, table: FederationStateActor.fedOutboxTable)
        try await FedOutboxStore.append(entry: b, to: storage, table: FederationStateActor.fedOutboxTable)
        try await FedOutboxStore.append(entry: c, to: storage, table: FederationStateActor.fedOutboxTable)

        let batch = try await FedOutboxStore.readBatch(from: storage, table: FederationStateActor.fedOutboxTable)
        #expect(batch.count == 3)
        #expect(batch.map { $0.payload } == [Data("first".utf8), Data("second".utf8), Data("third".utf8)],
                "readBatch must order by true HLC ascending regardless of insertion order")
    }
}
