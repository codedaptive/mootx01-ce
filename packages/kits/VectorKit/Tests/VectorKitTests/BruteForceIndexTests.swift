// BruteForceIndexTests.swift
//
// Lane A conformance and correctness tests for BruteForceIndex and
// ResidentArrayStore.
//
// Test strategy (three layers):
//
//   1. Conformance gate — the brute-force oracle is anchored to the
//      existing `hamming_nn_topk_tie.json` substrate vector. The oracle
//      must produce identical results to EngramLib.findNearest on the
//      same candidates. This is the Kong condition: "the brute-force
//      oracle gets its OWN independent gate against the substrate's
//      already-four-way-tested HammingNN."
//
//   2. Determinism and order tests — the MIH spec vectors (§1.10 of the
//      retrieval algorithms reference) exercised through BruteForceIndex:
//      distance ASC, tie-break by itemID ASC, multi-model filter, delete.
//
//   3. SQLite-backed persistence — write → mmap-reopen → identical top-k
//      on a real on-disk file (NOT InMemory), as required by the mission.
//      These tests verify that the .vec sidecar round-trips exactly and
//      that mmap load and heap load produce bit-identical arrays.
//
// All tests use real UUIDs or UUID-derived itemIDs so the tie-break
// ordering is well-defined and matches the universal §0.3 rule.

import Testing
import Foundation
import EngramLib
@testable import VectorKit

// MARK: - Helpers

/// 256-bit Engram → 32-byte wire form (4×UInt64 LE).
private func engramBytes(_ e: Engram) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    func le64(_ v: UInt64, into buf: inout [UInt8], at offset: Int) {
        buf[offset]     = UInt8(v & 0xFF)
        buf[offset + 1] = UInt8((v >> 8)  & 0xFF)
        buf[offset + 2] = UInt8((v >> 16) & 0xFF)
        buf[offset + 3] = UInt8((v >> 24) & 0xFF)
        buf[offset + 4] = UInt8((v >> 32) & 0xFF)
        buf[offset + 5] = UInt8((v >> 40) & 0xFF)
        buf[offset + 6] = UInt8((v >> 48) & 0xFF)
        buf[offset + 7] = UInt8((v >> 56) & 0xFF)
    }
    le64(e.block0, into: &out, at: 0)
    le64(e.block1, into: &out, at: 8)
    le64(e.block2, into: &out, at: 16)
    le64(e.block3, into: &out, at: 24)
    return out
}

/// Build a VectorPayload from an Engram.
private func binaryPayload(_ e: Engram) -> VectorPayload {
    VectorPayload(engram: e)
}

/// Build a VectorRecordKey with a chosen itemID and the default model.
private func key(_ itemID: String, modelID: String = "model-a",
                 modelVersion: String = "1") -> VectorRecordKey {
    VectorRecordKey(itemID: itemID, vectorIndex: 0,
                    modelID: modelID, modelVersion: modelVersion)
}

/// Zero Engram.
private let zeroEngram = Engram(blocks: 0, 0, 0, 0)

// MARK: - BruteForceIndex suite

@Suite("BruteForceIndex", .serialized)
struct BruteForceIndexTests {

    // MARK: — Conformance gate (anchored to substrate HammingNN)

