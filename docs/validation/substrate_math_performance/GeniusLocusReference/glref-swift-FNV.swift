// glref-swift-FNV.swift
//
// Canonical scalar reference for FNV-1a in two widths and the
// 16-bit fold. Byte-identical to packages/libs/SubstrateLib/
// Sources/SubstrateLib/FNV.swift (the shipping implementation
// kits consume by name per I-25) and to glref-rust-fnv.rs in
// the Rust reference crate.
//
// FNV-1a 64-bit and 32-bit are independent hash families with
// different offset basis and prime constants; they are not
// derivable from each other. `hash16` IS derivable — it is the
// low-16 fold of `hash64` (cookbook §3.3, §3.4).

import Foundation

/// FNV-1a string hash family (substrate-canonical, I-25).
public enum FNV {

    /// FNV-1a 64-bit. Offset basis `0xCBF29CE484222325`,
    /// prime `0x100000001B3`. Hashes UTF-8 bytes of the input.
    @inlinable
    public static func hash64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001B3
        }
        return h
    }

    /// FNV-1a 32-bit. Offset basis `0x811C9DC5`,
    /// prime `0x01000193` (decimal 16_777_619). An independent
    /// hash family from `hash64`, not a truncation of it.
    @inlinable
    public static func hash32(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return h
    }

    /// `hash64(s)` folded to 16 bits by low-bit truncation
    /// (cookbook §3.3, §3.4). Not an FNV-1a 16-bit variant;
    /// FNV-1a is not standard-defined at 16 bits.
    @inlinable
    public static func hash16(_ s: String) -> UInt16 {
        UInt16(truncatingIfNeeded: hash64(s))
    }
}
