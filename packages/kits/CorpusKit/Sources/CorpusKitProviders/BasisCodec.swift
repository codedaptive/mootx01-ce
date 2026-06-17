// BasisCodec.swift
//
// Shared little-endian binary codec for distributional-provider basis
// serialization (mission 6a-i). One definition, used by all four
// stateful providers (RandomIndexing, PPMI, LSA, NMF). This is
// PROVIDER-FORMAT code, not a math primitive — it lives in
// CorpusKitProviders, never in the substrate.
//
// ## Why a hand-rolled binary codec rather than Codable/JSON
//
// The format is the CROSS-PORT CONTRACT: identical trained state on
// Swift and Rust MUST produce byte-identical blobs. JSON float encoding,
// key ordering, and whitespace are not guaranteed identical across the
// two language ecosystems. A fixed little-endian binary layout with
// explicit sorted-key map ordering removes every source of ambiguity:
// the byte stream is a pure function of the logical state.
//
// ## Byte format (the contract — mirrored exactly in Rust basis_codec.rs)
//
//   - Endianness: LITTLE-ENDIAN throughout, no exceptions.
//   - Integers: UInt32 → 4 bytes LE; UInt64 → 8 bytes LE.
//   - Float32:  IEEE-754 bit pattern (Float.bitPattern) → UInt32 → 4 bytes LE.
//   - Float64:  IEEE-754 bit pattern (Double.bitPattern) → UInt64 → 8 bytes LE.
//   - String:   UInt32 LE byte-length prefix, then that many UTF-8 bytes.
//   - [Float]:  UInt32 LE element count, then count × (Float32 = 4 bytes).
//   - [[Float]] (matrix): UInt32 LE row count, then each row as a [Float].
//   - Map<String,*>: UInt32 LE entry count, then entries emitted in
//     LEXICOGRAPHICALLY ASCENDING order of the key's UTF-8 bytes. Sorting
//     is what makes Swift and Rust emit identical bytes for the same map
//     (HashMap/Dictionary iteration order is unspecified on both ports).
//
// Each provider blob is framed as:
//   MAGIC (4 ASCII bytes, provider-specific) | FORMAT_VERSION (1 byte) | payload
//
// The magic + version live at the FRONT so mission 6a-ii can detect and
// version a persisted basis without parsing the payload. An unknown
// version or a truncated blob is rejected with a structured
// CorpusKitError.decodingFailure — never a force-unwrap crash.

import Foundation
import CorpusKit

// MARK: - Format version

/// Current basis-blob format version. Bumped only when the byte layout
/// of any provider's payload changes incompatibly. Mission 6a-i ships v1.
public let basisFormatVersion: UInt8 = 1

// MARK: - Writer

/// Append-only little-endian byte writer for basis serialization.
///
/// Every primitive is appended in the fixed little-endian layout
/// documented at the top of this file. The writer holds no provider
/// knowledge — providers compose their blob from these primitives.
public struct BasisWriter {

    /// Accumulated bytes. Read out via `data` when the blob is complete.
    private(set) var bytes: [UInt8] = []

    public init() {}

    /// The serialized bytes accumulated so far.
    public var data: Data { Data(bytes) }

    /// Append a single raw byte (used for the format-version tag).
    public mutating func writeByte(_ b: UInt8) {
        bytes.append(b)
    }

    /// Append the 4 ASCII magic bytes that identify a provider's blob.
    /// Precondition: `magic` is exactly 4 ASCII bytes.
    public mutating func writeMagic(_ magic: [UInt8]) {
        precondition(magic.count == 4, "BasisWriter.writeMagic: magic must be exactly 4 bytes")
        bytes.append(contentsOf: magic)
    }

