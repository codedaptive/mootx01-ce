//! Mission 6a-iii-core: cross-port conformance for the Corpus N-provider
//! capability + per-signal nearest API.
//!
//! Mirrors the Swift `NProvider` suite. The load-bearing test builds an
//! N-provider Corpus with all five distributional / co-classification models
//! (RI, PPMI, LSA, NMF trained via `reindex`; FDC stateless), ingests a FIXED
//! corpus, and calls `float_nearest_per_signal`. The per-signal ranked lists
//! must equal the Swift-canonical shared fixture
//! (Tests/SharedVectors/n_provider_per_signal.json): same
//! signal order, same modelIDs, same outcome kind per signal, and — for the
//! `hits` signals — the same ranked itemID order (raw cosine similarity
//! is not compared; see lines 118-123). This proves the per-signal
//! nearest seam is cross-port deterministic for rank identity.
//!
//! Real SQLite (file-backed), never InMemory: the same primitive-form read-back
//! discipline as corpus_basis_persistence_tests.

use corpus_kit::{Corpus, EmbeddingModelConfig, FloatLaneOutcome};
use corpus_kit_providers::{
    FDCProvider, LsaProvider, NmfProvider, PpmiProvider, RandomIndexingProvider,
};
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use serde::Deserialize;
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

/// The fixed five-document corpus (vehicles / animals clusters), identical to
/// the Swift `NProviderTests.docs`. Each single-sentence doc is one chunk whose
/// text equals the doc.
const DOCS: [&str; 5] = [
    "car engine drive road vehicle",
    "vehicle road transport car fuel",
    "engine fuel combustion power car",
    "dog bark run fetch animal",
    "animal run cat dog pet",
];

const NOW_MILLIS: i64 = 1_700_000_000_000;
const PROBE: &str = "car engine";
const PER_SIGNAL_LIMIT: usize = 5;

/// The Swift-canonical shared fixture (also embedded by the Swift leg).
const N_PER_SIGNAL_FIXTURE: &[u8] =
    include_bytes!("../../Tests/SharedVectors/n_provider_per_signal.json");

fn scratch_path() -> String {
    std::env::temp_dir()
        .join(format!("corpuskit-nprov-rust-{}.sqlite3", Uuid::new_v4()))
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

/// The five 6a-iii signals, freshly constructed in the same slot order as the
/// Swift `allFiveModels()`. The four distributional / matrix providers are
/// trainable (trained via `reindex`); FDC is stateless.
fn all_five_models() -> Vec<EmbeddingModelConfig> {
    vec![
        EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        },
        EmbeddingModelConfig::Ppmi {
            provider: Box::new(PpmiProvider::new()),
        },
        // LSA/NMF use their canonical default constructors (same rank / sweeps /
        // iterations / seeds as the Swift parameterless inits) so the trained
        // bases — and therefore the per-signal rankings — match Swift bit-for-bit.
        EmbeddingModelConfig::Lsa {
            provider: Box::new(LsaProvider::default_new()),
        },
        EmbeddingModelConfig::Nmf {
            provider: Box::new(NmfProvider::default_new()),
        },
        EmbeddingModelConfig::Fdc {
            provider: Box::new(FDCProvider::default_provider()),
        },
    ]
}

// ── Shared fixture model (mirrors the Swift NPerSignalFixture) ──

