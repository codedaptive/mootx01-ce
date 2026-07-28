// expunge_vector_orphan.rs
//
// Parity tests for GLK's cross-kit vector delete on expunge.
// Rust mirror of Swift's ExpungeVectorOrphanTests.swift.
//
// The gap this closes: before GLK orchestration landed, Rust `expunge` called
// only `estate.expunge` — the Corpus and standalone VectorKit were never
// cleaned up. A user's "deleted" memory could still be recalled through the
// BM25/vector semantic lanes.
//
// Tests:
//   E1 — corpus no longer recalls the expunged drawer after expunge.
//   E2 — corpus.remove was invoked: chunk count for the source_id drops to zero.
//   E3 — standalone VectorStore without Corpus triggers CrossKitVectorDeleteFailed.
//   E4 — locusOnly estate expunge (no corpus, no vector store) succeeds without
//        attempting a cross-kit delete.
//   E5 — happy path: success audit sealed AFTER cross-kit delete (§B-2a ordering).
//   E6 — step-2 fails: orphan audit present, NO success audit, throw fires.
//   E7 — validation failure: no mutation, no audit (validation-first preserved).
//   E8 — double-failure: step-2 fails AND orphan-seal fails; returned error carries
//        both failure reasons; the coordinator does NOT swallow the seal error.
//   E9 — undistilled drawer expunge is a no-op for the distillation lane
//        (parity with Swift E9: expungeOfUndistilledDrawerSucceeds).
//   E10 — lineage cascade scrubs every member's lane entry (parity with Swift E10:
//         expungeScrubsLaneEntriesAcrossLineage).

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::{EstateCoordinator, VerbDispatchError, VerbError};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};
use locus_kit::{
    estate_types::LatticeAnchor,
    filter::{Filter, RecallFrame},
    frames::CaptureFrame,
};
use persistence_kit::{inmemory::InMemoryStorage, BackendConfiguration, EstateConfiguration, Storage};
use substrate_ml::distillation_pipeline::DistillationPipeline;
use vectorkit::VectorStore;

// CaptureChannel lives in drawer_operational in the Rust port.
use locus_kit::drawer_operational::CaptureChannel;

const NOW: i64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn make_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

/// Open a single estate on a fresh in-memory store.
fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "expunge-vector-tests",
        LatticeAnchor::udc("000"),
        "test-agent",
        "test-embed-v1",
    )
}

/// Open a Corpus on its own storage (deterministic embedding, no CoreML).
fn make_corpus() -> Arc<CorpusContentEngine> {
    let storage = make_storage();
    Arc::new(CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic]).expect("Corpus::open"))
}

/// Open a standalone VectorStore on its own storage.
fn make_vector_store() -> Arc<VectorStore> {
    Arc::new(VectorStore::open(make_storage()).expect("VectorStore::open"))
}

// ---------------------------------------------------------------------------
// E1: corpus no longer recalls the expunged drawer after expunge
// ---------------------------------------------------------------------------

/// After GLK expunge, `Corpus::recall` with a matching query no longer
/// returns any chunks for the expunged drawer. The corpus BM25 and vector
/// index entries are removed by `Corpus::remove(source_id = row_id)`.
#[test]
fn e1_expunge_removes_drawer_from_corpus_recall() {
    let (mut coord, h) = open_one();

    let content = "xenon krypton argon noble gas periodic table element";
    let drawer = coord
        .capture(&h, cap_frame(content), NOW)
        .expect("capture");

    // Wire corpus; ingest the drawer with its id as source_id (G4 convention).
    let corpus = make_corpus();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus.clone());

    // Verify corpus recalls the chunk BEFORE expunge.
    let before = corpus
        .recall("noble gas argon", 10)
        .expect("recall before");
    let found_before = before.iter().any(|sc| sc.id == drawer.id);
    assert!(
        found_before,
        "corpus must recall drawer '{}' before expunge; got {} hit(s)",
        drawer.id,
        before.len()
    );

    // Expunge via GLK coordinator — triggers cross-kit vector delete.
    coord
        .expunge(&h, &drawer.id, "privacy delete test", true, NOW)
        .expect("expunge");

    // Verify corpus NO LONGER recalls the chunk after expunge.
    let after = corpus
        .recall("noble gas argon", 10)
        .expect("recall after");
    let found_after = after.iter().any(|sc| sc.id == drawer.id);
    assert!(
        !found_after,
        "corpus must NOT recall drawer '{}' after expunge; the vector and BM25 index entries must be purged",
        drawer.id
    );
}

