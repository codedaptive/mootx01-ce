//! The retrieval-time cross-encoder stage. Mirrors Swift
//! CrossEncoderStageTests.swift:
//!
//!   fuse      — every case of the shared fixture
//!               (SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json)
//!               reproduces its order exactly.
//!   spans     — the windowed fallback and the span-row path select bounded,
//!               non-empty texts; empty content selects nothing.
//!   director  — on a 200-drawer in-memory estate: a None directive is
//!               byte-identical; bypass only attaches a report; apply reaches
//!               the registered scorer, reorders within the pool, re-cuts to
//!               the caller's limit and reports applied; the manifest limits
//!               clamp; an unknown profile, missing query text, missing model
//!               and a failing scorer degrade with their reason; close drops
//!               the scorer.
//!   packaged  — with MOOT_CROSS_ENCODER_ASSETS set (and the `cross-encoder`
//!               feature on) the real candle classifier loads once through the
//!               product's resolver and the apply reports `candle`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use corpus_kit::encoder::{
    CrossEncoderProfile, EncoderError, PairScorer, RerankDirective,
};
use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::cross_encoder_stage::{
    self as stage, reason, CrossEncoderLimits, CrossEncoderReport, CrossEncoderStatus,
    DEGRADED_STAGE,
};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring, RecallFallbackPolicy,
    RecallOrigin,
};
use genius_locus_kit::span_rerank::{SpanRerankVector, StrictSpanRerankVector};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::RecallFrame;
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_000;

// ── fuse parity ──────────────────────────────────────────────────────────────

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json")
}

