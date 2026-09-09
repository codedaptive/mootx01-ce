//! The `"encoder"` value of the `embedding_provider` manifest key and its
//! failure contract on the Rust coordinator: the default (nil) resolver and
//! a directory whose vocabulary hashes wrong both leave the estate with no
//! encoder and never panic or error out of `apply_provisioned_embedding_provider`;
//! plus the two companion manifest keys and their defaults.
//!
//! Failure modes: a factory error escaping the apply path, or a malformed
//! `encoder_head` value breaking the read instead of falling back.
//!
//! The seeding tests (`encoder_activation_seeds_the_default_encoder_row` and
//! `wire_glk_substores_seeds_through_the_open_path`) verify Bob's ruling
//! 2026-09-04: upgrade never creates content; seeding belongs to provision and
//! serve. `activate_span_encoder` seeds the bundled row before reading the
//! registry so an estate is encoder-active from its first open. Twin of
//! Swift `EncoderActivationTests.provisionSeedsTheActiveEncoderRowAndActivatesUnderIt`
//! and `serveOpenPathSeedsThroughWireGLKSubstores`.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, ModelDirectoryResolving};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};
use persistence_kit::{storage::Storage, TypedValue};

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("encoder-act-test"), 0, i64::MAX)
        .expect("open must succeed");
    (coord, handle)
}

/// Resolver that points every model id at one fixed directory.
struct FixedDirectoryResolver(PathBuf);

impl ModelDirectoryResolving for FixedDirectoryResolver {
    fn model_dir_for(&self, _model_id: &str) -> Option<PathBuf> {
        Some(self.0.clone())
    }
}

#[test]
fn wire_strings_and_defaults() {
    assert_eq!(EstateCoordinator::ENCODER_PROVIDER_ID, "encoder");
    assert_eq!(EstateCoordinator::ENCODER_HEAD_META_KEY, "encoder_head");
    assert_eq!(EstateCoordinator::ENCODER_BATCH_META_KEY, "encoder_batch");
    assert_ne!(
        EstateCoordinator::ENCODER_HEAD_META_KEY,
        EstateCoordinator::EMBEDDING_PROVIDER_META_KEY
    );
    assert_eq!(EstateCoordinator::DEFAULT_ENCODER_HEAD, 30);
    assert_eq!(EstateCoordinator::DEFAULT_ENCODER_BATCH, 64);
}

#[test]
fn encoder_without_model_directory_registers_nothing_and_does_not_panic() {
    let (mut coord, handle) = open_one();
    coord
        .provision_embedding_provider(&handle, EstateCoordinator::ENCODER_PROVIDER_ID)
        .expect("provision");
    // Default resolver → no directory → one stderr line, no encoder.
    coord.apply_provisioned_embedding_provider(&handle);
    assert!(coord.registered_span_encoder(&handle).is_none());
}

