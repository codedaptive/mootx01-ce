//! Rust leg of the cross-language bit-identity gate for the
//! CorpusKitProviders text providers (B2-5: CorpusKit Rust embedding
//! parity).
//!
//! Reads the SAME canonical fixture the Swift leg emits
//! (Tests/SharedVectors/embedding_provider_vectors.json — Swift is the
//! canonical source) and asserts that the Rust MiniLM/mpnet/
//! EmbeddingGemma providers produce bit-identical token streams,
//! engrams, and float-lane vectors.
//!
//! The model inference pass and the real WordPiece/SentencePiece
//! tokenizers are host-supplied on BOTH ports, so the embedding VALUES
//! are not owned by either language. To prove the kit-owned pipeline
//! (tokenize → inference-seam → SimHash-project → engram) is identical
//! across ports without a model bundle, the fixture uses a PURE
//! inference function of the token IDs — `deterministic_inference`
//! below — that mirrors the Swift `deterministicInference` byte for
//! byte. Both ports independently compute the same pooled vector for
//! the same token stream, so any engram divergence is a real
//! projection/tokenizer drift, not model noise.

use corpus_kit_providers::{
    DeterministicTokenizer, EmbeddingGemmaProvider, MPNetTextProvider, MiniLMTextProvider,
};
use corpus_kit::Tokenizer;
use serde::Deserialize;
use vectorkit::EmbeddingProvider;

// The canonical file ships under Tests/SharedVectors/, two levels up
// from rust-providers/tests/. Embedded at compile time so the test has
// no runtime path dependency — same pattern as the BM25 conformance
// test (rust/tests/bm25_conformance_test.rs).
const FIXTURE: &[u8] =
    include_bytes!("../../Tests/SharedVectors/embedding_provider_vectors.json");

// MARK: - Canonical model (mirrors the Swift Codable structs)

#[derive(Deserialize)]
struct TokenizerVector {
    provider: String,
    input: String,
    tokens: Vec<i32>,
}

