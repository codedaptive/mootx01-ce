//! The candle cross encoder against the lab's reference fixture: pair token
//! ids identical to the Swift `tokenizePair` pins, and logits within 1e-4 of
//! the PyTorch FP32 reference. Assets are never in git: set
//! `MOOT_CROSS_ENCODER_ASSETS` to a build-all output root (with `linux/`)
//! to enable; every test skips otherwise.
//!
//! Failure modes: a pair encode that pads or truncates differently from the
//! reference (`longest_first`), a classifier head read from the wrong
//! prefix, a pooler without the tanh.

use std::path::PathBuf;

use corpus_kit::encoder::CrossEncoderProfile;
use corpus_kit_providers::candle_pair_scorer::{encode_pair, pair_tokenizer};
use corpus_kit_providers::PairScorerFactory;

fn packaged_linux_dir() -> Option<PathBuf> {
    let root = std::env::var_os("MOOT_CROSS_ENCODER_ASSETS")?;
    let dir = PathBuf::from(root).join("linux");
    dir.is_dir().then_some(dir)
}

const CAPITAL: &str = "What is the capital of France?";
const BOILING: &str = "At what temperature does water boil at standard pressure?";
const PET: &str = "What kind of animal is a domestic cat?";
const PARIS0: &str = "Paris is the capital city of France.";
const PARIS1: &str = "Paris stands on the river Seine.";
const BERLIN: &str = "Berlin is the capital city of Germany.";
const WATER: &str = "At standard atmospheric pressure, pure water boils at 100 degrees Celsius.";
const CAT: &str = "A domestic cat is a small carnivorous mammal often kept as a pet.";

/// The same ids `PairTokenizerTests.swift` pins.
const CAPITAL_PARIS0: &[u32] = &[101, 2054, 2003, 1996, 3007, 1997, 2605, 1029, 102, 3000, 2003, 1996, 3007, 2103, 1997, 2605, 1012, 102];
const BOILING_WATER: &[u32] = &[101, 2012, 2054, 4860, 2515, 2300, 26077, 2012, 3115, 3778, 1029, 102, 2012, 3115, 12483, 3778, 1010, 5760, 2300, 26077, 2015, 2012, 2531, 5445, 8292, 4877, 4173, 1012, 102];
const BOILING_WATER_16: &[u32] = &[101, 2012, 2054, 4860, 2515, 2300, 26077, 102, 2012, 3115, 12483, 3778, 1010, 5760, 2300, 102];
const BOILING_WATER_15: &[u32] = &[101, 2012, 2054, 4860, 2515, 2300, 26077, 102, 2012, 3115, 12483, 3778, 1010, 5760, 102];

#[test]
fn pair_tokens_match_the_swift_pins() {
    let Some(dir) = packaged_linux_dir() else {
        eprintln!("SKIP: MOOT_CROSS_ENCODER_ASSETS not set");
        return;
    };
    let t = pair_tokenizer(&dir, 512).unwrap();
    let (ids, types) = encode_pair(&t, CAPITAL, PARIS0).unwrap();
    assert_eq!(ids, CAPITAL_PARIS0);
    assert_eq!(types, [vec![0u32; 9], vec![1u32; 9]].concat());
    let (ids, types) = encode_pair(&t, BOILING, WATER).unwrap();
    assert_eq!(ids, BOILING_WATER);
    assert_eq!(types, [vec![0u32; 12], vec![1u32; 17]].concat());

    let (ids, types) = encode_pair(&pair_tokenizer(&dir, 16).unwrap(), BOILING, WATER).unwrap();
    assert_eq!(ids, BOILING_WATER_16);
    assert_eq!(types, [vec![0u32; 8], vec![1u32; 8]].concat());
    let (ids, _) = encode_pair(&pair_tokenizer(&dir, 15).unwrap(), BOILING, WATER).unwrap();
    assert_eq!(ids, BOILING_WATER_15);
}

#[test]
fn loaded_classifier_reproduces_the_reference_logits() {
    let Some(dir) = packaged_linux_dir() else {
        eprintln!("SKIP: MOOT_CROSS_ENCODER_ASSETS not set");
        return;
    };
    let scorer = PairScorerFactory::make(&CrossEncoderProfile::minilm_l6(), &dir).unwrap();
    let reference: [(&str, &str, f32); 7] = [
        (CAPITAL, PARIS0, 8.089582443237305),
        (CAPITAL, PARIS1, -2.3964743614196777),
        (CAPITAL, BERLIN, -3.6770708560943604),
        (BOILING, WATER, 9.275367736816406),
        (BOILING, CAT, -11.256487846374512),
        (PET, CAT, 8.426995277404785),
        (PET, PARIS0, -11.166393280029297),
    ];
    for (query, span, expected) in reference {
        let logits = scorer.score(query, &[span]).unwrap();
        assert_eq!(logits.len(), 1);
        assert!((logits[0] - expected).abs() < 1e-4, "{query} / {span}: {} vs {expected}", logits[0]);
    }
    // Batched scoring (pad-to-longest within the batch) returns the same
    // values in span order.
    let batch = scorer.score(CAPITAL, &[PARIS0, PARIS1, BERLIN]).unwrap();
    assert_eq!(batch.len(), 3);
    assert!((batch[0] - 8.089582443237305).abs() < 1e-4);
    assert!((batch[1] - -2.3964743614196777).abs() < 1e-4);
    assert!((batch[2] - -3.6770708560943604).abs() < 1e-4);
}
