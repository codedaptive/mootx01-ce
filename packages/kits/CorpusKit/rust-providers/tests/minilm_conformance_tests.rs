//! Rust leg of the cross-language bit-identity gate for `MiniLMTextProvider`
//! (B2-1: CorpusKit Rust MiniLM parity).
//!
//! Reads the canonical fixture the Swift leg emits
//! (`Tests/SharedVectors/embedding_provider_vectors.json`) and asserts that
//! the Rust `MiniLMTextProvider` produces bit-identical token streams,
//! engrams, and float-lane vectors for the `"minilm"` rows. MPNet and
//! EmbeddingGemma rows are skipped — those providers are retired.
//!
//! The model inference pass and the real WordPiece tokenizer are
//! host-supplied on BOTH ports, so the embedding VALUES are not owned by
//! either language. To prove the kit-owned pipeline
//! (tokenize → inference-seam → SimHash-project → engram) is identical
//! across ports without a model bundle, the fixture uses a PURE
//! inference function of the token IDs — `deterministic_inference` below —
//! that mirrors the Swift `deterministicInference` byte for byte.

use corpus_kit_providers::{DeterministicTokenizer, MiniLMTextProvider};
use corpus_kit::Tokenizer;
use serde::Deserialize;
use synapsekit::EmbeddingProvider;

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
fn deterministic_inference(tokens: &[i32]) -> Vec<f32> {
    let dim = 384;
    let mut out = vec![0f32; dim];
    for (d, slot) in out.iter_mut().enumerate() {
        let mut acc: u64 = 0x9E37_79B9_7F4A_7C15u64.wrapping_mul((d as u64).wrapping_add(1));
        for &t in tokens {
            acc = acc.wrapping_mul(1099511628211).wrapping_add(t as u32 as u64);
        }
        let residue = (acc % 65536) as i32 - 32768;
        *slot = residue as f32 / 32768f32;
    }
    out
}

fn load_canonical() -> CanonicalFile {
    serde_json::from_slice(FIXTURE).expect("canonical embedding fixture must parse")
}

// MARK: - CHECK 1: tokenizer streams match the canonical

#[test]
fn minilm_tokenizer_matches_canonical() {
    let canonical = load_canonical();
    let minilm_rows: Vec<_> = canonical
        .tokenizer_vectors
        .iter()
        .filter(|v| v.provider == "minilm")
        .collect();
    assert!(
        !minilm_rows.is_empty(),
        "fixture must carry minilm tokenizer vectors"
    );
    let tok = DeterministicTokenizer::with_parameters("minilm-l6-v2", 30_522, 128);
    let mut failures = Vec::new();
    for v in &minilm_rows {
        let got = tok.tokenize(&v.input);
        if got != v.tokens {
            failures.push(format!(
                "{:?}: expected {:?} got {:?}",
                v.input, v.tokens, got
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "MiniLM tokenizer drift ({} cases):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// MARK: - CHECK 2: full pipeline engrams + float lane match the canonical

#[test]
fn minilm_matches_canonical_engrams() {
    let canonical = load_canonical();
    let minilm_rows: Vec<_> = canonical
        .engram_vectors
        .iter()
        .filter(|v| v.provider == "minilm")
        .collect();
    assert!(
        !minilm_rows.is_empty(),
        "fixture must carry minilm engram vectors"
    );
    let provider = MiniLMTextProvider::new(|tokens| Ok(deterministic_inference(tokens)));
    let mut failures = Vec::new();
    for v in &minilm_rows {
        let engram = provider.embed(&v.input).expect("embed must not fail on fixture input");
        let (b0, b1, b2, b3) = (
            engram.block(0),
            engram.block(1),
            engram.block(2),
            engram.block(3),
        );
        if (b0, b1, b2, b3) != (v.block0, v.block1, v.block2, v.block3) {
            failures.push(format!(
                "engram {:?}: expected blocks ({:#x},{:#x},{:#x},{:#x}) got ({b0:#x},{b1:#x},{b2:#x},{b3:#x})",
                v.input, v.block0, v.block1, v.block2, v.block3
            ));
        }
        let floats = provider
            .embed_float(&v.input)
            .expect("embed_float must not fail on fixture input");
        let got_bits: Vec<u32> = floats.iter().map(|f| f.to_bits()).collect();
        if got_bits != v.float_bits {
            failures.push(format!(
                "float-lane {:?}: {} bits expected, {} got (or content drift)",
                v.input,
                v.float_bits.len(),
                got_bits.len()
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "MiniLM provider drift ({} cases):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// MARK: - CHECK 3: empty input is the zero engram on the Rust side

#[test]
fn minilm_empty_input_is_zero_engram() {
    let canonical = load_canonical();
    let empty_rows: Vec<_> = canonical
        .engram_vectors
        .iter()
        .filter(|v| v.provider == "minilm" && v.input.is_empty())
        .collect();
    assert!(!empty_rows.is_empty(), "fixture must include the minilm empty-input case");
    let provider = MiniLMTextProvider::new(|tokens| Ok(deterministic_inference(tokens)));
    for v in &empty_rows {
        let engram = provider.embed("").expect("empty embed must not fail");
        assert_eq!(
            (engram.block(0), engram.block(1), engram.block(2), engram.block(3)),
            (0, 0, 0, 0),
            "empty input must be Engram::ZERO"
        );
        assert!(
            provider.embed_float("").expect("empty embed_float must not fail").is_empty(),
            "empty input float lane must be empty"
        );
    }
}
