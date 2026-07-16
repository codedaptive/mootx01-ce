// Integration tests for Federation backend: identity, signing,
// in-process relay, two-peer push/pull cycle, and conformance
// of the canonical envelope signing bytes.

use std::sync::Arc;
use std::time::Duration;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;
use convergence_kit::{
    envelope_signing_bytes, proposal_signing_bytes, verify_signature, ConflictPolicy,
    FederationRelay, FederationSyncEngine, HyperplaneFamilySpec, LocalIdentity, PackedHLC,
    PairingProposal, PayloadKind, Relay, SignedEnvelope, SyncDirection, SyncEngine, SyncEvent,
    SyncEventKind, SyncManifest, SyncRecord, SyncedTable,
};
use uuid::Uuid;

fn make_storage() -> Arc<dyn Storage> {
    use persistence_kit::{ColumnDeclaration, ColumnType, SchemaDeclaration, TableDeclaration};
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    // Open a minimal schema so apply_record can upsert into "drawers".
    // InMemory requires tables to be declared before row operations.
    let schema = SchemaDeclaration::new(
        "test-kit",
        1,
        vec![TableDeclaration::new(
            "drawers",
            vec![ColumnDeclaration::new("id", ColumnType::Uuid)],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open drawers schema");
    storage
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
    let mut engine = FederationSyncEngine::new(id, relay);
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
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_b.enable(sample_manifest(), make_storage()).unwrap();

    // Symmetric pairing required before push delivers envelopes.
    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family.clone()).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

    engine_a.enqueue(sample_record()).unwrap();
    let push_receipt = engine_a.push().unwrap();
    assert_eq!(push_receipt.pushed, 1);

    let pull_receipt = engine_b.pull().unwrap();
    assert_eq!(pull_receipt.pulled, 1);
    assert_eq!(pull_receipt.conflicts, 0);
}

/// Push routes envelopes only to explicitly paired peers. A third engine
/// registered on the same relay but not paired with the sender must not
/// receive any envelope. Enforces the pairing authorization boundary at
/// the push path (ADR-013).
#[test]
fn push_routes_only_to_paired_peers() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let id_c = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());
    let mut engine_c = FederationSyncEngine::new(id_c, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_b.enable(sample_manifest(), make_storage()).unwrap();
    engine_c.enable(sample_manifest(), make_storage()).unwrap();

    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family.clone()).unwrap();
    engine_b.pair(&engine_a, family).unwrap();
    // engine_c is registered on the relay but NOT paired with engine_a.

    engine_a.enqueue(sample_record()).unwrap();
    let push_receipt = engine_a.push().unwrap();
    assert_eq!(push_receipt.pushed, 1);

    let paired_receipt = engine_b.pull().unwrap();
    assert_eq!(paired_receipt.pulled, 1);
    assert_eq!(paired_receipt.conflicts, 0);

    let unpaired_receipt = engine_c.pull().unwrap();
    assert_eq!(unpaired_receipt.pulled, 0, "unpaired engine must not receive envelopes");
    assert_eq!(unpaired_receipt.conflicts, 0);
}

/// Pull rejects a valid self-signed envelope from an engine that is NOT
/// a paired peer. A valid signature alone does not prove pairing
/// authorization (ADR-013); the sender must be in the paired peer list.
#[test]
fn pull_rejects_signed_envelope_from_unpaired_sender() {
    let relay = Arc::new(FederationRelay::new());
    let id_victim = Arc::new(LocalIdentity::generate());
    let id_trusted = Arc::new(LocalIdentity::generate());
    let id_attacker = Arc::new(LocalIdentity::generate());
    let mut victim = FederationSyncEngine::new(id_victim, relay.clone());
    let mut trusted = FederationSyncEngine::new(id_trusted, relay.clone());
    let mut attacker = FederationSyncEngine::new(id_attacker.clone(), relay.clone());

    victim.enable(sample_manifest(), make_storage()).unwrap();
    trusted.enable(sample_manifest(), make_storage()).unwrap();
    attacker.enable(sample_manifest(), make_storage()).unwrap();

    // Victim is paired with trusted, not with attacker.
    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    victim.pair(&trusted, family.clone()).unwrap();
    trusted.pair(&victim, family).unwrap();

    // Craft a valid self-signed envelope from the attacker identity.
    let payload_bytes = serde_json::to_vec(&vec![sample_record()]).unwrap();
    let batch_hlc = PackedHLC { physical_time: 1000, logical_count: 1, node_id: 0 };
    let attacker_pk = id_attacker.public_key_bytes();
    let signing_bytes = envelope_signing_bytes(
        &attacker_pk,
        PayloadKind::SyncRecordBatch,
        &payload_bytes,
        &batch_hlc,
    );
    let envelope = SignedEnvelope {
        sender_public_key: attacker_pk,
        payload_kind: PayloadKind::SyncRecordBatch,
        payload: payload_bytes,
        signature: id_attacker.sign(&signing_bytes),
        hlc: batch_hlc,
    };

    // Inject via broadcast so it lands in victim's inbox even without pairing.
    relay.broadcast(attacker.peer_identity(), envelope);

    let receipt = victim.pull().unwrap();
    assert_eq!(receipt.pulled, 0, "unpaired sender must not inject records");
    assert_eq!(receipt.conflicts, 1, "rejected envelope counted as conflict");
}

