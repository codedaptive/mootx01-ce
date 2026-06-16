// composition_conformance_tests.rs — Rust mirror of the Mission GLK-08
// composition fixtures. The Swift reference is
// `Tests/GeniusLocusKitTests/CompositionConformanceTests.swift`.
//
// The `EstateCoordinator` dispatches all nine verbs through to a live
// `locus_kit::Estate` (verb bodies wired; see coordinator.rs MARK: propose,
// associate, learn, mutate, capture, recall, etc.). These composition
// fixtures exercise the surfaces beyond direct verb dispatch:
//
//   - Multi-estate coordinator open/close, handle issuance,
//     fan-out routing by lattice overlap (GLK-01 surface).
//   - Unified audit log projection across both tiers + enrichment
//     into the matrix tier (GLK-03 + GLK-06).
//   - Training daemon composes with the enrichment pipeline +
//     threshold gate (GLK-07).
//
// Verb-surface composition tests live in the Swift fixture
// (CompositionConformanceTests.swift); the Rust coordinator's verb
// dispatch is exercised directly in coordinator integration tests.

use genius_locus_kit::audit::{
    AuditProjectionFold, AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog,
    UnifiedAuditValue, UnifiedAuditVerb,
};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::fan_out::LatticeRegion;
use genius_locus_kit::handle::{EstateHandle, EstateUuid};
use genius_locus_kit::matrix::{MatrixCalibrationRegistry, MatrixTier};
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::inmemory::InMemoryStorage;
use std::sync::Arc;
use uuid::Uuid;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use genius_locus_kit::training::{EnrichmentPipeline, TrainingDaemon, TrainingThresholdGate};
use substrate_types::hlc::HLC;

// MARK: - Multi-estate fan-out by lattice overlap

/// Open one estate over a fresh in-memory store whose estate UUID is fixed
/// from `uuid_bytes`, so the handle UUID (derived from the opened estate) is
/// deterministic. Uses `InMemoryDrawerStore::with_storage` to pin the estate
/// UUID; all other construction sites use `InMemoryDrawerStore::new`.
fn open_estate(
    coord: &mut EstateCoordinator,
    uuid_bytes: EstateUuid,
    low: i64,
    high: i64,
) -> EstateHandle {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::from_bytes(uuid_bytes)));
    let store = Arc::new(InMemoryDrawerStore::with_storage(storage, 1_700_000_000, None).unwrap());
    coord
        .open(store, OwnerCredentials::new("owner"), low, high)
        .expect("open succeeds")
}

#[test]
fn multi_estate_open_and_fan_out_routes_by_overlap() {
    let mut coord = EstateCoordinator::new();
    let uuid_a: EstateUuid = [0xA0; 16];
    let uuid_b: EstateUuid = [0xB0; 16];
    let uuid_c: EstateUuid = [0xC0; 16];

    let h_a = open_estate(&mut coord, uuid_a, 0, 10);
    let h_b = open_estate(&mut coord, uuid_b, 5, 15);
    let h_c = open_estate(&mut coord, uuid_c, 20, 30);

    assert_eq!(coord.open_estate_count(), 3);

    // Region [4, 8] overlaps A and B; C is disjoint.
    let two_hit = coord
        .estates_overlapping(LatticeRegion::new(4, 8))
        .expect("region valid");
    let two_hit_uuids: std::collections::BTreeSet<_> =
        two_hit.iter().map(|h| h.estate_uuid).collect();
    let expected: std::collections::BTreeSet<_> =
        [h_a.estate_uuid, h_b.estate_uuid].iter().copied().collect();
    assert_eq!(two_hit_uuids, expected);
    assert!(!two_hit_uuids.contains(&h_c.estate_uuid));

    // Region [25, 28] overlaps C only.
    let one_hit = coord
        .estates_overlapping(LatticeRegion::new(25, 28))
        .expect("region valid");
    assert_eq!(one_hit.len(), 1);
    assert_eq!(one_hit[0].estate_uuid, h_c.estate_uuid);

    // Region [40, 50] overlaps nothing.
    let zero_hit = coord
        .estates_overlapping(LatticeRegion::new(40, 50))
        .expect("region valid");
    assert!(zero_hit.is_empty());

    // Close and verify the handle becomes stale.
    coord.close(&h_a).expect("close A succeeds");
    assert!(coord.estate_for(&h_a).is_err());
    assert_eq!(coord.open_estate_count(), 2);
}

// MARK: - Unified audit projection + enrichment across tiers

