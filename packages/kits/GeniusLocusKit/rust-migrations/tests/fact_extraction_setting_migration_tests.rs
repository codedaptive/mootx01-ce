//! Gate tests for the GLK 1.7 → 1.8 fact-extraction-setting migration capsule.
//! Rust twin of Swift `FactExtractionSettingMigrationTests.swift`.
//!
//! Six gate tests (G1–G6): enum default, absent-means-on seeding,
//! explicit-off preservation, stamp advance to V1_8, idempotent re-run,
//! and unrecognised-value fallback.

use std::sync::Arc;

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_preference::{EstatePreferenceKey, EstatePreferenceValue};
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit_migrations::FactExtractionSettingMigrationExt;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::Storage;

const NOW: i64 = 1_790_000_000_000; // millis — 2026-09-22

fn make_estate() -> (EstateCoordinator, EstateHandle, Arc<dyn Storage>) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");
    // Stamp V1_7 so the chain considers the estate historical and below current.
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(EstateFormatVersion::V1_7, NOW)
        .expect("stamp V1_7");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig18-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");
    (coord, handle, storage)
}

// ---------------------------------------------------------------------------
// G1 EstatePreferenceValue default
// ---------------------------------------------------------------------------

#[test]
fn g1_estate_preference_value_default_is_on() {
    let def = EstatePreferenceValue::default();
    assert_eq!(def, EstatePreferenceValue::On);
    assert_eq!(def.as_str(), "on");
    // Roundtrip: from_str returns Some for known values, None for garbage.
    assert_eq!(EstatePreferenceValue::from_str("on"), Some(EstatePreferenceValue::On));
    assert_eq!(EstatePreferenceValue::from_str("off"), Some(EstatePreferenceValue::Off));
    assert_eq!(EstatePreferenceValue::from_str("garbage"), None);
    // The fact-extraction key is stored under the manifest key "fact_extraction".
    assert_eq!(EstatePreferenceKey::FactExtraction.as_str(), "fact_extraction");
    assert_eq!(EstatePreferenceKey::from_str("fact_extraction"), Some(EstatePreferenceKey::FactExtraction));
}

// ---------------------------------------------------------------------------
// G2 absent-means-on seeding
// ---------------------------------------------------------------------------

#[test]
fn g2_migration_seeds_fact_extraction_on_when_absent() {
    let (coord, handle, storage) = make_estate();

    // Key must be absent before the capsule runs.
    let raw_before = coord
        .estate_for(&handle)
        .ok()
        .and_then(|e| e.meta(EstatePreferenceKey::FactExtraction.as_str()).ok())
        .flatten();
    assert!(raw_before.is_none(), "key must be absent before migration");

    // The public accessor returns On even when absent (absent-means-on).
    let before = coord
        .provisioned_preference(&handle, EstatePreferenceKey::FactExtraction)
        .expect("provisioned_preference");
    assert_eq!(before, EstatePreferenceValue::On);

    // Run the capsule.
    coord
        .run_fact_extraction_setting_migration(&handle, NOW)
        .expect("capsule succeeded");

    // The key must now be physically present with value "on".
    let raw_after = coord
        .estate_for(&handle)
        .ok()
        .and_then(|e| e.meta(EstatePreferenceKey::FactExtraction.as_str()).ok())
        .flatten();
    assert_eq!(raw_after.as_deref(), Some("on"), "migration seeded fact_extraction = on");

    let after = coord
        .provisioned_preference(&handle, EstatePreferenceKey::FactExtraction)
        .expect("provisioned_preference after migration");
    assert_eq!(after, EstatePreferenceValue::On);
    drop(storage);
}

// ---------------------------------------------------------------------------
// G3 explicit-off preserved
// ---------------------------------------------------------------------------

#[test]
fn g3_migration_preserves_explicit_off() {
    let (coord, handle, storage) = make_estate();

    // Pre-write Off through the public provisioner before migration.
    coord
        .provision_preference(&handle, EstatePreferenceKey::FactExtraction, EstatePreferenceValue::Off)
        .expect("provision Off");

    // Run the capsule.
    coord
        .run_fact_extraction_setting_migration(&handle, NOW)
        .expect("capsule succeeded");

    // The capsule must not overwrite an existing value.
    let after = coord
        .provisioned_preference(&handle, EstatePreferenceKey::FactExtraction)
        .expect("provisioned after migration");
    assert_eq!(after, EstatePreferenceValue::Off, "capsule must not overwrite Off");

    let raw = coord
        .estate_for(&handle)
        .ok()
        .and_then(|e| e.meta(EstatePreferenceKey::FactExtraction.as_str()).ok())
        .flatten();
    assert_eq!(raw.as_deref(), Some("off"));
    // The stamp advances to V1_8 even when the value was pre-set.
    let stamp = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read_if_present");
    assert_eq!(stamp, Some(EstateFormatVersion::V1_8), "capsule stamps V1_8 even when value is pre-set");
}

// ---------------------------------------------------------------------------
// G4 stamp advance to V1_8
// ---------------------------------------------------------------------------

#[test]
fn g4_migration_stamps_v1_8() {
    let (coord, handle, storage) = make_estate();

    coord
        .run_fact_extraction_setting_migration(&handle, NOW)
        .expect("capsule succeeded");

    let stamp = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read_if_present");
    assert_eq!(stamp, Some(EstateFormatVersion::V1_8), "capsule must stamp V1_8");
    // The capsule stamps V1_8 in isolation; later capsules carry the estate
    // on to `EstateFormatVersion::CURRENT`, which sits at or above V1_8.
    assert!(EstateFormatVersion::V1_8 <= EstateFormatVersion::CURRENT);
}

// ---------------------------------------------------------------------------
// G5 idempotent re-run
// ---------------------------------------------------------------------------

#[test]
fn g5_migration_is_idempotent() {
    let (coord, handle, storage) = make_estate();

    // First run: seeds and stamps.
    coord
        .run_fact_extraction_setting_migration(&handle, NOW)
        .expect("first run succeeded");
    // Second run: must not fail and must leave the value unchanged.
    coord
        .run_fact_extraction_setting_migration(&handle, NOW)
        .expect("second run succeeded");

    let after = coord
        .provisioned_preference(&handle, EstatePreferenceKey::FactExtraction)
        .expect("provisioned after second run");
    assert_eq!(after, EstatePreferenceValue::On, "second run must leave value at On");

    let stamp = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read_if_present");
    assert_eq!(stamp, Some(EstateFormatVersion::V1_8), "second run must leave stamp at V1_8");
}

// ---------------------------------------------------------------------------
// G6 accessor unrecognised-value fallback
// ---------------------------------------------------------------------------

#[test]
fn g6_provisioned_preference_returns_on_for_unrecognised_value_garbage() {
    let (coord, handle, _storage) = make_estate();

    // Write "garbage" directly via set_meta, bypassing the typed provisioner,
    // so the accessor's unrecognised-value branch (from_str returns None →
    // unwrap_or_default → On) actually executes.
    coord
        .estate_for(&handle)
        .expect("estate open")
        .set_meta(EstatePreferenceKey::FactExtraction.as_str(), "garbage")
        .expect("set_meta succeeded");

    // The accessor must degrade to On — the fail-quiet fallback.
    let result = coord
        .provisioned_preference(&handle, EstatePreferenceKey::FactExtraction)
        .expect("provisioned_preference");
    assert_eq!(result, EstatePreferenceValue::On, "unrecognised value must fall back to On");
}
