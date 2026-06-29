//! Precondition guard tests for the int8 payload rejection policy.
//!
//! Bob's ruling 2026-06-13 (Codex review item 5): int8 writes are rejected
//! fail-closed until a quantization policy is ratified. The `Int8` variant and
//! its `scale` field are retained in `VectorPayload` (no-removal doctrine) but
//! `VectorStore::add_payload` and `add_payloads` return
//! `VectorKitError::Int8QuantizationPolicyUndefined` on any int8 payload.
//!
//! The read side: `decode_payload` is documented to return an error for int8
//! rows. Because the write path now blocks int8 rows from ever reaching the
//! store, the read-side guard cannot be directly exercised through the public
//! API in these integration tests (no row to decode). The `decode_payload`
//! unit coverage lives in the crate's internal tests in payload.rs.
//!
//! These tests change NO current behavior: there are zero existing int8
//! producers. They are precondition guards for a latent trap.

use std::sync::Arc;
use vectorkit::{VectorKind, VectorPayload, VectorKitError, VectorPayloadInput, VectorStore};
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use uuid::Uuid;

// ── helpers ──────────────────────────────────────────────────────────────────

fn open_store() -> VectorStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    VectorStore::open(storage).expect("schema open must succeed")
}

fn int8_payload(dim: usize) -> VectorPayload {
    // Construct a minimal int8 payload. The quantization policy is
    // unspecified — this is precisely what the guard must reject.
    VectorPayload {
        kind: VectorKind::Int8,
        dim: dim as u32,
        bytes: vec![1u8; dim],
        scale: Some(0.5_f32),
    }
}

fn is_int8_policy_error(e: &VectorKitError) -> bool {
    matches!(e, VectorKitError::Int8QuantizationPolicyUndefined(_))
}

// ── write-path rejection: add_payload ────────────────────────────────────────

/// `add_payload` with an int8 payload must return
/// `Int8QuantizationPolicyUndefined`. No row must be written.
#[test]
fn add_payload_int8_returns_rejection_error() {
    let store = open_store();
    let payload = int8_payload(4);

    let result = store.add_payload(
        "item-int8-test",
        0,
        &payload,
        "test-model",
        "1.0",
        1_700_000_000,
    );

    assert!(result.is_err(), "int8 add_payload must return Err");
    let err = result.unwrap_err();
    assert!(
        is_int8_policy_error(&err),
        "error must be Int8QuantizationPolicyUndefined, got: {:?}",
        err
    );

    // No row must have been written.
    let rows = store
        .vectors_for_item("item-int8-test")
        .expect("vectors_for_item must succeed on empty store");
    assert!(rows.is_empty(), "no row must be persisted when int8 is rejected");
}

/// The error message must state the reason and the remedy.
#[test]
fn add_payload_int8_error_message_is_informative() {
    let store = open_store();
    let payload = int8_payload(4);

    let result = store.add_payload("x", 0, &payload, "m", "1.0", 0);
    let err = result.expect_err("must err");

    if let VectorKitError::Int8QuantizationPolicyUndefined(msg) = err {
        assert!(
            msg.to_lowercase().contains("quantization"),
            "error message must mention quantization. Got: {msg}"
        );
        assert!(
            msg.contains("VECTORKIT_SPEC"),
            "error message must cite VECTORKIT_SPEC. Got: {msg}"
        );
    } else {
        panic!("expected Int8QuantizationPolicyUndefined");
    }
}

// ── write-path rejection: add_payloads (batch) ───────────────────────────────

/// A batch with a single int8 payload must be rejected entirely.
/// No rows from the batch must be written.
#[test]
fn add_payloads_batch_containing_int8_returns_rejection_error() {
    let store = open_store();

    let batch = vec![VectorPayloadInput {
        item_id: "int8-item".to_string(),
        vector_index: 0,
        payload: int8_payload(4),
        model_id: "m".to_string(),
        model_version: "1.0".to_string(),
        filed_at_unix_secs: 1_700_000_000,
    }];

    let result = store.add_payloads(&batch);
    assert!(result.is_err(), "int8 batch must return Err");
    assert!(
        is_int8_policy_error(&result.unwrap_err()),
        "error must be Int8QuantizationPolicyUndefined"
    );

    let rows = store
        .vectors_for_item("int8-item")
        .expect("read must succeed");
    assert!(rows.is_empty(), "no row must be persisted when batch int8 is rejected");
}

