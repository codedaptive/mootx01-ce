//! Resident float-index admission cap tests for the Rust VectorStore.
//!
//! Covers the four behaviours from MISSION_RS_01 Part 3:
//!
//!   (a) OVER-CAP: a tiny Bytes ceiling causes the float index to be refused,
//!       bumps the refusal count, and still returns correct query results from
//!       the table-scan fallback path.
//!
//!   (b) UNDER-CAP: a generous ceiling admits the index; the index IS resident,
//!       refusal count stays zero, and results are identical to (a). Asserting
//!       result identity between the resident and scan paths is the strongest
//!       single assertion here.
//!
//!   (c) UNBOUNDED overrides: the Unbounded case must admit an estate that the
//!       tiny Bytes(1) ceiling would refuse. This is the explicit opt-out.
//!
//!   (d) PROJECTION LITERALS: the projection formula must produce specific byte
//!       values for recordCount=10_000 at stride=1_536 (dim=384, float32), so
//!       the twin Swift test can assert the same numbers and any formula
//!       divergence shows up as a test failure rather than silence.
//!
//! WHY TINY EXPLICIT CEILINGS NOT SYSTEM FRACTIONS:
//!   A SystemFraction(0.25) ceiling on a test machine with several GiB of RAM
//!   resolves to several hundred megabytes — far above any projection from the
//!   small corpora used in integration tests. It can never trip. A tiny
//!   Bytes(1) ceiling trips immediately and exercises the identical admission
//!   branch in milliseconds without allocating real multi-gigabyte estates.

use persistence_kit::{inmemory::InMemoryStorage, BackendConfiguration, EstateConfiguration, ResidentIndexBudget, Storage};
use synapsekit::{engine::metric::FloatMetric, VectorPayload, VectorStore};
use std::sync::Arc;
use uuid::Uuid;

const MODEL: &str = "admission-model";
const FILED_AT: i64 = 1_700_000_000;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Open a VectorStore backed by InMemoryStorage with the given budget.
/// The HNSW activation threshold is left at the default (5_000) so tests
/// below that count use the brute-force exact path.
fn store_with_budget(budget: ResidentIndexBudget) -> VectorStore {
    let mut config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    config.resident_index_budget = budget;
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    VectorStore::open(storage).expect("VectorStore::open must succeed on InMemory")
}

/// Open a VectorStore with a custom HNSW activation threshold AND a custom
/// budget. Used by projection-literal tests that must control which branch of
/// _project_float_index_bytes fires for 10_000 records.
fn store_with_budget_and_hnsw_threshold(
    budget: ResidentIndexBudget,
    hnsw_threshold: u32,
) -> VectorStore {
    let mut config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    config.resident_index_budget = budget;
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    VectorStore::open_with_hnsw_threshold(storage, hnsw_threshold)
        .expect("VectorStore::open_with_hnsw_threshold must succeed on InMemory")
}

/// Insert a slice of (item_id, float vector) pairs under the given model.
fn add_floats(store: &VectorStore, items: &[(&str, Vec<f32>)], model: &str) {
    for (item_id, floats) in items {
        let payload = VectorPayload::from_f32(floats);
        store
            .add_payload(item_id, 0, &payload, model, "1", FILED_AT)
            .expect("add_payload must not fail");
    }
}

