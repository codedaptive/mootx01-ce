// tokenizer.rs — UAX #29 word-boundary tokenization
//
// Port of Tokenizer.swift, which uses Foundation's `String.enumerateSubstrings
// (in:options:.byWords)` → ICU UAX #29.
//
// This Rust port uses the `unicode-segmentation` crate (unicode_word_indices),
// which also implements UAX #29. Both implementations produce byte-identical
// output for the ASCII/Latin inputs in the bundled artifacts and the
// conformance corpus. Foundation's `.byWords` additionally treats ASCII
// colon as a separator where `unicode-segmentation` retains it as UAX #29
// MidLetter punctuation, so the Rust seam applies that compatibility split.
//
// The tokenizer returns only non-empty word tokens, dropping whitespace,
// punctuation, and word separators — matching the Swift contract.

use unicode_segmentation::UnicodeSegmentation;

/// Tokenize a string into Unicode words (UAX #29).
/// Whitespace, punctuation, and separators are dropped; tokens returned in
/// input order. Mirrors `Tokenizer.tokenize` in Swift.
pub fn tokenize(text: &str) -> Vec<String> {
    text.unicode_words()
        .flat_map(|word| word.split(':'))
        .filter(|word| !word.is_empty())
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_on_whitespace() {
        let tokens = tokenize("computer science");
        assert_eq!(tokens, vec!["computer", "science"]);
    }

    #[test]
    fn drops_punctuation() {
        let tokens = tokenize("hello, world!");
        assert_eq!(tokens, vec!["hello", "world"]);
    }

    #[test]
    fn empty_input() {
        assert!(tokenize("").is_empty());
    }

    #[test]
    fn whitespace_only() {
        assert!(tokenize("   ").is_empty());
    }

    #[test]
    fn single_word() {
        assert_eq!(tokenize("chemistry"), vec!["chemistry"]);
    }

    #[test]
    fn matches_foundation_by_words_for_ascii_colon() {
        assert_eq!(
            tokenize("TASK:VERIFY|FILES:hydration.rs"),
            vec!["TASK", "VERIFY", "FILES", "hydration.rs"]
        );
    }
}