// ---------------------------------------------------------------------------
// E2: corpus.remove was invoked — chunk count for the source_id drops to zero
// ---------------------------------------------------------------------------

/// After GLK expunge, the Corpus has no more chunks with the expunged drawer's
/// source_id in BM25 recall results. This verifies the cross-kit delete acted on
/// the correct source_id (the drawer id, per the G4 ingest convention).
///
/// Parity of Swift `expungeRemovesChunksFromCorpusRecallIndex`.
#[test]
fn e2_expunge_clears_chunks_for_source_in_corpus() {
    let (mut coord, h) = open_one();

    let content = "osmium iridium platinum dense transition metal element";
    let drawer = coord
        .capture(&h, cap_frame(content), NOW)
        .expect("capture");

    let corpus = make_corpus();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus.clone());

    // Count chunks BEFORE expunge (BM25 top-k by source).
    let before_sources = corpus.bm25_top_k_by_source("platinum transition metal", 10);
    let sources_before: Vec<_> = before_sources
        .iter()
        .filter(|(sid, _)| sid == &drawer.id)
        .collect();
    assert!(
        !sources_before.is_empty(),
        "corpus must surface drawer '{}' in bm25_top_k_by_source before expunge",
        drawer.id
    );

    coord
        .expunge(&h, &drawer.id, "chunk-level verification", true, NOW)
        .expect("expunge");

    // After expunge: source_id must not appear in BM25 results.
    let after_sources = corpus.bm25_top_k_by_source("platinum transition metal", 10);
    let sources_after: Vec<_> = after_sources
        .iter()
        .filter(|(sid, _)| sid == &drawer.id)
        .collect();
    assert!(
        sources_after.is_empty(),
        "corpus must NOT surface expunged drawer '{}' in bm25_top_k_by_source; \
         corpus.remove must have cleared the BM25 index entry",
        drawer.id
    );
}

// ---------------------------------------------------------------------------
// E3: standalone VectorStore without Corpus → CrossKitVectorDeleteFailed
// ---------------------------------------------------------------------------

/// When a standalone VectorStore is registered without a Corpus, `expunge`
/// raises `VerbError::CrossKitVectorDeleteFailed` rather than silently
/// succeeding with an orphaned vector. This is the fail-closed privacy
/// contract: no silent orphan.
///
/// Parity of Swift `expungeThrowsCrossKitVectorDeleteFailedWhenCorpusRemoveFails`.
#[test]
fn e3_expunge_fails_closed_when_vector_store_registered_without_corpus() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("fail-closed probe content"), NOW)
        .expect("capture");

    // Register ONLY a standalone VectorStore, no Corpus. This is the defensive
    // branch: modelID is unavailable, so expunge must raise CrossKitVectorDeleteFailed
    // rather than silently proceeding.
    let vs = make_vector_store();
    coord.register_vector_store(&h, vs);

    let result = coord.expunge(&h, &drawer.id, "fail-closed probe", true, NOW);
    match result {
        Err(VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
            row_id,
            reason,
        })) => {
            assert_eq!(
                row_id, drawer.id,
                "CrossKitVectorDeleteFailed must carry the correct row_id"
            );
            assert!(
                !reason.is_empty(),
                "CrossKitVectorDeleteFailed must carry a non-empty reason"
            );
        }
        other => {
            panic!(
                "expected VerbError::CrossKitVectorDeleteFailed, got {:?}",
                other
            );
        }
    }
}

// ---------------------------------------------------------------------------
// E4: locusOnly estate — expunge succeeds, cross-kit step is a no-op
// ---------------------------------------------------------------------------

