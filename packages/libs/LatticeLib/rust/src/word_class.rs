// word_class.rs — Word class label for FDC encoder Step 1
//
// Port of WordClass.swift. The enum is string-backed (noun/verb/other) to match
// the Swift serialization contract and the shared conformance vectors.
//
// Also owns `NovelTokenTaggerChoice` (Layer-2a): the estate-creation-time
// selection of which novel-token tagger to use. Mirrors the identically-named
// type in PersistenceKit. On Rust, `NlTagger` is a schema-parity variant only —
// it is rejected at `EstateConfiguration` construction (PersistenceKit
// `new_with_tagger` returns an error for `NlTagger`). The tagging call path
// `word_class_with_tagger` treats `NlTagger` as a HMM fallback on Rust because
// no NaturalLanguage framework is available; this path is reached only when
// a configuration written by the Swift port is read back by Rust.

use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

/// The word class of a single token under FDC encoder Step 1.
/// `.other` is the discard bucket: any token the encoder will not carry forward.
/// String-backed so it serializes to the same JSON as the Swift port.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WordClass {
    Noun,
    Verb,
    Other,
}

// ---------------------------------------------------------------------------
// Deterministic HMM/Viterbi novel-token tagger (non-Apple path)
//
// Port of HMMTagger.swift. Model weights are loaded from the SAME frozen
// checked-in artifact both ports read:
//   ../../Sources/LatticeLib/Resources/HMMTaggerModel.json
// The JSON is embedded at compile time via `include_bytes!`, identical to
// the `qid_closure.rs` pattern. See HMMTagger.swift for the full contract
// and the training methodology (MASC 3.0.0 Penn Treebank, CC BY 3.0 US,
// the HMM-training ETL (EE build tooling)).
//
// CONTRACT (load-bearing): byte-identical to the Swift `HMMTagger.tag`.
// Scoring is INTEGER (fixed-point log-weights, scale 1000): pure add + max,
// no floating point, so the two ports cannot diverge. This is NOT required to
// match Apple's NLTagger — Apple and this HMM are different engines. The
// guarantee is cross-platform self-consistency of the non-Apple path. The
// shared fixture tests/fixtures/tag_conformance.json gates byte-identity.
// ---------------------------------------------------------------------------

/// The morphological observation alphabet. Mirrors `HMMTagger.Obs` in Swift;
/// the integer discriminants are part of the contract (emission columns).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Obs {
    NonAlpha = 0,
    SuffixIng = 1,
    SuffixEd = 2,
    SuffixIzeIse = 3,
    SuffixAte = 4,
    SuffixTion = 5,
    SuffixNess = 6,
    SuffixMent = 7,
    SuffixItyTy = 8,
    SuffixErOrAr = 9,
    SuffixLy = 10,
    Plain = 11,
}

/// Hidden states in fixed index order (0=noun, 1=verb, 2=other). The order is
/// part of the contract: the Viterbi tie-break favours the lowest index.
/// Mirrors `HMMTagger.states` in Swift.
const STATES: [WordClass; 3] = [WordClass::Noun, WordClass::Verb, WordClass::Other];

// ---------------------------------------------------------------------------
// Frozen model loading — include_bytes! at compile time, parsed once
// per process via OnceLock. Same pattern as qid_closure.rs.
//
// Artifact path is relative to this source file (the macro resolves relative
// to the source file location, not the crate root). The JSON lives at:
//   ../../Sources/LatticeLib/Resources/HMMTaggerModel.json
// which is correct for the position of this file at
//   packages/libs/LatticeLib/rust/src/word_class.rs
// ---------------------------------------------------------------------------

/// The on-disk schema of HMMTaggerModel.json. Snake_case matches the JSON
/// keys produced by the ETL script (sort_keys=True, Python snake_case).
#[derive(Deserialize)]
struct ModelArtifact {
    initial_weights: Vec<i32>,
    emission_weights: Vec<Vec<i32>>,
}

/// The embedded JSON bytes of HMMTaggerModel.json. Embedded at compile time;
/// the artifact is pinned in the repository alongside the Rust source.
static MODEL_BYTES: &[u8] =
    include_bytes!("../../Sources/LatticeLib/Resources/HMMTaggerModel.json");

/// The parsed model, initialized once per process. Falls back to the known
/// trained values if JSON parsing fails (build-time invariant — the artifact
/// is always present and correctly formed).
static MODEL: OnceLock<ModelArtifact> = OnceLock::new();

fn model() -> &'static ModelArtifact {
    MODEL.get_or_init(|| {
        serde_json::from_slice::<ModelArtifact>(MODEL_BYTES).unwrap_or_else(|_| {
            // Fallback: the trained values the artifact encodes (MASC 3.0.0,
            // hapax/rare-word estimated — see HMMTaggerModel.json). This path
            // should never be reached in a correctly built binary; it must
            // stay byte-identical to the JSON so a load failure cannot diverge
            // the ports.
            ModelArtifact {
                initial_weights: vec![-643, -1562, -1329],
                emission_weights: vec![
                    // noun
                    vec![-2954, -3606, -5526, -6132, -5978, -3103, -4746, -4260, -3898, -2867, -5621, -270],
                    // verb
                    vec![-4525, -1473, -1011, -4445, -3609, -6317, -7010, -6317, -7010, -4708, -6317, -1075],
                    // other
                    vec![-1125, -3874, -2898, -7241, -4843, -6548, -7241, -7241, -5162, -3528, -2160, -826],
                ],
            }
        })
    })
}

