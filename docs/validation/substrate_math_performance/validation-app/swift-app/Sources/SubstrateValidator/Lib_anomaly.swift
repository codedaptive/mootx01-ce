// Lib_anomaly.swift
//
// Lib-side conformance CRC for the `anomaly` primitive (cookbook
// §8.13) — rolling z-score. Computes the canonical CRC by calling the
// SHIPPING lib SubstrateML.AnomalyDetection.rollingZScore, not the
// glref reference, so the validator can report lib-vs-glref drift on
// anomaly scoring.
//
// Byte mechanism mirrors Harness AnomalyPrimitive.validateCase
// exactly:
//
//   Input schema:
//     current : f32  (8-hex-digit IEEE-754 little-endian bit pattern)
//     window  : array of f32 (each 8-hex-digit LE bit pattern)
//
//   Output schema:
//     z_score : f32
//
// For each case we decode `current` and the `window` array, call the
// shipping rollingZScore, and write the result with a single
// encoder.writeF32 — identical to the harness, which encodes one f32
// per case (the IEEE-754 bit pattern of the z-score) and writes
// nothing for malformed cases (`guard ... else { return }`). f32 is
// written as its 4-byte little-endian IEEE-754 bit pattern by the
// shared CanonicalBinaryEncoder.writeF32, so the lib byte stream is
// directly comparable to the committed glref CRC.

import Foundation
import Harness
import SubstrateML

enum Lib_anomaly {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases { anomalyEncodeCase(c, enc: &enc) }
        return CRC32.compute(enc.bytes)
    }

    /// Decode `window` and `current`, call the shipping
    /// SubstrateML.AnomalyDetection.rollingZScore, and write the
    /// resulting z-score as one f32 (4-byte LE IEEE-754 bit pattern).
    /// Malformed input is skipped without writing, mirroring the
    /// harness `guard ... else { return fail }` (failed cases write no
    /// canonical bytes).
    private static func anomalyEncodeCase(_ c: VectorFile.Case,
                                          enc: inout CanonicalBinaryEncoder) {
        guard case .array(let wArr) = c.inputs.get("window") ?? .null else { return }
        var window = [Float32]()
        window.reserveCapacity(wArr.count)
        for v in wArr {
            guard case .string(let s) = v,
                  let f = anomalyParseF32Hex(s) else { return }
            window.append(f)
        }
        guard case .string(let cs) = c.inputs.get("current") ?? .null,
              let current = anomalyParseF32Hex(cs) else { return }

        // Shipping API:
        //   SubstrateML.AnomalyDetection.rollingZScore(window:current:)
        //     -> Float32
        // Same function/signature as the glref reference the harness
        // calls; the only difference is the module it resolves from.
        let z = AnomalyDetection.rollingZScore(window: window, current: current)
        enc.writeF32(z)
    }

    /// Decode an 8-char little-endian hex string into a Float32 by its
    /// IEEE-754 bit pattern. Mirrors the harness `parseF32Hex`: 4
    /// bytes, byte i contributes bits [i*8, i*8+8). Returns nil on
    /// wrong length / malformed hex.
    private static func anomalyParseF32Hex(_ s: String) -> Float32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var bits: UInt32 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt32(b) << (i * 8)
        }
        return Float32(bitPattern: bits)
    }
}
