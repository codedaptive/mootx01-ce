// SHA256.swift
//
// SHA-256 content-hash primitive for the substrate.
//
// Per the F18 atomic-centralization rule: content addressing is a
// math atomic and lives in SubstrateLib. The audit-log content ID
// (cookbook §5.1 — entries are content-addressed by SHA-256 over
// their wire encoding) hashes through this one implementation, so
// every kit that content-addresses an audit entry produces identical
// IDs and the G-Set deduplicates correctly across replicas and tiers.
//
// This is a faithful, dependency-free FIPS 180-4 SHA-256. It was
// lifted verbatim from GeniusLocusKit's in-kit implementation (which
// the audit conformance vectors already pin) so the centralization
// preserves every existing content ID byte-for-byte. The conformance
// tests below add the NIST published vectors on top, so the primitive
// is gated both against the prior in-kit bytes and against the
// standard.
//
// Mirror: rust/glref-rust-sha256.rs. The two legs are conformance-
// gated against the same vectors.

import Foundation

/// FIPS 180-4 SHA-256. Pure, dependency-free, deterministic.
public enum SHA256 {

    /// Hash `bytes`, returning the 32-byte digest.
    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        // Pad: append 0x80, then zero bytes until length ≡ 56 (mod 64),
        // then 8-byte big-endian length in bits.
        var msg = bytes
        let bitLen = UInt64(bytes.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 {
            msg.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> shift) & 0xFF))
        }
        // Process each 512-bit block.
        var offset = 0
        while offset < msg.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = (UInt32(msg[j]) << 24)
                     | (UInt32(msg[j + 1]) << 16)
                     | (UInt32(msg[j + 2]) << 8)
                     |  UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let mj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ mj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
            offset += 64
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in h {
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8((word >> shift) & 0xFF))
            }
        }
        return out
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x >> n) | (x << (32 - n))
    }
}