/// Tags a single lowercased token via integer Viterbi decode.
/// For one token this reduces to argmax over (initial + emission); ties
/// resolve to the lowest state index (strict `>` on the running best).
/// Byte-identical to `HMMTagger.tag` in Swift. Weights loaded from the
/// frozen checked-in artifact `HMMTaggerModel.json` via `MODEL`.
pub fn hmm_tag(lowered: &str) -> WordClass {
    let m = model();
    let obs = observe(lowered) as usize;
    let mut best_state = 0usize;
    let mut best_score = m.initial_weights[0] + m.emission_weights[0][obs];
    for i in 1..STATES.len() {
        let score = m.initial_weights[i] + m.emission_weights[i][obs];
        if score > best_score {
            best_score = score;
            best_state = i;
        }
    }
    STATES[best_state]
}

/// Maps a token to its single morphological observation, in the same fixed
/// priority order as `HMMTagger.observe` in Swift: non-alphabetic shape
/// first, then most-specific suffix to least. The ETL script replicates this
/// order exactly when computing emission counts from the training corpus.
fn observe(token: &str) -> Obs {
    if token.is_empty() || token.chars().any(|c| !c.is_alphabetic()) {
        return Obs::NonAlpha;
    }
    if token.ends_with("ing") {
        return Obs::SuffixIng;
    }
    if token.ends_with("tion") || token.ends_with("sion") {
        return Obs::SuffixTion;
    }
    if token.ends_with("ness") {
        return Obs::SuffixNess;
    }
    if token.ends_with("ment") {
        return Obs::SuffixMent;
    }
    if token.ends_with("ize") || token.ends_with("ise") {
        return Obs::SuffixIzeIse;
    }
    if token.ends_with("ate") {
        return Obs::SuffixAte;
    }
    if token.ends_with("ity") || token.ends_with("ty") {
        return Obs::SuffixItyTy;
    }
    if token.ends_with("ed") {
        return Obs::SuffixEd;
    }
    if token.ends_with("ly") {
        return Obs::SuffixLy;
    }
    if token.ends_with("er") || token.ends_with("or") || token.ends_with("ar") {
        return Obs::SuffixErOrAr;
    }
    Obs::Plain
}

// ---------------------------------------------------------------------------
// NovelTokenTaggerChoice (Layer-2a)
// ---------------------------------------------------------------------------

/// Estate-creation-time selection of the novel-token tagger.
///
/// Mirrors `LatticeLib.NovelTokenTaggerChoice` in Swift and
/// `persistence_kit::NovelTokenTaggerChoice` in PersistenceKit. The
/// two-enum pattern is required because PersistenceKit is upstream of
/// LatticeLib in the dependency topology; consumers bridge between them
/// with a trivial match at the GLK/NeuronKit boundary.
///
/// On Rust, `NlTagger` is a schema-parity variant only. The tagging
/// function `word_class_with_tagger` treats it as HMM because no
/// NaturalLanguage framework is available on non-Apple platforms.
/// `EstateConfiguration::new_with_tagger` in PersistenceKit rejects
/// `NlTagger` with `StorageError::InvalidConfiguration` so this path
/// is only reached when a configuration written by the Swift port is
/// read back by Rust.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NovelTokenTaggerChoice {
    /// Deterministic HMM/Viterbi — the default and cross-port baseline.
    Hmm,
    /// Apple NLTagger — schema-parity variant only on Rust.
    /// Treated as HMM when reached in the Rust tagging path (NaturalLanguage
    /// not available). Rejected at estate construction by PersistenceKit.
    NlTagger,
}

impl Default for NovelTokenTaggerChoice {
    fn default() -> Self {
        NovelTokenTaggerChoice::Hmm
    }
}

/// Classify a single lowercased token using the specified tagger choice.
///
/// The table fast-path (verb-before-noun, constant time) is NOT included
/// here — this function is the NOVEL-TOKEN tier only, called after a table
/// miss. Use `WordClassTableCache::word_class_with_tagger` for the full
/// table-first → tagger pipeline.
///
/// On Rust, `NlTagger` falls back to HMM (no NaturalLanguage framework
/// available). The result for `NlTagger` may differ from the Swift Apple
/// port; this is acceptable and documented in the cross-port contract
/// (cookbook §2.2, §8): the cross-port contract for novel tokens is the
/// HMM path; NLTagger is Apple-only.
pub fn hmm_tag_with_choice(lowered: &str, choice: NovelTokenTaggerChoice) -> WordClass {
    match choice {
        NovelTokenTaggerChoice::Hmm => hmm_tag(lowered),
        // NlTagger is Apple-only. On Rust, fall back to HMM. This case
        // is only reachable when a Swift-written configuration is read
        // back by Rust (PersistenceKit rejects NlTagger at construction).
        NovelTokenTaggerChoice::NlTagger => hmm_tag(lowered),
    }
}
