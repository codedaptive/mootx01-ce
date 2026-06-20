// lattice_conformance_test.rs — Swift↔Rust agreement for the deterministic
// language layer: the compatibility-fold normalizer and the HMM/Viterbi
// novel-token tagger.
//
// Both fixtures are SHARED with the Swift leg (Tests/LatticeLibTests/
// LatticeLanguageConformanceTests.swift reads the same JSON files via a
// #filePath anchor). Byte-identity across the two ports is the contract:
//   * normalize_conformance.json — Normalizer::normalize == Normalizer.normalize
//   * tag_conformance.json       — word_class::hmm_tag == HMMTagger.tag
//
// The HMM tagger is the default on ALL platforms, including Apple (NLTagger
// is opt-in only via explicit estate configuration). The guarantee here is
// cross-platform bit-identity: Swift HMM == Rust HMM. See HMMTagger.swift.

use lattice_lib::normalizer::normalize;
use lattice_lib::word_class::{hmm_tag, WordClass};
use serde::Deserialize;

#[derive(Deserialize)]
struct NormalizeVector {
    input: String,
    expected: String,
}

#[derive(Deserialize)]
struct TagVector {
    token: String,
    #[serde(rename = "class")]
    class: String,
}

fn class_name(c: WordClass) -> &'static str {
    match c {
        WordClass::Noun => "noun",
        WordClass::Verb => "verb",
        WordClass::Other => "other",
    }
}

#[test]
fn normalize_conformance_all_vectors_match() {
    let bytes = include_bytes!("fixtures/normalize_conformance.json");
    let vectors: Vec<NormalizeVector> =
        serde_json::from_slice(bytes).expect("normalize fixture must parse");
    assert!(!vectors.is_empty(), "fixture must not be empty");

    let total = vectors.len();
    let mut failures: Vec<String> = Vec::new();
    for v in &vectors {
        let got = normalize(&v.input);
        if got != v.expected {
            failures.push(format!(
                "MISMATCH input={:?} expected={:?} got={:?}",
                v.input, v.expected, got
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "normalize conformance FAILED: {}/{} pass\n{}",
            total - failures.len(),
            total,
            failures.join("\n")
        );
    }
    println!("normalize conformance: {}/{} vectors pass (100%)", total, total);
}

#[test]
fn tag_conformance_all_vectors_match() {
    let bytes = include_bytes!("fixtures/tag_conformance.json");
    let vectors: Vec<TagVector> =
        serde_json::from_slice(bytes).expect("tag fixture must parse");
    assert!(!vectors.is_empty(), "fixture must not be empty");

    let total = vectors.len();
    let mut failures: Vec<String> = Vec::new();
    for v in &vectors {
        let got = class_name(hmm_tag(&v.token));
        if got != v.class {
            failures.push(format!(
                "MISMATCH token={:?} expected={:?} got={:?}",
                v.token, v.class, got
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "tag conformance FAILED: {}/{} pass\n{}",
            total - failures.len(),
            total,
            failures.join("\n")
        );
    }
    println!("tag conformance: {}/{} vectors pass (100%)", total, total);
}
