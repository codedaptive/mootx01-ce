//! Mission 6a-iii-wire — end-to-end PAYOFF proof (Rust parity leg).
//!
//! The default recall ensemble (`corpus_kit_providers::default_ensemble()`:
//! RI then LSA) un-pins recall. This is the Rust mirror of the Swift
//! `DefaultEnsembleRecallPayoffTests`: the Corpus built here is exactly the one
//! the Rust GLK provision path (via the moot-mgr / ARIA_MCP app callers) and
//! `estate_registry` now construct (all thread `default_ensemble()` into
//! `Corpus::open_many`), so proving the un-pinning here proves it for every Rust
//! production provision site.
//!
//! What "un-pinning" means and why it is the payoff
//! ------------------------------------------------
//! A single fake/hash lane (the old `Deterministic` default) collapses recall
//! onto a handful of lexically-overlapping documents and misses
//! semantically-related-but-lexically-different content. The two-signal
//! ensemble — both signals trained on the estate's own corpus — produces
//! distributional structure, so:
//!   (a) varied queries return DIVERSE top hits (not pinned to one cluster),
//!   (b) every hit carries MULTI-SIGNAL dense provenance (multiple model_ids vote),
//!   (c) a semantically-related-but-lexically-different document is recalled.
//!
//! Real SQLite (file-backed), never InMemory: the same primitive-form read-back
//! discipline as the other corpus integration tests.

// The payoff under proof is the default dense ensemble: RI and LSA, both always-on.

use corpus_kit::{Corpus, EmbeddingModelConfig, FloatLaneOutcome};
use corpus_kit_providers::default_ensemble;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use std::collections::HashSet;
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

// Process-wide lock: Corpus.ingest / reindex emit IntellectusLib telemetry and
// the SQLite scratch files must not race. Shared discipline with corpus_tests.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    match GLOBAL_LOCK.get_or_init(|| Mutex::new(())).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

/// A diverse multi-topic corpus spanning four clearly separated topical clusters
/// (space / cooking / finance / gardening), identical to the Swift
/// `DefaultEnsembleRecallPayoffTests.docs`. Each doc is one chunk.
const DOCS: [(&str, &str); 12] = [
    ("space-1", "rocket launch orbit satellite spacecraft mission"),
    ("space-2", "astronaut spacecraft orbit station module docking"),
    ("space-3", "telescope galaxy star planet nebula cosmos observation"),
    ("cook-1", "recipe oven bake bread flour yeast dough"),
    ("cook-2", "saute pan onion garlic simmer sauce stove"),
    ("cook-3", "knife chop vegetable dice prep cutting board"),
    ("fin-1", "invest portfolio stock bond dividend market return"),
    ("fin-2", "budget savings expense income loan interest rate"),
    ("fin-3", "tax filing deduction revenue accounting ledger audit"),
    ("garden-1", "soil seed plant water sunlight grow sprout"),
    ("garden-2", "prune shrub hedge trim branch leaf foliage"),
    ("garden-3", "compost fertilizer nutrient root mulch garden bed"),
];

const NOW_MILLIS: i64 = 1_700_000_000_000;

/// Both default signals carry the 1.1.0 basis version, so a persisted 1.0
/// basis is invalidated and retrained rather than restored.
#[test]
fn default_ensemble_invalidates_trainable_1_0_bases() {
    let models = default_ensemble();
    let versions: Vec<&str> = models
        .iter()
        .map(|model| match model {
            EmbeddingModelConfig::RandomIndexing { provider }
            | EmbeddingModelConfig::Lsa { provider } => provider.model_version(),
            _ => panic!("unexpected model in the default ensemble"),
        })
        .collect();
    assert_eq!(versions, ["1.1.0", "1.1.0"]);
}

