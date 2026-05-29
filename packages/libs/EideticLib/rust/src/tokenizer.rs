//! UAX #29 word-boundary tokenization. Pure wrapper over the
//! `unicode-segmentation` crate's `UnicodeSegmentation::unicode_words`
//! iterator, which implements the Unicode Standard Annex #29
//! word-boundary rules. Deterministic, no_std-compatible
//! upstream.

use unicode_segmentation::UnicodeSegmentation;

/// Tokenize a string into Unicode words. Whitespace, punctuation,
/// and word separators are dropped; words are returned in input
/// order.
pub fn tokenize(text: &str) -> Vec<String> {
    text.unicode_words().map(|s| s.to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_string_yields_no_tokens() {
        assert!(tokenize("").is_empty());
    }

    #[test]
    fn simple_english_phrase_tokenizes() {
        let tokens = tokenize("organic chemistry research");
        assert_eq!(tokens, vec!["organic", "chemistry", "research"]);
    }

    #[test]
    fn punctuation_dropped() {
        let tokens = tokenize("Hello, world! How are you?");
        assert_eq!(
            tokens,
            vec!["Hello", "world", "How", "are", "you"]
        );
    }

    #[test]
    fn multi_script_handled() {
        // Mixed Latin and Cyrillic, with punctuation between.
        let tokens = tokenize("Hello, мир!");
        assert_eq!(tokens, vec!["Hello", "мир"]);
    }

    #[test]
    fn determinism_holds() {
        let a = tokenize("the quick brown fox");
        let b = tokenize("the quick brown fox");
        assert_eq!(a, b);
    }
}
