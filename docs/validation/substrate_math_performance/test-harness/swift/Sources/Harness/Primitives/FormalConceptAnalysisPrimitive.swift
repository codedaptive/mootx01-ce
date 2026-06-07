// FormalConceptAnalysisPrimitive.swift
//
// Validation primitive for FormalConceptAnalysis (cookbook § 8, pure engine).
// Validator-only: vectors are hand-crafted by the Rust harness generator;
// the Swift side only validates existing formal_concept_analysis.json.
// Mirrors rust/src/primitives/formal_concept_analysis.rs case-for-case.
//
// Input schema per case:
//   rows            : array of arrays of attribute objects
//                     { namespace: string, key: string, value: string }
//   min_support     : integer
//   max_intent_size : integer
//   max_concepts    : integer
//
// Output schema per case:
//   concepts : array of {
//     extent  : [u32 JSON integer]  — sorted row indices ascending
//     intent  : [{ namespace, key, value }]  — sorted attributes ascending
//     support : integer
//   }
//   (stability is always None in v1 and is not encoded)
//
// Canonical binary encoding:
//   u64  concept_count
//   per concept:
//     u64  extent_len; per row: u32 row_id
//     u64  intent_len; per attr: string(namespace) string(key) string(value)
//     u64  support
//     u8   stability_tag = 0  (None, always in v1)

import Foundation
import SubstrateML

public enum FormalConceptAnalysisPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "formal_concept_analysis",
        cookbookSection: "§8 (pure engine)",
        referenceFile: "SubstrateML/Sources/SubstrateML/FormalConceptAnalysis.swift",
        generate: generate,
        validate: validate
    )

    /// Vectors are hand-crafted by the Rust harness generator; Swift
    /// does not regenerate them. Throw so the caller skips generation.
    public static func generate(seed: UInt64) throws -> VectorFile {
        throw HarnessError.generatorNotAvailable(
            "formal_concept_analysis vectors are hand-crafted; " +
            "read formal_concept_analysis.json from vectors/")
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

        // Parse rows: array of arrays of attribute objects.
        var rows = [[FormalAttribute]]()
        if case .array(let jsonRows) = c.inputs.get("rows") ?? .null {
            for jsonRow in jsonRows {
                var attrs = [FormalAttribute]()
                if case .array(let jsonAttrs) = jsonRow {
                    for jsonAttr in jsonAttrs {
                        guard case .dict(let obj) = jsonAttr,
                              case .string(let ns) = obj.get("namespace") ?? .null,
                              case .string(let k) = obj.get("key") ?? .null,
                              case .string(let v) = obj.get("value") ?? .null
                        else { continue }
                        attrs.append(FormalAttribute(namespace: ns, key: k, value: v))
                    }
                }
                rows.append(attrs)
            }
        }

        let minSupport = parseInt(c.inputs.get("min_support"))
        let maxIntentSize = parseInt(c.inputs.get("max_intent_size"))
        let maxConcepts = parseInt(c.inputs.get("max_concepts"))

        let context = FormalContext(rows: rows)
        let miner = BoundedConceptMiner(
            minSupport: minSupport,
            maxIntentSize: maxIntentSize,
            maxConcepts: maxConcepts)
        let actualConcepts = miner.mine(context: context)

        // Parse expected concepts.
        let expectedConcepts = parseExpectedConcepts(c.expectedOutput)

        // Encode actual output into CRC.
        // Encoding: u64 count; per concept: u64 extent_len, u32 row ids,
        // u64 intent_len, strings per attr, u64 support, u8 stability_tag=0.
        encoder.writeU64(UInt64(actualConcepts.count))
        for concept in actualConcepts {
            encoder.writeU64(UInt64(concept.extent.count))
            for rowID in concept.extent {
                encoder.writeU32(rowID)
            }
            encoder.writeU64(UInt64(concept.intent.count))
            for attr in concept.intent {
                encoder.writeString(attr.namespace)
                encoder.writeString(attr.key)
                encoder.writeString(attr.value)
            }
            encoder.writeU64(UInt64(concept.support))
            // stability is always None in v1 — encode tag byte 0
            encoder.writeU8(0)
        }

        // Compare actual to expected.
        let passed = actualConcepts.count == expectedConcepts.count
            && zip(actualConcepts, expectedConcepts).allSatisfy { (a, e) in
                a.extent == e.extent
                && a.intent == e.intent
                && a.support == e.support
            }

        let diagnostic: String? = passed ? nil :
            "expected \(expectedConcepts.count) concepts, got \(actualConcepts.count)"

        return ValidationResult.CaseResult(id: c.id, passed: passed,
                                           diagnostic: diagnostic)
    }

    // MARK: - Expected concept shape

    private struct ExpectedConcept {
        let extent: [FormalContext.RowID]
        let intent: [FormalAttribute]
        let support: Int
    }

    private static func parseExpectedConcepts(_ output: JSONDict) -> [ExpectedConcept] {
        guard case .array(let arr) = output.get("concepts") ?? .null else {
            return []
        }
        return arr.compactMap { v -> ExpectedConcept? in
            guard case .dict(let obj) = v else { return nil }
            // extent: array of JSON integers
            var extent = [FormalContext.RowID]()
            if case .array(let extArr) = obj.get("extent") ?? .null {
                for item in extArr {
                    if case .integer(let n) = item {
                        extent.append(FormalContext.RowID(n))
                    }
                }
            }
            // intent: array of attribute objects
            var intent = [FormalAttribute]()
            if case .array(let intentArr) = obj.get("intent") ?? .null {
                for item in intentArr {
                    guard case .dict(let attrObj) = item,
                          case .string(let ns) = attrObj.get("namespace") ?? .null,
                          case .string(let k) = attrObj.get("key") ?? .null,
                          case .string(let v2) = attrObj.get("value") ?? .null
                    else { continue }
                    intent.append(FormalAttribute(namespace: ns, key: k, value: v2))
                }
            }
            let support = parseInt(obj.get("support"))
            return ExpectedConcept(extent: extent, intent: intent, support: support)
        }
    }

    // MARK: - Helpers

    /// Parse a plain JSON integer value. Returns 0 on failure.
    private static func parseInt(_ v: JSONValue?) -> Int {
        guard case .integer(let n)? = v else { return 0 }
        return Int(n)
    }
}
