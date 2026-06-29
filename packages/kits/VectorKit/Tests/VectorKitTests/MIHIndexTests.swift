// MIHIndexTests.swift
//
// Lane B conformance tests for MIHIndex.
//
// Test strategy (four layers — the Kong condition from §3.3 of the arch spec):
//
//   1. Canonical spec vectors (MIH-1..5) — run through MIHIndex and assert
//      the exact ordered (itemID, dist) results specified in §1.10 of the
//      retrieval algorithms reference.
//
//   2. MIH == BruteForce gate on canonical vectors — run the same inputs
//      through BruteForceIndex and assert bit-for-bit identical output.
//      BruteForceIndex is always the oracle; if they disagree, MIH is wrong.
//
//   3. Randomised fuzz cross-check — many seeds, varied n/k values, all
//      four m values {4,8,16,32}. For each configuration:
//        - build both MIHIndex and BruteForceIndex from the same random codes,
//        - run the same random probe,
//        - assert the output is bit-for-bit identical (same hits, same order,
//          same distances, same itemIDs).
//      This gates the exactness claim itself; the fixed vectors only pin
//      corner cases (ties, radius expansion, deletes).
//
//   4. Sidecar-backed resident-array persistence — build MIHIndex, persist
//      state to a real on-disk .vec file via ResidentArrayStore, reopen,
//      rebuild MIHIndex from the loaded array, assert identical results.
//      Tests run on a real .vec sidecar, NOT InMemory.
//
// All tests use the canonical §0.3 itemID tie-break: smaller itemID wins.

import Testing
import Foundation
import EngramLib
@testable import VectorKit

// MARK: - Test helpers

/// Build a VectorPayload from 4 u64 blocks (canonical §0.1 layout).
private func payload(b0: UInt64, b1: UInt64 = 0, b2: UInt64 = 0, b3: UInt64 = 0) -> VectorPayload {
    VectorPayload(engram: Engram(blocks: b0, b1, b2, b3))
}

/// Zero payload (all blocks zero).
private let zeroPayload = VectorPayload(engram: Engram(blocks: 0, 0, 0, 0))

/// Build a VectorRecordKey with itemID and default model.
private func key(_ itemID: String,
                 modelID: String = "model-a",
                 modelVersion: String = "1") -> VectorRecordKey {
    VectorRecordKey(itemID: itemID, vectorIndex: 0,
                    modelID: modelID, modelVersion: modelVersion)
}

/// Canonical 32-byte wire form of an Engram (4×UInt64 LE).
private func engramBytes(b0: UInt64, b1: UInt64 = 0, b2: UInt64 = 0, b3: UInt64 = 0) -> [UInt8] {
    let e = Engram(blocks: b0, b1, b2, b3)
    return e.wireBytes
}

/// Simple deterministic pseudo-random u64 (xorshift64 seeded).
private func xorshift64(_ state: inout UInt64) -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
}

/// Generate `count` distinct random VectorPayload/VectorRecordKey pairs
/// using the given seed.
private func randomPayloads(
    count: Int,
    seed: UInt64,
    modelID: String = "model-a",
    modelVersion: String = "1"
) -> [(key: VectorRecordKey, payload: VectorPayload)] {
    var state = seed
    return (0..<count).map { i in
        let b0 = xorshift64(&state)
        let b1 = xorshift64(&state)
        let b2 = xorshift64(&state)
        let b3 = xorshift64(&state)
        let itemID = "item-\(String(format: "%08d", i))"
        return (
            key: VectorRecordKey(itemID: itemID, vectorIndex: 0,
                                 modelID: modelID, modelVersion: modelVersion),
            payload: VectorPayload(engram: Engram(blocks: b0, b1, b2, b3))
        )
    }
}

/// Assert that two DenseHit arrays are identical (same count, same order,
/// same distances, same keys). This is the Kong condition gate.
private func assertHitsIdentical(
    _ mih: [DenseHit],
    _ brute: [DenseHit],
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    #expect(mih.count == brute.count,
            "\(context): count mismatch mih=\(mih.count) brute=\(brute.count)",
            sourceLocation: sourceLocation)
    let n = min(mih.count, brute.count)
    for i in 0..<n {
        #expect(mih[i].key.itemID == brute[i].key.itemID,
                "\(context) hit[\(i)]: itemID mih=\(mih[i].key.itemID) brute=\(brute[i].key.itemID)",
                sourceLocation: sourceLocation)
        #expect(mih[i].rawDistance == brute[i].rawDistance,
                "\(context) hit[\(i)]: dist mih=\(mih[i].rawDistance) brute=\(brute[i].rawDistance)",
                sourceLocation: sourceLocation)
    }
}

// MARK: - Suite 1: Canonical spec vectors (MIH-1..5)

@Suite("MIHIndex canonical vectors", .serialized)
struct MIHIndexCanonicalVectors {

    // MARK: MIH-1: exact small index, k=2

    /// §1.10 MIH-1: 4-item index, m=4, probe=all-zero, k=2.
    /// id=1 at dist=0, id=4 at dist=1, id=2 at dist=3, id=3 at dist=8.
    /// Expected: [(id-1, 0), (id-4, 1)].
    @Test func mih1_exactSmallIndex_k2() async throws {
        let mih = MIHIndex(bandCount: .m4)
        // §1.10 loader: hex MSB-first → w[3]=first 16 hex chars, w[0]=last 16.
        // id=1: all-zero.
        // id=2: 0x07 in w[0] (block0) = 3 bits set, dist=3.
        // id=3: 0xFF in w[0] = 8 bits set, dist=8.
        // id=4: MSB of w[3] (block3) set = 1 bit, dist=1.
        try await mih.add(key: key("id-1"), vector: payload(b0: 0, b1: 0, b2: 0, b3: 0))
        try await mih.add(key: key("id-2"), vector: payload(b0: 7))
        try await mih.add(key: key("id-3"), vector: payload(b0: 0xFF))
        try await mih.add(key: key("id-4"), vector: payload(b0: 0, b1: 0, b2: 0, b3: 0x8000_0000_0000_0000))

        let hits = try await mih.search(
            probe: zeroPayload, metric: .hamming, k: 2, filter: nil)

        #expect(hits.count == 2)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].rawDistance == 0)
        #expect(hits[1].key.itemID == "id-4")
        #expect(hits[1].rawDistance == 1)
    }

    // MARK: MIH-2: tie-break by id