#[test]
fn pull_rejects_kit_mismatch() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    // B has a different kit id.
    let mut alt_manifest = sample_manifest();
    alt_manifest.kit_id = "different-kit".to_string();
    engine_b.enable(alt_manifest, make_storage()).unwrap();

    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family.clone()).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

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
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    let mut alt_manifest = sample_manifest();
    alt_manifest.schema_version = 99;
    engine_b.enable(alt_manifest, make_storage()).unwrap();

    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family.clone()).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

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
    let mut engine = FederationSyncEngine::new(id, relay.clone());
    // A second engine serves as the paired peer so push is not gated.
    let id_b = Arc::new(LocalIdentity::generate());
    let mut peer = FederationSyncEngine::new(id_b, relay);
    peer.enable(sample_manifest(), make_storage()).unwrap();
    engine.enable(sample_manifest(), make_storage()).unwrap();
    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine.pair(&peer, family).unwrap();
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
    // party intercepts the envelope, swaps the sender key, and
    // re-broadcasts. The receiver must reject because the canonical
    // signing bytes include the sender_public_key — a mismatch
    // between the claimed key and the key that actually signed fails
    // verification.
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a.clone(), relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b.clone(), relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_b.enable(sample_manifest(), make_storage()).unwrap();

    // Build a well-formed envelope signed by id_a, then swap the sender
    // key to id_b's key. The signature is now invalid for the claimed
    // sender (id_b), so engine_b must reject.
    let record = sample_record();
    let payload_bytes = serde_json::to_vec(&vec![record]).unwrap();
    let batch_hlc = PackedHLC { physical_time: 1000, logical_count: 1, node_id: 0 };
    let pk_a = id_a.public_key_bytes();
    let signing_bytes = envelope_signing_bytes(
        &pk_a,
        PayloadKind::SyncRecordBatch,
        &payload_bytes,
        &batch_hlc,
    );
    // Signature produced by id_a's key over canonical bytes with id_a's pubkey.
    let good_sig = id_a.sign(&signing_bytes);

    // Forge: claim id_b's sender key while keeping id_a's signature.
    // The canonical bytes computed by engine_b at verify-time will include
    // id_b's pubkey, not id_a's, so the signature won't verify.
    let forged_envelope = SignedEnvelope {
        sender_public_key: id_b.public_key_bytes(),
        payload_kind: PayloadKind::SyncRecordBatch,
        payload: payload_bytes.clone(),
        signature: good_sig,
        hlc: batch_hlc,
    };

    let sentinel = convergence_kit::PeerIdentity::new([0u8; 32]);
    relay.broadcast(&sentinel, forged_envelope);

    let receipt = engine_b.pull().unwrap();
    assert_eq!(receipt.pulled, 0);
    assert_eq!(receipt.conflicts, 1);
}

// MARK: - F-3 security gate tests (FED-HARDEN-1)
//
// F-3 attack: attacker crafts signing bytes using ATTACKER'S own public key,
// signs with the attacker's private key, but sets `sender_public_key` in the
// envelope header to the REGISTERED peer's key. When pull() verifies against
// the registry-sourced key (the fix), it recomputes signing bytes with the
// registered key — those bytes differ from what the attacker signed, so the
// signature fails verification and the envelope is rejected.
//
// Both the negative case (F-3 spoofing rejected) and the positive case
// (correctly-paired envelope ingested) are required to prove that the
// hardened verification path does not regress legitimate traffic.

