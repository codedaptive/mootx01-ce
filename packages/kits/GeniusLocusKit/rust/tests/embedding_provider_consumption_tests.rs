// embedding_provider_consumption_tests.rs
//
// Rust conformance tests for the embedding_provider manifest key: the verb
// pair (`provision_embedding_provider` / `provisioned_embedding_provider`), the
// meta-key constant, and the provenance-recording helper
// `apply_provisioned_embedding_provider`.
//
// ## What is under test
//
// The Rust port reads the `embedding_provider` manifest key. For the
// Apple-platform ids it records provenance to stderr (one line per estate
// open) and selects nothing — NaturalLanguage is unavailable on Linux/Windows
// (parity ruling GENIUSLOCUSKIT_INTERFACE §1.53, EMBED-PROV-E2). The
// `"encoder"` value activates the span encoder on both ports; that path is
// covered in encoder_activation_tests.rs.
//
// ## Coverage
//
//   (a) Meta-key constant — `EMBEDDING_PROVIDER_META_KEY == "embedding_provider"`.
//   (b) Absent key — `provisioned_embedding_provider` returns `None` before any
//       write.
//   (c) Round-trip — `provision_embedding_provider("apple-nl-v1")` reads back
//       unchanged.
//   (d) Overwrite — second provision wins.
//   (e) apply with absent key — no panic, no side-effect (early-return path).
//   (f) apply with known key — no panic (records provenance to stderr; we do
//       not capture stderr in tests, so we just verify the call completes).
//   (g) apply with unknown key — no panic (Rust treats all model IDs the same:
//       provenance only, no selection).
//   (h) Empty string round-trip — stores and reads back as Some("").
//       Callers treat "" the same as None.

use std::sync::Arc;

use genius_locus_kit::EstateCoordinator;
use locus_kit::{
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

const NOW: i64 = 1_700_000_000;

/// Open an in-memory estate and return the coordinator + handle pair.
/// Mirrors the `open_one()` helper in `recall_tuning_manifest_tests.rs`.
fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("embed-prov-test"), 0, i64::MAX)
        .expect("open must succeed");
    (coord, handle)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (a) Meta-key constant
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn embedding_provider_meta_key_is_correct_string() {
    // Wire key must match the Swift twin's `embeddingProviderMetaKey` and the
    // manifest table column used in `set_meta` / `meta` calls.
    assert_eq!(
        EstateCoordinator::EMBEDDING_PROVIDER_META_KEY,
        "embedding_provider",
        "meta key must be the bare string 'embedding_provider'"
    );
}

#[test]
fn embedding_provider_meta_key_is_distinct_from_lane_weights_key() {
    // Three optimizer-owned keys must all be distinct manifest rows.
    assert_ne!(
        EstateCoordinator::EMBEDDING_PROVIDER_META_KEY,
        EstateCoordinator::LANE_WEIGHTS_META_KEY,
    );
}