    /// §1.10 MIH-2: add id-5 (dist=1) to the MIH-1 index. id-4 and id-5
    /// both at dist=1. id-4 < id-5 so id-4 wins second slot.
    /// Expected: [(id-1, 0), (id-4, 1)].
    @Test func mih2_tieBreakByItemID() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("id-1"), vector: payload(b0: 0, b1: 0, b2: 0, b3: 0))
        try await mih.add(key: key("id-2"), vector: payload(b0: 7))
        try await mih.add(key: key("id-3"), vector: payload(b0: 0xFF))
        try await mih.add(key: key("id-4"), vector: payload(b0: 0, b1: 0, b2: 0, b3: 0x8000_0000_0000_0000))
        try await mih.add(key: key("id-5"), vector: payload(b0: 1))  // dist=1, id-5 > id-4

        let hits = try await mih.search(
            probe: zeroPayload, metric: .hamming, k: 2, filter: nil)

        #expect(hits.count == 2)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].rawDistance == 0)
        // id-4 < id-5 in string order — id-4 should win the second slot.
        #expect(hits[1].key.itemID == "id-4")
        #expect(hits[1].rawDistance == 1)
    }

    // MARK: MIH-3: radius forces multi-band, k=3

    /// §1.10 MIH-3: m=4, three-way tie at dist=4.
    ///
    /// id-10: 2 bits in band0 (block0) + 2 bits in band1 (block1) = dist 4.
    ///   This code distributes its 4 differing bits across two bands (2+2).
    ///   At r=4, rho=⌊4/4⌋=1. Band0 and band1 each differ by 2 > rho=1,
    ///   but band2 and band3 match exactly (rho=1 covers the match bands).
    ///   The stopping rule ensures we reach id-10 once r >= 4.
    ///
    /// id-11: 4 bits in band3 (block3) = dist 4.
    /// id-12: 4 bits in band0 (block0) = dist 4.
    /// id-13: 1 bit in band0 = dist 1.
    ///
    /// Expected: [(id-13,1), (id-10,4), (id-11,4)].
    /// id-12 is excluded: id-10 < id-11 < id-12 so id-12 loses the boundary tie.
    @Test func mih3_multiBandThreeWayTie_k3() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("id-10"), vector: payload(b0: 3, b1: 3, b2: 0, b3: 0))
        try await mih.add(key: key("id-11"), vector: payload(b0: 0, b1: 0, b2: 0, b3: 0x0F))
        try await mih.add(key: key("id-12"), vector: payload(b0: 0x0F))
        try await mih.add(key: key("id-13"), vector: payload(b0: 1))

        let hits = try await mih.search(
            probe: zeroPayload, metric: .hamming, k: 3, filter: nil)

        #expect(hits.count == 3)
        #expect(hits[0].key.itemID == "id-13")
        #expect(hits[0].rawDistance == 1)
        #expect(hits[1].key.itemID == "id-10")
        #expect(hits[1].rawDistance == 4)
        #expect(hits[2].key.itemID == "id-11")
        #expect(hits[2].rawDistance == 4)
    }

    // MARK: MIH-4: fewer than k codes

    /// §1.10 MIH-4: index has only 1 code; k=5.
    /// Expected: [(id-1, 0)] — length 1.
    @Test func mih4_fewerThanKCodes() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("id-1"), vector: payload(b0: 0))

        let hits = try await mih.search(
            probe: zeroPayload, metric: .hamming, k: 5, filter: nil)

        #expect(hits.count == 1)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].rawDistance == 0)
    }

    // MARK: MIH-5: delete then query

    /// §1.10 MIH-5: start from MIH-1 index, delete id-4, query k=2.
    /// Expected: [(id-1,0), (id-2,3)] — id-4 absent, id-2 at dist=3 is next.
    @Test func mih5_deleteThenQuery() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("id-1"), vector: payload(b0: 0))
        try await mih.add(key: key("id-2"), vector: payload(b0: 7))
        try await mih.add(key: key("id-3"), vector: payload(b0: 0xFF))
        try await mih.add(key: key("id-4"), vector: payload(b0: 0, b1: 0, b2: 0, b3: 0x8000_0000_0000_0000))

        try await mih.remove(key: key("id-4"))

        let hits = try await mih.search(
            probe: zeroPayload, metric: .hamming, k: 2, filter: nil)

        #expect(hits.count == 2)
        #expect(hits[0].key.itemID == "id-1")
        #expect(hits[0].rawDistance == 0)
        #expect(hits[1].key.itemID == "id-2")
        #expect(hits[1].rawDistance == 3)
    }
}

// MARK: - Suite 2: MIH == BruteForce gate on canonical vectors

/// The Kong condition: MIHIndex.search must equal BruteForceIndex.search
/// bit-for-bit on all canonical vectors. BruteForceIndex is always the
/// oracle. Any disagreement is a bug in MIH.
@Suite("MIHIndex == BruteForce gate (canonical vectors)", .serialized)
struct MIHBruteForceGateCanonical {

    private func mihAndBrute(bandCount: MIHBandCount) -> (MIHIndex, BruteForceIndex) {
        (MIHIndex(bandCount: bandCount), BruteForceIndex())
    }

    @Test func gate_mih1() async throws {
        let (mih, brute) = mihAndBrute(bandCount: .m4)
        let records: [(String, VectorPayload)] = [
            ("id-1", payload(b0: 0)),
            ("id-2", payload(b0: 7)),
            ("id-3", payload(b0: 0xFF)),
            ("id-4", payload(b0: 0, b1: 0, b2: 0, b3: 0x8000_0000_0000_0000)),
        ]
        for (id, p) in records {
            try await mih.add(key: key(id), vector: p)
            try await brute.add(key: key(id), vector: p)
        }
        let mihHits   = try await mih.search(probe: zeroPayload, metric: .hamming, k: 2, filter: nil)
        let bruteHits = try await brute.search(probe: zeroPayload, metric: .hamming, k: 2, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: "MIH-1")
    }

    @Test func gate_mih2() async throws {
        let (mih, brute) = mihAndBrute(bandCount: .m4)
        let records: [(String, VectorPayload)] = [
            ("id-1", payload(b0: 0)),
            ("id-2", payload(b0: 7)),
            ("id-3", payload(b0: 0xFF)),
            ("id-4", payload(b0: 0, b1: 0, b2: 0, b3: 0x8000_0000_0000_0000)),
            ("id-5", payload(b0: 1)),
        ]
        for (id, p) in records {
            try await mih.add(key: key(id), vector: p)
            try await brute.add(key: key(id), vector: p)
        }
        let mihHits   = try await mih.search(probe: zeroPayload, metric: .hamming, k: 2, filter: nil)
        let bruteHits = try await brute.search(probe: zeroPayload, metric: .hamming, k: 2, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: "MIH-2")
    }

    @Test func gate_mih3() async throws {
        let (mih, brute) = mihAndBrute(bandCount: .m4)
        let records: [(String, VectorPayload)] = [
            ("id-10", payload(b0: 3, b1: 3)),
            ("id-11", payload(b0: 0, b1: 0, b2: 0, b3: 0x0F)),
            ("id-12", payload(b0: 0x0F)),
            ("id-13", payload(b0: 1)),
        ]
        for (id, p) in records {
            try await mih.add(key: key(id), vector: p)
            try await brute.add(key: key(id), vector: p)
        }
        let mihHits   = try await mih.search(probe: zeroPayload, metric: .hamming, k: 3, filter: nil)
        let bruteHits = try await brute.search(probe: zeroPayload, metric: .hamming, k: 3, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: "MIH-3")
    }

    @Test func gate_mih4() async throws {
        let (mih, brute) = mihAndBrute(bandCount: .m4)
        try await mih.add(key: key("id-1"), vector: payload(b0: 0))
        try await brute.add(key: key("id-1"), vector: payload(b0: 0))
        let mihHits   = try await mih.search(probe: zeroPayload, metric: .hamming, k: 5, filter: nil)
        let bruteHits = try await brute.search(probe: zeroPayload, metric: .hamming, k: 5, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: "MIH-4")
    }

    @Test func gate_mih5() async throws {
        let (mih, brute) = mihAndBrute(bandCount: .m4)
        let records: [(String, VectorPayload)] = [
            ("id-1", payload(b0: 0)),
            ("id-2", payload(b0: 7)),
            ("id-3", payload(b0: 0xFF)),
            ("id-4", payload(b0: 0, b1: 0, b2: 0, b3: 0x8000_0000_0000_0000)),
        ]
        for (id, p) in records {
            try await mih.add(key: key(id), vector: p)
            try await brute.add(key: key(id), vector: p)
        }
        try await mih.remove(key: key("id-4"))
        try await brute.remove(key: key("id-4"))
        let mihHits   = try await mih.search(probe: zeroPayload, metric: .hamming, k: 2, filter: nil)
        let bruteHits = try await brute.search(probe: zeroPayload, metric: .hamming, k: 2, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: "MIH-5")
    }
}

