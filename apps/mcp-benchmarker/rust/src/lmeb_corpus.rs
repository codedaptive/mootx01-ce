//! lmeb_corpus.rs — LMEB/ConvoMem retrieval corpus loader (Rust twin of LMEBCorpus.swift).
//!
//! Schema verified 2026-07-26 against KaLM-Embedding/LMEB on HuggingFace.
//! The dataset is never committed; see scripts/fetch-lmeb.sh to download.
//!
//! # File structure per evidence type
//!
//! ```text
//! {base_dir}/{evidence_type}/corpus.jsonl
//! {base_dir}/{evidence_type}/queries.jsonl
//! {base_dir}/{evidence_type}/candidates.jsonl
//! {base_dir}/{evidence_type}/qrels.tsv       — NOT in HuggingFace datasets API
//! ```
//!
//! # Formats
//!
//! - `corpus.jsonl`:     one JSON object per line: `{"id": str, "text": str, "title": str}`
//! - `queries.jsonl`:    one JSON object per line: `{"id": str, "text": str}`
//! - `candidates.jsonl`: one JSON object per line: `{"scene_id": str, "candidate_doc_ids": [str]}`
//! - `qrels.tsv`:        tab-separated, no header: `query_id\tcorpus_id\tscore`
//!                       (score is always "1" for binary relevance)
//!
//! # Key schema facts
//!
//! - Corpus docs are individual conversation TURNS (id: `"scene_X_session_Y_turn_Z"`).
//! - Query IDs encode the scene: `"scene_X_q_N"` → scene_id = `"scene_X"`.
//! - `candidates.jsonl` maps scene_id → all candidate turn IDs for that scene.
//! - `qrels.tsv` is absent from the HuggingFace datasets API; it must be
//!   downloaded directly (see LME-06_BLAST_RADIUS.md §Schema Discovery).
//! - Binary relevance: all qrel scores are 1; average 2.35 relevant docs/query.

use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;

// ─── Public types ────────────────────────────────────────────────────────────

/// One LMEB corpus document — a single conversation turn.
#[derive(Debug, Clone)]
pub struct LmebDoc {
    /// Unique turn identifier, e.g. `"scene_0_session_1_turn_9"`.
    pub id: String,
    /// Conversation turn text.
    pub text: String,
    /// Human-readable label, e.g. `"Session 1, Turn 9"`.
    pub title: String,
}

/// One LMEB query.
#[derive(Debug, Clone)]
pub struct LmebQuery {
    /// Query identifier, e.g. `"scene_0_q_0"`.
    pub id: String,
    /// Question text.
    pub text: String,
}

/// The fully-loaded LMEB/ConvoMem corpus, ready for evaluation.
///
/// Use [`LmebCorpus::candidate_docs`] to retrieve the retrieval scope for a query,
/// and [`LmebCorpus::relevant_docs`] to retrieve the ground-truth relevant set.
#[derive(Debug)]
pub struct LmebCorpus {
    /// Corpus documents indexed by ID.
    pub docs_by_id: HashMap<String, LmebDoc>,
    /// Queries indexed by ID.
    pub queries_by_id: HashMap<String, LmebQuery>,
    /// Per-scene candidate document IDs (from candidates.jsonl).
    pub candidates_by_scene_id: HashMap<String, Vec<String>>,
    /// Per-query set of relevant document IDs (from qrels.tsv).
    pub relevant_docs_by_query_id: HashMap<String, HashSet<String>>,
}

impl LmebCorpus {
    /// Total corpus document count.
    pub fn doc_count(&self) -> usize {
        self.docs_by_id.len()
    }

    /// Total query count.
    pub fn query_count(&self) -> usize {
        self.queries_by_id.len()
    }

    /// Total qrel count (sum of per-query relevant-doc sets).
    pub fn qrel_count(&self) -> usize {
        self.relevant_docs_by_query_id.values().map(|s| s.len()).sum()
    }