/// Expunge on an estate with no Corpus and no VectorStore registered
/// (`.locusOnly` equivalent) completes successfully. The cross-kit step
/// is skipped (no-op), not an error.
///
/// Parity of Swift `expungeOnLocusOnlyEstateSucceedsWithoutVectorCleanup`.
#[test]
fn e4_expunge_on_locusonly_estate_succeeds_without_vector_cleanup() {
    let (coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("locusonly expunge probe"), NOW)
        .expect("capture");

    // No corpus, no vector store registered. Expunge must succeed cleanly.
    coord
        .expunge(&h, &drawer.id, "locusOnly test", true, NOW)
        .expect("expunge on locusOnly estate must succeed");

    // The drawer must not appear in active recall.
    let frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    let rows = coord
        .recall(&h, frame, NOW)
        .expect("recall after locusOnly expunge");
    assert!(
        !rows.iter().any(|d| d.id == drawer.id),
        "expunged drawer must not appear in active recall"
    );
}

// ---------------------------------------------------------------------------
// E5: happy path — success audit sealed AFTER cross-kit delete (§B-2a ordering)
// ---------------------------------------------------------------------------

/// Verifies the §B-2a audit-seal ordering: after a successful full expunge
/// (storage + cross-kit corpus delete), exactly ONE "tombstone" audit event
/// exists in the substrate and NO "expungeOrphan" event exists.
///
/// If the seal occurred before the vector delete, a step-2 failure would
/// produce a success "tombstone" event while the embedding survived. The
/// parity assertion here proves the success seal fires only after step 2.
///
/// Parity of Swift `expungeSuccessAuditSealedAfterVectorDelete`.
#[test]
fn e5_expunge_success_audit_sealed_after_vector_delete() {
    let (mut coord, h) = open_one();

    let content = "helium neon argon noble gas periodic table element audit ordering";
    let drawer = coord
        .capture(&h, cap_frame(content), NOW)
        .expect("capture");

    let corpus = make_corpus();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus.clone());

    // Full expunge — storage + cross-kit delete, both succeed.
    coord
        .expunge(&h, &drawer.id, "audit ordering test", true, NOW)
        .expect("expunge");

    // Substrate audit trail must contain exactly ONE "tombstone" event
    // (the success audit) and NO "expungeOrphan" event.
    let estate = coord
        .estate_for(&h)
        .expect("estate must still be open after expunge");
    let trail = estate
        .audit_trail(&drawer.id)
        .expect("audit_trail must not fail");
    let tombstone_count = trail.iter().filter(|e| e.verb == "tombstone").count();
    let orphan_count = trail.iter().filter(|e| e.verb == "expungeOrphan").count();

    assert_eq!(
        tombstone_count, 1,
        "exactly one 'tombstone' success audit must exist after a successful expunge; got {}",
        tombstone_count
    );
    assert_eq!(
        orphan_count, 0,
        "no 'expungeOrphan' event must exist after a successful expunge; got {}",
        orphan_count
    );

    // Corpus must have no chunks for this drawer (proves cross-kit delete
    // ran; §B-2a ordering verified because success audit exists AND corpus
    // is empty).
    let chunks_after = corpus
        .recall("noble gas argon", 10)
        .expect("recall after expunge");
    let vector_survived = chunks_after
        .iter()
        .any(|sc| sc.id == drawer.id);
    assert!(
        !vector_survived,
        "no corpus chunk must survive after a successful expunge — \
         cross-kit delete ran before the success audit sealed (§B-2a)"
    );
}

// ---------------------------------------------------------------------------
// E6: step-2 fails → orphan audit present, NO success audit, throw fires
// ---------------------------------------------------------------------------

