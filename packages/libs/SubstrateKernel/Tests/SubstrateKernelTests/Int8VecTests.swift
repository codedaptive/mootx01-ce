// Int8VecTests.swift
//
// Unit pins for Int8Vec (ENCODER_RERANK_CONTRACT §4). The cross-port
// conformance gate over the shared fixture lives in SynapseKit
// (Int8VecConformanceTests), where the fixture file is.
//
// Failure modes pinned here:
//   1. A port that rounds half to even produces [127, 62, -62, 0, 0, 2, -2, 0]
//      on the exact-tie vector instead of [127, 63, -63, 1, -1, 2, -3, 0].
//   2. A port that divides by 128, or uses an asymmetric range, moves the
//      maximum element off ±127.
//   3. A port that scales every term instead of the accumulated sum changes
//      the float32 result of dotQuery.

import Testing
@testable import SubstrateKernel

@Suite("Int8Vec")
struct Int8VecTests {

    @Test("zero vector quantises to zeros with scale 1")
    func zeroVector() {
        let (q, scale) = Int8Vec.quantize([Float](repeating: 0, count: 8))
        #expect(q == [Int8](repeating: 0, count: 8))
        #expect(scale == 1)
        #expect(Int8Vec.dotQuery([Float](repeating: 0.25, count: 8), q: q, scale: scale) == 0)
    }

    @Test("maximum element maps to ±127 and dequantises back exactly")
    func maximumElement() {
        let (q, scale) = Int8Vec.quantize([0.5, -1.0, 0.25, 0.0])
        #expect(scale == Float(1) / 127)
        #expect(q == [64, -127, 32, 0])
        #expect(Int8Vec.dequantize(q, scale: scale)[1] == -1.0)
    }

    @Test("exact .5 ties round half away from zero")
    func halfTies() {
        // scale = 127·2^-8 / 127 = 2^-8 exactly, so every quotient is an exact
        // float32 value: 127, 62.5, -62.5, 0.5, -0.5, 1.5, -2.5, 0.
        let step = Float(1) / 256
        let v: [Float] = [127.0, 62.5, -62.5, 0.5, -0.5, 1.5, -2.5, 0.0].map { $0 * step }
        let (q, scale) = Int8Vec.quantize(v)
        #expect(scale == step)
        #expect(q == [127, 63, -63, 1, -1, 2, -3, 0])
    }

    @Test("dotQuery multiplies by scale once after accumulating")
    func dotQueryOrder() {
        let u: [Float] = [0.5, 0.5, 0.5, 0.5]
        let q: [Int8] = [10, -20, 30, -40]
        let scale: Float = 0.01
        let expected: Float = ((Float(0.5) * 10 + 0.5 * -20 + 0.5 * 30) + 0.5 * -40) * 0.01
        #expect(Int8Vec.dotQuery(u, q: q, scale: scale) == expected)
    }
}
