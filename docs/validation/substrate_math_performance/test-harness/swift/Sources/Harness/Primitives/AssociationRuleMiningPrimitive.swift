// AssociationRuleMiningPrimitive.swift
//
// Validation primitive for AssociationRuleMining (cookbook § 6.3).
// Validator-only: vectors are hand-crafted by the Rust harness generator;
// the Swift side only validates existing association_rule_mining.json.
// Mirrors rust/src/primitives/association_rule_mining.rs case-for-case.
//
// Input schema per case:
//   entries           : array of { field_i, field_j, value_i, value_j: u8-hex,
//                                  count: i64 LE-hex }
//   active_row_count  : i64 LE-hex
//   min_support       : f64 LE-hex
//   min_confidence    : f64 LE-hex
//
// Output schema per case:
//   rules : array of {
//     antecedent_field, antecedent_value,
//     consequent_field, consequent_value : u8-hex
//     support, confidence, lift, leverage, conviction : f64 LE-hex
//   }
//
// Canonical binary encoding:
//   u64  rule_count
//   per rule:
//     u8  antecedent_field
//     u8  antecedent_value
//     u8  consequent_field
//     u8  consequent_value
//     f64 support
//     f64 confidence
//     f64 lift
//     f64 leverage
//     f64 conviction

import Foundation
import SubstrateML
import SubstrateTypes

public enum AssociationRuleMiningPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "association_rule_mining",
        cookbookSection: "§6.3",
        referenceFile: "SubstrateML/Sources/SubstrateML/AssociationRuleMining.swift",
        generate: generate,
        validate: validate
    )

    /// Vectors are hand-crafted by the Rust harness generator; Swift
    /// does not regenerate them. Throw so the caller skips generation.
    public static func generate(seed: UInt64) throws -> VectorFile {
        throw HarnessError.generatorNotAvailable(
            "association_rule_mining vectors are hand-crafted; " +
            "read association_rule_mining.json from vectors/")
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases {
            caseResults.append(validateCase(c, encoder: &encoder))
        }
        let crcActual = CRC32.compute(encoder.bytes)
        let allPassed = caseResults.allSatisfy { $0.passed }
        return ValidationResult(
            passed: allPassed && crcActual == file.outputCrc32,
            caseResults: caseResults,
            crcExpected: file.outputCrc32,
            crcActual: crcActual)
    }

    private static func validateCase(
        _ c: VectorFile.Case,
        encoder: inout CanonicalBinaryEncoder
    ) -> ValidationResult.CaseResult {

        // Build MatrixO from entries array.
        var matrix = MatrixO()
        if case .array(let entries) = c.inputs.get("entries") ?? .null {
            for entry in entries {
                guard case .dict(let e) = entry else { continue }
                let fi = parseU8(e.get("field_i"))
                let vi = parseU8(e.get("value_i"))
                let fj = parseU8(e.get("field_j"))
                let vj = parseU8(e.get("value_j"))
                let count = parseI64(e.get("count"))
                let key = CooccurrenceKey(fieldI: fi, valueI: vi, fieldJ: fj, valueJ: vj)
                matrix.increment(key, by: count)
            }
        }

        let activeRowCount = parseI64(c.inputs.get("active_row_count"))
        let minSupport = parseF64(c.inputs.get("min_support"))
        let minConfidence = parseF64(c.inputs.get("min_confidence"))

        let thresholds = MiningThresholds(minSupport: minSupport,
                                          minConfidence: minConfidence)
        let actualRules = mineAssociationRules(
            matrix: matrix,
            activeRowCount: activeRowCount,
            thresholds: thresholds)

        // Parse expected rules.
        let expectedRules = parseRules(c.expectedOutput)

        // Encode actual output.
        encoder.writeU64(UInt64(actualRules.count))
        for r in actualRules {
            encoder.writeU8(r.antecedent.field)
            encoder.writeU8(r.antecedent.value)
            encoder.writeU8(r.consequent.field)
            encoder.writeU8(r.consequent.value)
            encoder.writeF64(r.support)
            encoder.writeF64(r.confidence)
            encoder.writeF64(r.lift)
            encoder.writeF64(r.leverage)
            encoder.writeF64(r.conviction)
        }

        // Compare actual to expected.
        let passed = actualRules.count == expectedRules.count
            && zip(actualRules, expectedRules).allSatisfy { (a, e) in
                a.antecedent.field == e.antecedentField
                && a.antecedent.value == e.antecedentValue
                && a.consequent.field == e.consequentField
                && a.consequent.value == e.consequentValue
                && a.support.bitPattern == e.support.bitPattern
                && a.confidence.bitPattern == e.confidence.bitPattern
                && a.lift.bitPattern == e.lift.bitPattern
                && a.leverage.bitPattern == e.leverage.bitPattern
                && a.conviction.bitPattern == e.conviction.bitPattern
            }

        let diagnostic: String? = passed ? nil :
            "expected \(expectedRules.count) rules, got \(actualRules.count)"

        return ValidationResult.CaseResult(id: c.id, passed: passed,
                                           diagnostic: diagnostic)
    }

    // MARK: - Expected rule shape

    private struct ExpectedRule {
        let antecedentField: UInt8
        let antecedentValue: UInt8
        let consequentField: UInt8
        let consequentValue: UInt8
        let support: Double
        let confidence: Double
        let lift: Double
        let leverage: Double
        let conviction: Double
    }

    private static func parseRules(_ output: JSONDict) -> [ExpectedRule] {
        guard case .array(let arr) = output.get("rules") ?? .null else {
            return []
        }
        return arr.compactMap { v -> ExpectedRule? in
            guard case .dict(let r) = v else { return nil }
            return ExpectedRule(
                antecedentField: parseU8(r.get("antecedent_field")),
                antecedentValue: parseU8(r.get("antecedent_value")),
                consequentField: parseU8(r.get("consequent_field")),
                consequentValue: parseU8(r.get("consequent_value")),
                support: parseF64(r.get("support")),
                confidence: parseF64(r.get("confidence")),
                lift: parseF64(r.get("lift")),
                leverage: parseF64(r.get("leverage")),
                conviction: parseF64(r.get("conviction"))
            )
        }
    }

    // MARK: - Hex decode helpers

    /// Decode a 1-byte hex string to UInt8. Returns 0 on failure.
    private static func parseU8(_ v: JSONValue?) -> UInt8 {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s),
              !bytes.isEmpty else { return 0 }
        return bytes[0]
    }

    /// Decode an 8-byte LE-hex string to Int64. Returns 0 on failure.
    private static func parseI64(_ v: JSONValue?) -> Int64 {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s),
              bytes.count == 8 else { return 0 }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Int64(bitPattern: bits)
    }

    /// Decode an 8-byte LE-hex string to Double (IEEE-754 bits). Returns 0.0 on failure.
    private static func parseF64(_ v: JSONValue?) -> Double {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s),
              bytes.count == 8 else { return 0.0 }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Double(bitPattern: bits)
    }
}

/// Harness-internal error type for generation-not-available cases.
/// Defined here and shared; formal_concept_analysis uses the same type.
enum HarnessError: Error {
    case generatorNotAvailable(String)
}
