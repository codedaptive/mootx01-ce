// HLCPrimitive.swift
//
// HLC ordering (cookbook § 5.2). Mirror of
// rust/src/primitives/hlc.rs. Validates the lexicographic
// comparison (physicalTime, logicalCount, nodeID) shared by Swift
// and Rust ports.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-HLC.swift
// via the GeniusLocusReference Swift package.
//
// Input schema:
//   a : HLC wire bytes (32-char hex, 16 bytes LE: 8 phys + 4 log + 4 node)
//   b : HLC wire bytes
//
// Output schema:
//   ordering : i8 (-1 if a < b, 0 if a == b, +1 if a > b)

import Foundation
import GeniusLocusReference

public enum HLCPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "hlc",
        cookbookSection: "§5.2",
        referenceFile: "glref-swift-HLC.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Three case shapes cycled:
            //   shape 0: random vs random (most likely a != b)
            //   shape 1: a == b exactly (equality boundary)
            //   shape 2: a differs from b only in nodeID (tertiary tiebreak)
            let shape = i % 3
            let a = randomHLC(&rng)
            let b: HLC
            switch shape {
            case 1:
                b = a
            case 2:
                let aNode = a.nodeID
                let newNode = aNode == Int32.max ? aNode - 1 : aNode + 1
                b = HLC(physicalTime: a.physicalTime,
                        logicalCount: a.logicalCount,
                        nodeID: newNode)
            default:
                b = randomHLC(&rng)
            }

            let ordering: Int8
            if a < b { ordering = -1 }
            else if b < a { ordering = 1 }
            else { ordering = 0 }

            let inputs = JSONDict([
                ("a", .string(HexCoding.encode(a.wireBytes))),
                ("b", .string(HexCoding.encode(b.wireBytes))),
            ])
            let output = JSONDict([
                ("ordering", .integer(Int64(ordering))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "shape \(shape), ordering \(ordering)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "hlc",
            cookbookSection: "§5.2",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-HLC.swift"),
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
        guard case .string(let aHex) = c.inputs.get("a") ?? .null,
              let a = parseHLC(aHex) else { return fail(c, "missing or malformed a") }
        guard case .string(let bHex) = c.inputs.get("b") ?? .null,
              let b = parseHLC(bHex) else { return fail(c, "missing or malformed b") }

        let actual: Int8
        if a < b { actual = -1 }
        else if b < a { actual = 1 }
        else { actual = 0 }

        guard case .integer(let expectedRaw) = c.expectedOutput.get("ordering") ?? .null else {
            return fail(c, "missing expected ordering")
        }
        let expected = Int8(expectedRaw)

        encoder.writeI8(actual)

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "ordering mismatch: expected \(expected), got \(actual)")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .integer(let raw) = output.get("ordering") ?? .null else {
            fatalError("expected_output missing ordering")
        }
        encoder.writeI8(Int8(raw))
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    /// Build an HLC whose components span the wire format's range
    /// in a way both languages reproduce bit-identically.
    private static func randomHLC(_ rng: inout SplitMix64) -> HLC {
        let physRaw = rng.next()
        let logRaw  = rng.next()
        let nodeRaw = rng.next()
        // Keep physicalTime non-negative and bounded so equality
        // cases remain reachable; logicalCount and nodeID likewise.
        let physicalTime = Int64(physRaw & 0x0000_FFFF_FFFF_FFFF)
        let logicalCount = Int32(logRaw & 0x0000_FFFF)
        let nodeID       = Int32(nodeRaw & 0x0000_00FF)
        return HLC(physicalTime: physicalTime,
                   logicalCount: logicalCount,
                   nodeID: nodeID)
    }

    private static func parseHLC(_ s: String) -> HLC? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 16 else { return nil }
        var phys: Int64 = 0
        for i in 0..<8 { phys |= Int64(bytes[i]) << (i * 8) }
        var log: Int32 = 0
        for i in 0..<4 { log  |= Int32(bytes[8 + i]) << (i * 8) }
        var node: Int32 = 0
        for i in 0..<4 { node |= Int32(bytes[12 + i]) << (i * 8) }
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }
}
