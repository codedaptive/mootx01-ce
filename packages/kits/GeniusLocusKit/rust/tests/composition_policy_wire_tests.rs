//! The GLK wire seam under a stored index composition setting the index rows
//! disagree with: a serving wire (`reindex_pending = false`) refuses the
//! estate with the engine's exact mismatch detail, and a rebuild-committed
//! wire (`reindex_pending = true`) opens it so `reindex_corpus` can rewrite
//! every row under the stored setting. Rust twin of the Swift
//! `DbCompositionCommandExecTests` refusal / rebuild pair at the kit layer.

use std::sync::Arc;

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::coordinator::{
    EstateCoordinator, EstateKind, EstateLifetime, EstateProvisionParams, GeniusLocusKitError,
    SyncMode,
};
use genius_locus_kit::EstateHandle;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;
const CURRENT_ID: &str = "lex=original;dense=distilled";
const OTHER_ID: &str = "lex=originalPlusAdornments;dense=distilled";
/// The detail the engine reports for rows under `CURRENT_ID` opened under
/// `OTHER_ID`: byte-identical across the Swift and Rust ports.
const MISMATCH_DETAIL: &str =
    "recorded=lex=original;dense=distilled;configured=lex=originalPlusAdornments;dense=distilled";

fn owner() -> OwnerCredentials {
    OwnerCredentials::new("owner-composition-wire")
}

fn capture(coord: &EstateCoordinator, handle: &EstateHandle, body: &str) {
    let frame = CaptureFrame::new(
        body,
        CaptureChannel::Typed,
        "composition-wire-tests",
        LatticeAnchor::udc("000"),
        "composition-wire-tests",
        "test-model-v1",
    );
    coord.capture(handle, frame, NOW).expect("capture");
}

/// A GLK estate whose active index rows (the seven default-wing hints plus
/// two captures) were all built under `CURRENT_ID`, returned closed so each
/// wire below reopens it the way a host does, with the indexed row count.
fn estate_indexed_under_current() -> (EstateCoordinator, Arc<dyn DrawerStore>, Arc<dyn Storage>, usize) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap());
    let storage: Arc<dyn Storage> = storage;
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .provision(
            Arc::clone(&store),
            Arc::clone(&storage),
            None,
            owner(),
            EstateProvisionParams {
                estate_name: "composition-wire".to_string(),
                kind: EstateKind::Glk,
                zoom_window_low: 1,
                zoom_window_high: 10,
                framework_profile: "KnowledgeWork".to_string(),
                sync_mode: SyncMode::None,
                lifetime: EstateLifetime::Durable,
            },
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision");
    // Pin the stored setting so the rows below carry CURRENT_ID whatever the
    // creating process's environment seeded, then wire under it and rebuild.
    coord
        .set_index_composition_policy_id(&handle, CURRENT_ID)
        .expect("store the setting");
    coord
        .wire_glk_substores(
            &handle,
            Arc::clone(&storage),
            vec![EmbeddingModelConfig::Deterministic],
            NOW,
            false,
        )
        .expect("wire under the stored setting: no rows yet");
    capture(&coord, &handle, "alpha content under the current policy");
    capture(&coord, &handle, "beta content under the current policy");
    coord.reindex_corpus(&handle, NOW).expect("reindex");
    let counts = coord
        .index_composition_policy_row_counts(&handle)
        .expect("row counts");
    assert_eq!(counts.keys().collect::<Vec<_>>(), vec![CURRENT_ID], "{counts:?}");
    let indexed = counts[CURRENT_ID];
    assert!(indexed >= 2, "{counts:?}");
    coord.close(&handle).expect("close");
    (coord, store, storage, indexed)
}

fn reopen(coord: &mut EstateCoordinator, store: &Arc<dyn DrawerStore>) -> EstateHandle {
    coord
        .open(Arc::clone(store), owner(), 1, 10)
        .expect("reopen")
}

#[test]
fn a_serving_wire_refuses_rows_built_under_another_policy() {
    let (mut coord, store, storage, _indexed) = estate_indexed_under_current();
    let handle = reopen(&mut coord, &store);
    coord
        .set_index_composition_policy_id(&handle, OTHER_ID)
        .expect("flip the stored setting without a rebuild");
    let err = coord
        .wire_glk_substores(
            &handle,
            Arc::clone(&storage),
            vec![EmbeddingModelConfig::Deterministic],
            NOW,
            false,
        )
        .err()
        .expect("a serving wire must refuse");
    match err {
        GeniusLocusKitError::UnderlyingEstateFailure { reason } => {
            assert_eq!(
                reason,
                format!("engine open failed for Glk estate: CompositionPolicyMismatch({MISMATCH_DETAIL:?})")
            );
        }
        other => panic!("expected UnderlyingEstateFailure, got {other:?}"),
    }
    // The refused estate stays open at the LocusKit layer with no Corpus.
    assert!(!coord.has_corpus(&handle));
}

#[test]
fn a_rebuild_committed_wire_opens_and_the_rebuild_moves_every_row() {
    let (mut coord, store, storage, indexed) = estate_indexed_under_current();
    let handle = reopen(&mut coord, &store);
    coord
        .set_index_composition_policy_id(&handle, OTHER_ID)
        .expect("flip the stored setting");
    coord
        .wire_glk_substores(
            &handle,
            Arc::clone(&storage),
            vec![EmbeddingModelConfig::Deterministic],
            NOW,
            true,
        )
        .expect("rebuild-committed wire opens the mismatched estate");
    assert_eq!(
        coord.index_composition_policy(&handle).map(|p| p.id()),
        Some(OTHER_ID.to_string())
    );
    coord.reindex_corpus(&handle, NOW + 1).expect("reindex");
    let counts = coord
        .index_composition_policy_row_counts(&handle)
        .expect("row counts");
    assert_eq!(counts.keys().collect::<Vec<_>>(), vec![OTHER_ID], "{counts:?}");
    assert_eq!(counts[OTHER_ID], indexed);
    // With every row under the stored setting, a serving wire succeeds again.
    coord.close(&handle).expect("close");
    let handle = reopen(&mut coord, &store);
    coord
        .wire_glk_substores(
            &handle,
            Arc::clone(&storage),
            vec![EmbeddingModelConfig::Deterministic],
            NOW,
            false,
        )
        .expect("serving wire after the rebuild");
    assert!(coord.has_corpus(&handle));
}

#[test]
fn a_locus_only_wire_registers_nothing() {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap());
    let storage: Arc<dyn Storage> = storage;
    let mut coord = EstateCoordinator::new();
    let handle = coord.open(store, owner(), 1, 10).expect("open");
    coord
        .wire_substores(
            &handle,
            EstateKind::LocusOnly,
            storage,
            vec![EmbeddingModelConfig::Deterministic],
            NOW,
            false,
        )
        .expect("locus-only wire");
    assert!(!coord.has_corpus(&handle));
    assert!(!coord.has_vector_store(&handle));
}