#[test]
fn every_fixture_case_reproduces_the_lab_order() {
    let text = std::fs::read_to_string(fixture_path()).expect("fixture");
    let fixture: serde_json::Value = serde_json::from_str(&text).expect("json");
    let cases = fixture["cases"].as_array().expect("cases");
    assert!(cases.len() >= 6);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let incoming: Vec<String> = case["incoming"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let head = case["head"].as_u64().unwrap() as usize;
        let rrf_k = case["rrf_k"].as_u64().unwrap() as usize;
        let mut logits: HashMap<String, Vec<f32>> = HashMap::new();
        for (id, values) in case["logits"].as_object().unwrap() {
            logits.insert(id.clone(), values.as_array().unwrap().iter().map(|v| v.as_f64().unwrap() as f32).collect());
        }
        let expected: Vec<String> = case["expected"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
        assert_eq!(stage::fuse(&incoming, head, &logits, rrf_k), expected, "{name}");
    }
}

#[test]
fn fuse_edges() {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    let mut logits = HashMap::new();
    logits.insert("zzz".to_string(), vec![99.0]);
    logits.insert("b".to_string(), vec![1.0]);
    // `zzz` is outside the pool; `a` unscored and `b` scored tie on RRF and
    // the tie keeps the incoming order.
    assert_eq!(stage::fuse(&s(&["a", "b"]), 30, &logits, 60), s(&["a", "b"]));
    let mut c = HashMap::new();
    c.insert("c".to_string(), vec![5.0]);
    assert_eq!(stage::fuse(&s(&["a", "b", "c"]), 30, &c, 60), s(&["a", "c", "b"]));
    assert_eq!(stage::fuse(&s(&["a"]), 0, &c, 60), s(&["a"]));
}

// ── span selection ───────────────────────────────────────────────────────────

#[test]
fn windowed_fallback_yields_bounded_spans() {
    let content: Vec<String> = (0..130).map(|i| format!("w{i}")).collect();
    let content = content.join(" ");
    let spans = stage::select_spans(&content, None, None, 3, 60, 2);
    assert_eq!(spans.len(), 3);
    assert!(spans.iter().all(|s| !s.is_empty() && s.split(' ').count() <= 60));
    assert!(spans[0].starts_with("w0 w1 "));
    assert!(spans[2].starts_with("w60 ") && spans[2].ends_with(" w119"));
    assert!(stage::select_spans("   ", None, None, 3, 60, 2).is_empty());
    assert!(stage::select_spans(&content, None, None, 0, 60, 2).is_empty());
}

#[test]
fn span_rows_are_ranked_by_cosine_and_rebuilt_from_bounds() {
    let content: Vec<String> = (0..20).map(|i| format!("w{i}")).collect();
    let content = content.join(" ");
    let rows = vec![
        SpanRerankVector { index: 0, int8: vec![10, 0], scale: 0.01, start_word: 0, end_word: 5 },
        SpanRerankVector { index: 1, int8: vec![100, 0], scale: 0.01, start_word: 5, end_word: 10 },
        SpanRerankVector { index: 2, int8: vec![50, 0], scale: 0.01, start_word: 10, end_word: 40 },
    ];
    let spans = stage::select_spans(&content, Some(&rows), Some(&[1.0, 0.0]), 2, 60, 2);
    assert_eq!(spans, vec!["w5 w6 w7 w8 w9".to_string(), "w10 w11 w12 w13 w14 w15 w16 w17 w18 w19".to_string()]);
    let wrong = vec![SpanRerankVector { index: 0, int8: vec![1, 2, 3], scale: 1.0, start_word: 0, end_word: 5 }];
    let fallback = stage::select_spans(&content, Some(&wrong), Some(&[1.0, 0.0]), 2, 60, 2);
    assert_eq!(fallback, vec![content.clone()]);
}

#[test]
fn strict_span_selection_requires_fresh_rows_and_never_windows() {
    let content = "zero one two three four five";
    let fresh = vec![StrictSpanRerankVector {
        vector: SpanRerankVector { index: 0, int8: vec![127, 0], scale: 0.01, start_word: 0, end_word: 3 },
        content_version: genius_locus_kit::span_content_version::span_content_version(content),
    }];
    assert_eq!(
        stage::select_strict_spans(content, &fresh, &[1.0, 0.0], 3, &genius_locus_kit::span_content_version::span_content_version(content)).unwrap(),
        vec!["zero one two".to_string()]
    );
    let mut stale = fresh.clone();
    stale[0].content_version = "0000000000000000".to_string();
    assert_eq!(stage::select_strict_spans(content, &stale, &[1.0, 0.0], 3, &genius_locus_kit::span_content_version::span_content_version(content)), Err(reason::STRICT_SPANS_STALE));
    assert_eq!(stage::select_strict_spans(content, &[], &[1.0, 0.0], 3, &genius_locus_kit::span_content_version::span_content_version(content)), Err(reason::STRICT_SPANS_UNAVAILABLE));
}

#[test]
fn transcript_eligibility_accepts_declared_and_multiline_legacy_turns() {
    use locus_kit::drawer::Drawer;
    use locus_kit::drawer_operational::ContentKind;

    let legacy = Drawer::new("legacy", "\nUser:\nThe LME summary is attached.\nIt includes the evidence receipt.\n\nAssistant: I will preserve the receipt\nand keep the original query bytes.", "room", "test", NOW, "test");
    assert_eq!(stage::classify_transcript(&legacy), stage::TranscriptEligibility::LegacyRoleTurns);
    let prose = Drawer::new("prose", "The report begins with an editorial note.\nUser: where is the file?\nAssistant: it is in the cabinet", "room", "test", NOW, "test");
    assert_eq!(stage::classify_transcript(&prose), stage::TranscriptEligibility::NotTranscript);
    let quoted = Drawer::new("quoted", "> User: where is the file?\n> Assistant: it is in the cabinet", "room", "test", NOW, "test");
    assert_eq!(stage::classify_transcript(&quoted), stage::TranscriptEligibility::NotTranscript);
    let mut declared = Drawer::new("declared", "ordinary prose remains authoritative when declared transcript", "room", "test", NOW, "test");
    declared.operational_bitmap = ContentKind::Transcript.raw_value() << 6;
    assert_eq!(stage::classify_transcript(&declared), stage::TranscriptEligibility::DeclaredTranscript);
}

#[test]
fn strict_transcript_pool_retains_eligible_hits_in_order() {
    let (coord, h) = open_estate();
    let result = coord.recall_scored(&h, request(3, Some(QUERY), None, None), NOW + 1000).unwrap();
    let mut eligible = result.hits[0].clone();
    eligible.drawer.as_mut().unwrap().operational_bitmap = 2 << 6;
    let prose = result.hits[1].clone();
    let mut quoted = result.hits[2].clone();
    quoted.drawer.as_mut().unwrap().content = "> User: where is the file?\n> Assistant: it is in the cabinet".to_string();
    let filtered = stage::strict_transcript_pool(&[eligible.clone(), prose, quoted]);
    assert_eq!(filtered.iter().map(|hit| &hit.id).collect::<Vec<_>>(), vec![&eligible.id]);
}

#[test]
fn strict_transcript_pool_excludes_sensitive_and_unknown_capture_provenance() {
    let (coord, h) = open_estate();
    let result = coord.recall_scored(&h, request(1, Some(QUERY), None, None), NOW + 1000).unwrap();
    for raw in [0_i64, 16, 32, 48, 63] {
        let mut hit = result.hits[0].clone();
        let drawer = hit.drawer.as_mut().unwrap();
        drawer.operational_bitmap = 2 << 6; // Declared transcript, regardless of wording.
        drawer.provenance = raw << 30;
        let selected = stage::strict_transcript_pool(&[hit.clone()]);
        if raw == 0 || raw == 16 {
            assert_eq!(selected.len(), 1);
            assert_eq!(selected[0].id, hit.id);
        } else {
            assert!(selected.is_empty(), "capture sensitivity {raw} reached strict pool");
        }
    }
}

// ── director ─────────────────────────────────────────────────────────────────

/// Records every (query, spans) it scores; a span carrying `favored` wins.
struct FakePairScorer {
    profile: CrossEncoderProfile,
    favored: String,
    calls: Arc<Mutex<Vec<(String, Vec<String>)>>>,
    failing: bool,
}

impl FakePairScorer {
    fn new(favored: &str, failing: bool) -> (Arc<Self>, Arc<Mutex<Vec<(String, Vec<String>)>>>) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        (
            Arc::new(Self { profile: CrossEncoderProfile::minilm_l6(), favored: favored.to_string(), calls: Arc::clone(&calls), failing }),
            calls,
        )
    }
}

