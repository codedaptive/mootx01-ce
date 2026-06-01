// LatticeCodeState.swift
//
// The valid-but-unknown-code state from docs/canon/LAUNCH_PLAN.md
// §EideticLib. An MDCC code presented to EideticLib is one of three
// things:
//
//   - malformed: the string does not match the MDCC grammar
//   - known:     the string is well-formed and present in the
//                caller's bound canon
//   - pending:   the string is well-formed but not yet in the
//                caller's bound canon — accepted, stored, and
//                round-tripped intact, resolvable on the next
//                canon pull
//
// The grammar in LatticeCodeGrammar is the same grammar enforced by
// LatticeLib's Code.isWellFormed(_:). It is reimplemented here in
// six lines so EideticLib can validate codes without importing
// LatticeLib. The two implementations are conformance-checked via
// agreement tests in LatticeLib's CodeTests.

import Foundation

/// The state a candidate MDCC code is in relative to a bound canon.
/// Conforms to Codable so a pending code round-trips intact through
/// storage layers — that is the core invariant of the launch plan's
/// valid-but-unknown-code requirement.
public enum LatticeCodeState: Sendable, Hashable, Codable {

    /// The string does not match the MDCC grammar. The associated
    /// value preserves the original input for error reporting.
    case malformed(String)

    /// Well-formed and present in the bound canon. The associated
    /// value is the code itself; resolution to a label/entry is
    /// performed by the consumer through their LatticeLib canon.
    case known(String)

    /// Well-formed but not present in the bound canon. The
    /// pending state. Consumers must accept and round-trip the
    /// code intact; it will resolve on the next canon pull or
    /// when a newer canon ships.
    case pending(String)

    /// The original input string, regardless of state. Lets
    /// storage layers round-trip the value without unpacking.
    public var rawCode: String {
        switch self {
        case let .malformed(c), let .known(c), let .pending(c):
            return c
        }
    }

    /// True when the code passed the grammar check. False only
    /// for `.malformed`. Useful in tests that assert pending
    /// codes are accepted.
    public var isWellFormed: Bool {
        switch self {
        case .malformed: return false
        case .known, .pending: return true
        }
    }
}

/// The MDCC code grammar in EideticLib. Pure-Swift, no canon access.
///
/// Parallel implementation of LatticeLib's `Code.isWellFormed(_:)`. Kept
/// as a dependency-free grammar check so `classifyLatticeCode` can
/// validate a code's shape without loading the canon, even though
/// EideticLib now depends on LatticeLib for resolution. Bit-for-bit
/// agreement with LatticeLib is enforced by tests that share the
/// canonical conformance vectors in LatticeLib's test target.
public enum LatticeCodeGrammar {

    /// Maximum digits permitted after the decimal point. Matches
    /// LatticeLib's `Code.maxExtensionDigits` (v1: 8). Locked across
    /// both implementations.
    public static let maxExtensionDigits: Int = 8

    /// True if `code` matches the MDCC code grammar:
    /// three ASCII digits optionally followed by a dot and up to
    /// eight ASCII digits.
    public static func isWellFormed(_ code: String) -> Bool {
        let parts = code.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let integerSub = parts.first else { return false }
        let integerPart = String(integerSub)
        guard integerPart.count == 3,
              integerPart.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return false
        }
        if parts.count == 1 {
            return true
        }
        let extensionPart = String(parts[1])
        guard !extensionPart.isEmpty,
              extensionPart.count <= maxExtensionDigits,
              extensionPart.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return false
        }
        return true
    }
}