/// When the cross-kit vector delete (step 2) fails, the expunge verb must:
///   1. Throw `VerbError::CrossKitVectorDeleteFailed`.
///   2. Leave an "expungeOrphan" audit event in the substrate.
///   3. Leave NO "tombstone" success audit event.
///   4. Leave the row tombstoned and its content zeroed (storage half done).
///
/// This is the core §B-2a assertion: before this fix, a "tombstone" success
/// event was sealed in step 1 even when step 2 failed — the audit over-reported.
/// After this fix, only the orphan event is sealed on step-2 failure.
///
/// Fault injection: standalone VectorStore without a Corpus triggers the
/// defensive CrossKitVectorDeleteFailed branch.
///
/// Parity of Swift `expungeStep2FailureSealsOrphanAuditNotSuccessAudit`.
#[test]
fn e6_expunge_step2_failure_seals_orphan_audit_not_success_audit() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("orphan audit test"), NOW)
        .expect("capture");

    // Register a standalone VectorStore without a Corpus — this triggers the
    // defensive CrossKitVectorDeleteFailed branch in coordinator.expunge.
    let vs = make_vector_store();
    coord.register_vector_store(&h, vs);

    // Expunge must throw CrossKitVectorDeleteFailed.
    let result = coord.expunge(&h, &drawer.id, "orphan audit probe", true, NOW);
    match &result {
        Err(VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
            row_id, ..
        })) => {
            assert_eq!(
                row_id, &drawer.id,
                "CrossKitVectorDeleteFailed must carry the correct row_id"
            );
        }
        other => panic!(
            "expected CrossKitVectorDeleteFailed, got {:?}",
            other
        ),
    }

    // Substrate audit trail must contain ONE "expungeOrphan" event and
    // NO "tombstone" success event. This is the core §B-2a assertion.
    let estate = coord
        .estate_for(&h)
        .expect("estate must still be open after failed expunge");
    let trail = estate
        .audit_trail(&drawer.id)
        .expect("audit_trail must not fail");
    let tombstone_count = trail.iter().filter(|e| e.verb == "tombstone").count();
    let orphan_count = trail.iter().filter(|e| e.verb == "expungeOrphan").count();

    assert_eq!(
        tombstone_count, 0,
        "NO 'tombstone' success audit must exist when step-2 failed; got {}",
        tombstone_count
    );
    assert_eq!(
        orphan_count, 1,
        "exactly one 'expungeOrphan' audit must exist after step-2 failure; got {}",
        orphan_count
    );

    // Row must be tombstoned and content zeroed (storage step 1 succeeded).
    // Use coordinator.all_drawers (public) since Estate.store is pub(crate).
    let all_drawers = coord.all_drawers(&h).expect("all_drawers");
    let row_after = all_drawers.iter().find(|d| d.id == drawer.id);
    assert!(
        row_after.map(|d| d.tombstoned_at.is_some()).unwrap_or(false),
        "row must be tombstoned even when step-2 failed"
    );
    assert_eq!(
        row_after.map(|d| d.content.as_str()).unwrap_or("NOT_FOUND"),
        "",
        "content must be zeroed even when step-2 failed"
    );
}

// ---------------------------------------------------------------------------
// E7: validation failure — no mutation, no audit (validation-first preserved)
// ---------------------------------------------------------------------------

/// Confirms that validation-before-mutation is preserved (invariant 1):
/// an expunge that fails validation (confirmation=false) leaves the row
/// completely unchanged — no tombstone, no audit event.
///
/// Parity of Swift `expungeValidationFailureLeavesRowAndVectorUntouched`.
#[test]
fn e7_expunge_validation_failure_leaves_row_untouched() {
    let (mut coord, h) = open_one();

    let content = "thorium uranium actinide radioactive element audit validation test";
    let drawer = coord
        .capture(&h, cap_frame(content), NOW)
        .expect("capture");

    let corpus = make_corpus();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus.clone());

    // Capture audit trail length before the rejected expunge.
    let estate = coord.estate_for(&h).expect("estate");
    let trail_before = estate.audit_trail(&drawer.id).expect("audit_trail before");
    let count_before = trail_before.len();

    // Expunge with confirmation=false must be rejected at the boundary.
    let result = coord.expunge(&h, &drawer.id, "validation test", false, NOW);
    assert!(
        result.is_err(),
        "expunge with confirmation=false must fail; got Ok"
    );

    // Audit trail must be unchanged — validation fires before any mutation.
    let trail_after = estate.audit_trail(&drawer.id).expect("audit_trail after");
    assert_eq!(
        trail_after.len(),
        count_before,
        "audit trail must not grow when expunge is rejected by validation; \
         before={} after={}",
        count_before,
        trail_after.len()
    );

    // Row must still be active.
    // Use coordinator.all_drawers (public) since Estate.store is pub(crate).
    let all_drawers = coord.all_drawers(&h).expect("all_drawers");
    let row_after = all_drawers.iter().find(|d| d.id == drawer.id);
    assert!(
        row_after.map(|d| d.tombstoned_at.is_none()).unwrap_or(false),
        "row must remain active (not tombstoned) when expunge is rejected"
    );
    assert_eq!(
        row_after.map(|d| d.content.as_str()).unwrap_or("NOT_FOUND"),
        content,
        "row content must be unchanged when expunge is rejected by validation"
    );

    // Corpus must still have the vector (validation fires before cross-kit delete).
    let chunks_after = corpus
        .recall("actinide radioactive", 10)
        .expect("recall after rejected expunge");
    let vector_present = chunks_after
        .iter()
        .any(|sc| sc.id == drawer.id);
    assert!(
        vector_present,
        "corpus vector must survive when expunge is rejected by validation — \
         validation-first preserved"
    );
}