impl PairScorer for FakePairScorer {
    fn profile(&self) -> &CrossEncoderProfile { &self.profile }
    fn backend(&self) -> &str { "fake" }
    fn score(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError> {
        self.calls.lock().unwrap().push((query.to_string(), spans.iter().map(|s| s.to_string()).collect()));
        if self.failing {
            return Err(EncoderError::InferenceFailed("fake failure".into()));
        }
        Ok(spans.iter().map(|s| if s.contains(&self.favored) { 10.0 } else { -10.0 }).collect())
    }
}

/// 200 drawers; every fourth carries the query terms at differing lengths and
/// every drawer carries a unique `tag<i>zz` token so a scorer can favour one.
fn open_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).expect("open");
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic]).expect("corpus"),
    );
    for i in 0..200usize {
        let padding: Vec<String> = (0..(i % 9 + 1)).map(|p| format!("filler{}", p + i)).collect();
        let content = if i % 4 == 0 {
            format!("ledger note tag{i}zz {} reconciled by clerk {}", padding.join(" "), i % 13)
        } else {
            format!("invoice archive tag{i}zz {} filed by assistant {}", padding.join(" "), i % 11)
        };
        let frame = CaptureFrame::new(
            &content, CaptureChannel::Typed, "cross-stage-tests", LatticeAnchor::udc("0"), "test-agent", "test-embed-v1",
        );
        let drawer = coord.capture(&h, frame, NOW + i as i64).expect("capture");
        corpus.ingest(&content, &drawer.id, NOW).expect("ingest");
    }
    coord.register_corpus(&h, corpus);
    (coord, h)
}

fn request(limit: usize, query: Option<&str>, frontier_k: Option<usize>, directive: Option<RerankDirective>) -> GLKRecallRequest {
    // Full hydration, as the Swift twin requests: the stage pairs the query
    // with the hydrated content, so a body-free hit is unscored.
    let mut frame = RecallFrame::new(vec![]);
    frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    let mut req = GLKRecallRequest::new(
        frame,
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        limit,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    );
    if let Some(q) = query {
        req = req.with_query_text(q);
    }
    if let Some(k) = frontier_k {
        req = req.with_frontier_k(k);
    }
    if let Some(d) = directive {
        req = req.with_rerank_directive(d);
    }
    req
}

