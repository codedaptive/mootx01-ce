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

#[test]
fn default_keyword_tokens_lowercases_greek_sigma_without_context() {
    assert_eq!(
        default_keyword_tokens("embeddings from U·Σ"),
        vec!["embeddings", "from", "u", "σ",]
    );
}

#[test]
fn final_sigma_folds_to_medial_sigma_cross_port() {
    let tokens = default_keyword_tokens("ΟΔΥΣΣΕΥΣ and ς alone");
    assert_eq!(tokens, vec!["οδυσσευσ", "and", "σ", "alone"]);
    assert_eq!(
        tokens[0].as_bytes(),
        &[
            0xCE, 0xBF, 0xCE, 0xB4, 0xCF, 0x85, 0xCF, 0x83, 0xCF, 0x83, 0xCE, 0xB5,
            0xCF, 0x85, 0xCF, 0x83,
        ]
    );
}
