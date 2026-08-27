//! Post-mint validation gate for adornment strings.
//!
//! Pure, deterministic validators — model-free and side-effect-free.
//! The minting model proposes; these validators certify. The minting
//! model NEVER certifies its own output (architecture ruling, Apple RCA
//! DDE22E7B 2026-08-22).
//!
//! Ports `AdornmentValidators.swift` field-for-field. Both ports carry the
//! same golden-pin fixture (AV-1 through AV-8) that forms the four-way
//! conformance gate.
//!
//! Golden-pin labels AV-1..AV-8 renamed from the superseded MV-1..MV-8
//! of MarkerValidators; logic and fixture values are identical.
//!
//! No external dependencies (C-1). Word-boundary detection uses a pure
//! byte-level scan: a match is at a word boundary when the character
//! immediately before is non-alphanumeric (or start-of-string) AND the
//! character immediately after is non-alphanumeric (or end-of-string).
//! Matching is case-folded with `to_lowercase()` on both sides so
//! "Newton" certifies against "newton" and "NEWTON" in source text.
//!
//! Rule references:
//!   - Word-boundary containment: mirrors the judge-audit primitive (SPEC_ADORNMENT §3).
//!   - Count validation: exact integer equality (no fuzzy tolerance).
//!   - Date validation: year-token equivalence (same heuristic as Swift).
//!   - Determinism mandate: no `SystemTime::now()` inside these functions.

use std::collections::HashSet;

// MARK: - Containment

/// Returns `true` when `entity` appears in `source_text` at a word boundary.
///
/// Case-insensitive. "Newton" inside "Newtonian" does NOT match because
/// 'i' (alphanumeric) immediately follows the match end.
/// An empty `entity` always returns `false`.
///
/// A "word boundary" is: the character immediately before the match is
/// non-alphanumeric (or the match starts at position 0) AND the character
/// immediately after the match is non-alphanumeric (or the match ends at
/// the end of the string).
///
/// Mirrors `AdornmentValidators.containsWordBoundary(entity:in:)` in Swift.
pub fn contains_word_boundary(entity: &str, source_text: &str) -> bool {
    if entity.is_empty() {
        return false;
    }
    let entity_lower = entity.to_lowercase();
    let source_lower = source_text.to_lowercase();
    let source_chars: Vec<char> = source_lower.chars().collect();
    let entity_chars: Vec<char> = entity_lower.chars().collect();
    let elen = entity_chars.len();
    let slen = source_chars.len();

    for start in 0..slen {
        if start + elen > slen {
            break;
        }
        // Check if source[start..start+elen] == entity (already lowercased).
        if source_chars[start..start + elen] != entity_chars[..] {
            continue;
        }
        // Check left boundary: position before `start` must be non-alphanumeric
        // or be start of string.
        let left_ok = if start == 0 {
            true
        } else {
            !source_chars[start - 1].is_alphanumeric()
        };
        // Check right boundary: position after `start + elen` must be
        // non-alphanumeric or be end of string.
        let right_ok = if start + elen == slen {
            true
        } else {
            !source_chars[start + elen].is_alphanumeric()
        };
        if left_ok && right_ok {
            return true;
        }
    }
    false
}

// MARK: - Count

/// Returns `true` when `expected_count` appears word-bounded in both
/// `claim` AND `source_text`.
///
/// The count must be grounded in the source — a model-hallucinated
/// count that does not appear in any source is rejected.
///
/// Mirrors `AdornmentValidators.validateCount(claim:in:expectedCount:)`.
pub fn validate_count(claim: &str, source_text: &str, expected_count: i64) -> bool {
    let count_str = expected_count.to_string();
    // Count must appear in the claim at a word boundary.
    if !contains_word_boundary(&count_str, claim) {
        return false;
    }
    // Count must also be grounded in the source at a word boundary.
    contains_word_boundary(&count_str, source_text)
}

// MARK: - Date

/// Returns `true` when at least one year token in `claim` is also present
/// in `source_text` (year-level equivalence, 1000–2099 range).
///
/// When `claim` contains no year-like token, returns `true` vacuously —
/// callers only invoke this when the claim references a date.
///
/// Mirrors `AdornmentValidators.validateDate(claim:in:)`.
pub fn validate_date(claim: &str, source_text: &str) -> bool {
    let claim_years = extract_years(claim);
    if claim_years.is_empty() {
        // No year in claim → vacuous pass.
        return true;
    }
    let source_years = extract_years(source_text);
    // At least one claim year must appear in source.
    claim_years.iter().any(|y| source_years.contains(y))
}

