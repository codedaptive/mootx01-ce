// encode_intake_parity.rs — Rust parity of Swift EncodeIntakeTests.swift.
//
// Dual-Path Intake acceptance line (P3/P4/P6): proves the previously-dark
// semantic-recall lane is now LIT for normally-captured content.
//
// Before this wiring, a capture wrote a LocusKit drawer row only — never
// chunked, never BM25-indexed — so a hybrid recall could only find captured
// content via the Locus structured lane, never the BM25/vector semantic lane.
// These tests provision a GLK estate (which mounts the dedicated encode queue,
// D-B), capture through the mode-aware write verb, and assert the drawer comes
// back via the CORPUS BM25 lane (`CorpusBm25`) — the lane that was dark before:
//
//   • REGULAR: capture returns, await_encode_drain() drains the encode queue,
//     then recall returns the drawer via CorpusBm25.
//   • IMPATIENT: capture ingests inline, so recall returns the drawer via
//     CorpusBm25 immediately, with NO drain wait.
//
// ── RUST DIFFERENCE FROM SWIFT ────────────────────────────────────────────
// The Swift drain worker is a background Task; the Rust port has no background
// thread, so `await_encode_drain` PUMP-DRIVES the drain synchronously. Caller-
// observable behaviour is identical: after a regular write + await_encode_drain
// the drawer is BM25-searchable.

use std::sync::Arc;

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::coordinator::{
    EstateCoordinator, EstateKind, EstateProvisionParams, SyncMode,
};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath,
    RecallFallbackPolicy,
};
use genius_locus_kit::{EncodeJob, WriteMode};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use genius_locus_kit::handle::EstateHandle;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000; // capture instant, millis since epoch

// MARK: - Helpers

/// Provision a GLK estate (mounts Corpus + VectorStore + the dedicated encode
/// queue). Mirrors the Swift `provisionGLKEstate()` helper. One in-memory
/// storage backs both the LocusKit estate and the Corpus/VectorStore.
fn provision_glk_estate() -> (EstateCoordinator, EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap(),
    );
    let storage_dyn: Arc<dyn Storage> = storage;

    let mut coord = EstateCoordinator::new();
    let params = EstateProvisionParams {
        estate_name: "Encode Intake Test Estate".to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: SyncMode::None,
    };
    // Deterministic embedding model — reproducible, no CoreML.
    let handle = coord
        .provision(
            store,
            storage_dyn,
            None,
            OwnerCredentials::new("owner-encode-intake-tests"),
            params,
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision GLK estate");
    (coord, handle)
}

fn capture_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "encode-intake-tests",
        LatticeAnchor::udc("000.000"),
        "encode-intake-tests",
        "test-model-v1",
    )
}

/// A hybrid recall request with the given query text (matches every newly
/// captured unconfirmed row, scored raw).
fn hybrid_request(query: &str) -> GLKRecallRequest {
    GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(50)
        .with_fallback(RecallFallbackPolicy::FailClosed)
        .with_query_text(query.to_string())
}

// MARK: - THE KEY TEST: regular write → drain → semantic recall finds it

/// A REGULAR write of a fresh drawer, then await_encode_drain(), then a hybrid
/// recall RETURNS that drawer via the BM25 (corpus) lane — i.e. semantic recall
/// now works for normally-captured content. This is the lane that was DARK
/// before the dual-path wiring.
#[test]
fn regular_write_becomes_semantically_searchable_after_drain() {
    let (mut coord, handle) = provision_glk_estate();

    let content = "apple mango banana fruit recall semantic content";
    let drawer = coord
        .capture_with_mode(&handle, capture_frame(content), NOW, WriteMode::Regular)
        .expect("regular capture");

    // Drive the encode drain until the drawer is ingested into the Corpus.
    coord.await_encode_drain(&handle).expect("await_encode_drain");

    // Hybrid recall on a query that matches the seeded content.
    let result = coord
        .recall_scored(&handle, hybrid_request("fruit mango recall"), NOW + 1)
        .expect("recall_scored");

    // The drawer is returned...
    let hit = result
        .hits
        .iter()
        .find(|h| h.drawer.as_ref().map(|d| d.id.as_str()) == Some(drawer.id.as_str()))
        .expect("regular-written drawer must be recalled after the encode queue drains");
    // ...AND it was found via the CORPUS BM25 lane — the previously-dark
    // semantic lane. This is the load-bearing assertion.
    assert!(
        hit.sources.contains(&RecallEvidencePath::CorpusBm25),
        "the drawer must surface via CorpusBm25 — the semantic lane lit by the \
         encode drain; got {:?}",
        hit.sources
    );
}

