// EngramLibTests.swift

import XCTest
@testable import EngramLib

final class EngramLibTests: XCTestCase {

    func testDistanceIdentical() {
        let a = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
        XCTAssertEqual(EngramLib.distance(a, a), 0)
    }

    func testDistanceInverse() {
        let a = Engram.zero
        let b = Engram(blocks: .max, .max, .max, .max)
        XCTAssertEqual(EngramLib.distance(a, b), 256)
    }

    func testDistanceKnown() {
        let a = Engram(blocks: 0, 0, 0, 0)
        let b = Engram(blocks: 0b1011, 0, 0, 0)
        XCTAssertEqual(EngramLib.distance(a, b), 3)
    }

    func testDistancesEmpty() {
        let probe = Engram.zero
        XCTAssertEqual(EngramLib.distances(probe: probe, candidates: []), [])
    }

    func testDistancesBatchMatchesPair() {
        let probe = Engram(blocks: 0xAAAA_AAAA, 0, 0, 0)
        let estate = (0..<10).map { i in
            Engram(blocks: UInt64(i) &* 0xDEAD, UInt64(i), 0, 0)
        }
        let batch = EngramLib.distances(probe: probe, candidates: estate)
        for i in 0..<estate.count {
            XCTAssertEqual(batch[i], EngramLib.distance(probe, estate[i]))
        }
    }

    func testFindNearestEmpty() {
        let probe = Engram.zero
        XCTAssertEqual(EngramLib.findNearest(probe: probe, in: [], k: 5), [])
    }

    func testFindNearestKZeroOrNegative() {
        let probe = Engram.zero
        let estate = [Engram(blocks: 1, 0, 0, 0)]
        XCTAssertEqual(EngramLib.findNearest(probe: probe, in: estate, k: 0), [])
        XCTAssertEqual(EngramLib.findNearest(probe: probe, in: estate, k: -1), [])
    }

    func testFindNearestKGreaterThanN() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 1, 0, 0, 0),
            Engram(blocks: 3, 0, 0, 0),
        ]
        let result = EngramLib.findNearest(probe: probe, in: estate, k: 10)
        XCTAssertEqual(result.count, 2)
    }

    func testFindNearestOrdering() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b1111, 0, 0, 0),
            Engram(blocks: 0b1,    0, 0, 0),
            Engram(blocks: 0b111,  0, 0, 0),
            Engram(blocks: 0b11,   0, 0, 0),
        ]
        let result = EngramLib.findNearest(probe: probe, in: estate, k: 3)
        XCTAssertEqual(result.map { $0.index }, [1, 3, 2])
        XCTAssertEqual(result.map { $0.distance }, [1, 2, 3])
    }

    func testFindNearestTieBreakByIndex() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b1,   0, 0, 0),
            Engram(blocks: 0b10,  0, 0, 0),
            Engram(blocks: 0b100, 0, 0, 0),
        ]
        let result = EngramLib.findNearest(probe: probe, in: estate, k: 3)
        XCTAssertEqual(result.map { $0.index }, [0, 1, 2])
    }

    func testFindNearestSingle() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b111, 0, 0, 0),
            Engram(blocks: 0b1,   0, 0, 0),
        ]
        let match = EngramLib.findNearest(probe: probe, in: estate)
        XCTAssertEqual(match?.index, 1)
        XCTAssertEqual(match?.distance, 1)
    }

    func testFindNearestSingleEmpty() {
        XCTAssertNil(EngramLib.findNearest(probe: Engram.zero, in: []))
    }

    func testFindWithin() {
        let probe = Engram.zero
        let estate = [
            Engram(blocks: 0b1,    0, 0, 0),
            Engram(blocks: 0b1111, 0, 0, 0),
            Engram(blocks: 0b11,   0, 0, 0),
        ]
        let result = EngramLib.findWithin(probe: probe, in: estate, maxDistance: 2)
        XCTAssertEqual(result.map { $0.index }, [0, 2])
        XCTAssertEqual(result.map { $0.distance }, [1, 2])
    }

    func testFindWithinEmpty() {
        XCTAssertEqual(
            EngramLib.findWithin(probe: Engram.zero,
                                 in: [], maxDistance: 10),
            [])
    }

    func testFindWithinNegativeMax() {
        let probe = Engram.zero
        let estate = [Engram(blocks: 1, 0, 0, 0)]
        XCTAssertEqual(
            EngramLib.findWithin(probe: probe, in: estate, maxDistance: -1),
            [])
    }

    func testUnionEmpty() {
        XCTAssertEqual(EngramLib.union([]), Engram.zero)
    }

    func testUnionTwo() {
        let a = Engram(blocks: 0b1010, 0, 0, 0)
        let b = Engram(blocks: 0b0101, 0, 0, 0)
        let result = EngramLib.union(a, b)
        XCTAssertEqual(result.block0, 0b1111)
    }

    func testUnionMany() {
        let engrams = [
            Engram(blocks: 0b0001, 0, 0, 0),
            Engram(blocks: 0b0010, 0, 0, 0),
            Engram(blocks: 0b0100, 0, 0, 0),
            Engram(blocks: 0b1000, 0, 0, 0),
        ]
        XCTAssertEqual(EngramLib.union(engrams).block0, 0b1111)
    }

    func testSessionMatchesStateless() {
        let probe = Engram(blocks: 0xDEAD_BEEF, 0, 0, 0)
        let estate = (0..<100).map { i in
            Engram(blocks: UInt64(i) &* 0xABCD, UInt64(i), 0, 0)
        }
        let stateless = EngramLib.findNearest(probe: probe, in: estate, k: 10)
        let session = EngramLib.session()
        let stateful = session.findNearest(probe: probe, in: estate, k: 10)
        XCTAssertEqual(stateless, stateful)
    }

    func testMatchOrdering() {
        let m1 = Match(index: 5, distance: 3)
        let m2 = Match(index: 1, distance: 3)
        let m3 = Match(index: 0, distance: 2)
        XCTAssertTrue(m3 < m2)
        XCTAssertTrue(m2 < m1)
        let sorted = [m1, m2, m3].sorted()
        XCTAssertEqual(sorted.map { $0.index }, [0, 1, 5])
    }
}
