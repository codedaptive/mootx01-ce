//! LocusKit telemetry integration tests — cp-locuskit-report.
//!
//! Mirrors the Swift suite in
//! Tests/LocusKitTests/LocusKitTelemetryTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Disabled gate: no metric emitted when monitoring is OFF.
//!   §2 Drawer capture: add_drawer emits capture_latency_ms + capture_count.
//!   §3 Drawer query: drawers_in_wing / all_drawers emit query metrics.
//!   §4 KGFact: add_kg_fact / kg_facts_for_drawer / all_kg_facts emit metrics.
//!   §5 Tunnel: add_tunnel emits tunnel.add_count.
//!   §6 Conformance: results are byte-identical with monitoring on and off.
//!   §7 Event emission: Estate::capture / capture_tunnel emit StatSample::Event.
//!
//! ## Global state isolation
//!
//! DrawerStoreCore operations call the telemetry module, which uses the
//! process-wide Intellectus singleton (enabled flag + installed sink).
//! Rust integration tests run in parallel by default.
//!
//! All tests that touch the singleton (toggle enabled flag, install a
//! capturing sink, or call DrawerStore methods that emit) MUST acquire
//! GLOBAL_LOCK for their entire duration. This prevents interleaving
//! between concurrent tests that would corrupt exact-count assertions.
//!
//! Pattern mirrors packages/kits/VectorKit/rust/tests/vectorkit_telemetry_tests.rs.
//!
//! For enabled-path count assertions, each test creates a fresh store
//! with a unique estate UUID. Metrics are filtered by `estate` tag to
//! exclude emissions from concurrent tests operating on different stores.
//! This mirrors the Swift approach (CapturingSink.count(named:forEstate:)).
//!
//! Lock poisoning: if a prior test panicked while holding the lock,
//! `lock()` returns a PoisonError. We recover with `into_inner()` so
//! subsequent tests can still run. Each test restores the global state
//! to disabled + NoOpSink before releasing.

use std::sync::{Arc, Mutex, OnceLock};

use intellectus_lib::{EventKind, Intellectus, NoOpSink, StatSample, StatsSink};
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::{CaptureFrame, TunnelCaptureFrame};
use locus_kit::kg_fact::KGFact;
use locus_kit::tunnel::Tunnel;
use locus_kit::tunnel_operational::TunnelKind;
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────
// Process-wide serialisation lock
// ─────────────────────────────────────────────────────────────────

/// Serialises all tests that manipulate the Intellectus singleton.
/// All such tests hold this lock for their entire duration.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

// ─────────────────────────────────────────────────────────────────
// CapturingSink — records every received StatSample, thread-safe
// ─────────────────────────────────────────────────────────────────

struct CapturingSink {
    samples: Mutex<Vec<StatSample>>,
}

impl CapturingSink {
    fn new() -> Self {
        CapturingSink { samples: Mutex::new(Vec::new()) }
    }

    fn count(&self) -> usize {
        self.samples.lock().unwrap().len()
    }

    fn all_samples(&self) -> Vec<StatSample> {
        self.samples.lock().unwrap().clone()
    }

    /// Count metrics with the given name AND matching estate tag.
    /// Used to filter out emissions from concurrent tests on different
    /// stores — each store has a unique estate UUID.
    fn count_for_estate(&self, name: &str, estate_tag: &str) -> usize {
        self.all_samples().into_iter().filter(|s| {
            if let StatSample::Metric { name: n, tags, .. } = s {
                n == name && tags.get("estate").map(|s| s.as_str()) == Some(estate_tag)
            } else {
                false
            }
        }).count()
    }

    /// All samples with the given name AND matching estate tag.
    fn samples_for_estate(&self, name: &str, estate_tag: &str) -> Vec<StatSample> {
        self.all_samples().into_iter().filter(|s| {
            if let StatSample::Metric { name: n, tags, .. } = s {
                n == name && tags.get("estate").map(|s| s.as_str()) == Some(estate_tag)
            } else {
                false
            }
        }).collect()
    }

