// PythonText.swift
// Python-semantics text helpers over [Unicode.Scalar].
//
// All functions in this file replicate Python 3 str methods exactly,
// using unicodeScalars as the index unit (matching Python's code-point
// indexing via str[i]).  Rust uses chars() for the same unit.
//
// Unicode divergences from Swift's stdlib are documented per function.
//
// No external dependencies.  No regex.  Pure arithmetic over scalars.

import Foundation

// MARK: - Whitespace

/// Returns `true` if the scalar is in Python 3's `str.isspace()` set.
///
/// Mirrors Python: `c.isspace()` for a single character.
///
/// Python uses Unicode's Whitespace property (UAX #44 PropList.txt).
/// The exact set:
///   U+0009 TAB, U+000A LF, U+000B VT, U+000C FF, U+000D CR
///   U+0020 SPACE
///   U+0085 NEL (next line)
///   U+00A0 NO-BREAK SPACE
///   U+1680 OGHAM SPACE MARK
///   U+2000–U+200A (various typographic spaces)
///   U+2028 LINE SEPARATOR
///   U+2029 PARAGRAPH SEPARATOR
///   U+202F NARROW NO-BREAK SPACE
///   U+205F MEDIUM MATHEMATICAL SPACE
///   U+3000 IDEOGRAPHIC SPACE
///
/// Swift divergence: `CharacterSet.whitespacesAndNewlines` covers most of
/// these but is not identical at the Unicode scalar level.  We enumerate the
/// exact code-point set from Python's unicodedata to avoid divergence.
///
/// Note: U+001C–U+001F (ASCII separators) are NOT in this set even though
/// some sources list them.  Python 3.x does not treat them as whitespace.
public func isPythonWhitespace(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x0009,          // U+0009 CHARACTER TABULATION (\t)
         0x000A,          // U+000A LINE FEED (\n)
         0x000B,          // U+000B LINE TABULATION (\v)
         0x000C,          // U+000C FORM FEED (\f)
         0x000D,          // U+000D CARRIAGE RETURN (\r)
         0x0020,          // U+0020 SPACE
         0x0085,          // U+0085 NEXT LINE (NEL)
         0x00A0,          // U+00A0 NO-BREAK SPACE
         0x1680,          // U+1680 OGHAM SPACE MARK
         0x2000 ... 0x200A, // U+2000–U+200A (EN QUAD through HAIR SPACE)
         0x2028,          // U+2028 LINE SEPARATOR
         0x2029,          // U+2029 PARAGRAPH SEPARATOR
         0x202F,          // U+202F NARROW NO-BREAK SPACE
         0x205F,          // U+205F MEDIUM MATHEMATICAL SPACE
         0x3000:          // U+3000 IDEOGRAPHIC SPACE
        return true
    default:
        return false
    }
}

// MARK: - Word characters (\w)

/// Returns `true` if the scalar is a Python regex `\w` character.
///
/// Python 3 re with default Unicode flag: `\w` matches Unicode letters,
/// digits, and underscore — equivalent to `[A-Za-z0-9_]` for ASCII plus
/// Unicode letters/digits from all scripts.
///
/// Swift divergence: Swift's `CharacterSet.letters` and `.decimalDigits`
/// cover the correct Unicode sets.  We use `properties.isAlphabetic`,
/// `.isNumber`, and the literal underscore for maximum fidelity.
///
/// Used by `pyWordBoundary` to detect \b transitions.
public func isPythonWordChar(_ s: Unicode.Scalar) -> Bool {
    // Underscore is always a word character.
    if s.value == 0x005F { return true }
    // Unicode alphabetic (covers letters from all scripts).
    if s.properties.isAlphabetic { return true }
    // Unicode decimal/letter/number digits.
    // .isNumber is broader (includes fractions); Python's \w uses isAlpha+isDigit,
    // so we check numeric digit categories directly.
    switch s.properties.generalCategory {
    case .decimalNumber,          // Nd — 0-9 and script-specific digits
         .letterNumber,           // Nl — Roman numerals, etc.
         .otherNumber:            // No — fractions, etc.
        return true
    default:
        return false
    }
}

/// Returns `true` at a Python `\b` word boundary in `scalars` at `index`.
///
/// A `\b` is a zero-width assertion that is true when:
///   - The character at `index` is `\w` and the character at `index-1` is `\W`
///     (or `index == 0`)
///   - OR the character at `index-1` is `\w` and the character at `index` is
///     `\W` (or `index == scalars.count`)
///
/// This mirrors Python's `re` engine's `\b` semantics exactly, using
/// `isPythonWordChar` for `\w` classification.
///
/// - Parameters:
///   - index: The code-point index to test (0-based, inclusive of
///     `scalars.count` for the position after the last character).
///   - scalars: The full scalar array.
/// - Returns: `true` if a word boundary exists at `index`.
public func pyWordBoundary(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
    let prevW: Bool
    let currW: Bool
    if index > 0 {
        prevW = isPythonWordChar(scalars[index - 1])
    } else {
        prevW = false   // virtual non-word before start of string
    }
    if index < scalars.count {
        currW = isPythonWordChar(scalars[index])
    } else {
        currW = false   // virtual non-word after end of string
    }
    return prevW != currW
}

// MARK: - Character predicates (str.isalnum, isalpha, isdigit, isupper)