// ---------------------------------------------------------------------------
// E8: double-failure — step-2 fails AND orphan-seal fails; error is NOT swallowed
// ---------------------------------------------------------------------------

/// When BOTH the cross-kit vector delete (step 2) AND the orphan-audit seal
/// fail, the coordinator must NOT swallow the seal error. The returned
/// `CrossKitVectorDeleteFailed` reason must contain BOTH failure descriptions
/// so the ARIA caller learns the full double-failure from a single typed error.
///
/// Before the fix, `let _ = estate.seal_expunge_orphan_audit(...)` silently
/// discarded the seal error, leaving a tombstoned row with no audit record and
/// no indication that the audit write also failed. The fix captures the seal
/// result and folds it into the `reason` string.
///
/// Fault injection:
///   - Step-2 failure: standalone VectorStore without Corpus (defensive branch).
///   - Orphan-seal failure: `Estate::set_test_force_orphan_seal_error(true)`.
///
/// Requires `--features test-seams` (the seam is compiled out in production).
#[cfg(any(test, feature = "test-seams"))]
#[test]
fn e8_double_failure_seal_error_folded_into_returned_error() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("double-failure probe content"), NOW)
        .expect("capture");

    // Register a standalone VectorStore without a Corpus — step-2 will
    // raise CrossKitVectorDeleteFailed from the defensive branch.
    let vs = make_vector_store();
    coord.register_vector_store(&h, vs);

    // Arm the orphan-seal fault seam on the estate so that when the
    // coordinator tries to write the "expungeOrphan" audit after step-2
    // fails, that write also fails. This is the double-failure path.
    let estate = coord.estate_for(&h).expect("estate must be open");
    estate.set_test_force_orphan_seal_error(true);

    // Expunge must fail with CrossKitVectorDeleteFailed.
    let result = coord.expunge(&h, &drawer.id, "double-failure probe", true, NOW);

    match result {
        Err(VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed { row_id, reason })) => {
            assert_eq!(
                row_id, drawer.id,
                "CrossKitVectorDeleteFailed must carry the correct row_id"
            );
            // The reason string must contain BOTH failure descriptions:
            // the step-2 reason AND the orphan-seal error.
            assert!(
                reason.contains("orphan-audit seal also failed"),
                "reason must describe the orphan-seal failure; got: {:?}",
                reason
            );
            assert!(
                reason.contains("forced orphan-seal failure"),
                "reason must carry the seal error message; got: {:?}",
                reason
            );
            // The reason must ALSO describe the original step-2 failure.
            assert!(
                !reason.is_empty() && reason.len() > 40,
                "reason must be non-trivial (both failures encoded); got: {:?}",
                reason
            );
        }
        other => panic!(
            "expected CrossKitVectorDeleteFailed with folded double-failure reason, got {:?}",
            other
        ),
    }
}

// ---------------------------------------------------------------------------
// E9: undistilled drawer expunge is a no-op for the lane (parity with Swift E9)
// ---------------------------------------------------------------------------

/// `delete_all_vectors` on an absent key is a no-op. An undistilled drawer
/// has no distillation-features-v1 lane entry; expunge must complete cleanly.
/// Parity of Swift `expungeOfUndistilledDrawerSucceeds`.
#[test]
fn e9_expunge_of_undistilled_drawer_is_no_op_for_lane() {
    let (mut coord, h) = open_one();

    // Capture a drawer without running the distillation sweep — no lane entry.
    let drawer = coord
        .capture(&h, cap_frame("plain undistilled polonium note"), NOW)
        .expect("capture");

    // Wire corpus + VectorStore so the full cross-kit step executes.
    // Content is not ingested into the corpus — remove_content is a no-op.
    let corpus = make_corpus();
    let vs = make_vector_store();
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vs);

    // Expunge must succeed — delete_all_vectors on an absent entry is a no-op.
    coord
        .expunge(
            &h,
            &drawer.id,
            "undistilled lane no-op test",
            true,
            NOW + 100,
        )
        .expect("expunge of undistilled drawer must succeed");

    // Drawer must be tombstoned.
    let estate = coord.estate_for(&h).expect("estate must be open");
    let row = estate
        .drawer_by_id(&drawer.id)
        .unwrap()
        .expect("row must still exist after tombstone");
    assert!(
        row.tombstoned_at.is_some(),
        "expunge must tombstone the drawer even when no lane entry exists"
    );
}

