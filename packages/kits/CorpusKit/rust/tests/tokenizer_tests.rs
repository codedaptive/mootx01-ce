// Tests for corpus-kit's `Tokenizer` trait + `default_keyword_tokens`.
// The `DeterministicTokenizer` test stub lives in the sibling
// `corpus-kit-providers` crate and has its own tests there.

use corpus_kit::default_keyword_tokens;

#[test]
fn default_keyword_tokens_lowercases_and_splits() {
    let toks = default_keyword_tokens("Hello, World! 2024");
    assert_eq!(toks, vec!["hello", "world", "2024"]);
}

#[test]
fn default_keyword_tokens_empty_input() {
    assert!(default_keyword_tokens("").is_empty());
}

#[test]
fn default_keyword_tokens_punctuation_only_input() {
    assert!(default_keyword_tokens("!!!,,,..").is_empty());
}
