import Foundation
import XCTest
@testable import SubstrateLib

/// SHA-256 conformance — NIST FIPS 180-4 published vectors. Mirror of
/// the Rust sha256 test module; the two legs are gated against the
/// same vectors so the centralized content-hash is identical across
/// ports (and therefore content IDs round-trip across replicas/tiers).
final class SHA256Tests: XCTestCase {

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testNISTEmptyString() {
        XCTAssertEqual(hex(SHA256.hash([])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testNISTabc() {
        XCTAssertEqual(hex(SHA256.hash(bytes("abc"))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testNISTTwoBlock() {
        let m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(hex(SHA256.hash(bytes(m))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testNISTLongMillionA() {
        let m = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(hex(SHA256.hash(m)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testOutputIs32Bytes() {
        XCTAssertEqual(SHA256.hash(bytes("anything")).count, 32)
    }
}