    /// All Event samples whose `estate` field matches `estate_tag`.
    fn event_samples_for_estate(&self, estate_tag: &str) -> Vec<StatSample> {
        self.all_samples().into_iter().filter(|s| {
            if let StatSample::Event { estate, .. } = s {
                estate == estate_tag
            } else {
                false
            }
        }).collect()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

// ─────────────────────────────────────────────────────────────────
// Store helpers
// ─────────────────────────────────────────────────────────────────

/// Derives a deterministic UUID string from a short label using FNV-1a
/// hashing. Mirrors `TestStorage.tid(_:)` in the Swift test helpers so
/// the same short label produces a consistent, valid UUID across runs.
fn tid(label: &str) -> String {
    if Uuid::parse_str(label).is_ok() {
        return label.to_string();
    }
    let mut bytes = [0u8; 16];
    let mut h: u64 = 0xcbf29ce484222325u64;
    for (i, b) in label.bytes().enumerate() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
        bytes[i % 16] ^= (h & 0xff) as u8;
        bytes[(i + 7) % 16] ^= ((h >> 32) & 0xff) as u8;
    }
    for i in 0..16usize {
        h ^= bytes[i] as u64;
        h = h.wrapping_mul(0x100000001b3);
        bytes[i] = bytes[i].wrapping_add((h & 0xff) as u8);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // UUID v4 version nibble
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // UUID variant nibble
    let hex: String = bytes.iter().map(|b| format!("{:02x}", b)).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Creates a fresh InMemoryDrawerStore with a new estate UUID each call.
fn make_fresh_store() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(1_000_000, None).expect("InMemoryDrawerStore::new must succeed")
}

/// Returns the estate UUID string from a store via its manifest.
fn estate_tag_of(store: &InMemoryDrawerStore) -> String {
    store.read_manifest().expect("read_manifest must succeed").estate_uuid
}

/// A minimal valid Drawer for testing.
/// `label` is a short name; this function converts it to a deterministic
/// UUID via `tid()` so the Rust stores' UUID-format validation passes.
fn sample_drawer(label: &str) -> Drawer {
    Drawer {
        id: tid(label),
        lineage_id: Uuid::new_v4(),
        parent_node_id: "test-parent".to_string(),
        content: "Test content for telemetry".to_string(),
        added_by: "test-agent".to_string(),
        embedding_model_id: "minilm-v2".to_string(),
        adjective_bitmap: 0,
        operational_bitmap: 0,
        provenance: 0,
        filed_at: 1_000_000,
        event_time: 1_000_000,
        source_file: None,
        chunk_index: None,
        tombstoned_at: None,
        removed_by_batch: None,
        udc_code: String::new(),
        udc_facets: None,
        wikidata_qid: None,
        wikidata_qids_secondary: None,
        distilled: None,
        distilled_pipeline_version: None,
        distilled_token_count: None,
        distilled_at: None,
        subject: None,
        subject_pipeline_version: None,
        subject_at: None,
    }
}

/// A minimal valid Tunnel for testing.
/// `source_label` and `target_label` are short names converted to UUID
/// strings via `tid()` to satisfy the stores' UUID-format validation.
fn sample_tunnel(source_label: &str, target_label: &str) -> Tunnel {
    let source_id = tid(source_label);
    let target_id = tid(target_label);
    Tunnel {
        id: tid(&format!("tunnel-{source_label}-{target_label}")),
        source_drawer_id: Some(source_id.clone()),
        target_drawer_id: Some(target_id.clone()),
        source_wing: "wing-tel".to_string(),
        source_room: "room-tel".to_string(),
        target_wing: "wing-tel".to_string(),
        target_room: "room-tel".to_string(),
        label: "test-tunnel".to_string(),
        kind: TunnelKind::References,
        adjective_bitmap: 0,
        operational_bitmap: 0,
        provenance_bitmap: 0,
        filed_at: 1_000_000,
        tombstoned_at: None,
        added_by: "test-agent".to_string(),
        removed_by_batch: None,
        order_key: None,
        ext: None,
    }
}

/// A minimal valid KGFact for testing.
/// `label` and `drawer_label` are short names converted via `tid()`.
fn sample_kgfact(label: &str, drawer_label: &str) -> KGFact {
    KGFact {
        id: tid(label),
        subject: "SubjectA".to_string(),
        predicate: "relatesTo".to_string(),
        object: "ObjectB".to_string(),
        source_drawer_id: tid(drawer_label),
        added_by: String::new(),
        foreign_source_key: String::new(),
        foreign_record_id: String::new(),
        adjective_bitmap: 0,
        operational_bitmap: 0,
        provenance_bitmap: 0,
        filed_at: 1_000_000,
    }
}

/// Restore Intellectus to the default disabled+NoOpSink state.
fn reset_intellectus() {
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ─────────────────────────────────────────────────────────────────
// §1 Disabled gate
// ─────────────────────────────────────────────────────────────────

/// add_drawer must not emit when monitoring is disabled.
#[test]
fn add_drawer_no_metric_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let store = make_fresh_store();
    store.add_drawer(&sample_drawer("d1"), 1_000_000)
        .expect("add_drawer must succeed");

    assert_eq!(sink.count(), 0,
        "add_drawer must not emit when monitoring is disabled; got {}", sink.count());

    reset_intellectus();
}

/// drawers_in_wing must not emit when monitoring is disabled.
#[test]
fn drawers_in_wing_no_metric_when_disabled() {
    let _guard = global_lock();
    let store = make_fresh_store();
    // Insert drawer before installing monitoring sink.
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("d1"), 1_000_000)
        .expect("add_drawer must succeed");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let _ = store.drawers_in_wing("wing-tel")
        .expect("drawers_in_wing must succeed");

    assert_eq!(sink.count(), 0,
        "drawers_in_wing must not emit when monitoring is disabled; got {}", sink.count());

    reset_intellectus();
}

/// add_tunnel must not emit when monitoring is disabled.
#[test]
fn add_tunnel_no_metric_when_disabled() {
    let _guard = global_lock();
    let store = make_fresh_store();
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("t1"), 1_000_000).expect("add_drawer t1");
    store.add_drawer(&sample_drawer("t2"), 1_000_001).expect("add_drawer t2");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    store.add_tunnel(&sample_tunnel("t1", "t2"))
        .expect("add_tunnel must succeed");

