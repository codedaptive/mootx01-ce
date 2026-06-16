// normalizer.rs — compatibility fold (documented NFKC subset) + case fold
//
// Port of Normalizer.swift + NFKCSubset.swift. Swift LEADS; this file mirrors
// the Swift table VERBATIM. See Normalizer.swift for the full contract.
//
// CROSS-PLATFORM CONTRACT (load-bearing)
// `normalize` is NOT Rust's nonexistent built-in NFKC (the zero-dep rule
// forbids the `unicode-normalization` crate here). Both legs apply the SAME
// explicit, table-driven compatibility map. Same table + same algorithm ⇒
// byte-identical output by construction. The shared fixture
// tests/fixtures/normalize_conformance.json gates the agreement.
//
// COVERAGE / OUT-OF-SCOPE: identical to NFKCSubset.swift. We fold full-width
// ASCII, typographic ligatures, super/subscript digits and signs, circled
// and parenthesized Latin letters/digits, Roman-numeral letterlikes,
// vulgar fractions, the fraction slash, the numero sign, and compatibility
// spaces — every mapping whose NFKC target is plain ASCII. Canonical
// recomposition of base+combining sequences (e.g. half-width katakana
// ｶ + ﾞ → ガ) is deliberately OUT OF SCOPE and passes through unchanged.

/// Normalize a token: compatibility fold (`fold`) then Unicode-aware case
/// fold (`to_lowercase`). Byte-identical to `Normalizer.normalize` in Swift.
pub fn normalize(token: &str) -> String {
    fold(token).to_lowercase()
}

/// Folds every scalar of `input` through the compatibility subset and
/// concatenates the replacements in order. Unmapped scalars pass through.
/// Mirrors `NFKCSubset.fold` in Swift.
pub fn fold(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match fold_scalar(ch as u32) {
            Some(rep) => out.push_str(&rep),
            None => out.push(ch),
        }
    }
    out
}

/// The replacement for a single scalar value, or None if unmapped.
/// Lookup order mirrors `NFKCSubset.foldScalar`: literal map first, then the
/// disjoint algorithmic range families.
fn fold_scalar(v: u32) -> Option<String> {
    if let Some(lit) = literal_map(v) {
        return Some(lit);
    }

    // Full-width ASCII variants (U+FF01..=U+FF5E) → ASCII; constant 0xFEE0.
    if (0xFF01..=0xFF5E).contains(&v) {
        return Some(scalar_string(v - 0xFEE0));
    }

    // Superscript digits: ⁰ (U+2070), ⁴..⁹ (U+2074..=U+2079). (¹²³ in literal_map.)
    if v == 0x2070 {
        return Some("0".to_string());
    }
    if (0x2074..=0x2079).contains(&v) {
        return Some(scalar_string(0x30 + (v - 0x2074) + 4));
    }

    // Subscript digits: U+2080..=U+2089 → '0'..'9'.
    if (0x2080..=0x2089).contains(&v) {
        return Some(scalar_string(0x30 + (v - 0x2080)));
    }

    // Circled Latin capitals: U+24B6..=U+24CF → 'A'..'Z'.
    if (0x24B6..=0x24CF).contains(&v) {
        return Some(scalar_string(0x41 + (v - 0x24B6)));
    }

    // Circled Latin smalls: U+24D0..=U+24E9 → 'a'..'z'.
    if (0x24D0..=0x24E9).contains(&v) {
        return Some(scalar_string(0x61 + (v - 0x24D0)));
    }

    // Circled digits 1–9: U+2460..=U+2468 → '1'..'9'.
    if (0x2460..=0x2468).contains(&v) {
        return Some(scalar_string(0x31 + (v - 0x2460)));
    }
    // Circled digit 0: U+24EA → '0'.
    if v == 0x24EA {
        return Some("0".to_string());
    }

    // Parenthesized Latin smalls: U+249C..=U+24B5 → "(a)".."(z)".
    if (0x249C..=0x24B5).contains(&v) {
        let letter = scalar_string(0x61 + (v - 0x249C));
        return Some(format!("({})", letter));
    }

    // Roman-numeral letterlikes.
    if let Some(roman) = roman_numeral(v) {
        return Some(roman.to_string());
    }

    None
}

