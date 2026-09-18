import Foundation

// PayloadArm.swift — payload-economics shape-variant arms (PAYLOAD-ARMS).
//
// Prices candidate-row FIELD CONTRIBUTIONS without reopening the ruled
// ARIA 2.0.0 result contract. The product payload never changes: the
// benchmarker post-processes the FULL ruled payload harness-side, per arm,
// before row text feeds judged output. The ruled dense row is
//
//   <UUID> · <subject> · <bestSpan> · <sscFacts> · <eventTime ISO8601> · <score>
//
// (` · ` = space, U+00B7 MIDDLE DOT, space — dense-row grammar;
// S2 rows carry five columns, score absent). A suppressed column is re-rendered as the contract's own
// absent-field sentinel `-`, so a stripped row stays IN-GRAMMAR: any
// downstream dense-row parse still reads it, the UUID/subject columns
// survive, and only the priced content is removed. Retrieval scoring is
// unaffected by design — `retrieveThroughSeam` strips only the textBlocks
// of its result; orderedIDs/items (parsed from the full payload) pass
// through untouched.
//
// Arm identity is recorded in the report's run_environment as
// `payload_arm` (IdentityEnvironment). A run with no arm records nothing
// and is byte-identical to pre-arm behaviour.

/// One payload-economics shape-variant arm. Raw values are the CLI/env
/// spelling (`--payload-arm v0`, `v1`, `v4`, `v5`, or `MOOT_BENCH_PAYLOAD_ARM`).
public enum PayloadArm: String, Sendable, Codable, CaseIterable {
    /// Floor: uuid + subject + eventTime + score. bestSpan and sscFacts are
    /// sentineled.
    case v0
    /// Floor + bestSpan (only sscFacts sentineled).
    case v1
    /// Full ruled row — the identity transform / control cell.
    case v4
    /// Full ruled row with CONTROL LINES suppressed: non-row lines
    /// (e.g. the `found N candidate memories…` header) are dropped from
    /// payloads that contain at least one dense row. A payload with no
    /// dense rows passes through unchanged so hydrated full-body payloads
    /// are never wiped.
    case v5

    /// The dense-row field separator — space, U+00B7 MIDDLE DOT, space.
    static let separator = " \u{00B7} "

    /// The ruled contract's absent-field sentinel (`-` on the wire).
    static let absentSentinel = "-"

    /// 0-based ruled-row column indexes this arm suppresses.
    /// Columns: 0 uuid · 1 subject · 2 bestSpan · 3 sscFacts ·
    /// 4 eventTime · 5 score (absent on S2 rows).
    /// The suppressible columns are 2 and 3 only, so the same set applies to
    /// 5-column (S2) and 6-column (S1) rows.
    var suppressedColumns: Set<Int> {
        switch self {
        case .v0: return [2, 3]
        case .v1: return [3]
        case .v4, .v5: return []
        }
    }

    /// True when the line parses as a ruled dense row (5 or 6 ` · `
    /// separated columns). Anything else is a control line (header,
    /// coaching text, hydrated body text).
    static func isDenseRow(_ line: String) -> Bool {
        let n = line.components(separatedBy: separator).count
        return n == 5 || n == 6
    }

    /// Re-renders one dense row with this arm's suppressed columns replaced
    /// by the absent sentinel. Non-row lines and v4/v5 rows return
    /// unchanged. Idempotent: a sentinel column re-sentinels to itself.
    public func strip(row: String) -> String {
        guard !suppressedColumns.isEmpty else { return row }
        let fields = row.components(separatedBy: Self.separator)
        guard fields.count == 5 || fields.count == 6 else { return row }
        let rendered = fields.enumerated().map { idx, field in
            suppressedColumns.contains(idx) ? Self.absentSentinel : field
        }
        return rendered.joined(separator: Self.separator)
    }

    /// Applies the arm to one multi-line payload block. v0–v3 strip each
    /// dense row and pass control lines through; v4 is the identity; v5
    /// keeps rows whole and drops control lines (only when the block
    /// actually contains dense rows — see the case doc).
    public func apply(toPayload payload: String) -> String {
        guard self != .v4 else { return payload }
        let lines = payload.components(separatedBy: "\n")
        if self == .v5 {
            guard lines.contains(where: Self.isDenseRow) else { return payload }
            return lines.filter(Self.isDenseRow).joined(separator: "\n")
        }
        return lines.map { Self.isDenseRow($0) ? strip(row: $0) : $0 }
            .joined(separator: "\n")
    }

    /// Applies the arm to each MCP text block independently.
    public func apply(toTextBlocks blocks: [String]) -> [String] {
        guard self != .v4 else { return blocks }
        return blocks.map { apply(toPayload: $0) }
    }
}

/// Parses a payload-arm spelling (`"v0"`, `"v1"`, `"v4"`, `"v5"`). nil in,
/// nil out — the arm machinery stays inert when neither `--payload-arm` nor
/// `MOOT_BENCH_PAYLOAD_ARM` is present. An unknown value is a HARD error:
/// an unrecognized arm silently falling back to the full payload would
/// record a mislabeled cell (same fail-loud rule as
/// `MOOT_BENCH_RETRIEVAL_ARGS`).
func parsePayloadArm(_ raw: String?) throws -> PayloadArm? {
    guard let raw, !raw.isEmpty else { return nil }
    guard let arm = PayloadArm(rawValue: raw) else {
        throw MCPError(description:
            "--payload-arm / MOOT_BENCH_PAYLOAD_ARM must be one of "
            + PayloadArm.allCases.map(\.rawValue).joined(separator: "|")
            + "; got '\(raw)'")
    }
    return arm
}