    assert_eq!(sink.count(), 0,
        "add_tunnel must not emit when monitoring is disabled; got {}", sink.count());

    reset_intellectus();
}

/// add_kg_fact must not emit when monitoring is disabled.
#[test]
fn add_kg_fact_no_metric_when_disabled() {
    let _guard = global_lock();
    let store = make_fresh_store();
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("kd1"), 1_000_000).expect("add_drawer");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    store.add_kg_fact(&sample_kgfact("f1", "kd1"))
        .expect("add_kg_fact must succeed");

    assert_eq!(sink.count(), 0,
        "add_kg_fact must not emit when monitoring is disabled; got {}", sink.count());

    reset_intellectus();
}

// ─────────────────────────────────────────────────────────────────
// §2 Drawer capture emissions
// ─────────────────────────────────────────────────────────────────

/// add_drawer emits capture_latency_ms and capture_count when enabled.
/// Estate-filtered to isolate from concurrent tests on other stores.
#[test]
fn add_drawer_emits_capture_metrics_when_enabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    store.add_drawer(&sample_drawer("d1"), 1_000_000)
        .expect("add_drawer must succeed");

    // Filter by estate to exclude emissions from concurrent tests on other stores.
    let latency_count = sink.count_for_estate("locuskit.drawer.capture_latency_ms", &estate);
    let capture_count = sink.count_for_estate("locuskit.drawer.capture_count", &estate);
    assert_eq!(latency_count, 1,
        "add_drawer must emit exactly 1 capture_latency_ms for estate {}; got {}", estate, latency_count);
    assert_eq!(capture_count, 1,
        "add_drawer must emit exactly 1 capture_count for estate {}; got {}", estate, capture_count);

    reset_intellectus();
}

/// capture_count value is 1.0 per call.
#[test]
fn add_drawer_capture_count_value_is_one() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    store.add_drawer(&sample_drawer("d1"), 1_000_000)
        .expect("add_drawer must succeed");

    let samples = sink.samples_for_estate("locuskit.drawer.capture_count", &estate);
    assert_eq!(samples.len(), 1, "expected exactly one capture_count sample for estate {}", estate);
    if let Some(StatSample::Metric { value, .. }) = samples.first() {
        assert_eq!(*value, 1.0, "capture_count must be 1.0; got {}", value);
    } else {
        panic!("expected Metric sample; got {:?}", samples.first());
    }

    reset_intellectus();
}

