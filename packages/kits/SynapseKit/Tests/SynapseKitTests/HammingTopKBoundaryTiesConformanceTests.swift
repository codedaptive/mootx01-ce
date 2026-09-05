// HammingTopKBoundaryTiesConformanceTests.swift
//
// SYN-1 shared conformance vector for the binary (Hamming) lane's top-K
// boundary: Tests/Conformance/hamming_topk_boundary_ties.json.
//
// The vector holds 300 fingerprints built around one probe so that a large
// tie group straddles the K-th position: K=10 cuts inside a 45-way tie at
// distance 2, K=80 cuts inside a 50-way tie at distance 4 (four byte-identical
// payload pairs inside that group exercise the itemID backstop). Insertion
// order is a deterministic shuffle, so an engine that keeps the first-arrived
// members of the tie group, or a heap that drops the secondary keys, returns a
// different subset than the expected list.
//
// Every engine in this port must return exactly the expected ordered list per
// SYNAPSEKIT_SPEC B-6 — distance ASC, vecHash ASC (FNV-1a 64 over the 32 wire
// bytes), itemID ASC:
//   • BruteForceIndex (the oracle),
//   • MIHIndex at m=16 and m=4,
//   • VectorStore.findNearest on the brute-force tier and on the MIH tier
//     (MIH forced active below the default threshold via mihThreshold: 1).
// The Rust twin (rust/tests/hamming_topk_boundary_ties_tests.rs) asserts the
// same file, so the two ports are pinned to one list, not to each other.

import Testing
import Foundation
import EngramLib
import PersistenceKit
@testable import SynapseKit

// MARK: - Fixture

private struct BoundaryTiesFixture {
    struct Candidate { let itemID: String; let engram: Engram }
    struct Expected { let itemID: String; let distance: Int; let vecHash: UInt64 }
    struct Case {
        let k: Int
        let boundaryDistance: Int
        let tieGroupSize: Int
        let expected: [Expected]
    }
    let modelID: String
    let modelVersion: String
    let probe: Engram
    let candidates: [Candidate]
    let cases: [Case]

    /// Resolves Tests/Conformance/hamming_topk_boundary_ties.json relative to
    /// this file's compile-time location:
    ///   this file → Tests/SynapseKitTests/<this file>
    ///   fixture   → Tests/Conformance/hamming_topk_boundary_ties.json
    static func url() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // SynapseKitTests/
            .deletingLastPathComponent()            // Tests/
            .appendingPathComponent("Conformance")
            .appendingPathComponent("hamming_topk_boundary_ties.json")
    }

    /// The fixture writes every 64-bit block and hash as a "0x…" hex string
    /// so no JSON parser's number range is in play.
    static func hex64(_ any: Any?) throws -> UInt64 {
        let s = try #require(any as? String)
        #expect(s.hasPrefix("0x"), "fixture hex field must start with 0x: \(s)")
        return try #require(UInt64(s.dropFirst(2), radix: 16))
    }

    static func engram(_ any: Any?) throws -> Engram {
        let blocks = try #require(any as? [Any])
        #expect(blocks.count == 4)
        return Engram(blocks: try hex64(blocks[0]), try hex64(blocks[1]),
                      try hex64(blocks[2]), try hex64(blocks[3]))
    }

    static func load() throws -> BoundaryTiesFixture {
        let data = try Data(contentsOf: url())
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let candidates = try #require(root["candidates"] as? [[String: Any]]).map { c in
            Candidate(itemID: try #require(c["item_id"] as? String),
                      engram: try engram(c["blocks"]))
        }
        let cases = try #require(root["cases"] as? [[String: Any]]).map { c in
            Case(
                k: try #require(c["k"] as? Int),
                boundaryDistance: try #require(c["boundary_distance"] as? Int),
                tieGroupSize: try #require(c["tie_group_size"] as? Int),
                expected: try #require(c["expected"] as? [[String: Any]]).map { e in
                    Expected(itemID: try #require(e["item_id"] as? String),
                             distance: try #require(e["distance"] as? Int),
                             vecHash: try hex64(e["vec_hash"]))
                })
        }
        return BoundaryTiesFixture(
            modelID: try #require(root["model_id"] as? String),
            modelVersion: try #require(root["model_version"] as? String),
            probe: try engram(root["probe"]),
            candidates: candidates,
            cases: cases)
    }
}

// MARK: - Assertion helper

/// Compare an engine's ordered (itemID, distance) list against the expected
/// list; on divergence, name the first differing position with both sides so
/// the failure reads as a tie-order diagnosis, not a bare inequality.
private func expectOrderedList(
    _ got: [(itemID: String, distance: Int)],
    matches expected: [BoundaryTiesFixture.Expected],
    context: String
) {
    #expect(got.count == expected.count,
            "\(context): returned \(got.count) hits, expected exactly K=\(expected.count)")
    let first = zip(got, expected).enumerated().first { _, pair in
        pair.0.itemID != pair.1.itemID || pair.0.distance != pair.1.distance
    }
    if let (pos, pair) = first {
        Issue.record(
            "\(context): first divergence at position \(pos): got \(pair.0.itemID) d=\(pair.0.distance), expected \(pair.1.itemID) d=\(pair.1.distance)")
    }
}

