// ConformanceTests.swift
// Oracle-vector conformance tests for ContextDistillLib.
//
// TDD flow (Part 1):
//   1. Write these tests first.
//   2. They fail (no Sources exist yet).
//   3. Port ContextShape.classify — tests go green.
//
// The shape tests compare canonical JSON (sorted keys, no whitespace) of
// ContextShape.classify(original).asDict() against the oracle vector's "shape"
// field.  Both sides go through JSONSerialization so Foundation's NSNumber
// encoding is consistent.
//
// The full-row conformance test (Part 5) compares every expected-output field
// in the oracle row against ContextDistiller.distill(_:converter:) output.
// Excluded fields: drawer_id, event_time, original, candidate, enrichment_trailer.

import Foundation
import Testing
@testable import ContextDistillLib

// MARK: - Helpers

/// Asserts that classifying `row.original` produces a shape equal to `row.shape`
/// under canonical-JSON comparison.  A mismatch prints the drawer_id for triage.
private func assertShapeMatch(_ row: OracleRow) throws {
    let actual = ContextShape.classify(row.original)
    let actualStr  = try canonicalJSON(actual.asDict())
    let expectedStr = try canonicalJSON(row.shape)
    #expect(
        actualStr == expectedStr,
        "Shape mismatch for drawer \(row.drawerID):\n  expected: \(expectedStr)\n  actual:   \(actualStr)"
    )
}

/// Fields excluded from the full-row conformance comparison.
/// These are record-identity or input fields, not converter output.
private let rowExcludedKeys: Set<String> = [
    "drawer_id", "event_time", "original", "candidate", "enrichment_trailer"
]

/// Strips excluded keys from `dict` and serialises the remainder as canonical JSON.
private func canonicalOutputJSON(_ dict: [String: Any]) throws -> String {
    var filtered = dict
    for key in rowExcludedKeys { filtered.removeValue(forKey: key) }
    let data = try JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
    guard let str = String(data: data, encoding: .utf8) else {
        throw JSONError.encoding
    }
    return str
}

private enum JSONError: Error { case encoding }

/// Asserts that the ContextDistiller output for `row` matches the oracle row's
/// expected output fields under canonical-JSON comparison.
private func assertFullRowMatch(
    _ row: OracleRow,
    distiller: ContextDistiller
) throws {
    let input = DistillationInput(original: row.original,
                                  enrichmentTrailer: row.enrichmentTrailer)
    let result = distiller.distill(input, converter: .intentSpanV22)

    let portDict = result.asDict()
    let oracleDict = row.rawJSON

    let portJSON   = try canonicalOutputJSON(portDict)
    let oracleJSON = try canonicalOutputJSON(oracleDict)

    #expect(
        portJSON == oracleJSON,
        "Full-row mismatch for drawer \(row.drawerID)"
    )
}

// MARK: - Shape conformance (509 rows, four beds)

/// Runs shape conformance on all 7 debug7 rows.
@Test("Shape conformance — debug7 (7 rows)")
func shapeConformance_debug7() throws {
    let rows = loadOracleRows(bed: "debug7")
    for row in rows {
        try assertShapeMatch(row)
    }
}

/// Runs shape conformance on all 30 sample30 rows.
@Test("Shape conformance — sample30 (30 rows)")
func shapeConformance_sample30() throws {
    let rows = loadOracleRows(bed: "sample30")
    for row in rows {
        try assertShapeMatch(row)
    }
}

/// Runs shape conformance on all 272 locomo rows.
@Test("Shape conformance — locomo (272 rows)")
func shapeConformance_locomo() throws {
    let rows = loadOracleRows(bed: "locomo")
    for row in rows {
        try assertShapeMatch(row)
    }
}

/// Runs shape conformance on all 200 blind200 rows.
@Test("Shape conformance — blind200 (200 rows)")
func shapeConformance_blind200() throws {
    let rows = loadOracleRows(bed: "blind200")
    for row in rows {
        try assertShapeMatch(row)
    }
}

// MARK: - Full-row conformance (Part 5 — 509 rows, four beds)

/// Full-row conformance: ContextDistiller output matches every oracle field
/// (excluding record-identity and input-only keys) for all 7 debug7 rows.
@Test("Full-row conformance — debug7 (7 rows)")
func fullRowConformance_debug7() throws {
    let distiller = ContextDistiller()
    let rows = loadOracleRows(bed: "debug7")
    for row in rows {
        try assertFullRowMatch(row, distiller: distiller)
    }
}

/// Full-row conformance for all 30 sample30 rows.
@Test("Full-row conformance — sample30 (30 rows)")
func fullRowConformance_sample30() throws {
    let distiller = ContextDistiller()
    let rows = loadOracleRows(bed: "sample30")
    for row in rows {
        try assertFullRowMatch(row, distiller: distiller)
    }
}

/// Full-row conformance for all 272 locomo rows.
@Test("Full-row conformance — locomo (272 rows)")
func fullRowConformance_locomo() throws {
    let distiller = ContextDistiller()
    let rows = loadOracleRows(bed: "locomo")
    for row in rows {
        try assertFullRowMatch(row, distiller: distiller)
    }
}

/// Full-row conformance for all 200 blind200 rows.
@Test("Full-row conformance — blind200 (200 rows)")
func fullRowConformance_blind200() throws {
    let distiller = ContextDistiller()
    let rows = loadOracleRows(bed: "blind200")
    for row in rows {
        try assertFullRowMatch(row, distiller: distiller)
    }
}

// MARK: - Cross-port fixture (Part 5)

