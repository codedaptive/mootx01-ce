import Foundation
import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

/// SHA-256 conformance — NIST FIPS 180-4 published vectors. Mirror of
/// the Rust sha256 test module; the two legs are gated against the
/// same vectors so the centralized content-hash is identical across
/// ports (and therefore content IDs round-trip across replicas/tiers).
@Suite("SHA-256 NIST FIPS 180-4 vectors")
struct SHA256Tests {

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func testNISTEmptyString() {
        #expect(hex(SHA256.hash([])) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func testNISTabc() {
        #expect(hex(SHA256.hash(bytes("abc"))) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func testNISTTwoBlock() {
        let m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(hex(SHA256.hash(bytes(m))) ==
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func testNISTLongMillionA() {
        let m = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(hex(SHA256.hash(m)) ==
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func testOutputIs32Bytes() {
        #expect(SHA256.hash(bytes("anything")).count == 32)
    }
}
