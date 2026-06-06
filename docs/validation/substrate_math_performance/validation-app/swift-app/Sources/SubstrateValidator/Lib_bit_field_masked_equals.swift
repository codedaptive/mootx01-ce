// Lib_bit_field_masked_equals — lib-side conformance CRC for the
// `bit_field_masked_equals` primitive (cookbook §2.8 / §7.7), calling the
// SHIPPING SubstrateKernel.BitField.maskedEquals (not glref).
//
// Input schema (per BitFieldMaskedEqualsPrimitive):
//   bitmap   : i64 (hex, u64 bit-pattern, 8 bytes little-endian)
//   mask     : i64 (hex, u64 bit-pattern, 8 bytes little-endian)
//   expected : i64 (hex, u64 bit-pattern, 8 bytes little-endian)
//
// Output schema:
//   result : bool encoded as one u8 byte (0x00 = false, 0x01 = true).
//
// The harness writes exactly one byte per case via encoder.writeU8; we
// mirror that encoding byte-for-byte so the lib CRC matches the committed
// vector and the glref reference.
import Foundation
import Harness
import SubstrateKernel

enum Lib_bit_field_masked_equals {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            guard case .string(let bitmapHex) = c.inputs.get("bitmap") ?? .null,
                  case .string(let maskHex) = c.inputs.get("mask") ?? .null,
                  case .string(let expectedHex) = c.inputs.get("expected") ?? .null,
                  let bitmap = bfmeParseI64(bitmapHex),
                  let mask = bfmeParseI64(maskHex),
                  let expected = bfmeParseI64(expectedHex) else { continue }
            // BitField is a static enum in SubstrateKernel — call the static
            // func directly (no kernel instance). Do NOT qualify as
            // SubstrateKernel.BitField (module/type name would clash).
            let result = BitField.maskedEquals(bitmap, mask: mask, expected: expected)
            // Output is a single byte per case: 0x00 / 0x01.
            enc.writeU8(result ? 1 : 0)
        }
        return CRC32.compute(enc.bytes)
    }

    // Decode an 8-byte little-endian u64 hex string into an Int64 via its
    // two's-complement bit pattern, mirroring the harness's parseI64.
    private static func bfmeParseI64(_ s: String) -> Int64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[i]) << (i * 8) }
        return Int64(bitPattern: v)
    }
}