/// Two add_drawer calls emit two capture_count metrics for the same estate.
#[test]
fn two_add_drawer_calls_emit_two_capture_count_metrics() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    store.add_drawer(&sample_drawer("a1"), 1_000_000).expect("add_drawer a1");
    store.add_drawer(&sample_drawer("a2"), 1_000_001).expect("add_drawer a2");

    // Filter by estate to exclude any concurrent test emissions on other stores.
    let capture_count = sink.count_for_estate("locuskit.drawer.capture_count", &estate);
    assert_eq!(capture_count, 2,
        "two add_drawer calls must produce 2 capture_count for estate {}; got {}", estate, capture_count);

    reset_intellectus();
}

/// capture_latency_ms is non-negative.
#[test]
fn capture_latency_ms_is_non_negative() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    store.add_drawer(&sample_drawer("d1"), 1_000_000)
        .expect("add_drawer must succeed");

    let samples = sink.samples_for_estate("locuskit.drawer.capture_latency_ms", &estate);
    assert_eq!(samples.len(), 1, "expected one capture_latency_ms sample for estate {}", estate);
    if let Some(StatSample::Metric { value, .. }) = samples.first() {
        assert!(*value >= 0.0, "capture_latency_ms must be non-negative; got {}", value);
    } else {
        panic!("expected Metric sample; got {:?}", samples.first());
    }

    reset_intellectus();
}

// ─────────────────────────────────────────────────────────────────
// §3 Drawer query emissions
// ─────────────────────────────────────────────────────────────────

/// drawers_in_wing emits query_latency_ms and query_result_count.
#[test]
fn drawers_in_wing_emits_query_metrics() {
    let _guard = global_lock();
    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    // Insert drawers with monitoring off to isolate query-only metrics.
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("q1"), 1_000_000).expect("add_drawer q1");
    store.add_drawer(&sample_drawer("q2"), 1_000_001).expect("add_drawer q2");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let results = store.drawers_in_wing("wing-tel").expect("drawers_in_wing must succeed");

    let latency_count = sink.count_for_estate("locuskit.drawer.query_latency_ms", &estate);
    let result_count_count = sink.count_for_estate("locuskit.drawer.query_result_count", &estate);
    assert_eq!(latency_count, 1,
        "drawers_in_wing must emit 1 query_latency_ms for estate {}; got {}", estate, latency_count);
    assert_eq!(result_count_count, 1,
        "drawers_in_wing must emit 1 query_result_count for estate {}; got {}", estate, result_count_count);

    // result_count value must match actual count returned.
    let rc_samples = sink.samples_for_estate("locuskit.drawer.query_result_count", &estate);
    if let Some(StatSample::Metric { value, tags, .. }) = rc_samples.first() {
        assert_eq!(*value, results.len() as f64,
            "query_result_count must equal actual result count; got {}, expected {}", value, results.len());
        assert_eq!(tags.get("query").map(|s| s.as_str()), Some("wing"),
            "drawers_in_wing must carry query=wing tag; got {:?}", tags.get("query"));
    } else {
        panic!("expected Metric sample for query_result_count in estate {}", estate);
    }

    reset_intellectus();
}

/// all_drawers emits query_result_count with query="all".
#[test]
fn all_drawers_emits_query_result_count_with_all_tag() {
    let _guard = global_lock();
    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("all1"), 1_000_000).expect("add_drawer all1");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = store.all_drawers().expect("all_drawers must succeed");

    let rc_samples = sink.samples_for_estate("locuskit.drawer.query_result_count", &estate);
    if let Some(StatSample::Metric { tags, .. }) = rc_samples.first() {
        assert_eq!(tags.get("query").map(|s| s.as_str()), Some("all"),
            "all_drawers must carry query=all tag; got {:?}", tags.get("query"));
    } else {
        panic!("expected Metric sample for query_result_count from all_drawers in estate {}", estate);
    }

    reset_intellectus();
}