/// A mixed batch (valid binary + int8) must be rejected entirely — no partial writes.
/// The guard fires before the table write loop.
#[test]
fn add_payloads_mixed_batch_with_int8_rejects_batch_completely() {
    use engram_lib::Engram;

    let store = open_store();

    let binary_input = VectorPayloadInput {
        item_id: "binary-item".to_string(),
        vector_index: 0,
        payload: VectorPayload::from_engram(&Engram::new(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)),
        model_id: "m".to_string(),
        model_version: "1.0".to_string(),
        filed_at_unix_secs: 1_700_000_000,
    };
    let int8_input = VectorPayloadInput {
        item_id: "int8-item".to_string(),
        vector_index: 0,
        payload: int8_payload(4),
        model_id: "m".to_string(),
        model_version: "1.0".to_string(),
        filed_at_unix_secs: 1_700_000_000,
    };

    // int8 item is second — guard must still catch it before any table write.
    let batch = vec![binary_input, int8_input];
    let result = store.add_payloads(&batch);
    assert!(result.is_err(), "mixed batch must return Err");
    assert!(is_int8_policy_error(&result.unwrap_err()));

    // The binary item must NOT have been partially written.
    let binary_rows = store
        .vectors_for_item("binary-item")
        .expect("read must succeed");
    assert!(
        binary_rows.is_empty(),
        "binary rows from a rejected batch must not be partially written"
    );
}

// ── non-regression: float32 and binary writes are unaffected ─────────────────

/// float32 payloads must write without error. The guard is int8-only.
#[test]
fn add_payload_float32_succeeds() {
    let store = open_store();
    let float_payload = VectorPayload::from_f32(&[1.0_f32, 2.0, 3.0, 4.0]);

    let result = store.add_payload(
        "float-item",
        0,
        &float_payload,
        "m",
        "1.0",
        1_700_000_000,
    );
    assert!(result.is_ok(), "float32 add_payload must succeed: {:?}", result);

    // Row must be retrievable.
    let retrieved = store
        .get_payload("float-item", 0, "m")
        .expect("get_payload must succeed");
    assert!(retrieved.is_some(), "float32 payload must persist and read back");
    assert_eq!(retrieved.unwrap().kind, VectorKind::Float32);
}

/// Binary payloads must write without error.
#[test]
fn add_payload_binary_succeeds() {
    use engram_lib::Engram;

    let store = open_store();
    let engram = Engram::new(0xCAFE_BABE_DEAD_BEEF, 0x1234, 0x5678, 0xABCD);

    let result = store.add_vector("binary-item", &engram, "m", "1.0", 1_700_000_000);
    assert!(result.is_ok(), "binary add_vector must succeed: {:?}", result);

    let retrieved = store
        .get_vector("binary-item", "m")
        .expect("get_vector must succeed");
    assert!(retrieved.is_some());
    assert_eq!(retrieved.unwrap(), engram);
}

// ── read-side guard: decode_payload returns Err for int8 rows ────────────────

/// Verify that `get_payload` surfaces an error (not None, not a broken payload)
/// when a hand-crafted int8 row exists in the table.
///
/// The symmetric read guard described in VECTORKIT_SPEC §I-4a ensures that
/// even a manually-inserted int8 row cannot be silently consumed.
///
/// Implementation note: in the Rust port `decode_payload` returns
/// `Err(Int8QuantizationPolicyUndefined)` for int8 rows, which propagates
/// through `get_payload` as an Err. In the Swift port `decodePayload` returns
/// `nil` for int8 rows, which surfaces as `nil` (row "not found") in
/// `getPayload`. Both behaviors prevent silent consumption; the Rust side is
/// more explicit (the caller receives a named error rather than None).
///
/// We can't inject a raw row into the InMemory store without going through
/// the write path (which now rejects int8). Instead we test the guard at the
/// `decode_payload` layer directly via the crate's internal test coverage.
/// The integration-level proof is: add_payload returning Err means no int8
/// row can ever reach the store through the public API, and the unit tests
/// in payload.rs confirm the type is preserved but writes blocked.
#[test]
fn add_payload_int8_rejects_before_table_write_so_no_row_exists_for_decode() {
    // Confirm the chain: add_payload rejects → no row in store → get_payload
    // returns Ok(None) (no row to decode).
    let store = open_store();
    let payload = int8_payload(4);

    let write_result = store.add_payload("x", 0, &payload, "m", "1.0", 0);
    assert!(is_int8_policy_error(&write_result.unwrap_err()));

    // Since the write was rejected, no row exists; get_payload returns None.
    let read_result = store.get_payload("x", 0, "m");
    assert!(read_result.is_ok(), "get_payload on empty store must succeed");
    assert!(read_result.unwrap().is_none(), "no row should exist after rejected write");
}