/// F-3 negative case: attacker signs with their own key but claims the
/// registered peer's key as the sender. The receiver must reject.
///
/// Mirrors Swift `pullRejectsEnvelopeWithSpoofedSenderKeyAndAttackerSignature`.
#[test]
fn pull_rejects_envelope_with_spoofed_sender_key_and_attacker_signature() {
    let relay = Arc::new(FederationRelay::new());
    let id_victim  = Arc::new(LocalIdentity::generate());
    let id_trusted = Arc::new(LocalIdentity::generate());
    // Attacker is a bare identity — no engine, not registered on the relay.
    let attacker = LocalIdentity::generate();

    let mut victim  = FederationSyncEngine::new(id_victim.clone(),  relay.clone());
    let mut trusted = FederationSyncEngine::new(id_trusted.clone(), relay.clone());

    victim.enable(sample_manifest(), make_storage()).unwrap();
    trusted.enable(sample_manifest(), make_storage()).unwrap();

    // Victim is paired with trusted, not with attacker.
    let family = convergence_kit::HyperplaneFamilySpec::new(0xDEADC0DE);
    victim.pair(&trusted, family.clone()).unwrap();
    trusted.pair(&victim, family).unwrap();

    let trusted_pk  = id_trusted.public_key_bytes();
    let attacker_pk = attacker.public_key_bytes();

    // Forge: signing bytes use the ATTACKER's key; envelope claims trusted's key.
    let payload_bytes = serde_json::to_vec(&vec![sample_record()]).unwrap();
    let batch_hlc = PackedHLC { physical_time: 2000, logical_count: 1, node_id: 0 };
    let attacker_signing_bytes = envelope_signing_bytes(
        &attacker_pk,               // ATTACKER's key in canonical signing bytes
        PayloadKind::SyncRecordBatch,
        &payload_bytes,
        &batch_hlc,
    );
    let attacker_signature = attacker.sign(&attacker_signing_bytes);

    let forged_envelope = SignedEnvelope {
        sender_public_key: trusted_pk,          // spoof: claim registered peer's key
        payload_kind: PayloadKind::SyncRecordBatch,
        payload: payload_bytes,
        signature: attacker_signature,          // signed using attacker's key, not trusted's
        hlc: batch_hlc,
    };

    // Broadcast from a sentinel so the forged envelope lands in victim's relay
    // inbox. Because sender_public_key matches a registered peer, the
    // pairing-registry lookup passes — only signature verification (using the
    // registry-sourced key) catches the mismatch and rejects.
    let sentinel = convergence_kit::PeerIdentity::new([0u8; 32]);
    relay.broadcast(&sentinel, forged_envelope);

    let receipt = victim.pull().unwrap();
    assert_eq!(receipt.pulled, 0, "forged sender key claim must not apply records");
    assert_eq!(receipt.conflicts, 1, "rejected envelope must be counted as conflict");
}

/// F-3 positive regression: a correctly-signed envelope from a registered
/// peer must still be ingested after the hardened verification path is active.
///
/// Mirrors Swift `inProcessPairingPushPull` — proves the registry-key
/// verification path does not block legitimate traffic.
#[test]
fn pull_accepts_paired_envelope_and_ingests_record() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_b.enable(sample_manifest(), make_storage()).unwrap();

    // Symmetric pairing is required for push to deliver envelopes.
    let family = convergence_kit::HyperplaneFamilySpec::new(0xFED_CAFE);
    engine_a.pair(&engine_b, family.clone()).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

    engine_a.enqueue(sample_record()).unwrap();
    let push = engine_a.push().unwrap();
    assert_eq!(push.pushed, 1, "push must send one record when paired");

    let pull = engine_b.pull().unwrap();
    assert_eq!(pull.pulled, 1, "correctly-signed paired envelope must be ingested");
    assert_eq!(pull.conflicts, 0, "no conflicts on a legitimate paired envelope");
}

// MARK: - Canonical signing bytes conformance

/// Verify that `envelope_signing_bytes` is deterministic: same inputs,
/// same output on every call.
#[test]
fn envelope_signing_bytes_are_deterministic() {
    let pk = [0xAB_u8; 32];
    let payload = b"test-payload-data";
    let hlc = PackedHLC { physical_time: 1_000_000, logical_count: 7, node_id: 3 };
    let a = envelope_signing_bytes(&pk, PayloadKind::SyncRecordBatch, payload, &hlc);
    let b = envelope_signing_bytes(&pk, PayloadKind::SyncRecordBatch, payload, &hlc);
    assert_eq!(a, b);
}

/// Verify that different inputs produce different canonical bytes.
#[test]
fn envelope_signing_bytes_differ_on_different_inputs() {
    let pk = [0xAB_u8; 32];
    let payload_a = b"payload-A";
    let payload_b = b"payload-B";
    let hlc = PackedHLC { physical_time: 100, logical_count: 1, node_id: 1 };
    let bytes_a = envelope_signing_bytes(&pk, PayloadKind::SyncRecordBatch, payload_a, &hlc);
    let bytes_b = envelope_signing_bytes(&pk, PayloadKind::SyncRecordBatch, payload_b, &hlc);
    assert_ne!(bytes_a, bytes_b);
}

