// expunge_encoder_lane.rs
//
// The encoder span lane is part of the expunge destruction contract
// (GENIUSLOCUSKIT_SPEC §B-2a step 2, §B-2b step 3a). The span-encode duty
// stores up to max_spans int8 span vectors per drawer under the ENCODER's
// model id (`<model>-w<window>`), which is neither the distillation lane nor
// the corpus model id. Expunge and the integrity sweep must delete those rows
// for the erased drawer and leave every other drawer's rows alone.
//
// Tests (twin of Swift `ExpungeEncoderLaneTests`):
//   L1 — expunge scrubs the span rows under an `encoder_models` registry id
//        (no encoder registered for the session).
//   L2 — expunge scrubs the span rows under the session's registered encoder
//        when the registry holds no row for it.
//   L3 — the integrity sweep scrubs the span rows of a crash-window row.
//
// Every test also pins the scope: a sibling drawer's span rows under the
// same model id survive the erase byte-identical.

use std::sync::Arc;

use corpus_kit::encoder::{EncoderError, EncoderModelSpec, Pooling as EncoderPooling, SpanEncoder};
use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::encoder_model_store::{EncoderModelRow, EncoderModelStore, Pooling};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::LatticeAnchor, estate_types::OwnerCredentials, frames::CaptureFrame,
};
use persistence_kit::{inmemory::InMemoryStorage, BackendConfiguration, EstateConfiguration, Storage};
use synapsekit::{SpanVectorInput, VectorStore};

const NOW: i64 = 1_700_000_000;
const NOW2: i64 = 1_700_000_001;

/// The encoder lane under test. Same literal as the Swift twin.
const ENCODER_MODEL_ID: &str = "fake-encoder-w3";

fn make_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

fn make_vector_store() -> Arc<VectorStore> {
    Arc::new(VectorStore::open(make_storage()).expect("VectorStore::open"))
}

fn make_corpus() -> Arc<CorpusContentEngine> {
    Arc::new(
        CorpusContentEngine::standalone_on(make_storage(), vec![EmbeddingModelConfig::Deterministic])
            .expect("Corpus::open"),
    )
}

/// Open one estate and hand back the estate's own storage (the LocusKit
/// schema, where `encoder_models` lives) beside the coordinator.
fn open_one() -> (EstateCoordinator, EstateHandle, Arc<dyn Storage>) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let storage = store.storage().expect("InMemoryDrawerStore exposes its storage");
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle, storage)
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "encoder-lane-tests",
        LatticeAnchor::udc("000"),
        "test-agent",
        "test-embed-v1",
    )
}

/// One `encoder_models` registry row for `ENCODER_MODEL_ID`.
fn registry_row() -> EncoderModelRow {
    EncoderModelRow {
        model_id: ENCODER_MODEL_ID.to_string(),
        model_version: "v1".to_string(),
        dim: 4,
        query_prefix: "Q:".to_string(),
        doc_prefix: "D:".to_string(),
        pooling: Pooling::Mean,
        tokenizer_hash: "abc123".to_string(),
        window_words: 3,
        overlap_divisor: 2,
        max_spans: 4,
        max_sequence: 512,
        is_active: true,
    }
}

/// A session encoder whose spec names `ENCODER_MODEL_ID`; never invoked
/// (the tests write span rows directly), it only supplies the model id.
struct FakeEncoder {
    spec: EncoderModelSpec,
}

impl FakeEncoder {
    fn new() -> Self {
        FakeEncoder {
            spec: EncoderModelSpec {
                model_id: ENCODER_MODEL_ID.to_string(),
                model_version: "v1".to_string(),
                dim: 4,
                query_prefix: "Q:".to_string(),
                doc_prefix: "D:".to_string(),
                pooling: EncoderPooling::Mean,
                tokenizer_hash: "abc123".to_string(),
                window_words: 3,
                overlap_divisor: 2,
                max_spans: 4,
                max_sequence: 512,
            },
        }
    }
}

impl SpanEncoder for FakeEncoder {
    fn spec(&self) -> &EncoderModelSpec {
        &self.spec
    }
    fn encode_query(&self, _text: &str) -> Result<Vec<f32>, EncoderError> {
        Ok(vec![0.5, -0.5, 0.25, -0.25])
    }
    fn encode_spans(&self, spans: &[&str]) -> Result<Vec<Vec<f32>>, EncoderError> {
        Ok(spans.iter().map(|_| vec![0.5, -0.5, 0.25, -0.25]).collect())
    }
}

/// Two int8 spans, the shape the span-encode duty writes. Same literals as
/// the Swift twin.
fn span_rows() -> Vec<SpanVectorInput> {
    vec![
        SpanVectorInput {
            index: 0,
            int8: vec![127, -127, 64, -64],
            scale: 0.0039,
            start_word: 0,
            end_word: 3,
            content_version: "cv-erase".to_string(),
        },
        SpanVectorInput {
            index: 1,
            int8: vec![1, -1, 2, -2],
            scale: 0.5,
            start_word: 1,
            end_word: 4,
            content_version: "cv-erase".to_string(),
        },
    ]
}

fn span_count(vs: &VectorStore, id: &str) -> usize {
    vs.span_vectors(&[id], ENCODER_MODEL_ID)
        .expect("span_vectors")
        .get(id)
        .map(|rows| rows.len())
        .unwrap_or(0)
}

