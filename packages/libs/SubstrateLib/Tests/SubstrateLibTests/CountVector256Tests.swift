// CountVector256Tests.swift
//
// Tests for the bundle-algebra count-vector and the kernel-layer
// count-fold. The load-bearing property is lossless composition: a
// tree-fold of count-vectors equals the direct accumulation of every
// leaf, in any fold order. The majority-vote read's strict tie
// convention and the cross-backend conformance gate are also fixed
// here.

import XCTest
@testable import SubstrateLib

final class CountVector256Tests: XCTestCase {

    // Deterministic pseudo-random fingerprints for property tests.
    private func fingerprints(seed: UInt64, count: Int) -> [Fingerprint256] {
        var state = seed &+ 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        return (0..<count).map { _ in
            Fingerprint256(block0: next(), block1: next(),
                           block2: next(), block3: next())
        }
    }

    // MARK: - Accumulation

    func testAccumulateCountsSetBits() {
        var cv = CountVector256()
        var fp = Fingerprint256.zero
        fp = fp.with(bit: 0, set: true)
        fp = fp.with(bit: 64, set: true)    // first bit of block1
        fp = fp.with(bit: 255, set: true)   // top bit of block3
        cv.accumulate(fp)
        XCTAssertEqual(cv.n, 1)
        XCTAssertEqual(cv.counts[0], 1)
        XCTAssertEqual(cv.counts[64], 1)
        XCTAssertEqual(cv.counts[255], 1)
        XCTAssertEqual(cv.counts[1], 0)
        XCTAssertEqual(cv.counts.reduce(0, +), 3)
    }

    func testEmptyVectorIsIdentity() {
        let empty = CountVector256.zero
        XCTAssertEqual(empty.n, 0)
        XCTAssertEqual(empty.counts.reduce(0, +), 0)
        XCTAssertEqual(empty.majorityVote(), Fingerprint256.zero)
        XCTAssertEqual(empty.profile(), [Float](repeating: 0, count: 256))
    }

    // MARK: - Lossless composition (the load-bearing property)

    func testTreeFoldEqualsDirectAccumulation() {
        // Split 300 members into three uneven groups, fold each group,
        // merge the partial vectors, and assert the result equals the
        // direct accumulation of all 300. This is the property
        // majority-vote lacks.
        let all = fingerprints(seed: 42, count: 300)
        let direct = CountVector256.fold(all)

        let g1 = CountVector256.fold(Array(all[0..<137]))
        let g2 = CountVector256.fold(Array(all[137..<255]))
        let g3 = CountVector256.fold(Array(all[255..<300]))
        let merged = g1 + g2 + g3

        XCTAssertEqual(merged, direct)
        XCTAssertEqual(merged.n, 300)
    }

    func testMergeIsCommutativeAndAssociative() {
        let a = CountVector256.fold(fingerprints(seed: 1, count: 50))
        let b = CountVector256.fold(fingerprints(seed: 2, count: 70))
        let c = CountVector256.fold(fingerprints(seed: 3, count: 90))
        XCTAssertEqual(a + b, b + a)                  // commutative
        XCTAssertEqual((a + b) + c, a + (b + c))      // associative
    }

    func testMergeWithIdentity() {
        let a = CountVector256.fold(fingerprints(seed: 7, count: 33))
        XCTAssertEqual(a + .zero, a)
        XCTAssertEqual(CountVector256.zero + a, a)
    }

    // MARK: - Majority-vote read and the strict tie convention

    func testMajorityVoteStrictThreshold() {
        // Four members. Bit 0 set in 3 of 4 (majority, 2*3 > 4 -> set).
        // Bit 1 set in 2 of 4 (exact tie, 2*2 > 4 is false -> clear).
        // Bit 2 set in 1 of 4 (minority -> clear).
        var members = [Fingerprint256](repeating: .zero, count: 4)
        members[0] = members[0].with(bit: 0); members[1] = members[1].with(bit: 0); members[2] = members[2].with(bit: 0)
        members[0] = members[0].with(bit: 1); members[1] = members[1].with(bit: 1)
        members[0] = members[0].with(bit: 2)
        let cv = CountVector256.fold(members)
        XCTAssertEqual(cv.n, 4)
        XCTAssertEqual(cv.counts[0], 3)
        XCTAssertEqual(cv.counts[1], 2)
        XCTAssertEqual(cv.counts[2], 1)
        let mv = cv.majorityVote()
        XCTAssertTrue(mv.bit(at: 0), "strict majority sets the bit")
        XCTAssertFalse(mv.bit(at: 1), "exact tie does not set the bit")
        XCTAssertFalse(mv.bit(at: 2), "minority does not set the bit")
    }

