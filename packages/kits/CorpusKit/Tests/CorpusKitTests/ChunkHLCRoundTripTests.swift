// ChunkHLCRoundTripTests.swift
//
// Verifies that a Chunk's HLC survives a round-trip through the SQLite
// backend. This test exercises BundleStore.insert → BundleStore.get via
// SQLiteStorage, which goes through the PersistenceKitSQLite unpackHLC
// path. It would FAIL against the old wrong unpack and PASS after the fix.
//
// The chunks table was the HIGH-severity victim of the HLC unpack bug
// (F-HLC-01): chunks.hlc is declared .hlc in the schema, so every
// insert would store the correct packed layout but every read would
// decode it incorrectly, corrupting the HLC comparison used by sync.
//
// INTELLECTUS LOCK: Tests that call store.insert hold GlobalTestLock
// for their entire duration to prevent concurrent telemetry tests from
// seeing spurious corpuskit.* emissions in their capturing sinks.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
import CorpusKit

@Suite("Chunk HLC SQLite round-trip", .serialized)
struct ChunkHLCRoundTripTests {

    func makeSQLiteStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-hlc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("corpus.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    @Test("chunk with known HLC survives SQLite round-trip")
    func chunkHLCRoundTripKnownAnswer() async throws {
        // physicalTime=0x0102030405, logicalCount=0x0607, nodeID=0x08 expose
        // the layout difference between the old wrong decode and the correct one.
        let original = HLC(physicalTime: 0x0102030405, logicalCount: 0x0607, nodeID: 0x08)

        try await GlobalTestLock.shared.withLock {
            let storage = try makeSQLiteStorage()
            try await storage.open(schema: BundleStore.schemaDeclaration)
            let store = BundleStore(storage: storage)

            let chunk = Chunk(
                sourceID: "doc-hlc-test",
                startOffset: 0,
                length: 5,
                text: "hello",
                hlc: original
            )
            try await store.insert([chunk])

            let fetched = try await store.get(id: chunk.id)
            #expect(fetched != nil, "chunk must be retrievable after insert")

            guard let fetched else {
                await storage.close()
                return
            }

            // Each field must match exactly. Any layout mismatch in unpackHLC
            // would show up here as a wrong physicalTime, logicalCount, or nodeID.
            #expect(fetched.hlc.physicalTime == original.physicalTime,
                    "physicalTime mismatch: \(fetched.hlc.physicalTime) ≠ \(original.physicalTime)")
            #expect(fetched.hlc.logicalCount == original.logicalCount,
                    "logicalCount mismatch: \(fetched.hlc.logicalCount) ≠ \(original.logicalCount)")
            #expect(fetched.hlc.nodeID == original.nodeID,
                    "nodeID mismatch: \(fetched.hlc.nodeID) ≠ \(original.nodeID)")
            #expect(fetched.hlc == original, "chunk HLC must be identical after SQLite round-trip")

            await storage.close()
        }
    }

    @Test("allChunks HLC ordering is correct after round-trip")
    func chunkHLCOrderingAfterRoundTrip() async throws {
        // Three chunks with different HLCs. After a round-trip through SQLite,
        // allChunks() must return them in HLC ascending order.
        let hlcA = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        let hlcB = HLC(physicalTime: 2000, logicalCount: 0, nodeID: 1)
        let hlcC = HLC(physicalTime: 3000, logicalCount: 0, nodeID: 1)

        try await GlobalTestLock.shared.withLock {
            let storage = try makeSQLiteStorage()
            try await storage.open(schema: BundleStore.schemaDeclaration)
            let store = BundleStore(storage: storage)

            // Insert in non-chronological order.
            let cB = Chunk(sourceID: "s", startOffset: 10, length: 1, text: "b", hlc: hlcB)
            let cA = Chunk(sourceID: "s", startOffset: 0, length: 1, text: "a", hlc: hlcA)
            let cC = Chunk(sourceID: "s", startOffset: 20, length: 1, text: "c", hlc: hlcC)
            try await store.insert([cB, cA, cC])

            let all = try await store.allChunks()
            #expect(all.count == 3)
            // allChunks orders by hlc ascending; verify the read-back HLCs are correct.
            #expect(all[0].hlc == hlcA, "first chunk must have smallest HLC after round-trip")
            #expect(all[1].hlc == hlcB, "second chunk must have middle HLC after round-trip")
            #expect(all[2].hlc == hlcC, "third chunk must have largest HLC after round-trip")

            await storage.close()
        }
    }
}
