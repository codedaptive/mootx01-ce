// recall_tuning_manifest_tests.rs
//
// Rust conformance tests for the optimizer-owned "recall_tuning" manifest key
// and RecallTuningManifest type (W4). Mirrors Swift RecallTuningManifestTests.
//
// Coverage:
//   (a) Spec defaults — Default::default() fields match the hardcoded spec constants.
//   (b) Codable round-trip — serialize + deserialize produces the same value.
//   (c) Snake_case wire keys are present in serialized JSON.
//   (d) Partial JSON — a JSON with only some keys fills absent keys with spec defaults.
//   (e) Malformed JSON — fails to deserialize (fail-quiet logic is caller responsibility).
//   (f) Golden pin — k=80, λ=0.6, bm25=0.4, vector=0.6 round-trips exactly.
//   (g) Estate verb round-trip via provision_recall_tuning / provisioned_recall_tuning.
//   (h) Absent key returns spec-default tuning.

use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, RecallTuningManifest};
use locus_kit::{
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("tuning-test"), 0, i64::MAX)
        .expect("open must succeed");
    (coord, handle)
}

// MARK: (a) Spec defaults

#[test]
fn default_rrf_k_is_60() {
    assert_eq!(RecallTuningManifest::default().rrf_k, 60);
}

#[test]
fn default_mmr_lambda_is_07() {
    let diff = (RecallTuningManifest::default().mmr_lambda - 0.7_f32).abs();
    assert!(diff < 1e-6, "mmr_lambda default expected 0.7, got {}", RecallTuningManifest::default().mmr_lambda);
}

#[test]
fn default_rrf_bm25_weight_is_03() {
    let diff = (RecallTuningManifest::default().rrf_bm25_weight - 0.3_f32).abs();
    assert!(diff < 1e-6, "bm25 default expected 0.3, got {}", RecallTuningManifest::default().rrf_bm25_weight);
}

#[test]
fn default_rrf_vector_weight_is_07() {
    let diff = (RecallTuningManifest::default().rrf_vector_weight - 0.7_f32).abs();
    assert!(diff < 1e-6, "vector default expected 0.7, got {}", RecallTuningManifest::default().rrf_vector_weight);
}

#[test]
fn two_defaults_are_equal() {
    assert_eq!(RecallTuningManifest::default(), RecallTuningManifest::default());
}

// MARK: (b) Codable round-trip

#[test]
fn serde_round_trip() {
    // Struct-update syntax spreads spec defaults for the seven packager threshold
    // fields added by the PACKAGER mission. The four recall fields are tested here.
    let original = RecallTuningManifest {
        rrf_k: 80,
        mmr_lambda: 0.6,
        rrf_bm25_weight: 0.4,
        rrf_vector_weight: 0.6,
        ..RecallTuningManifest::default()
    };
    let json = serde_json::to_string(&original).expect("serialize");
    let decoded: RecallTuningManifest = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(decoded, original);
}

// MARK: (c) Snake_case wire keys

#[test]
fn serialized_json_uses_snake_case_keys() {
    let tuning = RecallTuningManifest::default();
    let json = serde_json::to_string(&tuning).expect("serialize");
    assert!(json.contains("\"rrf_k\""), "expected rrf_k in JSON: {json}");
    assert!(json.contains("\"mmr_lambda\""), "expected mmr_lambda in JSON: {json}");
    assert!(json.contains("\"rrf_bm25_weight\""), "expected rrf_bm25_weight in JSON: {json}");
    assert!(json.contains("\"rrf_vector_weight\""), "expected rrf_vector_weight in JSON: {json}");
}

// MARK: (d) Partial JSON