#[derive(Deserialize)]
struct EngramVector {
    provider: String,
    input: String,
    block0: u64,
    block1: u64,
    block2: u64,
    block3: u64,
    #[serde(rename = "floatBits")]
    float_bits: Vec<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalFile {
    tokenizer_vectors: Vec<TokenizerVector>,
    engram_vectors: Vec<EngramVector>,
}

// MARK: - Shared deterministic inference seam
//
// Pure function of the token IDs. MUST be byte-identical to the Swift
// `deterministicInference`. Uses only exact integer / f32 arithmetic
// (no transcendental functions) so the two ports cannot diverge on
// libm differences.
fn deterministic_inference(tokens: &[i32], dim: usize) -> Vec<f32> {
    let mut out = vec![0f32; dim];
    for (d, slot) in out.iter_mut().enumerate() {
        // Wrapping arithmetic is identical Swift/Rust. The multiplier
        // is the same odd constant the Swift leg uses.
        let mut acc: u64 = 0x9E37_79B9_7F4A_7C15u64.wrapping_mul((d as u64).wrapping_add(1));
        for &t in tokens {
            // Token ids are non-negative; the Swift leg reinterprets
            // the Int32 bit pattern as UInt32 then widens. `t as u32`
            // is the identical reinterpretation in Rust.
            acc = acc.wrapping_mul(1099511628211).wrapping_add(t as u32 as u64);
        }
        let residue = (acc % 65536) as i32 - 32768;
        *slot = residue as f32 / 32768f32;
    }
    out
}

// MARK: - Tokenizer params per provider (mirror the Swift defaults)

fn tokenizer_for(provider: &str) -> DeterministicTokenizer {
    match provider {
        "minilm" => DeterministicTokenizer::with_parameters("minilm-l6-v2", 30_522, 128),
        "mpnet" => DeterministicTokenizer::with_parameters("mpnet-base", 30_522, 128),
        "embedding-gemma" => {
            DeterministicTokenizer::with_parameters("embedding-gemma-300m", 256_000, 2048)
        }
        other => panic!("unknown provider in fixture: {other}"),
    }
}

fn dim_for(provider: &str) -> usize {
    match provider {
        "minilm" => 384,
        "mpnet" | "embedding-gemma" => 768,
        other => panic!("unknown provider in fixture: {other}"),
    }
}

fn make_provider(provider: &str) -> Box<dyn EmbeddingProvider> {
    let dim = dim_for(provider);
    let inference = move |tokens: &[i32]| Ok(deterministic_inference(tokens, dim));
    match provider {
        "minilm" => Box::new(MiniLMTextProvider::new(inference)),
        "mpnet" => Box::new(MPNetTextProvider::new(inference)),
        "embedding-gemma" => Box::new(EmbeddingGemmaProvider::new(inference)),
        other => panic!("unknown provider in fixture: {other}"),
    }
}

fn load_canonical() -> CanonicalFile {
    serde_json::from_slice(FIXTURE).expect("canonical embedding fixture must parse")
}

// MARK: - CHECK 1: tokenizer streams match the canonical

#[test]
fn rust_tokenizer_matches_canonical() {
    let canonical = load_canonical();
    assert!(
        !canonical.tokenizer_vectors.is_empty(),
        "fixture must carry tokenizer vectors"
    );
    let mut failures = Vec::new();
    for v in &canonical.tokenizer_vectors {
        let tok = tokenizer_for(&v.provider);
        let got = tok.tokenize(&v.input);
        if got != v.tokens {
            failures.push(format!(
                "{}/{:?}: expected {:?} got {:?}",
                v.provider, v.input, v.tokens, got
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "tokenizer drift ({} cases):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// MARK: - CHECK 2: full pipeline engrams + float lane match the canonical

#[test]
fn rust_providers_match_canonical_engrams() {
    let canonical = load_canonical();
    assert!(
        !canonical.engram_vectors.is_empty(),
        "fixture must carry engram vectors"
    );
    let mut failures = Vec::new();
    for v in &canonical.engram_vectors {
        let provider = make_provider(&v.provider);

        let engram = provider.embed(&v.input).expect("embed must not fail on fixture input");
        let (b0, b1, b2, b3) = (
            engram.block(0),
            engram.block(1),
            engram.block(2),
            engram.block(3),
        );
        if (b0, b1, b2, b3) != (v.block0, v.block1, v.block2, v.block3) {
            failures.push(format!(
                "engram {}/{:?}: expected blocks ({:#x},{:#x},{:#x},{:#x}) got ({b0:#x},{b1:#x},{b2:#x},{b3:#x})",
                v.provider, v.input, v.block0, v.block1, v.block2, v.block3
            ));
        }

        let floats = provider
            .embed_float(&v.input)
            .expect("embed_float must not fail on fixture input");
        let got_bits: Vec<u32> = floats.iter().map(|f| f.to_bits()).collect();
        if got_bits != v.float_bits {
            failures.push(format!(
                "float-lane {}/{:?}: {} bits expected, {} got (or content drift)",
                v.provider,
                v.input,
                v.float_bits.len(),
                got_bits.len()
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "provider drift ({} cases):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// MARK: - CHECK 3: empty input is the zero engram on the Rust side

#[test]
fn rust_empty_input_is_zero_engram() {
    let canonical = load_canonical();
    let mut saw_empty = false;
    for v in &canonical.engram_vectors {
        if v.input.is_empty() {
            saw_empty = true;
            let provider = make_provider(&v.provider);
            let engram = provider.embed("").expect("empty embed must not fail");
            assert_eq!(
                (engram.block(0), engram.block(1), engram.block(2), engram.block(3)),
                (0, 0, 0, 0),
                "{}: empty input must be Engram::ZERO",
                v.provider
            );
            // Float lane: empty input yields an empty vector.
            assert!(
                provider.embed_float("").expect("empty embed_float must not fail").is_empty(),
                "{}: empty input float lane must be empty",
                v.provider
            );
        }
    }
    assert!(saw_empty, "fixture must include the empty-input case");
}