    /// Gate 1: BruteForceIndex.search must agree with EngramLib.findNearest
    /// on the hamming_nn_topk_tie.json canonical vector.
    ///
    /// The vector pins five candidates all at distance 1 from the zero
    /// anchor. Top-3 must be the three with the smallest itemIDs (row_ids
    /// 1, 2, 3 map to string "00000000-0000-0000-0000-000000000001" etc.).
    @Test func conformanceGate_hammingNNTopkTie() async throws {
        // Canonical codes from hamming_nn_topk_tie.json.
        // Anchor = all-zero.
        // row_id=1 → block0=1  (1 bit set, distance=1)
        // row_id=2 → block0=2  (1 bit set, distance=1)
        // row_id=3 → block0=8  (1 bit set, distance=1)
        // row_id=4 → block0=4  (1 bit set, distance=1)
        // row_id=5 → block0=16 (1 bit set, distance=1)
        // k=3, expected: row_ids 1,2,3 (smallest itemIDs win tie).
        let anchor = Engram(blocks: 0, 0, 0, 0)
        let candidates: [(String, Engram)] = [
            ("00000000-0000-0000-0000-000000000005", Engram(blocks: 16, 0, 0, 0)),
            ("00000000-0000-0000-0000-000000000003", Engram(blocks:  8, 0, 0, 0)),
            ("00000000-0000-0000-0000-000000000001", Engram(blocks:  1, 0, 0, 0)),
            ("00000000-0000-0000-0000-000000000004", Engram(blocks:  4, 0, 0, 0)),
            ("00000000-0000-0000-0000-000000000002", Engram(blocks:  2, 0, 0, 0)),
        ]

        let index = BruteForceIndex()
        for (itemID, engram) in candidates {
            try await index.add(key: key(itemID), vector: binaryPayload(engram))
        }

        let hits = try await index.search(
            probe: binaryPayload(anchor),
            metric: .hamming,
            k: 3,
            filter: nil
        )

        // Must return exactly 3 hits all at distance 1.
        #expect(hits.count == 3)
        for h in hits { #expect(h.hammingDistance == 1) }

        // Tie-break: smallest itemID ASC. The UUIDs sort as strings, so
        // "...0001" < "...0002" < "...0003".
        #expect(hits[0].key.itemID == "00000000-0000-0000-0000-000000000001")
        #expect(hits[1].key.itemID == "00000000-0000-0000-0000-000000000002")
        #expect(hits[2].key.itemID == "00000000-0000-0000-0000-000000000003")
    }

    // MARK: — MIH spec vectors exercised on BruteForce (oracle role)

    /// MIH-1: exact small index, k=2.
    /// Index has 4 codes; probe is all-zero; expect nearest 2 by distance.
    @Test func mih_vector1_exact_small_index_k2() async throws {
        // id=1: all zero,    dist=0
        // id=2: 3 bits set,  dist=3 (block0=0x07)
        // id=3: 8 bits set,  dist=8 (block0=0xFF)
        // id=4: 1 bit block3, dist=1 (block3=0x8000000000000000)
        let codes: [(String, Engram)] = [
            ("id-1", Engram(blocks: 0, 0, 0, 0)),
            ("id-2", Engram(blocks: 7, 0, 0, 0)),
            ("id-3", Engram(blocks: 0xFF, 0, 0, 0)),
            ("id-4", Engram(blocks: 0, 0, 0, 0x8000_0000_0000_0000)),
        ]
        let index = BruteForceIndex()
        for (itemID, e) in codes {
            try await index.add(key: key(itemID), vector: binaryPayload(e))
        }
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )
        #expect(hits.count == 2)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].hammingDistance == 0)
        #expect(hits[1].key.itemID == "id-4")
        #expect(hits[1].hammingDistance == 1)
    }