// MARK: - IMPATIENT write → immediately searchable, no drain wait

/// An IMPATIENT write returns and the drawer is IMMEDIATELY semantically
/// searchable with NO drain wait — the inline encode (P6) ran before the write
/// returned.
#[test]
fn impatient_write_is_immediately_searchable() {
    let (mut coord, handle) = provision_glk_estate();

    let content = "kingfisher heron osprey wading bird estuary content";
    let drawer = coord
        .capture_with_mode(&handle, capture_frame(content), NOW, WriteMode::Impatient)
        .expect("impatient capture");

    // NO await_encode_drain — impatient encodes inline before returning.
    let result = coord
        .recall_scored(&handle, hybrid_request("heron wading bird"), NOW + 1)
        .expect("recall_scored");

    let hit = result
        .hits
        .iter()
        .find(|h| h.drawer.as_ref().map(|d| d.id.as_str()) == Some(drawer.id.as_str()))
        .expect("impatient-written drawer must be recalled immediately, with no drain wait");
    assert!(
        hit.sources.contains(&RecallEvidencePath::CorpusBm25),
        "impatient drawer must surface via CorpusBm25 immediately; got {:?}",
        hit.sources
    );
}

// MARK: - await_encode_drain returns promptly on an empty queue

/// await_encode_drain() returns when the queue is empty and does not hang when
/// there is nothing to drain.
#[test]
fn await_encode_drain_returns_when_empty() {
    let (mut coord, handle) = provision_glk_estate();
    // No writes — the encode queue is empty. Must return without error.
    coord.await_encode_drain(&handle).expect("empty drain returns");
}

// MARK: - Regular vs impatient converge on the same searchable state

/// After draining, a regular-written drawer and an impatient-written drawer are
/// both semantically recallable — the two paths converge on the same lit-lane
/// end state.
#[test]
fn regular_and_impatient_converge_on_searchable_state() {
    let (mut coord, handle) = provision_glk_estate();

    let regular = coord
        .capture_with_mode(
            &handle,
            capture_frame("tungsten molybdenum refractory metal alloy"),
            NOW,
            WriteMode::Regular,
        )
        .expect("regular capture");
    let impatient = coord
        .capture_with_mode(
            &handle,
            capture_frame("tungsten carbide cutting tool tip industrial"),
            NOW + 1,
            WriteMode::Impatient,
        )
        .expect("impatient capture");

    coord.await_encode_drain(&handle).expect("await_encode_drain");

    let result = coord
        .recall_scored(&handle, hybrid_request("tungsten metal"), NOW + 2)
        .expect("recall_scored");
    let ids: Vec<&str> = result
        .hits
        .iter()
        .filter_map(|h| h.drawer.as_ref().map(|d| d.id.as_str()))
        .collect();
    assert!(
        ids.contains(&regular.id.as_str()),
        "regular-written drawer must be searchable after drain"
    );
    assert!(
        ids.contains(&impatient.id.as_str()),
        "impatient-written drawer must be searchable"
    );
}

// MARK: - LocusOnly estate degrades both modes to row-only (no encode queue)

