// SplitMix64.swift
//
// SplitMix64 deterministic PRNG for case generation. Same
// algorithm used in `glref-swift-HyperplaneFamily.swift`
// (private there); promoted here so the harness can seed case
// generators reproducibly across languages.
//
// Bit-identical with the Rust harness's `SplitMix64`. Two ports
// seeded with the same u64 produce the same stream.

import Foundation

public struct SplitMix64 {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Returns the next `count` u64 values.
    public mutating func nextBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            let w = next()
            for i in 0..<min(8, remaining) {
                bytes.append(UInt8((w >> (i * 8)) & 0xFF))
                remaining -= 1
            }
        }
        return bytes
    }
}
