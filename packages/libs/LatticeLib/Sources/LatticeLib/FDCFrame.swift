// FDCFrame.swift
//
// The FDC classification frame model and its decimal-string ancestry.
//
// Schema (FDC_ENCODER_COOKBOOK_v1.0 §1.1):
//
//   { "frame_version": "1.0.0",
//     "codes": [ { "code": "006.6", "label": "Computer graphics" }, ... ] }
//
// Ancestry is NOT stored. It is derived from the decimal string, per the
// canonical spec §2 ("the decimal string itself encodes the ancestry")
// and cookbook §6.2 / §7.1.

import Foundation

/// One FDC code and its label, as stored in `FDCFrame.json`.
public struct FDCEntry: Codable, Equatable, Sendable {
    /// The decimal classification code, e.g. "000", "006", "006.6".
    public let code: String
    /// The heading text carried by this artifact. Maintainer build frames keep
    /// the lossless `fdc.txt` syntax for signature construction; bundled runtime
    /// frames use the corresponding clean user-facing display label.
    public let label: String

    public init(code: String, label: String) {
        self.code = code
        self.label = label
    }
}

/// The FDC frame: a versioned list of codes. Ancestry is computed from
/// the decimal strings, not stored.
public struct FDCFrame: Codable, Equatable, Sendable {
    /// Artifact version string (JSON key `frame_version`).
    public let frameVersion: String
    /// All codes in the frame.
    public let codes: [FDCEntry]

    private enum CodingKeys: String, CodingKey {
        case frameVersion = "frame_version"
        case codes
    }

    public init(frameVersion: String, codes: [FDCEntry]) {
        self.frameVersion = frameVersion
        self.codes = codes
    }

    // MARK: - Ancestry derivation
    //
    // WHY THIS IS NOT A PLAIN STRING-PREFIX / DOT-SPLIT MATCH
    // ------------------------------------------------------
    // The obvious approach — "split the code on '.', a child is the node
    // plus one more dot-segment" — is WRONG for FDC, and the canonical
    // contract proves it: ancestors("006.6") MUST equal ["000","006"]
    // (cookbook §1.1, mission Part 2 verify). Under a pure dot-split the
    // only ancestor of "006.6" would be "006" — "000" would never appear,
    // because "006" does not contain a '.' to split on.
    //
    // FDC codes have TWO different ancestry regimes:
    //
    //   1. The 3-digit INTEGER HEAD (before any '.') is a Dewey
    //      positional hierarchy, read left to right at the hundreds /
    //      tens / units places:
    //        - units place set (d3 != 0): parent zeroes the units, e.g.
    //          parent("006") = "000", parent("016") = "010".
    //        - tens place set, units zero (d2 != 0, d3 == 0): parent
    //          zeroes the tens, e.g. parent("010") = "000",
    //          parent("510") = "500".
    //        - hundreds place set only (d1 != 0, d2 == d3 == 0): parent
    //          is the root "000", e.g. parent("100") = "000".
    //        - "000" is the root and has no parent.
    //      So parent("006") = "000", NOT "00". The head is always three
    //      digits; there is no two-digit code.
    //
    //   2. The DECIMAL TAIL (after the first '.') is a per-segment
    //      hierarchy: each ".segment" is exactly one level. The parent of
    //      a code with a decimal point is the code with its last
    //      ".segment" removed, e.g. parent("006.6") = "006",
    //      parent("006.6.1") = "006.6". The period is a segment delimiter,
    //      never a substring marker.
    //
    // `ancestors(of:)` is a pure function of the code string and does not
    // consult `codes`; `children(of:)` filters `codes` by parent identity.

    /// The immediate parent of a code, or `nil` for the root "000" (and
    /// for any string that is not a well-formed FDC code).
    ///
    /// Pure function of the string: no frame lookup. See the regime notes
    /// above for the integer-head vs decimal-tail rules.
    static func decimalParent(of code: String) -> String? {
        // Regime 2: a decimal tail present — drop the last ".segment".
        if let lastDot = code.lastIndex(of: ".") {
            return String(code[code.startIndex..<lastDot])
        }

        // Regime 1: 3-digit integer head, Dewey positional hierarchy.
        // Guard the expected shape: exactly three ASCII digits.
        let chars = Array(code)
        guard chars.count == 3, chars.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            // Not a recognized head shape (e.g. a malformed token); no
            // derivable parent. Ancestry callers stop here.
            return nil
        }
        let d1 = chars[0], d2 = chars[1], d3 = chars[2]
        let zero: Character = "0"
        if d3 != zero {
            // Units place occupied: parent is the same head with units = 0.
            return String([d1, d2, zero])
        }
        if d2 != zero {
            // Tens place occupied, units zero: parent zeroes the tens.
            return String([d1, zero, zero])
        }
        if d1 != zero {
            // Hundreds place occupied only: parent is the root.
            return "000"
        }
        // code == "000": the root has no parent.
        return nil
    }

    /// All codes in the frame whose immediate parent is `node`, i.e. the
    /// codes exactly one level below `node` in the FDC hierarchy.
    ///
    /// Children of "006" include "006.6" (one decimal segment deeper) but
    /// not "006.6.1" (two deeper). Children of "000" are its Dewey-head
    /// children (001, 002, 010, 100, ...), never decimal descendants like
    /// "006.6". Returned sorted lexicographically by code for
    /// deterministic output regardless of frame order.
    public func children(of node: String) -> [FDCEntry] {
        codes
            .filter { Self.decimalParent(of: $0.code) == node }
            .sorted { $0.code < $1.code }
    }

    /// All ancestors of `code`, root first, excluding `code` itself.
    ///
    /// Pure function of the decimal string (cookbook §7.1: "ancestors =
    /// all prefixes, root first"). `ancestors("006.6")` is
    /// `["000", "006"]`; `ancestors("000")` is `[]`.
    public func ancestors(of code: String) -> [String] {
        var chain: [String] = []
        var current = code
        // Walk parent links upward, then reverse so the root comes first.
        while let parent = Self.decimalParent(of: current) {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }
}