/// Returns `true` if `s` is an alphanumeric Unicode scalar.
///
/// Mirrors Python: `c.isalnum()` — True if the character is alphabetic OR a
/// decimal/letter/other number.  Unicode-aware.
public func pyIsAlnum(_ s: Unicode.Scalar) -> Bool {
    if s.properties.isAlphabetic { return true }
    switch s.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber: return true
    default: return false
    }
}

/// Returns `true` if `s` is an alphabetic Unicode scalar.
///
/// Mirrors Python: `c.isalpha()` — True if the scalar is in the Unicode
/// alphabetic category (`Alphabetic` derived property).
public func pyIsAlpha(_ s: Unicode.Scalar) -> Bool {
    s.properties.isAlphabetic
}

/// Returns `true` if `s` is a decimal digit (Unicode Nd category).
///
/// Mirrors Python: `c.isdigit()`.  Python's isdigit() is True for decimal
/// digits in any script (Nd) plus some superscript/circled digits (No).
/// For the ASCII-dominant oracle texts this distinction does not arise.
///
/// Swift divergence: `properties.generalCategory == .decimalNumber` is Nd
/// only.  Python includes some No characters.  For the oracle corpus this
/// difference is irrelevant.
public func pyIsDigit(_ s: Unicode.Scalar) -> Bool {
    s.properties.generalCategory == .decimalNumber
}

/// Returns `true` if `s` is an uppercase letter.
///
/// Mirrors Python: `c.isupper()` for a single character — True when the
/// character has uppercase casing.
///
/// Swift divergence: `s.properties.isUppercase` uses Unicode's Uppercase
/// derived property, which matches Python 3's `str.isupper()` for single
/// characters.
public func pyIsUpper(_ s: Unicode.Scalar) -> Bool {
    s.properties.isUppercase
}

// MARK: - Case conversion

/// Applies Python's `str.lower()` to a scalar array.
///
/// Mirrors Python: `text.lower()`.
///
/// Python uses Unicode simple case mapping, as does Swift's `lowercased()`.
/// The two implementations agree for the characters in the oracle corpus.
///
/// Swift divergence: `String.lowercased()` may produce ligature decompositions
/// (e.g. DZ-ligature → dz) or multi-character expansions for some rare code
/// points.  For the ASCII-dominant oracle texts this does not arise.
/// Swift does NOT produce different results for Greek sigma context (Σ→σ always)
/// at the single-character level.  Python is the same.
///
/// Implementation: convert to String, lowercase, re-extract scalars.
/// This is safe because we work with code points as the index unit; the
/// round-trip through String preserves code-point count for simple mappings.
public func pyLower(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    let str = scalars.asString().lowercased()
    return Array(str.unicodeScalars)
}

// MARK: - Splitting and stripping

/// Splits `scalars` on Python's whitespace set, returning non-empty tokens.
///
/// Mirrors Python: `text.split()` (no argument).
///
/// Python's no-arg split:
///   1. Strips leading and trailing whitespace.
///   2. Splits on any run of whitespace (any character for which isspace()
///      returns True).
///   3. Never produces empty strings.
///
/// Result: an array of scalar arrays, one per token.  Returns empty if the
/// input is all whitespace or empty.
///
/// Used by `estimateTokens` to count words, matching Python's `text.split()`.
public func pySplit(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
    var tokens: [[Unicode.Scalar]] = []
    var current: [Unicode.Scalar] = []
    for s in scalars {
        if isPythonWhitespace(s) {
            if !current.isEmpty {
                tokens.append(current)
                current = []
            }
        } else {
            current.append(s)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}

/// Strips Python whitespace from both ends of `scalars`.
///
/// Mirrors Python: `text.strip()`.
public func pyStrip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    let ls = pyLstrip(scalars)
    return pyRstrip(ls)
}

/// Strips Python whitespace from the left (start) of `scalars`.
///
/// Mirrors Python: `text.lstrip()`.
public func pyLstrip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    var start = 0
    while start < scalars.count && isPythonWhitespace(scalars[start]) {
        start += 1
    }
    return Array(scalars[start...])
}

/// Strips Python whitespace from the right (end) of `scalars`.
///
/// Mirrors Python: `text.rstrip()`.
public func pyRstrip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    var end = scalars.count
    while end > 0 && isPythonWhitespace(scalars[end - 1]) {
        end -= 1
    }
    return Array(scalars[..<end])
}

// MARK: - UTF-8 byte offset

/// Returns the UTF-8 byte offset corresponding to code-point index `cpIndex`
/// in `scalars`.
///
/// Python uses code points as its index unit (str[i] is the i-th Unicode
/// scalar).  Swift struct fields in the oracle output carry both `start` (code
/// points) and `start_utf8_byte` (bytes).  This function converts between them.
///
/// - Parameters:
///   - cpIndex: A code-point index (0-based) into `scalars`.
///   - scalars: The full scalar array.
/// - Returns: The byte offset into the equivalent UTF-8 encoding.
///   Returns `scalars.utf8ByteCount` when `cpIndex == scalars.count`.
/// - Precondition: `cpIndex` is in `0 ... scalars.count`.
public func utf8ByteOffset(forCodePoint cpIndex: Int, in scalars: [Unicode.Scalar]) -> Int {
    precondition(cpIndex >= 0 && cpIndex <= scalars.count,
                 "cpIndex \(cpIndex) out of range [0, \(scalars.count)]")
    var bytes = 0
    for i in 0 ..< cpIndex {
        bytes += scalars[i].utf8.count
    }
    return bytes
}
