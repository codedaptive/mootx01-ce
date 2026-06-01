// EngramLibTests.swift
//
// swift-testing suite for the EngramLib-type API: distance,
// distances, findNearest, findWithin, union, and Session. Mirrors
// the Rust behavior set in rust/tests/engram_lib_tests.rs. Match-type
// coverage lives in the peer suite MatchTests.swift.

import Testing
@testable import EngramLib

@Suite("EngramLib API")
struct EngramLibTests {

    // MARK: - Distance

    @Test("identical engrams are distance 0")
    func distanceIdentical() {
        let a = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
        #expect(EngramLib.distance(a, a) == 0)
    }

    @Test("bit-inverse engrams are distance 256")
    func distanceInverse() {
        let a = Engram.zero
        let b = Engram(blocks: .max, .max, .max, .max)
        #expect(EngramLib.distance(a, b) == 256)
    }

    @Test("known bit pattern yields known distance")
    func distanceKnown() {
        let a = Engram(blocks: 0, 0, 0, 0)
        let b = Engram(blocks: 0b1011, 0, 0, 0)
        #expect(EngramLib.distance(a, b) == 3)
    }

    @Test("distances over empty candidates is empty")
    func distancesEmpty() {
        let probe = Engram.zero
        #expect(EngramLib.distances(probe: probe, candidates: []) == [])
    }

    @Test("batch distances match per-pair distances")
    func distancesBatchMatchesPair() {
        let probe = Engram(blocks: 0xAAAA_AAAA, 0, 0, 0)
        let estate = (0..<10).map { i in
            Engram(blocks: UInt64(i) &* 0xDEAD, UInt64(i), 0, 0)
        }
        let batch = EngramLib.distances(probe: probe, candidates: estate)
        for i in 0..<estate.count {
            #expect(batch[i] == EngramLib.distance(probe, estate[i]))
        }
    }

    // MARK: - Nearest neighbor

    @Test("findNearest over empty candidates is empty")
    func findNearestEmpty() {
        let probe = Engram.zero
        #expect(EngramLib.findNearest(probe: probe, in: [], k: 5) == [])
    }

    @Test("findNearest with k <= 0 is empty")
    func findNearestKZeroOrNegative() {
        let probe = Engram.zero
        let estate = [Engram(blocks: 1, 0, 0, 0)]
        #expect(EngramLib.findNearest(probe: probe, in: estate, k: 0) == [])
        #expect(EngramLib.findNearest(probe: probe, in: estate, k: -1) == [])
    }

    @Test("findNearest clamps k to candidate count")
    func findNearestKGreaterThanN() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 1, 0, 0, 0),
            Engram(blocks: 3, 0, 0, 0),
        ]
        let result = EngramLib.findNearest(probe: probe, in: estate, k: 10)
        #expect(result.count == 2)
    }

    @Test("findNearest orders by ascending distance")
    func findNearestOrdering() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b1111, 0, 0, 0),
            Engram(blocks: 0b1,    0, 0, 0),
            Engram(blocks: 0b111,  0, 0, 0),
            Engram(blocks: 0b11,   0, 0, 0),
        ]
        let result = EngramLib.findNearest(probe: probe, in: estate, k: 3)
        #expect(result.map { $0.index } == [1, 3, 2])
        #expect(result.map { $0.distance } == [1, 2, 3])
    }

    @Test("findNearest breaks distance ties by ascending index")
    func findNearestTieBreakByIndex() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b1,   0, 0, 0),
            Engram(blocks: 0b10,  0, 0, 0),
            Engram(blocks: 0b100, 0, 0, 0),
        ]
        let result = EngramLib.findNearest(probe: probe, in: estate, k: 3)
        #expect(result.map { $0.index } == [0, 1, 2])
    }

    @Test("findNearest single returns the closest match")
    func findNearestSingle() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b111, 0, 0, 0),
            Engram(blocks: 0b1,   0, 0, 0),
        ]
        let match = EngramLib.findNearest(probe: probe, in: estate)
        #expect(match?.index == 1)
        #expect(match?.distance == 1)
    }

    @Test("findNearest single over empty candidates is nil")
    func findNearestSingleEmpty() {
        #expect(EngramLib.findNearest(probe: Engram.zero, in: []) == nil)
    }

    // MARK: - Filtering

    @Test("findWithin returns candidates inside the radius, ordered")
    func findWithin() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b1,    0, 0, 0),
            Engram(blocks: 0b1111, 0, 0, 0),
            Engram(blocks: 0b11,   0, 0, 0),
        ]
        let result = EngramLib.findWithin(probe: probe, in: estate, maxDistance: 2)
        #expect(result.map { $0.index } == [0, 2])
        #expect(result.map { $0.distance } == [1, 2])
    }

    @Test("findWithin over empty candidates is empty")
    func findWithinEmpty() {
        #expect(
            EngramLib.findWithin(probe: Engram.zero,
                                 in: [], maxDistance: 10) == [])
    }

    @Test("findWithin with negative maxDistance is empty")
    func findWithinNegativeMax() {
        // Swift-only extra coverage: Rust find_within takes u32, so a
        // negative maxDistance is structurally impossible there. The
        // Swift guard (maxDistance >= 0) is the peer behavior.
        let probe = Engram.zero
        let estate = [Engram(blocks: 1, 0, 0, 0)]
        #expect(
            EngramLib.findWithin(probe: probe, in: estate, maxDistance: -1) == [])
    }

    // MARK: - Aggregation

    @Test("union of no engrams is the zero engram")
    func unionEmpty() {
        #expect(EngramLib.union([]) == Engram.zero)
    }

    @Test("pairwise union ORs the bits")
    func unionTwo() {
        let a = Engram(blocks: 0b1010, 0, 0, 0)
        let b = Engram(blocks: 0b0101, 0, 0, 0)
        let result = EngramLib.union(a, b)
        #expect(result.block0 == 0b1111)
    }

    @Test("union over many engrams ORs all bits")
    func unionMany() {
        let engrams = [
            Engram(blocks: 0b0001, 0, 0, 0),
            Engram(blocks: 0b0010, 0, 0, 0),
            Engram(blocks: 0b0100, 0, 0, 0),
            Engram(blocks: 0b1000, 0, 0, 0),
        ]
        #expect(EngramLib.union(engrams).block0 == 0b1111)
    }

    // MARK: - Session

    @Test("session results match the stateless API")
    func sessionMatchesStateless() {
        let probe = Engram(blocks: 0xDEAD_BEEF, 0, 0, 0)
        let estate = (0..<100).map { i in
            Engram(blocks: UInt64(i) &* 0xABCD, UInt64(i), 0, 0)
        }
        let stateless = EngramLib.findNearest(probe: probe, in: estate, k: 10)
        let session = EngramLib.session()
        let stateful = session.findNearest(probe: probe, in: estate, k: 10)
        #expect(stateless == stateful)
    }
}
