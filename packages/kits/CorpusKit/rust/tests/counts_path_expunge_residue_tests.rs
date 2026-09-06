//! counts_path_expunge_residue_tests.rs
//!
//! Rust twin of `CountsPathExpungeResidueTests.swift`.
//!
//! Regression gate for finding C (MEDIUM) from the ci-corpus-incremental wave
//! Codex review (commit 852117d): "Counts-path reindex can resurrect expunged
//! corpus terms."
//!
//! The governing invariant:
//!
//!   After expunging a source and running reindex, the counts path MUST NOT be
//!   taken. The population guard (`doc_count != chunks.len()`) must drive
//!   `CorpusPathReason::PopulationMismatch`, which retrains from active texts
//!   only and overwrites the stale counts snapshot.
//!
//! WHY THE GUARD ALWAYS FIRES AFTER AN EXPUNGE:
//!   - `document_count` is monotonic: incremented by `chunks.len()` per ingest
//!     fold (`fold_chunks_into_counts`), never decremented.
//!   - `expunge` / `remove` never decrements `document_count` and never calls
//!     `persist_maintained_counts` — the in-memory and stored values are
//!     unchanged by removal.
//!   - `active_chunks()` excludes removed sources.
//!   - Therefore any expunge leaves `document_count > active_chunks().len()`,
//!     forcing `PopulationMismatch` → corpus path → F-2 heal.
//!   - After F-2 heal, subsequent ingest of k chunks increments both sides by k,
//!     preserving the gap. The gap cannot close by ingest alone.
//!
//! Tests:
//!
//!   T-1: in-session — ingest A → first reindex (firstTrain) → expunge A →
//!        ingest B → second reindex. Population guard must fire on second reindex.
//!        A-unique terms must not surface in recall.
//!
//!   T-2: across-reopen — ingest A → reindex → drop corpus → reopen → expunge A →
//!        ingest B → drop corpus → reopen → reindex. Guard must still fire because
//!        the persisted `doc_count` is restored on reopen and the gap is preserved.
//!
//! T-1 uses InMemoryStorage (no reopen needed).
//! T-2 uses SqliteStorage (reopen requires on-disk persistence).

// Every case opens a PPMI corpus — a dark dense family (contract sheet §13) —
// so this file compiles only under the dense-families feature.
#![cfg(feature = "dense-families")]

use corpus_kit::{Corpus, CorpusPathReason, EmbeddingModelConfig, TrainingPathDecision};
use corpus_kit_providers::PpmiProvider;
use intellectus_lib::Intellectus;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

// ── Global lock ──────────────────────────────────────────────────────────────
//
// Corpus.ingest / reindex emit IntellectusLib telemetry. Tests holding the lock
// hold it for their entire duration to prevent concurrent telemetry tests from
// seeing spurious emissions.

static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    match GLOBAL_LOCK.get_or_init(|| Mutex::new(())).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

// ── Deterministic time constants ─────────────────────────────────────────────

/// Epoch-milliseconds — never SystemTime::now() (determinism mandate).
const NOW_A: i64 = 2_000_000_000;
const NOW_B: i64 = 2_100_000_000;

// ── Text bodies ───────────────────────────────────────────────────────────────
//
// Distinct made-up compound tokens ensure vocabulary contamination is detectable
// through recall. "quantumxylograph" appears only in source A (to be expunged).
// "bioluminescence" appears only in source B (to survive).

const TEXT_A: &str = "quantumxylograph quantumxylograph quantumxylograph researchers \
    investigated the quantumxylograph process using specialized quantumxylograph \
    instruments that produce quantumxylograph results under quantumxylograph laboratory \
    conditions. The quantumxylograph technique has never been applied outside \
    quantumxylograph contexts.";

const TEXT_B: &str = "bioluminescence bioluminescence bioluminescence organisms produce \
    bioluminescence through enzymatic bioluminescence reactions that emit bioluminescence \
    light. Studying bioluminescence in deep-sea bioluminescence environments reveals \
    bioluminescence adaptations that aid bioluminescence survival.";

// ── PPMI corpus factory ───────────────────────────────────────────────────────