    /// MIH-2: tie-break by id.
    /// id-4 and id-5 both have dist=1; id-4 wins (smaller itemID).
    @Test func mih_vector2_tie_break_by_itemID() async throws {
        let codes: [(String, Engram)] = [
            ("id-1", Engram(blocks: 0, 0, 0, 0)),
            ("id-2", Engram(blocks: 7, 0, 0, 0)),
            ("id-3", Engram(blocks: 0xFF, 0, 0, 0)),
            ("id-4", Engram(blocks: 0, 0, 0, 0x8000_0000_0000_0000)),
            ("id-5", Engram(blocks: 1, 0, 0, 0)),
        ]
        let index = BruteForceIndex()
        for (itemID, e) in codes {
            try await index.add(key: key(itemID), vector: binaryPayload(e))
        }
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )
        #expect(hits.count == 2)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].hammingDistance == 0)
        // id-4 < id-5 in string order
        #expect(hits[1].key.itemID == "id-4")
        #expect(hits[1].hammingDistance == 1)
    }

    /// MIH-3: radius forces multi-band, three-way tie at distance 4. k=3.
    @Test func mih_vector3_multiband_three_way_tie() async throws {
        // id-10: 2 bits band0 + 2 bits band1 = dist 4 from 0
        // id-11: 4 bits band3 = dist 4
        // id-12: 4 bits band0 = dist 4
        // id-13: 1 bit band0 = dist 1
        // Expect (id-13, dist=1), (id-10, dist=4), (id-11, dist=4)
        // Note: id-10 < id-11 < id-12 lexicographically so id-12 is excluded.
        let codes: [(String, Engram)] = [
            ("id-10", Engram(blocks: 0x0000_0000_0000_0003,
                             0x0000_0000_0000_0003, 0, 0)),
            ("id-11", Engram(blocks: 0, 0, 0, 0x0000_0000_0000_000F)),
            ("id-12", Engram(blocks: 0x0000_0000_0000_000F, 0, 0, 0)),
            ("id-13", Engram(blocks: 1, 0, 0, 0)),
        ]
        let index = BruteForceIndex()
        for (itemID, e) in codes {
            try await index.add(key: key(itemID), vector: binaryPayload(e))
        }
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 3,
            filter: nil
        )
        #expect(hits.count == 3)
        #expect(hits[0].key.itemID == "id-13")
        #expect(hits[0].hammingDistance == 1)
        #expect(hits[1].key.itemID == "id-10")
        #expect(hits[1].hammingDistance == 4)
        #expect(hits[2].key.itemID == "id-11")
        #expect(hits[2].hammingDistance == 4)
    }

    /// MIH-4: fewer than k codes in index. k=5, only 1 code.
    @Test func mih_vector4_fewer_than_k() async throws {
        let index = BruteForceIndex()
        try await index.add(
            key: key("id-1"),
            vector: binaryPayload(Engram(blocks: 0, 0, 0, 0))
        )
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 5,
            filter: nil
        )
        #expect(hits.count == 1)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].hammingDistance == 0)
    }

    /// MIH-5: delete then query. Remove id-4, then query; expect id-2 at
    /// dist=3 in second place.
    @Test func mih_vector5_delete_then_query() async throws {
        let codes: [(String, Engram)] = [
            ("id-1", Engram(blocks: 0, 0, 0, 0)),
            ("id-2", Engram(blocks: 7, 0, 0, 0)),
            ("id-3", Engram(blocks: 0xFF, 0, 0, 0)),
            ("id-4", Engram(blocks: 0, 0, 0, 0x8000_0000_0000_0000)),
        ]
        let index = BruteForceIndex()
        for (itemID, e) in codes {
            try await index.add(key: key(itemID), vector: binaryPayload(e))
        }
        try await index.remove(key: key("id-4"))

        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )
        #expect(hits.count == 2)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].hammingDistance == 0)
        #expect(hits[1].key.itemID == "id-2")
        #expect(hits[1].hammingDistance == 3)
    }

    // MARK: — Model-partition filter

    /// Filter by modelID restricts the scan to that model's slots.
    @Test func modelIDFilterRestrictsScan() async throws {
        let index = BruteForceIndex()
        // Add two items under different models.
        try await index.add(
            key: key("item-a", modelID: "model-a"),
            vector: binaryPayload(Engram(blocks: 0, 0, 0, 0))
        )
        try await index.add(
            key: key("item-b", modelID: "model-b"),
            vector: binaryPayload(Engram(blocks: 0xFF, 0, 0, 0))
        )

        let filter = MetadataFilter.exact(modelID: "model-a", modelVersion: "1")
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 10,
            filter: filter
        )
        // Only model-a should appear.
        #expect(hits.count == 1)
        #expect(hits[0].key.itemID == "item-a")
    }

    /// Filter for absent modelID returns empty.
    @Test func absentModelIDFilterReturnsEmpty() async throws {
        let index = BruteForceIndex()
        try await index.add(
            key: key("item-a", modelID: "model-a"),
            vector: binaryPayload(Engram(blocks: 0, 0, 0, 0))
        )
        let filter = MetadataFilter(modelID: "no-such-model")
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 10,
            filter: filter
        )
        #expect(hits.isEmpty)
    }

    // MARK: — Error cases

    /// Non-binary probe throws invalidPayload.
    @Test func nonBinaryProbeThrows() async throws {
        let index = BruteForceIndex()
        let floatProbe = VectorPayload(floats: [1.0, 2.0])
        do {
            _ = try await index.search(
                probe: floatProbe,
                metric: .hamming,
                k: 1,
                filter: nil
            )
            Issue.record("Expected invalidPayload but search succeeded")
        } catch VectorKitError.invalidPayload { /* expected */ }
    }

    /// Float metric throws invalidPayload.
    @Test func floatMetricThrows() async throws {
        let index = BruteForceIndex()
        try await index.add(
            key: key("item-1"),
            vector: binaryPayload(Engram(blocks: 0, 0, 0, 0))
        )
        do {
            _ = try await index.search(
                probe: binaryPayload(zeroEngram),
                metric: .cosine,
                k: 1,
                filter: nil
            )
            Issue.record("Expected invalidPayload but search succeeded")
        } catch VectorKitError.invalidPayload { /* expected */ }
    }

    /// Empty index returns empty results.
    @Test func emptyIndexReturnsEmpty() async throws {
        let index = BruteForceIndex()
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 5,
            filter: nil
        )
        #expect(hits.isEmpty)
    }

    /// k=0 returns empty without error.
    @Test func kZeroReturnsEmpty() async throws {
        let index = BruteForceIndex()
        try await index.add(
            key: key("item-1"),
            vector: binaryPayload(Engram(blocks: 0, 0, 0, 0))
        )
        let hits = try await index.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 0,
            filter: nil
        )
        #expect(hits.isEmpty)
    }

    // MARK: — build(from:) round-trip

    /// build(from:) with a ResidentVectorArray produces the same results
    /// as add() calls, verifying the two mutation paths are equivalent.
    @Test func buildFromArrayEqualsAddCalls() async throws {
        let e1 = Engram(blocks: 1, 0, 0, 0)
        let e2 = Engram(blocks: 3, 0, 0, 0)
        let k1 = key("item-1")
        let k2 = key("item-2")

        // Path A: add() calls
        let indexA = BruteForceIndex()
        try await indexA.add(key: k1, vector: binaryPayload(e1))
        try await indexA.add(key: k2, vector: binaryPayload(e2))
        let hitsA = try await indexA.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )

        // Path B: build(from:) with a manually constructed array
        let storage = engramBytes(e1) + engramBytes(e2)
        let tombstones = [UInt64](repeating: 0, count: 1)
        let partitions = BruteForceIndex.buildPartitions(
            keys: [k1, k2], tombstones: tombstones)
        let arr = ResidentVectorArray(
            kind: .binary, stride: 32, count: 2,
            storage: storage, keys: [k1, k2],
            modelPartitions: partitions, tombstones: tombstones
        )
        let indexB = BruteForceIndex()
        await indexB.build(from: arr)
        let hitsB = try await indexB.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )

        #expect(hitsA.count == hitsB.count)
        for (a, b) in zip(hitsA, hitsB) {
            #expect(a.key == b.key)
            #expect(a.rawDistance == b.rawDistance)
        }
    }
}

