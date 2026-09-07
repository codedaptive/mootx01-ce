//! Verifies that a freshly wired in-memory estate carries an active
//! `encoder_models` row seeded at open, following Bob's ruling 2026-09-04:
//! upgrade never creates content; seeding belongs to provision and serve.
//! `EstateRegistry::new_inmemory` wires the estate through
//! `wire_glk_substores`, which calls `activate_span_encoder`, which now seeds
//! the row before reading the registry.

use aria_mcp::estate_registry::EstateRegistry;
use corpus_kit_providers::EncoderModelSeed;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::encoder_model_store::EncoderModelStore;

/// A freshly constructed in-memory registry carries an active encoder row
/// seeded by the open path. The rerank stage is not registered because no
/// model directory is available in tests.
#[test]
fn inmemory_estate_has_active_encoder_row_at_open() {
    let reg = EstateRegistry::new_inmemory();

    // Reach the encoder_models table through the same storage the DrawerStore
    // was opened on (the LocusKit tables, which include encoder_models).
    let storage = reg
        .default
        .store
        .storage()
        .expect("InMemoryDrawerStore must expose its storage");
    let registry = EncoderModelStore::new(storage);

    let row = registry
        .active()
        .expect("active() must not fail")
        .expect("active encoder row must be seeded at open");
    assert_eq!(
        row.model_id,
        EncoderModelSeed::MODEL_ID,
        "seeded row must carry the bundled model ID"
    );
    assert!(row.is_active, "seeded row must be active");

    // No model directory in the test environment: the rerank stage is not
    // registered even though the row exists.
    assert!(
        !reg.coord
            .lock()
            .unwrap()
            .is_span_rerank_registered(&reg.default.handle),
        "rerank stage must not be registered without a model directory"
    );
}
