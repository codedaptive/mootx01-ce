//! Verification fixture for the GLK 1.3 → 1.4 index-composition-setting
//! migration. Rust twin of Swift `IndexCompositionSettingMigrationTests.swift`.
//!
//! Tests:
//!   1. v1_3-stamped estate without the setting: after the capsule the
//!      setting reads `current()` (no MOOT_INDEX_COMPOSITION) and the estate
//!      is stamped V1_4.
//!   2. Idempotence: a second run leaves the stamp at V1_4 and the setting
//!      untouched.
//!   3. A stored setting survives the capsule (cell B stays cell B).
//!   4. MOOT_INDEX_COMPOSITION set to a valid id at upgrade time seeds that
//!      id; an invalid value seeds `current()`. Both cases share one test so
//!      the environment mutation never races another test.
//!   5. StorageUnavailable: an unregistered handle returns the error variant.
//!   6. Full chain from v1_0 through the compiled catalog ends at V1_4 with
//!      the setting stored. (Gated on feature = "migration-v1-0-to-v1-1".)

use std::sync::Arc;

use corpus_kit::index_composition_policy::IndexCompositionPolicy;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    IndexCompositionSettingMigrationError, IndexCompositionSettingMigrationExt,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::Storage;

const NOW: i64 = 1_756_000_000_000; // millis

/// Open an in-memory estate stamped at `stamp_version` with no index
/// composition setting.
fn make_estate(
    stamp_version: EstateFormatVersion,
) -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Arc<dyn Storage>,
) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(stamp_version, NOW)
        .expect("stamp estate format");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig14-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");
    (coord, handle, storage)
}

fn read_stamp(storage: &Arc<dyn Storage>) -> EstateFormatVersion {
    EstateFormatStore::new(Arc::clone(storage))
        .read_if_present()
        .expect("read format version")
        .expect("version must be set")
}

/// Run `body` with MOOT_INDEX_COMPOSITION set to `value` (removed when None)
/// and restore the previous value afterwards. The process environment is
/// shared by every test thread, so the seed window is serialized through
/// one lock; a poisoned lock (a failed test) is recovered rather than
/// cascading into every later test.
fn with_creation_seed<T>(value: Option<&str>, body: impl FnOnce() -> T) -> T {
    static SEED_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _serialized = SEED_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let key = EstateCoordinator::INDEX_COMPOSITION_POLICY_ENV_KEY;
    let previous = std::env::var(key).ok();
    match value {
        Some(v) => std::env::set_var(key, v),
        None => std::env::remove_var(key),
    }
    let out = body();
    match previous {
        Some(p) => std::env::set_var(key, p),
        None => std::env::remove_var(key),
    }
    out
}

// ---------------------------------------------------------------------------
// §1 Core: v1_3-stamped estate gains the stored setting and stamps V1_4
// ---------------------------------------------------------------------------

#[test]
fn v1_3_estate_gains_stored_setting_and_stamps_v1_4() {
    with_creation_seed(None, || {
        let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_3);
        assert_eq!(coord.stored_index_composition_policy(&handle).expect("read"), None);

        let policy = coord
            .run_index_composition_setting_migration(&handle, NOW)
            .expect("migration must succeed on v1_3 estate");

        assert_eq!(policy, IndexCompositionPolicy::current());
        assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_4);
        assert_eq!(read_stamp(&storage), EstateFormatVersion::CURRENT);
        assert_eq!(
            coord.stored_index_composition_policy(&handle).expect("read"),
            Some(IndexCompositionPolicy::current())
        );
        // The row is the policy id, verbatim.
        let estate = coord.estate_for(&handle).expect("estate");
        assert_eq!(
            estate
                .meta(EstateCoordinator::index_composition_policy_meta_key())
                .expect("meta"),
            Some(IndexCompositionPolicy::current().id())
        );
    });
}

// ---------------------------------------------------------------------------
// §2 Idempotence
// ---------------------------------------------------------------------------