#[test]
fn embedding_provider_meta_key_is_distinct_from_recall_tuning_key() {
    assert_ne!(
        EstateCoordinator::EMBEDDING_PROVIDER_META_KEY,
        EstateCoordinator::RECALL_TUNING_META_KEY,
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (b) Absent key → None
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn absent_embedding_provider_returns_none() {
    let (coord, handle) = open_one();
    let result = coord
        .provisioned_embedding_provider(&handle)
        .expect("provisioned_embedding_provider must not error on absent key");
    // None is the sentinel for "use the deterministic default ensemble."
    assert!(
        result.is_none(),
        "absent key must return None, got {:?}",
        result
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (c) Round-trip
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn provisioned_apple_nl_v1_reads_back_unchanged() {
    let (coord, handle) = open_one();
    coord
        .provision_embedding_provider(&handle, "apple-nl-v1")
        .expect("provision must succeed");
    let result = coord
        .provisioned_embedding_provider(&handle)
        .expect("read-back must not error");
    assert_eq!(
        result,
        Some("apple-nl-v1".to_string()),
        "model_id must survive a manifest round-trip"
    );
}

#[test]
fn arbitrary_model_id_is_preserved_verbatim() {
    // The verb pair is model-ID-agnostic: it stores any String without
    // validation. Consumers (Swift selecter, Rust prover) reject unknown
    // IDs at resolution time, not at write time.
    let (coord, handle) = open_one();
    let model_id = "hypothetical-provider-v99";
    coord
        .provision_embedding_provider(&handle, model_id)
        .expect("provision must succeed for unknown model_id");
    let result = coord
        .provisioned_embedding_provider(&handle)
        .expect("read-back must not error");
    assert_eq!(result, Some(model_id.to_string()));
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (d) Overwrite
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn second_provision_overwrites_first() {
    let (coord, handle) = open_one();
    coord
        .provision_embedding_provider(&handle, "apple-nl-v1")
        .expect("first provision");
    coord
        .provision_embedding_provider(&handle, "hypothetical-provider-v99")
        .expect("second provision");
    let result = coord
        .provisioned_embedding_provider(&handle)
        .expect("read-back");
    assert_eq!(
        result,
        Some("hypothetical-provider-v99".to_string()),
        "second provision must win; got {:?}",
        result
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (e) apply with absent key — no panic
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn apply_with_absent_key_does_not_panic() {
    // No key written → early return path in apply_provisioned_embedding_provider.
    // The function must not panic and must not emit anything meaningful to stderr
    // (though we do not assert on stderr content here).
    let (mut coord, handle) = open_one();
    coord.apply_provisioned_embedding_provider(&handle);
    // Reaching here without panicking is the assertion.
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (f) apply with known key — records provenance, no panic
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn apply_with_apple_nl_key_does_not_panic() {
    // "apple-nl-v1" is the only key the Swift port selects to a concrete provider.
    // Rust records it to stderr and returns. Must complete without panicking.
    let (mut coord, handle) = open_one();
    coord
        .provision_embedding_provider(&handle, "apple-nl-v1")
        .expect("provision");
    // Emits "mootx01 embed-prov: estate … provisioned embedding_provider 'apple-nl-v1' …"
    // to stderr. We do not capture or assert on stderr in unit tests; the provenance
    // line is a diagnostic for log correlation, not a testable side-effect here.
    coord.apply_provisioned_embedding_provider(&handle);
    // Reaching here without panicking confirms the provenance path is alive.
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (g) apply with unknown key — no panic
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn apply_with_unknown_key_does_not_panic() {
    // Rust treats every non-empty model_id as a provenance line — there is no
    // switch statement and no "unknown" branch. Any model_id logs and returns.
    let (mut coord, handle) = open_one();
    coord
        .provision_embedding_provider(&handle, "unknown-provider-v99")
        .expect("provision");
    coord.apply_provisioned_embedding_provider(&handle);
    // No panic — provenance recorded, function returns normally.
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: (h) Empty string round-trip
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn empty_string_round_trip() {
    let (coord, handle) = open_one();
    coord
        .provision_embedding_provider(&handle, "")
        .expect("empty-string provision must not error");
    let result = coord
        .provisioned_embedding_provider(&handle)
        .expect("read-back of empty string must not error");
    // Some("") is acceptable: the key exists but the value is empty.
    // Callers normalise Some("") → absent (deterministic default).
    assert!(
        result == Some(String::new()) || result.is_none(),
        "empty string must read back as Some(\"\") or None, got {:?}",
        result
    );
}

#[test]
fn apply_with_empty_string_does_not_panic() {
    // Empty string is treated as absent by apply_provisioned_embedding_provider
    // (the `model_id.is_empty()` guard fires before the eprintln).
    // Verify that branch also completes without panicking.
    let (mut coord, handle) = open_one();
    coord
        .provision_embedding_provider(&handle, "")
        .expect("provision empty");
    coord.apply_provisioned_embedding_provider(&handle);
    // No panic — empty-string early-return path is alive.
}
