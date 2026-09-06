//! The `"encoder"` value of the `embedding_provider` manifest key and its
//! failure contract on the Rust coordinator: the default (nil) resolver and
//! a directory whose vocabulary hashes wrong both leave the estate with no
//! encoder and never panic or error out of `apply_provisioned_embedding_provider`;
//! plus the two companion manifest keys and their defaults.
//!
//! Failure modes: a factory error escaping the apply path, or a malformed
//! `encoder_head` value breaking the read instead of falling back.

use std::path::PathBuf;
use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, ModelDirectoryResolving};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

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