/// A LocusOnly estate registers no Corpus, so it mounts no encode queue and both
/// write modes degrade to row-only without error. await_encode_drain is a no-op.
#[test]
fn locus_only_degrades_both_modes_to_row_only() {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap(),
    );
    let storage_dyn: Arc<dyn Storage> = storage;
    let mut coord = EstateCoordinator::new();
    let params = EstateProvisionParams {
        estate_name: "LocusOnly Estate".to_string(),
        kind: EstateKind::LocusOnly,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "PersonalLifeMgmt".to_string(),
        sync_mode: SyncMode::None,
    };
    let handle = coord
        .provision(
            store,
            storage_dyn,
            None,
            OwnerCredentials::new("owner"),
            params,
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision LocusOnly");

    // Both modes store the row and return Ok; no corpus to feed.
    coord
        .capture_with_mode(&handle, capture_frame("a note"), NOW, WriteMode::Regular)
        .expect("regular on locus-only");
    coord
        .capture_with_mode(&handle, capture_frame("b note"), NOW + 1, WriteMode::Impatient)
        .expect("impatient on locus-only");
    // await_encode_drain is a no-op when no queue is mounted.
    coord.await_encode_drain(&handle).expect("no-op drain");
}

// MARK: - EncodeJob payload round-trips through QueueKit's Job

/// The EncodeJob payload (P2) survives a Job encode/decode round-trip,
/// preserving the drawer id, estate uuid, text, model id, and capture instant.
/// Mirrors Swift `encodeJobRoundTripsThroughJob`.
#[test]
fn encode_job_round_trips_through_job() {
    use queuekit::{StreamId, HLC};

    let captured_millis = 1_700_000_000_500_i64; // .5 s past the second
    let estate_bytes = *Uuid::new_v4().as_bytes();
    let payload = EncodeJob::new(
        "drawer-123".to_string(),
        &estate_bytes,
        "round-trip payload text".to_string(),
        "test-model-v1".to_string(),
        captured_millis,
    );
    let stream_id = StreamId("glk_encode_test".to_string());
    let hlc = HLC { physical_time: 42, logical_count: 0, node_id: 1 };
    let job = payload.to_job(stream_id.clone(), hlc).expect("to_job");
    let decoded = EncodeJob::from_job(&job).expect("from_job");

    assert_eq!(decoded.drawer_id, "drawer-123");
    assert_eq!(
        decoded.estate_uuid,
        Uuid::from_bytes(estate_bytes).to_string().to_uppercase()
    );
    assert_eq!(decoded.text, "round-trip payload text");
    assert_eq!(decoded.embedding_model_id, "test-model-v1");
    // Capture instant round-trips to the same sub-second instant (exact in ms).
    assert_eq!(decoded.captured_at_millis(), captured_millis);
    assert_eq!(job.stream_id, stream_id);
}

// MARK: - EncodeJob JSON shape byte-agrees with the Swift Codable shape

/// The EncodeJob JSON keys match the Swift `Codable` property names exactly
/// (`drawerID`, `estateUUID`, `text`, `embeddingModelID`, `capturedAtISO8601`)
/// and the estateUUID is the uppercase UUID string Swift's UUID Codable emits —
/// the load-bearing cross-port wire contract (item #3).
#[test]
fn encode_job_json_shape_matches_swift() {
    let estate_bytes = [
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88,
    ];
    let job = EncodeJob::new(
        "drawer-1".to_string(),
        &estate_bytes,
        "hello".to_string(),
        "m-1".to_string(),
        1_700_000_000_000,
    );
    let json: serde_json::Value =
        serde_json::from_slice(&serde_json::to_vec(&job).unwrap()).unwrap();
    assert_eq!(json["drawerID"], "drawer-1");
    assert_eq!(json["text"], "hello");
    assert_eq!(json["embeddingModelID"], "m-1");
    // Uppercase UUID string, matching Swift's UUID Codable output.
    assert_eq!(json["estateUUID"], "12345678-9ABC-DEF0-1122-334455667788");
    // ISO8601 with fractional seconds and a trailing Z.
    assert_eq!(json["capturedAtISO8601"], "2023-11-14T22:13:20.000Z");
}

// MARK: - BURST (load) — all regular-mode burst captures become recallable

