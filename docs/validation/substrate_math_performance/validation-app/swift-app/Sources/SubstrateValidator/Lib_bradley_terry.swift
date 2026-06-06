// Lib_bradley_terry.swift
//
// Lib-side conformance CRC for the `bradley_terry` primitive
// (cookbook §8.12). Computes the canonical CRC by calling the SHIPPING
// lib (SubstrateML.BradleyTerryEstimator), not the glref reference, so
// the validator can report lib-vs-glref drift on the post-state theta
// wire encoding.
//
// Byte mechanism mirrors Harness BradleyTerryPrimitive.validateCase
// exactly (its CRC-accumulation path). Per case:
//   1. Decode learning_rate, l2, pre_theta (id+theta pairs), winner_id,
//      losers, and weight.
//   2. Construct a fresh BradleyTerryEstimator seeded with the pre-state
//      theta dictionary, then apply a single PreferenceObservation.
//   3. Sort the population id-bytes ascending (lexCompare), and for each
//      emit `encoder.writeBytes(idBytes)` (16 raw bytes) followed by
//      `encoder.writeF64(theta)` (IEEE-754 bit pattern, LE).
// There is NO u32 length prefix on the per-case post-state — the harness
// writes the 16-byte id then the f64 directly, in id-ascending order.
// CRC32 over the accumulated bytes (all cases concatenated in case order)
// must equal the committed outputCrc32.
//
// Input schema (per case):
//   learning_rate : f64  (16-hex IEEE-754 bit pattern, LE)
//   l2            : f64  (16-hex IEEE-754 bit pattern, LE)
//   pre_theta     : array of {id: 16-byte (32-hex) raw id, theta: f64 16-hex}
//   winner_id     : 16-byte (32-hex) raw id
//   losers        : array of 16-byte (32-hex) raw ids
//   weight        : f64  (16-hex IEEE-754 bit pattern, LE)
//
// All floats here are f64 (8 bytes, 16 hex chars): byte i carries bits
// [i*8, i*8+8) of the bit pattern, decoded LE into a UInt64 and read back
// via Double(bitPattern:). There are no f32 fields in this primitive.
//
// Output (per case, accumulated into the shared encoder):
//   post_theta : for each population id (ascending by raw id bytes),
//                16 raw id bytes then one 8-byte f64 LE (bit pattern).
//                No length prefix.
//
// Id-ordering discipline: the population is the set of ids that appear in
// pre_theta. The harness builds the actual post-state by sorting those
// id-byte arrays ascending (lexicographic over bytes) and reading each
// id's theta out of the post-observation estimator (defaulting to 0.0 if
// absent). This file reproduces that ordering byte-for-byte so the
// floating-point post-state and its serialization are bit-identical to
// the harness and the Rust port.
//
// Determinism: observe() accumulates the winner update across all losers
// against a running winnerNew value, writing each loser back immediately;
// given the same observation it produces bit-identical theta. The map
// (UUID -> Double) lookups do not affect the arithmetic order because the
// loser loop iterates the decoded losers array in JSON order.
//
// Shipping-vs-glref API note: SubstrateML.BradleyTerryEstimator and the
// glref reference are identical here — same struct name, same
// `init(learningRate:l2:theta:)`, same `observe(_:)` taking a
// PreferenceObservation(winnerID:losers:weight:), same `theta` accessor
// ([UUID: Double]), same log-space SGD update (sigmoid gradient with L2
// pull-to-zero). No glref-vs-shipping drift in the type surface; this lib
// path exercises the shipping module so any future divergence surfaces as
// a CRC mismatch. No SubstrateKernel symbols are referenced, so there is
// no kernel/protocol module qualifier ambiguity here.

import Foundation
import Harness
import SubstrateML

