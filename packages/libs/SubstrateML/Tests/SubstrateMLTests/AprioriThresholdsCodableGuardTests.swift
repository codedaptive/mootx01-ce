// AprioriThresholdsCodableGuardTests.swift
//
// Guard tests for the custom Decodable implementation on AprioriThresholds.
//
// SECURITY FIX (planned hardening 2026-06-28): Swift synthesises a
// Decodable init that sets stored properties directly, bypassing the
// public init's `max(2, maxK)` floor. A payload with maxK = 0 or 1
// would produce an AprioriThresholds whose maxK is below the enforced
// minimum, silently corrupting the for-loop `for _ in 2...thresholds.maxK`.
// The custom init(from:) routes through the public init so the clamping
// is always applied regardless of the serialised value.

import Testing
import Foundation
@testable import SubstrateML

@Suite("AprioriThresholdsCodableGuard")
struct AprioriThresholdsCodableGuardTests {

    // MARK: - maxK floor enforcement via Codable

    /// Decoding a payload with maxK = 0 must produce maxK = 2 (clamped).
    @Test func decode_maxKZero_clampedToTwo() throws {
        let json = """
        {"minSupport":0.1,"minConfidence":0.5,"minLift":1.0,"maxK":0}
        """
        let decoded = try JSONDecoder().decode(AprioriThresholds.self, from: Data(json.utf8))
        #expect(decoded.maxK == 2,
                "maxK=0 must be clamped to 2 by the custom Decodable init")
    }

    /// Decoding a payload with maxK = 1 must produce maxK = 2 (clamped).
    @Test func decode_maxKOne_clampedToTwo() throws {
        let json = """
        {"minSupport":0.1,"minConfidence":0.5,"minLift":1.0,"maxK":1}
        """
        let decoded = try JSONDecoder().decode(AprioriThresholds.self, from: Data(json.utf8))
        #expect(decoded.maxK == 2,
                "maxK=1 must be clamped to 2 by the custom Decodable init")
    }

    /// Decoding a payload with maxK = -5 (negative) must produce maxK = 2.
    @Test func decode_negativeMaxK_clampedToTwo() throws {
        let json = """
        {"minSupport":0.2,"minConfidence":0.6,"minLift":1.0,"maxK":-5}
        """
        let decoded = try JSONDecoder().decode(AprioriThresholds.self, from: Data(json.utf8))
        #expect(decoded.maxK == 2,
                "maxK=-5 must be clamped to 2 by the custom Decodable init")
    }

    /// Decoding a payload with maxK = 3 (valid) must preserve the value.
    @Test func decode_maxKThree_preserved() throws {
        let json = """
        {"minSupport":0.05,"minConfidence":0.4,"minLift":1.0,"maxK":3}
        """
        let decoded = try JSONDecoder().decode(AprioriThresholds.self, from: Data(json.utf8))
        #expect(decoded.maxK == 3,
                "maxK=3 is above the floor and must not be altered")
    }

    /// Encoding → decoding round-trip must preserve a valid maxK value.
    @Test func roundTrip_preservesValidMaxK() throws {
        let original = AprioriThresholds(
            minSupport: 0.1,
            minConfidence: 0.5,
            minLift: 1.2,
            maxK: 4
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AprioriThresholds.self, from: data)
        #expect(decoded == original, "round-trip must preserve a valid AprioriThresholds")
    }

    /// The public init(maxK:) still enforces the floor (non-regression).
    @Test func publicInit_maxKBelowFloor_clampedToTwo() {
        let thresholds = AprioriThresholds(minSupport: 0.1, minConfidence: 0.5, maxK: 1)
        #expect(thresholds.maxK == 2,
                "public init must clamp maxK=1 to 2")
    }
}