    /// Candidate document IDs for the scene of the given query.
    ///
    /// Scene ID is derived by stripping the `_q_N` suffix from the query ID:
    ///   `"scene_42_q_3"` → `"scene_42"`
    ///
    /// Returns an empty slice if the scene has no registered candidate pool.
    pub fn candidate_docs<'a>(&'a self, query_id: &str) -> &'a [String] {
        let scene_id = extract_scene_id(query_id);
        self.candidates_by_scene_id
            .get(scene_id)
            .map(|v| v.as_slice())
            .unwrap_or_default()
    }

    /// Relevant document IDs for a query (empty set if none).
    pub fn relevant_docs<'a>(&'a self, query_id: &str) -> &'a HashSet<String> {
        static EMPTY: std::sync::OnceLock<HashSet<String>> = std::sync::OnceLock::new();
        self.relevant_docs_by_query_id
            .get(query_id)
            .unwrap_or_else(|| EMPTY.get_or_init(HashSet::new))
    }
}

/// A load error with a message naming the file, line, and field where
/// loading failed (mirrors [`crate::LMEBLoadError`] in Swift).
#[derive(Debug)]
pub struct LmebLoadError(pub String);

impl std::fmt::Display for LmebLoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LmebLoadError: {}", self.0)
    }
}

impl std::error::Error for LmebLoadError {}

// ─── Internal helpers ────────────────────────────────────────────────────────

/// Extracts the scene ID from a query ID by stripping the last `_q_N` suffix.
///
/// Examples:
///   `"scene_0_q_0"`   → `"scene_0"`
///   `"scene_42_q_3"`  → `"scene_42"`
///   `"no_suffix"`     → `"no_suffix"` (passthrough)
fn extract_scene_id(query_id: &str) -> &str {
    // Find the LAST occurrence of "_q_" and take everything before it.
    if let Some(idx) = query_id.rfind("_q_") {
        &query_id[..idx]
    } else {
        query_id
    }
}

/// Raw corpus.jsonl row (Deserialize only).
#[derive(Debug, Deserialize)]
struct DocRaw {
    id: String,
    text: String,
    title: String,
}

/// Raw queries.jsonl row.
#[derive(Debug, Deserialize)]
struct QueryRaw {
    id: String,
    text: String,
}

/// Raw candidates.jsonl row.
#[derive(Debug, Deserialize)]
struct CandidatesRaw {
    scene_id: String,
    candidate_doc_ids: Vec<String>,
}

/// Parses a JSONL file (one JSON object per line) into `Vec<T>`.
///
/// Empty / whitespace lines are skipped. Returns `LmebLoadError` naming the
/// file path, line index, and serde error on any decode failure.
fn load_jsonl<T: for<'de> Deserialize<'de>>(
    path: &Path,
    label: &str,
) -> Result<Vec<T>, LmebLoadError> {
    let content = fs::read_to_string(path).map_err(|e| {
        LmebLoadError(format!("{label}: could not read file {path:?}: {e}"))
    })?;

    let mut results = Vec::new();
    let mut line_index: usize = 0;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<T>(trimmed) {
            Ok(item) => results.push(item),
            Err(e) => {
                return Err(LmebLoadError(format!(
                    "{label} line {line_index}: decode failed: {e}"
                )));
            }
        }
        line_index += 1;
    }
    Ok(results)
}