const QUERY: &str = "ledger reconciled clerk";

fn ids(r: &GLKRecallResult) -> Vec<String> {
    r.hits.iter().map(|h| h.id.clone()).collect()
}

/// The page an apply widens to: the pool as the limit, at the frontier the
/// caller's own limit-20 request computes (`min(max(20 × 4, 64), 256)`).
fn pool_page(coord: &EstateCoordinator, h: &genius_locus_kit::handle::EstateHandle) -> GLKRecallResult {
    coord.recall_scored(h, request(50, Some(QUERY), Some(80), None), NOW + 1000).expect("wide")
}

#[test]
fn none_is_byte_identical_and_bypass_only_attaches_a_report() {
    let (coord, h) = open_estate();
    let plain = coord.recall_scored(&h, request(20, Some(QUERY), None, None), NOW + 1000).unwrap();
    assert!(plain.hits.len() >= 20);
    assert!(plain.cross_encoder.is_none());
    let again = coord.recall_scored(&h, request(20, Some(QUERY), None, None), NOW + 1000).unwrap();
    assert_eq!(ids(&again), ids(&plain));
    let bypass = coord
        .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::bypass(Some("strategy")))), NOW + 1000)
        .unwrap();
    assert_eq!(ids(&bypass), ids(&plain));
    let report = bypass.cross_encoder.as_ref().expect("report");
    assert_eq!(report.status, CrossEncoderStatus::Bypassed);
    assert!(!report.requested);
    assert_eq!(report.reason.as_deref(), Some("strategy"));
    assert_eq!(bypass.degraded_stages, plain.degraded_stages);
    assert_eq!(bypass.request.rerank_directive, Some(RerankDirective::bypass(Some("strategy"))));
}

#[test]
fn apply_reaches_the_scorer_reorders_within_the_pool_and_reports_applied() {
    let (mut coord, h) = open_estate();
    let wide = pool_page(&coord, &h);
    assert!(wide.hits.len() > 20);
    let favored_hit = &wide.hits[5];
    let favored_index_before = 5usize;
    let favored = favored_hit
        .drawer
        .as_ref()
        .unwrap()
        .content
        .split(' ')
        .find(|w| w.starts_with("tag"))
        .unwrap()
        .to_string();
    let (scorer, calls) = FakePairScorer::new(&favored, false);
    coord.register_pair_scorer(&h, scorer);

    let applied = coord
        .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::apply(Some("explicit")))), NOW + 1000)
        .unwrap();
    let report = applied.cross_encoder.as_ref().expect("report");
    assert_eq!(report.status, CrossEncoderStatus::Applied);
    assert!(report.requested);
    assert_eq!(report.reason.as_deref(), Some("explicit"));
    assert_eq!(report.backend.as_deref(), Some("fake"));
    assert_eq!(report.profile_id, CrossEncoderProfile::minilm_l6().model_id);
    assert_eq!(report.model_version.as_deref(), Some("233902d25c440f23af6f7d6e94d2946bac0bee0a"));
    assert_eq!(report.pool, 50usize.min(wide.hits.len()));
    assert_eq!(report.head, 30usize.min(report.pool));
    assert_eq!(report.spans, 3);
    assert_eq!(report.scored, report.head);
    assert!(!report.cold_load);
    assert!(report.stage_millis.is_some());
    assert_eq!(applied.hits.len(), 20);
    assert_eq!(applied.request.limit, 20);
    let pool_ids: std::collections::HashSet<String> = wide.hits.iter().take(report.pool).map(|h| h.id.clone()).collect();
    assert!(applied.hits.iter().all(|h| pool_ids.contains(&h.id)));
    let favored_index_after = applied.hits.iter().position(|h| h.id == favored_hit.id).expect("favored stays");
    assert!(favored_index_after < favored_index_before, "{favored_index_after} vs {favored_index_before}");
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), report.head);
    assert!(calls.iter().all(|(q, spans)| q == QUERY && !spans.is_empty() && spans.len() <= 3));
    assert!(calls.iter().any(|(_, spans)| spans.iter().any(|s| s.contains(&favored))));
    // The full encoding is covered by `summary_line_encodes_all_applied_fields` below.
}

