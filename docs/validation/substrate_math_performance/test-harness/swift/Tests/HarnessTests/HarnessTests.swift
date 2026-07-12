// HarnessTests.swift
//
// Sanity tests for the harness core. These do NOT test the
// reference implementations; they test that the harness itself
// (CRC, hex coding, canonical encoder, JSON writer) is correct.

import Foundation
import Testing
@testable import Harness

@Suite("Harness core")
struct HarnessTests {

    // MARK: - CRC32

    @Test func crc32EmptyIsZero() {
        #expect(CRC32.compute([]) == 0)
    }

    @Test func crc32KnownVector() {
        // "123456789" in ASCII → 0xCBF43926 (the standard CRC32
        // test vector).
        let input: [UInt8] = [0x31, 0x32, 0x33, 0x34, 0x35,
                              0x36, 0x37, 0x38, 0x39]
        #expect(CRC32.compute(input) == 0xCBF43926)
    }

    // MARK: - Hex coding

    @Test func hexU64RoundTrip() {
        let v: UInt64 = 0xDEAD_BEEF_CAFE_BABE
        let hex = HexCoding.u64(v)
        #expect(hex == "0xbebafecaefbeadde")  // little-endian bytes
        let bytes = try? HexCoding.decode(hex)
        #expect(bytes?.count == 8)
        let back = bytes!.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        #expect(back == v)
    }

    @Test func hexF64RoundTrip() {
        let v: Double = 4.0
        let hex = HexCoding.f64(v)
        // 4.0 IEEE-754 = 0x4010_0000_0000_0000; LE bytes are
        // 00 00 00 00 00 00 10 40.
        #expect(hex == "0x0000000000001040")
        let bytes = try! HexCoding.decode(hex)
        let bits = bytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        #expect(Double(bitPattern: bits) == v)
    }

    // MARK: - SplitMix64 determinism

    @Test func splitMix64Deterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<10 {
            #expect(a.next() == b.next())
        }
    }

    // MARK: - Canonical binary encoder

    @Test func encoderU64LittleEndian() {
        var enc = CanonicalBinaryEncoder()
        enc.writeU64(0x0102_0304_0506_0708)
        #expect(enc.bytes == [0x08, 0x07, 0x06, 0x05,
                              0x04, 0x03, 0x02, 0x01])
    }

    @Test func encoderF64IsBitPattern() {
        var enc = CanonicalBinaryEncoder()
        enc.writeF64(4.0)
        // 4.0 IEEE-754 bits = 0x4010_0000_0000_0000.
        #expect(enc.bytes == [0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x10, 0x40])
    }

    @Test func encoderBool() {
        var enc = CanonicalBinaryEncoder()
        enc.writeBool(true)
        enc.writeBool(false)
        #expect(enc.bytes == [0x01, 0x00])
    }

    // MARK: - SimHash primitive end-to-end

    @Test func simHashGenerateAndValidate() throws {
        let seed: UInt64 = 0xCAFE_BABE_DEAD_BEEF
        let file = try SimHashPrimitive.generate(seed: seed)
        #expect(file.primitive == "simhash")
        #expect(file.cases.count == 40)  // 32 pair-at-a-time + 8 batched
        #expect(file.generator.language == "swift")

        let result = try SimHashPrimitive.validate(file)
        #expect(result.passed,
                "self-generated file should self-validate")
        #expect(result.crcExpected == result.crcActual)
    }

    @Test func simHashDeterministicAcrossRuns() throws {
        let seed: UInt64 = 0x1234_5678_9ABC_DEF0
        let f1 = try SimHashPrimitive.generate(seed: seed)
        let f2 = try SimHashPrimitive.generate(seed: seed)
        #expect(f1.outputCrc32 == f2.outputCrc32)
        #expect(f1.cases.count == f2.cases.count)
        for (a, b) in zip(f1.cases, f2.cases) {
            // expected_output should be identical
            #expect(a.expectedOutput.get("block_value") ==
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