#[test]
fn encoder_with_wrong_vocab_directory_registers_nothing_and_does_not_panic() {
    let dir = std::env::temp_dir().join(format!("glk-encoder-act-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("vocab.txt"), b"[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n").unwrap();

    let (mut coord, handle) = open_one();
    coord.set_model_directory_resolver(Box::new(FixedDirectoryResolver(dir.clone())));
    coord
        .provision_embedding_provider(&handle, EstateCoordinator::ENCODER_PROVIDER_ID)
        .expect("provision");
    // Resolver answers; the factory reports TokenizerMismatch; the
    // coordinator swallows it (one stderr line).
    coord.apply_provisioned_embedding_provider(&handle);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(coord.registered_span_encoder(&handle).is_none());
}

#[test]
fn encoder_head_and_batch_round_trip_with_defaults_on_malformed_values() {
    let (coord, handle) = open_one();
    assert_eq!(coord.provisioned_encoder_head(&handle), EstateCoordinator::DEFAULT_ENCODER_HEAD);
    assert_eq!(coord.provisioned_encoder_batch(&handle), EstateCoordinator::DEFAULT_ENCODER_BATCH);

    coord.provision_encoder_head(&handle, 45).expect("head");
    coord.provision_encoder_batch(&handle, 8).expect("batch");
    assert_eq!(coord.provisioned_encoder_head(&handle), 45);
    assert_eq!(coord.provisioned_encoder_batch(&handle), 8);

    // Malformed / non-positive values never break a read: default.
    let estate = coord.estate_for(&handle).expect("estate");
    estate.set_meta(EstateCoordinator::ENCODER_HEAD_META_KEY, "thirty").unwrap();
    estate.set_meta(EstateCoordinator::ENCODER_BATCH_META_KEY, "0").unwrap();
    assert_eq!(coord.provisioned_encoder_head(&handle), EstateCoordinator::DEFAULT_ENCODER_HEAD);
    assert_eq!(coord.provisioned_encoder_batch(&handle), EstateCoordinator::DEFAULT_ENCODER_BATCH);
}

#[test]
fn close_drops_the_span_encoder_registration_slot() {
    // No encoder can load here, so this pins the close path indirectly: a
    // closed handle answers None and does not panic.
    let (mut coord, handle) = open_one();
    coord.close(&handle).expect("close");
    assert!(coord.registered_span_encoder(&handle).is_none());
}

/// `provision_default_encoder_if_absent` writes `"encoder"` only when the
/// estate names no provider, and never overwrites a named one. Swift twin:
/// EncoderActivationTests.provisionDefaultEncoder.
#[test]
fn default_encoder_provisioning_writes_once_and_never_overwrites() {
    let (coord, handle) = open_one();
    assert_eq!(coord.provisioned_embedding_provider(&handle).unwrap(), None);
    assert!(coord.provision_default_encoder_if_absent(&handle).unwrap());
    assert_eq!(
        coord.provisioned_embedding_provider(&handle).unwrap().as_deref(),
        Some(EstateCoordinator::ENCODER_PROVIDER_ID)
    );
    // Idempotent: a second call writes nothing.
    assert!(!coord.provision_default_encoder_if_absent(&handle).unwrap());
    // A named provider is never overwritten.
    coord.provision_embedding_provider(&handle, "apple-nl-v1").unwrap();
    assert!(!coord.provision_default_encoder_if_absent(&handle).unwrap());
    assert_eq!(
        coord.provisioned_embedding_provider(&handle).unwrap().as_deref(),
        Some("apple-nl-v1")
    );
    // A cleared key is absent again and the default returns.
    coord.provision_embedding_provider(&handle, "").unwrap();
    assert!(coord.provision_default_encoder_if_absent(&handle).unwrap());
    assert_eq!(
        coord.provisioned_embedding_provider(&handle).unwrap().as_deref(),
        Some(EstateCoordinator::ENCODER_PROVIDER_ID)
    );
}

// ─── Seeding tests (Part B, ruling 2026-09-04) ────────────────────────────────

/// Records every model ID the resolver is queried for; returns None so no
/// encoder loads. Shared via Arc so the test can inspect captured calls after
/// the coordinator owns the Box<dyn ModelDirectoryResolving>.
struct SpyResolver(std::sync::Arc<std::sync::Mutex<Vec<String>>>);

impl ModelDirectoryResolving for SpyResolver {
    fn model_dir_for(&self, model_id: &str) -> Option<PathBuf> {
        self.0.lock().unwrap().push(model_id.to_string());
        None
    }
}

/// Returns the coordinator, handle, AND the DrawerStore Arc so tests can
/// reach the estate's underlying storage for encoder_model_store reads.
fn open_one_with_store() -> (EstateCoordinator, genius_locus_kit::EstateHandle, Arc<dyn DrawerStore>) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let store_ref = Arc::clone(&store);
    let handle = coord
        .open(store, OwnerCredentials::new("encoder-seed-test"), 0, i64::MAX)
        .expect("open must succeed");
    (coord, handle, store_ref)
}

/// `activate_span_encoder` seeds the bundled encoder row before reading the
/// registry when no active row exists, so an estate provisioned with the
/// encoder key is encoder-active from its first open. The resolver spy
/// confirms the seeded MODEL_ID was read, not the floor model.
///
/// Twin of Swift `EncoderActivationTests.provisionSeedsTheActiveEncoderRowAndActivatesUnderIt`.
#[test]
fn encoder_activation_seeds_the_default_encoder_row() {
    use corpus_kit_providers::EncoderModelSeed;
    use locus_kit::encoder_model_store::EncoderModelStore;

    let spy_calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let (mut coord, handle, store) = open_one_with_store();
    coord.set_model_directory_resolver(Box::new(SpyResolver(std::sync::Arc::clone(&spy_calls))));
    coord
        .provision_embedding_provider(&handle, EstateCoordinator::ENCODER_PROVIDER_ID)
        .expect("provision");

    // Activation seeds first: after this call the active row must exist.
    coord.apply_provisioned_embedding_provider(&handle);

    let storage = store.storage().expect("InMemoryDrawerStore must expose its storage");
    let registry = EncoderModelStore::new(storage);
    let row = registry
        .active()
        .expect("active() must not fail")
        .expect("active row must exist after activation seeds it");
    assert_eq!(row.model_id, EncoderModelSeed::MODEL_ID);
    assert!(row.is_active);
    // The resolver saw MODEL_ID, proving activation read the seeded row and
    // not the floor model (minilm-l6-v2-w60).
    let seen = spy_calls.lock().unwrap();
    assert_eq!(seen.as_slice(), &[EncoderModelSeed::MODEL_ID]);
    drop(seen);
    // No model directory in tests: encoder and rerank stage are not registered.
    assert!(coord.registered_span_encoder(&handle).is_none());
    assert!(!coord.is_span_rerank_registered(&handle));
    // seed_default_encoder_model_if_absent is idempotent.
    let again = coord
        .seed_default_encoder_model_if_absent(&handle)
        .expect("seed must not fail");
    assert!(!again, "seed must be idempotent when a row already exists");
    assert_eq!(registry.all().expect("all() must not fail").len(), 1);
}

/// `wire_glk_substores` seeds the active encoder row through
/// `activate_span_encoder`, so the serve-open path activates the encoder from
/// the first open of a provisioned estate.
///
/// Twin of Swift `EncoderActivationTests.serveOpenPathSeedsThroughWireGLKSubstores`.
#[test]
fn wire_glk_substores_seeds_through_the_open_path() {
    use corpus_kit_providers::{default_ensemble, EncoderModelSeed};
    use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::encoder_model_store::EncoderModelStore;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    let (mut coord, handle, store) = open_one_with_store();
    coord.provision_default_encoder_if_absent(&handle).expect("provision encoder key");

    let storage = store.storage().expect("storage must be accessible");
    let registry = EncoderModelStore::new(Arc::clone(&storage));
    // Pre-wire: no active row; seeding happens inside activate_span_encoder.
    assert!(
        registry.active().expect("active() must not fail").is_none(),
        "no row before wire_glk_substores"
    );

    // A fresh InMemoryStorage stamped at the current estate format, mirroring
    // wire_inmemory_semantic_recall in AriaMcpKit/rust/src/estate_registry.rs.
    let backing: Arc<dyn persistence_kit::storage::Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    EstateFormatStore::new(Arc::clone(&backing))
        .stamp(EstateFormatVersion::CURRENT, NOW)
        .expect("format stamp must succeed");

    coord
        .wire_glk_substores(&handle, backing, default_ensemble(), NOW)
        .expect("wire_glk_substores must succeed");

    // Post-wire: the active row must be seeded with MODEL_ID.
    let row = registry
        .active()
        .expect("active() must not fail")
        .expect("active row must be seeded by wire_glk_substores");
    assert_eq!(row.model_id, EncoderModelSeed::MODEL_ID);

    // Span rows are empty until the span-encode signal runs.
    let frame = CaptureFrame::new(
        "hello world",
        CaptureChannel::Typed,
        "inbox",
        LatticeAnchor::udc("0"),
        "test",
        EncoderModelSeed::MODEL_ID,
    );
    let drawer = coord.capture(&handle, frame, NOW).expect("capture must succeed");
    let span_rows = coord
        .vector_store_for(&handle)
        .expect("vector store must be registered after wire_glk_substores")
        .span_vectors(&[drawer.id.as_str()], EncoderModelSeed::MODEL_ID)
        .expect("span_vectors must not fail");
    assert!(span_rows.is_empty(), "span rows are empty until the signal drains them");
}

fn rows(storage: &Arc<dyn Storage>, table: &str) -> Vec<BTreeMap<String, TypedValue>> {
    storage.row_store().query(table, None, &[], None, None)
        .unwrap_or_else(|error| panic!("read {table}: {error:?}"))
        .into_iter()
        .map(|row| row.values)
        .collect()
}

#[test]
fn readonly_glk_wiring_preserves_stale_receipts_and_keeps_query_tiers() {
    use corpus_kit_providers::default_ensemble;
    use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    let (mut coord, handle, _drawer) = open_one_with_store();
    let backing: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    EstateFormatStore::new(Arc::clone(&backing))
        .stamp(EstateFormatVersion::CURRENT, NOW)
        .expect("current format");
    coord.wire_glk_substores(&handle, Arc::clone(&backing), default_ensemble(), NOW)
        .expect("live preparation");

    let mut configuration = BTreeMap::new();
    configuration.insert("singleton_id".to_string(), TypedValue::Int(1));
    configuration.insert("generation_token".to_string(), TypedValue::Text("stale-ri-fingerprint".to_string()));
    configuration.insert("updated_at".to_string(), TypedValue::Timestamp(17));
    backing.row_store().upsert("corpus_provider_configuration", configuration, &["singleton_id".to_string()])
        .expect("stale configuration");
    for mut claim in rows(&backing, "vector_rep_claims") {
        claim.insert("claimed_at".to_string(), TypedValue::Timestamp(19));
        backing.row_store().upsert("vector_rep_claims", claim, &[
            "model_id".to_string(), "model_version".to_string(),
            "vector_index".to_string(), "consumer".to_string(),
        ]).expect("stale claim");
    }
    let expected_configuration = rows(&backing, "corpus_provider_configuration");
    let expected_claims = rows(&backing, "vector_rep_claims");
    assert!(!expected_claims.is_empty(), "live preparation must create vector claims");

    coord.wire_glk_substores_readonly(&handle, Arc::clone(&backing), default_ensemble(), NOW + 1_000)
        .expect("read-preserving wire");
    assert!(coord.has_corpus(&handle), "readonly wire keeps the corpus query tier");
    assert!(coord.has_vector_store(&handle), "readonly wire keeps the vector/strict source tier");
    assert_eq!(rows(&backing, "corpus_provider_configuration"), expected_configuration,
        "readonly wire must not reconcile a stale provider receipt");
    assert_eq!(rows(&backing, "vector_rep_claims"), expected_claims,
        "readonly wire must not refresh claim timestamps");
}

/// When a real Arctic CoreML model directory is available, the rerank stage is
/// registered after activation seeds and activates the encoder.
///
/// Requires `MOOT_ENCODER_MODEL_DIR` set to a directory containing the Arctic
/// vocab file and weights. Run with `--features encoder` to compile the
/// model-loading path.
///
/// The estate must be wired through `wire_glk_substores` so the VectorStore
/// is registered before `apply_provisioned_embedding_provider` runs.
/// `activate_span_encoder` only registers the rerank stage when a VectorStore
/// is present — without the wire step the assertion would always fail even
/// when the real model loads. Mirrors Swift `kit.provision()`.
#[test]
#[ignore = "needs MOOT_ENCODER_MODEL_DIR and --features encoder"]
fn real_model_registers_the_rerank_stage() {
    use corpus_kit_providers::default_ensemble;
    use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    let dir = std::env::var("MOOT_ENCODER_MODEL_DIR")
        .expect("MOOT_ENCODER_MODEL_DIR must point at the Arctic model directory");
    let (mut coord, handle, _store) = open_one_with_store();
    coord.set_model_directory_resolver(Box::new(FixedDirectoryResolver(PathBuf::from(&dir))));
    coord
        .provision_embedding_provider(&handle, EstateCoordinator::ENCODER_PROVIDER_ID)
        .expect("provision");
    // Wire GLK substores so the VectorStore is registered before
    // apply_provisioned_embedding_provider runs (called inside wire_glk_substores).
    // A fresh InMemoryStorage stamped at the current estate format mirrors the
    // wire_inmemory_semantic_recall pattern in AriaMcpKit/rust/src/estate_registry.rs.
    let backing: Arc<dyn persistence_kit::storage::Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    EstateFormatStore::new(Arc::clone(&backing))
        .stamp(EstateFormatVersion::CURRENT, NOW)
        .expect("format stamp must succeed");
    coord
        .wire_glk_substores(&handle, backing, default_ensemble(), NOW)
        .expect("wire_glk_substores must succeed");
    assert!(
        coord.is_span_rerank_registered(&handle),
        "rerank stage must be registered when a real model directory is provided"
    );
}