#[derive(Debug, Deserialize)]
struct Signal {
    #[serde(rename = "modelID")]
    model_id: String,
    kind: String,
    #[serde(rename = "rankedItemIDs")]
    ranked_item_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct NPerSignalFixture {
    probe: String,
    limit: i64,
    signals: Vec<Signal>,
}

/// Encode a FloatLaneOutcome into the fixture's (kind, rankedItemIDs) shape,
/// matching the Swift `encodeOutcome`. The cross-port contract is RANK IDENTITY
/// (outcome kind + ranked itemID order); raw cosine similarity is NOT compared —
/// the float lane is reproducible-within-config, not four-way bit-identical
/// (arch spec §6 / VECTORKIT_SPEC), so cosine accumulation/FMA differences
/// perturb the low float bits without changing the rank order.
fn encode_outcome(outcome: &FloatLaneOutcome) -> (String, Vec<String>) {
    match outcome {
        FloatLaneOutcome::Hits(pairs) => (
            "hits".to_string(),
            pairs.iter().map(|(item_id, _sim)| item_id.clone()).collect(),
        ),
        FloatLaneOutcome::UnavailableProviderOptOut => ("dark_provider".to_string(), vec![]),
        FloatLaneOutcome::UnavailableNoFloatRows => ("dark_no_rows".to_string(), vec![]),
        // Trained distributional provider, all query tokens OOV — truthful relabel
        // added by the Bug-A fix (vocabMiss != providerOptOut).
        FloatLaneOutcome::UnavailableNoVocabHit => ("dark_vocab_miss".to_string(), vec![]),
        FloatLaneOutcome::EmptyQuery => ("empty_query".to_string(), vec![]),
        FloatLaneOutcome::StoreError(_) => ("store_error".to_string(), vec![]),
    }
}

#[test]
fn all_five_per_signal_matches_shared_fixture() {
    let _g = global_lock();

    let fixture: NPerSignalFixture =
        serde_json::from_slice(N_PER_SIGNAL_FIXTURE).expect("decode shared fixture");
    assert_eq!(fixture.probe, PROBE, "fixture probe must match");
    assert_eq!(fixture.limit, PER_SIGNAL_LIMIT as i64, "fixture limit must match");

    let path = scratch_path();
    let corpus = Corpus::open_many(storage_at(&path), all_five_models())
        .expect("Corpus::open_many must succeed with all five models");
    for (i, doc) in DOCS.iter().enumerate() {
        corpus
            .ingest(doc, &format!("doc-{i}"), NOW_MILLIS)
            .expect("ingest");
    }
    // Train the four trainable signals from scratch on the fixed corpus; FDC is
    // stateless (vector refresh only).
    corpus.reindex(NOW_MILLIS).expect("reindex");

    let per_signal = corpus.float_nearest_per_signal(PROBE, PER_SIGNAL_LIMIT);

    assert_eq!(
        per_signal.len(),
        fixture.signals.len(),
        "signal count must match the Swift-canonical fixture"
    );

    for (observed, expected) in per_signal.iter().zip(fixture.signals.iter()) {
        let (model_id, outcome) = observed;
        assert_eq!(
            model_id, &expected.model_id,
            "signal modelID mismatch (slot order must match Swift)"
        );

        let (obs_kind, obs_ranked) = encode_outcome(outcome);
        assert_eq!(
            obs_kind, expected.kind,
            "per-signal outcome kind for {model_id} must match the fixture"
        );
        assert_eq!(
            obs_ranked, expected.ranked_item_ids,
            "per-signal ranked itemID order for {model_id} must match the \
             Swift-canonical fixture (rank identity is the cross-port contract)"
        );
    }
}

/// N=1 back-compat: `open_many` with a one-element vec equals `open` on the
/// default-signal float lane, and `float_nearest_per_signal` returns exactly one
/// entry whose outcome equals the single-signal `float_nearest`.
#[test]
fn single_element_open_many_matches_open() {
    let _g = global_lock();

    let via_open =
        Corpus::open(storage_at(&scratch_path()), EmbeddingModelConfig::Deterministic)
            .expect("open");
    let via_open_many = Corpus::open_many(
        storage_at(&scratch_path()),
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("open_many");

    for (i, doc) in DOCS.iter().enumerate() {
        via_open.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("ingest a");
        via_open_many
            .ingest(doc, &format!("doc-{i}"), NOW_MILLIS)
            .expect("ingest b");
    }

    assert_eq!(via_open.model_id(), via_open_many.model_id());

    let a = encode_outcome(&via_open.float_nearest(PROBE, PER_SIGNAL_LIMIT));
    let b = encode_outcome(&via_open_many.float_nearest(PROBE, PER_SIGNAL_LIMIT));
    assert_eq!(a, b, "single-model and single-element float lanes must be identical");

    let per_signal = via_open_many.float_nearest_per_signal(PROBE, PER_SIGNAL_LIMIT);
    assert_eq!(per_signal.len(), 1);
    assert_eq!(per_signal[0].0, via_open_many.model_id());
    assert_eq!(encode_outcome(&per_signal[0].1), b);
}