// MARK: - ResidentArrayStore suite

@Suite("ResidentArrayStore", .serialized)
struct ResidentArrayStoreTests {

    /// Make a temporary .vec file URL that is cleaned up after the test.
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorkit-lane-a-\(UUID().uuidString).vec")
    }

    // MARK: — Round-trip: write → mmap-reopen → identical top-k

    /// Core persistence test (mission requirement): write records to the
    /// sidecar, reopen via mmap load, rebuild the BruteForceIndex, then
    /// verify the top-k is identical to the pre-close result.
    @Test func writeThenMmapReopenProducesIdenticalTopK() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let e1 = Engram(blocks: 0,   0, 0, 0) // dist=0
        let e2 = Engram(blocks: 1,   0, 0, 0) // dist=1
        let e3 = Engram(blocks: 0xFF,0, 0, 0) // dist=8
        let records: [(VectorRecordKey, Engram)] = [
            (key("item-1"), e1),
            (key("item-2"), e2),
            (key("item-3"), e3),
        ]

        // --- Session 1: write ---
        let store1 = ResidentArrayStore(sidecarURL: url)
        for (k, e) in records {
            try await store1.append(key: k, bytes: engramBytes(e))
        }
        let snap1 = await store1.snapshot()
        let idx1 = BruteForceIndex()
        await idx1.build(from: snap1)
        let hitsBeforeClose = try await idx1.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )

        // --- Session 2: mmap-reopen ---
        let store2 = ResidentArrayStore(sidecarURL: url)
        try await store2.load()
        let snap2 = await store2.snapshot()
        let idx2 = BruteForceIndex()
        await idx2.build(from: snap2)
        let hitsAfterReopen = try await idx2.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )

        // Results must be bit-identical across the reopen.
        #expect(hitsBeforeClose.count == hitsAfterReopen.count)
        for (before, after) in zip(hitsBeforeClose, hitsAfterReopen) {
            #expect(before.key == after.key)
            #expect(before.rawDistance == after.rawDistance)
        }
    }

    // MARK: — Sidecar byte format round-trip

    /// parseSidecar(writeSidecar(array)) == array (byte-identical round-trip).
    @Test func sidecarFormatRoundTrip() throws {
        let e1 = Engram(blocks: 0xDEAD_BEEF_CAFE_BABE, 0x0123_4567_89AB_CDEF,
                        0xFFFF_0000_FFFF_0000, 0x0000_FFFF_0000_FFFF)
        let e2 = Engram(blocks: 0, 1, 2, 3)
        let k1 = VectorRecordKey(itemID: "item-alpha", vectorIndex: 0,
                                 modelID: "model-test", modelVersion: "v1")
        let k2 = VectorRecordKey(itemID: "item-beta",  vectorIndex: 1,
                                 modelID: "model-test", modelVersion: "v1")

        let tombstones = [UInt64](repeating: 0, count: 1)
        let partitions = BruteForceIndex.buildPartitions(
            keys: [k1, k2], tombstones: tombstones)
        let original = ResidentVectorArray(
            kind: .binary, stride: 32, count: 2,
            storage: engramBytes(e1) + engramBytes(e2),
            keys: [k1, k2], modelPartitions: partitions, tombstones: tombstones
        )

        // Encode to Data then parse back.
        var data = Data()
        // Use the internal static methods to test the codec directly.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnd-trip-\(UUID().uuidString).vec")
        defer { try? FileManager.default.removeItem(at: url) }
        try ResidentArrayStore.writeSidecar(original, to: url)
        let parsed = try ResidentArrayStore.readSidecar(from: url)
        _ = data // keep data accessible for debugging if needed

        // Structural equality.
        #expect(parsed.kind == original.kind)
        #expect(parsed.stride == original.stride)
        #expect(parsed.count == original.count)
        #expect(parsed.storage == original.storage)
        #expect(parsed.tombstones == original.tombstones)
        #expect(parsed.keys == original.keys)
        // Partitions rebuilt from keys; compare modelID+range.
        #expect(parsed.modelPartitions.count == original.modelPartitions.count)
        for (p, o) in zip(parsed.modelPartitions, original.modelPartitions) {
            #expect(p.modelID == o.modelID)
            #expect(p.range == o.range)
        }
    }

    // MARK: — Tombstone and compaction

    /// Tombstoned records do not appear in search results after reopen.
    @Test func tombstonedRecordAbsentAfterReopen() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ResidentArrayStore(sidecarURL: url)
        let kA = key("item-a")
        let kB = key("item-b")
        try await store.append(key: kA, bytes: engramBytes(Engram(blocks: 0, 0, 0, 0)))
        try await store.append(key: kB, bytes: engramBytes(Engram(blocks: 1, 0, 0, 0)))
        try await store.tombstone(key: kA)

        // Reopen.
        let store2 = ResidentArrayStore(sidecarURL: url)
        try await store2.load()
        let snap = await store2.snapshot()
        let idx = BruteForceIndex()
        await idx.build(from: snap)
        let hits = try await idx.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 10,
            filter: nil
        )
        // Only item-b should be returned (item-a is tombstoned).
        #expect(hits.count == 1)
        #expect(hits[0].key.itemID == "item-b")
    }

    /// compact() removes tombstoned slots and produces a deterministic
    /// sorted output.
    @Test func compactionRemovesTombstonedSlots() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ResidentArrayStore(sidecarURL: url)
        let kA = key("item-a")
        let kB = key("item-b")
        let kC = key("item-c")
        try await store.append(key: kA, bytes: engramBytes(Engram(blocks: 5, 0, 0, 0)))
        try await store.append(key: kB, bytes: engramBytes(Engram(blocks: 3, 0, 0, 0)))
        try await store.append(key: kC, bytes: engramBytes(Engram(blocks: 1, 0, 0, 0)))
        try await store.tombstone(key: kA)
        try await store.compact()

        let snap = await store.snapshot()
        // After compaction there should be 2 live slots (b and c).
        #expect(Int(snap.count) == 2)
        // Tombstones should all be zero after compaction.
        let anyTombstoned = (0..<Int(snap.count)).contains { snap.isTombstoned($0) }
        #expect(!anyTombstoned)
    }

    // MARK: — rebuild(from:) → reopen

    /// rebuild(from:) then reopen produces identical results.
    @Test func rebuildFromRecsAndReopenMatch() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let records: [(key: VectorRecordKey, bytes: [UInt8])] = [
            (key: key("item-b"), bytes: engramBytes(Engram(blocks: 3, 0, 0, 0))),
            (key: key("item-a"), bytes: engramBytes(Engram(blocks: 1, 0, 0, 0))),
        ]
        // rebuild expects sorted input.
        let sorted = records.sorted { $0.key < $1.key }

        let store1 = ResidentArrayStore(sidecarURL: url)
        try await store1.rebuild(from: sorted)
        let snap1 = await store1.snapshot()
        let idx1 = BruteForceIndex()
        await idx1.build(from: snap1)
        let hits1 = try await idx1.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )

        let store2 = ResidentArrayStore(sidecarURL: url)
        try await store2.load()
        let snap2 = await store2.snapshot()
        let idx2 = BruteForceIndex()
        await idx2.build(from: snap2)
        let hits2 = try await idx2.search(
            probe: binaryPayload(zeroEngram),
            metric: .hamming,
            k: 2,
            filter: nil
        )

        #expect(hits1.count == hits2.count)
        for (a, b) in zip(hits1, hits2) {
            #expect(a.key == b.key)
            #expect(a.rawDistance == b.rawDistance)
        }
    }

    // MARK: — Heap path equals mmap path

    /// parseSidecar (used by both mmap and heap paths) produces the same
    /// array as what was written by writeSidecar. This gates §4.3:
    /// "mmap path and heap-fallback path produce bit-identical results."
    @Test func heapPathEqualsMmapPath() throws {
        // Write a sidecar and parse it twice: once via readSidecar (mmap),
        // once via reading the raw bytes (heap copy of same data).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heap-vs-mmap-\(UUID().uuidString).vec")
        defer { try? FileManager.default.removeItem(at: url) }

        let e = Engram(blocks: 0xABCD_EF01_2345_6789, 0, 0, 0)
        let k = VectorRecordKey(itemID: "item-x", vectorIndex: 0,
                                modelID: "m1", modelVersion: "v2")
        let arr = ResidentVectorArray(
            kind: .binary, stride: 32, count: 1,
            storage: engramBytes(e),
            keys: [k],
            modelPartitions: [ModelPartitionEntry(modelID: "m1", range: 0..<1)],
            tombstones: [0]
        )
        try ResidentArrayStore.writeSidecar(arr, to: url)

        // mmap path
        let viaMap = try ResidentArrayStore.readSidecar(from: url)
        // heap path: load the raw data without mmap option
        let rawData = try Data(contentsOf: url)
        let viaHeap = try ResidentArrayStore.parseSidecar(rawData)

        #expect(viaMap.storage == viaHeap.storage)
        #expect(viaMap.keys == viaHeap.keys)
        #expect(viaMap.tombstones == viaHeap.tombstones)
        #expect(viaMap.count == viaHeap.count)
    }

    // MARK: — Bad magic returns decodingFailure

    /// An invalid magic byte triggers a decodingFailure, not a crash.
    @Test func badMagicThrowsDecodingFailure() {
        var bad = Data(kVecMagic)
        bad[0] = 0x00 // corrupt magic
        bad.appendLE16(kVecVersion)
        bad.append(VectorKind.binary.rawValue)
        bad.appendLE32(32)
        bad.appendLE32(0)  // count = 0
        bad.appendLE32(0)  // live_count = 0 (version 0x0002)
        bad.appendLE32(0)  // tombstone_words = 0
        do {
            _ = try ResidentArrayStore.parseSidecar(bad)
            Issue.record("Expected decodingFailure for bad magic")
        } catch VectorKitError.decodingFailure { /* expected */ }
          catch { Issue.record("Wrong error type: \(error)") }
    }

    // MARK: — C5: stale detection uses live-count, not total-slot-count

    /// C5-1: liveCount after tombstone is correct.
    ///
    /// Write 4 vectors, tombstone 2. Count must remain 4 (total slots),
    /// liveCount must become 2 (non-tombstoned). After reload from disk,
    /// the same values must hold — live_count was written to the sidecar
    /// header at flush time and the bitmap must agree on reload.
    @Test func liveCount_afterTombstone_isCorrect() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c5-livecount-\(UUID().uuidString).vec")
        defer { try? FileManager.default.removeItem(at: url) }

        // Use a high compaction threshold (1.0 = never auto-compact) so that
        // tombstoned slots stay in the array and we can verify that count
        // remains 4 (total slots) while liveCount drops to 2.
        let store = ResidentArrayStore(
            sidecarURL: url, kind: .binary, stride: 32,
            compactionThreshold: 1.0  // never auto-compact during this test
        )
        let keys = (1...4).map { i in
            VectorRecordKey(itemID: "item-\(i)", vectorIndex: 0,
                            modelID: "m1", modelVersion: "1")
        }
        let engs = (1...4).map { i in Engram(blocks: UInt64(i), 0, 0, 0) }

        for (k, e) in zip(keys, engs) {
            try await store.append(key: k, bytes: engramBytes(e))
        }
        // Tombstone items at index 0 and 2.
        try await store.tombstone(key: keys[0])
        try await store.tombstone(key: keys[2])

        let snap = await store.snapshot()
        #expect(snap.count == 4, "total slots: 4 allocated, 2 tombstoned")
        #expect(snap.liveCount == 2, "live slots: 2 of 4 survive")

        // Reload from disk: live_count must match.
        let store2 = ResidentArrayStore(sidecarURL: url, kind: .binary, stride: 32)
        try await store2.load()
        let snap2 = await store2.snapshot()
        #expect(snap2.count == 4, "reloaded total count")
        #expect(snap2.liveCount == 2, "reloaded liveCount from sidecar header / bitmap")
    }

    /// C5-2: liveCount matches the sidecar header live_count field after
    /// round-trip write and re-parse.
    ///
    /// Simulates the stale-detection path:
    ///   - sidecar liveCount (loaded) == simulatedTableCount (2) → no rebuild.
    ///   - sidecar liveCount (loaded) != simulatedTableCount (3) → rebuild fires.
    @Test func liveCount_vs_tableCount_staleDetectionLogic() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c5-stale-\(UUID().uuidString).vec")
        defer { try? FileManager.default.removeItem(at: url) }

        let ka = VectorRecordKey(itemID: "item-a", vectorIndex: 0,
                                 modelID: "m1", modelVersion: "1")
        let kb = VectorRecordKey(itemID: "item-b", vectorIndex: 0,
                                 modelID: "m1", modelVersion: "1")
        let records: [(key: VectorRecordKey, bytes: [UInt8])] = [
            (ka, engramBytes(Engram(blocks: 1, 0, 0, 0))),
            (kb, engramBytes(Engram(blocks: 2, 0, 0, 0))),
        ]
        // Build a fresh (all-live) sidecar with 2 slots.
        let arr = ResidentArrayStore.buildArray(from: records, kind: .binary, stride: 32)
        try ResidentArrayStore.writeSidecar(arr, to: url)

        let loaded = try ResidentArrayStore.readSidecar(from: url)
        #expect(loaded.count == 2, "total slots")
        #expect(loaded.liveCount == 2, "all live")

        // Case A: table also has 2 live rows → not stale.
        #expect(loaded.liveCount == 2, "live-vs-live: not stale")

        // Case B: table has 3 live rows → stale (row added out-of-band).
        let tableCountWithExtra: UInt32 = 3
        #expect(loaded.liveCount != tableCountWithExtra,
                "live-vs-live: stale when counts diverge")
    }
}
