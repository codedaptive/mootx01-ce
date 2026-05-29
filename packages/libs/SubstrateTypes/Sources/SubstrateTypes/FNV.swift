// FNV.swift
//
// Fowler–Noll–Vo 1a string hash, in the two widths the substrate
// uses and the 16-bit fold the cookbook calls out. Substrate-
// canonical: every kit that needs a deterministic string hash
// (drawer fingerprints, manifest-derived node ids, deterministic
// tokenization) consumes this by name (I-25). Behavior is byte-
// identical to glref-rust-fnv on the same input.
//
// The 64-bit and 32-bit variants are independent FNV-1a hashes
// with different offset bases and primes; they are not derivable
// from each other. `hash16` IS derivable — it is the low-16 fold
// of `hash64` (cookbook §3.3 / §3.4).

import Foundation

/// FNV-1a string hash family.
public enum FNV {

    // MARK: - FNV-1a 64-bit

    /// FNV-1a 64-bit. Offset basis `0xCBF29CE484222325`, prime
    /// `0x100000001B3`. Hashes UTF-8 bytes of the input string.
    @inlinable
    public static func hash64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001B3
        }
        return h
    }

    // MARK: - FNV-1a 32-bit

    /// FNV-1a 32-bit. Offset basis `0x811C9DC5`, prime `0x01000193`
    /// (decimal 16_777_619). A different hash family from `hash64`,
    /// not a truncation of it.
    @inlinable
    public static func hash32(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return h
    }

    // MARK: - 16-bit fold of FNV-1a 64-bit

    /// `hash64(s)` folded to 16 bits by low-bit truncation. This is
    /// the form the cookbook specifies for UDC-prefix and lattice
    /// sub-hashes (§3.3, §3.4). It is *not* an FNV-1a 16-bit
    /// variant; FNV-1a is not defined at 16 bits in the canonical
    /// reference.
    @inlinable
    public static func hash16(_ s: String) -> UInt16 {
        UInt16(truncatingIfNeeded: hash64(s))
    }
}
