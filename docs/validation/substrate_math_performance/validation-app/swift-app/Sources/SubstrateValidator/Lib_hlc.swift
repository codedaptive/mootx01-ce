// Lib_hlc.swift
//
// Conformance CRC for the `hlc` primitive computed against the
// SHIPPING substrate library (SubstrateTypes.HLC), not the glref
// reference. Used to confirm the shipping HLC ordering produces
// the exact same conformance byte stream the harness produces.
//
// Input schema (mirrors HLCPrimitive.validate):
//   a : 32-char hex, 16 bytes LE wire form (8 phys + 4 log + 4 node)
//   b : same
//
// Output encoding (mirrors HLCPrimitive.validateCase byte-for-byte):
//   per case the lexicographic ordering of a vs b is written as a
//   single i8 (-1 if a < b, 0 if a == b, +1 if a > b) via
//   CanonicalBinaryEncoder.writeI8. The concatenated stream over all
//   cases is CRC32'd to yield the conformance value.
//
// The shipping HLC's Comparable conformance (lexicographic on
// physicalTime, logicalCount, nodeID) and its throwing
// `init(wireBytes:)` decoder (16-byte LE, validates length) are the
// substrate symbols under test here.

import Foundation
import Harness
import SubstrateTypes

enum Lib_hlc {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // Decode the two 16-byte wire HLCs from their hex inputs.
            guard case .string(let aHex) = c.inputs.get("a") ?? .null,
                  case .string(let bHex) = c.inputs.get("b") ?? .null,
                  let ab = try? HexCoding.decode(aHex),
                  let bb = try? HexCoding.decode(bHex),
                  // Shipping decoder: validates 16-byte length, LE layout.
                  let a = try? HLC(wireBytes: ab),
                  let b = try? HLC(wireBytes: bb) else { continue }

            // Shipping Comparable: lexicographic (phys, logical, node).
            let ordering: Int8
            if a < b { ordering = -1 }
            else if b < a { ordering = 1 }
            else { ordering = 0 }

            // Same i8 encoding the harness emits per case.
            enc.writeI8(ordering)
        }
        return CRC32.compute(enc.bytes)
    }
}
