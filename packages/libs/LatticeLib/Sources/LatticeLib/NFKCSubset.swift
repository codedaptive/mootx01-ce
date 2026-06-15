// NFKCSubset.swift
//
// The documented compatibility-fold subset used by `Normalizer.normalize`.
// See Normalizer.swift for the cross-platform contract: this table is the
// single source of truth and is mirrored verbatim in rust/src/normalizer.rs.
// The two ports MUST stay byte-identical; the shared fixture
// rust/tests/fixtures/normalize_conformance.json gates the agreement.
//
// DERIVATION
// Every mapping here is a strict subset of the official Unicode NFKC
// compatibility decomposition (the <font>, <wide>, <super>, <sub>,
// <circle>, <compat>, <fraction>, <noBreak> tags). We include only the
// mappings whose target is plain ASCII (or another already-folded form),
// because those are the ones that improve query/import/token quality for an
// ASCII-English corpus: a full-width digit, a superscript, a circled
// letter, or a ligature should hash to the same lattice key as its plain
// ASCII equivalent. Mappings whose NFKC target is non-ASCII (e.g.
// katakana recomposition) are deliberately omitted — see Normalizer.swift
// "EXPLICITLY OUT OF SCOPE".
//
// The range families (full-width, super/subscript, circled, parenthesized,
// roman numerals) are expressed as algorithmic offsets rather than a giant
// literal map so the table stays auditable and the Swift and Rust ports
// compute identical results from identical arithmetic.

import Foundation

/// A deterministic, table-driven compatibility fold: the NFKC subset that
/// maps compatibility code points to their plain-ASCII equivalents.
///
/// Pure and total. Produces output byte-identical to the Rust port.
enum NFKCSubset {