// MARK: - Suite 3: Randomised fuzz cross-check (the exactness gate)

/// The real exactness gate: many random configurations assert
/// MIH == BruteForce on randomised inputs.
///
/// Fuzz strategy: generate k "near" items within small Hamming distance
/// of the probe, plus n-k random "far" items. This guarantees the stopping
/// rule fires early (when k items are found at small distance), keeping
/// the colex enumeration tractable. Correctness is fully exercised:
/// MIH must find the exact k nearest from a mixed population of near+far codes.
///
/// Motivation: MIH's progressive-radius expansion is sub-linear only on
/// CLUSTERED binary codes. For purely uniform random 256-bit codes, the k
/// nearest are at ~128-bit distance, requiring rho=32+ per band (m=4,
/// sub_bits=64) and C(64,32)≈10^18 enumerations — intractable for tests.
@Suite("MIHIndex == BruteForce fuzz cross-check", .serialized)
struct MIHFuzzGate {

    /// One fuzz run: build both indexes from `records`, search with `probe`,
    /// assert identical results.
    private func fuzzRun(
        records: [(key: VectorRecordKey, payload: VectorPayload)],
        probe: VectorPayload,
        k: Int,
        bandCount: MIHBandCount,
        context: String
    ) async throws {
        let mih   = MIHIndex(bandCount: bandCount)
        let brute = BruteForceIndex()
        for r in records {
            try await mih.add(key: r.key, vector: r.payload)
            try await brute.add(key: r.key, vector: r.payload)
        }
        let mihHits   = try await mih.search(probe: probe, metric: .hamming, k: k, filter: nil)
        let bruteHits = try await brute.search(probe: probe, metric: .hamming, k: k, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: context)
    }

    /// Generate n records where the first k are within maxNearDist bits of the
    /// probe (guaranteed near), and the remainder are uniformly random.
    ///
    /// The near items are generated by flipping 1..maxNearDist bits of block0
    /// of the probe engram. This ensures the stopping rule fires at r ≤
    /// maxNearDist without requiring deep colex enumeration.
    private func nearFarRecords(
        n: Int, k: Int, maxNearDist: UInt64,
        probeE: Engram, state: inout UInt64
    ) -> [(key: VectorRecordKey, payload: VectorPayload)] {
        var records: [(key: VectorRecordKey, payload: VectorPayload)] = []
        // Near items: probe XOR small flip in block0.
        for i in 0..<k {
            let flipCount = 1 + xorshift64(&state) % maxNearDist
            let mask: UInt64 = flipCount >= 64 ? UInt64.max : (1 << flipCount) - 1
            let flip = xorshift64(&state) & mask
            let b0 = probeE.block0 ^ flip
            records.append((
                key: VectorRecordKey(itemID: "near-\(String(format: "%06d", i))",
                                     vectorIndex: 0, modelID: "model-a", modelVersion: "1"),
                payload: VectorPayload(engram: Engram(blocks: b0, probeE.block1,
                                                     probeE.block2, probeE.block3))
            ))
        }
        // Far items: fully random.
        for i in k..<n {
            records.append((
                key: VectorRecordKey(itemID: "rand-\(String(format: "%06d", i))",
                                     vectorIndex: 0, modelID: "model-a", modelVersion: "1"),
                payload: VectorPayload(engram: Engram(blocks: xorshift64(&state),
                                                     xorshift64(&state),
                                                     xorshift64(&state),
                                                     xorshift64(&state)))
            ))
        }
        return records
    }

    @Test func fuzz_m4_nearData() async throws {
        // m=4 (sub_bits=64): near items within 4 bits → rho ≤ 1 per band → fast.
        var state: UInt64 = 0xCAFEBABEDEADBEEF
        let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                            xorshift64(&state), xorshift64(&state))
        let n = 50, k = 5
        let records = nearFarRecords(n: n, k: k, maxNearDist: 4, probeE: probeE, state: &state)
        try await fuzzRun(records: records, probe: VectorPayload(engram: probeE),
                          k: k, bandCount: .m4, context: "fuzz-m4-n\(n)-k\(k)")
    }

    @Test func fuzz_m8_nearData() async throws {
        // m=8 (sub_bits=32): near items within 8 bits → rho ≤ 1 per band → fast.
        var state: UInt64 = 0xDEADBEEFCAFEBABE
        let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                            xorshift64(&state), xorshift64(&state))
        let n = 80, k = 10
        let records = nearFarRecords(n: n, k: k, maxNearDist: 8, probeE: probeE, state: &state)
        try await fuzzRun(records: records, probe: VectorPayload(engram: probeE),
                          k: k, bandCount: .m8, context: "fuzz-m8-n\(n)-k\(k)")
    }

    @Test func fuzz_m16_nearData() async throws {
        // m=16 (sub_bits=16): near items within 16 bits → rho ≤ 1 per band → fast.
        var state: UInt64 = 0x0102030405060708
        let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                            xorshift64(&state), xorshift64(&state))
        let n = 80, k = 10
        let records = nearFarRecords(n: n, k: k, maxNearDist: 8, probeE: probeE, state: &state)
        try await fuzzRun(records: records, probe: VectorPayload(engram: probeE),
                          k: k, bandCount: .m16, context: "fuzz-m16-n\(n)-k\(k)")
    }

    @Test func fuzz_m32_nearData() async throws {
        // m=32 (sub_bits=8): near items within 8 bits → rho ≤ 1 per band → fast.
        var state: UInt64 = 0xFEDCBA9876543210
        let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                            xorshift64(&state), xorshift64(&state))
        let n = 80, k = 10
        let records = nearFarRecords(n: n, k: k, maxNearDist: 8, probeE: probeE, state: &state)
        try await fuzzRun(records: records, probe: VectorPayload(engram: probeE),
                          k: k, bandCount: .m32, context: "fuzz-m32-n\(n)-k\(k)")
    }

    @Test func fuzz_allM_multipleSeeds() async throws {
        // Five seeds × four m values. Near items within 4 bits of probe.
        let seeds: [UInt64] = [
            0xCAFEBABEDEADBEEF,
            0x1234567890ABCDEF,
            0xFEEDFACECAFEBEEF,
            0xA5A5A5A5A5A5A5A5,
            0x0F0F0F0F0F0F0F0F,
        ]
        let bandCounts: [MIHBandCount] = [.m4, .m8, .m16, .m32]

        for (seedIdx, seed) in seeds.enumerated() {
            for bandCount in bandCounts {
                var state = seed
                let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                                    xorshift64(&state), xorshift64(&state))
                let n = 20 + Int(xorshift64(&state) % 30)  // 20..49
                let k = 2 + Int(xorshift64(&state) % 5)    // 2..6
                let records = nearFarRecords(n: n, k: k, maxNearDist: 4,
                                             probeE: probeE, state: &state)
                try await fuzzRun(
                    records: records,
                    probe: VectorPayload(engram: probeE),
                    k: k, bandCount: bandCount,
                    context: "fuzz-m\(bandCount.rawValue)-n\(n)-k\(k)-seed\(seedIdx)"
                )
            }
        }
    }

    @Test func fuzz_nearDuplicateCodes() async throws {
        // All codes are near-duplicates of the probe — stresses tie-break
        // at boundary distance and multi-band radius expansion.
        var state: UInt64 = 0xAAAAAAAAAAAAAAAA
        let probe = Engram(blocks: 0xFFFF_FFFF_FFFF_FFFF, 0, 0, 0)
        let n = 60
        var records: [(key: VectorRecordKey, payload: VectorPayload)] = []
        for i in 0..<n {
            let flip = UInt64(1) << (xorshift64(&state) % 64)
            let b0 = probe.block0 ^ flip
            let itemID = "near-\(String(format: "%04d", i))"
            records.append((
                key: VectorRecordKey(itemID: itemID, vectorIndex: 0,
                                     modelID: "model-a", modelVersion: "1"),
                payload: VectorPayload(engram: Engram(blocks: b0, 0, 0, 0))
            ))
        }
        for bandCount in [MIHBandCount.m4, .m8, .m16, .m32] {
            try await fuzzRun(
                records: records,
                probe: VectorPayload(engram: probe),
                k: 10, bandCount: bandCount,
                context: "near-dup-m\(bandCount.rawValue)"
            )
        }
    }

    @Test func fuzz_emptyIndex() async throws {
        // Empty index: both should return empty.
        let mih   = MIHIndex(bandCount: .m4)
        let brute = BruteForceIndex()
        let mihHits   = try await mih.search(probe: zeroPayload, metric: .hamming, k: 5, filter: nil)
        let bruteHits = try await brute.search(probe: zeroPayload, metric: .hamming, k: 5, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: "empty-index")
    }

    @Test func fuzz_kLargerThanN() async throws {
        // k > n: both should return all n codes. Near data so termination is fast.
        var state: UInt64 = 0x1111111111111111
        let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                            xorshift64(&state), xorshift64(&state))
        let n = 10, k = 50
        let records = nearFarRecords(n: n, k: n, maxNearDist: 4,
                                     probeE: probeE, state: &state)
        for bandCount in [MIHBandCount.m4, .m8, .m16, .m32] {
            try await fuzzRun(
                records: records,
                probe: VectorPayload(engram: probeE),
                k: k, bandCount: bandCount,
                context: "k-larger-than-n-m\(bandCount.rawValue)"
            )
        }
    }
}