#[test]
fn capsule_is_idempotent() {
    with_creation_seed(None, || {
        let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_3);
        coord
            .run_index_composition_setting_migration(&handle, NOW)
            .expect("first call must succeed");
        coord
            .run_index_composition_setting_migration(&handle, NOW)
            .expect("second call must be idempotent");
        assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_4);
        assert_eq!(
            coord.stored_index_composition_policy(&handle).expect("read"),
            Some(IndexCompositionPolicy::current())
        );
    });
}

// ---------------------------------------------------------------------------
// §3 A stored setting survives the capsule
// ---------------------------------------------------------------------------

#[test]
fn stored_setting_is_left_untouched() {
    with_creation_seed(Some(&IndexCompositionPolicy::lexical_baseline().id()), || {
        let (coord, handle, _) = make_estate(EstateFormatVersion::V1_3);
        coord
            .set_index_composition_policy(&handle, IndexCompositionPolicy::lexical_adornments())
            .expect("set");
        coord
            .run_index_composition_setting_migration(&handle, NOW)
            .expect("migration");
        assert_eq!(
            coord.stored_index_composition_policy(&handle).expect("read"),
            Some(IndexCompositionPolicy::lexical_adornments())
        );
    });
}

// ---------------------------------------------------------------------------
// §4 The creation seed at upgrade time
// ---------------------------------------------------------------------------

#[test]
fn environment_seeds_the_setting_at_upgrade_time() {
    with_creation_seed(Some(&IndexCompositionPolicy::both_adornments().id()), || {
        let (coord, handle, _) = make_estate(EstateFormatVersion::V1_3);
        coord
            .run_index_composition_setting_migration(&handle, NOW)
            .expect("migration");
        assert_eq!(
            coord.stored_index_composition_policy(&handle).expect("read"),
            Some(IndexCompositionPolicy::both_adornments())
        );
    });
    with_creation_seed(Some("lex=nonsense;dense=distilled"), || {
        let (coord, handle, _) = make_estate(EstateFormatVersion::V1_3);
        coord
            .run_index_composition_setting_migration(&handle, NOW)
            .expect("migration");
        assert_eq!(
            coord.stored_index_composition_policy(&handle).expect("read"),
            Some(IndexCompositionPolicy::current())
        );
    });
}

// ---------------------------------------------------------------------------
// §5 StorageUnavailable
// ---------------------------------------------------------------------------

#[test]
fn unregistered_handle_returns_storage_unavailable() {
    let coord = EstateCoordinator::new();
    let store = InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new");
    let mut staging = EstateCoordinator::new();
    let unregistered_handle = staging
        .open(
            Arc::new(store),
            OwnerCredentials::new("unregistered-owner"),
            0,
            100,
        )
        .expect("open in staging coord");
    let result = coord.run_index_composition_setting_migration(&unregistered_handle, NOW);
    assert!(
        matches!(result, Err(IndexCompositionSettingMigrationError::StorageUnavailable { .. })),
        "expected StorageUnavailable, got {result:?}"
    );
}

// ---------------------------------------------------------------------------
// §6 Full chain from v1_0 (only when migration-floor-1-0 is enabled)
// ---------------------------------------------------------------------------

#[cfg(feature = "migration-v1-0-to-v1-1")]
#[test]
fn v1_0_estate_runs_full_chain_to_v1_4() {
    use corpus_kit_providers::default_ensemble;
    use genius_locus_kit_migrations::{compiled_floor, MigrationChainExt};

    with_creation_seed(None, || {
        let (mut coord, handle, storage) = make_estate(EstateFormatVersion::V1_0);
        assert_eq!(compiled_floor(), Some(EstateFormatVersion::V1_0));
        coord
            .run_migration_chain(&handle, NOW, default_ensemble())
            .expect("full chain must succeed on an empty v1_0 estate");
        assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_4, "full chain must end at V1_4");
        assert_eq!(
            coord.stored_index_composition_policy(&handle).expect("read"),
            Some(IndexCompositionPolicy::current())
        );
    });
}