// ─────────────────────────────────────────────────────────────────
// §4 KGFact emissions
// ─────────────────────────────────────────────────────────────────

/// add_kg_fact emits kgfact.add_count when enabled.
#[test]
fn add_kg_fact_emits_add_count_when_enabled() {
    let _guard = global_lock();
    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    // Insert drawer with monitoring off (setup).
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("kd1"), 1_000_000).expect("add_drawer");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    store.add_kg_fact(&sample_kgfact("f1", "kd1"))
        .expect("add_kg_fact must succeed");

    let add_count = sink.count_for_estate("locuskit.kgfact.add_count", &estate);
    assert_eq!(add_count, 1,
        "add_kg_fact must emit 1 kgfact.add_count for estate {}; got {}", estate, add_count);

    reset_intellectus();
}

/// kg_facts_for_drawer emits query_result_count with query="drawer".
#[test]
fn kg_facts_for_drawer_emits_result_count_with_drawer_tag() {
    let _guard = global_lock();
    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("kd1"), 1_000_000).expect("add_drawer");
    store.add_kg_fact(&sample_kgfact("f1", "kd1")).expect("add_kg_fact f1");
    store.add_kg_fact(&sample_kgfact("f2", "kd1")).expect("add_kg_fact f2");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let facts = store.kg_facts_for_drawer(&tid("kd1")).expect("kg_facts_for_drawer must succeed");

    let rc_samples = sink.samples_for_estate("locuskit.kgfact.query_result_count", &estate);
    if let Some(StatSample::Metric { value, tags, .. }) = rc_samples.first() {
        assert_eq!(tags.get("query").map(|s| s.as_str()), Some("drawer"),
            "kg_facts_for_drawer must carry query=drawer tag; got {:?}", tags.get("query"));
        assert_eq!(*value, facts.len() as f64,
            "query_result_count must equal fact count; got {}, expected {}", value, facts.len());
    } else {
        panic!("expected Metric sample for kgfact.query_result_count in estate {}", estate);
    }

    reset_intellectus();
}

/// all_kg_facts emits query_result_count with query="all".
#[test]
fn all_kg_facts_emits_result_count_with_all_tag() {
    let _guard = global_lock();
    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("kd1"), 1_000_000).expect("add_drawer");
    store.add_kg_fact(&sample_kgfact("g1", "kd1")).expect("add_kg_fact");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = store.all_kg_facts().expect("all_kg_facts must succeed");

    let rc_samples = sink.samples_for_estate("locuskit.kgfact.query_result_count", &estate);
    if let Some(StatSample::Metric { tags, .. }) = rc_samples.first() {
        assert_eq!(tags.get("query").map(|s| s.as_str()), Some("all"),
            "all_kg_facts must carry query=all tag; got {:?}", tags.get("query"));
    } else {
        panic!("expected Metric sample for kgfact.query_result_count from all_kg_facts in estate {}", estate);
    }

    reset_intellectus();
}

// ─────────────────────────────────────────────────────────────────
// §5 Tunnel emissions
// ─────────────────────────────────────────────────────────────────

/// add_tunnel emits tunnel.add_count when enabled.
#[test]
fn add_tunnel_emits_add_count_when_enabled() {
    let _guard = global_lock();
    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("t1"), 1_000_000).expect("add_drawer t1");
    store.add_drawer(&sample_drawer("t2"), 1_000_001).expect("add_drawer t2");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    store.add_tunnel(&sample_tunnel("t1", "t2"))
        .expect("add_tunnel must succeed");

    let add_count = sink.count_for_estate("locuskit.tunnel.add_count", &estate);
    assert_eq!(add_count, 1,
        "add_tunnel must emit 1 tunnel.add_count for estate {}; got {}", estate, add_count);

    reset_intellectus();
}