// MARK: - Suite 4: build(from:) round-trip

/// build(from: ResidentVectorArray) produces the same results as add()
/// calls, exercising the second construction path.
@Suite("MIHIndex build(from:) round-trip", .serialized)
struct MIHBuildFromTests {

    @Test func buildFromArrayEqualsAddCalls() async throws {
        let e1 = Engram(blocks: 1, 0, 0, 0)
        let e2 = Engram(blocks: 3, 0, 0, 0)
        let e3 = Engram(blocks: 0x0F, 0, 0, 0)
        let k1 = key("item-1")
        let k2 = key("item-2")
        let k3 = key("item-3")

        // Path A: add() calls.
        let mihA = MIHIndex(bandCount: .m4)
        try await mihA.add(key: k1, vector: VectorPayload(engram: e1))
        try await mihA.add(key: k2, vector: VectorPayload(engram: e2))
        try await mihA.add(key: k3, vector: VectorPayload(engram: e3))
        let hitsA = try await mihA.search(probe: zeroPayload, metric: .hamming, k: 3, filter: nil)

        // Path B: build(from: ResidentVectorArray).
        let storage = e1.wireBytes + e2.wireBytes + e3.wireBytes
        let tombstones = [UInt64](repeating: 0, count: 1)
        let partitions = BruteForceIndex.buildPartitions(keys: [k1, k2, k3],
                                                         tombstones: tombstones)
        let arr = ResidentVectorArray(
            kind: .binary, stride: 32, count: 3,
            storage: storage, keys: [k1, k2, k3],
            modelPartitions: partitions, tombstones: tombstones
        )
        let mihB = MIHIndex(bandCount: .m4)
        await mihB.build(from: arr)
        let hitsB = try await mihB.search(probe: zeroPayload, metric: .hamming, k: 3, filter: nil)

        assertHitsIdentical(hitsA, hitsB, context: "build-from-array")
    }

    @Test func buildFromRespectsTombstones() async throws {
        // Tombstone slot 1 (item-2). build(from:) should skip it.
        let e1 = Engram(blocks: 0, 0, 0, 0)
        let e2 = Engram(blocks: 1, 0, 0, 0)  // tombstoned — should not appear
        let e3 = Engram(blocks: 3, 0, 0, 0)
        let k1 = key("item-1")
        let k2 = key("item-2")
        let k3 = key("item-3")
        let storage = e1.wireBytes + e2.wireBytes + e3.wireBytes
        // Set bit 1 in the tombstone bitmap to tombstone slot 1.
        let tombstones: [UInt64] = [2]  // bit 1 = 0b10 = 2
        let partitions = BruteForceIndex.buildPartitions(keys: [k1, k2, k3],
                                                         tombstones: tombstones)
        let arr = ResidentVectorArray(
            kind: .binary, stride: 32, count: 3,
            storage: storage, keys: [k1, k2, k3],
            modelPartitions: partitions, tombstones: tombstones
        )
        let mih = MIHIndex(bandCount: .m4)
        await mih.build(from: arr)
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 3, filter: nil)
        // item-2 was tombstoned; only item-1 (dist=0) and item-3 (dist=2) should appear.
        #expect(hits.count == 2)
        let ids = hits.map(\.key.itemID)
        #expect(!ids.contains("item-2"), "tombstoned item-2 should not appear")
        #expect(ids.contains("item-1"))
        #expect(ids.contains("item-3"))
    }
}

// MARK: - Suite 5: Model-partition filter

@Suite("MIHIndex metadata filter", .serialized)
struct MIHFilterTests {

    @Test func modelIDFilterRestrictsScan() async throws {
        let mih = MIHIndex(bandCount: .m4)
        let kA = VectorRecordKey(itemID: "item-a", vectorIndex: 0,
                                 modelID: "model-a", modelVersion: "1")
        let kB = VectorRecordKey(itemID: "item-b", vectorIndex: 0,
                                 modelID: "model-b", modelVersion: "1")
        try await mih.add(key: kA, vector: payload(b0: 0))
        try await mih.add(key: kB, vector: payload(b0: 0xFF))

        let filter = MetadataFilter.exact(modelID: "model-a", modelVersion: "1")
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 10, filter: filter)

        #expect(hits.count == 1)
        #expect(hits[0].key.itemID == "item-a")
    }

    @Test func absentModelIDFilterReturnsEmpty() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("item-a", modelID: "model-a"),
                          vector: payload(b0: 0))
        let filter = MetadataFilter(modelID: "no-such-model")
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 10, filter: filter)
        #expect(hits.isEmpty)
    }

    @Test func filterGateEqualsUnfilteredBruteForce() async throws {
        // Filter removes model-b. MIH with filter should equal BruteForce
        // that was never given model-b records.
        let mih   = MIHIndex(bandCount: .m4)
        let brute = BruteForceIndex()

        let kA = VectorRecordKey(itemID: "item-a", vectorIndex: 0,
                                 modelID: "model-a", modelVersion: "1")
        let kB = VectorRecordKey(itemID: "item-b", vectorIndex: 0,
                                 modelID: "model-b", modelVersion: "1")
        let kC = VectorRecordKey(itemID: "item-c", vectorIndex: 0,
                                 modelID: "model-a", modelVersion: "1")

        try await mih.add(key: kA, vector: payload(b0: 1))
        try await mih.add(key: kB, vector: payload(b0: 0))  // model-b — filtered out
        try await mih.add(key: kC, vector: payload(b0: 3))

        // BruteForce only has model-a records.
        try await brute.add(key: kA, vector: payload(b0: 1))
        try await brute.add(key: kC, vector: payload(b0: 3))

        let filter = MetadataFilter(modelID: "model-a")
        let mihHits   = try await mih.search(probe: zeroPayload, metric: .hamming, k: 5, filter: filter)
        let bruteHits = try await brute.search(probe: zeroPayload, metric: .hamming, k: 5, filter: nil)
        assertHitsIdentical(mihHits, bruteHits, context: "filter-gate-model-a")
    }
}