enum Lib_bradley_terry {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // --- learning_rate / l2 / weight: 16-hex f64 bit patterns ---
            guard case .string(let lrHex) = c.inputs.get("learning_rate") ?? .null,
                  let lr = btParseF64Hex(lrHex)
            else { continue }
            guard case .string(let l2Hex) = c.inputs.get("l2") ?? .null,
                  let l2 = btParseF64Hex(l2Hex)
            else { continue }
            guard case .string(let wHex) = c.inputs.get("weight") ?? .null,
                  let weight = btParseF64Hex(wHex)
            else { continue }

            // --- pre_theta: [{id: 16-byte raw, theta: f64 hex}] ---
            // Build the seed theta dictionary AND the parallel list of
            // population id-byte arrays (the canonical output ordering is
            // derived from this set, sorted ascending).
            guard case .array(let preArr) = c.inputs.get("pre_theta") ?? .null
            else { continue }
            var thetaInit = [UUID: Double]()
            var idBytesAll = [[UInt8]]()
            var malformed = false
            for v in preArr {
                guard case .dict(let obj) = v,
                      case .string(let idHex) = obj.get("id") ?? .null,
                      let idBytes = try? HexCoding.decode(idHex), idBytes.count == 16,
                      case .string(let tHex) = obj.get("theta") ?? .null,
                      let t = btParseF64Hex(tHex)
                else { malformed = true; break }
                thetaInit[btUUIDFromBytes(idBytes)] = t
                idBytesAll.append(idBytes)
            }
            if malformed { continue }

            // --- winner_id: 16-byte raw id ---
            guard case .string(let winnerHex) = c.inputs.get("winner_id") ?? .null,
                  let winnerBytes = try? HexCoding.decode(winnerHex), winnerBytes.count == 16
            else { continue }

            // --- losers: [16-byte raw id], preserved in JSON order so the
            // observe() loser loop arithmetic matches the harness/Rust port ---
            guard case .array(let losersArr) = c.inputs.get("losers") ?? .null
            else { continue }
            var losers = [UUID]()
            for v in losersArr {
                guard case .string(let s) = v,
                      let lb = try? HexCoding.decode(s), lb.count == 16
                else { malformed = true; break }
                losers.append(btUUIDFromBytes(lb))
            }
            if malformed { continue }
            let winner = btUUIDFromBytes(winnerBytes)

            // Shipping online Bradley-Terry estimator: seed with the
            // pre-state theta, apply one preference observation.
            var est = BradleyTerryEstimator(
                learningRate: lr, l2: l2, theta: thetaInit)
            est.observe(PreferenceObservation(
                winnerID: winner, losers: losers, weight: weight))

            // Canonical encoding: population ids sorted ascending by raw
            // bytes; per id emit 16 raw id bytes then the post-state f64
            // (bit pattern, LE). Default 0.0 for any id absent post-observe.
            // Exactly the harness validateCase accumulation path — no length
            // prefix.
            let sortedIDBytes = idBytesAll.sorted { btLexCompare($0, $1) }
            for bytes in sortedIDBytes {
                let id = btUUIDFromBytes(bytes)
                let t = est.theta[id] ?? 0.0
                enc.writeBytes(bytes)
                enc.writeF64(t)
            }
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Helpers (private, bt-prefixed to avoid cross-file collisions)

    /// Decode an 8-byte little-endian f64 from its hex bit-pattern string.
    /// Mirrors the harness `parseF64Hex`: byte i contributes bits
    /// [i*8, i*8+8) of the IEEE-754 bit pattern.
    private static func btParseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt64(b) << (i * 8)
        }
        return Double(bitPattern: bits)
    }

    /// Build a UUID from 16 raw bytes in wire order. Mirrors the harness
    /// `uuidFromBytes`: byte k maps directly to uuid_t component k, so the
    /// UUID's dictionary identity matches the seed/observation ids.
    private static func btUUIDFromBytes(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    /// Lexicographic byte comparison (ascending), shorter-is-less on a
    /// shared prefix. Mirrors the harness `lexCompare`; for this primitive
    /// all ids are 16 bytes, so this is a straight byte-wise ordering.
    private static func btLexCompare(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }
}