#[test]
fn partial_json_fills_absent_keys_with_spec_defaults() {
    // Only rrf_k is present; the other three should resolve to spec defaults.
    let json = r#"{"rrf_k": 80}"#;
    let decoded: RecallTuningManifest = serde_json::from_str(json).expect("deserialize partial");
    assert_eq!(decoded.rrf_k, 80);
    let diff_lambda = (decoded.mmr_lambda - 0.7_f32).abs();
    assert!(diff_lambda < 1e-6, "mmr_lambda expected 0.7, got {}", decoded.mmr_lambda);
    let diff_bm25 = (decoded.rrf_bm25_weight - 0.3_f32).abs();
    assert!(diff_bm25 < 1e-6, "bm25 expected 0.3, got {}", decoded.rrf_bm25_weight);
    let diff_vec = (decoded.rrf_vector_weight - 0.7_f32).abs();
    assert!(diff_vec < 1e-6, "vector expected 0.7, got {}", decoded.rrf_vector_weight);
}

// MARK: (e) Malformed JSON

#[test]
fn malformed_json_fails_to_deserialize() {
    let result: Result<RecallTuningManifest, _> = serde_json::from_str("not-json");
    assert!(result.is_err(), "malformed JSON should fail to deserialize");
}

// MARK: (f) Golden pin

#[test]
fn golden_pin_non_default_tuning_round_trips() {
    // Pin: k=80, λ=0.6, bm25=0.4, vector=0.6 — all differ from spec defaults.
    let json = r#"{"mmr_lambda":0.6,"rrf_bm25_weight":0.4,"rrf_k":80,"rrf_vector_weight":0.6}"#;
    let decoded: RecallTuningManifest = serde_json::from_str(json).expect("deserialize golden pin");
    assert_eq!(decoded.rrf_k, 80);
    assert!((decoded.mmr_lambda - 0.6_f32).abs() < 1e-6, "lambda mismatch: {}", decoded.mmr_lambda);
    assert!((decoded.rrf_bm25_weight - 0.4_f32).abs() < 1e-6, "bm25 mismatch: {}", decoded.rrf_bm25_weight);
    assert!((decoded.rrf_vector_weight - 0.6_f32).abs() < 1e-6, "vector mismatch: {}", decoded.rrf_vector_weight);
    assert_ne!(decoded, RecallTuningManifest::default());
}

// MARK: (h) Absent key returns spec-default

#[test]
fn absent_key_returns_spec_default() {
    let (coord, handle) = open_one();
    let tuning = coord.provisioned_recall_tuning(&handle).expect("provisioned_recall_tuning");
    assert_eq!(tuning, RecallTuningManifest::default());
}

// MARK: (g) Estate verb round-trip

#[test]
fn provisioned_tuning_reads_back_unchanged() {
    let (coord, handle) = open_one();
    let written = RecallTuningManifest {
        rrf_k: 80,
        mmr_lambda: 0.6,
        rrf_bm25_weight: 0.4,
        rrf_vector_weight: 0.6,
        ..RecallTuningManifest::default()
    };
    coord.provision_recall_tuning(&handle, &written).expect("provision");
    let read = coord.provisioned_recall_tuning(&handle).expect("read back");
    assert_eq!(read, written);
}

#[test]
fn provisioned_tuning_overwrite_is_reflected() {
    let (coord, handle) = open_one();
    let first = RecallTuningManifest { rrf_k: 80, mmr_lambda: 0.6, rrf_bm25_weight: 0.4, rrf_vector_weight: 0.6, ..RecallTuningManifest::default() };
    coord.provision_recall_tuning(&handle, &first).expect("provision first");
    let second = RecallTuningManifest { rrf_k: 100, mmr_lambda: 0.5, rrf_bm25_weight: 0.5, rrf_vector_weight: 0.5, ..RecallTuningManifest::default() };
    coord.provision_recall_tuning(&handle, &second).expect("provision second");
    let read = coord.provisioned_recall_tuning(&handle).expect("read back");
    assert_eq!(read, second);
    assert_ne!(read, first);
}

#[test]
fn provisioning_default_reads_back_as_default() {
    let (coord, handle) = open_one();
    coord.provision_recall_tuning(&handle, &RecallTuningManifest::default()).expect("provision default");
    let read = coord.provisioned_recall_tuning(&handle).expect("read back");
    assert_eq!(read, RecallTuningManifest::default());
}
