// MortonKey.swift
//
// The chest placement key (ADR-026, LocusKit spec § 12): the Morton
// (Z-order) interleave of two bit orderings of a 256-bit fingerprint.
//
// WHY two orderings: sorting fingerprints as one integer is a
// one-dimensional order over a 256-dimensional Hamming space; two
// fingerprints that differ in one high bit sort far apart however alike the
// rest of them is. Interleaving a second, permuted ordering bit for bit
// means a pair of similar fingerprints lands far apart only when BOTH
// orderings put a differing bit high, which the permutation makes unlikely.
//
// WHY Morton and not Hilbert: the same two orderings under a Hilbert curve
// give slightly better locality at slightly more code. Nothing above this
// file reads the key's bits, so the swap is confined here if it is ever
// measured to matter. Do not add a third ordering: it only reshuffles which
// bits count as high.
//
// Determinism: the key, the permutation and the bin cuts are pinned by the
// vectors in EngramLibTests / engram_lib_tests.rs, identical on both ports.

import Foundation
import SubstrateTypes

/// A 512-bit placement key, eight words, most significant word first.
/// Ordered lexicographically by word, so `<` is the numeric order of the
/// 512-bit value.
public struct MortonKey: Hashable, Sendable, Comparable {
    public let words: [UInt64]

    public init(words: [UInt64]) {
        precondition(words.count == 8, "MortonKey is eight 64-bit words")
        self.words = words
    }

    public static func < (lhs: MortonKey, rhs: MortonKey) -> Bool {
        lhs.words.lexicographicallyPrecedes(rhs.words)
    }

    /// The key as 128 lowercase hex characters, most significant word first:
    /// the form a chest node is named by (LocusKit spec § 12). Fixed width
    /// and lowercase so string order equals key order, which is what lets a
    /// room's chests be sorted by name.
    public var hex: String {
        words.map { String(format: "%016llx", $0) }.joined()
    }

    /// The key a `hex` name denotes; nil unless it is exactly 128 hex
    /// characters (either case).
    public init?(hex: String) {
        guard hex.count == 128 else { return nil }
        var words: [UInt64] = []
        words.reserveCapacity(8)
        var rest = Substring(hex)
        while !rest.isEmpty {
            let chunk = rest.prefix(16)
            guard let word = UInt64(chunk, radix: 16) else { return nil }
            words.append(word)
            rest = rest.dropFirst(16)
        }
        self.words = words
    }
}

/// One chest's key range after a deal: every key in `low ... high` belongs
/// to it, and `count` keys were dealt into it.
public struct KeyRange<Key: Comparable & Sendable>: Sendable {
    public let low: Key
    public let high: Key
    public let count: Int
    public init(low: Key, high: Key, count: Int) { self.low = low; self.high = high; self.count = count }
}

public enum ChestPlacement {
    /// A chest at or above this many drawers owes its room a re-bin.
    public static let capacity = 500
    /// A re-bin deals chests to this size.
    public static let fill = 250

    /// Ordering B's bit for ordering A's bit `i`: an affine bijection on
    /// 0..<256 (97 is odd, so coprime with 256). Pinned by the vectors;
    /// changing it re-bins every estate.
    @inlinable
    public static func permutation(_ i: Int) -> Int {
        (i &* 97 &+ 41) & 255
    }

    /// Bit `i` of the fingerprint, where bit 0 is the most significant bit
    /// of `block0` and bit 255 the least significant bit of `block3`.
    @inlinable
    static func bit(_ f: Fingerprint256, _ i: Int) -> UInt64 {
        let block: UInt64
        switch i >> 6 {
        case 0: block = f.block0
        case 1: block = f.block1
        case 2: block = f.block2
        default: block = f.block3
        }
        return (block >> UInt64(63 - (i & 63))) & 1
    }

    /// The placement key: key bit 2i is fingerprint bit i, key bit 2i+1 is
    /// fingerprint bit `permutation(i)`, bit 0 most significant.
    public static func key(_ fingerprint: Fingerprint256) -> MortonKey {
        var words = [UInt64](repeating: 0, count: 8)
        for i in 0..<256 {
            let a = bit(fingerprint, i)
            let b = bit(fingerprint, permutation(i))
            let pa = 2 * i, pb = 2 * i + 1
            words[pa >> 6] |= a << UInt64(63 - (pa & 63))
            words[pb >> 6] |= b << UInt64(63 - (pb & 63))
        }
        return MortonKey(words: words)
    }

    /// Deal keys already in ascending order into chests of `fill`: the
    /// ranges of consecutive runs, the last one shorter. Empty input, no
    /// ranges.
    public static func deal<Key>(sortedKeys: [Key], fill: Int) -> [KeyRange<Key>] {
        precondition(fill > 0, "fill must be positive")
        var ranges: [KeyRange<Key>] = []
        var start = 0
        while start < sortedKeys.count {
            let end = min(start + fill, sortedKeys.count)
            ranges.append(KeyRange(low: sortedKeys[start], high: sortedKeys[end - 1], count: end - start))
            start = end
        }
        return ranges
    }

    /// The index of the range whose `low ... high` holds `key`, by binary
    /// search over ranges in ascending order; nil when the key falls below
    /// the first low, above the last high, or in a gap between ranges.
    public static func rangeIndex<Key>(of key: Key, in ranges: [KeyRange<Key>]) -> Int? {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if key < r.low { hi = mid - 1 }
            else if key > r.high { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }
}
