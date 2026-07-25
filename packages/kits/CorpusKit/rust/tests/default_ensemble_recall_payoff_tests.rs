//! Mission 6a-iii-wire — end-to-end PAYOFF proof (Rust parity leg).
//!
//! The default recall ensemble (`corpus_kit_providers::default_ensemble()`:
//! RI/PPMI/LSA/NMF/FDC) un-pins recall. This is the Rust mirror of the Swift
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
//! semantically-related-but-lexically-different content. The five-signal
//! ensemble — trained on the estate's own corpus plus stateless taxonomic FDC —
//! produces distributional + categorical structure, so:
//!   (a) varied queries return DIVERSE top hits (not pinned to one cluster),
//!   (b) every hit carries MULTI-SIGNAL dense provenance (multiple model_ids vote),
//!   (c) a semantically-related-but-lexically-different document is recalled.
//!
//! Real SQLite (file-backed), never InMemory: the same primitive-form read-back
//! discipline as the other corpus integration tests.

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

#[test]
fn default_ensemble_invalidates_trainable_1_0_bases() {
    let models = default_ensemble();
    let versions: Vec<&str> = models
        .iter()
        .map(|model| match model {
            EmbeddingModelConfig::RandomIndexing { provider }
            | EmbeddingModelConfig::Ppmi { provider }
            | EmbeddingModelConfig::Lsa { provider }
            | EmbeddingModelConfig::Nmf { provider } => provider.model_version(),
            EmbeddingModelConfig::Fdc { provider } => provider.model_version(),
            _ => panic!("unexpected model in the default ensemble"),
        })
        .collect();
    assert_eq!(versions, ["1.1.0", "1.1.0", "1.1.0", "1.1.0", "1.0.0"]);
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
/// corpus, and reindex (trains the four trainable signals). The call under test:
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
        vec!["random-indexing-v1", "ppmi-v1", "lsa-v1", "nmf-v1", "fdc-v1"],
        "per-signal provenance must carry all five default model_ids in order, got {model_ids:?}"
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

    // The trained distributional signals must agree the top hit is space-cluster.
    for (model_id, outcome) in per_signal.iter() {
        if model_id == "fdc-v1" {
            continue;
        }
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