    /// Folds every scalar of `input` through the compatibility subset and
    /// concatenates the (possibly multi-scalar) replacements in order.
    ///
    /// A scalar with no mapping passes through unchanged. The fold is
    /// applied scalar-by-scalar with no reordering, so it is associative
    /// over concatenation and trivially deterministic.
    static func fold(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if let mapped = foldScalar(scalar) {
                out.append(contentsOf: mapped.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// The replacement string for a single scalar, or nil if it has no
    /// mapping in the subset. Replacements may be more than one scalar
    /// (e.g. the `ﬁ` ligature → `fi`, the `½` → `1/2`).
    ///
    /// Lookup order is: explicit literal map first, then the algorithmic
    /// range families. The families are disjoint, so order among them is
    /// irrelevant; the literal map is consulted first only so a literal can
    /// override a family if one is ever added.
    static func foldScalar(_ s: Unicode.Scalar) -> String? {
        if let literal = literalMap[s.value] {
            return literal
        }
        let v = s.value

        // Full-width ASCII variants (U+FF01…U+FF5E) → ASCII (U+0021…U+007E).
        // Offset is a constant 0xFEE0 across the whole printable block.
        if (0xFF01...0xFF5E).contains(v) {
            return scalarString(v - 0xFEE0)
        }

        // Full-width and half-width spaces handled in literalMap (U+3000 etc).

        // Superscript digits: ¹²³ are scattered, the rest are contiguous.
        // U+2070 ⁰, U+2074…U+2079 ⁴…⁹ → '0','4'…'9'. (¹²³ are in literalMap
        // because they sit in the Latin-1 block, not the U+207x block.)
        if v == 0x2070 { return "0" }
        if (0x2074...0x2079).contains(v) { return scalarString(0x30 + (v - 0x2074) + 4) }

        // Subscript digits: U+2080…U+2089 ₀…₉ → '0'…'9'.
        if (0x2080...0x2089).contains(v) { return scalarString(0x30 + (v - 0x2080)) }

        // Circled Latin capital letters: U+24B6…U+24CF Ⓐ…Ⓩ → 'a'…'z'.
        // NFKC maps these to the *lowercase* base letter is not true — NFKC
        // maps Ⓐ→A. We map to the uppercase base; the trailing lowercased()
        // in Normalizer folds it. Here we return the base letter as NFKC
        // would (uppercase for capitals, lowercase for smalls).
        if (0x24B6...0x24CF).contains(v) { return scalarString(0x41 + (v - 0x24B6)) }

        // Circled Latin small letters: U+24D0…U+24E9 ⓐ…ⓩ → 'a'…'z'.
        if (0x24D0...0x24E9).contains(v) { return scalarString(0x61 + (v - 0x24D0)) }

        // Circled digits 1–9: U+2460…U+2468 ①…⑨ → '1'…'9'.
        if (0x2460...0x2468).contains(v) { return scalarString(0x31 + (v - 0x2460)) }
        // Circled digit 0: U+24EA ⓪ → '0'.
        if v == 0x24EA { return "0" }

        // Parenthesized Latin small letters: U+249C…U+24B5 ⒜…⒵ → 'a'…'z'.
        // NFKC decomposes these to "(a)"…"(z)". We follow NFKC exactly.
        if (0x249C...0x24B5).contains(v) {
            let letter = scalarString(0x61 + (v - 0x249C))
            return "(" + letter + ")"
        }

        // Roman numeral capitals: U+2160…U+216B Ⅰ…Ⅻ → ASCII letter runs.
        // and U+216C…U+216F Ⅼ Ⅽ Ⅾ Ⅿ. Smalls U+2170…U+217F similarly.
        if let roman = romanNumeral(v) {
            return roman
        }

        return nil
    }

    /// Explicit one-off mappings that are not part of an arithmetic family.
    /// Keyed by scalar value; value is the ASCII replacement. NFKC-faithful.
    private static let literalMap: [UInt32: String] = [
        // Latin-1 superscripts ¹ ² ³ (U+00B9, U+00B2, U+00B3).
        0x00B9: "1", 0x00B2: "2", 0x00B3: "3",
        // Typographic ligatures (U+FB00…U+FB06).
        0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl",
        0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",
        // Vulgar fractions whose NFKC target is ASCII via the fraction slash.
        0x00BC: "1/4", 0x00BD: "1/2", 0x00BE: "3/4",
        0x2153: "1/3", 0x2154: "2/3",
        // Fraction slash → ASCII solidus.
        0x2044: "/",
        // Superscript/subscript signs.
        0x207A: "+", 0x207B: "-", 0x207C: "=", 0x207D: "(", 0x207E: ")",
        0x208A: "+", 0x208B: "-", 0x208C: "=", 0x208D: "(", 0x208E: ")",
        // No-break / compatibility spaces → ASCII space (NFKC <noBreak>/<compat>).
        0x00A0: " ", 0x2007: " ", 0x202F: " ", 0x3000: " ",
        // Numero sign № (U+2116) → "No" per NFKC.
        0x2116: "No",
    ]

    /// Roman-numeral letterlike scalars → their ASCII letter runs.
    /// Capitals: U+2160…U+216F, smalls: U+2170…U+217F. Returns nil outside
    /// those blocks. Faithful to NFKC (which decomposes Ⅻ→"XII", etc.).
    private static func romanNumeral(_ v: UInt32) -> String? {
        switch v {
        case 0x2160: return "I";   case 0x2161: return "II"
        case 0x2162: return "III"; case 0x2163: return "IV"
        case 0x2164: return "V";   case 0x2165: return "VI"
        case 0x2166: return "VII"; case 0x2167: return "VIII"
        case 0x2168: return "IX";  case 0x2169: return "X"
        case 0x216A: return "XI";  case 0x216B: return "XII"
        case 0x216C: return "L";   case 0x216D: return "C"
        case 0x216E: return "D";   case 0x216F: return "M"
        case 0x2170: return "i";   case 0x2171: return "ii"
        case 0x2172: return "iii"; case 0x2173: return "iv"
        case 0x2174: return "v";   case 0x2175: return "vi"
        case 0x2176: return "vii"; case 0x2177: return "viii"
        case 0x2178: return "ix";  case 0x2179: return "x"
        case 0x217A: return "xi";  case 0x217B: return "xii"
        case 0x217C: return "l";   case 0x217D: return "c"
        case 0x217E: return "d";   case 0x217F: return "m"
        default: return nil
        }
    }

    /// Builds a one-scalar string from a code-point value. The value is
    /// always a valid scalar here (computed from a checked ASCII range).
    private static func scalarString(_ value: UInt32) -> String {
        // Force-unwrap is safe: every call site passes an ASCII-range value.
        return String(Unicode.Scalar(value)!)
    }
}
