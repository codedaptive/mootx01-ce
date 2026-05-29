// CanonicalBinaryEncoder.swift
//
// Canonical binary serialization per
// `docs/test-vector-format.md` § "Binary canonical form".
//
// The encoder produces a delimiter-free byte stream. Outputs from
// all cases of a vector file are concatenated in case order, and
// the resulting byte stream is CRC32'd to produce the
// `output_crc32` value that is the conformance gate.
//
// Encoding rules (all little-endian):
//
//   u8 / u16 / u32 / u64   width-sized LE
//   i8 .. i64              two's-complement LE
//   f64                    IEEE-754 LE (the bit pattern)
//   bool                   1 byte (0x00 or 0x01)
//   Option<T>              tag byte (0x00 None / 0x01 Some) + T if Some
//   Vec<T> / array         u32 LE length + concatenated T encodings
//   String                 u32 LE length + UTF-8 bytes
//   Fingerprint256         32 bytes (wire format)
//   HLC                    16 bytes (wire format)
//   UUID                   16 bytes (raw)

import Foundation

public struct CanonicalBinaryEncoder {

    private(set) public var bytes: [UInt8] = []

    public init() {}

    // MARK: - Unsigned integers

    public mutating func writeU8(_ v: UInt8) {
        bytes.append(v)
    }

    public mutating func writeU16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
    }

    public mutating func writeU32(_ v: UInt32) {
        for i in 0..<4 {
            bytes.append(UInt8((v >> (i * 8)) & 0xFF))
        }
    }

    public mutating func writeU64(_ v: UInt64) {
        for i in 0..<8 {
            bytes.append(UInt8((v >> (i * 8)) & 0xFF))
        }
    }

    // MARK: - Signed integers

    public mutating func writeI8(_ v: Int8) {
        bytes.append(UInt8(bitPattern: v))
    }

    public mutating func writeI16(_ v: Int16) {
        writeU16(UInt16(bitPattern: v))
    }

    public mutating func writeI32(_ v: Int32) {
        writeU32(UInt32(bitPattern: v))
    }

    public mutating func writeI64(_ v: Int64) {
        writeU64(UInt64(bitPattern: v))
    }

    // MARK: - Floating point

    public mutating func writeF64(_ v: Double) {
        writeU64(v.bitPattern)
    }

    public mutating func writeF32(_ v: Float32) {
        writeU32(v.bitPattern)
    }

    // MARK: - Boolean

    public mutating func writeBool(_ v: Bool) {
        writeU8(v ? 1 : 0)
    }

    // MARK: - Option<T>

    public mutating func writeOption<T>(_ v: T?, encoder: (inout Self, T) -> Void) {
        if let value = v {
            writeU8(1)
            encoder(&self, value)
        } else {
            writeU8(0)
        }
    }

    // MARK: - Bytes (raw)

    public mutating func writeBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    // MARK: - Length-prefixed sequences

    public mutating func writeArray<T>(_ items: [T], encoder: (inout Self, T) -> Void) {
        precondition(items.count <= Int(UInt32.max),
                     "array too long for u32 length prefix")
        writeU32(UInt32(items.count))
        for item in items {
            encoder(&self, item)
        }
    }

    public mutating func writeString(_ s: String) {
        let utf8 = Array(s.utf8)
        precondition(utf8.count <= Int(UInt32.max),
                     "string too long for u32 length prefix")
        writeU32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}
