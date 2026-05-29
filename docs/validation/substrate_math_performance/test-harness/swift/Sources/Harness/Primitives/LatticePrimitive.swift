// LatticePrimitive.swift
//
// UDC tree distance (cookbook § 8.3) - the UDC component of
// lattice distance. Mirror of rust/src/primitives/lattice.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-LatticeDistance.swift
// via the GeniusLocusReference Swift package.
//
// The full LatticeDistance API also covers Wikidata graph
// distance (requires an adjacency provider) and the composite
// lattice distance. This primitive exercises the pure UDC tree
// component, which is the most-used path in the substrate's
// recall-by-place primitive.
//
// Input schema:
//   a : UDC string (synthetic, generated from the RNG)
//   b : UDC string
//
// Output schema:
//   distance : f64

import Foundation
import GeniusLocusReference

public enum LatticePrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "lattice",
        cookbookSection: "§8.3",
        referenceFile: "glref-swift-LatticeDistance.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Build two UDC strings: shared prefix of varying
            // length, then divergent suffixes. Cases cycle through
            // (identical strings, partial overlap, fully disjoint).
            let shape = i % 4
            let (a, b) = synthUDCPair(&rng, shape: shape)
            let dist = UDCTreeDistance.distance(a, b)

            let inputs = JSONDict([
                ("a", .string(a)),
                ("b", .string(b)),
            ])
            let output = JSONDict([
                ("distance", .string(HexCoding.f64(dist))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "shape \(shape), a=\"\(a)\", b=\"\(b)\", d=\(dist)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "lattice",
            cookbookSection: "§8.3",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-LatticeDistance.swift"),
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
        guard case .string(let a) = c.inputs.get("a") ?? .null else {
            return fail(c, "missing a")
        }
        guard case .string(let b) = c.inputs.get("b") ?? .null else {
            return fail(c, "missing b")
        }

        let actual = UDCTreeDistance.distance(a, b)

        guard case .string(let expHex) = c.expectedOutput.get("distance") ?? .null,
              let expected = parseF64Hex(expHex) else {
            return fail(c, "missing or malformed expected distance")
        }

        encoder.writeF64(actual)

        if actual.bitPattern == expected.bitPattern {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "distance mismatch: expected \(HexCoding.f64(expected)), got \(HexCoding.f64(actual))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("distance") ?? .null,
              let f = parseF64Hex(s) else {
            fatalError("expected_output missing or malformed distance")
        }
        encoder.writeF64(f)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Double(bitPattern: bits)
    }

    /// Generate a pair of synthetic UDC strings deterministically
    /// from the RNG. UDC strings are dotted decimal: "1.2.3.4".
    /// Each component is in [1, 9] so the strings stay readable.
    /// Both languages must produce the same strings from the same
    /// RNG state, so the construction uses only operations that
    /// agree bit-identically between Swift and Rust.
    private static func synthUDCPair(_ rng: inout SplitMix64, shape: Int) -> (String, String) {
        let aLen = 2 + Int(rng.next() % 4)
        var aComponents = [String]()
        for _ in 0..<aLen {
            aComponents.append(String(1 + (rng.next() % 9)))
        }
        let a = aComponents.joined(separator: ".")

        let b: String
        switch shape {
        case 0:
            // Identical
            b = a
        case 1:
            // Sibling: share all but last component
            var bComponents = aComponents
            bComponents[aLen - 1] = String(1 + (rng.next() % 9))
            b = bComponents.joined(separator: ".")
        case 2:
            // Ancestor: trim last component(s)
            let trimTo = max(1, aLen - 1 - Int(rng.next() % 2))
            b = aComponents.prefix(trimTo).joined(separator: ".")
        default:
            // Disjoint: build from scratch
            let bLen = 2 + Int(rng.next() % 4)
            var bComponents = [String]()
            for _ in 0..<bLen {
                bComponents.append(String(1 + (rng.next() % 9)))
            }
            // Force first component to differ so trees are disjoint
            bComponents[0] = String(1 + ((rng.next() + 5) % 9))
            b = bComponents.joined(separator: ".")
        }
        return (a, b)
    }
}