#[test]
fn unified_audit_projection_and_enrichment_fold_both_tiers() {
    let mut log = UnifiedAuditLog::new();

    let locus_a = row_uuid(1);
    let locus_b = row_uuid(2);
    let rag_a = row_uuid(3);
    let rag_b = row_uuid(4);
    let locus_c = row_uuid(5);

    fn add(
        log: &mut UnifiedAuditLog,
        tier: AuditTier,
        step: i64,
        verb: UnifiedAuditVerb,
        row: EntryUUID,
        path: &str,
        after: UnifiedAuditValue,
    ) {
        log.add(UnifiedAuditEntry::new(
            tier,
            HLC::new(step, 0, 1),
            verb,
            row,
            path.to_string(),
            UnifiedAuditValue::Null,
            after,
            None,
        ));
    }

    add(
        &mut log,
        AuditTier::Locus,
        1,
        UnifiedAuditVerb::Capture,
        locus_a,
        "tag_bits",
        UnifiedAuditValue::Bitmap(0x01),
    );
    add(
        &mut log,
        AuditTier::Rag,
        2,
        UnifiedAuditVerb::Capture,
        rag_a,
        "tag_bits",
        UnifiedAuditValue::Bitmap(0x02),
    );
    add(
        &mut log,
        AuditTier::Locus,
        3,
        UnifiedAuditVerb::Capture,
        locus_b,
        "tag_bits",
        UnifiedAuditValue::Bitmap(0x04),
    );
    add(
        &mut log,
        AuditTier::Rag,
        4,
        UnifiedAuditVerb::Capture,
        rag_b,
        "tag_bits",
        UnifiedAuditValue::Bitmap(0x08),
    );
    add(
        &mut log,
        AuditTier::Locus,
        5,
        UnifiedAuditVerb::Capture,
        locus_c,
        "tag_bits",
        UnifiedAuditValue::Bitmap(0x10),
    );

    let projection = AuditProjectionFold::project(&log);
    assert_eq!(projection.count(), 5);
    assert_eq!(projection.rows_in_tier(AuditTier::Locus).len(), 3);
    assert_eq!(projection.rows_in_tier(AuditTier::Rag).len(), 2);

    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let pipeline = EnrichmentPipeline::new();
    let result = pipeline.run(&log, &mut tier, &mut calibration, HLC::new(0, 0, 0));
    assert_eq!(result.transitions_considered, 5);
    assert_eq!(
        tier.live_row_count, 5,
        "enrichment folds every capture across both tiers"
    );
    assert!(!tier.field_presence.is_empty());
}

// MARK: - Training daemon composition

#[test]
fn training_daemon_composes_with_enrichment_and_gate() {
    // The Rust scheduler is exercised by `scheduler_parity.rs` and
    // `standing_signals_parity.rs`; this fixture composes the daemon
    // surface directly, which is what `TrainingDaemonTests` exercises
    // in Swift outside the scheduler-registration test (and what the
    // composition conformance suite is meant to assert at the kit
    // boundary).
    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let mut daemon = TrainingDaemon::new(TrainingThresholdGate::new(8));

    // Below-threshold tick: log has 4 captures, gate dormant.
    let mut log = UnifiedAuditLog::new();
    for i in 0..4u16 {
        log.add(UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new((i as i64) + 1, 0, 1),
            UnifiedAuditVerb::Capture,
            row_uuid(i),
            "tag_bits".to_string(),
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(1u64 << (i % 8)),
            None,
        ));
    }
    let tick_a = daemon.run_once(&log, &mut tier, &mut calibration);
    assert!(!tick_a.decision.is_active());
    assert_eq!(
        tier.live_row_count, 0,
        "below-threshold daemon must not enrich"
    );

    // Grow the log past the threshold and tick again — gate active.
    for i in 4..10u16 {
        log.add(UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new((i as i64) + 1, 0, 1),
            UnifiedAuditVerb::Capture,
            row_uuid(i),
            "tag_bits".to_string(),
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(1u64 << (i % 8)),
            None,
        ));
    }
    let tick_b = daemon.run_once(&log, &mut tier, &mut calibration);
    assert!(tick_b.decision.is_active());
    assert_eq!(
        tier.live_row_count, 10,
        "above-threshold daemon must enrich on the next tick"
    );
}

// MARK: - Helpers

fn row_uuid(index: u16) -> EntryUUID {
    let mut bytes = [0u8; 16];
    bytes[0] = (index & 0xFF) as u8;
    bytes[1] = ((index >> 8) & 0xFF) as u8;
    EntryUUID(bytes)
}