/// Capture two drawers, write two span rows for each under the encoder
/// lane, and confirm both sets are present. Returns `(erase_id, keep_id)`.
fn seed_two_drawers_with_span_rows(
    coord: &EstateCoordinator,
    h: &EstateHandle,
    vs: &VectorStore,
) -> (String, String) {
    let erase = coord
        .capture(h, cap_frame("erase me: span rows must not outlive the erase"), NOW)
        .expect("capture erase");
    let keep = coord
        .capture(h, cap_frame("keep me: span rows must survive a sibling erase"), NOW)
        .expect("capture keep");
    for id in [&erase.id, &keep.id] {
        vs.write_span_vectors(id, ENCODER_MODEL_ID, "v1", &span_rows(), NOW)
            .expect("write_span_vectors");
    }
    assert_eq!(span_count(vs, &erase.id), 2, "seed: erase drawer carries two span rows");
    assert_eq!(span_count(vs, &keep.id), 2, "seed: keep drawer carries two span rows");
    (erase.id, keep.id)
}

// ---------------------------------------------------------------------------
// L1: expunge scrubs the span rows under an encoder_models registry id
// ---------------------------------------------------------------------------

/// Pre-fix the two span rows survived the expunge (only the distillation and
/// corpus-model lanes were deleted). Twin of Swift
/// `expungeScrubsRegistryEncoderLaneSpanRows`.
#[test]
fn l1_expunge_scrubs_registry_encoder_lane_span_rows() {
    let (mut coord, h, storage) = open_one();
    coord.register_corpus(&h, make_corpus());
    let vs = make_vector_store();
    let vs_ref = Arc::clone(&vs);
    coord.register_vector_store(&h, vs);
    EncoderModelStore::new(storage)
        .upsert(&registry_row())
        .expect("upsert encoder_models row");
    assert!(coord.registered_span_encoder(&h).is_none(), "L1 runs on the registry path alone");

    let (erase_id, keep_id) = seed_two_drawers_with_span_rows(&coord, &h, &vs_ref);

    let outcome = coord
        .expunge(&h, &erase_id, "encoder lane test", true, NOW2)
        .expect("expunge");
    assert!(outcome.refused_sibling_ids.is_empty());

    assert_eq!(
        span_count(&vs_ref, &erase_id),
        0,
        "expunge must delete the erased drawer's span rows under the encoder lane"
    );
    assert_eq!(span_count(&vs_ref, &keep_id), 2, "a sibling's span rows survive the erase");
}

// ---------------------------------------------------------------------------
// L2: expunge scrubs the span rows under the registered session encoder
// ---------------------------------------------------------------------------

/// The registry holds no row; the registered encoder's spec is the only
/// source of the model id. Twin of Swift
/// `expungeScrubsRegisteredEncoderLaneWithoutRegistryRow`.
#[test]
fn l2_expunge_scrubs_registered_encoder_lane_without_registry_row() {
    let (mut coord, h, storage) = open_one();
    coord.register_corpus(&h, make_corpus());
    let vs = make_vector_store();
    let vs_ref = Arc::clone(&vs);
    coord.register_vector_store(&h, vs);
    coord.register_span_encoder(&h, Arc::new(FakeEncoder::new()));
    let registry_ids: Vec<String> = EncoderModelStore::new(storage)
        .all()
        .expect("registry read")
        .into_iter()
        .map(|r| r.model_id)
        .collect();
    assert!(
        !registry_ids.iter().any(|id| id == ENCODER_MODEL_ID),
        "L2 precondition: the registry holds no row for the session encoder; got {registry_ids:?}"
    );

    let (erase_id, keep_id) = seed_two_drawers_with_span_rows(&coord, &h, &vs_ref);

    coord
        .expunge(&h, &erase_id, "encoder lane test", true, NOW2)
        .expect("expunge");

    assert_eq!(
        span_count(&vs_ref, &erase_id),
        0,
        "expunge must delete the span rows under the registered encoder's model id"
    );
    assert_eq!(span_count(&vs_ref, &keep_id), 2, "a sibling's span rows survive the erase");
}

// ---------------------------------------------------------------------------
// L3: the integrity sweep scrubs the span rows of a crash-window row
// ---------------------------------------------------------------------------

/// Crash-window (step 1 ran, steps 2 and 3 never did) leaves the span rows
/// in place; the sweep's re-delete must remove them. Twin of Swift
/// `sweepScrubsEncoderLaneSpanRows`.
#[test]
fn l3_sweep_scrubs_encoder_lane_span_rows() {
    let (mut coord, h, storage) = open_one();
    coord.register_corpus(&h, make_corpus());
    let vs = make_vector_store();
    let vs_ref = Arc::clone(&vs);
    coord.register_vector_store(&h, vs);
    EncoderModelStore::new(storage)
        .upsert(&registry_row())
        .expect("upsert encoder_models row");

    let (erase_id, keep_id) = seed_two_drawers_with_span_rows(&coord, &h, &vs_ref);

    // Crash-window: tombstone WITHOUT sealing; step 2 never runs.
    let estate = coord.estate_for(&h).expect("estate");
    let _unsealed = estate
        .expunge(&erase_id, "crash-window-sim-l3", true, NOW2, false)
        .expect("estate expunge (no seal)");
    assert_eq!(span_count(&vs_ref, &erase_id), 2, "span rows survive the crash window");

    let result = coord
        .run_expunge_integrity_sweep(&h, NOW2 + 1)
        .expect("sweep must not fail fatally");
    assert_eq!(result.remediated_count, 1, "sweep remediates the crash-window row; got {result:?}");
    assert_eq!(result.orphaned_count, 0, "got {result:?}");
    assert!(result.per_row_errors.is_empty(), "got {:?}", result.per_row_errors);

    assert_eq!(
        span_count(&vs_ref, &erase_id),
        0,
        "the sweep must delete the crash-window row's span rows under the encoder lane"
    );
    assert_eq!(span_count(&vs_ref, &keep_id), 2, "a sibling's span rows survive the sweep");
}
