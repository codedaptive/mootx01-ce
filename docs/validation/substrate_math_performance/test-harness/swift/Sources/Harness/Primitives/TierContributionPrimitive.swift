// TierContributionPrimitive.swift
//
// Tier contribution fingerprint (cookbook § 12.3). Mirror of
// rust/src/primitives/tier_contribution.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-TierContributionFingerprint.swift
// via the GeniusLocusReference Swift package.
//
// Each case:
//   1. Build a TierContribution from a list of shareable
//      fingerprints, an estate UUID, a FederationCase, and an HLC.
//   2. Encode it to the 64-byte canonical wire format.
//   3. Decode and verify roundtrip.
//
// Both ports must produce the same 64-byte wire output and the
// same TierContribution struct from build().
//
// Input schema:
//   estate_uuid    : 16-byte hex
//   federation_case: u32 (1=household, 2=fleet, 3=industry)
//   hlc_packed     : 8-byte hex (u64 BE)
//   shareable      : array of 32-byte Fingerprint256 hex
//
// Output schema:
//   wire_bytes : 64-byte hex (canonical encode output)
//   row_count  : u32 hex
//   aggregate  : 32-byte hex (BE block order)

import Foundation
import GeniusLocusReference

public enum TierContributionPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "tier_contribution",
        cookbookSection: "§12.3",
        referenceFile: "glref-swift-TierContributionFingerprint.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let estateBytes = randomUUIDBytes(&rng)
            let federationCaseRaw: UInt32 = UInt32(1 + (i % 3))
            let federationCase = FederationCase(rawValue: federationCaseRaw) ?? .household
            let hlcPacked = rng.next()
            let hlc = HLC(packed: hlcPacked)

            // Build cohort of 0..7 shareable fingerprints.
            let cohortSize = i % 8
            var cohort = [Fingerprint256]()
            for _ in 0..<cohortSize {
                cohort.append(Fingerprint256(
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next()))
            }

            let estateUUID = uuidFromBytes(estateBytes)
            let contrib = TierContributionFingerprint.build(
                estateUUID: estateUUID,
                case: federationCase,
                shareableFingerprints: cohort,
                hlc: hlc)

            let wireData = TierContributionFingerprint.encode(contrib)
            let wireBytes = [UInt8](wireData)

            let cohortArr: JSONValue = .array(cohort.map { .string(encodeFingerprintLE($0)) })
            let inputs = JSONDict([
                ("estate_uuid",     .string(HexCoding.encode(estateBytes))),
                ("federation_case", .string(HexCoding.u32(federationCaseRaw))),
                ("hlc_packed",      .string(HexCoding.u64(hlcPacked))),
                ("shareable",       cohortArr),
            ])
            let output = JSONDict([
                ("wire_bytes", .string(HexCoding.encode(wireBytes))),
                ("row_count",  .string(HexCoding.u32(contrib.rowCount))),
                ("aggregate",  .string(encodeFingerprintLE(contrib.aggregate))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "case=\(federationCaseRaw), |cohort|=\(cohortSize)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "tier_contribution",
            cookbookSection: "§12.3",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-TierContributionFingerprint.swift"),
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
        guard case .string(let estHex) = c.inputs.get("estate_uuid") ?? .null,
              let estBytes = try? HexCoding.decode(estHex),
              estBytes.count == 16 else { return fail(c, "malformed estate_uuid") }
        guard case .string(let fcHex) = c.inputs.get("federation_case") ?? .null,
              let fcBytes = try? HexCoding.decode(fcHex),
              fcBytes.count == 4 else { return fail(c, "malformed federation_case") }
        var fcRaw: UInt32 = 0
        for j in 0..<4 { fcRaw |= UInt32(fcBytes[j]) << (j * 8) }
        guard let fc = FederationCase(rawValue: fcRaw) else { return fail(c, "unknown federation_case") }
        guard case .string(let hlcHex) = c.inputs.get("hlc_packed") ?? .null,
              let hlcBytes = try? HexCoding.decode(hlcHex),
              hlcBytes.count == 8 else { return fail(c, "malformed hlc_packed") }
        var hlcPacked: UInt64 = 0
        for j in 0..<8 { hlcPacked |= UInt64(hlcBytes[j]) << (j * 8) }
        let hlc = HLC(packed: hlcPacked)

        guard case .array(let cohortArr) = c.inputs.get("shareable") ?? .null else {
            return fail(c, "missing shareable")
        }
        var cohort = [Fingerprint256]()
        for v in cohortArr {
            guard case .string(let s) = v,
                  let fp = parseFingerprintLE(s) else {
                return fail(c, "malformed shareable element")
            }
            cohort.append(fp)
        }

        let estateUUID = uuidFromBytes(estBytes)
        let contrib = TierContributionFingerprint.build(
            estateUUID: estateUUID,
            case: fc,
            shareableFingerprints: cohort,
            hlc: hlc)
        let actualWire = [UInt8](TierContributionFingerprint.encode(contrib))

        guard case .string(let expWireHex) = c.expectedOutput.get("wire_bytes") ?? .null,
              let expectedWire = try? HexCoding.decode(expWireHex),
              expectedWire.count == 64 else {
            return fail(c, "missing or malformed expected wire_bytes")
        }

        // Roundtrip check: decode and verify
        guard let roundtripped = TierContributionFingerprint.decode(Data(actualWire)),
              roundtripped.estateUUID == contrib.estateUUID,
              roundtripped.federationCase == contrib.federationCase,
              roundtripped.rowCount == contrib.rowCount,
              roundtripped.aggregate == contrib.aggregate else {
            return fail(c, "decode roundtrip failed")
        }

        encoder.writeBytes(actualWire)

        if actualWire == expectedWire {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "wire_bytes mismatch")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("wire_bytes") ?? .null,
              let bytes = try? HexCoding.decode(s),
              bytes.count == 64 else {
            fatalError("expected_output missing or malformed wire_bytes")
        }
        encoder.writeBytes(bytes)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func randomUUIDBytes(_ rng: inout SplitMix64) -> [UInt8] {
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

    /// Encode Fingerprint256 as 32-byte LE hex (the harness's
    /// canonical fingerprint encoding).
    private static func encodeFingerprintLE(_ fp: Fingerprint256) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let blocks = [fp.block0, fp.block1, fp.block2, fp.block3]
        for (i, w) in blocks.enumerated() {
            for j in 0..<8 { bytes[i * 8 + j] = UInt8((w >> (j * 8)) & 0xFF) }
        }
        return HexCoding.encode(bytes)
    }

    private static func parseFingerprintLE(_ s: String) -> Fingerprint256? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 32 else { return nil }
        var blocks = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var w: UInt64 = 0
            for j in 0..<8 { w |= UInt64(bytes[i * 8 + j]) << (j * 8) }
            blocks[i] = w
        }
        return Fingerprint256(block0: blocks[0], block1: blocks[1],
                              block2: blocks[2], block3: blocks[3])
    }
}