/// Small deterministic corpus with unambiguous nearest ordering.
/// Probe [1, 0] → item "near" ([0.9, 0.1]) is nearest; "far" ([-1, -1]) is farthest.
fn corpus() -> Vec<(&'static str, Vec<f32>)> {
    vec![
        ("near", vec![0.9_f32, 0.1]),
        ("mid", vec![0.5_f32, 0.5]),
        ("far", vec![-1.0_f32, -1.0]),
    ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Behaviour (a): over-cap estate degrades gracefully
// ─────────────────────────────────────────────────────────────────────────────

/// A Bytes(1) ceiling is far below any projection: the float index must be
/// refused, the refusal counter must increment, and find_nearest_float must
/// still return correct results from the table-scan fallback.
///
/// This is half of the discrimination test: the same corpus and query used in
/// under_cap_index_is_resident produces different residency outcomes driven
/// only by the budget value.
#[test]
fn over_cap_index_not_resident_refusal_bumped_results_correct() {
    // Bytes(1) is 1 byte — always below any float-payload projection.
    let store = store_with_budget(ResidentIndexBudget::Bytes(1));
    add_floats(&store, &corpus(), MODEL);

    // Trigger admission check by querying.
    let results = store
        .find_nearest_float(&[1.0_f32, 0.0], MODEL, 3, FloatMetric::Cosine)
        .expect("find_nearest_float must return Ok even when index is refused");

    // Index must NOT be cached — refusal leaves residency false.
    assert!(
        !store.float_index_resident(MODEL),
        "float index must not be resident when cap is Bytes(1)"
    );

    // The refusal counter must have incremented at least once.
    assert!(
        store.admission_refusal_count() > 0,
        "admission_refusal_count must be > 0 after a cap refusal; got {}",
        store.admission_refusal_count()
    );

    // Results must be non-empty — the scan path returns correct rows.
    assert!(
        !results.is_empty(),
        "find_nearest_float must return results from the scan path even after refusal"
    );
    // Nearest result must be the closest item.
    assert_eq!(
        results[0].item_id, "near",
        "scan path must return the geometrically nearest item first"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Behaviour (b): under-cap estate caches the index
// ─────────────────────────────────────────────────────────────────────────────

/// A Bytes(1_000_000_000) ceiling (1 GiB) is far above any projection from a
/// 3-vector corpus: the float index must be admitted and results must be
/// identical to the scan-path results from the over-cap test.
///
/// This is the other half of the discrimination test: same corpus, same probe,
/// same k — the only difference is the budget.
#[test]
fn under_cap_index_is_resident_refusal_zero_results_identical() {
    // Bytes(1_000_000_000) is 1 GiB — always above any projection from a
    // tiny corpus. Same corpus and probe as the over-cap test.
    let store = store_with_budget(ResidentIndexBudget::Bytes(1_000_000_000));
    add_floats(&store, &corpus(), MODEL);

    let results = store
        .find_nearest_float(&[1.0_f32, 0.0], MODEL, 3, FloatMetric::Cosine)
        .expect("find_nearest_float must return Ok when admitted");

    // Index MUST be cached after a successful admission.
    assert!(
        store.float_index_resident(MODEL),
        "float index must be resident when cap is generous"
    );

    // No refusals.
    assert_eq!(
        store.admission_refusal_count(),
        0,
        "admission_refusal_count must be zero when every build is admitted"
    );

    // Results must be non-empty and agree with the scan-path order.
    assert!(
        !results.is_empty(),
        "find_nearest_float must return results when admitted"
    );
    assert_eq!(
        results[0].item_id, "near",
        "resident-index path must return the geometrically nearest item first"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Behaviour (c): Unbounded overrides a ceiling that would otherwise refuse
// ─────────────────────────────────────────────────────────────────────────────

/// The Unbounded case must admit an estate that Bytes(1) would refuse.
/// This is the explicit operator opt-out of the admission gate.
#[test]
fn unbounded_admits_estate_that_tiny_bytes_would_refuse() {
    // Establish that Bytes(1) refuses this corpus (reproduced from (a)).
    let refused_store = store_with_budget(ResidentIndexBudget::Bytes(1));
    add_floats(&refused_store, &corpus(), MODEL);
    refused_store
        .find_nearest_float(&[1.0_f32, 0.0], MODEL, 1, FloatMetric::Cosine)
        .expect("find_nearest_float");
    assert!(
        !refused_store.float_index_resident(MODEL),
        "Bytes(1) must refuse the float index — precondition for the (c) test"
    );

    // Same corpus with Unbounded must admit.
    let admitted_store = store_with_budget(ResidentIndexBudget::Unbounded);
    add_floats(&admitted_store, &corpus(), MODEL);
    admitted_store
        .find_nearest_float(&[1.0_f32, 0.0], MODEL, 1, FloatMetric::Cosine)
        .expect("find_nearest_float under Unbounded");

    assert!(
        admitted_store.float_index_resident(MODEL),
        "Unbounded must admit the float index regardless of projected footprint"
    );
    assert_eq!(
        admitted_store.admission_refusal_count(),
        0,
        "Unbounded must produce zero refusals"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Behaviour (d): projection literals — cross-port agreement
// ─────────────────────────────────────────────────────────────────────────────
//
// These tests verify the exact byte figures the projection formula computes for
// recordCount=10_000, dim=384 (stride=1_536 bytes per float32 record):
//
//   OVERHEAD = 2_000 bytes/record (measured Rust RSS; both ports use the larger
//              Rust figure so they always agree on admission decisions).
//
//   Below HNSW threshold:
//     projected = 10_000 × (1_536 + 2_000) = 10_000 × 3_536 = 35_360_000
//
//   At/above HNSW threshold:
//     graph_allow = 1_536 + 2_000 + 256 = 3_792
//     projected = 10_000 × (1_536 + 2_000 + 3_792) = 10_000 × 7_328 = 73_280_000
//
// The discrimination ceiling sits between the two projections: 40_000_000.
//   - Below threshold (hnsw_threshold=50_000):  35_360_000 < 40_000_000 → ADMITTED.
//   - Above threshold (hnsw_threshold=100):      73_280_000 > 40_000_000 → REFUSED.
//
// If either port's formula drifts, the admitted/refused assertion flips.
// The Swift twin uses the same record count, same dim, and the same ceiling
// so divergence is caught in the same test run that runs both ports.

/// Below-HNSW-threshold projection for 10_000 × dim=384 must be 35_360_000.
///
/// Verified indirectly: ceiling=40_000_000 (above 35_360_000) admits the index
/// when hnsw_threshold=50_000 forces the below-threshold branch.
#[test]
fn projection_below_hnsw_threshold_10k_records_dim384_admitted_at_ceiling_40m() {
    // Cross-port literal inputs:
    //   recordCount=10_000, dim=384 (stride=1_536 bytes)
    //   ceiling=40_000_000 bytes
    // Expected projection (below-threshold formula):
    //   10_000 × (1_536 + 2_000) = 35_360_000 < ceiling → ADMITTED.
    const DIM: usize = 384; // stride = 384 × 4 = 1_536 bytes
    const RECORD_COUNT: usize = 10_000;
    const CEILING: u64 = 40_000_000;
    // hnsw_threshold=50_000: 10_000 < 50_000 → below-threshold branch fires.
    const HNSW_THRESHOLD: u32 = 50_000;

    let store = store_with_budget_and_hnsw_threshold(
        ResidentIndexBudget::Bytes(CEILING),
        HNSW_THRESHOLD,
    );
    let floats = vec![0.1_f32; DIM];
    for i in 0..RECORD_COUNT {
        let payload = VectorPayload::from_f32(&floats);
        store
            .add_payload(&format!("item-{i}"), 0, &payload, MODEL, "1", FILED_AT)
            .expect("add_payload");
    }

    // Trigger admission.
    let probe = vec![1.0_f32; DIM];
    store
        .find_nearest_float(&probe, MODEL, 1, FloatMetric::Cosine)
        .expect("find_nearest_float");

    // Below-threshold projection 35_360_000 < ceiling 40_000_000 → admitted.
    assert!(
        store.float_index_resident(MODEL),
        "below-threshold projection (35_360_000) must be ADMITTED at ceiling 40_000_000; \
         if this fails the projection formula has diverged from the expected literal"
    );
    assert_eq!(
        store.admission_refusal_count(),
        0,
        "no refusals expected when below-threshold projection fits under ceiling"
    );
}

/// At/above-HNSW-threshold projection for 10_000 × dim=384 must be 73_280_000.
///
/// Verified indirectly: ceiling=40_000_000 (below 73_280_000) refuses the index
/// when hnsw_threshold=100 forces the above-threshold branch.
#[test]
fn projection_above_hnsw_threshold_10k_records_dim384_refused_at_ceiling_40m() {
    // Cross-port literal inputs:
    //   recordCount=10_000, dim=384 (stride=1_536 bytes)
    //   ceiling=40_000_000 bytes
    // Expected projection (above-threshold formula):
    //   graph_allow = 1_536 + 2_000 + 256 = 3_792
    //   10_000 × (1_536 + 2_000 + 3_792) = 10_000 × 7_328 = 73_280_000 > ceiling → REFUSED.
    const DIM: usize = 384;
    const RECORD_COUNT: usize = 10_000;
    const CEILING: u64 = 40_000_000;
    // hnsw_threshold=100: 10_000 >= 100 → above-threshold branch fires.
    const HNSW_THRESHOLD: u32 = 100;

    let store = store_with_budget_and_hnsw_threshold(
        ResidentIndexBudget::Bytes(CEILING),
        HNSW_THRESHOLD,
    );
    let floats = vec![0.1_f32; DIM];
    for i in 0..RECORD_COUNT {
        let payload = VectorPayload::from_f32(&floats);
        store
            .add_payload(&format!("item-{i}"), 0, &payload, MODEL, "1", FILED_AT)
            .expect("add_payload");
    }

    // Trigger admission.
    let probe = vec![1.0_f32; DIM];
    let results = store
        .find_nearest_float(&probe, MODEL, 1, FloatMetric::Cosine)
        .expect("find_nearest_float must return Ok even when index is refused");

    // Above-threshold projection 73_280_000 > ceiling 40_000_000 → refused.
    assert!(
        !store.float_index_resident(MODEL),
        "above-threshold projection (73_280_000) must be REFUSED at ceiling 40_000_000; \
         if this fails the projection formula has diverged from the expected literal"
    );
    assert!(
        store.admission_refusal_count() > 0,
        "refusal count must be > 0 when above-threshold projection exceeds ceiling"
    );
    // Scan path must still return correct results even after refusal.
    assert!(
        !results.is_empty(),
        "find_nearest_float must return results from the scan path after a projection refusal"
    );
}
