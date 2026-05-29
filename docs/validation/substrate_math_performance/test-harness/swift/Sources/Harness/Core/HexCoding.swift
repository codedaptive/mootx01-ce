// HexCoding.swift
//
// Hex string encoding/decoding per `docs/test-vector-format.md`
// § "Type encodings". Lowercase "0x..." everywhere, no padding
// except where the type has a fixed width (f64 → 16 hex digits;
// Fingerprint256 → 64 hex digits; UUID → 32 hex digits).

import Foundation

public enum HexCoding {

    private static let lowerHex: [Character] = Array("0123456789abcdef")

    /// Encode a sequence of bytes as `"0x..."` lowercase, no
    /// padding. `[]` ⇒ `"0x"`.
    public static func encode(_ bytes: [UInt8]) -> String {
        var s = "0x"
        s.reserveCapacity(2 + bytes.count * 2)
        for b in bytes {
            s.append(lowerHex[Int(b >> 4)])
            s.append(lowerHex[Int(b & 0x0F)])
        }
        return s
    }

    /// Decode `"0x..."` lowercase or uppercase to a byte array.
    public static func decode(_ s: String) throws -> [UInt8] {
        var hex = s
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        guard hex.count % 2 == 0 else {
            throw HexCodingError.oddLength(s)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            let pair = hex[idx..<next]
            guard let b = UInt8(pair, radix: 16) else {
                throw HexCodingError.invalidCharacter(String(pair))
            }
            bytes.append(b)
            idx = next
        }
        return bytes
    }

    // MARK: - Typed encoders

    public static func u8(_ v: UInt8) -> String {
        return encode([v])
    }

    public static func u16(_ v: UInt16) -> String {
        return encode([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    public static func u32(_ v: UInt32) -> String {
        var b = [UInt8]()
        for i in 0..<4 { b.append(UInt8((v >> (i * 8)) & 0xFF)) }
        return encode(b)
    }

    public static func u64(_ v: UInt64) -> String {
        var b = [UInt8]()
        for i in 0..<8 { b.append(UInt8((v >> (i * 8)) & 0xFF)) }
        return encode(b)
    }

    /// f64 as the IEEE-754 bit pattern, always 16 hex digits.
    public static func f64(_ v: Double) -> String {
        let bits = v.bitPattern
        var b = [UInt8]()
        for i in 0..<8 { b.append(UInt8((bits >> (i * 8)) & 0xFF)) }
        return encode(b)
    }

    /// f32 as the IEEE-754 bit pattern, always 8 hex digits.
    public static func f32(_ v: Float32) -> String {
        let bits = v.bitPattern
        var b = [UInt8]()
        for i in 0..<4 { b.append(UInt8((bits >> (i * 8)) & 0xFF)) }
        return encode(b)
    }

    /// CRC32 value, always 8 hex digits.
    public static func crc32(_ v: UInt32) -> String {
        return u32(v)
    }
}

public enum HexCodingError: Error, CustomStringConvertible {
    case oddLength(String)
    case invalidCharacter(String)

    public var description: String {
        switch self {
        case .oddLength(let s):
            return "hex string has odd length: \(s)"
        case .invalidCharacter(let s):
            return "invalid hex characters: \(s)"
        }
    }
}