    func testProfileIsCountOverN() {
        var members = [Fingerprint256](repeating: .zero, count: 5)
        for i in 0..<3 { members[i] = members[i].with(bit: 10) }   // 3 of 5
        let cv = CountVector256.fold(members)
        let p = cv.profile()
        XCTAssertEqual(p[10], 0.6, accuracy: 1e-6)
        XCTAssertEqual(p[11], 0.0, accuracy: 1e-6)
    }

    // MARK: - OR-reduce is the degenerate fold

    func testMajorityVoteIsNotOrReduce() {
        // A bit set in a strict minority survives OR-reduce but not
        // majority-vote. This is why the stored object cannot be the
        // OR-reduced engram.
        var members = [Fingerprint256](repeating: .zero, count: 5)
        members[0] = members[0].with(bit: 99)                       // 1 of 5
        let cv = CountVector256.fold(members)
        let ored = ScalarKernel().orReduce256(members)
        XCTAssertTrue(ored.bit(at: 99), "OR-reduce keeps any set bit")
        XCTAssertFalse(cv.majorityVote().bit(at: 99), "majority drops the minority bit")
    }

    // MARK: - Cross-backend conformance gate

    func testCountFoldConformanceAcrossBackends() {
        // Every available kernel must produce a CountVector256
        // identical to the scalar reference. Backends that do not yet
        // override countFold256 inherit the reference and pass
        // trivially; the gate becomes load-bearing the moment a
        // vectorized override lands.
        let inputs = fingerprints(seed: 2026, count: 257)
        let reference = ScalarKernel().countFold256(inputs)
        for kind in [KernelKind.scalar, .simd, .bnns, .neon, .metal] {
            let k = PortableKernel.kernel(of: kind)
            let got = k.countFold256(inputs)
            XCTAssertEqual(got, reference,
                           "kernel \(kind.rawValue) diverged from scalar reference")
        }
    }

    func testCountFoldBatchMatchesPerBatchFold() {
        let b1 = fingerprints(seed: 11, count: 40)
        let b2 = fingerprints(seed: 22, count: 60)
        let batched = ScalarKernel().countFoldBatch(batches: [b1, b2])
        XCTAssertEqual(batched.count, 2)
        XCTAssertEqual(batched[0], CountVector256.fold(b1))
        XCTAssertEqual(batched[1], CountVector256.fold(b2))
    }
    // MARK: - SIMD count-fold equals the scalar reference (vectorization gate)

    func testSimdCountFoldMatchesScalarAcrossSizes() {
        // The SIMD vertical counter must equal the scalar reference at
        // every size, including the sizes that cross a plane boundary
        // (a new high bit appears in some column's count): 1, 2, 3, a
        // run around 255/256/257, and a larger cohort. A carry-logic
        // error shows up as a mismatch at one of these.
        let scalar = ScalarKernel()
        let simd = SimdKernel()
        for nMembers in [1, 2, 3, 4, 7, 8, 15, 16, 31, 255, 256, 257, 1000, 4096] {
            let fps = fingerprints(seed: UInt64(nMembers) &* 0x100000001B3, count: nMembers)
            let ref = scalar.countFold256(fps)
            let got = simd.countFold256(fps)
            XCTAssertEqual(got, ref, "SIMD diverged from scalar at n=\(nMembers)")
            XCTAssertEqual(got.n, UInt32(nMembers))
        }
    }

    func testSimdCountFoldEmpty() {
        XCTAssertEqual(SimdKernel().countFold256([]), CountVector256.zero)
    }

    func testSimdCountFoldHighCountColumn() {
        // A single column set in every member drives that column's
        // count to n, exercising the full plane stack while other
        // columns stay zero. Verifies the bit-sliced readout assembles
        // the count correctly across all planes.
        let n = 1000
        var members = [Fingerprint256](repeating: .zero, count: n)
        for i in 0..<n { members[i] = members[i].with(bit: 137, set: true) }
        let cv = SimdKernel().countFold256(members)
        XCTAssertEqual(cv.counts[137], UInt32(n))
        XCTAssertEqual(cv.counts[136], 0)
        XCTAssertEqual(cv.counts[138], 0)
        XCTAssertEqual(cv, ScalarKernel().countFold256(members))
    }

}