// MARK: - Suite 6: Error cases

@Suite("MIHIndex error cases", .serialized)
struct MIHErrorTests {

    @Test func nonBinaryProbeThrows() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("item-1"), vector: payload(b0: 0))
        do {
            _ = try await mih.search(probe: VectorPayload(floats: [1.0, 2.0]),
                                     metric: .hamming, k: 1, filter: nil)
            Issue.record("Expected invalidPayload but search succeeded")
        } catch VectorKitError.invalidPayload { /* expected */ }
    }

    @Test func floatMetricThrows() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("item-1"), vector: payload(b0: 0))
        do {
            _ = try await mih.search(probe: zeroPayload, metric: .cosine, k: 1, filter: nil)
            Issue.record("Expected invalidPayload but search succeeded")
        } catch VectorKitError.invalidPayload { /* expected */ }
    }

    @Test func kZeroReturnsEmpty() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("item-1"), vector: payload(b0: 0))
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 0, filter: nil)
        #expect(hits.isEmpty)
    }

    @Test func emptyIndexReturnsEmpty() async throws {
        let mih = MIHIndex(bandCount: .m4)
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 5, filter: nil)
        #expect(hits.isEmpty)
    }

    @Test func nonBinaryAddThrows() async throws {
        let mih = MIHIndex(bandCount: .m4)
        do {
            try await mih.add(key: key("item-1"), vector: VectorPayload(floats: [1.0, 2.0]))
            Issue.record("Expected invalidPayload but add succeeded")
        } catch VectorKitError.invalidPayload { /* expected */ }
    }

    @Test func removeAbsentKeyIsNoOp() async throws {
        let mih = MIHIndex(bandCount: .m4)
        try await mih.add(key: key("item-1"), vector: payload(b0: 0))
        // Removing a non-existent key should not throw.
        try await mih.remove(key: key("item-nonexistent"))
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 1, filter: nil)
        // item-1 should still be there.
        #expect(hits.count == 1)
        #expect(hits[0].key.itemID == "item-1")
    }
}

// MARK: - Suite 7: SQLite-backed persistence (real on-disk .vec sidecar)

/// Mission requirement: persistence tests run on a real on-disk file,
/// NOT InMemory. Verifies: build → reopen → MIH results identical.
///
/// The test writes a .vec sidecar via ResidentArrayStore, reopens it,
/// rebuilds MIHIndex from the loaded ResidentVectorArray, then asserts
/// that search results are identical across the reopen boundary.
@Suite("MIHIndex SQLite-backed persistence", .serialized)
struct MIHPersistenceTests {

    /// Temporary .vec file URL, cleaned up after the test.
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorkit-mih-\(UUID().uuidString).vec")
    }

    @Test func writeThenReopenProducesIdenticalResults() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let e1 = Engram(blocks: 0,   0, 0, 0)  // dist=0
        let e2 = Engram(blocks: 1,   0, 0, 0)  // dist=1
        let e3 = Engram(blocks: 3,   0, 0, 0)  // dist=2
        let e4 = Engram(blocks: 0xFF,0, 0, 0)  // dist=8
        let records: [(VectorRecordKey, [UInt8])] = [
            (key("item-1"), e1.wireBytes),
            (key("item-2"), e2.wireBytes),
            (key("item-3"), e3.wireBytes),
            (key("item-4"), e4.wireBytes),
        ]

        // --- Session 1: write and search ---
        let store1 = ResidentArrayStore(sidecarURL: url)
        for (k, bytes) in records {
            try await store1.append(key: k, bytes: bytes)
        }
        let snap1 = await store1.snapshot()

        let mih1 = MIHIndex(bandCount: .m4)
        await mih1.build(from: snap1)
        let hitsBeforeClose = try await mih1.search(
            probe: zeroPayload, metric: .hamming, k: 3, filter: nil)

        // --- Session 2: reopen from the .vec sidecar ---
        let store2 = ResidentArrayStore(sidecarURL: url)
        try await store2.load()
        let snap2 = await store2.snapshot()

        let mih2 = MIHIndex(bandCount: .m4)
        await mih2.build(from: snap2)
        let hitsAfterReopen = try await mih2.search(
            probe: zeroPayload, metric: .hamming, k: 3, filter: nil)

        assertHitsIdentical(hitsBeforeClose, hitsAfterReopen,
                            context: "persistence-reopen")
    }

    @Test func persistenceReopenEqualsBruteForce() async throws {
        // After reopen, MIH results should still match BruteForce on the
        // same data. This confirms the .vec round-trip doesn't corrupt codes.
        // Uses near data so the stopping rule fires early (tractable).
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var state: UInt64 = 0xCAFEBABEDEADBEEF
        let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                            xorshift64(&state), xorshift64(&state))
        let probe = VectorPayload(engram: probeE)
        let n = 40, k = 10
        // k near items within 8 bits of probe, rest random.
        var nearRecords: [(key: VectorRecordKey, payload: VectorPayload)] = []
        for i in 0..<k {
            let flip = UInt64(1) << (xorshift64(&state) % 8)
            let b0 = probeE.block0 ^ flip
            nearRecords.append((
                key: VectorRecordKey(itemID: "near-\(String(format: "%04d", i))",
                                     vectorIndex: 0, modelID: "model-a", modelVersion: "1"),
                payload: VectorPayload(engram: Engram(blocks: b0, probeE.block1,
                                                     probeE.block2, probeE.block3))
            ))
        }
        let farRecords = randomPayloads(count: n - k, seed: xorshift64(&state))
        let allRecords = nearRecords + farRecords

        // Write to sidecar.
        let store = ResidentArrayStore(sidecarURL: url)
        for r in allRecords { try await store.append(key: r.key, bytes: r.payload.bytes) }

        // Reopen and build MIH.
        let store2 = ResidentArrayStore(sidecarURL: url)
        try await store2.load()
        let snap = await store2.snapshot()

        let mih = MIHIndex(bandCount: .m8)
        await mih.build(from: snap)
        let mihHits = try await mih.search(probe: probe, metric: .hamming, k: k, filter: nil)

        // Build BruteForce from the same add() calls (not from sidecar).
        let brute = BruteForceIndex()
        for r in allRecords { try await brute.add(key: r.key, vector: r.payload) }
        let bruteHits = try await brute.search(probe: probe, metric: .hamming, k: k, filter: nil)

        assertHitsIdentical(mihHits, bruteHits, context: "persistence-vs-brute")
    }

    @Test func tombstonedRecordAbsentAfterPersistenceReopen() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ResidentArrayStore(sidecarURL: url)
        let kA = key("item-a")
        let kB = key("item-b")
        try await store.append(key: kA, bytes: Engram(blocks: 0, 0, 0, 0).wireBytes)
        try await store.append(key: kB, bytes: Engram(blocks: 1, 0, 0, 0).wireBytes)
        try await store.tombstone(key: kA)

        // Reopen.
        let store2 = ResidentArrayStore(sidecarURL: url)
        try await store2.load()
        let snap = await store2.snapshot()

        let mih = MIHIndex(bandCount: .m4)
        await mih.build(from: snap)
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 10, filter: nil)

        // Only item-b (dist=1) should appear; item-a is tombstoned.
        #expect(hits.count == 1)
        #expect(hits[0].key.itemID == "item-b")
    }

    @Test func multipleM_valuesProduceSameResultsAfterReopen() async throws {
        // Uses near data (probe + small flips) so the stopping rule fires
        // quickly for all m values including m=4 (sub_bits=64).
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var state: UInt64 = 0x9999999999999999
        let probeE = Engram(blocks: xorshift64(&state), xorshift64(&state),
                            xorshift64(&state), xorshift64(&state))
        let probe = VectorPayload(engram: probeE)
        let n = 30, k = 8

        // k near items + n-k random.
        var allRecords: [(key: VectorRecordKey, payload: VectorPayload)] = []
        for i in 0..<k {
            let flip = UInt64(1) << (xorshift64(&state) % 8)
            allRecords.append((
                key: VectorRecordKey(itemID: "near-\(String(format: "%04d", i))",
                                     vectorIndex: 0, modelID: "model-a", modelVersion: "1"),
                payload: VectorPayload(engram: Engram(blocks: probeE.block0 ^ flip,
                                                     probeE.block1, probeE.block2, probeE.block3))
            ))
        }
        let far = randomPayloads(count: n - k, seed: xorshift64(&state))
        allRecords += far

        // Write sidecar once.
        let store = ResidentArrayStore(sidecarURL: url)
        for r in allRecords { try await store.append(key: r.key, bytes: r.payload.bytes) }

        // For each m value, reopen and confirm against BruteForce.
        let brute = BruteForceIndex()
        for r in allRecords { try await brute.add(key: r.key, vector: r.payload) }
        let bruteHits = try await brute.search(probe: probe, metric: .hamming, k: k, filter: nil)

        for bandCount in [MIHBandCount.m4, .m8, .m16, .m32] {
            let storeN = ResidentArrayStore(sidecarURL: url)
            try await storeN.load()
            let snap = await storeN.snapshot()
            let mih = MIHIndex(bandCount: bandCount)
            await mih.build(from: snap)
            let mihHits = try await mih.search(probe: probe, metric: .hamming, k: k, filter: nil)
            assertHitsIdentical(mihHits, bruteHits,
                                context: "persistence-m\(bandCount.rawValue)")
        }
    }
}

