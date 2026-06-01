// Code.swift
//
// FDC code validity. A code is well-formed if it matches the integer-
// plus-optional-decimal-extension grammar:
//
//     code        := integer ( '.' digits )?
//     integer     := three decimal digits, value 000..999
//     digits      := one to N decimal digits (N=8 in v1; see below)
//
// The decimal extension carries leaf resolution under a spine code.
// Each additional digit subdivides into ten — 540 -> 540.0 .. 540.9
// -> 540.00 .. 540.99 and so on. v1 caps the extension length at
// eight digits, which gives ten to the eighth distinct leaves per
// spine code, far more than any plausible signature set will reach. The cap
// exists so the printable form fits in a reasonable column width
// (twelve characters including the dot) and so encoders/decoders can
// reason about an upper bound on string length.
//
// Validity is purely grammatical: a well-formed code is accepted by
// tooling, stored, and round-tripped intact regardless of whether any
// term currently encodes to it. The known-vs-pending decision belongs
// to the caller, which carries its own set of known codes — see
// EideticLib.classifyLatticeCode(_:knownCodes:).

import Foundation

/// Code grammar checks. Pure functions; no canon lookup involved.
public enum Code {

    /// The maximum number of digits permitted after the decimal point.
    public static let maxExtensionDigits: Int = 8

    /// True if `code` matches the FDC code grammar.
    public static func isWellFormed(_ code: String) -> Bool {
        let parts = code.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
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

    /// The three-digit integer base of a well-formed code, or nil if
    /// the code is malformed. "540.137" -> 540.
    public static func integerBase(of code: String) -> Int? {
        guard isWellFormed(code) else { return nil }
        let integerPart = code.split(separator: ".").first.map(String.init) ?? code
        return Int(integerPart)
    }
}