#[test]
fn manifest_limits_clamp_pool_head_and_spans() {
    let (mut coord, h) = open_estate();
    let profile = CrossEncoderProfile::minilm_l6();
    coord.provision_cross_encoder_limits(&h, 8, 4, 1).unwrap();
    assert_eq!(coord.provisioned_cross_encoder_limits(&h, &profile), CrossEncoderLimits::new(8, 4, 1));
    coord.provision_cross_encoder_limits(&h, 500, 400, 9).unwrap();
    assert_eq!(coord.provisioned_cross_encoder_limits(&h, &profile), CrossEncoderLimits::new(50, 30, 3));
    coord.provision_cross_encoder_limits(&h, 8, 4, 1).unwrap();
    let (scorer, calls) = FakePairScorer::new("none", false);
    coord.register_pair_scorer(&h, scorer);
    let applied = coord
        .recall_scored(&h, request(5, Some(QUERY), None, Some(RerankDirective::apply(None))), NOW + 1000)
        .unwrap();
    let report = applied.cross_encoder.as_ref().unwrap();
    assert_eq!(report.status, CrossEncoderStatus::Applied);
    assert_eq!((report.pool, report.head, report.spans), (8, 4, 1));
    assert_eq!(applied.hits.len(), 5);
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), 4);
    assert!(calls.iter().all(|(_, spans)| spans.len() == 1));
}

#[test]
fn degrades_carry_their_reason_and_the_incoming_order() {
    let (mut coord, h) = open_estate();
    let plain = coord.recall_scored(&h, request(20, Some(QUERY), None, None), NOW + 1000).unwrap();
    let wide = pool_page(&coord, &h);
    let pool_head: Vec<String> = wide.hits.iter().take(20).map(|h| h.id.clone()).collect();

    let unknown = coord
        .recall_scored(
            &h,
            request(20, Some(QUERY), None, Some({ let mut directive = RerankDirective::apply(None); directive.profile_id = "nope-v9".into(); directive })),
            NOW + 1000,
        )
        .unwrap();
    assert_eq!(ids(&unknown), ids(&plain));
    let r = unknown.cross_encoder.as_ref().unwrap();
    assert_eq!(r.status, CrossEncoderStatus::Degraded);
    assert_eq!(r.reason.as_deref(), Some(reason::PROFILE_UNKNOWN));
    assert!(unknown.degraded_stages.iter().any(|s| s == DEGRADED_STAGE));

    let no_model = coord
        .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::apply(None))), NOW + 1000)
        .unwrap();
    assert_eq!(ids(&no_model), pool_head);
    let r = no_model.cross_encoder.as_ref().unwrap();
    assert_eq!(r.status, CrossEncoderStatus::Degraded);
    // Without the feature the activation returns `capability_off`; with it,
    // it tries to load the model and returns `model_unavailable` when no
    // directory is registered (no resolver configured in this test).
    #[cfg(feature = "cross-encoder")]
    assert_eq!(r.reason.as_deref(), Some(reason::MODEL_UNAVAILABLE));
    #[cfg(not(feature = "cross-encoder"))]
    assert_eq!(r.reason.as_deref(), Some(reason::CAPABILITY_OFF));
    assert!(!coord.is_pair_scorer_registered(&h));

    let no_query = coord
        .recall_scored(&h, request(20, None, None, Some(RerankDirective::apply(None))), NOW + 1000)
        .unwrap();
    let r = no_query.cross_encoder.as_ref().unwrap();
    assert_eq!(r.status, CrossEncoderStatus::Degraded);
    assert_eq!(r.reason.as_deref(), Some(reason::NO_QUERY_TEXT));

    let (scorer, _) = FakePairScorer::new("none", true);
    coord.register_pair_scorer(&h, scorer);
    let failed = coord
        .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::apply(None))), NOW + 1000)
        .unwrap();
    assert_eq!(ids(&failed), pool_head);
    let r = failed.cross_encoder.as_ref().unwrap();
    assert_eq!(r.status, CrossEncoderStatus::Degraded);
    assert_eq!(r.reason.as_deref(), Some(reason::SCORER_FAILED));
    assert!(failed.degraded_stages.iter().any(|s| s == DEGRADED_STAGE));
}