/// Two add_tunnel calls emit two tunnel.add_count metrics.
#[test]
fn two_add_tunnel_calls_emit_two_add_count_metrics() {
    let _guard = global_lock();
    let store = make_fresh_store();
    let estate = estate_tag_of(&store);
    Intellectus::set_enabled(false);
    store.add_drawer(&sample_drawer("u1"), 1_000_000).expect("add_drawer u1");
    store.add_drawer(&sample_drawer("u2"), 1_000_001).expect("add_drawer u2");
    store.add_drawer(&sample_drawer("u3"), 1_000_002).expect("add_drawer u3");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    store.add_tunnel(&sample_tunnel("u1", "u2")).expect("add_tunnel 1");
    store.add_tunnel(&sample_tunnel("u2", "u3")).expect("add_tunnel 2");

    let tunnel_count = sink.count_for_estate("locuskit.tunnel.add_count", &estate);
    assert_eq!(tunnel_count, 2,
        "two add_tunnel calls must emit 2 tunnel.add_count for estate {}; got {}", estate, tunnel_count);

    reset_intellectus();
}

// ─────────────────────────────────────────────────────────────────
// §6 Conformance — results byte-identical with monitoring on vs off
// ─────────────────────────────────────────────────────────────────

/// add_drawer result is identical (Ok) with monitoring on and off.
#[test]
fn add_drawer_result_identical_with_monitoring_on_and_off() {
    let _guard = global_lock();

    // OFF path.
    Intellectus::set_enabled(false);
    let store_off = make_fresh_store();
    let result_off = store_off.add_drawer(&sample_drawer("conf1"), 1_000_000);

    // ON path.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let store_on = make_fresh_store();
    let result_on = store_on.add_drawer(&sample_drawer("conf1"), 1_000_000);

    // Both must succeed (Ok variant).
    assert!(result_off.is_ok(), "add_drawer must succeed with monitoring off");
    assert!(result_on.is_ok(), "add_drawer must succeed with monitoring on");
    // Confirm monitoring was active by checking at least one metric emitted.
    assert!(sink.count() > 0, "at least one metric must be emitted when monitoring is on");

    reset_intellectus();
}

/// drawers_in_wing results are identical with monitoring on and off.
/// Set equality (not order) is asserted because two separate in-memory
/// stores do not guarantee identical insertion ordering.
#[test]
fn drawers_in_wing_results_identical_with_monitoring_on_and_off() {
    let _guard = global_lock();

    // OFF path.
    Intellectus::set_enabled(false);
    let store_off = make_fresh_store();
    store_off.add_drawer(&sample_drawer("cr1"), 1_000_000).expect("add cr1 off");
    store_off.add_drawer(&sample_drawer("cr2"), 1_000_001).expect("add cr2 off");
    let rows_off = store_off.drawers_in_wing("wing-tel").expect("query off");

    // ON path.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let store_on = make_fresh_store();
    store_on.add_drawer(&sample_drawer("cr1"), 1_000_000).expect("add cr1 on");
    store_on.add_drawer(&sample_drawer("cr2"), 1_000_001).expect("add cr2 on");
    let rows_on = store_on.drawers_in_wing("wing-tel").expect("query on");

    assert_eq!(rows_off.len(), rows_on.len(),
        "drawers_in_wing must return same count with monitoring off and on");

    // Set equality: same IDs, possibly different order.
    let ids_off: std::collections::HashSet<String> = rows_off.iter().map(|d| d.id.clone()).collect();
    let ids_on: std::collections::HashSet<String> = rows_on.iter().map(|d| d.id.clone()).collect();
    assert_eq!(ids_off, ids_on,
        "drawers_in_wing must return same drawer IDs regardless of monitoring state");

    // Confirm monitoring was active.
    assert!(sink.count() > 0, "at least one metric must be emitted when monitoring is on");

    reset_intellectus();
}

// ─────────────────────────────────────────────────────────────────
// §7 Event emission — Estate::capture / capture_tunnel
// ─────────────────────────────────────────────────────────────────
//
// These tests verify that the estate-level verb wrappers (estate_verbs.rs)
// emit a StatSample::Event with kind=Capture after successfully writing
// to the backing store. The DrawerStoreCore layer emits Metric samples;
// the Event emission is a distinct, higher-level instrumentation point.
//
// NounType wire-stable values (SubstrateTypes): Drawer=0, Tunnel=1.

