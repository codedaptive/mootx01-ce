//! Cross-language conformance gate for FDC encoder Step 1. Reads the
//! shared vectors at ../Tests/SharedVectors/word_class_vectors.json
//! and asserts that eidetic_lib::word_class::word_class produces the
//! expected WordClass for every vector. The Swift port runs the same
//! vectors against the same JSON; any divergence is a hard conformance
//! failure of the kit (cookbook §8).

use eidetic_lib::word_class::{word_class, NovelTokenCache, WordClass};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct Vector {
    id: String,
    input: String,
    expected: WordClass,
    #[allow(dead_code)]
    path: String,
}

#[derive(Debug, Deserialize)]
struct VectorFile {
    #[serde(rename = "schema_version")]
    schema_version: String,
    vectors: Vec<Vector>,
}

const VECTOR_JSON: &str = include_str!(
    "../../Tests/SharedVectors/word_class_vectors.json"
);

#[test]
fn shared_vector_file_schema_is_one() {
    let file: VectorFile =
        serde_json::from_str(VECTOR_JSON).expect("parse");
    assert_eq!(file.schema_version, "1");
}

#[test]
fn all_shared_vectors_match() {
    let file: VectorFile =
        serde_json::from_str(VECTOR_JSON).expect("parse");
    assert!(
        !file.vectors.is_empty(),
        "shared vectors file must carry at least one vector"
    );

    let mut failures: Vec<String> = Vec::new();
    for vector in &file.vectors {
        let actual = word_class(&vector.input);
        if actual != vector.expected {
            failures.push(format!(
                "{}: expected {:?} got {:?}",
                vector.id, vector.expected, actual
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "Shared-vector conformance failures:\n{}",
        failures.join("\n")
    );
}

/// Submit-and-purge at exactly POOL_SUBMIT_THRESHOLD (50). Mirrors the
/// Swift NovelTokenCacheTests: 49 entries do not drain; the 50th
/// returns a §2.3 submission with exactly 50 entries and the cache
/// drains to empty.
#[test]
fn cache_submits_and_purges_at_exactly_fifty() {
    let mut cache = NovelTokenCache::with_default_submitter(
        "1.0.0".to_string(),
        "other".to_string(),
        "hmm-viterbi-stub-0".to_string(),
    );

    for i in 0..49 {
        let drained = cache.record(&format!("novel{i}"), WordClass::Noun);
        assert!(drained.is_none(), "must not submit before 50 entries");
    }
    assert_eq!(cache.len(), 49);

    let submission = cache
        .record("novel49", WordClass::Verb)
        .expect("must submit at exactly 50 entries");
    assert_eq!(submission.entries.len(), 50);
    assert_eq!(submission.table_version, "1.0.0");
    assert_eq!(submission.platform, "other");
    assert_eq!(submission.tagger_version, "hmm-viterbi-stub-0");
    assert_eq!(submission.entries[0].token, "novel0");
    assert_eq!(submission.entries[0].tag, "NOUN");
    assert_eq!(submission.entries[49].tag, "VERB");
    assert!(cache.is_empty(), "cache must drain after submission");
}