// MARK: - Internal helpers

/// Extract all 4-digit tokens in the 1000–2099 range from `text` that
/// appear at word boundaries. Returns a `HashSet<i32>`.
///
/// Uses the same boundary rule as `contains_word_boundary`: the character
/// before the 4-digit run must be non-alphanumeric (or start-of-string)
/// AND the character after must be non-alphanumeric (or end-of-string).
fn extract_years(text: &str) -> HashSet<i32> {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let mut years = HashSet::new();

    // Slide a window of 4 over the character array.
    let mut i = 0;
    while i + 4 <= len {
        // All four chars must be ASCII digits.
        if chars[i].is_ascii_digit()
            && chars[i + 1].is_ascii_digit()
            && chars[i + 2].is_ascii_digit()
            && chars[i + 3].is_ascii_digit()
        {
            // Ensure word boundary on both sides.
            let left_ok = i == 0 || !chars[i - 1].is_alphanumeric();
            let right_ok = i + 4 == len || !chars[i + 4].is_alphanumeric();
            if left_ok && right_ok {
                // Parse the four-digit run.
                let s: String = chars[i..i + 4].iter().collect();
                if let Ok(year) = s.parse::<i32>() {
                    if (1000..=2099).contains(&year) {
                        years.insert(year);
                    }
                }
            }
            // Skip past this run to avoid overlapping matches on digit
            // sequences longer than 4 (e.g. "16870" should not produce 1687).
            i += 4;
            continue;
        }
        i += 1;
    }
    years
}

// MARK: - Tests (golden pin AV-1 through AV-8)
//
// GOLDEN PIN — these fixtures are identical to those in
// `AdornmentValidatorsTests.swift` in the Swift port.
// Any change here must be mirrored there and vice versa.
// Labels AV-1..AV-8 renamed from superseded MV-1..MV-8 of MarkerValidators;
// logic and fixture values are identical.

#[cfg(test)]
mod tests {
    use super::*;

    // AV-1: "Newton" appears as a whole word in the source text.
    #[test]
    fn av1_contains_word_boundary_present() {
        let source = "Isaac Newton published his laws in 1687.";
        assert!(contains_word_boundary("Newton", source));
    }

    // AV-2: "Newton" appears only inside "Newtonian" — not a word boundary.
    #[test]
    fn av2_contains_word_boundary_substring_only() {
        let source = "Newtonian mechanics underpins classical physics.";
        assert!(!contains_word_boundary("Newton", source));
    }

    // AV-3: empty entity string → false.
    #[test]
    fn av3_contains_word_boundary_empty_entity() {
        let source = "Any source text here.";
        assert!(!contains_word_boundary("", source));
    }

    // AV-4: count 25 present in both claim and source.
    #[test]
    fn av4_validate_count_valid() {
        let claim = "Newton published 25 papers between 1665 and 1687.";
        let source = "Historians estimate Newton wrote 25 scientific papers.";
        assert!(validate_count(claim, source, 25));
    }

    // AV-5: count 42 in claim but absent from source → false.
    #[test]
    fn av5_validate_count_not_in_source() {
        let claim = "Newton published 42 papers.";
        let source = "Historians estimate Newton wrote 25 scientific papers.";
        assert!(!validate_count(claim, source, 42));
    }

    // AV-6: year 1687 present in both claim and source.
    #[test]
    fn av6_validate_date_valid() {
        let claim = "Newton published the Principia in 1687.";
        let source = "The Principia Mathematica was released in 1687 by Isaac Newton.";
        assert!(validate_date(claim, source));
    }

    // AV-7: year 1702 in claim absent from source → false.
    #[test]
    fn av7_validate_date_year_not_in_source() {
        let claim = "Newton discovered gravity in 1702.";
        let source = "The apple incident is dated to 1666 in Newton's notebooks.";
        assert!(!validate_date(claim, source));
    }

    // AV-8: no year in claim → vacuous true.
    #[test]
    fn av8_validate_date_no_year() {
        let claim = "Newton invented calculus.";
        let source = "Newton and Leibniz independently developed calculus.";
        assert!(validate_date(claim, source));
    }
}