// MARK: - Suite 8: cumulativeChoose parity gate (integer arithmetic, Swift side)

/// Parity gate for the binomial-prefix helper used by the enumeration-budget
/// guard. The Rust port's `cumulative_choose` must produce the same values —
/// this table pins the Swift side as the canonical reference.
///
/// Verified by enumeration of colexFlipMasks at each (sub_bits, rho) pair:
/// cumulativeChoose(subBits, rho) == actual mask count generated by
/// colexFlipMasks(subBits:maxHamming:).
@Suite("cumulativeChoose parity gate", .serialized)
struct CumulativeChooseTests {

    @Test func knownValues_subBits8() {
        // C(8,0)=1, C(8,1)=8, C(8,2)=28, C(8,3)=56, C(8,4)=70
        #expect(cumulativeChoose(subBits: 8, rho: 0) == 1)
        #expect(cumulativeChoose(subBits: 8, rho: 1) == 9)    // 1+8
        #expect(cumulativeChoose(subBits: 8, rho: 2) == 37)   // 1+8+28
        #expect(cumulativeChoose(subBits: 8, rho: 3) == 93)   // 1+8+28+56
        #expect(cumulativeChoose(subBits: 8, rho: 4) == 163)  // 1+8+28+56+70
    }

    @Test func knownValues_subBits16() {
        // C(16,0)=1, C(16,1)=16, C(16,2)=120, C(16,3)=560, C(16,4)=1820
        #expect(cumulativeChoose(subBits: 16, rho: 0) == 1)
        #expect(cumulativeChoose(subBits: 16, rho: 1) == 17)
        #expect(cumulativeChoose(subBits: 16, rho: 2) == 137)
        #expect(cumulativeChoose(subBits: 16, rho: 3) == 697)
        #expect(cumulativeChoose(subBits: 16, rho: 4) == 2517)
    }

    @Test func knownValues_subBits32() {
        // C(32,0)=1, C(32,1)=32, C(32,2)=496, C(32,3)=4960
        #expect(cumulativeChoose(subBits: 32, rho: 0) == 1)
        #expect(cumulativeChoose(subBits: 32, rho: 1) == 33)
        #expect(cumulativeChoose(subBits: 32, rho: 2) == 529)
        #expect(cumulativeChoose(subBits: 32, rho: 3) == 5489)
    }

    @Test func knownValues_subBits64() {
        // C(64,0)=1, C(64,1)=64, C(64,2)=2016, C(64,3)=41664, C(64,4)=635376
        #expect(cumulativeChoose(subBits: 64, rho: 0) == 1)
        #expect(cumulativeChoose(subBits: 64, rho: 1) == 65)
        #expect(cumulativeChoose(subBits: 64, rho: 2) == 2081)
        #expect(cumulativeChoose(subBits: 64, rho: 3) == 43745)
        #expect(cumulativeChoose(subBits: 64, rho: 4) == 679121)
    }

    @Test func zeroRhoAlwaysOne() {
        // Σ_{d=0..0} C(n,0) = 1 for all n.
        for n in [8, 16, 32, 64] {
            #expect(cumulativeChoose(subBits: n, rho: 0) == 1, "subBits=\(n)")
        }
    }

    @Test func rhoExceedsSubBits_capsAtTotalMasks() {
        // Σ_{d=0..n} C(n,d) = 2^n for rho >= sub_bits (all combinations).
        #expect(cumulativeChoose(subBits: 8, rho: 8) == 256)   // 2^8
        #expect(cumulativeChoose(subBits: 8, rho: 100) == 256) // clamped
    }

    /// Verify cumulativeChoose matches the actual colex enumeration count
    /// for all conformance-gated (sub_bits, rho) pairs.
    @Test func matchesActualEnumerationCount() {
        // sub_bits ∈ {8,16,32,64} × rho ∈ {0,1,2,3,4}
        let subBitsValues = [8, 16, 32, 64]
        for sb in subBitsValues {
            for rho in 0...4 {
                var count = 0
                colexFlipMasks(subBits: sb, maxHamming: rho) { _ in count += 1 }
                let computed = cumulativeChoose(subBits: sb, rho: rho)
                #expect(computed == count,
                        "cumulativeChoose(subBits:\(sb), rho:\(rho))=\(computed) but colexFlipMasks generated \(count)")
            }
        }
    }
}

// MARK: - Suite 9: Enumeration-budget guard — deep-k random probes (m=4, small n)

/// Gate for the enumeration-budget guard introduced in
/// DECISION_MIH_ENUM_BUDGET_2026-06-12. Before this guard, a deep-k random
/// probe with m=4 on any non-trivial n would attempt C(64,~30) ≈ 10^17 mask
/// evaluations and hang. After the guard, such queries fall back to the brute
/// scan and complete in O(n), returning results identical to BruteForce.
///
/// This test was previously infeasible and is now the conformance win: the
/// guard makes the hardest case testable instead of forbidden.
@Suite("MIH enumeration-budget guard — deep-k random probes", .serialized)
struct MIHEnumerationBudgetGuardTests {

