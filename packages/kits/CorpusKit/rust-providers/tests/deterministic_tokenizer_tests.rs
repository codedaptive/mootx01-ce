// Tests for `DeterministicTokenizer`. Stable identity, stable
// per-token ids, sentinel reservation, max-tokens truncation,
// pad fallback for empty input. Mirrors the Swift tests in
// `CorpusKit/Tests/CorpusKitProvidersTests/DeterministicTokenizerTests.swift`.

use corpus_kit::Tokenizer;
use corpus_kit_providers::DeterministicTokenizer;

#[test]
fn deterministic_tokenizer_identity() {
    let tk = DeterministicTokenizer::new();
    assert_eq!(tk.vocab_id(), "deterministic-v1");
    assert_eq!(tk.max_tokens(), 128);
    assert_eq!(tk.pad_token_id(), 0);
    assert_eq!(tk.unknown_token_id(), 1);
}

#[test]
fn deterministic_tokenizer_same_input_same_ids() {
    let tk = DeterministicTokenizer::new();
    let a = tk.tokenize("the quick brown fox");
    let b = tk.tokenize("the quick brown fox");
    assert_eq!(a, b);
    assert_eq!(a.len(), 4);
}

#[test]
fn deterministic_tokenizer_different_input_different_ids() {
    let tk = DeterministicTokenizer::new();
    let a = tk.tokenize("foo");
    let b = tk.tokenize("bar");
    assert_ne!(a, b);
}

#[test]
fn deterministic_tokenizer_ids_avoid_pad_unk_sentinels() {
    let tk = DeterministicTokenizer::new();
    let ids = tk.tokenize("apple banana cherry date elderberry");
    for id in ids {
        assert_ne!(id, 0, "must not collide with pad token");
        assert_ne!(id, 1, "must not collide with unknown token");
    }
}

#[test]
fn deterministic_tokenizer_truncates_to_max_tokens() {
    let tk = DeterministicTokenizer::with_parameters("test-v1", 30_522, 4);
    let ids = tk.tokenize("one two three four five six seven");
    assert_eq!(ids.len(), 4);
}

#[test]
fn deterministic_tokenizer_empty_input_yields_pad_token() {
    let tk = DeterministicTokenizer::new();
    let ids = tk.tokenize("");
    assert_eq!(ids, vec![tk.pad_token_id()]);
}

#[test]
fn deterministic_tokenizer_keyword_tokens_uses_default_impl() {
    // The trait default lowercases and splits on Unicode word
    // boundaries; DeterministicTokenizer doesn't override it.
    let tk = DeterministicTokenizer::new();
    let toks = tk.keyword_tokens("Hello, World! 2024");
    assert_eq!(toks, vec!["hello", "world", "2024"]);
}