    /// Append a UInt32 in little-endian order (low byte first).
    public mutating func writeU32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }

    /// Append a UInt64 in little-endian order (low byte first).
    public mutating func writeU64(_ v: UInt64) {
        var x = v
        for _ in 0..<8 {
            bytes.append(UInt8(x & 0xFF))
            x >>= 8
        }
    }

    /// Append a Float32 as its IEEE-754 bit pattern, little-endian.
    /// Using `bitPattern` guarantees -0.0, NaN, and subnormals round-trip
    /// exactly and match Rust's `f32::to_le_bytes`.
    public mutating func writeF32(_ v: Float) {
        writeU32(v.bitPattern)
    }

    /// Append a UTF-8 string: UInt32 LE byte-length prefix, then the bytes.
    public mutating func writeString(_ s: String) {
        let utf8 = Array(s.utf8)
        writeU32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    /// Append a Float vector: UInt32 LE count, then each Float32.
    public mutating func writeFloatArray(_ a: [Float]) {
        writeU32(UInt32(a.count))
        for x in a { writeF32(x) }
    }

    /// Append a Float matrix: UInt32 LE row count, then each row as a
    /// length-prefixed Float vector (rows may be ragged; each carries its
    /// own length, so jagged matrices round-trip faithfully).
    public mutating func writeFloatMatrix(_ m: [[Float]]) {
        writeU32(UInt32(m.count))
        for row in m { writeFloatArray(row) }
    }

    /// Append a String→[Float] map in lexicographically ascending key
    /// order (UTF-8 byte order). Sorting is REQUIRED for cross-port byte
    /// identity: Dictionary iteration order is unspecified, so the keys
    /// are sorted before emission so Swift and Rust agree byte-for-byte.
    public mutating func writeStringFloatVectorMap(_ map: [String: [Float]]) {
        // Sort by the key's UTF-8 byte sequence. Swift String's default
        // `<` is Unicode-canonical, NOT raw byte order; the Rust port sorts
        // by raw bytes. To agree, both ports sort by the UTF-8 byte array.
        let sortedKeys = map.keys.sorted { lhsLess($0, $1) }
        writeU32(UInt32(sortedKeys.count))
        for key in sortedKeys {
            writeString(key)
            writeFloatArray(map[key]!)
        }
    }

    /// Append a String→UInt32 map (term → vocabulary index), sorted by the
    /// key's UTF-8 bytes (same ordering rule as the float-vector map).
    public mutating func writeStringU32Map(_ map: [String: Int]) {
        let sortedKeys = map.keys.sorted { lhsLess($0, $1) }
        writeU32(UInt32(sortedKeys.count))
        for key in sortedKeys {
            writeString(key)
            writeU32(UInt32(map[key]!))
        }
    }

    /// Lexicographic comparison of two strings by their raw UTF-8 bytes.
    /// This matches Rust's `Ord for str` (which compares by bytes), so the
    /// two ports emit map entries in the identical order.
    private func lhsLess(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        let n = min(ab.count, bb.count)
        var i = 0
        while i < n {
            if ab[i] != bb[i] { return ab[i] < bb[i] }
            i += 1
        }
        return ab.count < bb.count
    }
}

// MARK: - Reader

/// Sequential little-endian byte reader for basis deserialization.
///
/// Every read advances a cursor and bounds-checks against the buffer.
/// A read past the end throws `CorpusKitError.decodingFailure` — there is
/// NO force-unwrap and NO out-of-bounds crash on a truncated blob.
public struct BasisReader {

    private let bytes: [UInt8]
    private var cursor: Int = 0

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    /// Number of unread bytes remaining.
    public var remaining: Int { bytes.count - cursor }

    /// Read a single raw byte, or throw if the buffer is exhausted.
    public mutating func readByte() throws -> UInt8 {
        guard cursor + 1 <= bytes.count else {
            throw CorpusKitError.decodingFailure("BasisReader: truncated blob reading byte at offset \(cursor)")
        }
        let b = bytes[cursor]
        cursor += 1
        return b
    }

