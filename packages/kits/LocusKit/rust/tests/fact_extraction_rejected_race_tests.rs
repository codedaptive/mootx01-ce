//! F3 regression coverage — `DrawerStoreCore::mark_fact_extraction_rejected`
//! used to read the source drawer, check the active recipe, and write the
//! settle bits (FACTS_EXTRACTED | FACTS_REJECTED, bits 28/29) as three
//! SEPARATE, un-transacted storage calls. `runFactExtractionBatch` runs the
//! model call — and this settle write — off the coordinator lock (§
//! DUTY_LIFECYCLE), so a concurrent recipe activation
//! (`FactExtractorModelStore::activate`) could land between the read and the
//! write; the write then OR'd the settle bits into the STALE bitmap captured
//! at the read, silently reverting whatever the interleaved activation
//! changed. The fix wraps the read, the active-recipe check, and the write in
//! one `IsolationLevel::Serializable` transaction — the same pattern
//! `publish_extracted_facts` already used for the identical shape.
//!
//! On the SQLite backend this transaction is a REAL mutual-exclusion
//! boundary: `SqliteStorage::transaction` (and `FactExtractorModelStore::
//! activate`'s own `begin_transaction`) both acquire the SAME connection's
//! `tx_coord`, which blocks a second caller until the first caller's whole
//! bracket closes (see `sqlite.rs`'s `transaction()` doc comment, ISOLATION
//! INVARIANT SV-01). So under the fix, `mark_fact_extraction_rejected` and
//! `activate` can never partially interleave — only ever fully-before or
//! fully-after — which is exactly what removes the race window this finding
//! named.
//!
//! Honest limitation: proving the EXACT "B activated strictly between A's
//! internal read and A's internal write" ordering would need a mid-
//! transaction test hook that does not exist in production code (and adding
//! one is out of scope for an info-severity fix). What this test DOES prove,
//! deterministically and repeatedly under real concurrent threads: (1)
//! neither call ever panics, deadlocks, or returns a corrupted result under
//! contention, and (2) after every round the drawer's settle bits are always
//! in one of the two LEGAL states (both bits set, or both clear) — never a
//! garbled partial OR of a value one call read before the other's write
//! landed, which is the concrete corruption the pre-fix code could produce.

use std::sync::{Arc, Barrier};
use std::thread;

use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::DrawerFeatureFlags;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::fact_extractor_model_store::{FactExtractorModelRow, FactExtractorModelStore};
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::types::{Column, TypedValue};
use std::collections::BTreeMap;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;
const PARENT: &str = "00000000-0000-4000-8000-000000000001";
const DRAWER_ID: &str = "11111111-1111-4111-8111-111111111111";
const CONTENT: &str = "Jack's birthday is June 20th.";

// ---------------------------------------------------------------------------
// Test infrastructure — same TempDb pattern as corrupt_readback_tests.rs
// ---------------------------------------------------------------------------

struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("locus_f3_race_test_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir()
            .join(name)
            .to_string_lossy()
            .into_owned();
        TempDb { path }
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

fn model_row(recipe_id: &str) -> FactExtractorModelRow {
    FactExtractorModelRow {
        recipe_id: recipe_id.into(),
        provider_id: "test-provider".into(),
        model_id: "test-model".into(),
        model_version: "r1".into(),
        schema_version: "kgfact-extraction-v1".into(),
        extractor_kind: "closure".into(),
        maximum_input_characters: 16_384,
        maximum_facts_per_source: 16,
        is_active: false,
    }
}

/// Directly clear bits 28/29 between rounds — a raw test-only write, not a
/// path any production caller takes.
fn reset_settle_bits(store: &SqliteDrawerStore) {
    let storage = store.storage().expect("sqlite storage");
    let mut values = BTreeMap::new();
    // Read-modify-write is fine here: this runs strictly between rounds,
    // never concurrently with the round it is resetting for.
    let current = store
        .get_drawer(DRAWER_ID)
        .expect("get_drawer")
        .expect("drawer exists")
        .operational_bitmap;
    let cleared = current & !(DrawerFeatureFlags::FACTS_EXTRACTED | DrawerFeatureFlags::FACTS_REJECTED);
    values.insert("operationalBitmap".into(), TypedValue::Bitmap(cleared));
    storage
        .row_store()
        .update(
            "drawers",
            values,
            &StoragePredicate::Eq(Column::new("drawers", "id"), TypedValue::Text(DRAWER_ID.into())),
        )
        .expect("reset settle bits");
}

#[test]
fn concurrent_activation_never_corrupts_the_settle_bits() {
    let db = TempDb::new();
    let store = Arc::new(
        SqliteDrawerStore::from_path(&db.path, NOW, None, 5.0)
            .expect("open sqlite estate"),
    );
    let registry = FactExtractorModelStore::new(store.storage().expect("storage"));
    registry.upsert(&model_row("recipe-a")).unwrap();
    registry.upsert(&model_row("recipe-b")).unwrap();
    registry.activate("recipe-a").unwrap();

    let mut drawer = Drawer::new(DRAWER_ID, CONTENT, PARENT, "bilby", NOW, "test-v1");
    drawer.udc_code = "001".into();
    store.add_drawer(&drawer, NOW).unwrap();

    // Real concurrent threads, many rounds. Alternating which recipe starts
    // active so both "A settles while A is active" and "A settles while B
    // just became active" orderings get real chances to occur under genuine
    // OS scheduling, not a single lucky interleaving.
    for round in 0..300 {
        reset_settle_bits(&store);
        let (starting, other) = if round % 2 == 0 {
            ("recipe-a", "recipe-b")
        } else {
            ("recipe-b", "recipe-a")
        };
        registry.activate(starting).unwrap();

        let barrier = Arc::new(Barrier::new(2));

        let settle_store = Arc::clone(&store);
        let settle_barrier = Arc::clone(&barrier);
        let settle_recipe = starting.to_string();
        let settle_handle = thread::spawn(move || {
            settle_barrier.wait();
            settle_store
                .mark_fact_extraction_rejected(DRAWER_ID, CONTENT, &settle_recipe)
        });

        let activate_registry = FactExtractorModelStore::new(store.storage().expect("storage"));
        let activate_barrier = Arc::clone(&barrier);
        let activate_recipe = other.to_string();
        let activate_handle = thread::spawn(move || {
            activate_barrier.wait();
            activate_registry.activate(&activate_recipe)
        });

        let settle_result = settle_handle.join().expect("settle thread must not panic");
        let activate_result = activate_handle.join().expect("activate thread must not panic");

        assert!(settle_result.is_ok(), "mark_fact_extraction_rejected must not error under contention: {settle_result:?}");
        assert!(activate_result.is_ok(), "activate must not error under contention: {activate_result:?}");

        let after = store.get_drawer(DRAWER_ID).unwrap().unwrap();
        let extracted = after.are_facts_extracted();
        let rejected = after.are_facts_rejected();
        assert_eq!(
            extracted, rejected,
            "round {round}: bits 28/29 are written as one unit — {extracted}/{rejected} is a \
             corrupted partial state, exactly the class of bug a stale pre-transaction bitmap \
             read could produce"
        );
    }
}
