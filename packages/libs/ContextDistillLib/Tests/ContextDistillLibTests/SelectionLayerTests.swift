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