/// Parses a qrels TSV file (no header) into a `HashMap<query_id, HashSet<corpus_id>>`.
///
/// Format per line: `query_id\tcorpus_id\tscore`
/// All LMEB ConvoMem qrel scores are "1" (binary relevance).
/// Lines with fewer than 2 tab-separated fields produce `LmebLoadError`.
fn parse_qrels(path: &Path, label: &str) -> Result<HashMap<String, HashSet<String>>, LmebLoadError> {
    let content = fs::read_to_string(path).map_err(|e| {
        LmebLoadError(format!("{label}: could not read qrels file {path:?}: {e}"))
    })?;

    let mut result: HashMap<String, HashSet<String>> = HashMap::new();
    let mut line_index: usize = 0;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let parts: Vec<&str> = trimmed.splitn(3, '\t').collect();
        if parts.len() < 2 {
            return Err(LmebLoadError(format!(
                "{label} qrels line {line_index}: expected at least 2 \
                 tab-separated fields, got {}: {:?}",
                parts.len(),
                &trimmed[..trimmed.len().min(80)]
            )));
        }
        let query_id = parts[0];
        let corpus_id = parts[1];
        if query_id.is_empty() || corpus_id.is_empty() {
            return Err(LmebLoadError(format!(
                "{label} qrels line {line_index}: empty query_id or corpus_id"
            )));
        }
        result
            .entry(query_id.to_owned())
            .or_default()
            .insert(corpus_id.to_owned());
        line_index += 1;
    }
    Ok(result)
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Loads the LMEB/ConvoMem corpus from a directory tree.
///
/// # Parameters
///
/// - `base_dir`: Root directory containing one subdirectory per evidence type
///   (e.g. `fixtures/lmeb/data/ConvoMem/`).
/// - `evidence_types`: Which evidence-type subdirectories to load. Pass all six
///   for a full production run; pass `&["user_evidence"]` for test fixtures.
///
/// # Returns
///
/// A merged [`LmebCorpus`] across all requested evidence types.
///
/// # Errors
///
/// Returns [`LmebLoadError`] naming the file, line, and field where loading
/// failed.
pub fn load_lmeb_corpus(
    base_dir: &Path,
    evidence_types: &[&str],
) -> Result<LmebCorpus, LmebLoadError> {
    let mut docs_by_id: HashMap<String, LmebDoc> = HashMap::new();
    let mut queries_by_id: HashMap<String, LmebQuery> = HashMap::new();
    let mut candidates_by_scene_id: HashMap<String, Vec<String>> = HashMap::new();
    let mut relevant_docs_by_query_id: HashMap<String, HashSet<String>> = HashMap::new();

    for et in evidence_types {
        let et_dir = base_dir.join(et);
        let label = *et;

        // --- corpus.jsonl ---
        let corpus_path = et_dir.join("corpus.jsonl");
        let raw_docs: Vec<DocRaw> = load_jsonl(&corpus_path, &format!("{label}/corpus.jsonl"))?;
        for (i, raw) in raw_docs.into_iter().enumerate() {
            if raw.id.is_empty() {
                return Err(LmebLoadError(format!(
                    "{label}/corpus.jsonl row {i}: empty 'id' field"
                )));
            }
            docs_by_id.insert(
                raw.id.clone(),
                LmebDoc { id: raw.id, text: raw.text, title: raw.title },
            );
        }

        // --- queries.jsonl ---
        let queries_path = et_dir.join("queries.jsonl");
        let raw_queries: Vec<QueryRaw> =
            load_jsonl(&queries_path, &format!("{label}/queries.jsonl"))?;
        for (i, raw) in raw_queries.into_iter().enumerate() {
            if raw.id.is_empty() {
                return Err(LmebLoadError(format!(
                    "{label}/queries.jsonl row {i}: empty 'id' field"
                )));
            }
            queries_by_id
                .insert(raw.id.clone(), LmebQuery { id: raw.id, text: raw.text });
        }

        // --- candidates.jsonl ---
        let candidates_path = et_dir.join("candidates.jsonl");
        let raw_cands: Vec<CandidatesRaw> =
            load_jsonl(&candidates_path, &format!("{label}/candidates.jsonl"))?;
        for (i, raw) in raw_cands.into_iter().enumerate() {
            if raw.scene_id.is_empty() {
                return Err(LmebLoadError(format!(
                    "{label}/candidates.jsonl row {i}: empty 'scene_id' field"
                )));
            }
            candidates_by_scene_id.insert(raw.scene_id, raw.candidate_doc_ids);
        }

        // --- qrels.tsv ---
        let qrels_path = et_dir.join("qrels.tsv");
        let qrels = parse_qrels(&qrels_path, label)?;
        for (query_id, doc_ids) in qrels {
            relevant_docs_by_query_id
                .entry(query_id)
                .or_default()
                .extend(doc_ids);
        }
    }

    Ok(LmebCorpus {
        docs_by_id,
        queries_by_id,
        candidates_by_scene_id,
        relevant_docs_by_query_id,
    })
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    // Counter for unique temp directory names across parallel test runs.
    // avoids tempfile crate dependency per Cargo.toml "no external test deps" constraint.
    static TEST_DIR_COUNTER: AtomicU32 = AtomicU32::new(0);

    /// Creates a unique temp directory under `std::env::temp_dir()`.
    /// Uses PID + atomic counter to avoid collisions in parallel test runs.
    /// Caller is responsible for cleanup via `std::fs::remove_dir_all`.
    fn make_test_dir(tag: &str) -> std::path::PathBuf {
        let pid = std::process::id();
        let seq = TEST_DIR_COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir()
            .join(format!("mcp_bench_lmeb_{tag}_{pid}_{seq}"));
        std::fs::create_dir_all(&dir).expect("create test temp dir");
        dir
    }

    /// Writes the four required files for `{base}/{et}/`.
    fn write_sample_files(
        base_dir: &Path,
        et: &str,
        corpus_jsonl: &str,
        queries_jsonl: &str,
        candidates_jsonl: &str,
        qrels_tsv: &str,
    ) {
        let et_dir = base_dir.join(et);
        std::fs::create_dir_all(&et_dir).expect("create evidence type dir");
        std::fs::write(et_dir.join("corpus.jsonl"), corpus_jsonl).unwrap();
        std::fs::write(et_dir.join("queries.jsonl"), queries_jsonl).unwrap();
        std::fs::write(et_dir.join("candidates.jsonl"), candidates_jsonl).unwrap();
        std::fs::write(et_dir.join("qrels.tsv"), qrels_tsv).unwrap();
    }

    const SAMPLE_CORPUS: &str = concat!(
        r#"{"id": "scene_0_session_1_turn_1", "text": "User: I love restoring antique furniture. My current project is a Victorian rocking chair.", "title": "Session 1, Turn 1"}"#, "\n",
        r#"{"id": "scene_0_session_1_turn_2", "text": "Assistant: That sounds rewarding!", "title": "Session 1, Turn 2"}"#, "\n",
        r#"{"id": "scene_0_session_1_turn_3", "text": "User: It is made of oak.", "title": "Session 1, Turn 3"}"#, "\n",
        r#"{"id": "scene_1_session_1_turn_1", "text": "User: I worked at Clarity PR.", "title": "Session 1, Turn 1"}"#, "\n",
        r#"{"id": "scene_1_session_1_turn_2", "text": "Assistant: Interesting!", "title": "Session 1, Turn 2"}"#, "\n",
    );
    const SAMPLE_QUERIES: &str = concat!(
        r#"{"id": "scene_0_q_0", "text": "What piece of furniture am I restoring?"}"#, "\n",
        r#"{"id": "scene_1_q_0", "text": "What PR firm did I work at?"}"#, "\n",
    );
    const SAMPLE_CANDIDATES: &str = concat!(
        r#"{"scene_id": "scene_0", "candidate_doc_ids": ["scene_0_session_1_turn_1", "scene_0_session_1_turn_2", "scene_0_session_1_turn_3"]}"#, "\n",
        r#"{"scene_id": "scene_1", "candidate_doc_ids": ["scene_1_session_1_turn_1", "scene_1_session_1_turn_2"]}"#, "\n",
    );
    const SAMPLE_QRELS: &str = concat!(
        "scene_0_q_0\tscene_0_session_1_turn_1\t1\n",
        "scene_0_q_0\tscene_0_session_1_turn_3\t1\n",
        "scene_1_q_0\tscene_1_session_1_turn_1\t1\n",
    );

    /// Loads the sample corpus into a unique temp dir.
    /// Returns (corpus, temp_dir_path) — caller must clean up temp_dir_path.
    fn load_sample(tag: &str) -> (LmebCorpus, std::path::PathBuf) {
        let dir = make_test_dir(tag);
        write_sample_files(
            &dir, "user_evidence",
            SAMPLE_CORPUS, SAMPLE_QUERIES, SAMPLE_CANDIDATES, SAMPLE_QRELS,
        );
        let corpus = load_lmeb_corpus(&dir, &["user_evidence"]).unwrap();
        (corpus, dir)
    }

    #[test]
    fn loads_sample_counts() {
        let (corpus, dir) = load_sample("counts");
        assert_eq!(corpus.doc_count(), 5, "5 corpus docs");
        assert_eq!(corpus.query_count(), 2, "2 queries");
        assert_eq!(corpus.qrel_count(), 3, "3 qrels");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn doc_contents_correct() {
        let (corpus, dir) = load_sample("doc_contents");
        let doc = corpus.docs_by_id.get("scene_0_session_1_turn_1").unwrap();
        assert_eq!(doc.id, "scene_0_session_1_turn_1");
        assert!(doc.text.contains("Victorian rocking chair"));
        assert_eq!(doc.title, "Session 1, Turn 1");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn candidate_docs_scene0() {
        let (corpus, dir) = load_sample("cands0");
        let cands = corpus.candidate_docs("scene_0_q_0");
        assert_eq!(cands.len(), 3, "scene_0 has 3 candidates");
        assert!(cands.contains(&"scene_0_session_1_turn_1".to_owned()));
        assert!(cands.contains(&"scene_0_session_1_turn_3".to_owned()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn candidate_docs_scene1() {
        let (corpus, dir) = load_sample("cands1");
        let cands = corpus.candidate_docs("scene_1_q_0");
        assert_eq!(cands.len(), 2, "scene_1 has 2 candidates");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn candidate_docs_unknown_returns_empty() {
        let (corpus, dir) = load_sample("cands_unk");
        assert!(corpus.candidate_docs("scene_999_q_0").is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relevant_docs_scene0() {
        let (corpus, dir) = load_sample("rel0");
        let rel = corpus.relevant_docs("scene_0_q_0");
        assert_eq!(rel.len(), 2, "scene_0_q_0 has 2 relevant docs");
        assert!(rel.contains("scene_0_session_1_turn_1"));
        assert!(rel.contains("scene_0_session_1_turn_3"));
        assert!(!rel.contains("scene_0_session_1_turn_2"), "turn_2 is not relevant");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relevant_docs_scene1() {
        let (corpus, dir) = load_sample("rel1");
        let rel = corpus.relevant_docs("scene_1_q_0");
        assert_eq!(rel.len(), 1);
        assert!(rel.contains("scene_1_session_1_turn_1"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relevant_docs_unknown_returns_empty() {
        let (corpus, dir) = load_sample("rel_unk");
        assert!(corpus.relevant_docs("scene_999_q_0").is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn scene_id_extraction_variants() {
        // Direct unit test — no temp dir needed.
        assert_eq!(extract_scene_id("scene_0_q_0"), "scene_0");
        assert_eq!(extract_scene_id("scene_42_q_3"), "scene_42");
        assert_eq!(extract_scene_id("scene_1000_q_0"), "scene_1000");
        // No suffix — passthrough.
        assert_eq!(extract_scene_id("no_suffix"), "no_suffix");
        // Uses LAST occurrence (edge case: scene ID itself contains "_q_").
        assert_eq!(extract_scene_id("scene_q_0_q_1"), "scene_q_0");
    }

    #[test]
    fn empty_evidence_type_yields_zero_counts() {
        let dir = make_test_dir("empty_et");
        write_sample_files(&dir, "user_evidence", "", "", "", "");
        let corpus = load_lmeb_corpus(&dir, &["user_evidence"]).unwrap();
        assert_eq!(corpus.doc_count(), 0);
        assert_eq!(corpus.query_count(), 0);
        assert_eq!(corpus.qrel_count(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn empty_corpus_id_raises_error() {
        let dir = make_test_dir("empty_id");
        let bad_corpus = r#"{"id": "", "text": "x", "title": "T"}"#;
        write_sample_files(&dir, "user_evidence", bad_corpus, "", "", "");
        let result = load_lmeb_corpus(&dir, &["user_evidence"]);
        assert!(result.is_err(), "expected LmebLoadError for empty id");
        let err = result.unwrap_err();
        assert!(
            err.0.contains("'id'"),
            "error should name the 'id' field: {}",
            err.0
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn malformed_qrels_line_raises_error() {
        let dir = make_test_dir("bad_qrels");
        let bad_qrels = "scene_0_q_0\n"; // only one field
        let valid_corpus = r#"{"id": "d1", "text": "t", "title": "T"}"#;
        let valid_query = r#"{"id": "q1", "text": "q"}"#;
        let valid_cands = r#"{"scene_id": "scene_0", "candidate_doc_ids": ["d1"]}"#;
        write_sample_files(&dir, "user_evidence",
            valid_corpus, valid_query, valid_cands, bad_qrels);
        let result = load_lmeb_corpus(&dir, &["user_evidence"]);
        assert!(result.is_err(), "expected error for malformed qrels");
        let err = result.unwrap_err();
        assert!(
            err.0.contains("tab-separated"),
            "error should mention tab-separated fields: {}",
            err.0
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_directory_raises_error() {
        let dir = make_test_dir("no_et_dir");
        // Don't create the evidence type subdirectory — loading should fail.
        let result = load_lmeb_corpus(&dir, &["user_evidence"]);
        assert!(result.is_err(), "expected error for missing directory");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
