//! Gate tests for the GLK 1.8 → 1.9 preference-seed migration capsule.
//! Rust twin of Swift `PreferenceSeedMigrationTests.swift`.
//!
//! Two gates: a 1.8 estate gains the five seeded preference keys and the
//! recall_ratings table and is stamped V1_9; an existing "off" survives.

use std::sync::Arc;

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::estate_preference::{EstatePreferenceKey, EstatePreferenceValue};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit_migrations::{preference_seed_keys, PreferenceSeedMigrationExt};
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
    // Stamp V1_8 so the chain considers the estate historical and below current.
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(EstateFormatVersion::V1_8, NOW)
        .expect("stamp V1_8");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig19-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");
    (coord, handle, storage)
}

// ---------------------------------------------------------------------------
// G1 a 1.8 estate gains five keys, the table and the V1_9 stamp
// ---------------------------------------------------------------------------

#[test]
fn g1_migration_seeds_five_preferences_creates_table_and_stamps_v1_9() {
    let (coord, handle, storage) = make_estate();

    let keys = preference_seed_keys();
    assert_eq!(keys.len(), 5);
    assert!(!keys.contains(&EstatePreferenceKey::FactExtraction));
    for key in &keys {
        let raw_before = coord
            .estate_for(&handle)
            .expect("estate open")
            .meta(key.as_str())
            .expect("meta read");
        assert!(raw_before.is_none(), "{} must be absent before migration", key.as_str());
    }
    assert_eq!(
        storage.current_schema_version_for("GLKRecallRatings").expect("ledger read"),
        0,
        "recall_ratings must not exist before migration"
    );

    coord
        .run_preference_seed_migration(&handle, NOW)
        .expect("capsule succeeded");

    for key in &keys {
        let raw_after = coord
            .estate_for(&handle)
            .expect("estate open")
            .meta(key.as_str())
            .expect("meta read");
        assert_eq!(raw_after.as_deref(), Some("on"), "migration seeded {} = on", key.as_str());
        let after = coord
            .provisioned_preference(&handle, *key)
            .expect("provisioned_preference after migration");
        assert_eq!(after, EstatePreferenceValue::On);
    }
    assert_eq!(
        storage.current_schema_version_for("GLKRecallRatings").expect("ledger read"),
        1,
        "recall_ratings ladder must record version 1"
    );
    assert_eq!(
        storage.row_store().count("recall_ratings", None).expect("count"),
        0,
        "recall_ratings is created empty"
    );
    let stamp = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read_if_present");
    assert_eq!(stamp, Some(EstateFormatVersion::V1_9), "capsule must stamp V1_9");
    assert_eq!(EstateFormatVersion::CURRENT, EstateFormatVersion::V1_9);
}

// ---------------------------------------------------------------------------
// G2 an existing "off" survives
// ---------------------------------------------------------------------------

#[test]
fn g2_migration_preserves_explicit_off() {
    let (coord, handle, storage) = make_estate();

    // Pre-write Off for one seeded key through the public provisioner.
    coord
        .provision_preference(&handle, EstatePreferenceKey::Maintenance, EstatePreferenceValue::Off)
        .expect("provision Off");

    coord
        .run_preference_seed_migration(&handle, NOW)
        .expect("capsule succeeded");

    // The pre-set key keeps Off; the other four are seeded On.
    let after = coord
        .provisioned_preference(&handle, EstatePreferenceKey::Maintenance)
        .expect("provisioned after migration");
    assert_eq!(after, EstatePreferenceValue::Off, "capsule must not overwrite Off");
    let raw = coord
        .estate_for(&handle)
        .expect("estate open")
        .meta(EstatePreferenceKey::Maintenance.as_str())
        .expect("meta read");
    assert_eq!(raw.as_deref(), Some("off"));
    for key in preference_seed_keys()
        .into_iter()
        .filter(|key| *key != EstatePreferenceKey::Maintenance)
    {
        let value = coord
            .provisioned_preference(&handle, key)
            .expect("provisioned after migration");
        assert_eq!(value, EstatePreferenceValue::On);
    }
    let stamp = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read_if_present");
    assert_eq!(stamp, Some(EstateFormatVersion::V1_9), "capsule stamps V1_9 even when a value is pre-set");
}