fn scratch_path() -> String {
    std::env::temp_dir()
        .join(format!("corpuskit-payoff-rust-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

fn storage_at(path: &str) -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    Arc::new(SqliteStorage::new(config).expect("open sqlite"))
}

/// Build a Corpus on the canonical default ensemble, ingest the diverse
/// corpus, and reindex (trains both signals). The call under test:
/// `default_ensemble()` — the exact set the Rust production provision sites thread.
fn make_trained_ensemble_corpus() -> Corpus {
    let corpus =
        Corpus::open_many(storage_at(&scratch_path()), default_ensemble()).expect("open_many");
    for (id, text) in DOCS.iter() {
        corpus.ingest(text, id, NOW_MILLIS).expect("ingest");
    }
    corpus.reindex(NOW_MILLIS).expect("reindex");
    corpus
}

/// Pull ranked item ids out of a FloatLaneOutcome (default / per-signal).
fn ranked_ids(outcome: &FloatLaneOutcome) -> Vec<String> {
    match outcome {
        FloatLaneOutcome::Hits(pairs) => pairs.iter().map(|(id, _)| id.clone()).collect(),
        _ => Vec::new(),
    }
}

// (a) varied queries return DIVERSE hits (recall is NOT pinned)
#[test]
fn varied_queries_are_not_pinned() {
    let _guard = global_lock();
    let corpus = make_trained_ensemble_corpus();

    // Four queries, one per topical cluster; the top hit must differ across them.
    let queries: [(&str, &str); 4] = [
        ("orbit spacecraft mission", "space"),
        ("bake bread oven", "cook"),
        ("invest stock portfolio", "fin"),
        ("plant soil water grow", "garden"),
    ];

    let mut top_hits: Vec<String> = Vec::new();
    for (probe, cluster) in queries.iter() {
        let outcome = corpus.float_nearest(probe, 3);
        let ids = ranked_ids(&outcome);
        assert!(!ids.is_empty(), "query '{probe}' must return ranked hits");
        let top = ids[0].clone();
        assert!(
            top.starts_with(cluster),
            "query '{probe}' top hit '{top}' must be in cluster '{cluster}'"
        );
        top_hits.push(top);
    }

    // UN-PINNING: the four queries do NOT collapse onto the same documents.
    let distinct: HashSet<&String> = top_hits.iter().collect();
    assert_eq!(
        distinct.len(),
        queries.len(),
        "varied queries must recall DISTINCT top documents (un-pinned), got {top_hits:?}"
    );
}

// (b) hits carry MULTI-SIGNAL dense provenance (multiple model_ids vote)
#[test]
fn hits_carry_multi_signal_provenance() {
    let _guard = global_lock();
    let corpus = make_trained_ensemble_corpus();

    let per_signal = corpus.float_nearest_per_signal("orbit spacecraft mission", 3);

    let model_ids: Vec<&str> = per_signal.iter().map(|(id, _)| id.as_str()).collect();
    assert_eq!(
        model_ids,
        vec!["random-indexing-v1", "lsa-v1"],
        "per-signal provenance must carry both default model_ids in order, got {model_ids:?}"
    );

    // MULTI-SIGNAL VOTING: more than one signal must produce ranked hits.
    let voting: Vec<&str> = per_signal
        .iter()
        .filter(|(_, o)| !ranked_ids(o).is_empty())
        .map(|(id, _)| id.as_str())
        .collect();
    assert!(
        voting.len() >= 2,
        "at least two dense signals must vote on the query, got {} ({voting:?})",
        voting.len()
    );

    // Both trained distributional signals must agree the top hit is space-cluster.
    for (model_id, outcome) in per_signal.iter() {
        let ids = ranked_ids(outcome);
        if let Some(top) = ids.first() {
            assert!(
                top.starts_with("space"),
                "signal {model_id} top hit {top} should be in space cluster"
            );
        }
    }
}

// (c) semantically-related-but-lexically-different recall (BM25 misses)
#[test]
fn semantic_not_lexical_recall() {
    let _guard = global_lock();
    let corpus = make_trained_ensemble_corpus();

    // Probe = cook-1's baking vocabulary only. cook-3 shares ZERO tokens with the
    // probe, so a lexical (BM25) match scores it at zero. The trained ensemble
    // learned cook-1/2/3 co-occur, so the dense lane still surfaces cook-3.
    let probe_tokens: HashSet<&str> = ["oven", "bake", "flour", "dough"].into_iter().collect();
    let cook3_tokens: HashSet<&str> =
        ["knife", "chop", "vegetable", "dice", "prep", "cutting", "board"]
            .into_iter()
            .collect();
    assert!(
        probe_tokens.is_disjoint(&cook3_tokens),
        "test premise: probe and cook-3 must share no surface token"
    );

    let outcome = corpus.float_nearest("oven bake flour dough", 12);
    let ids = ranked_ids(&outcome);
    assert!(!ids.is_empty(), "semantic probe must return ranked hits");
    assert!(
        ids.iter().any(|id| id == "cook-3"),
        "ensemble must recall the lexically-disjoint cooking doc cook-3; recalled: {ids:?}"
    );
}

// MARK: - Gate proofs: default ensemble composition and LSA lane

/// Gate proof 1 — `default_ensemble()` must return exactly two configs: RI then LSA.
/// Validates the always-on ensemble contract (DENSE_LANE_TRIM ruling).
#[test]
fn default_ensemble_is_ri_and_lsa() {
    let ensemble = default_ensemble();
    assert_eq!(ensemble.len(), 2, "default ensemble must contain exactly two signals");
    assert!(
        matches!(ensemble[0], EmbeddingModelConfig::RandomIndexing { .. }),
        "first config must be RandomIndexing (RI)"
    );
    assert!(
        matches!(ensemble[1], EmbeddingModelConfig::Lsa { .. }),
        "second config must be Lsa"
    );
}

/// Gate proof 2 — the LSA lane encodes two drawers with disjoint vocabulary
/// and ranks the on-topic one first. Uses the public
/// `Corpus::float_nearest_per_signal` surface on a real SQLite scratch estate
/// and reads the `lsa-v1` entry, so the proof is about the LSA signal itself
/// and not the default (RI) slot that `float_nearest` serves.
#[test]
fn lsa_lane_float_nearest_returns_hits_on_scratch_estate() {
    let _guard = global_lock();
    let storage = storage_at(&scratch_path());
    let corpus = Corpus::open_many(storage, default_ensemble())
        .expect("Corpus::open_many must succeed with default ensemble");

    corpus.ingest("rocket launch orbit satellite spacecraft mission", "doc-space", NOW_MILLIS)
        .expect("ingest doc-space");
    corpus.ingest("recipe oven bake bread flour yeast dough", "doc-cook", NOW_MILLIS)
        .expect("ingest doc-cook");
    // Reindex trains the RI and LSA bases; untrained distributional lanes hold
    // no float rows. The query is drawn from doc-space's vocabulary so the
    // trained basis folds it in (an out-of-vocabulary query has no vector).
    corpus.reindex(NOW_MILLIS).expect("reindex");

    let per_signal = corpus.float_nearest_per_signal("rocket orbit", 10);
    let (_, outcome) = per_signal
        .iter()
        .find(|(model_id, _)| model_id == "lsa-v1")
        .expect("the default ensemble holds an lsa-v1 signal");
    match outcome {
        FloatLaneOutcome::Hits(hits) => {
            let ids: Vec<&str> = hits.iter().map(|(id, _)| id.as_str()).collect();
            assert_eq!(
                ids.first().copied(),
                Some("doc-space"),
                "the LSA lane must rank the on-topic drawer first, got {ids:?}"
            );
            assert_ne!(
                ids.last().copied(),
                Some("doc-space"),
                "doc-cook must rank below doc-space when both are returned, got {ids:?}"
            );
        }
        other => panic!("expected Hits from the LSA lane on the scratch estate, got {other:?}"),
    }
}
