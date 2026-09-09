//! The candle cross encoder against the lab's reference fixture: pair token
//! ids identical to the Swift `tokenizePair` pins, and logits within 1e-4 of
//! the PyTorch FP32 reference. Assets are never in git: set
//! `MOOT_CROSS_ENCODER_ASSETS` to a build-all output root (with `linux/`)
//! to enable the classifier tests; every test that needs model files skips
//! otherwise.
//!
//! The id parity arrays live in the shared fixture:
//!   packages/kits/SynapseKit/Tests/Fixtures/encoder/cross_encoder_tokenizer_parity.json
//! Both ports (Swift `PairTokenizerTests.swift` and this file) read the same
//! JSON, so the ground-truth values are not duplicated.
//!
//! Failure modes: a pair encode that pads or truncates differently from the
//! reference (`longest_first`), a classifier head read from the wrong
//! prefix, a pooler without the tanh.

use std::collections::HashMap;
use std::path::PathBuf;

use corpus_kit::encoder::CrossEncoderProfile;
use corpus_kit_providers::candle_pair_scorer::{encode_pair, pair_tokenizer};
use corpus_kit_providers::PairScorerFactory;

fn packaged_linux_dir() -> Option<PathBuf> {
    let root = std::env::var_os("MOOT_CROSS_ENCODER_ASSETS")?;
    let dir = PathBuf::from(root).join("linux");
    dir.is_dir().then_some(dir)
}

// --- shared fixture loader ---

#[derive(serde::Deserialize)]
struct TokenizerParityPair {
    name: String,
    ids: Vec<u32>,
    query_token_count: usize,
    span_token_count: usize,
}

/// Shared fixture read by both ports. The `texts` map and the `pairs` array
/// are the single source of truth for all candle tests; neither is duplicated
/// as module-level constants.
#[derive(serde::Deserialize)]
struct TokenizerParityFixture {
    /// Query and span texts keyed by short label (e.g. "capital", "paris0").
    texts: HashMap<String, String>,
    pairs: Vec<TokenizerParityPair>,
}

impl TokenizerParityFixture {
    fn pair(&self, name: &str) -> &TokenizerParityPair {
        self.pairs.iter().find(|p| p.name == name)
            .unwrap_or_else(|| panic!("fixture pair '{name}' not found"))
    }

    fn text(&self, key: &str) -> &str {
        self.texts.get(key)
            .unwrap_or_else(|| panic!("fixture text '{key}' not found"))
    }
}

/// Load `cross_encoder_tokenizer_parity.json` from the shared fixture directory.
/// Uses `CARGO_MANIFEST_DIR` (the `rust-providers/` crate directory) to navigate
/// up to the repo root, matching the layout used by `pair_scorer_tests.rs`.
fn load_tokenizer_parity_fixture() -> TokenizerParityFixture {
    let crate_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let fixture = crate_dir
        .parent().unwrap() // CorpusKit/
        .parent().unwrap() // kits/
        .parent().unwrap() // packages/
        .parent().unwrap() // repo root
        .join("packages/kits/SynapseKit/Tests/Fixtures/encoder/cross_encoder_tokenizer_parity.json");
    let text = std::fs::read_to_string(&fixture)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", fixture.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("failed to parse tokenizer parity fixture: {e}"))
}

/// Pair token ids match the shared fixture (same file as Swift `PairTokenizerTests`).
///
/// Enable with: `MOOT_CROSS_ENCODER_ASSETS=<dir> cargo test --features candle -- --ignored`
#[test]
#[ignore]
fn pair_tokens_match_the_shared_fixture() {
    let dir = packaged_linux_dir().expect("MOOT_CROSS_ENCODER_ASSETS must be set to run ignored tests");
    let fixture = load_tokenizer_parity_fixture();

    let cp = fixture.pair("capital_paris0");
    let t512 = pair_tokenizer(&dir, 512).unwrap();
    let (ids, types) = encode_pair(&t512, fixture.text("capital"), fixture.text("paris0")).unwrap();
    assert_eq!(ids, cp.ids);
    assert_eq!(types, [vec![0u32; cp.query_token_count], vec![1u32; cp.span_token_count]].concat());

    let bw = fixture.pair("boiling_water");
    let (ids, types) = encode_pair(&t512, fixture.text("boiling"), fixture.text("water")).unwrap();
    assert_eq!(ids, bw.ids);
    assert_eq!(types, [vec![0u32; bw.query_token_count], vec![1u32; bw.span_token_count]].concat());

    let bw16 = fixture.pair("boiling_water_16");
    let (ids, types) = encode_pair(&pair_tokenizer(&dir, 16).unwrap(), fixture.text("boiling"), fixture.text("water")).unwrap();
    assert_eq!(ids, bw16.ids);
    assert_eq!(types, [vec![0u32; bw16.query_token_count], vec![1u32; bw16.span_token_count]].concat());

    let bw15 = fixture.pair("boiling_water_15");
    let (ids, _) = encode_pair(&pair_tokenizer(&dir, 15).unwrap(), fixture.text("boiling"), fixture.text("water")).unwrap();
    assert_eq!(ids, bw15.ids);
}

/// Enable with: `MOOT_CROSS_ENCODER_ASSETS=<dir> cargo test --features candle -- --ignored`
#[test]
#[ignore]
fn loaded_classifier_reproduces_the_reference_logits() {
    let dir = packaged_linux_dir().expect("MOOT_CROSS_ENCODER_ASSETS must be set to run ignored tests");
    let fixture = load_tokenizer_parity_fixture();
    let scorer = PairScorerFactory::make(&CrossEncoderProfile::minilm_l6(), &dir).unwrap();
    // Reference logits from PyTorch FP32, CPU; texts are read from the shared
    // fixture so there is one source of truth for the input strings.
    let reference: [(&str, &str, f32); 7] = [
        (fixture.text("capital"), fixture.text("paris0"), 8.089582443237305),
        (fixture.text("capital"), fixture.text("paris1"), -2.3964743614196777),
        (fixture.text("capital"), fixture.text("berlin"), -3.6770708560943604),
        (fixture.text("boiling"), fixture.text("water"), 9.275367736816406),
        (fixture.text("boiling"), fixture.text("cat"), -11.256487846374512),
        (fixture.text("pet"), fixture.text("cat"), 8.426995277404785),
        (fixture.text("pet"), fixture.text("paris0"), -11.166393280029297),
    ];
    for (query, span, expected) in reference {
        let logits = scorer.score(query, &[span]).unwrap();
        assert_eq!(logits.len(), 1);
        assert!((logits[0] - expected).abs() < 1e-4, "{query} / {span}: {} vs {expected}", logits[0]);
    }
    // Batched scoring (pad-to-longest within the batch) returns the same
    // values in span order.
    let batch = scorer.score(fixture.text("capital"), &[fixture.text("paris0"), fixture.text("paris1"), fixture.text("berlin")]).unwrap();
    assert_eq!(batch.len(), 3);
    assert!((batch[0] - 8.089582443237305).abs() < 1e-4);
    assert!((batch[1] - -2.3964743614196777).abs() < 1e-4);
    assert!((batch[2] - -3.6770708560943604).abs() < 1e-4);
}