    /// n=300, m=4, k=10. All probes are uniformly random (no planted near items).
    /// Before the guard this shape hangs for hours. After the guard, the engine
    /// falls back to brute scan and returns exact results that match BruteForce.
    @Test func deepK_random_m4_n300_equalsbruteforce() async throws {
        let n = 300
        let k = 10
        var state: UInt64 = 0x1A2B3C4D5E6F0011

        // Build corpus — purely random 256-bit codes, no planted near items.
        var corpus: [(key: VectorRecordKey, payload: VectorPayload)] = []
        for i in 0..<n {
            let b0 = xorshift64(&state)
            let b1 = xorshift64(&state)
            let b2 = xorshift64(&state)
            let b3 = xorshift64(&state)
            corpus.append((
                key: VectorRecordKey(itemID: "item-\(String(format: "%06d", i))",
                                     vectorIndex: 0, modelID: "model-a", modelVersion: "1"),
                payload: VectorPayload(engram: Engram(blocks: b0, b1, b2, b3))
            ))
        }

        // Build MIH (m=4) and BruteForce from the same corpus.
        let mih   = MIHIndex(bandCount: .m4)
        let brute = BruteForceIndex()
        for r in corpus {
            try await mih.add(key: r.key, vector: r.payload)
            try await brute.add(key: r.key, vector: r.payload)
        }

        // Run 10 random probes — each would previously hang for hours at m=4.
        // The guard now triggers fallback on every one of them.
        for i in 0..<10 {
            let pb0 = xorshift64(&state)
            let pb1 = xorshift64(&state)
            let pb2 = xorshift64(&state)
            let pb3 = xorshift64(&state)
            let probe = VectorPayload(engram: Engram(blocks: pb0, pb1, pb2, pb3))

            let mihHits   = try await mih.search(probe: probe, metric: .hamming, k: k, filter: nil)
            let bruteHits = try await brute.search(probe: probe, metric: .hamming, k: k, filter: nil)
            assertHitsIdentical(mihHits, bruteHits, context: "deepK-random-m4-n300 probe[\(i)]")
        }
    }

    /// Verify that a forced-fallback (maskBudget=1) produces the same results
    /// as BruteForce. This is the unit assertion for the bruteScan code path:
    /// even with an impossibly tight budget the output must be exact.
    @Test func forcedFallback_equalsbruteforce() async throws {
        // maskBudget=1 means: fall back on the very first radius that has any
        // non-trivial band work. Since the projection for rho=0 is m*1=4 > 1,
        // fallback fires immediately for any non-zero probe distance.
        let mih   = MIHIndex(bandCount: .m4, maskBudget: 1)
        let brute = BruteForceIndex()

        var state: UInt64 = 0xFEDCBA9876543210
        let n = 50
        for i in 0..<n {
            let b0 = xorshift64(&state)
            let b1 = xorshift64(&state)
            let b2 = xorshift64(&state)
            let b3 = xorshift64(&state)
            let p = VectorPayload(engram: Engram(blocks: b0, b1, b2, b3))
            let k = VectorRecordKey(itemID: "item-\(String(format: "%04d", i))",
                                    vectorIndex: 0, modelID: "model-a", modelVersion: "1")
            try await mih.add(key: k, vector: p)
            try await brute.add(key: k, vector: p)
        }

        // 5 random probes — all fall back immediately.
        for i in 0..<5 {
            let pb0 = xorshift64(&state)
            let pb1 = xorshift64(&state)
            let pb2 = xorshift64(&state)
            let pb3 = xorshift64(&state)
            let probe = VectorPayload(engram: Engram(blocks: pb0, pb1, pb2, pb3))
            let mihHits   = try await mih.search(probe: probe, metric: .hamming, k: 10, filter: nil)
            let bruteHits = try await brute.search(probe: probe, metric: .hamming, k: 10, filter: nil)
            assertHitsIdentical(mihHits, bruteHits, context: "forced-fallback probe[\(i)]")
        }
    }
}

// MARK: - Suite W8b: bulk build conformance (MIH == BruteForce via build(from:))

/// W8b: Both MIHIndex and BruteForceIndex, built via the bulk `build(from:)`
/// path from the same ResidentVectorArray, must produce identical
/// `findNearest` output (k=10, ~500 fuzz vectors, fixed seed).
///
/// This gates the exactness of the `build(from:)` code path specifically
/// (distinct from the `add()` path used in the canonical vector tests).
@Suite("MIH-BruteForce bulk-build conformance (W8b)", .serialized)
struct MIHBruteForceBulkBuildConformanceTests {

    /// W8b-1: bulk-build from a 500-vector fuzz array, seed 0x1234ABCD.
    ///
    /// Builds both MIHIndex (m=16) and BruteForceIndex from the same
    /// ResidentVectorArray via `build(from:)`. Runs 25 random probes
    /// (same seed, shifted). Asserts bit-for-bit identical output (same
    /// hits, same order, same distances, same itemIDs) on every probe.
    ///
    /// The 500-vector corpus with 25 probes runs at the same seed on both
    /// the fixed corpus and varied probes, making the test deterministic
    /// and reproducible across platforms.
    @Test func bulkBuild_500vectors_500probes_mih16_equalsbruteforce() async throws {
        let n = 500
        let k = 10
        let seed: UInt64 = 0x1234_ABCD_5678_EF01

        // Build the fuzz corpus with a deterministic sequence.
        let corpus = randomPayloads(count: n, seed: seed)
        let bruteForce = BruteForceIndex()
        let mih = MIHIndex(bandCount: .m16)

        // Build both indexes from the same ResidentVectorArray (the bulk path).
        // First assemble the array via ResidentArrayStore, then snapshot it.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w8b-bulk-\(UUID().uuidString).vec")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ResidentArrayStore(sidecarURL: url)
        for r in corpus {
            try await store.append(key: r.key, bytes: r.payload.bytes)
        }
        let arr = await store.snapshot()

        // Build both indexes via the bulk build(from:) path.
        await bruteForce.build(from: arr)
        await mih.build(from: arr)

        // Generate 500 random probes from the same seed (phase-shifted).
        var probeState: UInt64 = seed ^ 0xDEAD_BEEF_CAFE_0000
        // 25 probes, not n: each random k=10 probe costs ~300k flip-mask
        // enumerations at m=16 in debug builds; 500 probes blows the 3-minute
        // test budget while adding no conformance value beyond ~25.
        for i in 0..<25 {
            let pb0 = xorshift64(&probeState)
            let pb1 = xorshift64(&probeState)
            let pb2 = xorshift64(&probeState)
            let pb3 = xorshift64(&probeState)
            let probe = VectorPayload(engram: Engram(blocks: pb0, pb1, pb2, pb3))

            let bruteHits = try await bruteForce.search(
                probe: probe, metric: .hamming, k: k, filter: nil)
            let mihHits = try await mih.search(
                probe: probe, metric: .hamming, k: k, filter: nil)

            assertHitsIdentical(mihHits, bruteHits,
                                context: "W8b probe[\(i)] n=\(n) k=\(k)")
        }
    }