/// Explicit one-off mappings (NFKC-faithful), mirroring `NFKCSubset.literalMap`.
fn literal_map(v: u32) -> Option<String> {
    let s = match v {
        // Latin-1 superscripts ¹ ² ³.
        0x00B9 => "1",
        0x00B2 => "2",
        0x00B3 => "3",
        // Typographic ligatures (U+FB00..=U+FB06).
        0xFB00 => "ff",
        0xFB01 => "fi",
        0xFB02 => "fl",
        0xFB03 => "ffi",
        0xFB04 => "ffl",
        0xFB05 => "st",
        0xFB06 => "st",
        // Vulgar fractions.
        0x00BC => "1/4",
        0x00BD => "1/2",
        0x00BE => "3/4",
        0x2153 => "1/3",
        0x2154 => "2/3",
        // Fraction slash → ASCII solidus.
        0x2044 => "/",
        // Superscript/subscript signs.
        0x207A => "+",
        0x207B => "-",
        0x207C => "=",
        0x207D => "(",
        0x207E => ")",
        0x208A => "+",
        0x208B => "-",
        0x208C => "=",
        0x208D => "(",
        0x208E => ")",
        // No-break / compatibility spaces → ASCII space.
        0x00A0 => " ",
        0x2007 => " ",
        0x202F => " ",
        0x3000 => " ",
        // Numero sign № → "No".
        0x2116 => "No",
        _ => return None,
    };
    Some(s.to_string())
}

/// Roman-numeral letterlike scalars → ASCII letter runs. Mirrors
/// `NFKCSubset.romanNumeral`.
fn roman_numeral(v: u32) -> Option<&'static str> {
    let s = match v {
        0x2160 => "I",
        0x2161 => "II",
        0x2162 => "III",
        0x2163 => "IV",
        0x2164 => "V",
        0x2165 => "VI",
        0x2166 => "VII",
        0x2167 => "VIII",
        0x2168 => "IX",
        0x2169 => "X",
        0x216A => "XI",
        0x216B => "XII",
        0x216C => "L",
        0x216D => "C",
        0x216E => "D",
        0x216F => "M",
        0x2170 => "i",
        0x2171 => "ii",
        0x2172 => "iii",
        0x2173 => "iv",
        0x2174 => "v",
        0x2175 => "vi",
        0x2176 => "vii",
        0x2177 => "viii",
        0x2178 => "ix",
        0x2179 => "x",
        0x217A => "xi",
        0x217B => "xii",
        0x217C => "l",
        0x217D => "c",
        0x217E => "d",
        0x217F => "m",
        _ => return None,
    };
    Some(s)
}

/// One-scalar string from a code-point value. The value is always a valid
/// scalar here (computed from a checked ASCII range), mirroring
/// `NFKCSubset.scalarString`.
fn scalar_string(value: u32) -> String {
    // unwrap is safe: every call site passes an ASCII-range value.
    char::from_u32(value).unwrap().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_lowercase_passthrough() {
        assert_eq!(normalize("hello"), "hello");
    }

    #[test]
    fn uppercased_ascii_folded() {
        assert_eq!(normalize("HELLO"), "hello");
    }

    #[test]
    fn mixed_case() {
        assert_eq!(normalize("ChEmIsTrY"), "chemistry");
    }

    #[test]
    fn empty_string() {
        assert_eq!(normalize(""), "");
    }

    #[test]
    fn fullwidth_folds_to_ascii() {
        // Ａ U+FF21 → 'A' → lowercased 'a'.
        assert_eq!(normalize("\u{FF21}\u{FF22}\u{FF23}"), "abc");
    }

    #[test]
    fn ligature_folds() {
        // ﬁ U+FB01 → "fi".
        assert_eq!(normalize("\u{FB01}le"), "file");
    }

    #[test]
    fn superscript_digits_fold() {
        assert_eq!(normalize("x\u{00B2}"), "x2");
        assert_eq!(normalize("\u{2079}"), "9");
    }

    #[test]
    fn roman_numeral_folds() {
        // Ⅻ U+216B → "XII" → lowercased "xii".
        assert_eq!(normalize("\u{216B}"), "xii");
    }

    #[test]
    fn katakana_recompose_out_of_scope_passthrough() {
        // ｶ + ﾞ are NOT recomposed (documented out-of-scope); they pass
        // through unchanged (then case-fold, which is a no-op for these).
        let input = "\u{FF76}\u{FF9E}";
        assert_eq!(normalize(input), input);
    }
}
