//! Tokenizer trait. Concrete implementations (BERT WordPiece for
//! MiniLM and mpnet, SentencePiece for EmbeddingGemma, and the
//! `DeterministicTokenizer` test stub) live in the sibling
//! `corpus-kit-providers` crate -- matches Swift's split between
//! `CorpusKit` and `CorpusKitProviders`. Core `corpus-kit` ships the trait
//! and the default `keyword_tokens` helper only.

pub trait Tokenizer: Send + Sync {
    /// Stable identifier for the tokenizer's vocabulary. Bumped
    /// when the vocab changes.
    fn vocab_id(&self) -> &str;

    /// Maximum sequence length the upstream model accepts.
    fn max_tokens(&self) -> usize;

    /// ID assigned to the [PAD] / padding token.
    fn pad_token_id(&self) -> i32;

    /// ID assigned to the [UNK] / unknown token.
    fn unknown_token_id(&self) -> i32;

    /// Tokenize text into model-ready IDs. Implementations are
    /// responsible for truncation to `max_tokens`.
    fn tokenize(&self, text: &str) -> Vec<i32>;

    /// Split text into BM25-style keyword tokens. Default
    /// implementation lowercases and splits on Unicode word
    /// boundaries.
    fn keyword_tokens(&self, text: &str) -> Vec<String> {
        default_keyword_tokens(text)
    }
}

/// Default keyword tokenization: lowercase and split on
/// Unicode word boundaries. Matches the Swift default in
/// `Tokenizer.keywordTokens`.
pub fn default_keyword_tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    for c in text.to_lowercase().chars() {
        if c.is_alphabetic() || c.is_ascii_digit() {
            current.push(c);
        } else if !current.is_empty() {
            out.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}
