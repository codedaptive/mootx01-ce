// SelectionLayerTests.swift
// Part 4 oracle-vector conformance tests for the intent-span selection layer.
//
// Asserts on all 509 rows across four beds:
//   1. compact_core       — string equality with oracle
//   2. selected_source_spans — per-span JSON equality (all fields: atom_id, start,
//      end, kind, speaker, dependencies, hard_required, start_utf8_byte, end_utf8_byte)
//   3. selection_details  — JSON equality with trailer_projection removed from
//      both the oracle and the Swift output before comparison
//
// The trailer field is intentionally excluded because Part 4 tests selection
// logic only.  Part 5 will add trailer_projection to the comparison.
//
// Test runner: `swift test` from the ContextDistillLib/ directory.

import Testing
@testable import ContextDistillLib
import Foundation

// MARK: - Helpers

/// Removes `trailer_projection` from a selection_details dict (in place on a copy).
private func stripTrailerProjection(_ d: [String: Any]) -> [String: Any] {
    var copy = d
    copy.removeValue(forKey: "trailer_projection")
    return copy
}

/// Canonical JSON string for an arbitrary Foundation-compatible value.
///
/// Uses `.sortedKeys` so dict insertion order doesn't affect comparison.
private func canonicalJSONAny(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let str = String(data: data, encoding: .utf8) else {
        throw JSONTestError.encoding
    }
    return str
}

private enum JSONTestError: Error { case encoding }

/// Asserts all three Part 4 outputs for a single oracle row.
private func assertSelectionConformance(_ row: OracleRow) throws {
    let source = row.original
    guard let trailer = row.rawJSON["enrichment_trailer"] as? String else {
        Issue.record("Missing enrichment_trailer for drawer \(row.drawerID)")
        return
    }
    let result = intentSpan(source, trailer: trailer)

    // --- 1. compact_core ---
    let expectedCore = (row.rawJSON["compact_core"] as? String) ?? ""
    #expect(
        result.core == expectedCore,
        "compact_core mismatch for drawer \(row.drawerID):\n  expected: \(expectedCore.prefix(120))\n  actual:   \(result.core.prefix(120))"
    )

    // --- 2. selected_source_spans ---
    guard let expectedSpans = row.rawJSON["selected_source_spans"] as? [[String: Any]] else {
        Issue.record("Missing selected_source_spans for drawer \(row.drawerID)")
        return
    }
    let actualSpansJSON = try canonicalJSONAny(result.selectedSpans)
    let expectedSpansJSON = try canonicalJSONAny(expectedSpans)
    #expect(
        actualSpansJSON == expectedSpansJSON,
        "selected_source_spans mismatch for drawer \(row.drawerID):\n  expected: \(expectedSpansJSON.prefix(200))\n  actual:   \(actualSpansJSON.prefix(200))"
    )

    // --- 3. selection_details (trailer_projection excluded) ---
    guard let expectedDetails = row.rawJSON["selection_details"] as? [String: Any] else {
        Issue.record("Missing selection_details for drawer \(row.drawerID)")
        return
    }
    let actualDetailsJSON = try canonicalJSONAny(stripTrailerProjection(result.selectionDetails))
    let expectedDetailsJSON = try canonicalJSONAny(stripTrailerProjection(expectedDetails))
    #expect(
        actualDetailsJSON == expectedDetailsJSON,
        "selection_details mismatch for drawer \(row.drawerID):\n  expected: \(expectedDetailsJSON.prefix(300))\n  actual:   \(actualDetailsJSON.prefix(300))"
    )
}

// MARK: - Per-bed conformance tests

/// Part 4 selection-layer conformance on the 7 debug7 rows.
@Test("Part 4 selection conformance — debug7 (7 rows)")
func selectionConformance_debug7() throws {
    let rows = loadOracleRows(bed: "debug7")
    for row in rows {
        try assertSelectionConformance(row)
    }
}

/// Part 4 selection-layer conformance on the 30 sample30 rows.
@Test("Part 4 selection conformance — sample30 (30 rows)")
func selectionConformance_sample30() throws {
    let rows = loadOracleRows(bed: "sample30")
    for row in rows {
        try assertSelectionConformance(row)
    }
}

/// Part 4 selection-layer conformance on the 272 locomo rows.
@Test("Part 4 selection conformance — locomo (272 rows)")
func selectionConformance_locomo() throws {
    let rows = loadOracleRows(bed: "locomo")
    for row in rows {
        try assertSelectionConformance(row)
    }
}

/// Part 4 selection-layer conformance on the 200 blind200 rows.
@Test("Part 4 selection conformance — blind200 (200 rows)")
func selectionConformance_blind200() throws {
    let rows = loadOracleRows(bed: "blind200")
    for row in rows {
        try assertSelectionConformance(row)
    }
}

// MARK: - sourceOccurrences guard tests (db238897)

/// Regression guard: value longer than source must return [] without trapping.
/// Pre-fix: the closed range `0 ... (n - valLen)` trapped when valLen > n
/// because Int subtraction underflowed to a huge positive, producing a
/// lowerBound > upperBound closed range — a Swift runtime trap.
/// Same vector used in Rust test `test_source_occurrences_basic` plus the
/// longer-than-source case added for db238897.
@Test("sourceOccurrences — value longer than source returns empty (db238897 guard)")
func sourceOccurrences_valueLongerThanSource() {
    // Source: "Hi" (2 scalars); value: "Hello" (5 scalars) — valLen > n.
    // Pre-fix code: `for i in 0 ... (2 - 5)` → runtime trap.
    // Post-fix code: guard valLen <= n → returns [].
    let scalars = Array("Hi".unicodeScalars)
    let result = sourceOccurrences(scalars: scalars, value: "Hello")
    #expect(result.isEmpty, "value longer than source must return [] not trap")
}

/// Regression guard: empty value must return [] (unchanged from before fix).
@Test("sourceOccurrences — empty value returns empty (db238897 guard)")
func sourceOccurrences_emptyValue() {
    let scalars = Array("Hello world".unicodeScalars)
    let result = sourceOccurrences(scalars: scalars, value: "")
    #expect(result.isEmpty, "empty value must return []")
}

/// Parity with Rust test_source_occurrences_basic: "world" in "Hello world" → [(6,11)].
@Test("sourceOccurrences — basic match parity with Rust oracle (db238897)")
func sourceOccurrences_basicMatchParityRust() {
    let scalars = Array("Hello world".unicodeScalars)
    let result = sourceOccurrences(scalars: scalars, value: "world")
    #expect(result.count == 1)
    #expect(result[0].start == 6)
    #expect(result[0].end == 11)
}