    /// Read 4 magic bytes and verify they equal `expected`. Throws on
    /// truncation or magic mismatch (wrong provider / corrupted header).
    public mutating func expectMagic(_ expected: [UInt8]) throws {
        guard cursor + 4 <= bytes.count else {
            throw CorpusKitError.decodingFailure("BasisReader: truncated blob reading magic")
        }
        let got = Array(bytes[cursor..<cursor + 4])
        cursor += 4
        guard got == expected else {
            throw CorpusKitError.decodingFailure(
                "BasisReader: magic mismatch — expected \(expected), got \(got)")
        }
    }

    /// Read the format-version byte and verify it is `expected`. An unknown
    /// version is rejected so a future on-disk format is never silently
    /// misread (mission 6a-ii relies on this gate).
    public mutating func expectVersion(_ expected: UInt8) throws {
        let v = try readByte()
        guard v == expected else {
            throw CorpusKitError.decodingFailure(
                "BasisReader: unsupported format version \(v) (expected \(expected))")
        }
    }

    /// Read a little-endian UInt32, or throw on truncation.
    public mutating func readU32() throws -> UInt32 {
        guard cursor + 4 <= bytes.count else {
            throw CorpusKitError.decodingFailure("BasisReader: truncated blob reading u32 at offset \(cursor)")
        }
        let b0 = UInt32(bytes[cursor])
        let b1 = UInt32(bytes[cursor + 1]) << 8
        let b2 = UInt32(bytes[cursor + 2]) << 16
        let b3 = UInt32(bytes[cursor + 3]) << 24
        cursor += 4
        return b0 | b1 | b2 | b3
    }

    /// Read a little-endian UInt64, or throw on truncation.
    public mutating func readU64() throws -> UInt64 {
        guard cursor + 8 <= bytes.count else {
            throw CorpusKitError.decodingFailure("BasisReader: truncated blob reading u64 at offset \(cursor)")
        }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(bytes[cursor + i]) << (8 * i)
        }
        cursor += 8
        return v
    }

    /// Read a Float32 from its little-endian IEEE-754 bit pattern.
    public mutating func readF32() throws -> Float {
        Float(bitPattern: try readU32())
    }

    /// Read a UTF-8 string (UInt32 LE length prefix, then bytes).
    public mutating func readString() throws -> String {
        let len = Int(try readU32())
        guard cursor + len <= bytes.count else {
            throw CorpusKitError.decodingFailure("BasisReader: truncated blob reading string of length \(len)")
        }
        let slice = Array(bytes[cursor..<cursor + len])
        cursor += len
        guard let s = String(bytes: slice, encoding: .utf8) else {
            throw CorpusKitError.decodingFailure("BasisReader: invalid UTF-8 in string")
        }
        return s
    }

    /// Read a Float vector (UInt32 LE count, then each Float32).
    public mutating func readFloatArray() throws -> [Float] {
        let count = Int(try readU32())
        var out = [Float]()
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try readF32()) }
        return out
    }

    /// Read a Float matrix (UInt32 LE row count, then each row).
    public mutating func readFloatMatrix() throws -> [[Float]] {
        let rows = Int(try readU32())
        var out = [[Float]]()
        out.reserveCapacity(rows)
        for _ in 0..<rows { out.append(try readFloatArray()) }
        return out
    }

    /// Read a String→[Float] map. Entries were written in sorted key order
    /// but the reconstructed Dictionary does not depend on order.
    public mutating func readStringFloatVectorMap() throws -> [String: [Float]] {
        let count = Int(try readU32())
        var out = [String: [Float]](minimumCapacity: count)
        for _ in 0..<count {
            let key = try readString()
            let vec = try readFloatArray()
            out[key] = vec
        }
        return out
    }

    /// Read a String→Int map (term → vocabulary index).
    public mutating func readStringU32Map() throws -> [String: Int] {
        let count = Int(try readU32())
        var out = [String: Int](minimumCapacity: count)
        for _ in 0..<count {
            let key = try readString()
            let idx = Int(try readU32())
            out[key] = idx
        }
        return out
    }
}
