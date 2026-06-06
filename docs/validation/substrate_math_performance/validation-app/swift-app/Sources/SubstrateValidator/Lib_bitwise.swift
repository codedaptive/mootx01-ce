// Lib_bitwise — lib-side conformance CRC for the `bitwise` primitive (§8.6),
// calling the SHIPPING SubstrateTypes.BitwiseArithmetic (not glref).
import Foundation
import Harness
import SubstrateTypes

enum Lib_bitwise {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            guard case .string(let aHex) = c.inputs.get("a") ?? .null,
                  case .string(let bHex) = c.inputs.get("b") ?? .null,
                  case .string(let opHex) = c.inputs.get("op") ?? .null,
                  let ab = try? HexCoding.decode(aHex), ab.count == 32,
                  let bb = try? HexCoding.decode(bHex), bb.count == 32,
                  let ob = try? HexCoding.decode(opHex), ob.count == 1 else { continue }
            let a = fpBitwise(ab), b = fpBitwise(bb)
            let r = ob[0] == 0
                ? BitwiseArithmetic.intersect(a, b)
                : BitwiseArithmetic.difference(a, b)
            enc.writeU64(r.block0); enc.writeU64(r.block1)
            enc.writeU64(r.block2); enc.writeU64(r.block3)
        }
        return CRC32.compute(enc.bytes)
    }

    private static func fpBitwise(_ bytes: [UInt8]) -> Fingerprint256 {
        var blk = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var w: UInt64 = 0
            for j in 0..<8 { w |= UInt64(bytes[i * 8 + j]) << (j * 8) }
            blk[i] = w
        }
        return Fingerprint256(block0: blk[0], block1: blk[1], block2: blk[2], block3: blk[3])
    }
}
