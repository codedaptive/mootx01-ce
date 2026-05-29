//! `DeterministicTokenizer` -- Rust port of Swift's
//! `CorpusKitProviders.DeterministicTokenizer`. A documented stub:
//! token IDs are derived from an FNV-1a fold over the keyword
//! string, so the result is stable per token but does NOT
//! correspond to any model vocabulary.
//!
//! Useful for:
//! - Exercising the `Tokenizer::keyword_tokens` path (BM25
//!   indexing, hybrid recall fixtures) -- the default impl
//!   lowercases and splits on Unicode word boundaries.
//! - Cross-language conformance harnesses where Swift and Rust
//!   both produce stable hash IDs from the same input.
//!
//! NOT useful for:
//! - Feeding `tokenize()` output into a real embedding model.
//!   The IDs do not match any WordPiece or SentencePiece
//!   vocabulary; the model will produce garbage embeddings.
//!   Use a real `corpus_kit_providers` tokenizer once model
//!   bundles ship.

use corpus_kit::Tokenizer;

/// Vocabulary size that matches the Swift default. Mirrors the
/// BERT WordPiece vocabulary cardinality so a future real
/// `MiniLM` tokenizer with the same `vocab_id` produces ids in
/// the same range -- callers cannot use that compatibility to
/// substitute the stub for a real tokenizer, but tooling that
/// histograms ids by frequency-bucket stays comparable.
const DEFAULT_VOCAB_SIZE: u32 = 30_522;

/// Maximum sequence length matching Swift's default.
const DEFAULT_MAX_TOKENS: usize = 128;

pub struct DeterministicTokenizer {
    vocab_id: String,
    vocab_size: u32,
    max_tokens: usize,
}

impl DeterministicTokenizer {
    /// Construct with the default `vocab_id = "deterministic-v1"`,
    /// `vocab_size = 30522`, `max_tokens = 128`. Matches Swift.
    pub fn new() -> Self {
        DeterministicTokenizer {
            vocab_id: "deterministic-v1".to_string(),
            vocab_size: DEFAULT_VOCAB_SIZE,
            max_tokens: DEFAULT_MAX_TOKENS,
        }
    }

    /// Construct with custom parameters. Used by tests that
    /// pin a specific vocab size or sequence length.
    pub fn with_parameters(
        vocab_id: impl Into<String>,
        vocab_size: u32,
        max_tokens: usize,
    ) -> Self {
        DeterministicTokenizer {
            vocab_id: vocab_id.into(),
            vocab_size,
            max_tokens,
        }
    }
}

impl Default for DeterministicTokenizer {
    fn default() -> Self {
        Self::new()
    }
}

impl Tokenizer for DeterministicTokenizer {
    fn vocab_id(&self) -> &str {
        &self.vocab_id
    }

    fn max_tokens(&self) -> usize {
        self.max_tokens
    }

    fn pad_token_id(&self) -> i32 {
        0
    }

    fn unknown_token_id(&self) -> i32 {
        1
    }

    fn tokenize(&self, text: &str) -> Vec<i32> {
        // Use the keyword-tokens path so tokenize() and
        // keyword_tokens() agree on which strings get IDs --
        // matches the Swift impl exactly.
        let words = corpus_kit::default_keyword_tokens(text);
        let mut out = Vec::with_capacity(words.len().min(self.max_tokens));
        for word in words {
            out.push(stable_token_id(&word, self.vocab_size));
            if out.len() >= self.max_tokens {
                break;
            }
        }
        if out.is_empty() {
            out.push(0); // pad token sentinel; matches Swift
        }
        out
    }
}

/// FNV-1a 32-bit (SubstrateLib, I-25), modded into the tokenizer's
/// id range with ids 0/1 reserved for PAD/UNK. Byte-identical to the
/// Swift `DeterministicTokenizer.tokenize` because both consume the
/// same substrate atomic.
fn stable_token_id(token: &str, vocab_size: u32) -> i32 {
    let hash = substrate_types::fnv::hash32(token);
    let id = (hash % (vocab_size - 2)) + 2;
    id as i32
}
