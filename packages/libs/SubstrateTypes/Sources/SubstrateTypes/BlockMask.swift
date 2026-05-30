// BlockMask.swift
//
// Phase 4.1 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.4.1)
//
// Typed bitmask over the four Fingerprint256 blocks. Replaces the
// `Set<Int>` parameter on Hamming.distance / Hamming.similarity
// (and downstream HammingNN.search): one byte, zero allocation,
// branchless contains() check. Mirrors the Rust side's existing
// `u8` block-mask constants (BLOCK_0..BLOCK_3, ALL_BLOCKS) and
// gives Swift the same shape.
//
// The four blocks correspond to the cookbook §3 factorization:
//
//   block0 — Bitmap-LSH       (§3.2)
//   block1 — Lattice-LSH      (§3.3)
//   block2 — Lineage+Temporal (§3.4)
//   block3 — Channel+Source   (§3.5)
//
// Lens citations:
//   APL — mask-and-AND idiom over fixed-width array
//   Clojure — value-semantic typed parameter
//   consumer-side analysis — Set<Int> per-call allocation was a
//                            hot-path footgun in HammingNN.

import Foundation

public struct BlockMask: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let block0 = BlockMask(rawValue: 0b0001)
    public static let block1 = BlockMask(rawValue: 0b0010)
    public static let block2 = BlockMask(rawValue: 0b0100)
    public static let block3 = BlockMask(rawValue: 0b1000)

    /// All four blocks selected — the common case.
    public static let all:  BlockMask = [.block0, .block1, .block2, .block3]
    /// No blocks selected — distance over this returns 0.
    public static let none: BlockMask = []

    /// Number of blocks selected (0...4). Used by Hamming.similarity
    /// to compute the maximum-distance denominator.
    @inlinable public var blockCount: Int {
        return Int(rawValue.nonzeroBitCount)
    }
}