/// Build an Estate over a fresh InMemoryDrawerStore for event-emission tests.
fn make_fresh_estate() -> Estate {
    let store = Arc::new(
        InMemoryDrawerStore::new(1_000_000, None).expect("InMemoryDrawerStore::new must succeed"),
    );
    Estate::create(store, OwnerCredentials::new("test-owner"), None)
        .expect("Estate::create must succeed")
}

/// A minimal valid CaptureFrame for event-emission tests.
fn capture_frame() -> CaptureFrame {
    CaptureFrame::new(
        "event-emission test content",
        CaptureChannel::Typed,
        "room-event-test",
        LatticeAnchor::udc("004"),
        "test-agent",
        "minilm-v2",
    )
}

/// A minimal valid TunnelCaptureFrame for event-emission tests.
fn tunnel_capture_frame() -> TunnelCaptureFrame {
    TunnelCaptureFrame::new(
        "wing-a",
        "room-event-test",
        "wing-b",
        "room-event-test-b",
        "test-link",
        "test-agent",
    )
}

/// Estate::capture emits exactly one StatSample::Event with kind=Capture,
/// noun_type=0 (Drawer), and row_id=drawer.id when monitoring is enabled.
///
/// Mirrors Swift `captureDrawerEmitsCaptureEvent` (TEL-01 §7).
#[test]
fn capture_drawer_emits_capture_event() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let estate = make_fresh_estate();
    let estate_tag = estate.estate_uuid().to_string();

    let drawer = estate
        .capture(capture_frame(), 1_700_000_000)
        .expect("Estate::capture must succeed");

    let events = sink.event_samples_for_estate(&estate_tag);
    assert_eq!(
        events.len(),
        1,
        "Estate::capture must emit exactly one Event for estate {}; got {}",
        estate_tag,
        events.len()
    );
    if let Some(StatSample::Event { kind, noun_type, row_id, estate: ev_estate, .. }) =
        events.first()
    {
        assert_eq!(
            *kind,
            EventKind::Capture,
            "Event kind must be Capture; got {:?}",
            kind
        );
        // Drawer NounType wire-stable value = 0 (SubstrateTypes)
        assert_eq!(*noun_type, 0i64, "Drawer noun_type must be 0; got {}", noun_type);
        assert_eq!(
            row_id, &drawer.id,
            "Event row_id must equal the returned drawer id"
        );
        assert_eq!(
            ev_estate, &estate_tag,
            "Event estate must match the estate UUID"
        );
    } else {
        panic!("Expected StatSample::Event; got {:?}", events.first());
    }

    reset_intellectus();
}

/// Estate::capture_tunnel emits exactly one StatSample::Event with kind=Capture,
/// noun_type=1 (Tunnel), and row_id=tunnel.id when monitoring is enabled.
///
/// Mirrors Swift `captureTunnelEmitsCaptureEvent` (TEL-01 §7).
#[test]
fn capture_tunnel_emits_capture_event() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let estate = make_fresh_estate();
    let estate_tag = estate.estate_uuid().to_string();

    let tunnel = estate
        .capture_tunnel(tunnel_capture_frame(), 1_700_000_000)
        .expect("Estate::capture_tunnel must succeed");

    let events = sink.event_samples_for_estate(&estate_tag);
    assert_eq!(
        events.len(),
        1,
        "Estate::capture_tunnel must emit exactly one Event for estate {}; got {}",
        estate_tag,
        events.len()
    );
    if let Some(StatSample::Event { kind, noun_type, row_id, estate: ev_estate, .. }) =
        events.first()
    {
        assert_eq!(
            *kind,
            EventKind::Capture,
            "Event kind must be Capture; got {:?}",
            kind
        );
        // Tunnel NounType wire-stable value = 1 (SubstrateTypes)
        assert_eq!(*noun_type, 1i64, "Tunnel noun_type must be 1; got {}", noun_type);
        assert_eq!(
            row_id, &tunnel.id,
            "Event row_id must equal the returned tunnel id"
        );
        assert_eq!(
            ev_estate, &estate_tag,
            "Event estate must match the estate UUID"
        );
    } else {
        panic!("Expected StatSample::Event; got {:?}", events.first());
    }

    reset_intellectus();
}