/// Two sequential `recall_scored` calls on an EMPTY scorer slot exercise the
/// `test_pair_scorer_maker` counting seam — W6-4.
///
/// The coordinator is single-threaded (RefCell) so "two applies" is a
/// sequential pair on the same slot. The first call sees `None` in the slot,
/// invokes the counting factory (cold_load == true), and caches the scorer.
/// The second call sees the filled slot and returns the cached scorer without
/// touching the factory (cold_load == false). The factory is called exactly
/// once. This mirrors the structural guarantee described in `coordinator.rs`:
/// the slot check and insert happen without suspension, so only one call ever
/// drives a load.
#[cfg(all(feature = "test-seams", feature = "cross-encoder"))]
#[test]
fn counting_factory_loads_once_on_empty_slot() {
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    let (coord, h) = open_estate();
    // Inject a counting factory via the test seam; the slot is empty.
    let call_count = Arc::new(AtomicU32::new(0));
    let call_count2 = Arc::clone(&call_count);
    let (factory_scorer, _) = FakePairScorer::new("none", false);
    // Wrap in Option so the closure can take ownership on first call.
    let scorer_cell = Arc::new(Mutex::new(Some(factory_scorer)));
    coord.set_test_pair_scorer_maker(Box::new(move |_profile| {
        call_count2.fetch_add(1, Ordering::SeqCst);
        // Panic on any call after the first — the seam must be hit exactly once.
        let scorer = scorer_cell.lock().unwrap().take()
            .expect("factory called more than once");
        Ok(scorer)
    }));

    // First apply: slot is empty → factory called → cold_load == true.
    let r1 = coord
        .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::apply(None))), NOW + 1000)
        .unwrap();
    let rep1 = r1.cross_encoder.as_ref().unwrap();
    assert_eq!(rep1.status, CrossEncoderStatus::Applied, "first apply must succeed");
    assert!(rep1.cold_load, "first apply must be a cold load");

    // Second apply: slot is already filled → factory NOT called → cold_load == false.
    let r2 = coord
        .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::apply(None))), NOW + 1000)
        .unwrap();
    let rep2 = r2.cross_encoder.as_ref().unwrap();
    assert_eq!(rep2.status, CrossEncoderStatus::Applied, "second apply must succeed");
    assert!(!rep2.cold_load, "second apply must NOT be a cold load");

    // Factory called exactly once across both applies.
    assert_eq!(call_count.load(Ordering::SeqCst), 1, "factory must be called exactly once");
}

#[test]
fn strict_rerank_refuses_ineligible_content_before_the_classifier() {
    let (mut coord, h) = open_estate();
    let (scorer, calls) = FakePairScorer::new("none", false);
    coord.register_pair_scorer(&h, scorer);
    let result = coord
        .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::strict_transcript(None))), NOW + 1000)
        .unwrap();
    let report = result.cross_encoder.as_ref().expect("report");
    assert!(result.hits.is_empty());
    assert_eq!(report.status, CrossEncoderStatus::Degraded);
    assert_eq!(report.reason.as_deref(), Some(reason::STRICT_TRANSCRIPT_INELIGIBLE));
    assert!(calls.lock().unwrap().is_empty());
}

#[test]
fn close_drops_the_scorer_slot() {
    let (mut coord, h) = open_estate();
    let (scorer, _) = FakePairScorer::new("none", false);
    coord.register_pair_scorer(&h, scorer);
    assert!(coord.is_pair_scorer_registered(&h));
    coord.close(&h).unwrap();
    assert!(!coord.is_pair_scorer_registered(&h));
}

