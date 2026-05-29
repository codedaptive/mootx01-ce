// PairingHandshakePrimitive.swift
//
// Pairing nonce seed derivation (cookbook § 12.2). Mirror of
// rust/src/primitives/pairing_handshake.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-PairingHandshake.swift
// via the GeniusLocusReference Swift package.
//
// Exercises `PairingNonce.seedWith(estateA, estateB)`, which is
// the cross-estate seed-derivation hot path: both sides of a
// pairing handshake compute the same u64 seed from the shared
// nonce plus the canonical (lower) estate UUID, then expand the
// seed into the shared hyperplane family. Any disagreement on the
// canonical-ordering rule yields incompatible families and silent
// federation corruption.
//
// Case construction hits the dangerous boundary: each case
// includes one UUID pair where lex-string vs raw-byte ordering
// can disagree (a byte transitioning from 0x0F to 0x10 around
// position 0), so the test catches the bug class that motivated
// the byte-compare fix.
//
// Input schema:
//   nonce      : 32-byte hex
//   estate_a   : 16-byte hex
//   estate_b   : 16-byte hex
//
// Output schema:
//   seed : u64 hex (the derived seed)

import Foundation
import GeniusLocusReference

public enum PairingHandshakePrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "pairing_handshake",
        cookbookSection: "§12.2",
        referenceFile: "glref-swift-PairingHandshake.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // 32-byte nonce.
            var nonceBytes = [UInt8](repeating: 0, count: 32)
            for j in 0..<4 {
                let w = rng.next()
                for k in 0..<8 { nonceBytes[j * 8 + k] = UInt8((w >> (k * 8)) & 0xFF) }
            }

            // Two estate UUIDs. Cases cycle through:
            //   shape 0: random vs random
            //   shape 1: forced first-byte tie (compare deeper bytes)
            //   shape 2: cross-the-letter-boundary (byte0 = 0x0F vs 0x10)
            //            — catches the string-vs-byte ordering bug
            //   shape 3: pair that DOES NOT cross the boundary
            let shape = i % 4
            let aBytes: [UInt8]
            let bBytes: [UInt8]
            switch shape {
            case 1:
                var first = randomIDBytes(&rng)
                var second = randomIDBytes(&rng)
                first[0] = 0x42
                second[0] = 0x42
                aBytes = first; bBytes = second
            case 2:
                var first = randomIDBytes(&rng)
                var second = randomIDBytes(&rng)
                first[0]  = 0x0F
                second[0] = 0x10
                aBytes = first; bBytes = second
            case 3:
                var first = randomIDBytes(&rng)
                var second = randomIDBytes(&rng)
                first[0]  = 0x20
                second[0] = 0x30
                aBytes = first; bBytes = second
            default:
                aBytes = randomIDBytes(&rng)
                bBytes = randomIDBytes(&rng)
            }
            let aUUID = uuidFromBytes(aBytes)
            let bUUID = uuidFromBytes(bBytes)

            let nonce = PairingNonce(bytes: nonceBytes)
            let seedVal = nonce.seedWith(estateA: aUUID, estateB: bUUID)

            let inputs = JSONDict([
                ("nonce",    .string(HexCoding.encode(nonceBytes))),
                ("estate_a", .string(HexCoding.encode(aBytes))),
                ("estate_b", .string(HexCoding.encode(bBytes))),
            ])
            let output = JSONDict([
                ("seed", .string(HexCoding.u64(seedVal))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "shape \(shape), seed \(HexCoding.u64(seedVal))",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "pairing_handshake",
            cookbookSection: "§12.2",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-PairingHandshake.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases { caseResults.append(validateCase(c, encoder: &encoder)) }
        let crcActual = CRC32.compute(encoder.bytes)
        let allPassed = caseResults.allSatisfy { $0.passed }
        return ValidationResult(
            passed: allPassed && crcActual == file.outputCrc32,
            caseResults: caseResults,
            crcExpected: file.outputCrc32,
            crcActual: crcActual)
    }

    private static func validateCase(_ c: VectorFile.Case,
                                      encoder: inout CanonicalBinaryEncoder)
                                     -> ValidationResult.CaseResult {
        guard case .string(let nHex) = c.inputs.get("nonce") ?? .null,
              let nBytes = try? HexCoding.decode(nHex),
              nBytes.count == 32 else { return fail(c, "malformed nonce") }
        guard case .string(let aHex) = c.inputs.get("estate_a") ?? .null,
              let aBytes = try? HexCoding.decode(aHex),
              aBytes.count == 16 else { return fail(c, "malformed estate_a") }
        guard case .string(let bHex) = c.inputs.get("estate_b") ?? .null,
              let bBytes = try? HexCoding.decode(bHex),
              bBytes.count == 16 else { return fail(c, "malformed estate_b") }

        let nonce = PairingNonce(bytes: nBytes)
        let aUUID = uuidFromBytes(aBytes)
        let bUUID = uuidFromBytes(bBytes)
        let actual = nonce.seedWith(estateA: aUUID, estateB: bUUID)

        guard case .string(let expHex) = c.expectedOutput.get("seed") ?? .null,
              let expBytes = try? HexCoding.decode(expHex),
              expBytes.count == 8 else { return fail(c, "malformed expected seed") }
        var expected: UInt64 = 0
        for j in 0..<8 { expected |= UInt64(expBytes[j]) << (j * 8) }

        encoder.writeU64(actual)

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "seed mismatch: expected \(HexCoding.u64(expected)), got \(HexCoding.u64(actual))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("seed") ?? .null,
              let bytes = try? HexCoding.decode(s),
              bytes.count == 8 else {
            fatalError("expected_output missing or malformed seed")
        }
        var v: UInt64 = 0
        for j in 0..<8 { v |= UInt64(bytes[j]) << (j * 8) }
        encoder.writeU64(v)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func randomIDBytes(_ rng: inout SplitMix64) -> [UInt8] {
        let lo = rng.next()
        let hi = rng.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for j in 0..<8 { bytes[j]     = UInt8((lo >> (j * 8)) & 0xFF) }
        for j in 0..<8 { bytes[8 + j] = UInt8((hi >> (j * 8)) & 0xFF) }
        return bytes
    }

    private static func uuidFromBytes(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
