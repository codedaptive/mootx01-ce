// FNVTests.swift
//
// Per-type suite for FNV (FNV-1a string hash family). Mirrors the Rust
// `fnv.rs` inline #[test] set: hash64/hash32 offset-basis on empty
// string, determinism, hash16 low-truncation of hash64, and the
// independence of the 64- and 32-bit families.

import Testing
@testable import SubstrateTypes

@Suite("FNV-1a hash family")
struct FNVTests {

    @Test("hash64 of empty string is the offset basis")
    func hash64EmptyIsOffsetBasis() {
        #expect(FNV.hash64("") == 0xCBF2_9CE4_8422_2325)
    }

    @Test("hash64 is deterministic and input-sensitive")
    func hash64IsDeterministic() {
        #expect(FNV.hash64("hello") == FNV.hash64("hello"))
        #expect(FNV.hash64("hello") != FNV.hash64("world"))
    }

    @Test("hash32 of empty string is the offset basis")
    func hash32EmptyIsOffsetBasis() {
        #expect(FNV.hash32("") == 0x811C_9DC5)
    }

    @Test("hash32 is deterministic and input-sensitive")
    func hash32IsDeterministic() {
        #expect(FNV.hash32("hello") == FNV.hash32("hello"))
        #expect(FNV.hash32("hello") != FNV.hash32("world"))
    }

    @Test("hash16 is the low-16 truncation of hash64")
    func hash16IsLowTruncationOfHash64() {
        let s = "drawer-fingerprint-test"
        #expect(FNV.hash16(s) == UInt16(truncatingIfNeeded: FNV.hash64(s)))
    }

    @Test("hash64 and hash32 are independent families")
    func hash64AndHash32AreIndependentFamilies() {
        // Different offset bases, different primes, no derivation:
        // the low 32 bits of hash64 must not coincide with hash32.
        let s = "GeniusLocus"
        #expect(UInt32(truncatingIfNeeded: FNV.hash64(s)) != FNV.hash32(s))
    }
}