/// Writes all 509 Swift port output rows to the cross-port fixture file.
///
/// The fixture path comes from the environment variable CDL_CROSSPORT_OUT.
/// When the variable is not set this test is skipped — it is a helper for the
/// cross-port diff, not a conformance gate.
///
/// Output format: one JSON object per line (JSONL), 509 lines, one per oracle
/// row in order debug7 → sample30 → locomo → blind200.
///
/// The Rust port writes its equivalent output to a sibling file (rust-rows.jsonl)
/// so the cross-port diff can compare the two ports against each other and against
/// the oracle.
@Test("Cross-port fixture — write swift-rows.jsonl (skipped if CDL_CROSSPORT_OUT unset)")
func crossPortFixture() throws {
    guard let outPath = ProcessInfo.processInfo.environment["CDL_CROSSPORT_OUT"] else {
        // CDL_CROSSPORT_OUT not set — skip.  The test runner emits no output
        // for a skipped test; the cross-port run sets the variable explicitly when
        // it wants the fixture written.
        return
    }

    let distiller = ContextDistiller()
    let beds = ["debug7", "sample30", "locomo", "blind200"]
    var lines: [String] = []
    lines.reserveCapacity(509)

    for bed in beds {
        let rows = loadOracleRows(bed: bed)
        for row in rows {
            let input = DistillationInput(original: row.original,
                                          enrichmentTrailer: row.enrichmentTrailer)
            let result = distiller.distill(input, converter: .intentSpanV22)

            // Include record-identity fields (drawer_id) in the fixture so the
            // cross-port diff can correlate rows across ports.
            var dict = result.asDict()
            dict["drawer_id"] = row.drawerID
            dict["original"]  = row.original
            dict["enrichment_trailer"] = row.enrichmentTrailer
            dict["candidate"] = "intent-span"

            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            guard let line = String(data: data, encoding: .utf8) else {
                throw JSONError.encoding
            }
            lines.append(line)
        }
    }

    let content = lines.joined(separator: "\n") + "\n"
    try content.write(toFile: outPath, atomically: true, encoding: .utf8)
}

// MARK: - Smoke tests for supporting types

@Test("ContextDistillConverter identifiers")
func contextDistillConverterIdentifiers() {
    let c = ContextDistillConverter.intentSpanV22
    #expect(c.id             == "intent-span@intent-span-v22-authority-closure")
    #expect(c.converterVersion == "distill-plus-v1")
    #expect(c.schemaVersion  == 1)
}

@Test("DistillationInput initialisation")
func distillationInputInit() {
    let di = DistillationInput(original: "hello", enrichmentTrailer: "(*[ ]*)")
    #expect(di.original == "hello")
    #expect(di.enrichmentTrailer == "(*[ ]*)")

    let di2 = DistillationInput(original: "world")
    #expect(di2.enrichmentTrailer == "")
}

@Test("ShapeDecision has(_:) and asDict() keys")
func shapeDecisionAccessors() throws {
    let sd = ShapeDecision(
        primary: "dialogue",
        labels: ["dialogue"],
        scores: ["dialogue": 11, "timeline": 0, "outline": 0, "entity_dense": 0, "prose": 0],
        features: ["chars": 100, "lines": 5, "tag_lines": 3, "distinct_tags": 2,
                   "known_speaker_lines": 2, "tag_line_pct": 60, "top2_tag_pct": 100,
                   "tag_switch_pct": 100, "date_lead_lines": 0, "date_lead_pct": 0,
                   "bullet_lines": 0, "bullet_line_pct": 0, "heading_lines": 0,
                   "pipe_parts": 1, "pipe_date_parts": 0, "date_mentions": 0,
                   "number_mentions": 0, "email_mentions": 0, "average_line_chars": 20],
        confidenceMargin: 11
    )
    #expect(sd.has("dialogue"))
    #expect(!sd.has("timeline"))

    let d = sd.asDict()
    #expect(d["primary"] as? String == "dialogue")
    #expect(d["confidence_margin"] as? Int == 11)
    let labels = d["labels"] as? [String]
    #expect(labels == ["dialogue"])

    // canonicalJSON must not throw and must contain all five top-level keys
    let json = try sd.canonicalJSON()
    #expect(json.contains("\"primary\""))
    #expect(json.contains("\"labels\""))
    #expect(json.contains("\"scores\""))
    #expect(json.contains("\"features\""))
    #expect(json.contains("\"confidence_margin\""))
}

@Test("combine(_:trailer:) mirrors _combine")
func combineHelper() {
    #expect(combine("core", trailer: "(*[ e: v ]*)")  == "core (*[ e: v ]*)")
    #expect(combine("core", trailer: "")              == "core")
    #expect(combine("",     trailer: "(*[ e: v ]*)") == "(*[ e: v ]*)")
    #expect(combine("",     trailer: "")             == "")
}

@Test("ContextDistiller assembles identity fields correctly")
func contextDistillerIdentityFields() {
    let distiller = ContextDistiller()
    let input = DistillationInput(original: "Hello world.", enrichmentTrailer: "")
    let result = distiller.distill(input, converter: .intentSpanV22)

    #expect(result.schemaVersion     == 1)
    #expect(result.converterVersion  == "distill-plus-v1")
    #expect(result.rulesetVersion    == "intent-span-v22-authority-closure")
    #expect(result.converterID       == "intent-span@intent-span-v22-authority-closure")
    #expect(result.sourceSHA256      == sourceDigest("Hello world."))
    #expect(result.spanOffsetUnit    == "unicode-code-point")
    #expect(result.spanUTF8OffsetUnit == "byte")
}