private func recordKey(_ itemID: String, fixture: BoundaryTiesFixture) -> VectorRecordKey {
    VectorRecordKey(itemID: itemID, vectorIndex: 0,
                    modelID: fixture.modelID, modelVersion: fixture.modelVersion)
}

// MARK: - Suite

@Suite("HammingTopKBoundaryTies conformance", .serialized)
struct HammingTopKBoundaryTiesConformanceTests {

    /// The fixture's own consistency: every expected entry's vec_hash equals
    /// this port's FNV-1a 64 over the candidate's 32 wire bytes, every
    /// expected distance equals the kernel-gated Hamming distance to the
    /// probe, and each case's tie group is at least 40 wide at the boundary.
    /// A drift here means the two ports no longer hash the same bytes.
    @Test func fixtureHashesAndDistancesAreThisPortsValues() throws {
        let f = try BoundaryTiesFixture.load()
        #expect(f.candidates.count == 300)
        let byID = Dictionary(uniqueKeysWithValues: f.candidates.map { ($0.itemID, $0.engram) })
        for c in f.cases {
            #expect(c.tieGroupSize >= 40, "k=\(c.k): tie group at the boundary must be ≥40 wide")
            #expect(c.expected.count == c.k)
            #expect(c.expected.last?.distance == c.boundaryDistance)
            for e in c.expected {
                let engram = try #require(byID[e.itemID])
                #expect(fnv1a64(VectorPayload(engram: engram).bytes) == e.vecHash,
                        "k=\(c.k): vec_hash drift for \(e.itemID)")
                #expect(EngramLib.distance(f.probe, engram) == e.distance,
                        "k=\(c.k): distance drift for \(e.itemID)")
            }
        }
    }

    /// BruteForceIndex — the oracle — returns exactly the expected lists.
    @Test func bruteForceIndexReturnsExpectedOrderedTopK() async throws {
        let f = try BoundaryTiesFixture.load()
        let index = BruteForceIndex()
        for c in f.candidates {
            try await index.add(key: recordKey(c.itemID, fixture: f),
                                vector: VectorPayload(engram: c.engram))
        }
        for c in f.cases {
            let hits = try await index.search(probe: VectorPayload(engram: f.probe),
                                              metric: .hamming, k: c.k, filter: nil)
            expectOrderedList(hits.map { ($0.key.itemID, $0.hammingDistance) },
                              matches: c.expected, context: "BruteForceIndex k=\(c.k)")
        }
    }

    /// MIHIndex at m=16 (the production band count) and m=4 returns the
    /// same lists as the oracle — the progressive-radius heap must keep the
    /// (distance, vecHash, key) order at the K-th boundary.
    @Test(arguments: [MIHBandCount.m16, MIHBandCount.m4])
    func mihIndexReturnsExpectedOrderedTopK(bandCount: MIHBandCount) async throws {
        let f = try BoundaryTiesFixture.load()
        let index = MIHIndex(bandCount: bandCount)
        for c in f.candidates {
            try await index.add(key: recordKey(c.itemID, fixture: f),
                                vector: VectorPayload(engram: c.engram))
        }
        for c in f.cases {
            let hits = try await index.search(probe: VectorPayload(engram: f.probe),
                                              metric: .hamming, k: c.k, filter: nil)
            expectOrderedList(hits.map { ($0.key.itemID, $0.hammingDistance) },
                              matches: c.expected, context: "MIHIndex m=\(bandCount.rawValue) k=\(c.k)")
        }
    }

    /// VectorStore.findNearest on both index tiers: the brute-force tier
    /// (threshold above the corpus size) and the MIH tier (mihThreshold: 1
    /// promotes to MIH as soon as one live binary vector exists). Both must
    /// serve exactly the expected lists through the public seam.
    @Test(arguments: [UInt32(1_000_000), UInt32(1)])
    func vectorStoreFindNearestReturnsExpectedOrderedTopK(mihThreshold: UInt32) async throws {
        try await GlobalTestLock.shared.withLock {
            let f = try BoundaryTiesFixture.load()
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage, sidecarURL: nil, mihThreshold: mihThreshold)
            let filedAt = Date(timeIntervalSince1970: 1_700_000_000)
            for c in f.candidates {
                try await store.addPayload(itemID: c.itemID, vectorIndex: 0,
                                           payload: VectorPayload(engram: c.engram),
                                           modelID: f.modelID, modelVersion: f.modelVersion,
                                           filedAt: filedAt)
            }
            for c in f.cases {
                let matches = try await store.findNearest(probe: f.probe, modelID: f.modelID, limit: c.k)
                expectOrderedList(matches.map { ($0.itemID, $0.distance) },
                                  matches: c.expected,
                                  context: "VectorStore(mihThreshold: \(mihThreshold)) k=\(c.k)")
            }
        }
    }
}