/// Pins the full `summary_line()` format for an `Applied` report with every
/// optional field present. Mirrors Swift `CrossEncoderStageTests.summaryLineEncodesAllAppliedFields`.
/// Constructed with fixed values so the assertion is byte-identical regardless of run context.
#[test]
fn summary_line_encodes_all_applied_fields() {
    let report = CrossEncoderReport {
        status: CrossEncoderStatus::Applied,
        requested: true,
        reason: Some("explicit".to_string()),
        profile_id: "ms-marco-minilm-l6-cross-v1".to_string(),
        model_version: Some("233902d25c440f23af6f7d6e94d2946bac0bee0a".to_string()),
        backend: Some("fake".to_string()),
        pool: 50,
        head: 30,
        spans: 3,
        scored: 30,
        cold_load: true,
        stage_millis: Some(42),
        strict_transcript: None,
    };
    assert_eq!(
        report.summary_line(),
        "cross_encoder: applied profile=ms-marco-minilm-l6-cross-v1 reason=explicit backend=fake pool=50 head=30 scored=30 cold_load ms=42"
    );
}

/// Pins the full `summary_line()` format for a `Degraded` report.
/// Mirrors the Swift twin: backend=nil, pool/head/spans all zero.
#[test]
fn summary_line_encodes_degraded_report() {
    let report = CrossEncoderReport {
        status: CrossEncoderStatus::Degraded,
        requested: true,
        reason: Some(reason::MODEL_UNAVAILABLE.to_string()),
        profile_id: "ms-marco-minilm-l6-cross-v1".to_string(),
        model_version: None,
        backend: None,
        pool: 0,
        head: 0,
        spans: 0,
        scored: 0,
        cold_load: false,
        stage_millis: None,
        strict_transcript: None,
    };
    assert_eq!(
        report.summary_line(),
        "cross_encoder: degraded profile=ms-marco-minilm-l6-cross-v1 reason=model_unavailable"
    );
}

#[cfg(feature = "cross-encoder")]
mod packaged {
    use super::*;
    use genius_locus_kit::encoder_activation::ModelDirectoryResolving;

    /// Resolves `<scratch>/models/<model_id>/` through the product resolver.
    struct ScratchResolver(PathBuf);
    impl ModelDirectoryResolving for ScratchResolver {
        fn model_dir_for(&self, model_id: &str) -> Option<PathBuf> {
            corpus_kit_providers::model_dir_for(model_id, &self.0)
        }
    }

    /// Enable with: `MOOT_CROSS_ENCODER_ASSETS=<dir> cargo test --features cross-encoder -- --ignored`
    #[test]
    #[ignore]
    fn packaged_candle_classifier_loads_once_and_applies() {
        let root = std::env::var_os("MOOT_CROSS_ENCODER_ASSETS")
            .expect("MOOT_CROSS_ENCODER_ASSETS must be set to run ignored tests");
        let linux = PathBuf::from(root).join("linux");
        assert!(linux.is_dir(), "MOOT_CROSS_ENCODER_ASSETS set but linux/ subdirectory absent");
        let scratch = std::env::temp_dir().join(format!("ce-packaged-{}", std::process::id()));
        let target = scratch.join("models").join(CrossEncoderProfile::minilm_l6().model_id);
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&target).unwrap();
        for file in ["config.json", "tokenizer.json", "model.safetensors", "vocab.txt"] {
            std::fs::copy(linux.join(file), target.join(file)).unwrap();
        }
        let (mut coord, h) = open_estate();
        coord.set_model_directory_resolver(Box::new(ScratchResolver(scratch.clone())));
        let first = coord
            .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::apply(None))), NOW + 1000)
            .unwrap();
        let report = first.cross_encoder.as_ref().unwrap();
        assert_eq!(report.status, CrossEncoderStatus::Applied, "{report:?}");
        assert_eq!(report.backend.as_deref(), Some("candle"));
        assert!(report.cold_load);
        assert_eq!(report.scored, report.head);
        assert_eq!(first.hits.len(), 20);
        let second = coord
            .recall_scored(&h, request(20, Some(QUERY), None, Some(RerankDirective::apply(None))), NOW + 1000)
            .unwrap();
        let r2 = second.cross_encoder.as_ref().unwrap();
        assert_eq!(r2.status, CrossEncoderStatus::Applied);
        assert!(!r2.cold_load);
        assert_eq!(ids(&second), ids(&first));
        let _ = std::fs::remove_dir_all(&scratch);
    }
}