/// A unique, collision-free, high-IDF BM25 token per index. Mirrors the Swift
/// `uniqueToken`: a fixed prefix, the 3-digit index spelled in letters at fixed
/// width (0→'a'…9→'j'), and a consonant suffix so Porter2 does not trim it and
/// no token is a prefix of another.
fn unique_token(i: usize) -> String {
    let padded = format!("{:03}", i);
    let letters: String = padded
        .chars()
        .map(|c| (b'a' + (c as u8 - b'0')) as char)
        .collect();
    format!("qzx{}xq", letters)
}

/// A CorpusKit-BM25-only request isolating the semantic lane the encode worker
/// lights. Mirrors the Swift `corpusOnlyRequest`.
fn corpus_only_request(query: &str) -> GLKRecallRequest {
    GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::CorpusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(200)
        .with_fallback(RecallFallbackPolicy::FailClosed)
        .with_query_text(query.to_string())
}

/// A burst of 120 regular captures, drained to completion: ALL 120 become
/// BM25-recallable by their distinctive token. Asserts 100% — not a tolerance.
///
/// This is the Rust twin of Swift `burstOf120AllBecomeRecallableAndAcceptStaysFast`.
/// The Rust InMemory transaction commit mutates live state (snapshot-for-rollback
/// only), so a concurrent bare `send()` insert is never clobbered by the drain's
/// serializable claim — the lost-update that the Swift port had to fix never
/// existed on this port. This test guards that property end-to-end.
#[test]
fn burst_of_120_regular_captures_all_recallable() {
    let (mut coord, handle) = provision_glk_estate();
    let n = 120usize;
    let mut ids = Vec::with_capacity(n);
    for i in 0..n {
        let d = coord
            .capture_with_mode(
                &handle,
                capture_frame(&unique_token(i)),
                NOW + i as i64,
                WriteMode::Regular,
            )
            .expect("regular capture");
        ids.push(d.id);
    }
    // Pump-drive the drain to completion (the Rust port has no background worker
    // in this path; await_encode_drain drives drain_encode_queue_once).
    coord.await_encode_drain(&handle).expect("await_encode_drain");

    let mut recalled = 0;
    for i in 0..n {
        let r = coord
            .recall_scored(&handle, corpus_only_request(&unique_token(i)), NOW + 1000)
            .expect("recall_scored");
        if r.hits.iter().any(|h| {
            h.drawer.as_ref().map(|d| d.id.as_str()) == Some(ids[i].as_str())
                && h.sources.contains(&RecallEvidencePath::CorpusBm25)
        }) {
            recalled += 1;
        }
    }
    assert_eq!(
        recalled, n,
        "ALL of the burst must be BM25-recallable end-to-end (got {recalled}/{n})"
    );
}

// MARK: - AT-LEAST-ONCE (transient ingest failure is retried, never lost)

/// A burst where each drawer's first ingest attempt fails transiently: the
/// bounded at-least-once retry re-attempts and lands every job, so all 120 are
/// recallable. Nothing is silently dropped on a transient failure. Rust twin of
/// Swift `burstWithInjectedTransientIngestFailureStillReaches100Percent`.
#[test]
fn burst_with_transient_ingest_failure_still_reaches_100_percent() {
    let (mut coord, handle) = provision_glk_estate();
    coord.arm_transient_encode_ingest_failures();

    let n = 120usize;
    let mut ids = Vec::with_capacity(n);
    for i in 0..n {
        let d = coord
            .capture_with_mode(
                &handle,
                capture_frame(&unique_token(i)),
                NOW + i as i64,
                WriteMode::Regular,
            )
            .expect("regular capture");
        ids.push(d.id);
    }
    coord.await_encode_drain(&handle).expect("await_encode_drain");

    let mut recalled = 0;
    for i in 0..n {
        let r = coord
            .recall_scored(&handle, corpus_only_request(&unique_token(i)), NOW + 1000)
            .expect("recall_scored");
        if r.hits.iter().any(|h| {
            h.drawer.as_ref().map(|d| d.id.as_str()) == Some(ids[i].as_str())
                && h.sources.contains(&RecallEvidencePath::CorpusBm25)
        }) {
            recalled += 1;
        }
    }
    assert_eq!(
        recalled, n,
        "at-least-once retry must land ALL jobs despite injected transient failures (got {recalled}/{n})"
    );
}
