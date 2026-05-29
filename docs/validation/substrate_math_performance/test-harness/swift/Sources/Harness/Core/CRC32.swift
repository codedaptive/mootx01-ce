// CRC32.swift
//
// CRC-32/ISO-HDLC (IEEE 802.3) implementation.
//
// Same polynomial and parameters as zlib `crc32`, Python
// `zlib.crc32`, Rust `crc32fast`. Used by the test harness as
// the conformance gate over canonical binary serializations of
// reference-implementation outputs (per
// `docs/test-vector-format.md`).
//
// Parameters:
//   polynomial    0xEDB88320 (reversed 0x04C11DB7)
//   initial       0xFFFFFFFF
//   input refl    yes
//   output refl   yes
//   output XOR    0xFFFFFFFF
//
// Zero external dependencies. Pure Swift, table-driven.

import Foundation

public struct CRC32 {

    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 == 1 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            t[i] = c
        }
        return t
    }()

    private var state: UInt32 = 0xFFFFFFFF

    public init() {}

    /// Feed bytes into the running CRC.
    public mutating func update(_ bytes: [UInt8]) {
        var s = state
        for b in bytes {
            let idx = Int((s ^ UInt32(b)) & 0xFF)
            s = (s >> 8) ^ Self.table[idx]
        }
        state = s
    }

    /// Finalize and return the 32-bit CRC value.
    public func finalize() -> UInt32 {
        return state ^ 0xFFFFFFFF
    }

    /// One-shot convenience over a byte sequence.
    public static func compute(_ bytes: [UInt8]) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.finalize()
    }
}