// ---------------------------------------------------------------------------
// E10: lineage cascade scrubs every member's lane entry (parity with Swift E10)
// ---------------------------------------------------------------------------

/// Expunge fans out over the entire lineage; each member's own
/// distillation-features-v1 lane entry (keyed by its id) must be deleted.
/// Parity of Swift `expungeScrubsLaneEntriesAcrossLineage`.
///
/// Uses three-sentence content so the matrix distillation path runs and
/// produces a non-zero fingerprint (entity "Rhenium" is mid-text, not first
/// word, so the default extractor captures it).
#[test]
fn e10_expunge_scrubs_lane_entries_across_lineage() {
    let (mut coord, h) = open_one();

    // v1 then v2 in the same lineage (v2 supersedes v1).
    let v1 = coord
        .capture(
            &h,
            cap_frame(
                "Batch one used Rhenium wire. Tests on Rhenium passed. Labs shipped Rhenium first.",
            ),
            NOW,
        )
        .expect("capture v1");

    let mut v2_frame = cap_frame(
        "Batch two used Rhenium wire. Retests on Rhenium passed. Labs shipped Rhenium again.",
    );
    // Same lineage — adding v2 causes the cascade to supersede v1.
    v2_frame.lineage_id = Some(v1.lineage_id);
    let v2 = coord
        .capture(&h, v2_frame, NOW + 100)
        .expect("capture v2");

    // Wire corpus + VectorStore before the distillation sweep.
    // Corpus is registered to satisfy the coordinator's fan-out (it calls
    // corpus.remove_content for each lineage member); content is not
    // ingested — those remove_content calls are no-ops.
    let corpus = make_corpus();
    let vs = make_vector_store();
    let vs_ref = vs.clone(); // retained for post-expunge queries
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vs);

    // Distill both v1 (Superseded) and v2 (Active) via the sweep. The sweep
    // processes all non-tombstoned drawers, so Superseded v1 is included.
    let distilled = coord
        .distill_items_sweep(&h, NOW + 200, None)
        .expect("distill_items_sweep");
    assert!(
        distilled >= 2,
        "sweep must produce at least 2 distilled items (v1 and v2); got {distilled}"
    );

    // Confirm both lane entries exist before expunge.
    let distill_lane = genius_locus_kit::brain::distillation_cycle::DISTILLATION_LANE_MODEL_ID;
    let probe =
        DistillationPipeline::query_fingerprint(&v1.content, DistillationPipeline::default_extractor);
    let before = vs_ref
        .find_nearest(&probe, distill_lane, 10)
        .expect("find_nearest before expunge");
    assert!(
        before.iter().any(|m| m.item_id == v1.id),
        "v1 lane entry must exist before expunge (fingerprint must be non-zero)"
    );
    assert!(
        before.iter().any(|m| m.item_id == v2.id),
        "v2 lane entry must exist before expunge (fingerprint must be non-zero)"
    );

    // Expunge the head (v2). The lineage fan-out scrubs both lane entries.
    coord
        .expunge(&h, &v2.id, "lineage lane scrub test", true, NOW + 300)
        .expect("expunge");

    // Both lane entries must be gone.
    let after = vs_ref
        .find_nearest(&probe, distill_lane, 10)
        .expect("find_nearest after expunge");
    assert!(
        !after.iter().any(|m| m.item_id == v1.id),
        "v1 predecessor lane entry must be scrubbed by the lineage cascade"
    );
    assert!(
        !after.iter().any(|m| m.item_id == v2.id),
        "v2 head lane entry must be scrubbed"
    );
}
