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
    let vectors: Vec<ConformanceVector> =
        serde_json::from_slice(fixture_bytes).expect("conformance fixture must parse");

    assert!(!vectors.is_empty(), "fixture must not be empty");
    assert!(
        Fdc::is_available(),
        "Rust FDC runtime must have loaded all artifacts"
    );

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

#[test]
fn operational_fragments_use_generalities() {
    let shell = r#"
git worktree prune
rm -f .git/index.lock
read_signal() {
  sqlite3 estate.sqlite 'select 1;'
}
"#;
    let markdown = r#"
# Monthly Canon Audit

```bash
set -euo pipefail
git status --short
```
"#;

    assert_eq!(Fdc::encode(shell), Some("000".to_owned()));
    assert_eq!(Fdc::encode_anchor(shell).1, None);
    assert_eq!(Fdc::encode(markdown), Some("000".to_owned()));
    assert_eq!(Fdc::encode_anchor(markdown).1, None);
}

#[test]
fn source_code_memories_use_programming_subject() {
    let swift_source = r#"
et nodeId: String
public let indexType: IndexType
public var semanticVector: [Double]
public var graphVector: GraphVector
public var behavioralVector: BehavioralVector
public var temporalVector: TemporalVector
public let createdAt: Date
public var updatedAt: Date
"#;
    assert_eq!(Fdc::encode(swift_source), Some("005".to_owned()));
    assert_eq!(Fdc::encode_anchor(swift_source).1.as_deref(), Some("Q17118377"));
    assert_eq!(Fdc::CLASSIFIER_VERSION, "4.2.0");
    assert_ne!(
        Fdc::encode("Let us remember the meeting.\nLet everyone review the notes."),
        Some("005".to_owned())
    );
}

#[test]
fn incidental_inherited_signature_terms_do_not_certify_narrow_headings() {
    // These were bad v1/v2 confidence failures caused by the compact signature
    // artifact flattening label/title/article/ancestor terms into one membership
    // set. The runtime may use that broad set for recall, but it must not return
    // a narrow user-facing code unless the winning code's own heading is
    // supported by the query.
    assert_eq!(
        Fdc::encode("machine learning neural networks artificial intelligence"),
        Some("004".to_owned()),
        "machine-learning terms must classify as computer science, not acupuncture"
    );
    assert_eq!(
        Fdc::encode("web development HTML programming"),
        Some("005".to_owned()),
        "web-development terms must classify as programming, not Great Britain"
    );
    assert_eq!(
        Fdc::encode("distributed systems cloud computing"),
        Some("004".to_owned()),
        "distributed-systems terms must classify as computer science, not Southeast Asia"
    );
}

#[test]
fn partial_qualified_heading_matches_do_not_overdescend() {
    assert_ne!(
        Fdc::encode("art painting sculpture museum"),
        Some("755".to_owned()),
        "generic art/painting text must not descend into religious painting without religious evidence"
    );
    assert_ne!(
        Fdc::encode("transportation automobile travel vehicles"),
        Some("699".to_owned()),
        "generic transportation text must not descend into railroad cars without railroad evidence"
    );
}

#[test]
fn own_heading_evidence_still_resolves_accessible_disability_topics() {
    assert_eq!(
        Fdc::encode("People with disabilities Blind Deaf"),
        Some("362.4".to_owned())
    );
    assert_eq!(
        Fdc::encode("screen reader accessibility braille deaf blind disability"),
        Some("362.4".to_owned())
    );
}

#[test]
fn specific_own_heading_evidence_still_resolves_supported_topics() {
    assert_eq!(
        Fdc::encode("computer graphics rendering visualization"),
        Some("006.6".to_owned())
    );
    assert_eq!(
        Fdc::encode("chemistry organic reactions molecules"),
        Some("547".to_owned())
    );
}

#[test]
fn query_repetition_cannot_manufacture_precision() {
    assert_eq!(
        Fdc::encode("railroad chemistry"),
        Fdc::encode("railroad railroad railroad chemistry")
    );
    assert_ne!(Fdc::encode("blind chemistry"), Some("362.4".to_owned()));
}

#[test]
fn recalculation_version_covers_algorithm_and_artifacts() {
    let version = Fdc::recalculation_version();
    assert!(version.contains("classifier:4.2.0"));
    assert!(version.contains("frame:1.1.0"));
    assert!(version.contains("lexicon:1.1.0"));
    assert!(version.contains("signatures:2.0.0"));
    assert!(version.contains("semantic:1.0.0:"));
    assert!(version.contains(Fdc::semantic_model_sha256()));
}

/// Stemmer conformance against SnowballEnglish.json (the same corpus used by
/// the Swift Stemmer test). Both the Swift hand-port and this Rust port MUST
/// produce byte-identical stems for every input in that corpus.
#[test]
fn stemmer_conformance_snowball_corpus() {
    use lattice_lib::stemmer::stem;

    // Load the bundled reference corpus.
    const CORPUS_BYTES: &[u8] =
        include_bytes!("../../Sources/LatticeLib/Resources/SnowballEnglish.json");

    #[derive(Deserialize)]
    struct Corpus {
        pairs: Vec<Pair>,
    }

    #[derive(Deserialize)]
    struct Pair {
        input: String,
        expected_stem: String,
    }

    let corpus: Corpus =
        serde_json::from_slice(CORPUS_BYTES).expect("SnowballEnglish.json must parse");

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

    println!(
        "Stemmer conformance: {}/{} vectors pass (100%)",
        pass, total
    );
}

/// Colon-delimited compact rows must classify identically across ports.
///
/// UAX #29 treats ASCII ':' as MidLetter, so `unicode-segmentation` keeps
/// `TASK:VERIFY` as ONE token while Foundation's `.byWords` splits it. Without
/// the tokenizer's compatibility split the merged tokens miss the word-class
/// table and lexicon, take the HMM `NonAlpha` path, and are dropped from the
/// concept bag — collapsing this row to `000` in Rust while Swift resolves it.
#[test]
fn encode_uses_the_same_canonical_classifier_as_encode_anchor() {
    // This compact estate row was one of 233 whose attached FDC vectors
    // diverged cross-port because Rust's UAX #29 tokenizer retained ASCII
    // colons while Foundation's `.byWords` tokenizer split them.
    let text = "TASK:MXE-2026-0151-VERIFY|FILES:hydration.rs|PATTERNS:stale-inline-comment:CLOSED(v3+v3+v2=8)|TESTS:4/4-exit0|VERDICT:PASS";
    assert_eq!(Fdc::encode(text).as_deref(), Some("700"));
    assert_eq!(Fdc::encode(text), Fdc::encode_anchor(text).0);
}
