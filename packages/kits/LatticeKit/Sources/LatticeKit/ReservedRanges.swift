// ReservedRanges.swift
//
// Held-open ranges within the MDCC v1 spine. Reserved ranges are
// design input to v1 — they cannot be retrofitted, because adding a
// reserved range after codes have been assigned around it forces
// renumbering and breaks downstream users.
//
// Two kinds of reservation ship in v1:
//   - Per-class community ranges. Each top-of-tree class holds a
//     ten-section block at the end of its hundred for curated
//     community additions ratified into the public canon.
//   - Per-class annex ranges. Each class holds one section reserved
//     for provisional annex codes that have not yet been ratified
//     into a reserved community range. An annex code is well-formed
//     but its meaning is held by the annex creator, not the canon.
//
// The valid-but-unknown state (LAUNCH_PLAN.md §MDCC) is handled by
// the code-validity check, not by the reservation table: a code
// inside a reserved community range is well-formed even when the
// canon does not yet enumerate an entry for it.

import Foundation

/// A contiguous reserved range within the MDCC spine. The range is
/// inclusive of both endpoints. `kind` describes the policy that
/// applies to codes inside the range.
public struct ReservedRange: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable {
        /// Curated community additions ratified into the public canon.
        case community
        /// Provisional annex codes — well-formed but unratified.
        case annex
    }

    /// Inclusive lower bound, as a three-digit integer (no decimal
    /// extension). 990 means code "990" and any decimal extension
    /// underneath it.
    public let lowerBound: Int
    /// Inclusive upper bound, as a three-digit integer.
    public let upperBound: Int
    /// Reservation policy.
    public let kind: Kind
    /// Short description used by the slow-docs channel.
    public let note: String

    public init(lowerBound: Int, upperBound: Int, kind: Kind, note: String) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.kind = kind
        self.note = note
    }

    /// True if the integer base of `code` falls inside this range.
    /// The decimal extension is ignored — a reservation covers a
    /// whole integer-base block.
    public func contains(code: String) -> Bool {
        let integerPart = code.split(separator: ".").first.map(String.init) ?? code
        guard let value = Int(integerPart) else { return false }
        return value >= lowerBound && value <= upperBound
    }
}

/// The v1 reservation table. Two reserved blocks per class:
///   - The last division of each class (NN8x and NN9x at the section
///     level — implemented as NN80-NN99) is the community range.
///   - One section inside the community range (NN90-NN99) is the
///     annex range, for provisional sets the canon does not yet name.
///
/// Holding the community range at the high end of every class means a
/// later curated addition that thematically belongs in a class can
/// land there without disturbing the codes already assigned in NN00-NN79.
public enum ReservedRanges {

    /// All reserved ranges in v1, ordered by lower bound.
    public static let table: [ReservedRange] = NotationSpine.classes.flatMap { latticeClass in
        // Each class holds 80-99 of its hundred as community + annex.
        // Concretely: for class 500, community is 580-599, annex is
        // 590-599. The annex range is nested inside the community
        // range — annex codes are a sub-policy of community codes,
        // marked provisional until ratified.
        let communityLower = latticeClass.base + 80
        let communityUpper = latticeClass.base + 99
        let annexLower = latticeClass.base + 90
        let annexUpper = latticeClass.base + 99
        return [
            ReservedRange(lowerBound: communityLower,
                          upperBound: communityUpper,
                          kind: .community,
                          note: "Community-ratified additions inside \(latticeClass.name)."),
            ReservedRange(lowerBound: annexLower,
                          upperBound: annexUpper,
                          kind: .annex,
                          note: "Provisional annex codes inside \(latticeClass.name)."),
        ]
    }

    /// Returns the reservation that owns a given code, or nil if the
    /// code is not inside any reserved range. When both a community
    /// range and an annex range nested inside it match (since the
    /// annex range is a subset), the annex match is returned — the
    /// nested policy wins, because annex codes have stricter rules
    /// (unratified, may be replaced on ratification).
    public static func reservation(for code: String) -> ReservedRange? {
        // Walk in reverse so the annex match (registered second per
        // class) is checked before the surrounding community match.
        for range in table.reversed() where range.contains(code: code) {
            return range
        }
        return nil
    }

    /// True if `code` is reserved under any policy. Used by the
    /// assembler to refuse assignment into reserved ranges — the
    /// assembler may only place codes in the unreserved part of each
    /// class (NN00 through NN79).
    public static func isReserved(_ code: String) -> Bool {
        reservation(for: code) != nil
    }
}
