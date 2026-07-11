// SHA256Tests.swift
//
// Swift library-test peer suite for `SHA256` (SHA256.swift). Mirrors
// the behavior set asserted by the Rust `sha256.rs` `#[test]` module
// (5 tests): the FIPS 180-4 NIST published vectors plus the digest
// length invariant. These pin the content-ID / seal primitive (the
// I-27 integrity triangle's binding leg) byte-for-byte; both legs hash
// the same vectors to the same digests.
//
// SHA-256 is pure integer math — no platform variability, no backend
// gating.

import Foundation  // String(format:) — Foundation overlay; required on non-Darwin
import Testing
@testable import SubstrateKernel

@Suite("SHA256")
struct SHA256Tests {

    /// Lowercase hex string of a digest, matching the Rust test's
    /// `hex(&hash(...))` helper.
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Test("NIST vector: empty string")
    func nistEmptyString() {
        #expect(hex(SHA256.hash(Array("".utf8)))
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("NIST vector: \"abc\"")
    func nistAbc() {
        #expect(hex(SHA256.hash(Array("abc".utf8)))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("NIST vector: 56-byte two-block input (padding boundary)")
    func nistTwoBlock() {
        // 56-byte input — exercises the multi-block path + padding boundary.
        let m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(hex(SHA256.hash(Array(m.utf8)))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test("NIST vector: one million 'a' (block-looping exerciser)")
    func nistLongMillionA() {
        // One million 'a' — the classic FIPS exerciser for block looping.
        let m = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(hex(SHA256.hash(m))
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test("digest is always 32 bytes")
    func outputIs32Bytes() {
        #expect(SHA256.hash(Array("anything".utf8)).count == 32)
    }
}