/// Golden-vector test for `envelope_signing_bytes`.
///
/// This vector is the authoritative cross-port conformance anchor.
/// The same inputs fed to the Swift `envelopeSigningBytes(...)` MUST
/// produce the same 57-byte output (32 + 1 + 4 + 4 + 4 + 8 + 4 = 57 bytes
/// for a 4-byte payload "ABCD", including the 4-byte node_id field).
///
/// Layout:
///   [0..31]  sender_public_key: 0x01 × 32
///   [32]     payload_kind: 0x01 (SyncRecordBatch)
///   [33..36] payload_len LE u32: 4 → 04 00 00 00
///   [37..40] payload: 0x41 0x42 0x43 0x44 ("ABCD")
///   [41..48] physical_time LE i64: 1234567890 → D2 02 96 49 00 00 00 00
///   [49..52] logical_count LE i32: 5 → 05 00 00 00
///   [53..56] node_id LE i32: 2 → 02 00 00 00
#[test]
fn envelope_signing_bytes_golden_vector() {
    let pk = [0x01_u8; 32];
    let payload = b"ABCD";
    let hlc = PackedHLC { physical_time: 1_234_567_890_i64, logical_count: 5_i32, node_id: 2_i32 };
    let got = envelope_signing_bytes(&pk, PayloadKind::SyncRecordBatch, payload, &hlc);

    // Build the expected bytes manually to make the layout explicit.
    let mut expected = Vec::with_capacity(57);
    expected.extend_from_slice(&[0x01_u8; 32]);        // public key
    expected.push(0x01);                               // SyncRecordBatch
    expected.extend_from_slice(&4_u32.to_le_bytes()); // payload_len
    expected.extend_from_slice(b"ABCD");               // payload
    expected.extend_from_slice(&1_234_567_890_i64.to_le_bytes()); // physical_time
    expected.extend_from_slice(&5_i32.to_le_bytes());  // logical_count
    expected.extend_from_slice(&2_i32.to_le_bytes());  // node_id

    assert_eq!(got, expected,
        "canonical signing bytes do not match golden vector — cross-port parity broken");
}

/// Sign an envelope on one side and verify using `verify_signature`
/// over the canonical bytes — end-to-end signing conformance test.
#[test]
fn envelope_sign_and_verify_roundtrip() {
    let id = LocalIdentity::generate();
    let pk = id.public_key_bytes();
    let payload = b"sync-batch-payload";
    let hlc = PackedHLC { physical_time: 9_000_000, logical_count: 1, node_id: 0 };

    let signing_bytes = envelope_signing_bytes(&pk, PayloadKind::SyncRecordBatch, payload, &hlc);
    let signature = id.sign(&signing_bytes);

    // Verify with the public key: must succeed.
    assert!(verify_signature(&signature, &signing_bytes, &pk),
        "self-sign/verify roundtrip failed");

    // Verify with tampered bytes: must fail.
    let mut tampered = signing_bytes.clone();
    tampered[0] ^= 0xFF;
    assert!(!verify_signature(&signature, &tampered, &pk),
        "tampered bytes should not verify");

    // Verify with wrong public key: must fail.
    let other_id = LocalIdentity::generate();
    assert!(!verify_signature(&signature, &signing_bytes, &other_id.public_key_bytes()),
        "wrong key should not verify");
}

// MARK: - Pairing gate tests

#[test]
fn push_without_pairing_returns_empty() {
    // An enabled engine with no paired peers returns an empty receipt
    // on push — matching Swift's `if peers.isEmpty { return .empty }`.
    let relay = Arc::new(FederationRelay::new());
    let id = Arc::new(LocalIdentity::generate());
    let mut engine = FederationSyncEngine::new(id, relay);
    engine.enable(sample_manifest(), make_storage()).unwrap();
    engine.enqueue(sample_record()).unwrap();
    let receipt = engine.push().unwrap();
    assert_eq!(receipt.pushed, 0, "push without pairing must return empty");
    assert_eq!(receipt.pulled, 0);
    assert_eq!(receipt.conflicts, 0);
}

#[test]
fn disable_clears_paired_peers() {
    // After disable, the paired-peers list is cleared. Re-enabling
    // requires re-pairing — matching Swift's `disable` clearing `peers`.
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay);
    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_b.enable(sample_manifest(), make_storage()).unwrap();

    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family).unwrap();

    engine_a.enqueue(sample_record()).unwrap();
    let receipt = engine_a.push().unwrap();
    assert_eq!(receipt.pushed, 1, "should push when paired");

    // Disable clears pairing state.
    engine_a.disable().unwrap();
    engine_a.enable(sample_manifest(), make_storage()).unwrap();
    engine_a.enqueue(sample_record()).unwrap();
    let receipt2 = engine_a.push().unwrap();
    assert_eq!(receipt2.pushed, 0, "re-enabled engine with no pairing must return empty");
}
