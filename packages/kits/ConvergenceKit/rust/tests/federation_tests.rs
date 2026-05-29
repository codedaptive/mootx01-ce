// Integration tests for Federation backend: identity, signing,
// in-process relay, two-peer push/pull cycle.

use std::sync::Arc;
use std::time::Duration;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;
use convergence_kit::{
    proposal_signing_bytes, verify_signature, ConflictPolicy, FederationRelay,
    FederationSyncEngine, HyperplaneFamilySpec, LocalIdentity, PairingProposal, SyncDirection,
    SyncEngine, SyncEvent, SyncEventKind, SyncManifest, SyncRecord, SyncedTable,
};
use uuid::Uuid;

fn make_storage() -> Arc<dyn Storage> {
    Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()))
}

fn sample_manifest() -> SyncManifest {
    SyncManifest::new(
        "test-kit",
        1,
        "zone-test",
        vec![SyncedTable::new("drawers", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(ConflictPolicy::AppendOnly)],
    )
}

fn sample_record() -> SyncRecord {
    SyncRecord::new(
        "drawers",
        SyncEventKind::Insert,
        Uuid::new_v4(),
        None,
        HLC { physical_time: 1, logical_count: 0, node_id: 1 },
        1,
        "test-kit",
    )
}

#[test]
fn local_identity_signs_and_verifies() {
    let id = LocalIdentity::generate();
    let data = b"hello world";
    let signature = id.sign(data);
    let pk = id.public_key_bytes();
    assert!(verify_signature(&signature, data, &pk));
    // Tampered data fails.
    assert!(!verify_signature(&signature, b"goodbye world", &pk));
}

#[test]
fn local_identity_roundtrips_through_secret_bytes() {
    let id = LocalIdentity::generate();
    let secret = id.secret_bytes();
    let restored = LocalIdentity::from_secret(secret);
    assert_eq!(id.public_key_bytes(), restored.public_key_bytes());

    let data = b"sanity check";
    let sig = id.sign(data);
    assert!(verify_signature(&sig, data, &restored.public_key_bytes()));
}

#[test]
fn pairing_proposal_signing_bytes_are_deterministic() {
    let proposal = PairingProposal {
        proposer_public_key: vec![0xAA; 32],
        proposed_family: HyperplaneFamilySpec::new(0xDEAD_BEEF),
        nonce: vec![0x11, 0x22, 0x33, 0x44],
    };
    let a = proposal_signing_bytes(&proposal);
    let b = proposal_signing_bytes(&proposal);
    assert_eq!(a, b);
    // Different proposal -> different bytes.
    let mut alt = proposal.clone();
    alt.nonce.push(0xFF);
    let c = proposal_signing_bytes(&alt);
    assert_ne!(a, c);
}

#[test]
fn pairing_acceptance_verifies_proposer_signature() {
    // Two peers; proposer signs the canonical proposal bytes;
    // accepter verifies using the proposer's public key.
    let proposer = LocalIdentity::generate();
    let _accepter = LocalIdentity::generate();
    let proposal = PairingProposal {
        proposer_public_key: proposer.public_key_bytes().to_vec(),
        proposed_family: HyperplaneFamilySpec::new(42),
        nonce: vec![0x42; 16],
    };
    let bytes = proposal_signing_bytes(&proposal);
    let signature = proposer.sign(&bytes);
    assert!(verify_signature(
        &signature,
        &bytes,
        &proposer.public_key_bytes()
    ));
}

#[test]
fn engine_enable_disable_state_transitions() {
    let relay = Arc::new(FederationRelay::new());
    let id = Arc::new(LocalIdentity::generate());
    let engine = FederationSyncEngine::new(id, relay);
    engine.enable(sample_manifest(), make_storage()).unwrap();
    let st = engine.state();
    assert!(matches!(st, convergence_kit::SyncState::Enabled { .. }));
    engine.disable().unwrap();
    assert!(matches!(engine.state(), convergence_kit::SyncState::Disabled));
}

#[test]
fn two_peer_push_pull_roundtrip() {
    // Build two engines on a shared relay. Engine A enqueues a
    // record and pushes; engine B pulls and observes pulled > 0.
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_b.enable(sample_manifest(), make_storage()).unwrap();

    engine_a.enqueue(sample_record()).unwrap();
    let push_receipt = engine_a.push().unwrap();
    assert_eq!(push_receipt.pushed, 1);

    let pull_receipt = engine_b.pull().unwrap();
    assert_eq!(pull_receipt.pulled, 1);
    assert_eq!(pull_receipt.conflicts, 0);
}

#[test]
fn pull_rejects_kit_mismatch() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    // B has a different kit id.
    let mut alt_manifest = sample_manifest();
    alt_manifest.kit_id = "different-kit".to_string();
    engine_b.enable(alt_manifest, make_storage()).unwrap();

    engine_a.enqueue(sample_record()).unwrap();
    engine_a.push().unwrap();

    let receipt = engine_b.pull().unwrap();
    assert_eq!(receipt.pulled, 0);
    assert_eq!(receipt.conflicts, 1);
}

#[test]
fn pull_rejects_schema_mismatch() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    let mut alt_manifest = sample_manifest();
    alt_manifest.schema_version = 99;
    engine_b.enable(alt_manifest, make_storage()).unwrap();

    engine_a.enqueue(sample_record()).unwrap();
    engine_a.push().unwrap();

    let receipt = engine_b.pull().unwrap();
    assert_eq!(receipt.pulled, 0);
    assert_eq!(receipt.conflicts, 1);
}

#[test]
fn subscriber_receives_push_completed_event() {
    let relay = Arc::new(FederationRelay::new());
    let id = Arc::new(LocalIdentity::generate());
    let engine = FederationSyncEngine::new(id, relay);
    engine.enable(sample_manifest(), make_storage()).unwrap();
    let rx = engine.subscribe();
    engine.enqueue(sample_record()).unwrap();
    engine.push().unwrap();
    let event = rx
        .recv_timeout(Duration::from_millis(100))
        .expect("subscriber should receive a SyncEvent");
    match event {
        SyncEvent::PushCompleted { receipt } => {
            assert_eq!(receipt.pushed, 1);
        }
        other => panic!("unexpected event: {:?}", other),
    }
}

#[test]
fn pull_rejects_tampered_signature() {
    // Tamper test: a peer with a valid keypair pushes; a third
    // party intercepts the record, swaps the signer bytes, and
    // re-broadcasts. The receiver must reject. We simulate this
    // by enqueueing through engine A, then verifying that a
    // forged envelope with engine_b's signer bytes (but engine_a's
    // signature) fails verification.
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let engine_a = FederationSyncEngine::new(id_a.clone(), relay.clone());
    let engine_b = FederationSyncEngine::new(id_b.clone(), relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_b.enable(sample_manifest(), make_storage()).unwrap();

    // Direct relay forge: bypass enqueue/push, manually broadcast
    // a tampered envelope.
    let record = sample_record();
    let bytes = serde_json::to_vec(&record).unwrap();
    let bad_signature = id_a.sign(&bytes);
    // Forged "from" identity: claim B's key while using A's signature.
    let envelope = convergence_kit::SignedRecord {
        record,
        signer: id_b.public_key_bytes(),
        signature: bad_signature,
    };
    // Broadcast from a sentinel identity that's not registered;
    // both A and B will receive (and reject).
    let sentinel = convergence_kit::PeerIdentity::new([0u8; 32]);
    relay.broadcast(&sentinel, envelope);

    let receipt = engine_b.pull().unwrap();
    assert_eq!(receipt.pulled, 0);
    assert_eq!(receipt.conflicts, 1);
}
