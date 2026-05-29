// HarnessTests.swift
//
// Sanity tests for the harness core. These do NOT test the
// reference implementations; they test that the harness itself
// (CRC, hex coding, canonical encoder, JSON writer) is correct.

import XCTest
@testable import Harness

final class HarnessTests: XCTestCase {

    // MARK: - CRC32

    func testCRC32EmptyIsZero() {
        XCTAssertEqual(CRC32.compute([]), 0)
    }

    func testCRC32KnownVector() {
        // "123456789" in ASCII → 0xCBF43926 (the standard CRC32
        // test vector).
        let input: [UInt8] = [0x31, 0x32, 0x33, 0x34, 0x35,
                              0x36, 0x37, 0x38, 0x39]
        XCTAssertEqual(CRC32.compute(input), 0xCBF43926)
    }

    // MARK: - Hex coding

    func testHexU64RoundTrip() {
        let v: UInt64 = 0xDEAD_BEEF_CAFE_BABE
        let hex = HexCoding.u64(v)
        XCTAssertEqual(hex, "0xbebafecaefbeadde")  // little-endian bytes
        let bytes = try? HexCoding.decode(hex)
        XCTAssertEqual(bytes?.count, 8)
        let back = bytes!.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        XCTAssertEqual(back, v)
    }

    func testHexF64RoundTrip() {
        let v: Double = 4.0
        let hex = HexCoding.f64(v)
        // 4.0 IEEE-754 = 0x4010_0000_0000_0000; LE bytes are
        // 00 00 00 00 00 00 10 40.
        XCTAssertEqual(hex, "0x0000000000001040")
        let bytes = try! HexCoding.decode(hex)
        let bits = bytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        XCTAssertEqual(Double(bitPattern: bits), v)
    }

    // MARK: - SplitMix64 determinism

    func testSplitMix64Deterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<10 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    // MARK: - Canonical binary encoder

    func testEncoderU64LittleEndian() {
        var enc = CanonicalBinaryEncoder()
        enc.writeU64(0x0102_0304_0506_0708)
        XCTAssertEqual(enc.bytes, [0x08, 0x07, 0x06, 0x05,
                                    0x04, 0x03, 0x02, 0x01])
    }

    func testEncoderF64IsBitPattern() {
        var enc = CanonicalBinaryEncoder()
        enc.writeF64(4.0)
        // 4.0 IEEE-754 bits = 0x4010_0000_0000_0000.
        XCTAssertEqual(enc.bytes, [0x00, 0x00, 0x00, 0x00,
                                    0x00, 0x00, 0x10, 0x40])
    }

    func testEncoderBool() {
        var enc = CanonicalBinaryEncoder()
        enc.writeBool(true)
        enc.writeBool(false)
        XCTAssertEqual(enc.bytes, [0x01, 0x00])
    }

    // MARK: - SimHash primitive end-to-end

    func testSimHashGenerateAndValidate() throws {
        let seed: UInt64 = 0xCAFE_BABE_DEAD_BEEF
        let file = try SimHashPrimitive.generate(seed: seed)
        XCTAssertEqual(file.primitive, "simhash")
        XCTAssertEqual(file.cases.count, 32)
        XCTAssertEqual(file.generator.language, "swift")

        let result = try SimHashPrimitive.validate(file)
        XCTAssertTrue(result.passed,
                      "self-generated file should self-validate")
        XCTAssertEqual(result.crcExpected, result.crcActual)
    }

    func testSimHashDeterministicAcrossRuns() throws {
        let seed: UInt64 = 0x1234_5678_9ABC_DEF0
        let f1 = try SimHashPrimitive.generate(seed: seed)
        let f2 = try SimHashPrimitive.generate(seed: seed)
        XCTAssertEqual(f1.outputCrc32, f2.outputCrc32)
        XCTAssertEqual(f1.cases.count, f2.cases.count)
        for (a, b) in zip(f1.cases, f2.cases) {
            // expected_output should be identical
            XCTAssertEqual(a.expectedOutput.get("block_value"),
                           b.expectedOutput.get("block_value"))
        }
    }
}

extension JSONValue: Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)):   return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.double(let a), .double(let b)):   return a.bitPattern == b.bitPattern
        case (.bool(let a), .bool(let b)):       return a == b
        case (.null, .null):                     return true
        case (.array(let a), .array(let b)):     return a == b
        case (.dict(let a), .dict(let b)):
            if a.keys != b.keys { return false }
            for k in a.keys {
                if a.values[k] != b.values[k] { return false }
            }
            return true
        default:                                  return false
        }
    }
}
