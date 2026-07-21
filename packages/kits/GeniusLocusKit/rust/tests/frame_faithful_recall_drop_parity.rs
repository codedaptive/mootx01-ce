// frame_faithful_recall_drop_parity.rs
//
// Rust parity of the Swift FrameFaithfulRecallDropTests. The Rust recall path is
// already frame-faithful: `recall_scored_multi_lane` derives its `drawer_index`
// from `estate.recall(frame)` (the frame-filtered active set) and drops fused
// candidates absent from it via `.filter(|(id,..)| drawer_index.contains_key(id))`
// — for the DEFAULT frame and any override. These tests pin that behavior so both
// ports assert the SAME A/B/C outcomes.
//
// A (WITHDRAWN DROP) is also covered at the ARIA dispatch level by
//   packages/kits/AriaMcpKit/rust/tests/dispatch_tests.rs::withdraw_memory_removes_from_unconfirmed_set.
//   It is reasserted here at the GLK level for symmetry with Swift.
// B (FRAME OVERRIDE SURFACES) proves the drop honors the frame, not a hardcode.
// C (BURST 100%) proves the join drops zero valid active drawers.

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, Corpus, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath};
use locus_kit::adjectives::State;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str, room: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

fn make_corpus() -> Arc<CorpusContentEngine> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic]).expect("Corpus::open"))
}

/// corpusOnly request with an optional state-axis override appended to the chain.
fn corpus_only_request(query: &str, extra: Option<Filter>) -> GLKRecallRequest {
    let mut chain = vec![Filter::Unconfirmed];
    if let Some(f) = extra {
        chain.push(f);
    }
    GLKRecallRequest::new(RecallFrame::new(chain))
        .with_mode(GLKRecallMode::CorpusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_query_text(query)
        .with_limit(50)
}

// A: withdrawn drawer is dropped under the default frame (GLK level).
#[test]
fn a_withdrawn_drawer_dropped_under_default_frame() {
    let (mut coord, h) = open_one();
    let drawer = coord
        .capture(&h, cap_frame("marmalade quasar threnody withdrawn drop probe", "lab"), NOW)
        .expect("capture");

    // Inline corpus ingest (deterministic; mirrors Swift impatient).
    let corpus = make_corpus();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus);

    // Precondition: active drawer is recallable.
    let pre = coord
        .recall_scored(&h, corpus_only_request("marmalade quasar threnody", None), NOW + 1)
        .expect("recall");
    assert!(
        pre.hits.iter().any(|hh| hh.id == drawer.id && hh.sources.contains(&RecallEvidencePath::CorpusBm25)),
        "active drawer must be BM25-recallable before withdrawal"
    );

    // Withdraw → Cluster B; the corpus chunk persists (BM25 still returns the id).
    coord.withdraw(&h, &drawer.id, Some("obsolete"), NOW + 2).expect("withdraw");

    // Default frame implies CurrentlyBelieve → withdrawn excluded → dropped entirely.
    let post = coord
        .recall_scored(&h, corpus_only_request("marmalade quasar threnody", None), NOW + 3)
        .expect("recall");
    assert!(
        !post.hits.iter().any(|hh| hh.id == drawer.id),
        "withdrawn drawer must be DROPPED from default recall (absent, not phantom); hits: {:?}",
        post.hits.iter().map(|hh| hh.id.clone()).collect::<Vec<_>>()
    );
}

// B: a UsedToBelieve frame STILL surfaces the withdrawn drawer (NOT a hardcode).
#[test]
fn b_used_to_believe_frame_surfaces_withdrawn_drawer() {
    let (mut coord, h) = open_one();
    let drawer = coord
        .capture(&h, cap_frame("marmalade quasar threnody frame override probe", "lab"), NOW)
        .expect("capture");
    let corpus = make_corpus();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus);

    coord.withdraw(&h, &drawer.id, Some("obsolete"), NOW + 1).expect("withdraw");

    // Default frame drops it.
    let def = coord
        .recall_scored(&h, corpus_only_request("marmalade quasar threnody", None), NOW + 2)
        .expect("recall");
    assert!(
        !def.hits.iter().any(|hh| hh.id == drawer.id),
        "default frame must drop the withdrawn drawer"
    );

    // UsedToBelieve override admits it — the drop honors the FRAME, not a constant.
    let over = coord
        .recall_scored(
            &h,
            corpus_only_request("marmalade quasar threnody", Some(Filter::UsedToBelieve)),
            NOW + 3,
        )
        .expect("recall");
    let hit = over.hits.iter().find(|hh| hh.id == drawer.id);
    assert!(
        hit.is_some(),
        "a UsedToBelieve frame MUST surface the withdrawn drawer (frame honored); hits: {:?}",
        over.hits.iter().map(|hh| hh.id.clone()).collect::<Vec<_>>()
    );
    assert_eq!(
        hit.and_then(|hh| hh.drawer.as_ref()).map(|d| d.state()),
        Some(State::Withdrawn),
        "the surfaced override hit must carry the real withdrawn drawer"
    );
}

// C: a burst of 120 active drawers is 100% recallable — the join drops nothing.
#[test]
fn c_burst_of_120_active_drawers_all_recallable() {
    let (mut coord, h) = open_one();
    let corpus = make_corpus();

    // Unique, collision-free, high-IDF token per doc (fixed-width alpha).
    fn unique_token(i: usize) -> String {
        let padded = format!("{i:03}");
        let letters: String = padded
            .chars()
            .map(|c| (b'a' + (c as u8 - b'0')) as char)
            .collect();
        format!("qzx{letters}xq")
    }

    let n = 120usize;
    let mut id_by_index: Vec<String> = Vec::with_capacity(n);
    for i in 0..n {
        let token = unique_token(i);
        let d = coord.capture(&h, cap_frame(&token, "burst"), NOW + i as i64).expect("capture");
        // Inline ingest (deterministic, isolates the recall JOIN from any drain path).
        corpus.ingest(&d.content, &d.id, NOW + i as i64).expect("ingest");
        id_by_index.push(d.id);
    }
    coord.register_corpus(&h, corpus);

    let mut recalled = 0usize;
    let mut missing: Vec<usize> = Vec::new();
    for i in 0..n {
        let res = coord
            .recall_scored(&h, corpus_only_request(&unique_token(i), None), NOW + n as i64 + i as i64)
            .expect("recall");
        if res
            .hits
            .iter()
            .any(|hh| hh.id == id_by_index[i] && hh.sources.contains(&RecallEvidencePath::CorpusBm25))
        {
            recalled += 1;
        } else {
            missing.push(i);
        }
    }
    // HARD GATE: 100%. A valid active drawer is never dropped by the join.
    assert_eq!(
        recalled, n,
        "all {n} active drawers must be BM25-recallable (got {recalled}/{n}; missing: {missing:?})"
    );
}