    /// W8b-2: bulk-build with all four m values {4,8,16,32}.
    ///
    /// Same corpus (200 vectors, seed 0xFEED_BABE), 50 probes per m value.
    /// Each MIH must produce identical output to BruteForce. This confirms
    /// the `build(from:)` path is correct for all conformance-gated m values.
    ///
    /// PROBE DESIGN — near-duplicate probes with k=1, NOT random probes with
    /// k=10: MIH's progressive-radius search terminates once (radius+1)·m
    /// exceeds the k-th best distance. A random probe over random data has a
    /// k-th best of ~120 bits, which at m=4 (64-bit bands) demands radius ~29
    /// — C(64,29) ≈ 10^17 flip masks per band, combinatorially infeasible
    /// (this exact shape hung the suite for hours, not minutes). Probing with
    /// a STORED vector ±≤2 flipped bits plants the best hit at distance ≤2,
    /// so every m terminates at radius ≤2 while still proving the bulk-built
    /// index put every live slot in the right buckets: a mis-indexed slot
    /// makes MIH miss the planted neighbour and diverge from brute force.
    /// Deep-k conformance on random data lives in W8b-1 above (m=16, where
    /// the enumeration is tractable).
    @Test func bulkBuild_200vectors_allMValues_equalsbruteforce() async throws {
        let n = 200
        let seed: UInt64 = 0xFEED_BABE_1234_5678

        let corpus = randomPayloads(count: n, seed: seed)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w8b-m-values-\(UUID().uuidString).vec")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build the shared array once.
        let store = ResidentArrayStore(sidecarURL: url)
        for r in corpus {
            try await store.append(key: r.key, bytes: r.payload.bytes)
        }
        let arr = await store.snapshot()

        let bruteForce = BruteForceIndex()
        await bruteForce.build(from: arr)

        // For each m value, build MIH from the same array and cross-check.
        for bandCount in MIHBandCount.allCases {
            let mih = MIHIndex(bandCount: bandCount)
            await mih.build(from: arr)

            for i in 0..<50 {
                // Probe = stored vector (i·7 mod n) with 0/1/2 deterministic
                // byte-level bit flips — the planted nearest neighbour that
                // every band count can reach at a tiny radius.
                var probeBytes = corpus[(i * 7) % n].payload.bytes
                for f in 0..<(i % 3) {
                    let bitIndex = (i * 13 + f * 97 + 7) % 256
                    probeBytes[bitIndex / 8] ^= UInt8(1) << UInt8(bitIndex % 8)
                }
                let probe = VectorPayload(kind: .binary, dim: 256, bytes: probeBytes)
                let bruteHits = try await bruteForce.search(
                    probe: probe, metric: .hamming, k: 1, filter: nil)
                let mihHits = try await mih.search(
                    probe: probe, metric: .hamming, k: 1, filter: nil)
                assertHitsIdentical(mihHits, bruteHits,
                                    context: "W8b m=\(bandCount.rawValue) probe[\(i)]")
            }
        }
    }
}

// MARK: - Finding 1: MIH itemID-collision fix

/// Two binary vectors sharing the same itemID but different vectorIndex must
/// BOTH survive in the MIH and be retrievable independently.
///
/// Before the fix, MIHIndex keyed its internals by itemID alone so the second
/// `add(key:vector:)` silently overwrote the first. After the fix the key is
/// the full VectorRecordKey and both coexist.
@Suite("MIHIndex-same-itemID collision fix") struct MIHIndexSameItemIDTests {

    @Test("add: two distinct vectorIndex entries under same itemID both survive")
    func sameItemIDDistinctVectorIndexBothSurvive() async throws {
        let mih = MIHIndex(bandCount: .m4)

        let key0 = VectorRecordKey(itemID: "item-A", vectorIndex: 0,
                                   modelID: "model-a", modelVersion: "1")
        let key1 = VectorRecordKey(itemID: "item-A", vectorIndex: 1,
                                   modelID: "model-a", modelVersion: "1")

        // vec0 = all-zeros (Hamming dist 0 to zero probe)
        // vec1 = 1 bit set  (Hamming dist 1 to zero probe)
        try await mih.add(key: key0, vector: payload(b0: 0))
        try await mih.add(key: key1, vector: payload(b0: 1))

        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 4, filter: nil)

        #expect(hits.count == 2,
                "both same-itemID slots must survive in the index; got \(hits.count)")
        #expect(hits[0].key == key0, "closest hit must be the zero-distance slot")
        #expect(hits[0].hammingDistance == 0)
        #expect(hits[1].key == key1, "second hit must be the one-bit-set slot")
        #expect(hits[1].hammingDistance == 1)
    }

    @Test("add: two distinct modelID entries under same itemID both survive")
    func sameItemIDDistinctModelIDBothSurvive() async throws {
        let mih = MIHIndex(bandCount: .m4)

        let keyA = VectorRecordKey(itemID: "item-X", vectorIndex: 0,
                                   modelID: "model-a", modelVersion: "1")
        let keyB = VectorRecordKey(itemID: "item-X", vectorIndex: 0,
                                   modelID: "model-b", modelVersion: "1")

        try await mih.add(key: keyA, vector: payload(b0: 0))
        try await mih.add(key: keyB, vector: payload(b0: 3))

        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 4, filter: nil)

        #expect(hits.count == 2,
                "distinct modelID entries under same itemID must coexist")
        #expect(hits[0].key == keyA)
        #expect(hits[0].hammingDistance == 0)
        #expect(hits[1].key == keyB)
        #expect(hits[1].hammingDistance == 2)
    }

    @Test("build: two entries sharing itemID via bulk path both survive")
    func sameItemIDViaBuildBothSurvive() async throws {
        let mih = MIHIndex(bandCount: .m4)
        let bruteForce = BruteForceIndex()

        let key0 = VectorRecordKey(itemID: "shared", vectorIndex: 0,
                                   modelID: "model-a", modelVersion: "1")
        let key1 = VectorRecordKey(itemID: "shared", vectorIndex: 1,
                                   modelID: "model-a", modelVersion: "1")
        let key2 = VectorRecordKey(itemID: "other",  vectorIndex: 0,
                                   modelID: "model-a", modelVersion: "1")

        let e0 = Engram(blocks: 0, 0, 0, 0)
        let e1 = Engram(blocks: 3, 0, 0, 0)
        let e2 = Engram(blocks: 0xFF, 0, 0, 0)
        let rawBytes = e0.wireBytes + e1.wireBytes + e2.wireBytes
        let tombstones = [UInt64](repeating: 0, count: 1)
        let keys3 = [key0, key1, key2]
        let partitions = BruteForceIndex.buildPartitions(keys: keys3, tombstones: tombstones)
        let snapshot = ResidentVectorArray(
            kind: .binary, stride: 32, count: 3,
            storage: rawBytes, keys: keys3,
            modelPartitions: partitions, tombstones: tombstones
        )

        await mih.build(from: snapshot)
        await bruteForce.build(from: snapshot)

        let probe = zeroPayload
        let mihHits   = try await mih.search(probe: probe, metric: .hamming, k: 3, filter: nil)
        let bruteHits = try await bruteForce.search(probe: probe, metric: .hamming, k: 3, filter: nil)

        #expect(mihHits.count == 3,
                "all three slots (two sharing itemID) must be present in MIH")
        assertHitsIdentical(mihHits, bruteHits, context: "sameItemID-via-build")
    }

    @Test("upsert: same full VectorRecordKey replaces, co-item sibling does not")
    func upsertSameFullKeyReplacesSibling() async throws {
        let mih = MIHIndex(bandCount: .m4)

        let key0 = VectorRecordKey(itemID: "item-A", vectorIndex: 0,
                                   modelID: "model-a", modelVersion: "1")
        let key1 = VectorRecordKey(itemID: "item-A", vectorIndex: 1,
                                   modelID: "model-a", modelVersion: "1")

        // Both start as all-zeros.
        try await mih.add(key: key0, vector: payload(b0: 0))
        try await mih.add(key: key1, vector: payload(b0: 0))

        // Upsert key0 with a different vector (1 bit set).
        try await mih.add(key: key0, vector: payload(b0: 1))

        // Now key0 has dist=1 and key1 has dist=0.
        let hits = try await mih.search(probe: zeroPayload, metric: .hamming, k: 4, filter: nil)
        #expect(hits.count == 2, "there must be exactly two entries; got \(hits.count)")
        #expect(hits[0].key == key1, "key1 (unchanged, dist=0) must rank first")
        #expect(hits[0].hammingDistance == 0)
        #expect(hits[1].key == key0, "key0 (upserted to dist=1) must rank second")
        #expect(hits[1].hammingDistance == 1)
    }
}
