// fdc_conformance_test.rs — FDC encode self-consistency and stemmer gate
//
// `fdc_conformance_all_vectors_match` asserts that the Rust `Fdc::encode`
// produces the values recorded in `fdc_conformance.json` for every fixture
// vector. The baseline in that fixture is the deterministic HMM path: novel
// tokens are classified via the integer-Viterbi HMM (`word_class::hmm_tag`),
// byte-identical to Swift's HMM path on every platform (including Apple).
//
// HMM is the default novel-token path on ALL platforms in Swift. The Apple
// NLTagger path is opt-in only (requires explicit `NovelTokenTaggerChoice.nlTagger`
// via the estate tagger-choice overload) and is NOT exercised or treated as a
// baseline here. The production `FDC.encode` / `FDC.encodeAnchor` path uses HMM
// everywhere, so this conformance gate covers the production path on all platforms.
//
// Conformance scope:
//   Rust-HMM scalar (self-consistent) + byte-identity with Swift-HMM (all platforms).
//
// The four-way conformance matrix (Swift-scalar, Swift-Metal, Rust-scalar,
// Rust-BLAS/NEON) does NOT apply here: FDC is a pure string/bag computation
// with no vector/matrix dimension. There is no Metal kernel and no BLAS/NEON
// leg. Saying so rather than faking a four-way matrix is the correct call per
// the substrate contract.
//
// Seed: N/A (determinism comes from the pinned artifacts and the algorithm,
// not from a hash-family seed).

use lattice_lib::Fdc;
use serde::Deserialize;

#[derive(Deserialize)]
struct ConformanceVector {
    input: String,
    code: Option<String>,
}

#[test]
fn fdc_conformance_all_vectors_match() {
    // Load the fixture.
    let fixture_bytes = include_bytes!("fixtures/fdc_conformance.json");
    let vectors: Vec<ConformanceVector> = serde_json::from_slice(fixture_bytes)
        .expect("conformance fixture must parse");

    assert!(!vectors.is_empty(), "fixture must not be empty");
    assert!(Fdc::is_available(), "Rust FDC runtime must have loaded all artifacts");

    let total = vectors.len();
    let mut pass = 0usize;
    let mut failures: Vec<String> = Vec::new();

    for v in &vectors {
        let rust_code = Fdc::encode(&v.input);
        if rust_code == v.code {
            pass += 1;
        } else {
            failures.push(format!(
                "MISMATCH input={:?} expected={:?} got={:?}",
                v.input, v.code, rust_code
            ));
        }
    }

    if !failures.is_empty() {
        let report = failures.join("\n");
        panic!(
            "FDC conformance FAILED: {}/{} vectors pass\n{}",
            pass, total, report
        );
    }

    println!("FDC conformance: {}/{} vectors pass (100%)", pass, total);
}

/// Stemmer conformance against SnowballEnglish.json (the same corpus used by
/// the Swift Stemmer test). Both the Swift hand-port and this Rust port MUST
/// produce byte-identical stems for every input in that corpus.
#[test]
fn stemmer_conformance_snowball_corpus() {
    use lattice_lib::stemmer::stem;

    // Load the bundled reference corpus.
    const CORPUS_BYTES: &[u8] = include_bytes!(
        "../../Sources/LatticeLib/Resources/SnowballEnglish.json"
    );

    #[derive(Deserialize)]
    struct Corpus {
        pairs: Vec<Pair>,
    }

    #[derive(Deserialize)]
    struct Pair {
        input: String,
        expected_stem: String,
    }

    let corpus: Corpus = serde_json::from_slice(CORPUS_BYTES)
        .expect("SnowballEnglish.json must parse");

    let total = corpus.pairs.len();
    let mut pass = 0usize;
    let mut failures: Vec<String> = Vec::new();

    for pair in &corpus.pairs {
        let got = stem(&pair.input);
        if got == pair.expected_stem {
            pass += 1;
        } else {
            failures.push(format!(
                "MISMATCH input={:?} expected={:?} got={:?}",
                pair.input, pair.expected_stem, got
            ));
        }
    }

    if !failures.is_empty() {
        let report = failures.join("\n");
        panic!(
            "Stemmer conformance FAILED: {}/{} vectors pass\n{}",
            pass, total, report
        );
    }

    println!("Stemmer conformance: {}/{} vectors pass (100%)", pass, total);
}
