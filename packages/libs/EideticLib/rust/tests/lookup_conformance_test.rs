// lookup_conformance_test.rs — EideticLib Rust cross-language conformance gate.
//
// Reads Tests/SharedVectors/lookup_vectors.json (schema_version 2) and asserts
// that Rust eidetic_lib::lookup produces the expected FDC code and Wikidata Q-ID
// for every vector. The Swift half lives in
// EideticLib/Tests/EideticLibTests/LookupConformanceTests.swift.
//
// Both legs must pass 100% against the same fixture file before merge.
// Any divergence is a parity violation.
//
// schema_version history:
//   v1 (PAR-3B-EL): expected_udc with UDC codes — wrong system, no test consumed it.
//   v2 (w3-latticelib-fdc): expected_code with real FDC codes, verified Swift+Rust.

use eidetic_lib::lookup;
use serde::Deserialize;

// MARK: - Vector schema (mirrors LookupVector in Swift)

#[derive(Deserialize)]
struct LookupVectorFile {
    schema_version: String,
    vectors: Vec<LookupVector>,
}

#[derive(Deserialize)]
struct LookupVector {
    id: String,
    input: String,
    /// Expected FDC code. Empty string means UNRESOLVED.
    expected_code: String,
    /// Expected Wikidata Q-ID, or None.
    expected_qid: Option<String>,
}

// MARK: - Load fixture

fn load_vectors() -> LookupVectorFile {
    // The fixture is at Tests/SharedVectors/lookup_vectors.json relative to
    // the EideticLib package root. This integration test file is at
    // rust/tests/lookup_conformance_test.rs, so the path walks up two
    // directories (tests/ → rust/ → package root) then into SharedVectors/.
    const FIXTURE: &[u8] = include_bytes!(
        "../../Tests/SharedVectors/lookup_vectors.json"
    );
    serde_json::from_slice(FIXTURE).expect("lookup_vectors.json must parse")
}

// MARK: - Conformance tests

#[test]
fn lookup_vectors_schema_version_is_2() {
    let file = load_vectors();
    // schema_version 2 carries FDC codes in expected_code (v1 had wrong UDC codes).
    assert_eq!(
        file.schema_version, "2",
        "lookup_vectors.json must be schema_version 2"
    );
    assert!(
        !file.vectors.is_empty(),
        "lookup_vectors.json must contain at least one vector"
    );
}

#[test]
fn all_lookup_vectors_match_expected_code() {
    let file = load_vectors();
    let mut failures: Vec<String> = Vec::new();

    for v in &file.vectors {
        let anchor = lookup(&v.input);
        if anchor.code != v.expected_code {
            failures.push(format!(
                "{}: input={:?} expected_code={:?} got={:?}",
                v.id, v.input, v.expected_code, anchor.code
            ));
        }
    }

    if !failures.is_empty() {
        let report = failures.join("\n");
        panic!(
            "Lookup conformance FAILED: {}/{} vectors diverge:\n{}",
            failures.len(),
            file.vectors.len(),
            report
        );
    }
}

#[test]
fn all_lookup_vectors_match_expected_qid() {
    let file = load_vectors();
    let mut failures: Vec<String> = Vec::new();

    for v in &file.vectors {
        let anchor = lookup(&v.input);
        if anchor.wikidata_qid != v.expected_qid {
            failures.push(format!(
                "{}: input={:?} expected_qid={:?} got={:?}",
                v.id, v.input, v.expected_qid, anchor.wikidata_qid
            ));
        }
    }

    if !failures.is_empty() {
        let report = failures.join("\n");
        panic!(
            "Lookup Q-ID conformance FAILED: {}/{} vectors diverge:\n{}",
            failures.len(),
            file.vectors.len(),
            report
        );
    }
}