fn ppmi_model() -> EmbeddingModelConfig {
    EmbeddingModelConfig::Ppmi { provider: Box::new(PpmiProvider::new()) }
}

fn make_inmemory_corpus() -> Corpus {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Corpus::open(storage, ppmi_model()).expect("Corpus::open with InMemory must succeed")
}

fn scratch_sqlite_path() -> String {
    std::env::temp_dir()
        .join(format!("corpuskit-expunge-residue-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

fn open_sqlite_corpus(path: &str) -> Corpus {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> =
        Arc::new(SqliteStorage::new(config).expect("open sqlite must succeed"));
    Corpus::open(storage, ppmi_model()).expect("Corpus::open with SQLite must succeed")
}

// ── T-1: in-session sequence ──────────────────────────────────────────────────

/// T-1 gate (finding C, MEDIUM): in-session ingest → reindex → expunge →
/// ingest → reindex.
///
/// Population guard:
///   After F-2 heal of the first reindex, document_count = 1 (one chunk for A).
///   Expunge A: active_chunks = 0, document_count = 1 (unchanged).
///   Ingest B:  active_chunks = 1, document_count = 2 (fold_chunks_into_counts += 1).
///   Second reindex guard: 2 != 1 → PopulationMismatch → corpus path.
///   Corpus path retrains on B's texts only, heals counts to {doc_count=1, T_B}.
///   A's unique marker "quantumxylograph" is absent from the serving vocabulary.
#[test]
fn t1_expunge_residue_in_session_population_guard() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let corpus = make_inmemory_corpus();

    // Phase 1: ingest source A with unique marker "quantumxylograph".
    corpus.ingest(TEXT_A, "source-A", NOW_A)
        .expect("ingest A must succeed");

    // Phase 2: first reindex.
    // PPMI is counts-capable (finalizeFromCounts=true, countsDeltaFoldSafe=true).
    // After ingest A, population guard may pass (document_count == active_chunks)
    // and the counts path is taken (CountsRestore). Either CountsRestore or
    // Corpus(FirstTrain) is valid here; the invariant is tested on the SECOND
    // reindex after expunge.
    corpus.reindex(NOW_A)
        .expect("first reindex must succeed");
    // (No assertion on the first path — either CountsRestore or Corpus(FirstTrain)
    // is acceptable. The critical gate is the second reindex path below.)

    // Phase 3: expunge source A.
    // active_chunks drops to 0; document_count stays at 1 (no decrement on expunge).
    // persist_maintained_counts is NOT called by expunge.
    corpus.expunge("source-A")
        .expect("expunge A must succeed");

    // Phase 4: ingest source B with unique marker "bioluminescence".
    // fold_chunks_into_counts: document_count becomes 2, active_chunks = 1.
    // persist_maintained_counts called at batch boundary: store → {doc_count=2}.
    corpus.ingest(TEXT_B, "source-B", NOW_B)
        .expect("ingest B must succeed");

    // Phase 5: second reindex.
    // Population guard: document_count (2) != active_chunks (1).
    // Expected: Corpus(PopulationMismatch) — NOT CountsRestore.
    corpus.reindex(NOW_B)
        .expect("second reindex must succeed");

    let decisions_after_second = corpus.training_path_decisions();
    let second_decision = decisions_after_second.get("ppmi-v1").cloned();
    assert_eq!(
        second_decision,
        Some(TrainingPathDecision::Corpus(CorpusPathReason::PopulationMismatch)),
        "After expunge + ingest, document_count (2) must differ from active_chunks (1), \
         driving Corpus(PopulationMismatch). Got: {:?}. \
         CountsRestore here would resurrect T_A terms into the serving basis.",
        second_decision
    );

    // Phase 6: verify source-A's chunks do not appear in recall.
    // Keyword lane was scrubbed by expunge. Dense lane retrained on B only.
    // Dense nearest-neighbor may return source-B for an OOV query — that is
    // acceptable. What is NOT acceptable is source-A's chunks returning.
    let a_results = corpus.recall("quantumxylograph", 10, NOW_B)
        .expect("recall must not error");
    let a_source_chunks: Vec<_> = a_results.iter()
        .filter(|r| r.chunk.source_id == "source-A")
        .collect();
    assert!(
        a_source_chunks.is_empty(),
        "No result with source_id 'source-A' must appear after expunge. \
         Got {} source-A result(s). Total results: {}. This indicates resurrected content.",
        a_source_chunks.len(),
        a_results.len()
    );
}

// ── T-2: across-reopen sequence ───────────────────────────────────────────────

/// T-2 gate (finding C, reopen variant): ingest A → reindex → drop → reopen →
/// expunge A → ingest B → drop → reopen → reindex.
///
/// After reopen, document_count is restored from the persisted store row.
/// Even so, the population guard fires because persist_maintained_counts is
/// called at every ingest boundary, keeping the stored doc_count equal to
/// the in-memory value at session end. The expunge in session 2 does NOT
/// update the store, but the subsequent ingest B does. Sequence:
///
///   session₁: ingest A → doc_count=1 in store; reindex → F-2 heal, still 1
///   session₂: reopen (doc_count=1), expunge A (doc_count=1, active=0),
///              ingest B (doc_count=2, active=1) → store: doc_count=2
///   session₃: reopen (doc_count=2, active=1) → guard 2!=1 → PopulationMismatch ✓
#[test]
fn t2_expunge_residue_across_reopen_population_guard() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let path = scratch_sqlite_path();

    // Session 1: ingest A and reindex (corpus path, F-2 heal).
    {
        let corpus = open_sqlite_corpus(&path);
        corpus.ingest(TEXT_A, "source-A", NOW_A)
            .expect("ingest A must succeed (session 1)");
        corpus.reindex(NOW_A)
            .expect("first reindex must succeed (session 1)");
        // corpus dropped here → "session closed"
    }

    // Session 2: reopen, expunge A, ingest B.
    {
        let corpus = open_sqlite_corpus(&path);
        // On reopen: document_count=1 (restored from store), accumulator=T_A.
        corpus.expunge("source-A")
            .expect("expunge A must succeed (session 2)");
        // document_count stays 1; active_chunks = 0. persist_maintained_counts
        // is NOT called by expunge.
        corpus.ingest(TEXT_B, "source-B", NOW_B)
            .expect("ingest B must succeed (session 2)");
        // After ingest: document_count=2, active_chunks=1.
        // persist_maintained_counts called: store → {doc_count=2, terms=T_A∪T_B}.
        // corpus dropped here
    }

    // Session 3: reopen and reindex.
    let corpus = open_sqlite_corpus(&path);
    // On reopen: document_count=2 (restored), accumulator=T_A∪T_B.
    // active_chunks = 1 (source-B only; source-A marked removed).

    corpus.reindex(NOW_B)
        .expect("second reindex must succeed (session 3)");

    let decisions = corpus.training_path_decisions();
    let path_decision = decisions.get("ppmi-v1").cloned();
    assert_eq!(
        path_decision,
        Some(TrainingPathDecision::Corpus(CorpusPathReason::PopulationMismatch)),
        "After expunge + reopen + ingest + reopen, document_count (2) must differ \
         from active_chunks (1), driving Corpus(PopulationMismatch). Got: {:?}. \
         CountsRestore here would resurrect T_A terms into the serving basis.",
        path_decision
    );

    // Verify source-A's chunks are absent from recall.
    // Dense nearest-neighbor may return source-B for an OOV query — acceptable.
    // Source-A chunks returning would indicate resurrection of expunged content.
    let a_results = corpus.recall("quantumxylograph", 10, NOW_B)
        .expect("recall must not error");
    let a_source_chunks: Vec<_> = a_results.iter()
        .filter(|r| r.chunk.source_id == "source-A")
        .collect();
    assert!(
        a_source_chunks.is_empty(),
        "No result with source_id 'source-A' must appear after expunge-A → reopen → reindex. \
         Got {} source-A result(s). Total results: {}. This indicates resurrected content.",
        a_source_chunks.len(),
        a_results.len()
    );

    // Cleanup: remove the scratch SQLite file.
    let _ = std::fs::remove_file(&path);
}
