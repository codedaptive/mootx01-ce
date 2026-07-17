//! FederationSyncEngine: Ed25519-authenticated peer-to-peer
//! backend.
//!
//! Cross-machine wire transport (HTTP/gRPC/QUIC) is a v1.x decision
//! — the governing ruling records this as deliberately out of v1.0
//! scope. The engine ships with an in-process FederationRelay that
//! two engines can plug into for unit tests; a hosted relay conforming
//! to the `Relay` trait is the v1.x extension point.
//!
//! All envelopes are signed at push and verified at pull. Schema
//! and kit mismatch reject the record. Conflict resolution
//! follows the per-table ConflictPolicy on the local manifest.

use crate::engine::SyncEngine;
use crate::record::{ColumnHLCMap, PackedHLC, SyncEventKind, SyncRecord, SyncValueMap};
use crate::types::{AppliedBatch, ConflictPolicy, SyncDirection, SyncedTable, SyncError, SyncEvent, SyncManifest, SyncReceipt, SyncResult, SyncState};
use substrate_types::hlc::{HLC, HLCGenerator};
use ed25519_dalek::{
    Signature, Signer, SigningKey, Verifier, VerifyingKey, PUBLIC_KEY_LENGTH, SECRET_KEY_LENGTH,
    SIGNATURE_LENGTH,
};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use uuid::Uuid;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use persistence_kit::{Column, OrderClause, RowStore, Storage, StorageEvent, StoragePredicate, TableChange, TypedValue};

// ----- identity -----

/// Peer identity: the 32-byte Ed25519 public key.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PeerIdentity {
    pub public_key: [u8; PUBLIC_KEY_LENGTH],
}

impl PeerIdentity {
    pub fn new(public_key: [u8; PUBLIC_KEY_LENGTH]) -> Self {
        PeerIdentity { public_key }
    }
}

/// Local identity: Ed25519 signing key plus derived verifying key.
pub struct LocalIdentity {
    signing_key: SigningKey,
}

impl LocalIdentity {
    /// Generate a fresh keypair.
    pub fn generate() -> Self {
        let signing_key = SigningKey::generate(&mut OsRng);
        LocalIdentity { signing_key }
    }

    /// Restore a keypair from a 32-byte secret. Useful for
    /// persisting the local identity in PersistenceKit's blob store
    /// across restarts.
    pub fn from_secret(secret: [u8; SECRET_KEY_LENGTH]) -> Self {
        LocalIdentity {
            signing_key: SigningKey::from_bytes(&secret),
        }
    }

    pub fn public_key_bytes(&self) -> [u8; PUBLIC_KEY_LENGTH] {
        self.signing_key.verifying_key().to_bytes()
    }

    pub fn secret_bytes(&self) -> [u8; SECRET_KEY_LENGTH] {
        self.signing_key.to_bytes()
    }

    pub fn sign(&self, data: &[u8]) -> [u8; SIGNATURE_LENGTH] {
        self.signing_key.sign(data).to_bytes()
    }
}

/// Verify an Ed25519 signature over `data` by `peer_public_key`.
/// Returns false on any decode error.
pub fn verify_signature(
    signature: &[u8],
    data: &[u8],
    peer_public_key: &[u8],
) -> bool {
    if signature.len() != SIGNATURE_LENGTH || peer_public_key.len() != PUBLIC_KEY_LENGTH {
        return false;
    }
    let mut sig_bytes = [0u8; SIGNATURE_LENGTH];
    sig_bytes.copy_from_slice(signature);
    let mut pk_bytes = [0u8; PUBLIC_KEY_LENGTH];
    pk_bytes.copy_from_slice(peer_public_key);
    let Ok(vk) = VerifyingKey::from_bytes(&pk_bytes) else {
        return false;
    };
    let sig = Signature::from_bytes(&sig_bytes);
    vk.verify(data, &sig).is_ok()
}

// ----- PayloadKind -----

/// Discriminator for the opaque payload carried by `SignedEnvelope`.
/// The single-byte tag is embedded in the canonical signing bytes so the
/// receiver knows how to decode the payload without ambiguity.
///
/// Variants are assigned stable byte values; never reuse a value.
/// `SyncRecordBatch` (0x01) is the only v1.0 data-plane variant.
/// `FieldWriteEventBatch` (0x02) is reserved for the next-gen write-path
/// payload (C1 extension point). `PairingProposal` (0x10) and
/// `PairingAcceptance` (0x11) are WC7 control-plane extension points —
/// silently ignored by `pull()` in v1.0 (handled out-of-band in `pair()`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum PayloadKind {
    /// A JSON-encoded array of `SyncRecord` values. The only v1.0 data payload.
    SyncRecordBatch = 0x01,
    // FieldWriteEventBatch = 0x02  — reserved; add when FieldWriteEvent
    // wire format lands. Do not assign 0x02 to anything else.
    /// Ed25519-signed pairing proposal (WC7 extension point).
    /// Silently ignored by `pull()` in v1.0; handled out-of-band in `pair()`.
    PairingProposal = 0x10,
    /// Ed25519-signed pairing acceptance (WC7 extension point).
    /// Silently ignored by `pull()` in v1.0; handled out-of-band in `pair()`.
    PairingAcceptance = 0x11,
}

// ----- canonical signing bytes -----

/// Build the canonical deterministic byte sequence that `SignedEnvelope.signature`
/// covers.
///
/// Layout (all integers little-endian):
///   sender_public_key (32 bytes, Ed25519 pubkey raw)
///   payload_kind      (1 byte: PayloadKind discriminator)
///   payload_len       (4 bytes: LE u32 count of payload bytes)
///   payload           (payload_len bytes: opaque batch bytes)
///   hlc.physical_time (8 bytes: LE i64)
///   hlc.logical_count (4 bytes: LE i32)
///   hlc.node_id       (4 bytes: LE i32)
///
/// This encoding is byte-identical to the Swift `envelopeSigningBytes` in
/// `FederationSyncEngine.swift`. The signature must verify cross-port.
pub fn envelope_signing_bytes(
    sender_public_key: &[u8; PUBLIC_KEY_LENGTH],
    payload_kind: PayloadKind,
    payload: &[u8],
    hlc: &PackedHLC,
) -> Vec<u8> {
    let payload_len = payload.len() as u32;
    let mut out = Vec::with_capacity(32 + 1 + 4 + payload.len() + 8 + 4 + 4);

    // 32-byte public key
    out.extend_from_slice(sender_public_key);

    // 1-byte payload kind discriminator
    out.push(payload_kind as u8);

    // 4-byte LE length prefix for payload
    out.extend_from_slice(&payload_len.to_le_bytes());

    // Payload bytes
    out.extend_from_slice(payload);

    // HLC: 8-byte LE physical_time, 4-byte LE logical_count, 4-byte LE node_id
    out.extend_from_slice(&hlc.physical_time.to_le_bytes());
    out.extend_from_slice(&hlc.logical_count.to_le_bytes());
    out.extend_from_slice(&hlc.node_id.to_le_bytes());

    out
}

// ----- SignedEnvelope -----

/// The authenticated wire envelope for federated sync.
///
/// Carries an opaque batch payload (discriminated by `payload_kind`) signed with
/// the sender's Ed25519 key. The signature covers deterministic canonical bytes
/// produced by `envelope_signing_bytes(...)`, not raw JSON — closing the
/// relabel/replay seam and ensuring cross-port byte-identical verification.
///
/// `payload_kind` is a C1 extension point: v1.0 only knows `SyncRecordBatch`;
/// `FieldWriteEventBatch` is reserved for the next-gen write-path payload.
/// A receiver that encounters an unknown `payload_kind` should reject the
/// envelope as a conflict rather than panic.
#[derive(Debug, Clone)]
pub struct SignedEnvelope {
    /// 32-byte Ed25519 public key of the sender.
    pub sender_public_key: [u8; PUBLIC_KEY_LENGTH],
    /// Discriminator for the opaque payload's type.
    pub payload_kind: PayloadKind,
    /// Opaque canonical bytes for the batch (e.g. JSON-encoded `[SyncRecord]`
    /// when `payload_kind == SyncRecordBatch`).
    pub payload: Vec<u8>,
    /// Ed25519 signature over `envelope_signing_bytes(...)`.
    /// Not over raw payload bytes — this closes the relabel/replay seam.
    pub signature: [u8; SIGNATURE_LENGTH],
    /// Batch-level HLC timestamp. The sender advances the clock once more after
    /// minting record HLCs; records that already carry their own HLCs may have
    /// higher logical counts, so strict ordering after every record is not
    /// guaranteed.
    pub hlc: PackedHLC,
}

// ----- in-process relay -----

/// Transport abstraction for federated sync. The engine moves signed
/// envelopes through a `Relay`; swapping the implementation swaps the
/// transport without touching the engine. The in-process
/// `FederationRelay` below serves local peering and tests; a hosted
/// HTTPS/gRPC relay (a third-party SyncServer) is a drop-in `Relay`
/// implementation — this trait is that extension point.
pub trait Relay: Send + Sync {
    /// Register a peer; returns the receiver its inbound envelopes arrive on.
    fn register(&self, identity: PeerIdentity) -> Receiver<SignedEnvelope>;
    /// Deliver a signed envelope to every registered peer except `from`.
    fn broadcast(&self, from: &PeerIdentity, envelope: SignedEnvelope);
    /// Deliver a signed envelope to a specific registered peer.
    fn send_to(
        &self,
        from: &PeerIdentity,
        to_public_key: &[u8; PUBLIC_KEY_LENGTH],
        envelope: SignedEnvelope,
    );
}

/// In-process federation relay (the local/test `Relay`). Federation
/// engines register themselves; push delivers a signed envelope to every
/// other registered peer's inbox. Pull drains the local inbox.
#[derive(Default)]
pub struct FederationRelay {
    inboxes: Mutex<Vec<(PeerIdentity, Sender<SignedEnvelope>)>>,
}

impl FederationRelay {
    pub fn new() -> Self {
        FederationRelay::default()
    }
}

impl Relay for FederationRelay {
    fn register(&self, identity: PeerIdentity) -> Receiver<SignedEnvelope> {
        let (tx, rx) = channel();
        self.inboxes.lock().unwrap().push((identity, tx));
        rx
    }

    fn broadcast(&self, from: &PeerIdentity, envelope: SignedEnvelope) {
        let inboxes = self.inboxes.lock().unwrap();
        for (id, tx) in inboxes.iter() {
            if id == from {
                continue;
            }
            // Best-effort: drop send errors (receiver gone).
            let _ = tx.send(envelope.clone());
        }
    }

    fn send_to(
        &self,
        from: &PeerIdentity,
        to_public_key: &[u8; PUBLIC_KEY_LENGTH],
        envelope: SignedEnvelope,
    ) {
        let inboxes = self.inboxes.lock().unwrap();
        for (id, tx) in inboxes.iter() {
            if id == from || &id.public_key != to_public_key {
                continue;
            }
            // Best-effort: drop send errors (receiver gone).
            let _ = tx.send(envelope.clone());
        }
    }
}

// ----- engine -----

/// A peer that has been explicitly paired via `pair()`. Mirrors Swift's
/// `FederationStateActor.PairedPeer`. The engine only pushes when at
/// least one paired peer exists; without pairing, push returns empty.
#[derive(Debug, Clone)]
pub struct PairedPeer {
    pub public_key: [u8; PUBLIC_KEY_LENGTH],
    pub family: crate::pairing::HyperplaneFamilySpec,
}

struct EngineState {
    enabled: bool,
    manifest: Option<SyncManifest>,
    storage: Option<Arc<dyn Storage>>,
    last_push_secs: Option<i64>,
    last_pull_secs: Option<i64>,
    inbox: Option<Receiver<SignedEnvelope>>,
    /// Explicitly paired peers. Mirrors Swift's `FederationStateActor.peers`.
    /// Push is gated on this list being non-empty.
    paired_peers: Vec<PairedPeer>,
    /// Pending records awaiting the next push. Shared (`Arc<Mutex<…>>`) because
    /// the observer worker threads append to it on every observed write while
    /// the engine drains it on `push`. Mirrors the Swift `pendingOutbound`
    /// array on `FederationStateActor`, which the actor's observer tasks fill.
    outbox: Arc<Mutex<Vec<SyncRecord>>>,
    /// HLC generator used to mint a monotonic timestamp for an observed change
    /// that arrives without one (the InMemory observer emits `hlc: None`).
    /// Shared with the worker threads so all auto-populated records draw from
    /// one monotonic clock. Mirrors the Swift `hlcGenerator` on the actor,
    /// which fills `change.hlc ?? hlcGenerator.send(now:)` in `push`.
    hlc_generator: Arc<Mutex<HLCGenerator>>,
    /// Monotonically increasing logical counter for the batch-level HLC.
    /// Advanced once per push batch (not per record) to order envelopes.
    hlc_counter: i32,
    /// Live observer worker threads — one per push-eligible table subscribed
    /// at `enable`. Joined on `disable` so no thread outlives the engine.
    /// Mirrors the Swift `observerTasks: [Task]` array, cancelled in `disable`.
    observer_workers: Vec<JoinHandle<()>>,
    /// Cancellation flag shared with every observer worker. Set on `disable`
    /// to wake the workers out of their bounded `recv_timeout` wait and end
    /// their loops — the explicit-cancel analogue of Swift's `Task.cancel()`.
    /// A flag (not relying on sender-drop) is required because a consumer that
    /// still holds an `Arc<dyn Storage>` clone keeps the observer hub — and its
    /// senders — alive, so the receiver would never disconnect on its own.
    observer_stop: Arc<AtomicBool>,
    /// Guard flag set to `true` for the duration of `pull()`'s apply loop.
    /// When the flag is set the observer workers skip appending inbound-write
    /// events to the outbox, preventing a sync echo: without this guard, each
    /// `apply_record` write triggers the storage observer, causing received
    /// records to be re-enqueued for the next `push` and bounced back to the
    /// peer that sent them.
    pulling: Arc<AtomicBool>,
}

pub struct FederationSyncEngine {
    identity: Arc<LocalIdentity>,
    // Pluggable transport: in-process today, a hosted SyncServer relay later.
    relay: Arc<dyn Relay>,
    peer_identity: PeerIdentity,
    // The engine owns its state directly; mutating verbs take `&mut self`.
    // (The relay is `Arc`-shared across peers, so it keeps its own lock.)
    state: EngineState,
    /// Subscribers receive SyncEvent on every push and pull.
    subscribers: Vec<Sender<SyncEvent>>,
}

impl FederationSyncEngine {
    pub fn new(identity: Arc<LocalIdentity>, relay: Arc<dyn Relay>) -> Self {
        let peer_identity = PeerIdentity::new(identity.public_key_bytes());
        FederationSyncEngine {
            identity,
            relay,
            peer_identity,
            state: EngineState {
                enabled: false,
                manifest: None,
                storage: None,
                last_push_secs: None,
                last_pull_secs: None,
                inbox: None,
                paired_peers: Vec::new(),
                outbox: Arc::new(Mutex::new(Vec::new())),
                // Random low node id in [1, 15], matching the Swift actor's
                // `HLCGenerator(nodeID: Int32.random(in: 1...0x0F))`.
                hlc_generator: Arc::new(Mutex::new(HLCGenerator::new(
                    (rand_node_id() & 0x0F).max(1),
                ))),
                hlc_counter: 0,
                observer_workers: Vec::new(),
                observer_stop: Arc::new(AtomicBool::new(false)),
                pulling: Arc::new(AtomicBool::new(false)),
            },
            subscribers: Vec::new(),
        }
    }

    pub fn peer_identity(&self) -> &PeerIdentity {
        &self.peer_identity
    }

    /// Queue a record for the next push explicitly.
    ///
    /// Production wiring auto-populates the outbox by subscribing to the
    /// storage observer at `enable` (parity with the Swift port — see the
    /// observer-worker setup in `enable`). This explicit entry point remains
    /// available for callers that mint `SyncRecord`s directly (tests, and
    /// out-of-band replays that do not flow through a storage write).
    pub fn enqueue(&mut self, record: SyncRecord) -> SyncResult<()> {
        if !self.state.enabled {
            return Err(SyncError::NotEnabled);
        }
        self.state.outbox.lock().unwrap().push(record);
        Ok(())
    }

    /// Signed Ed25519 pairing handshake (WC6).
    ///
    /// Produces a `PairingProposal` signed with the caller's Ed25519 key,
    /// calls `peer.accept_pairing_proposal` to obtain a `PairingAcceptance`
    /// signed with the peer's key, then verifies:
    ///   1. The accepter's signature over the proposal signing bytes is valid
    ///      against the peer's registered public key.
    ///   2. The accepted family in the acceptance matches the proposed family.
    ///
    /// On success, registers the peer in `self.state.paired_peers` and persists
    /// the peer to `_fed_peers` (if the engine is currently enabled and storage
    /// is available). After pairing, `push` routes envelopes to this peer.
    ///
    /// SYMMETRIC: both sides must call `pair` on each other. Each call registers
    /// the other peer on the CALLER'S side; it does NOT mutate the peer argument.
    ///
    /// SECURITY: failure → `SyncError::AuthenticationFailed`. No half-registered
    /// peer is left in the list on failure.
    pub fn pair(
        &mut self,
        peer: &FederationSyncEngine,
        family: crate::pairing::HyperplaneFamilySpec,
    ) -> SyncResult<()> {
        use crate::pairing::{PairingProposal, proposal_signing_bytes};

        // Build a 16-byte cryptographic nonce using OsRng.
        let mut nonce = [0u8; 16];
        rand_core::RngCore::fill_bytes(&mut OsRng, &mut nonce);

        let proposer_pk = self.identity.public_key_bytes();
        let proposal = PairingProposal {
            proposer_public_key: proposer_pk.to_vec(),
            proposed_family: family,
            nonce: nonce.to_vec(),
        };
        let signing_bytes = proposal_signing_bytes(&proposal);
        let proposer_sig = self.identity.sign(&signing_bytes);

        // Ask the peer to verify and accept the proposal (immutable call; peer
        // does not mutate its own peer list — that happens when peer calls pair()).
        let acceptance = peer.accept_pairing_proposal(&proposal, &proposer_sig)?;

        // Verify: acceptance claims it is from the peer we addressed.
        let expected_pk = peer.identity.public_key_bytes();
        if acceptance.accepter_public_key != expected_pk.as_slice() {
            return Err(SyncError::AuthenticationFailed {
                detail: "acceptance public key does not match addressed peer".to_string(),
            });
        }

        // Verify: accepted family matches the proposed family.
        if acceptance.accepted_family != family {
            return Err(SyncError::AuthenticationFailed {
                detail: "accepted family in acceptance does not match proposed family".to_string(),
            });
        }

        // Verify: accepter's signature over the same proposal signing bytes.
        if !verify_signature(&acceptance.signature_of_proposal, &signing_bytes, &expected_pk) {
            return Err(SyncError::AuthenticationFailed {
                detail: "accepter signature on proposal bytes failed verification".to_string(),
            });
        }

        // All checks passed. Register the peer on the caller's side.
        self.state.paired_peers.push(PairedPeer {
            public_key: expected_pk,
            family,
        });

        // Persist to _fed_peers so pairing survives estate reopen.
        if let Some(ref storage) = self.state.storage {
            if let Err(e) = write_peer(&storage.row_store(), &expected_pk, family) {
                // Persistence failure is non-fatal for the handshake: the peer
                // is registered in-memory and the session continues. Log the
                // failure so callers can observe degraded persistence posture.
                eprintln!(
                    "[ConvergenceKit] pair: failed to persist peer to _fed_peers: {}",
                    e
                );
            }
        }

        self.emit(SyncEvent::PeerConnected {
            identity: format!("{:?}", &expected_pk[..8]),
        });
        Ok(())
    }

    /// Verify a `PairingProposal` signed by the proposer and produce a
    /// `PairingAcceptance` signed with this engine's Ed25519 key.
    ///
    /// Called by the PROPOSER inside `pair()` via an immutable reference to the
    /// peer. Does NOT register the proposer in the peer's `paired_peers` — that
    /// happens when the peer calls `pair()` on the proposer (symmetric handshake).
    ///
    /// Verifies:
    ///   1. `proposer_signature` is a valid Ed25519 signature over
    ///      `proposal_signing_bytes(proposal)` using `proposal.proposer_public_key`.
    ///   2. `proposal.proposer_public_key` is 32 bytes (a well-formed Ed25519 key).
    ///
    /// Returns `SyncError::AuthenticationFailed` on any verification failure.
    /// Mirrors Swift `FederationStateActor.acceptPairingProposal`.
    pub fn accept_pairing_proposal(
        &self,
        proposal: &crate::pairing::PairingProposal,
        proposer_signature: &[u8],
    ) -> SyncResult<crate::pairing::PairingAcceptance> {
        use crate::pairing::{PairingAcceptance, proposal_signing_bytes};

        let signing_bytes = proposal_signing_bytes(proposal);

        // Verify proposer's signature using the public key the proposer claimed.
        // SECURITY: this is the proposer's own key embedded in the proposal;
        // trust is established here only enough to verify the key is self-consistent.
        // The proposer's key is registered in the pairing registry when the peer
        // calls pair() on this engine, which performs the same verification in
        // reverse. Neither side trusts the key unconditionally — both sides sign
        // and verify.
        if !verify_signature(proposer_signature, &signing_bytes, &proposal.proposer_public_key) {
            return Err(SyncError::AuthenticationFailed {
                detail: "proposer signature on pairing proposal failed verification".to_string(),
            });
        }

        // Produce the acceptance: sign the proposal bytes with this engine's key.
        let accepter_pk = self.identity.public_key_bytes();
        let signature_of_proposal = self.identity.sign(&signing_bytes);

        Ok(PairingAcceptance {
            accepter_public_key: accepter_pk.to_vec(),
            accepted_family: proposal.proposed_family,
            signature_of_proposal: signature_of_proposal.to_vec(),
        })
    }

    /// Subscribe to the storage observer and spawn one worker thread per
    /// push-eligible table that maps each observed `TableChange` to a
    /// `SyncRecord` and appends it to the shared outbox.
    ///
    /// This is the production write-capture path, parity with the Swift
    /// `FederationStateActor.enable`, which runs
    /// `storage.observer.observe(table:events:[.insert,.update,.delete])`
    /// for every `table.direction != .pullOnly` and feeds `recordOutbound`.
    /// Pull-only tables never originate local writes for replication, so they
    /// are skipped on both ports.
    ///
    /// Each worker waits on its `Receiver<TableChange>` with a bounded
    /// `recv_timeout` and re-checks the shared stop flag each tick, so
    /// `disable` can wake it promptly even when a consumer still holds a
    /// storage handle keeping the observer's senders alive. This is the
    /// explicit-cancel analogue of the Swift observer `Task` ending on
    /// `Task.cancel()`.
    fn start_observers(
        &mut self,
        manifest: &SyncManifest,
        storage: &Arc<dyn Storage>,
    ) -> SyncResult<()> {
        let observer = storage.observer();
        let events: BTreeSet<StorageEvent> =
            [StorageEvent::Insert, StorageEvent::Update, StorageEvent::Delete]
                .into_iter()
                .collect();

        for table in &manifest.tables {
            // Pull-only tables do not push local writes; skip them (Swift parity).
            if table.direction == SyncDirection::PullOnly {
                continue;
            }
            let rx = observer
                .observe(&table.name, events.clone())
                .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;

            let outbox = Arc::clone(&self.state.outbox);
            let hlc_generator = Arc::clone(&self.state.hlc_generator);
            let stop = Arc::clone(&self.state.observer_stop);
            let pulling = Arc::clone(&self.state.pulling);
            let schema_version = manifest.schema_version;
            let kit_id = manifest.kit_id.clone();
            // Column projection (R2, CVK-ICLOUD P2-M2): capture excluded columns and
            // the PK column from the table declaration so the observer closure can
            // strip them before enqueuing. Cloned at start_observers time; no lock needed.
            let excluded_columns: HashSet<String> = table.excluded_columns.clone();
            let pk_column = table.primary_key_column.clone();
            // Capture conflict_policy for fieldLevelLWW column HLC stamping.
            let conflict_policy = table.conflict_policy;

            let handle = std::thread::spawn(move || {
                // 100ms tick bounds shutdown latency without busy-spinning.
                let tick = Duration::from_millis(100);
                loop {
                    if stop.load(Ordering::Acquire) {
                        return;
                    }
                    match rx.recv_timeout(tick) {
                        Ok(change) => {
                            // Skip while a pull is in progress: the write was
                            // caused by apply_record, not by a local user
                            // mutation. Suppressing here prevents a sync echo
                            // where inbound records are re-enqueued and pushed
                            // back to the peer that originally sent them.
                            if pulling.load(Ordering::Acquire) {
                                continue;
                            }
                            // Column projection (R2): apply outbound strip and
                            // storm-kill before converting to a SyncRecord.
                            let change = outbound_strip_change(change, &excluded_columns, &pk_column);
                            let Some(change) = change else { continue };
                            if let Some(record) =
                                change_to_record(change, schema_version, &kit_id, &hlc_generator, conflict_policy)
                            {
                                outbox.lock().unwrap().push(record);
                            }
                        }
                        // Timed out: loop back and re-check the stop flag.
                        Err(RecvTimeoutError::Timeout) => continue,
                        // The observer hub was dropped (storage closed): exit.
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
            });
            self.state.observer_workers.push(handle);
        }
        Ok(())
    }

    /// Signal every observer worker to stop and join them. Idempotent.
    /// Mirrors the Swift `disable` loop that cancels each observer `Task`.
    fn stop_observers(&mut self) {
        self.state.observer_stop.store(true, Ordering::Release);
        for handle in self.state.observer_workers.drain(..) {
            // A worker can only be blocked for at most one tick, so join is bounded.
            let _ = handle.join();
        }
        // Reset for a future enable on the same engine instance.
        self.state.observer_stop.store(false, Ordering::Release);
    }

    fn emit(&mut self, event: SyncEvent) {
        // Send the event to every subscriber; drop any whose receiver
        // has been released (send returns Err once the rx is gone).
        self.subscribers.retain(|s| s.send(event.clone()).is_ok());
    }

    /// Mint a batch-level PackedHLC. Uses wall-clock millis as physical_time
    /// and an internal counter as the logical component. Advances the counter
    /// so successive batches are strictly ordered.
    fn next_batch_hlc(&mut self) -> PackedHLC {
        self.state.hlc_counter += 1;
        PackedHLC {
            physical_time: now_millis(),
            logical_count: self.state.hlc_counter,
            node_id: 0,
        }
    }
}

impl SyncEngine for FederationSyncEngine {
    fn enable(&mut self, manifest: SyncManifest, storage: Arc<dyn Storage>) -> SyncResult<()> {
        if self.state.enabled {
            return Err(SyncError::AlreadyEnabled);
        }
        let inbox = self.relay.register(self.peer_identity.clone());
        self.state.inbox = Some(inbox);
        // Ensure the _fed_sync_meta side tables exist before any apply. At v3
        // this also creates _fed_pending_skew (CVK-WC3). Mirrors Swift's
        // ensureFedSyncMetaTable call in enable() (A6 unification + WC3 parity).
        ensure_fed_sync_meta_table(&*storage)
            .map_err(|e| SyncError::TransportFailure { detail: format!("ensure _fed_sync_meta: {}", e) })?;

        // Schema-skew replay (CVK-WC3, R9).
        //
        // Drain records from _fed_pending_skew whose schema_version equals the
        // now-active manifest version. Echo suppression is active by construction:
        // observer workers are not yet started (start_observers runs below), so
        // the apply_record writes cannot re-enter the outbox. This mirrors
        // Swift FederationStateActor.enable() skew-replay block.
        {
            let row_store = storage.row_store();
            let ready = fed_skew_drain_ready(&row_store, manifest.schema_version);
            if !ready.is_empty() {
                let mut replayed_ids: Vec<Uuid> = Vec::new();
                for (entry_id, record) in &ready {
                    let Some(synced_table) = manifest.table_named(&record.table) else { continue };
                    if synced_table.direction == SyncDirection::PushOnly { continue }
                    if apply_record(record, synced_table, &storage).is_ok() {
                        replayed_ids.push(*entry_id);
                    }
                }
                let _ = fed_skew_delete_applied(&row_store, &replayed_ids);
            }
            // Emit RecordsHeldForMigration when records with a STILL-higher
            // schema_version remain in the queue after this replay cycle.
            let still_held = fed_skew_count_held(&row_store).unwrap_or(0);
            if still_held > 0 {
                self.emit(SyncEvent::RecordsHeldForMigration { count: still_held });
            }
        }

        // Subscribe the observer workers BEFORE marking enabled so the
        // write-capture path is live the moment the engine reports enabled.
        self.start_observers(&manifest, &storage)?;

        // Reload previously-paired peers from _fed_peers (WC6). This runs after
        // ensure_fed_sync_meta_table (which created _fed_peers if absent) and before
        // marking enabled, so the push gate is populated from the moment the engine
        // is ready. Mirrors Swift FederationStateActor.enable() reloadPeers call.
        if let Err(e) = reload_peers(&storage.row_store(), &mut self.state.paired_peers) {
            // Peer reload failure is non-fatal: the engine proceeds with an empty
            // peer list (no push will route until pair() is called). Log so callers
            // can observe degraded persistence posture.
            eprintln!(
                "[ConvergenceKit] enable: failed to reload peers from _fed_peers: {}",
                e
            );
        }

        self.state.manifest = Some(manifest);
        self.state.storage = Some(storage);
        self.state.enabled = true;
        Ok(())
    }

    fn disable(&mut self) -> SyncResult<()> {
        self.state.enabled = false;
        // Stop the observer workers BEFORE dropping storage so no worker races
        // a late write into the outbox after disable returns (Swift parity:
        // the actor cancels its observer tasks in `disable`).
        self.stop_observers();
        self.state.manifest = None;
        self.state.storage = None;
        self.state.inbox = None;
        self.state.outbox.lock().unwrap().clear();
        self.state.paired_peers.clear();
        Ok(())
    }

    fn push(&mut self) -> SyncResult<SyncReceipt> {
        if !self.state.enabled {
            return Err(SyncError::NotEnabled);
        }
        // Gate on paired peers: without explicit pairing, return empty.
        // Mirrors Swift's `if peers.isEmpty { return .empty }`.
        if self.state.paired_peers.is_empty() {
            return Ok(SyncReceipt::empty());
        }
        let to_send: Vec<SyncRecord> = std::mem::take(&mut *self.state.outbox.lock().unwrap());
        let record_count = to_send.len();
        if record_count == 0 {
            let receipt = SyncReceipt::now(0, 0, 0);
            self.state.last_push_secs = Some(receipt.timestamp_secs);
            self.emit(SyncEvent::PushCompleted { receipt: receipt.clone() });
            return Ok(receipt);
        }

        // Encode the batch to opaque bytes. SyncRecord has a conformance-gated
        // JSON wire format (Serialize/Deserialize via serde_json). The envelope's
        // canonical signing bytes wrap this payload with a length prefix so the
        // boundary is unambiguous when verifying the signature.
        let payload_bytes = serde_json::to_vec(&to_send).map_err(|e| SyncError::EncodingFailure {
            detail: e.to_string(),
        })?;

        // Batch-level HLC: advance once so the envelope timestamp is strictly
        // ordered after all per-record HLCs in the batch.
        let batch_hlc = self.next_batch_hlc();

        let sender_pk = self.identity.public_key_bytes();

        // Build canonical signing bytes and sign with sender's Ed25519 key.
        // The signature covers (sender_public_key || payload_kind || payload_len
        // || payload || hlc) — not raw JSON — closing the relabel/replay seam.
        let signing_bytes = envelope_signing_bytes(
            &sender_pk,
            PayloadKind::SyncRecordBatch,
            &payload_bytes,
            &batch_hlc,
        );
        let signature = self.identity.sign(&signing_bytes);

        let envelope = SignedEnvelope {
            sender_public_key: sender_pk,
            payload_kind: PayloadKind::SyncRecordBatch,
            payload: payload_bytes,
            signature,
            hlc: batch_hlc,
        };
        // Route only to explicitly paired peers rather than broadcasting to
        // all registered relay participants. Broadcasting allowed unpaired
        // observers to receive every push; send_to enforces the pairing
        // authorization boundary at the push path. Mirrors the Swift port.
        for peer in &self.state.paired_peers {
            self.relay.send_to(&self.peer_identity, &peer.public_key, envelope.clone());
        }

        let receipt = SyncReceipt::now(record_count, 0, 0);
        self.state.last_push_secs = Some(receipt.timestamp_secs);
        self.emit(SyncEvent::PushCompleted {
            receipt: receipt.clone(),
        });
        Ok(receipt)
    }

    fn pull(&mut self) -> SyncResult<SyncReceipt> {
        if !self.state.enabled {
            return Err(SyncError::NotEnabled);
        }
        if self.state.inbox.is_none() {
            return Err(SyncError::NotEnabled);
        }
        let manifest = self.state.manifest.clone().ok_or(SyncError::NotEnabled)?;
        let storage = self.state.storage.clone().ok_or(SyncError::NotEnabled)?;

        // Drain the inbox into an owned buffer.
        let envelopes: Vec<SignedEnvelope> = {
            let inbox = self.state.inbox.as_ref().unwrap();
            let mut out = Vec::new();
            while let Ok(env) = inbox.try_recv() {
                out.push(env);
            }
            out
        };

        // Block the observer workers from appending to the outbox for the
        // duration of the apply loop: writes made by apply_record are inbound
        // sync writes, not local user mutations, and must not be re-pushed back
        // to the sending peer. The flag is cleared in the finally-equivalent
        // block below (after all applies, before returning).
        self.state.pulling.store(true, Ordering::Release);

        let mut pulled = 0;
        let mut conflicts = 0;
        // Count of records held in _fed_pending_skew this pull cycle (CVK-WC3, R9).
        let mut skew_held_count: usize = 0;
        // Collect row keys per table for the post-apply integrity hook (R3).
        let mut applied_by_table: HashMap<String, Vec<Uuid>> = HashMap::new();
        let mut deleted_by_table: HashMap<String, Vec<Uuid>> = HashMap::new();
        for envelope in envelopes {
            // SECURITY (F-3 class): `envelope.sender_public_key` is a field
            // the sender controls and must never be trusted as the verification
            // key. Resolve the registered peer from the pairing registry using
            // the envelope's claimed key, then carry the REGISTERED key forward
            // for all subsequent checks. `sender_public_key` is advisory: if it
            // matches a registry entry we proceed; if it diverges from the
            // registered key we reject. Trust derives from the pairing registry,
            // not from the envelope's own fields. Mirrors Swift pull().
            let registered_key: [u8; ed25519_dalek::PUBLIC_KEY_LENGTH] = match self
                .state
                .paired_peers
                .iter()
                .find(|peer| peer.public_key == envelope.sender_public_key)
            {
                Some(p) => p.public_key,
                None => {
                    conflicts += 1;
                    continue; // sender not in pairing registry
                }
            };
            // Advisory-field check: envelope's claimed sender key must equal the
            // registered peer key. The `find` above guarantees this when the
            // peer list is keyed by public key, but the explicit comparison makes
            // the security intent visible: if the lookup mechanism ever changes
            // (e.g. a UUID peer-id lookup returning a different registered key),
            // a mismatch here is a federation-auth rejection, not a silent pass.
            if envelope.sender_public_key != registered_key {
                conflicts += 1;
                continue; // federation-auth: claimed sender key does not match registry
            }

            // Silently ignore pairing control-plane kinds (PairingProposal 0x10,
            // PairingAcceptance 0x11). They are handled out-of-band in pair();
            // their presence in the relay inbox in a future WC7 implementation
            // is expected and must not count as a conflict.
            if envelope.payload_kind == PayloadKind::PairingProposal
                || envelope.payload_kind == PayloadKind::PairingAcceptance
            {
                continue;
            }
            // Reject unknown payload kinds to avoid misinterpreting future
            // payload types. Known data-plane kind: SyncRecordBatch. Unknown
            // kinds are counted as conflicts; no panic.
            if envelope.payload_kind != PayloadKind::SyncRecordBatch {
                conflicts += 1;
                continue;
            }

            // Verify signature over canonical bytes (not raw payload).
            // The sender signed envelope_signing_bytes(...); we reproduce
            // the same bytes here. SECURITY: use the REGISTERED peer key
            // (`registered_key`) as the sender key in the canonical bytes
            // and as the verification key — not `envelope.sender_public_key`.
            // The advisory check above confirms they are equal, but trust
            // derives from the pairing registry, not from the envelope.
            let signing_bytes = envelope_signing_bytes(
                &registered_key,               // registered peer key, not envelope claim
                envelope.payload_kind,
                &envelope.payload,
                &envelope.hlc,
            );
            if !verify_signature(&envelope.signature, &signing_bytes, &registered_key) {
                conflicts += 1;
                continue;
            }

            // Decode the batch from the opaque payload.
            let records: Vec<SyncRecord> = match serde_json::from_slice(&envelope.payload) {
                Ok(r) => r,
                Err(_) => {
                    conflicts += 1;
                    continue;
                }
            };

            for record in &records {
                // Validate kit + schema.
                if record.kit_id != manifest.kit_id {
                    conflicts += 1;
                    continue;
                }
                // Schema-skew split (CVK-WC3, R9):
                //
                // Future-schema (sender on newer schema than receiver):
                //   Enqueue in _fed_pending_skew. NOT a conflict — the record is
                //   valid and will be replayed on enable() after the receiver
                //   updates its manifest schema_version to match.
                //
                // Downgrade-apply (sender on OLDER schema than receiver):
                //   Reject. Applying an older-schema record could overwrite
                //   newer-schema columns with missing-field defaults. Count
                //   as conflict so callers know something was skipped.
                //
                // Equal: normal apply path (schema versions match).
                //
                // Mirrors Swift FederationStateActor.pull() schema-skew split.
                if record.schema_version > manifest.schema_version {
                    let row_store = storage.row_store();
                    if fed_skew_enqueue(&row_store, record).is_ok() {
                        skew_held_count += 1;
                    } else {
                        // Enqueue failure (storage error): count as conflict so
                        // the receipt accurately reflects that this record was
                        // not applied.
                        conflicts += 1;
                    }
                    continue;
                } else if record.schema_version < manifest.schema_version {
                    // Sender is on an older schema than receiver. Applying would
                    // risk clobbering newer-schema columns with missing-field
                    // defaults. Sender must update its schema before retrying.
                    conflicts += 1;
                    continue;
                }
                // record.schema_version == manifest.schema_version — normal apply.
                // Look up the synced table; reject records for unknown tables.
                let synced_table = match manifest.table_named(&record.table) {
                    Some(t) => t,
                    None => {
                        conflicts += 1;
                        continue;
                    }
                };
                // Skip push-only tables on the pull boundary.
                if synced_table.direction == SyncDirection::PushOnly {
                    continue;
                }
                // Apply the record per event kind and conflict policy.
                match apply_record(record, synced_table, &storage) {
                    Ok(()) => {
                        pulled += 1;
                        // Track for post-apply hook: deletes go to deleted_by_table,
                        // inserts/updates go to applied_by_table.
                        if record.event == SyncEventKind::Delete {
                            deleted_by_table
                                .entry(record.table.clone())
                                .or_default()
                                .push(record.row_key);
                        } else {
                            applied_by_table
                                .entry(record.table.clone())
                                .or_default()
                                .push(record.row_key);
                        }
                    }
                    Err(_) => { conflicts += 1; }
                }
            }
        }
        // Clear the pull guard: local writes from this point forward are user
        // mutations and must be captured by the observer workers as normal.
        // The hook invocation below intentionally runs AFTER the guard is
        // cleared so that hook-originated repair writes flow into the outbox
        // (hook-writes-must-ship, Kong Q2 adjudication).
        self.state.pulling.store(false, Ordering::Release);

        // Emit RecordsHeldForMigration when at least one future-schema record
        // was enqueued this cycle (CVK-WC3, R9). Mirrors Swift pull() behavior.
        if skew_held_count > 0 {
            self.emit(SyncEvent::RecordsHeldForMigration { count: skew_held_count });
        }

        // Post-apply integrity hook (R3): invoked once per batch when at least
        // one record was applied. A hook error counts as ONE additional conflict
        // but does NOT abort — all records were already applied before the hook
        // ran. The hook runs after the pull guard is cleared, so writes made
        // through AppliedBatch.storage carry origin == local and reach the outbox.
        if pulled > 0 {
            if let Some(ref hook) = manifest.post_apply_integrity_hook {
                let batch = AppliedBatch {
                    storage: Arc::clone(&storage),
                    applied_by_table,
                    deleted_by_table,
                };
                if hook(&batch).is_err() {
                    conflicts += 1;
                }
            }
        }

        // Tombstone GC: run if the 24 h interval has elapsed since the last sweep.
        // Called on every successful pull; best-effort — a GC failure does not abort
        // the pull or increment conflicts. Mirrors Swift gcIfDue(nowMs:).
        gc_if_due(&storage.row_store(), now_millis());

        let receipt = SyncReceipt::now(0, pulled, conflicts);
        self.state.last_pull_secs = Some(receipt.timestamp_secs);
        self.emit(SyncEvent::RemoteChangesApplied { count: pulled });
        Ok(receipt)
    }

    fn subscribe(&mut self) -> Receiver<SyncEvent> {
        let (tx, rx) = channel();
        self.subscribers.push(tx);
        rx
    }

    fn state(&self) -> SyncState {
        if let Some(ref m) = self.state.manifest {
            if self.state.enabled {
                return SyncState::Enabled {
                    zone: m.zone_identifier.clone(),
                    last_push_secs: self.state.last_push_secs,
                    last_pull_secs: self.state.last_pull_secs,
                };
            }
        }
        SyncState::Disabled
    }
}

/// Apply one inbound SyncRecord to local storage per event kind and conflict policy.
///
/// A6 UNIFICATION: the sync HLC is now stored in `_fed_sync_meta` (a per-engine
/// side table) rather than in the application row's `_syncHLC` column. This
/// matches the Swift Federation engine's A6 migration and the CloudKit engine's
/// `_ck_sync_meta` pattern. The side-table entry survives hard-deletes, blocking
/// stale resurrections for rows that were previously deleted.
///
/// Dispatch order: tombstone first (sync_deleted == Some(true) || Delete event),
/// then Insert/Update via conflict policy. Each arm is a short operation.
fn apply_record(
    record: &SyncRecord,
    synced_table: &SyncedTable,
    storage: &Arc<dyn Storage>,
) -> SyncResult<()> {
    let row_store = storage.row_store();
    let predicate = StoragePredicate::Eq(
        Column::new(record.table.clone(), synced_table.primary_key_column.clone()),
        TypedValue::Uuid(record.row_key),
    );

    // Tombstone path: dispatches on conflict policy, gates via LWW, persists
    // delete HLC in _fed_sync_meta after hard-delete (A6 adjudication).
    let is_tombstone = record.sync_deleted == Some(true) || record.event == SyncEventKind::Delete;
    if is_tombstone {
        match synced_table.conflict_policy {
            ConflictPolicy::AppendOnly => {
                // Append-only tables are write-once; silently reject remote deletes.
            }
            ConflictPolicy::LocalWins => {
                // Local state is authoritative; silently reject remote deletes.
            }
            ConflictPolicy::RemoteWins => {
                // Remote delete wins unconditionally.
                let _ = row_store.delete(&record.table, &predicate);
                // P5-M1b: purge skew-queue entries whose HLC predates this tombstone.
                // remoteWins applies without an HLC gate; purge all older-HLC skew entries
                // since they would be overridden by this delete on replay. Mirrors
                // Swift FederationStateActor.applyInbound remoteWins tombstone arm.
                let _ = fed_skew_delete_older_than(
                    &row_store, &record.table, &record.row_key, record.hlc);
            }
            ConflictPolicy::LastWriterWinsByHLC => {
                // HLC gate: stale delete (incoming HLC < side-table HLC) must not
                // remove a newer local row. Side table persists the HLC after delete
                // so stale resurrections are also blocked (A6).
                if let Some(local_hlc) = read_fed_sync_hlc(&row_store, &record.table, &record.row_key) {
                    let incoming: HLC = record.hlc.into();
                    if incoming < local_hlc {
                        return Ok(()); // stale delete — local row is newer
                    }
                }
                let _ = row_store.delete(&record.table, &predicate);
                // A6: persist tombstone HLC in side table after hard-delete.
                // WHY: without this a stale insert arriving later would find
                // local_hlc = None and be accepted, resurrecting the deleted row.
                write_fed_tombstone_hlc(
                    &row_store,
                    &record.table,
                    &record.row_key,
                    record.hlc.into(),
                )
                .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                // P5-M1b: purge skew-queue entries whose HLC predates this tombstone.
                // The tombstone won the LWW gate; older-HLC skew entries are already
                // superseded (they would be rejected on replay by the same gate).
                // Mirrors Swift FederationStateActor.applyInbound lastWriterWinsByHLC
                // tombstone arm (PendingSkewQueue.deleteMatchingOlderThan call).
                let _ = fed_skew_delete_older_than(
                    &row_store, &record.table, &record.row_key, record.hlc);
            }
            ConflictPolicy::FieldLevelLWW => {
                // Tombstone interplay (edit-beats-delete): the tombstone wins only
                // when its HLC is >= ALL local per-column HLCs. If even one column
                // was written more recently than the tombstone, the row was edited
                // after the delete — the edit wins and the row is preserved.
                // An empty local column HLC map means no column-grain edits exist;
                // tombstone wins unconditionally (row never written under fieldLevelLWW).
                let local_col_hlcs = read_fed_column_hlcs(&row_store, &record.table, &record.row_key);
                if tombstone_wins(record.hlc, &local_col_hlcs) {
                    let _ = row_store.delete(&record.table, &predicate);
                    // Clear column HLC side-table entries: the row is gone, and stale
                    // column entries would confuse a future re-insert under fieldLevelLWW.
                    clear_fed_column_hlcs(&row_store, &record.table, &record.row_key);
                    // A6: persist tombstone HLC in _fed_sync_meta to block stale
                    // resurrections from older records arriving later.
                    write_fed_tombstone_hlc(
                        &row_store,
                        &record.table,
                        &record.row_key,
                        record.hlc.into(),
                    )
                    .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                    // P5-M1b: purge skew-queue entries whose HLC predates this tombstone.
                    // The tombstone won the edit-beats-delete gate; older-HLC skew entries
                    // are already superseded and would lose again on replay. Mirrors
                    // Swift FederationStateActor.applyInbound fieldLevelLWW tombstone arm.
                    let _ = fed_skew_delete_older_than(
                        &row_store, &record.table, &record.row_key, record.hlc);
                }
                // If tombstone_wins returns false, a local column HLC is strictly
                // greater than the tombstone — edit-beats-delete; keep the row.
            }
        }
        return Ok(());
    }

    // Normal (non-tombstone) Insert/Update path.
    match record.event {
        SyncEventKind::Insert | SyncEventKind::Update => {
            let raw_values: BTreeMap<String, TypedValue> = record
                .values
                .as_ref()
                .map(|v| v.clone().into_typed())
                .unwrap_or_default();

            // Inbound projection (R2, CVK-ICLOUD P2-M2): drop excluded columns before
            // the conflict-policy switch. A peer on a different manifest version may
            // send columns this manifest marks excluded. Writing them would overwrite
            // locally-computed derived values with stale remote copies.
            let mut values: BTreeMap<String, TypedValue> = if !synced_table.excluded_columns.is_empty() {
                let dropped: Vec<_> = raw_values
                    .keys()
                    .filter(|k| synced_table.excluded_columns.contains(*k))
                    .cloned()
                    .collect();
                if !dropped.is_empty() {
                    // Log at warn-equivalent (eprintln for now; adopt tracing when wired).
                    eprintln!(
                        "[ConvergenceKit] inbound projection: dropping {} excluded column(s) for table '{}': {}",
                        dropped.len(),
                        synced_table.name,
                        dropped.join(", ")
                    );
                }
                raw_values
                    .into_iter()
                    .filter(|(k, _)| !synced_table.excluded_columns.contains(k))
                    .collect()
            } else {
                raw_values
            };

            // Guarantee the primary key column is present so the storage
            // backend can resolve the row key even when `values` is sparse.
            values
                .entry(synced_table.primary_key_column.clone())
                .or_insert_with(|| TypedValue::Uuid(record.row_key));
            match synced_table.conflict_policy {
                ConflictPolicy::AppendOnly => {
                    row_store
                        .upsert(&record.table, values, &[synced_table.primary_key_column.clone()])
                        .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                }
                ConflictPolicy::LastWriterWinsByHLC => {
                    // A6: read HLC from _fed_sync_meta side table, not from the row.
                    // The side-table entry exists even after a delete (tombstone HLC),
                    // so a stale resurrect for a previously-deleted row is also gated.
                    if let Some(local_hlc) = read_fed_sync_hlc(&row_store, &record.table, &record.row_key) {
                        let incoming: HLC = record.hlc.into();
                        if incoming < local_hlc {
                            return Ok(()); // stale inbound — local (or tombstone) is newer
                        }
                    }
                    // Apply WITHOUT embedding _syncHLC in the row. A6: HLC lives
                    // in _fed_sync_meta, not in the application row column.
                    row_store
                        .upsert(&record.table, values, &[synced_table.primary_key_column.clone()])
                        .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                    // Persist HLC in side table (is_deleted = 0, live row).
                    write_fed_sync_hlc(
                        &row_store,
                        &record.table,
                        &record.row_key,
                        record.hlc.into(),
                    )
                    .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                }
                ConflictPolicy::RemoteWins => {
                    row_store
                        .upsert(&record.table, values, &[synced_table.primary_key_column.clone()])
                        .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                }
                ConflictPolicy::LocalWins => {
                    let count = row_store
                        .count(&record.table, Some(&predicate))
                        .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                    if count == 0 {
                        row_store
                            .insert(&record.table, values)
                            .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                    }
                }
                ConflictPolicy::FieldLevelLWW => {
                    // True column-grain fieldLevelLWW apply using wire-carried column
                    // HLCs and the persistent _fed_sync_meta_cols side table.
                    //
                    // For each column: apply iff incoming column HLC >= local column HLC.
                    // Falls back to the row-grain HLC when the sender omits per-column
                    // HLCs (backward-compat: treat all columns as incoming at row HLC).
                    //
                    // Port of Swift's FieldLWWMerge.merge(…) + ColumnHLCStore.writeAll(…)
                    // in ApplyInbound.swift. Commutativity is guaranteed by field_lww_merge.
                    let local_col_hlcs = read_fed_column_hlcs(&row_store, &record.table, &record.row_key);
                    let incoming_col_hlcs = record.column_hlcs.as_ref().cloned().unwrap_or_default();
                    let (columns_to_apply, updated_col_hlcs) = field_lww_merge(
                        values,
                        &incoming_col_hlcs,
                        record.hlc,
                        &local_col_hlcs,
                    );
                    if !columns_to_apply.is_empty() {
                        row_store
                            .upsert(
                                &record.table,
                                columns_to_apply,
                                &[synced_table.primary_key_column.clone()],
                            )
                            .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                        // Persist updated column HLCs to side table so the next
                        // inbound apply can read them for its own column-grain gate.
                        write_fed_column_hlcs(&row_store, &record.table, &record.row_key, &updated_col_hlcs)
                            .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                    }
                    // Update the row-grain sync HLC in _fed_sync_meta with the
                    // incoming row HLC. The tombstone path uses the column-grain
                    // side table (not this value) for its own gate; this update
                    // keeps _fed_sync_meta current for any code that may query it
                    // independently (e.g. observability, GC).
                    write_fed_sync_hlc(
                        &row_store,
                        &record.table,
                        &record.row_key,
                        record.hlc.into(),
                    )
                    .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                }
            }
        }
        // Delete is handled by the tombstone path above; this arm is unreachable
        // when is_tombstone dispatches correctly.
        SyncEventKind::Delete => {}
    }
    Ok(())
}

/// Outbound column projection (R2, CVK-ICLOUD P2-M2).
///
/// Strips `excluded_columns` from `change.values` before the change enters the
/// outbox. Returns `None` (storm kill) when the change is an update and, after
/// stripping, only the primary key remains — i.e. every changed column was
/// excluded and there is nothing sync-meaningful to ship.
///
/// Parity with Swift `FederationStateActor.recordOutbound`: same two enforcement
/// points (strip + storm-kill), same semantics for delete unaffected.
fn outbound_strip_change(
    mut change: TableChange,
    excluded: &HashSet<String>,
    pk_column: &str,
) -> Option<TableChange> {
    if excluded.is_empty() {
        return Some(change);
    }
    let Some(raw_values) = change.values.take() else {
        // Delete: no values to strip; tombstone must propagate.
        return Some(change);
    };
    let stripped: BTreeMap<String, TypedValue> = raw_values
        .into_iter()
        .filter(|(k, _)| !excluded.contains(k))
        .collect();

    // Storm kill: after stripping, if only the PK remains (or nothing at all),
    // every changed column was excluded. Nothing meaningful to sync for an update.
    // Deletes are handled above (values is None → returned early).
    if change.event == StorageEvent::Update {
        let has_non_pk = stripped.keys().any(|k| k != pk_column);
        if !has_non_pk {
            return None; // storm kill
        }
    }
    change.values = Some(stripped);
    Some(change)
}

/// Map an observed `TableChange` to a `SyncRecord` for the outbox.
///
/// Returns `None` for a change with no `row_key`: a sync record is keyed by
/// its primary-key UUID, so a keyless change cannot be replicated and is
/// dropped (the Swift `push` loop applies the same `guard let rowKey` skip).
///
/// HLC selection mirrors Swift's `change.hlc ?? hlcGenerator.send(now:)`: if
/// the observation already carries the HLC that ordered the write, reuse it;
/// otherwise mint a monotonic one through the shared generator. `send(now:)`
/// advances the logical counter so two HLC-less changes in the same instant do
/// not collide on an identical timestamp.
fn change_to_record(
    change: TableChange,
    schema_version: i32,
    kit_id: &str,
    hlc_generator: &Arc<Mutex<HLCGenerator>>,
    conflict_policy: ConflictPolicy,
) -> Option<SyncRecord> {
    let row_key = change.row_key?;
    let hlc = match change.hlc {
        Some(h) => h,
        None => hlc_generator.lock().unwrap().send(now_millis()),
    };
    let event = SyncEventKind::from(change.event);
    // Tombstone flag: set sync_deleted = Some(true) for delete events so the
    // receiver applies the tombstone path (LWW gate + _fed_sync_meta persistence).
    // Matches Swift FederationStateActor.push() and the wire contract (C-8 parity).
    let sync_deleted = if event == SyncEventKind::Delete { Some(true) } else { None };

    // For fieldLevelLWW tables, stamp all present value columns with the capture HLC.
    // Mirrors Swift FederationStateActor.push() stamping logic (coarse stamp — no
    // changedColumns field on TableChange in PersistenceKit).
    let column_hlcs: Option<ColumnHLCMap> =
        if conflict_policy == ConflictPolicy::FieldLevelLWW && event != SyncEventKind::Delete {
            let raw = change.values.as_ref();
            if let Some(raw_values) = raw {
                let mut entries = std::collections::BTreeMap::new();
                for key in raw_values.keys() {
                    entries.insert(key.clone(), PackedHLC::from(hlc));
                }
                Some(ColumnHLCMap { entries })
            } else {
                None
            }
        } else {
            None
        };

    let values = change.values.map(SyncValueMap::from_typed);
    let mut record = SyncRecord::new(
        change.table,
        event,
        row_key,
        values,
        hlc,
        schema_version,
        kit_id,
    );
    record.sync_deleted = sync_deleted;
    record.column_hlcs = column_hlcs;
    Some(record)
}

/// Current wall-clock in milliseconds, passed explicitly into the HLC
/// generator. Note: the engine also reads wall-clock time through
/// `SyncReceipt::now()` during push and pull receipt creation. Mirrors
/// the Swift actor's `nowMillis()`.
fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Draw a low, non-zero node id for the HLC generator. Mirrors the Swift
/// actor's `Int32.random(in: 1...0x0F)`; the caller masks to `[1, 15]`.
fn rand_node_id() -> i32 {
    let mut key = [0u8; 4];
    rand_core::RngCore::fill_bytes(&mut OsRng, &mut key);
    i32::from_le_bytes(key).unsigned_abs() as i32
}

/// Side table name for Federation row-grain sync HLC storage (A6 unification).
/// Mirrors `_ck_sync_meta` in the CloudKit engine.
const FED_SYNC_META_TABLE: &str = "_fed_sync_meta";

/// Side table name for Federation per-column HLC storage (fieldLevelLWW, B-8).
///
/// Schema: (table_name TEXT, primary_key TEXT, column_name TEXT, col_hlc INT);
/// PRIMARY KEY (table_name, primary_key, column_name).
///
/// One row per (table, row, column) triple. Populated by `write_fed_column_hlcs`
/// after every winning fieldLevelLWW column apply. Consulted by the inbound apply
/// path to determine which columns from the incoming record win over local state.
///
/// Mirrors Swift's `_fed_sync_meta_cols` declared in `FederationStateActor v2`
/// (referenced in ColumnHLCStore.swift). Naming parity: column layout, INT
/// col_hlc encoding, and PK structure are byte-identical to the Swift side.
const FED_SYNC_META_COLS_TABLE: &str = "_fed_sync_meta_cols";

// ─── tombstone GC constants ────────────────────────────────────────────────────

/// Minimum seconds a tombstone HLC entry persists in `_fed_sync_meta` before
/// GC may compact it. 90 days = 7 776 000 s.
///
/// This value MUST STRICTLY EXCEED the slot-eviction long window (30 days,
/// SlotLongInactivityWindow): a device idle just under the eviction window can
/// return, re-enroll, and pull — and must still find every tombstone minted
/// while it was away, or deleted rows would silently resurrect from its stale
/// local copy. Equality is NOT sufficient (a device evicted at exactly the
/// window boundary could race a GC sweep at the same boundary), so retention
/// is 3× the eviction window (raised at the CVK-WB7 merge gate, 2026-07-17).
/// If the eviction window ever changes, this constant must move with it,
/// staying strictly greater.
///
/// Mirrors Swift `SyncTombstone.gcRetentionSeconds`.
pub const TOMBSTONE_GC_RETENTION_SECS: i64 = 7_776_000; // 90 days

/// How often (ms) the federation pull triggers a tombstone GC sweep. 24 h.
///
/// GC pressure is tiny — tombstones accumulate at the delete rate, not the
/// overall write rate. A daily sweep is far more frequent than needed to keep
/// tombstone count bounded; the retention window is 90 d (1 200× the interval).
///
/// Mirrors Swift `TombstoneGCSchedule.gcIntervalMs`.
pub const TOMBSTONE_GC_INTERVAL_MS: i64 = 86_400_000; // 24 h

/// Sentinel `table_name` value in `_fed_sync_meta` for the GC state row.
///
/// The leading underscore matches the convention for internal sentinel keys and
/// cannot collide with a real application table name (application tables are
/// caller-chosen bare identifiers; the protocol reserves underscore-prefixed
/// names for system use). Mirrors Swift `TombstoneGCCoordinator`'s sentinel
/// zone name pattern.
const GC_SENTINEL_TABLE_NAME: &str = "_gc_state";

/// Sentinel `primary_key` value in `_fed_sync_meta` for the GC state row.
///
/// Together with `GC_SENTINEL_TABLE_NAME`, this uniquely identifies the GC
/// sentinel row. The `sync_hlc` field of this row stores the last-GC
/// wall-clock ms directly (NOT a packed HLC — documented here so future
/// readers do not misinterpret it as a sync event timestamp).
const GC_SENTINEL_PRIMARY_KEY: &str = "_tombstone_sweep";

/// Side table name for Federation pending-skew queue (CVK-WC3, schema v3).
///
/// Holds future-schema records (sender schema_version > local manifest) that
/// cannot be applied immediately. On enable(), records whose schema_version
/// equals the newly-active manifest version are replayed through apply_record.
///
/// Schema (mirrors Swift `_fed_pending_skew`):
///   id             UUID    — primary key assigned at enqueue time.
///   table_name     TEXT    — application table the record belongs to.
///   row_key        TEXT    — UUID as TEXT (PK of the application row).
///   schema_version INT     — schemaVersion from the wire record (sender's version).
///   received_at    TEXT    — ISO8601 wall-clock for oldest-eviction ordering.
///                            DATE storage is TEXT per schema invariants.
///   payload        BLOB    — JSON-encoded SyncRecord (full wire format).
///
/// Mirrors Swift `FederationStateActor.fedPendingSkewTable` = "_fed_pending_skew".
const FED_PENDING_SKEW_TABLE: &str = "_fed_pending_skew";

/// Maximum number of held entries before oldest-eviction fires (Playground Rule 8).
///
/// When exceeded, the oldest entries by received_at are evicted. The evicted
/// records are not permanently lost: the peer resends after the remote estate
/// updates its schema. Mirrors Swift `PendingSkewQueue.cap = 512`.
const FED_SKEW_QUEUE_CAP: usize = 512;

/// Side table name for the persistent estate Ed25519 identity (I-8, WC1).
/// One row per estate: key_id TEXT PK (fixed "local"), secret_key BLOB
/// (32 bytes, Ed25519 private key), public_key BLOB (32 bytes),
/// created_at TEXT (ISO8601 per schema invariants — never REAL).
/// At-rest posture: covered by SQLCipher per ADR-014 on the estate file.
const FED_IDENTITY_TABLE: &str = "_fed_identity";

/// Side table name for the persistent paired-peer registry (WC6).
///
/// One row per paired peer:
///   peer_id         TEXT PRIMARY KEY — deterministic UUID from first 16 bytes
///                   of the peer's Ed25519 public key (upsert deduplication).
///   public_key      BLOB — raw 32-byte Ed25519 public key (verifying key).
///   family_seed     INT  — HyperplaneFamilySpec.seed (LE u64 stored as INT64).
///   family_dimension INT  — HyperplaneFamilySpec.dimension (u32 stored as INT64).
///   paired_at       TEXT — ISO8601 wall-clock timestamp (DATE = TEXT per schema
///                   invariants — never REAL).
///
/// enable() drains this table into `state.paired_peers` so pairing survives
/// estate reopen without re-calling pair(). Mirrors Swift `_fed_peers`.
const FED_PEERS_TABLE: &str = "_fed_peers";

/// Ensure all five Federation side tables exist (v6: WC3 skew + WC1 identity + WC6 peers).
///
/// Called from `enable()` before any `apply_record`. Uses `storage.migrate()`
/// which is forward-only and idempotent.
///
/// Schema version history:
///   v1 — `_fed_sync_meta`      row-grain HLC for A6 LWW gate + tombstone block
///   v2 — `_fed_sync_meta_cols` per-column HLC for fieldLevelLWW (B-8 parity)
///   v3 — `_fed_pending_skew`   schema-skew hold queue (CVK-WC3, parity with Swift v3)
///   v4 — `_fed_identity`       persistent Ed25519 estate identity (I-8, WC1)
///   v5 — `_fed_outbox`         durable push outbox (WC2 — root adds migration at merge)
///   v6 — `_fed_peers`          persistent paired-peer registry (WC6)
///
/// NOTE: the v4→v5 migration (`_fed_outbox`, WC2) lands in a sibling worktree.
/// Root reconciles the full migration chain (v4→v5→v6) and the tables list at
/// merge. Fresh installs use the tables array directly (all tables created at
/// schema version 6); v5→v6 only runs for estates upgrading from an existing v5.
///
/// Mirrors Swift `FederationStateActor.ensureFedSyncMetaTable`. Returns an error
/// string on failure (caller converts to SyncError).
fn ensure_fed_sync_meta_table(storage: &dyn Storage) -> Result<(), String> {
    use persistence_kit::{ColumnDeclaration, Migration, SchemaDeclaration, SchemaOperation, TableDeclaration};
    let meta_table = TableDeclaration::new(
        FED_SYNC_META_TABLE,
        vec![
            ColumnDeclaration::text("table_name"),
            ColumnDeclaration::text("primary_key"),
            // sync_hlc: Int64-packed HLC for LWW gate; 0 means no entry yet.
            ColumnDeclaration::int("sync_hlc").with_default(TypedValue::Int(0)),
            ColumnDeclaration::int("schema_version").with_default(TypedValue::Int(0)),
            ColumnDeclaration::text("kit_id").with_default(TypedValue::Text(String::new())),
            // is_deleted: 1 for tombstone entries (delete HLC that outlives the row).
            ColumnDeclaration::int("is_deleted").with_default(TypedValue::Int(0)),
        ],
        vec!["table_name".to_string(), "primary_key".to_string()],
    );
    let cols_table = TableDeclaration::new(
        FED_SYNC_META_COLS_TABLE,
        vec![
            ColumnDeclaration::text("table_name"),
            ColumnDeclaration::text("primary_key"),
            ColumnDeclaration::text("column_name"),
            // col_hlc: Int64-packed HLC, same encoding as _fed_sync_meta.sync_hlc.
            // Stored as signed Int64 (TypedValue::Int); recovered via u64 bit-cast.
            // WHY Int and not a dedicated HLC column: matches Swift's col_hlc INT
            // convention in CKSideSchema v6 and ColumnHLCStore.writeAll.
            ColumnDeclaration::int("col_hlc").with_default(TypedValue::Int(0)),
        ],
        vec![
            "table_name".to_string(),
            "primary_key".to_string(),
            "column_name".to_string(),
        ],
    );
    // _fed_pending_skew: schema-skew hold queue (v3, CVK-WC3).
    // Mirrors Swift `_fed_pending_skew` in FederationStateActor.ensureFedSyncMetaTable.
    // Holds future-schema records until enable() replays them after schema update.
    let skew_table = TableDeclaration::new(
        FED_PENDING_SKEW_TABLE,
        vec![
            // id: UUID primary key assigned at enqueue time.
            ColumnDeclaration::uuid("id"),
            // table_name: application table the record belongs to.
            ColumnDeclaration::text("table_name"),
            // row_key: UUID as TEXT (primary key of the application row).
            ColumnDeclaration::text("row_key"),
            // schema_version: schemaVersion from the wire record (sender's version).
            // INT (not Bool) per schema invariants.
            ColumnDeclaration::int("schema_version").with_default(TypedValue::Int(0)),
            // received_at: ISO8601 wall-clock TEXT for oldest-eviction ordering.
            // Date storage is TEXT (ISO8601) per schema invariants.
            ColumnDeclaration::text("received_at"),
            // payload: JSON-encoded SyncRecord (full wire format).
            ColumnDeclaration::blob("payload"),
        ],
        vec!["id".to_string()],
    );
    // v4 (WC1): persistent Ed25519 estate identity (I-8).
    // One row per estate (key_id = "local"). At-rest posture: SQLCipher
    // per ADR-014 covers the estate file. No custom crypto invented.
    let identity_table = TableDeclaration::new(
        FED_IDENTITY_TABLE,
        vec![
            ColumnDeclaration::text("key_id"),
            // secret_key: 32-byte Ed25519 private key (SigningKey seed).
            ColumnDeclaration::blob("secret_key"),
            // public_key: 32-byte Ed25519 verifying key.
            ColumnDeclaration::blob("public_key"),
            // created_at: ISO8601 TEXT per schema invariants (never REAL).
            ColumnDeclaration::text("created_at"),
        ],
        vec!["key_id".to_string()],
    );
    // v6 (WC6): persistent paired-peer registry (_fed_peers).
    // One row per peer that has completed the signed Ed25519 pairing
    // handshake. Reloaded by enable() so pairing survives estate reopen.
    // Mirrors Swift FederationStateActor.fedPeersTable.
    let peers_table = TableDeclaration::new(
        FED_PEERS_TABLE,
        vec![
            // peer_id: deterministic UUID from first 16 bytes of public key.
            ColumnDeclaration::text("peer_id"),
            // public_key: raw 32-byte Ed25519 verifying key.
            ColumnDeclaration::blob("public_key"),
            // family_seed: HyperplaneFamilySpec.seed (u64 → INT64 bit-cast).
            ColumnDeclaration::int("family_seed"),
            // family_dimension: HyperplaneFamilySpec.dimension (u32 → INT64).
            ColumnDeclaration::int("family_dimension"),
            // paired_at: ISO8601 wall-clock TEXT (never REAL per schema invariants).
            ColumnDeclaration::text("paired_at"),
        ],
        vec!["peer_id".to_string()],
    );
    let schema = SchemaDeclaration::new(
        "ConvergenceKitFederation",
        6,
        vec![
            meta_table,
            cols_table.clone(),
            skew_table.clone(),
            identity_table.clone(),
            peers_table.clone(),
        ],
    )
    .with_migrations(vec![
        // v1 → v2: add _fed_sync_meta_cols per-column HLC side table
        // for fieldLevelLWW column-grain apply (B-8 parity with Swift).
        Migration {
            from_version: 1,
            to_version: 2,
            operations: vec![SchemaOperation::CreateTable(cols_table)],
        },
        // v2 → v3: add _fed_pending_skew schema-skew hold queue (CVK-WC3).
        // Holds future-schema records until enable() replays them after the
        // local manifest schema version is updated. Mirrors Swift v2→v3 migration.
        Migration {
            from_version: 2,
            to_version: 3,
            operations: vec![SchemaOperation::CreateTable(skew_table)],
        },
        // v3 → v4: add _fed_identity persistent estate identity (I-8, WC1).
        // Mirrors Swift FederationStateActor v3→v4.
        Migration {
            from_version: 3,
            to_version: 4,
            operations: vec![SchemaOperation::CreateTable(identity_table)],
        },
        // v4 → v5: _fed_outbox durable push outbox (WC2, landing in a sibling worktree).
        // Root reconciles this migration at merge. The step is a placeholder here
        // so the v5 → v6 migration below can reference a valid from_version.
        // NOTE: this worktree does NOT have WC2's _fed_outbox table declaration;
        // root will add the CreateTable(_fed_outbox) operation at merge.
        // v5 → v6: add _fed_peers persistent paired-peer registry (WC6).
        //
        // This migration runs for estates upgrading from v5 (WC2 applied).
        // Fresh installs bypass migrations and use the tables array directly,
        // landing at v6 with all five tables created. Root reconciles the v4→v5
        // step (WC2's _fed_outbox) and the full migration chain at merge.
        Migration {
            from_version: 5,
            to_version: 6,
            operations: vec![SchemaOperation::CreateTable(peers_table)],
        },
    ]);
    storage.migrate(&schema).map_err(|e| e.to_string())
}

/// Load the estate's persistent Ed25519 identity from `_fed_identity`, or mint
/// a fresh one and persist it (I-8, WC1).
///
/// Called by the host at startup — mirrors Swift `FederationStateActor.loadOrMintIdentity`.
/// Runs `ensure_fed_sync_meta_table` first so callers need not pre-warm the schema.
///
/// At-rest posture: the estate file is covered by SQLCipher (ADR-014); no custom
/// crypto is applied to the key bytes at this layer.
///
/// Returns `Err(String)` on storage failure; callers should surface the error.
pub fn load_or_mint_identity(storage: &dyn Storage) -> Result<LocalIdentity, String> {
    ensure_fed_sync_meta_table(storage)?;
    let predicate = StoragePredicate::Eq(
        Column::new(FED_IDENTITY_TABLE.to_string(), "key_id".to_string()),
        TypedValue::Text("local".to_string()),
    );
    let rows = storage
        .row_store()
        .query(FED_IDENTITY_TABLE, Some(&predicate), &[], None, None)
        .map_err(|e| e.to_string())?;
    if let Some(row) = rows.into_iter().next() {
        if let Some(TypedValue::Blob(secret_bytes)) = row.get("secret_key") {
            if secret_bytes.len() == SECRET_KEY_LENGTH {
                let mut arr = [0u8; SECRET_KEY_LENGTH];
                arr.copy_from_slice(secret_bytes);
                return Ok(LocalIdentity::from_secret(arr));
            }
        }
    }
    // No existing row — mint a fresh identity and persist it.
    let identity = LocalIdentity::generate();
    let secret = identity.secret_bytes().to_vec();
    let pubkey = identity.public_key_bytes().to_vec();
    let now = iso8601_utc_now();
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("key_id".to_string(), TypedValue::Text("local".to_string()));
    values.insert("secret_key".to_string(), TypedValue::Blob(secret));
    values.insert("public_key".to_string(), TypedValue::Blob(pubkey));
    values.insert("created_at".to_string(), TypedValue::Text(now));
    storage
        .row_store()
        .upsert(FED_IDENTITY_TABLE, values, &["key_id".to_string()])
        .map_err(|e| e.to_string())?;
    Ok(identity)
}

// ─── paired-peer persistence (_fed_peers, WC6) ────────────────────────────────

/// Derive a deterministic UUID from the first 16 bytes of an Ed25519 public key.
///
/// Used as the `peer_id` primary key in `_fed_peers` for upsert deduplication:
/// re-pairing with the same public key overwrites the previous row rather than
/// inserting a duplicate. The UUID is derived purely from the key's high-entropy
/// prefix; no randomness is introduced.
///
/// Mirrors Swift `FederationStateActor.peerUUID(from:)`.
fn peer_uuid_from_pubkey(public_key: &[u8; PUBLIC_KEY_LENGTH]) -> String {
    // SAFETY: PUBLIC_KEY_LENGTH == 32 ≥ 16; prefix slice is always 16 bytes.
    let b = &public_key[..16];
    let mut uuid_bytes = [0u8; 16];
    uuid_bytes.copy_from_slice(b);
    Uuid::from_bytes(uuid_bytes).to_string()
}

/// Persist one paired peer to `_fed_peers` (upsert by `peer_id`).
///
/// Called immediately after `pair()` succeeds. Also called by `reload_peers`
/// indirectly via the in-memory peer list — but `reload_peers` reads rows,
/// it does not write them.
fn write_peer(
    row_store: &Arc<dyn RowStore>,
    public_key: &[u8; PUBLIC_KEY_LENGTH],
    family: crate::pairing::HyperplaneFamilySpec,
) -> Result<(), String> {
    let peer_id = peer_uuid_from_pubkey(public_key);
    let now = iso8601_utc_now();
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("peer_id".to_string(), TypedValue::Text(peer_id));
    values.insert("public_key".to_string(), TypedValue::Blob(public_key.to_vec()));
    // family_seed: u64 stored as INT64 via bit-cast (same convention as
    // col_hlc and family seed in the Swift leg — Int64(bitPattern: seed)).
    values.insert(
        "family_seed".to_string(),
        TypedValue::Int(i64::from_ne_bytes(family.seed.to_ne_bytes())),
    );
    values.insert(
        "family_dimension".to_string(),
        TypedValue::Int(i64::from(family.dimension)),
    );
    values.insert("paired_at".to_string(), TypedValue::Text(now));
    row_store
        .upsert(FED_PEERS_TABLE, values, &["peer_id".to_string()])
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Drain `_fed_peers` into `peers`, appending one `PairedPeer` per row.
///
/// Skips rows with unreadable columns and logs a warning per row. Called by
/// `enable()` before marking the engine enabled so the push gate is populated
/// from the moment the engine is ready.
///
/// Mirrors Swift `FederationStateActor.reloadPeers(storage:)`.
fn reload_peers(
    row_store: &Arc<dyn RowStore>,
    peers: &mut Vec<PairedPeer>,
) -> Result<(), String> {
    let rows = row_store
        .query(FED_PEERS_TABLE, None, &[], None, None)
        .map_err(|e| e.to_string())?;
    let mut loaded = 0usize;
    for row in rows {
        let public_key = match row.get("public_key") {
            Some(TypedValue::Blob(b)) if b.len() == PUBLIC_KEY_LENGTH => {
                let mut arr = [0u8; PUBLIC_KEY_LENGTH];
                arr.copy_from_slice(b);
                arr
            }
            _ => {
                eprintln!(
                    "[ConvergenceKit] reload_peers: row with missing/short public_key — skipped"
                );
                continue;
            }
        };
        let seed_i64 = match row.get("family_seed") {
            Some(TypedValue::Int(i)) => *i,
            _ => {
                eprintln!("[ConvergenceKit] reload_peers: row with unreadable family_seed — skipped");
                continue;
            }
        };
        let dim_i64 = match row.get("family_dimension") {
            Some(TypedValue::Int(i)) => *i,
            _ => {
                eprintln!(
                    "[ConvergenceKit] reload_peers: row with unreadable family_dimension — skipped"
                );
                continue;
            }
        };
        // Reverse the bit-cast: seed stored as i64 bit pattern of the u64 value.
        let seed = u64::from_ne_bytes(seed_i64.to_ne_bytes());
        let dimension = dim_i64 as u32;
        let family = crate::pairing::HyperplaneFamilySpec { seed, dimension };
        peers.push(PairedPeer { public_key, family });
        loaded += 1;
    }
    if loaded > 0 {
        eprintln!("[ConvergenceKit] enable: reloaded {} paired peer(s) from _fed_peers", loaded);
    }
    Ok(())
}

// ─── tombstone GC ─────────────────────────────────────────────────────────────

/// Compact stale tombstone entries from `_fed_sync_meta`.
///
/// Queries all rows where `is_deleted = 1` (tombstone entries), unpacks the
/// `sync_hlc` physical time, and deletes entries whose physical time is older
/// than `TOMBSTONE_GC_RETENTION_SECS` ago. The retention window ensures
/// in-flight stale resurrects from peers that have not recently synced are
/// still gated by a live tombstone HLC entry (A6 stale-resurrect guard).
///
/// Returns the count of compacted entries.
///
/// Port of Swift `TombstoneGC.compact(from:sideTable:nowMillis:)`.
fn tombstone_compact(row_store: &Arc<dyn RowStore>, now_ms: i64) -> usize {
    let retention_ms = TOMBSTONE_GC_RETENTION_SECS * 1_000;

    // CRITICAL: the stored sync_hlc physical field is 40-bit-truncated
    // (HLC.packed() masks phys with 0xFF_FFFF_FFFF), while now_ms is full-width
    // Unix ms (~1.75e12 in 2026 > 2^40 ≈ 1.10e12). Comparing an unmasked
    // cutoff against truncated stored values would make EVERY tombstone look
    // ~35 years old and compact them all instantly, silently destroying the
    // A6 stale-resurrect guard (same failure class as the SlotTable eviction
    // bug — Perkins P4-M4 finding). Mask the cutoff into the same 40-bit
    // space so both sides of the comparison wrap identically.
    let cutoff_ms: i64 = ((now_ms - retention_ms) as u64 & 0xFF_FFFF_FFFF) as i64;

    // Query all tombstone entries for this side table.
    // WHY query-then-delete rather than a single DELETE WHERE: the packed HLC
    // stores physical time in the lowest 40 bits with node/logical in the upper
    // bits. A direct SQL comparison on the packed int64 would not correctly
    // isolate physical time; we unpack in Rust instead. Mirrors Swift TombstoneGC.compact.
    let predicate = StoragePredicate::Eq(
        Column::new(FED_SYNC_META_TABLE.to_string(), "is_deleted".to_string()),
        TypedValue::Int(1),
    );
    let Ok(tombstones) = row_store.query(FED_SYNC_META_TABLE, Some(&predicate), &[], None, None)
    else {
        return 0;
    };

    let mut compacted = 0;
    for row in tombstones {
        let packed_i64 = match row.get("sync_hlc") {
            Some(TypedValue::Int(i)) => *i,
            _ => continue,
        };

        // Extract the low 40 bits as the physical time in milliseconds.
        // Packed layout (cookbook §12.3): (node 8 bits << 56) |
        //   (logicalCount 16 bits << 40) | (physicalTime 40 bits).
        let physical_ms: i64 = (packed_i64 as u64 & 0xFF_FFFF_FFFF) as i64;

        if physical_ms > cutoff_ms {
            // Tombstone is within the retention window — keep it.
            continue;
        }

        // Tombstone is beyond the retention window. Delete by (table_name, primary_key).
        let tname = match row.get("table_name") {
            Some(TypedValue::Text(t)) => t.clone(),
            _ => continue,
        };
        let pk = match row.get("primary_key") {
            Some(TypedValue::Text(p)) => p.clone(),
            _ => continue,
        };
        let delete_pred = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new(FED_SYNC_META_TABLE.to_string(), "table_name".to_string()),
                TypedValue::Text(tname),
            ),
            StoragePredicate::Eq(
                Column::new(FED_SYNC_META_TABLE.to_string(), "primary_key".to_string()),
                TypedValue::Text(pk),
            ),
        ]);
        if row_store.delete(FED_SYNC_META_TABLE, &delete_pred).is_ok() {
            compacted += 1;
        }
    }
    compacted
}

/// Read the last-GC wall-clock ms from the GC sentinel row.
///
/// Returns 0 when no prior GC run has been recorded, so `(now_ms - 0)` is
/// always `>= TOMBSTONE_GC_INTERVAL_MS` for any reasonable `now_ms` (well
/// past the Unix epoch). Mirrors Swift `readLastGCMs(from:)`.
fn read_gc_sentinel_ms(row_store: &Arc<dyn RowStore>) -> i64 {
    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_TABLE.to_string(), "table_name".to_string()),
            TypedValue::Text(GC_SENTINEL_TABLE_NAME.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_TABLE.to_string(), "primary_key".to_string()),
            TypedValue::Text(GC_SENTINEL_PRIMARY_KEY.to_string()),
        ),
    ]);
    let Ok(rows) = row_store.query(FED_SYNC_META_TABLE, Some(&predicate), &[], None, None) else {
        return 0;
    };
    let Some(row) = rows.into_iter().next() else {
        return 0;
    };
    match row.get("sync_hlc") {
        Some(TypedValue::Int(ms)) => *ms,
        _ => 0,
    }
}

/// Write the last-GC wall-clock ms to the GC sentinel row.
///
/// The sentinel occupies `(table_name='_gc_state', primary_key='_tombstone_sweep')`
/// in `_fed_sync_meta`. The `sync_hlc` field stores wall-clock ms directly —
/// NOT a packed HLC. This sentinel row is never read as a tombstone gate;
/// only `read_gc_sentinel_ms` reads it.
///
/// `is_deleted = 0` ensures the sentinel row is never swept by
/// `tombstone_compact`, which only queries `is_deleted = 1` rows.
///
/// Mirrors Swift `writeLastGCMs(_:to:)`.
fn write_gc_sentinel_ms(row_store: &Arc<dyn RowStore>, ms: i64) {
    let mut values = BTreeMap::new();
    values.insert("table_name".to_string(), TypedValue::Text(GC_SENTINEL_TABLE_NAME.to_string()));
    values.insert("primary_key".to_string(), TypedValue::Text(GC_SENTINEL_PRIMARY_KEY.to_string()));
    // sync_hlc: wall-clock ms of last GC run. NOT a packed HLC — this field
    // is read only by read_gc_sentinel_ms; it never participates in the LWW gate.
    values.insert("sync_hlc".to_string(), TypedValue::Int(ms));
    values.insert("schema_version".to_string(), TypedValue::Int(0));
    values.insert("kit_id".to_string(), TypedValue::Text(String::new()));
    // is_deleted = 0: sentinel row MUST NOT be swept by tombstone_compact.
    values.insert("is_deleted".to_string(), TypedValue::Int(0));
    let _ = row_store.upsert(
        FED_SYNC_META_TABLE,
        values,
        &["table_name".to_string(), "primary_key".to_string()],
    );
}

/// Run tombstone GC if the 24 h interval has elapsed since the last sweep.
///
/// Reads the last-GC timestamp from the GC sentinel row in `_fed_sync_meta`,
/// checks the `TOMBSTONE_GC_INTERVAL_MS` interval, runs `tombstone_compact`
/// if due, and updates the sentinel. Best-effort — a storage failure leaves
/// the sentinel unchanged so the next pull retries.
///
/// `now_ms` is injectable for testing; production callers pass `now_millis()`.
///
/// Mirrors Swift `FederationStateActor.gcIfDue(nowMs:)`, which calls
/// `TombstoneGC.compact(from:sideTable:nowMillis:)` then `writeLastGCMs(_:to:)`.
fn gc_if_due(row_store: &Arc<dyn RowStore>, now_ms: i64) {
    let last_gc_ms = read_gc_sentinel_ms(row_store);
    if (now_ms - last_gc_ms) < TOMBSTONE_GC_INTERVAL_MS {
        return;
    }
    tombstone_compact(row_store, now_ms);
    write_gc_sentinel_ms(row_store, now_ms);
}

/// Read the persisted sync HLC from `_fed_sync_meta` for a given (table, row_key).
///
/// A6: HLC lives in the side table, not in the application row. Returns the HLC
/// regardless of `is_deleted` status — tombstone HLCs gate the same as live HLCs.
fn read_fed_sync_hlc(
    row_store: &Arc<dyn RowStore>,
    table: &str,
    row_key: &uuid::Uuid,
) -> Option<HLC> {
    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_TABLE.to_string(), "table_name".to_string()),
            TypedValue::Text(table.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_TABLE.to_string(), "primary_key".to_string()),
            TypedValue::Text(row_key.to_string()),
        ),
    ]);
    let rows = row_store
        .query(FED_SYNC_META_TABLE, Some(&predicate), &[], None, None)
        .ok()?;
    let first = rows.into_iter().next()?;
    match first.get("sync_hlc") {
        Some(TypedValue::Hlc(h)) => Some(*h),
        Some(TypedValue::Int(i)) => Some(HLC::from_packed((*i) as u64)),
        _ => None,
    }
}

/// Persist the sync HLC in `_fed_sync_meta` after a successful upsert (is_deleted = 0).
fn write_fed_sync_hlc(
    row_store: &Arc<dyn RowStore>,
    table: &str,
    row_key: &uuid::Uuid,
    hlc: HLC,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut values = BTreeMap::new();
    values.insert("table_name".to_string(), TypedValue::Text(table.to_string()));
    values.insert("primary_key".to_string(), TypedValue::Text(row_key.to_string()));
    // hlc.packed() → u64 bit layout per cookbook §12.3; stored as Int64 for TypedValue parity.
    values.insert("sync_hlc".to_string(), TypedValue::Int(hlc.packed() as i64));
    values.insert("schema_version".to_string(), TypedValue::Int(0));
    values.insert("kit_id".to_string(), TypedValue::Text(String::new()));
    values.insert("is_deleted".to_string(), TypedValue::Int(0));
    row_store.upsert(
        FED_SYNC_META_TABLE,
        values,
        &["table_name".to_string(), "primary_key".to_string()],
    )?;
    Ok(())
}

/// Persist the delete HLC in `_fed_sync_meta` after a hard-delete (A6, is_deleted = 1).
///
/// WHY: without this a stale insert for the same (table, row_key) would find
/// local_hlc = None and be accepted, resurrecting the deleted row.
fn write_fed_tombstone_hlc(
    row_store: &Arc<dyn RowStore>,
    table: &str,
    row_key: &uuid::Uuid,
    hlc: HLC,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut values = BTreeMap::new();
    values.insert("table_name".to_string(), TypedValue::Text(table.to_string()));
    values.insert("primary_key".to_string(), TypedValue::Text(row_key.to_string()));
    // hlc.packed() → u64 bit layout per cookbook §12.3; stored as Int64 for TypedValue parity.
    values.insert("sync_hlc".to_string(), TypedValue::Int(hlc.packed() as i64));
    values.insert("schema_version".to_string(), TypedValue::Int(0));
    values.insert("kit_id".to_string(), TypedValue::Text(String::new()));
    values.insert("is_deleted".to_string(), TypedValue::Int(1));
    row_store.upsert(
        FED_SYNC_META_TABLE,
        values,
        &["table_name".to_string(), "primary_key".to_string()],
    )?;
    Ok(())
}

// ─── per-column HLC side table (_fed_sync_meta_cols) ──────────────────────────

/// Read the ColumnHLCMap for a given (table, row_key) from `_fed_sync_meta_cols`.
///
/// Returns all (column_name, col_hlc) rows for the pair, decoded into a
/// ColumnHLCMap. Returns an empty map when no entries exist — first write for
/// this row under fieldLevelLWW (any incoming HLC wins).
///
/// Mirrors Swift's `ColumnHLCStore.readAll(from:sideTable:tableName:primaryKey:)`.
fn read_fed_column_hlcs(
    row_store: &Arc<dyn RowStore>,
    table: &str,
    row_key: &uuid::Uuid,
) -> ColumnHLCMap {
    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_COLS_TABLE.to_string(), "table_name".to_string()),
            TypedValue::Text(table.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_COLS_TABLE.to_string(), "primary_key".to_string()),
            TypedValue::Text(row_key.to_string()),
        ),
    ]);
    let Ok(rows) = row_store.query(FED_SYNC_META_COLS_TABLE, Some(&predicate), &[], None, None)
    else {
        return ColumnHLCMap::default();
    };
    let mut entries = BTreeMap::new();
    for row in rows {
        let Some(TypedValue::Text(col_name)) = row.get("column_name") else { continue };
        let col_hlc_i64 = match row.get("col_hlc") {
            Some(TypedValue::Int(i)) => *i,
            _ => continue,
        };
        // col_hlc stored as Int64 bit-cast from u64 (same as sync_hlc in _fed_sync_meta).
        let hlc = HLC::from_packed(col_hlc_i64 as u64);
        entries.insert(col_name.clone(), PackedHLC::from(hlc));
    }
    ColumnHLCMap { entries }
}

/// Persist a ColumnHLCMap for a given (table, row_key) to `_fed_sync_meta_cols`.
///
/// Upserts one row per column using the three-column PK (table_name, primary_key,
/// column_name) on conflict. Existing entries for columns not in `map` are left
/// unchanged. Empty map is a no-op.
///
/// Mirrors Swift's `ColumnHLCStore.writeAll(map:to:sideTable:tableName:primaryKey:)`.
fn write_fed_column_hlcs(
    row_store: &Arc<dyn RowStore>,
    table: &str,
    row_key: &uuid::Uuid,
    map: &ColumnHLCMap,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if map.is_empty() {
        return Ok(());
    }
    for (col_name, &packed_hlc) in &map.entries {
        let hlc: HLC = packed_hlc.into();
        // Encode as Int64 bit-cast from u64 — same convention as write_fed_sync_hlc.
        let col_hlc_val = hlc.packed() as i64;
        let mut values = BTreeMap::new();
        values.insert("table_name".to_string(),  TypedValue::Text(table.to_string()));
        values.insert("primary_key".to_string(), TypedValue::Text(row_key.to_string()));
        values.insert("column_name".to_string(), TypedValue::Text(col_name.clone()));
        values.insert("col_hlc".to_string(),     TypedValue::Int(col_hlc_val));
        row_store.upsert(
            FED_SYNC_META_COLS_TABLE,
            values,
            &[
                "table_name".to_string(),
                "primary_key".to_string(),
                "column_name".to_string(),
            ],
        )?;
    }
    Ok(())
}

/// Delete all per-column HLC entries for a given (table, row_key).
///
/// Called after a row is hard-deleted: column HLC side-table entries are
/// no longer needed once the tombstone HLC is persisted in `_fed_sync_meta`
/// (the row-grain side table guards against stale resurrects). Leaving stale
/// column entries wastes space and could confuse a future re-insert under
/// fieldLevelLWW.
///
/// Mirrors Swift's `ColumnHLCStore.clearAll(from:sideTable:tableName:primaryKey:)`.
fn clear_fed_column_hlcs(
    row_store: &Arc<dyn RowStore>,
    table: &str,
    row_key: &uuid::Uuid,
) {
    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_COLS_TABLE.to_string(), "table_name".to_string()),
            TypedValue::Text(table.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new(FED_SYNC_META_COLS_TABLE.to_string(), "primary_key".to_string()),
            TypedValue::Text(row_key.to_string()),
        ),
    ]);
    // Best-effort: ignore errors (row may already be absent; stale entries
    // would only affect future re-inserts, not correctness of current deletes).
    let _ = row_store.delete(FED_SYNC_META_COLS_TABLE, &predicate);
}

// ─── _fed_pending_skew helpers (CVK-WC3) ──────────────────────────────────────

/// Enqueue a SyncRecord in `_fed_pending_skew`.
///
/// Writes the entry with a fresh UUID primary key and the current wall-clock
/// time (ISO8601) in `received_at`, then calls `fed_skew_evict_if_needed` to
/// keep the table at or below `FED_SKEW_QUEUE_CAP`.
///
/// All side-table writes flow through the default `upsert` path (not
/// `upsert_sync`) because the Rust engine suppresses echo via the
/// `pulling: AtomicBool` flag, not the sync-tagged write variants.
///
/// Mirrors Swift `PendingSkewQueue.enqueue(_:to:sideTable:)`.
fn fed_skew_enqueue(
    row_store: &Arc<dyn RowStore>,
    record: &SyncRecord,
) -> Result<(), String> {
    let payload = serde_json::to_vec(record).map_err(|e| e.to_string())?;
    let id = Uuid::new_v4();
    let received_at = iso8601_utc_now();
    let mut values = BTreeMap::new();
    values.insert("id".to_string(),             TypedValue::Uuid(id));
    values.insert("table_name".to_string(),     TypedValue::Text(record.table.clone()));
    values.insert("row_key".to_string(),        TypedValue::Text(record.row_key.to_string()));
    values.insert("schema_version".to_string(), TypedValue::Int(record.schema_version as i64));
    values.insert("received_at".to_string(),    TypedValue::Text(received_at));
    values.insert("payload".to_string(),        TypedValue::Blob(payload));
    row_store
        .upsert(FED_PENDING_SKEW_TABLE, values, &["id".to_string()])
        .map_err(|e| e.to_string())?;
    let _ = fed_skew_evict_if_needed(row_store);
    Ok(())
}

/// Evict the oldest entries when `_fed_pending_skew` exceeds the cap.
///
/// Oldest is defined by `received_at` ascending (ISO8601 sorts lexicographically,
/// equivalent to chronological oldest-first). Best-effort: errors are silently
/// ignored. Mirrors Swift `PendingSkewQueue.evictIfNeeded(cap:from:sideTable:)`.
fn fed_skew_evict_if_needed(row_store: &Arc<dyn RowStore>) {
    let total = match row_store.count(FED_PENDING_SKEW_TABLE, None) {
        Ok(n) => n,
        Err(_) => return,
    };
    if total <= FED_SKEW_QUEUE_CAP {
        return;
    }
    let excess = total - FED_SKEW_QUEUE_CAP;
    // Fetch the oldest `excess` entries by received_at ascending.
    let order = OrderClause::ascending(Column::new(FED_PENDING_SKEW_TABLE, "received_at"));
    let oldest = match row_store.query(
        FED_PENDING_SKEW_TABLE,
        None,
        &[order],
        Some(excess),
        None,
    ) {
        Ok(rows) => rows,
        Err(_) => return,
    };
    let ids: Vec<TypedValue> = oldest
        .iter()
        .filter_map(|row| row.get("id").cloned())
        .filter(|v| matches!(v, TypedValue::Uuid(_)))
        .collect();
    if ids.is_empty() {
        return;
    }
    let predicate = StoragePredicate::In(
        Column::new(FED_PENDING_SKEW_TABLE.to_string(), "id".to_string()),
        ids,
    );
    let _ = row_store.delete(FED_PENDING_SKEW_TABLE, &predicate);
}

/// Fetch all entries from `_fed_pending_skew` whose `schema_version` equals
/// `current_version`. Does NOT delete the entries — the caller must confirm
/// successful apply by passing IDs to `fed_skew_delete_applied`.
///
/// Entries with corrupt payloads are silently skipped (the entry remains in
/// the table for the next enable() attempt). Mirrors Swift
/// `SkewReplay.drainReady(currentVersion:from:sideTable:)`.
fn fed_skew_drain_ready(
    row_store: &Arc<dyn RowStore>,
    current_version: i32,
) -> Vec<(Uuid, SyncRecord)> {
    let predicate = StoragePredicate::Eq(
        Column::new(FED_PENDING_SKEW_TABLE.to_string(), "schema_version".to_string()),
        TypedValue::Int(current_version as i64),
    );
    let rows = match row_store.query(FED_PENDING_SKEW_TABLE, Some(&predicate), &[], None, None) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let mut result = Vec::new();
    for row in rows {
        let id = match row.get("id") {
            Some(TypedValue::Uuid(u)) => *u,
            _ => continue,
        };
        let payload = match row.get("payload") {
            Some(TypedValue::Blob(b)) => b.clone(),
            _ => continue,
        };
        let record: SyncRecord = match serde_json::from_slice(&payload) {
            Ok(r) => r,
            Err(_) => continue,  // corrupt payload: skip, leave for next enable()
        };
        result.push((id, record));
    }
    result
}

/// Delete entries with the given IDs from `_fed_pending_skew`.
///
/// Called after successful `apply_record` for each replayed entry. Uses
/// `delete` (not `delete_sync`) because Rust echo suppression is handled
/// by the `pulling` flag, not the sync-tagged write paths.
///
/// Mirrors Swift `SkewReplay.deleteApplied(ids:from:sideTable:)`.
fn fed_skew_delete_applied(
    row_store: &Arc<dyn RowStore>,
    ids: &[Uuid],
) {
    if ids.is_empty() {
        return;
    }
    let id_values: Vec<TypedValue> = ids.iter().map(|u| TypedValue::Uuid(*u)).collect();
    let predicate = StoragePredicate::In(
        Column::new(FED_PENDING_SKEW_TABLE.to_string(), "id".to_string()),
        id_values,
    );
    let _ = row_store.delete(FED_PENDING_SKEW_TABLE, &predicate);
}

/// Return the total number of entries in `_fed_pending_skew`, regardless
/// of schema_version. Used to emit `RecordsHeldForMigration` after replay
/// when higher-version records still remain. Mirrors Swift
/// `SkewReplay.countHeld(from:sideTable:)`.
fn fed_skew_count_held(
    row_store: &Arc<dyn RowStore>,
) -> Result<usize, String> {
    row_store
        .count(FED_PENDING_SKEW_TABLE, None)
        .map_err(|e| e.to_string())
}

/// Purge skew-queue entries for a (table_name, row_key) pair whose stored
/// record HLC is strictly OLDER than the winning tombstone HLC.
///
/// WHY only older entries are removed:
/// A future-schema entry whose HLC is >= the tombstone represents a write
/// that postdates (or ties) the delete. On replay (after a schema update),
/// that newer record may win the LWW gate and override the delete — removing
/// it here would silence a legitimate re-create. Only entries the tombstone
/// would already defeat on replay are safe to discard.
///
/// P5-M1b parity: mirrors Swift
/// `PendingSkewQueue.deleteMatchingOlderThan(tableName:rowKey:tombstoneHLC:from:sideTable:)`.
fn fed_skew_delete_older_than(
    row_store: &Arc<dyn RowStore>,
    table_name: &str,
    row_key: &Uuid,
    tombstone_hlc: PackedHLC,
) {
    // Query all entries for this (table_name, row_key). Per-row count is
    // typically 0–2, so decoding all payloads to compare HLCs is inexpensive.
    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new(FED_PENDING_SKEW_TABLE.to_string(), "table_name".to_string()),
            TypedValue::Text(table_name.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new(FED_PENDING_SKEW_TABLE.to_string(), "row_key".to_string()),
            TypedValue::Text(row_key.to_string()),
        ),
    ]);
    let rows = match row_store.query(FED_PENDING_SKEW_TABLE, Some(&predicate), &[], None, None) {
        Ok(r) => r,
        Err(_) => return,
    };
    let tombstone: HLC = tombstone_hlc.into();
    for row in rows {
        let id = match row.get("id") {
            Some(TypedValue::Uuid(u)) => *u,
            _ => continue,
        };
        let payload = match row.get("payload") {
            Some(TypedValue::Blob(b)) => b.clone(),
            _ => continue,
        };
        let record: SyncRecord = match serde_json::from_slice(&payload) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let record_hlc: HLC = record.hlc.into();
        // Only purge entries that the tombstone would defeat on replay.
        // Entries with HLC >= tombstone survive (they postdate the delete).
        if record_hlc < tombstone {
            let id_pred = StoragePredicate::Eq(
                Column::new(FED_PENDING_SKEW_TABLE.to_string(), "id".to_string()),
                TypedValue::Uuid(id),
            );
            let _ = row_store.delete(FED_PENDING_SKEW_TABLE, &id_pred);
        }
    }
}

/// Format current UTC wall-clock time as an ISO8601 string.
///
/// Used for `received_at` in `_fed_pending_skew` entries so eviction ordering
/// is chronological (ISO8601 strings sort lexicographically). Mirrors Swift's
/// `ISO8601DateFormatter().string(from: Date())` used in PendingSkewQueue.enqueue.
///
/// Implemented without chrono to avoid a new dependency. Accuracy is to the
/// second; subsecond precision is not needed for eviction ordering.
fn iso8601_utc_now() -> String {
    let total_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let sec = (total_secs % 60) as u8;
    let total_mins = total_secs / 60;
    let min = (total_mins % 60) as u8;
    let total_hours = total_mins / 60;
    let hour = (total_hours % 24) as u8;
    let days = total_hours / 24;  // days since 1970-01-01
    let (year, month, day) = epoch_days_to_date(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, min, sec
    )
}

/// Convert days-since-epoch (1970-01-01) to a (year, month, day) calendar date.
/// Implements the proleptic Gregorian calendar; correct for years 1970–2099
/// (the only range relevant to received_at timestamps).
fn epoch_days_to_date(mut days: u64) -> (u32, u8, u8) {
    let mut year: u32 = 1970;
    loop {
        let days_in_year: u64 = if is_leap_year(year) { 366 } else { 365 };
        if days < days_in_year {
            break;
        }
        days -= days_in_year;
        year += 1;
    }
    let leap = is_leap_year(year);
    let month_lengths: [u8; 12] = [
        31, if leap { 29 } else { 28 },
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
    ];
    let mut month: u8 = 1;
    for &mlen in &month_lengths {
        if days < mlen as u64 {
            break;
        }
        days -= mlen as u64;
        month += 1;
    }
    (year, month, days as u8 + 1)
}

/// Returns true if `year` is a leap year in the Gregorian calendar.
fn is_leap_year(year: u32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

// ─── pure fieldLevelLWW merge logic ───────────────────────────────────────────

/// Compute which columns from an incoming record should be applied to local
/// storage, given the local column HLC state.
///
/// Port of Swift's `FieldLWWMerge.merge(incomingValues:incomingColumnHLCs:
/// incomingRowHLC:localColumnHLCs:)` — semantics are byte-identical.
///
/// For each column in `incoming_values`:
///   - Use the per-column HLC from `incoming_column_hlcs` if present; fall back
///     to `incoming_row_hlc` (backward-compat: sender omits column HLCs).
///   - Apply the column iff incoming HLC >= local column HLC (first write if
///     local has no entry for that column).
///
/// COMMUTATIVITY: identical to Swift — applying A then B, or B then A,
/// produces the same per-column result because ties (`>=` on equal HLCs)
/// resolve identically in both orderings.
///
/// Returns `(columns_to_apply, updated_column_hlcs)`. The caller must:
///   1. Apply `columns_to_apply` to the application row (upsert).
///   2. Persist `updated_column_hlcs` to `_fed_sync_meta_cols`.
fn field_lww_merge(
    incoming_values: BTreeMap<String, TypedValue>,
    incoming_column_hlcs: &ColumnHLCMap,
    incoming_row_hlc: PackedHLC,
    local_column_hlcs: &ColumnHLCMap,
) -> (BTreeMap<String, TypedValue>, ColumnHLCMap) {
    let mut columns_to_apply: BTreeMap<String, TypedValue> = BTreeMap::new();
    let mut updated_entries = local_column_hlcs.entries.clone();

    for (column, value) in incoming_values {
        // Prefer per-column HLC from sender; fall back to row-grain HLC when
        // the sender does not support fieldLevelLWW (backward-compat).
        let incoming_col_hlc: PackedHLC = incoming_column_hlcs
            .entries
            .get(&column)
            .copied()
            .unwrap_or(incoming_row_hlc);

        let should_apply = match local_column_hlcs.entries.get(&column) {
            // Apply iff incoming HLC >= local HLC.
            // Ties (>=, not >) go to incoming so convergence is guaranteed
            // when two replicas simultaneously write the same HLC.
            Some(&local_hlc) => incoming_col_hlc >= local_hlc,
            // No local HLC for this column — first write always wins.
            None => true,
        };

        if should_apply {
            columns_to_apply.insert(column.clone(), value);
            // Advance stored HLC to the winner.
            updated_entries.insert(column, incoming_col_hlc);
        }
    }

    (columns_to_apply, ColumnHLCMap { entries: updated_entries })
}

/// Decide whether an incoming tombstone should delete the local row.
///
/// Port of Swift's `FieldLWWMerge.tombstoneWins(tombstoneHLC:localColumnHLCs:)`.
///
/// The tombstone wins (returns `true`, caller should delete) iff its HLC is
/// >= ALL local per-column HLCs. If even one column has an HLC strictly greater
/// than the tombstone, the row was edited after the delete — the edit wins
/// and the row is preserved (edit-beats-delete).
///
/// WHY empty local map → tombstone wins:
/// An empty `local_column_hlcs` means this row has never been written under
/// fieldLevelLWW (e.g., created before the policy was enabled). There are no
/// column-grain edits to protect, so the tombstone wins unconditionally.
fn tombstone_wins(tombstone_hlc: PackedHLC, local_column_hlcs: &ColumnHLCMap) -> bool {
    if local_column_hlcs.is_empty() {
        return true;
    }
    // Tombstone wins iff its HLC is >= every local column HLC.
    // A single column with a strictly higher HLC keeps the row alive.
    for (_, &local_hlc) in &local_column_hlcs.entries {
        if local_hlc > tombstone_hlc {
            return false; // edit-beats-delete: this column was written more recently
        }
    }
    true
}

// ─── unit tests (pure merge logic) ────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use persistence_kit::inmemory::InMemoryStorage;
    use std::collections::BTreeMap;

    // ── tombstone GC test helpers ────────────────────────────────────────────

    /// Fresh storage with `_fed_sync_meta` (and `_fed_sync_meta_cols`) initialised.
    fn make_gc_storage() -> Arc<dyn Storage> {
        let s = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        ensure_fed_sync_meta_table(&*s).expect("ensure_fed_sync_meta_table");
        s
    }

    /// Count rows in `_fed_sync_meta` matching a predicate.
    fn count_meta_rows(row_store: &Arc<dyn RowStore>, predicate: Option<&StoragePredicate>) -> usize {
        row_store
            .query(FED_SYNC_META_TABLE, predicate, &[], None, None)
            .map(|r| r.len())
            .unwrap_or(0)
    }

    /// Count tombstone rows (`is_deleted = 1`) in `_fed_sync_meta`.
    fn count_tombstones(row_store: &Arc<dyn RowStore>) -> usize {
        let pred = StoragePredicate::Eq(
            Column::new(FED_SYNC_META_TABLE.to_string(), "is_deleted".to_string()),
            TypedValue::Int(1),
        );
        count_meta_rows(row_store, Some(&pred))
    }

    // ── tombstone GC tests ───────────────────────────────────────────────────

    /// GC compacts a tombstone that is past the 90 d retention window.
    ///
    /// Mirrors Swift `TombstoneGCRetentionInvariantTests`.
    #[test]
    fn gc_compact_when_due() {
        let storage = make_gc_storage();
        let row_store = storage.row_store();

        // now_ms small enough that arithmetic stays below 2^40.
        let now_ms: i64 = 10_000_000_000;
        // Tombstone physical time: just past the 90 d retention boundary.
        let past_retention_ms = now_ms - TOMBSTONE_GC_RETENTION_SECS * 1_000 - 1;
        let old_hlc = HLC { physical_time: past_retention_ms, logical_count: 0, node_id: 1 };

        // Write a tombstone entry for a fake row.
        let row_key = Uuid::new_v4();
        write_fed_tombstone_hlc(&row_store, "test_items", &row_key, old_hlc)
            .expect("write tombstone");
        assert_eq!(count_tombstones(&row_store), 1, "tombstone must exist before GC");

        // Sentinel = 0 (no prior GC run) → interval check passes immediately.
        gc_if_due(&row_store, now_ms);

        assert_eq!(
            count_tombstones(&row_store),
            0,
            "tombstone older than 90 d must be compacted"
        );
        // Sentinel must be updated to now_ms.
        assert_eq!(
            read_gc_sentinel_ms(&row_store),
            now_ms,
            "sentinel must record the GC run timestamp"
        );
    }

    /// GC skips compaction when the 24 h interval has not elapsed.
    #[test]
    fn gc_skip_when_not_due() {
        let storage = make_gc_storage();
        let row_store = storage.row_store();

        let now_ms: i64 = 10_000_000_000;
        // Old tombstone — past retention, would be compacted if GC ran.
        let past_retention_ms = now_ms - TOMBSTONE_GC_RETENTION_SECS * 1_000 - 1;
        let old_hlc = HLC { physical_time: past_retention_ms, logical_count: 0, node_id: 1 };
        let row_key = Uuid::new_v4();
        write_fed_tombstone_hlc(&row_store, "test_items", &row_key, old_hlc)
            .expect("write tombstone");

        // Sentinel = 1 second ago — interval has NOT elapsed (need 24 h = 86_400_000 ms).
        write_gc_sentinel_ms(&row_store, now_ms - 1_000);

        gc_if_due(&row_store, now_ms);

        assert_eq!(
            count_tombstones(&row_store),
            1,
            "tombstone must survive when GC interval has not elapsed"
        );
    }

    /// A tombstone inside the 90 d retention window is kept by compact.
    #[test]
    fn gc_inside_retention_survives() {
        let storage = make_gc_storage();
        let row_store = storage.row_store();

        let now_ms: i64 = 10_000_000_000;
        // Recent tombstone: 1 day ago — well within the 90 d window.
        let recent_ms = now_ms - 86_400_000;
        let recent_hlc = HLC { physical_time: recent_ms, logical_count: 0, node_id: 1 };
        let row_key = Uuid::new_v4();
        write_fed_tombstone_hlc(&row_store, "test_items", &row_key, recent_hlc)
            .expect("write recent tombstone");

        // Sentinel = 0 → GC interval passes; compact will run.
        gc_if_due(&row_store, now_ms);

        assert_eq!(
            count_tombstones(&row_store),
            1,
            "tombstone inside the 90 d retention window must not be compacted"
        );
    }

    /// The GC sentinel row survives tombstone_compact (it has is_deleted = 0).
    ///
    /// `tombstone_compact` queries `WHERE is_deleted = 1`. The sentinel row has
    /// `is_deleted = 0`, so the query never sees it — it cannot be accidentally
    /// swept even when compact is called directly.
    #[test]
    fn gc_sentinel_survives_compaction() {
        let storage = make_gc_storage();
        let row_store = storage.row_store();

        let now_ms: i64 = 10_000_000_000;
        write_gc_sentinel_ms(&row_store, now_ms);

        // Run compact with no tombstones — sentinel must be untouched.
        tombstone_compact(&row_store, now_ms);

        let sentinel_ms = read_gc_sentinel_ms(&row_store);
        assert_eq!(
            sentinel_ms, now_ms,
            "sentinel row must survive tombstone_compact (is_deleted = 0 is invisible to the sweep)"
        );
    }

    /// 2026-scale packed-HLC regression: a tombstone from 1 day ago must NOT be
    /// compacted when now_ms exceeds 2^40 and both sides of the cutoff comparison
    /// are correctly masked to 40 bits.
    ///
    /// Without the 40-bit mask on the cutoff, any packed physical time (which IS
    /// already masked to 40 bits) would appear older than the unmasked cutoff
    /// (~1.76e12), causing every tombstone to be silently compacted — destroying
    /// the A6 stale-resurrect guard. This is the same failure class as the
    /// SlotTable eviction bug (Perkins P4-M4 finding). The mask on both sides
    /// wraps the comparison into the same 40-bit space so tombstones within the
    /// retention window are correctly identified.
    ///
    /// Approximate 2026-07-17 wall-clock: 1_766_779_200_000 ms > 2^40 (1_099_511_627_776).
    /// Physical time in the stored packed HLC is masked to 40 bits:
    ///   stored_physical = tombstone_physical_time & 0xFF_FFFF_FFFF
    ///   Without mask: cutoff ≈ 1.76e12 > any 40-bit stored value → all compacted (BUG).
    ///   With mask:    cutoff & 0xFF_FFFF_FFFF < stored_physical → tombstone kept (CORRECT).
    #[test]
    fn gc_2026_scale_packed_hlc_regression() {
        let storage = make_gc_storage();
        let row_store = storage.row_store();

        // Approximate 2026-07-17 wall-clock ms. Exceeds 2^40 = 1_099_511_627_776.
        let now_ms: i64 = 1_766_779_200_000;

        // Tombstone minted 1 day ago — physical_time > 2^40, so the HLC packer
        // truncates it to 40 bits when storing sync_hlc.
        let tombstone_physical = now_ms - 86_400_000; // 1 day ago, still within 90 d
        let recent_hlc = HLC { physical_time: tombstone_physical, logical_count: 0, node_id: 1 };
        let row_key = Uuid::new_v4();
        write_fed_tombstone_hlc(&row_store, "test_items", &row_key, recent_hlc)
            .expect("write 2026-scale tombstone");

        // Sentinel = 0 → GC runs. If the mask is absent on the cutoff,
        // the tombstone would be incorrectly compacted here.
        gc_if_due(&row_store, now_ms);

        assert_eq!(
            count_tombstones(&row_store),
            1,
            "2026-scale tombstone 1 day old must survive (within 90 d retention) — \
             failure means the 40-bit mask is missing from the cutoff comparison"
        );

        // Also verify the invariant directly: retention must strictly exceed the
        // slot-eviction long window (30 d = 2_592_000 s).
        // If this assertion fails, the constants drifted and the GC window is broken.
        let slot_eviction_long_window_secs: i64 = 30 * 24 * 3_600; // 2_592_000 s
        assert!(
            TOMBSTONE_GC_RETENTION_SECS > slot_eviction_long_window_secs,
            "TOMBSTONE_GC_RETENTION_SECS ({}) must strictly exceed the slot-eviction \
             long window ({}) — equality is insufficient (race at window boundary)",
            TOMBSTONE_GC_RETENTION_SECS,
            slot_eviction_long_window_secs
        );
    }

    fn hlc(physical_time: i64, logical: i32, node: i32) -> PackedHLC {
        PackedHLC { physical_time, logical_count: logical, node_id: node }
    }

    fn col_map(pairs: &[(&str, PackedHLC)]) -> ColumnHLCMap {
        let mut entries = BTreeMap::new();
        for (col, h) in pairs {
            entries.insert(col.to_string(), *h);
        }
        ColumnHLCMap { entries }
    }

    // ── field_lww_merge ──────────────────────────────────────────────────────

    /// Disjoint columns: each replica contributes a column the other lacks.
    /// After merge, both columns survive in the result (and both appear in
    /// updated_column_hlcs). Mirrors Swift's disjoint-column test case.
    #[test]
    fn merge_disjoint_columns_both_survive() {
        // Incoming record has column "title" at T=200.
        let mut incoming_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        incoming_values.insert("title".to_string(), TypedValue::Text("Hello".to_string()));
        let incoming_col_hlcs = col_map(&[("title", hlc(200, 0, 1))]);

        // Local has column "body" at T=100 (different column, no conflict).
        let local_col_hlcs = col_map(&[("body", hlc(100, 0, 1))]);

        let (apply, updated) = field_lww_merge(
            incoming_values,
            &incoming_col_hlcs,
            hlc(200, 0, 1),
            &local_col_hlcs,
        );

        // "title" must be applied (no local HLC → first write wins).
        assert_eq!(
            apply.get("title"),
            Some(&TypedValue::Text("Hello".to_string())),
            "incoming disjoint column must be applied"
        );
        // "body" is not in incoming_values, so it's untouched.
        assert!(!apply.contains_key("body"), "local-only column must not appear in apply set");

        // updated_column_hlcs must contain both: "title" at T=200, "body" retained at T=100.
        assert_eq!(updated.entries.get("title"), Some(&hlc(200, 0, 1)));
        assert_eq!(updated.entries.get("body"),  Some(&hlc(100, 0, 1)));
    }

    /// Same column, newest HLC wins — incoming T=200 beats local T=100.
    /// Mirrors Swift's "same-column newest wins" test case.
    #[test]
    fn merge_same_column_newest_wins() {
        let mut incoming: BTreeMap<String, TypedValue> = BTreeMap::new();
        incoming.insert("title".to_string(), TypedValue::Text("Newer".to_string()));
        let incoming_col_hlcs = col_map(&[("title", hlc(200, 0, 1))]);

        let local_col_hlcs = col_map(&[("title", hlc(100, 0, 1))]);

        let (apply, updated) = field_lww_merge(
            incoming,
            &incoming_col_hlcs,
            hlc(200, 0, 1),
            &local_col_hlcs,
        );

        // Incoming wins (T=200 > T=100).
        assert_eq!(
            apply.get("title"),
            Some(&TypedValue::Text("Newer".to_string())),
            "incoming column with higher HLC must win"
        );
        assert_eq!(updated.entries.get("title"), Some(&hlc(200, 0, 1)));
    }

    /// Same column, stale incoming (T=50 < local T=100) — local wins, column NOT applied.
    #[test]
    fn merge_same_column_stale_incoming_loses() {
        let mut incoming: BTreeMap<String, TypedValue> = BTreeMap::new();
        incoming.insert("title".to_string(), TypedValue::Text("Stale".to_string()));
        let incoming_col_hlcs = col_map(&[("title", hlc(50, 0, 1))]);

        let local_col_hlcs = col_map(&[("title", hlc(100, 0, 1))]);

        let (apply, updated) = field_lww_merge(
            incoming,
            &incoming_col_hlcs,
            hlc(50, 0, 1),
            &local_col_hlcs,
        );

        // Stale incoming must not overwrite local.
        assert!(apply.is_empty(), "stale incoming column must not be applied");
        // Local HLC must be unchanged.
        assert_eq!(updated.entries.get("title"), Some(&hlc(100, 0, 1)));
    }

    /// Tie (equal HLCs) — incoming wins (>= semantics, not >).
    /// Equal-HLC ties resolve to incoming to guarantee eventual convergence.
    #[test]
    fn merge_tie_incoming_wins() {
        let mut incoming: BTreeMap<String, TypedValue> = BTreeMap::new();
        incoming.insert("title".to_string(), TypedValue::Text("Tie-wins".to_string()));
        let tie_hlc = hlc(100, 0, 1);
        let incoming_col_hlcs = col_map(&[("title", tie_hlc)]);
        let local_col_hlcs   = col_map(&[("title", tie_hlc)]);

        let (apply, _) = field_lww_merge(
            incoming,
            &incoming_col_hlcs,
            tie_hlc,
            &local_col_hlcs,
        );

        // Tie → incoming wins (>= semantics).
        assert!(apply.contains_key("title"), "tie must resolve to incoming (>= semantics)");
    }

    /// Commutativity property: merge(A over B) and merge(B over A) must agree
    /// on which value each column holds when the HLCs differ.
    /// Mirrors Swift's commutativity property test with seeded orders.
    #[test]
    fn merge_commutativity_property() {
        // A has "title" at T=200, "body" at T=50.
        let mut a_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        a_values.insert("title".to_string(), TypedValue::Text("A-title".to_string()));
        a_values.insert("body".to_string(),  TypedValue::Text("A-body".to_string()));
        let a_col_hlcs = col_map(&[("title", hlc(200, 0, 1)), ("body", hlc(50, 0, 1))]);

        // B has "title" at T=100, "body" at T=300.
        let mut b_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        b_values.insert("title".to_string(), TypedValue::Text("B-title".to_string()));
        b_values.insert("body".to_string(),  TypedValue::Text("B-body".to_string()));
        let b_col_hlcs = col_map(&[("title", hlc(100, 0, 1)), ("body", hlc(300, 0, 1))]);

        // Order 1: start with A's state, apply B on top.
        let (apply_b_over_a, final_b_over_a) = field_lww_merge(
            b_values.clone(),
            &b_col_hlcs,
            hlc(300, 0, 1),
            &a_col_hlcs,
        );
        // Now take A as winner where A won, fold in B's apply set.
        // Build state_after_b_over_a: start with A's values, overwrite with apply set.
        let mut state_b_over_a: BTreeMap<String, String> = BTreeMap::new();
        state_b_over_a.insert("title".to_string(), "A-title".to_string()); // A wins title
        state_b_over_a.insert("body".to_string(),  "A-body".to_string());  // A initial
        for (k, v) in &apply_b_over_a {
            if let TypedValue::Text(s) = v {
                state_b_over_a.insert(k.clone(), s.clone());
            }
        }

        // Order 2: start with B's state, apply A on top.
        let (apply_a_over_b, final_a_over_b) = field_lww_merge(
            a_values.clone(),
            &a_col_hlcs,
            hlc(200, 0, 1),
            &b_col_hlcs,
        );
        let mut state_a_over_b: BTreeMap<String, String> = BTreeMap::new();
        state_a_over_b.insert("title".to_string(), "B-title".to_string()); // B initial
        state_a_over_b.insert("body".to_string(),  "B-body".to_string());  // B wins body
        for (k, v) in &apply_a_over_b {
            if let TypedValue::Text(s) = v {
                state_a_over_b.insert(k.clone(), s.clone());
            }
        }

        // Both orderings must converge on the same per-column winner:
        //   title: A wins (T=200 > T=100)
        //   body:  B wins (T=300 > T=50)
        assert_eq!(state_b_over_a["title"], "A-title", "title: A must win (T=200 > T=100)");
        assert_eq!(state_b_over_a["body"],  "B-body",  "body: B must win (T=300 > T=50)");
        assert_eq!(state_a_over_b["title"], "A-title", "commutativity: title must be same");
        assert_eq!(state_a_over_b["body"],  "B-body",  "commutativity: body must be same");

        // HLC maps must also converge.
        assert_eq!(final_b_over_a.entries["title"], hlc(200, 0, 1));
        assert_eq!(final_b_over_a.entries["body"],  hlc(300, 0, 1));
        assert_eq!(final_b_over_a, final_a_over_b, "updated HLC maps must be identical");
    }

    /// Fallback to row-grain HLC when incoming_column_hlcs is empty
    /// (backward-compat: sender does not carry per-column HLCs).
    #[test]
    fn merge_row_grain_fallback_when_no_column_hlcs() {
        let mut incoming: BTreeMap<String, TypedValue> = BTreeMap::new();
        incoming.insert("note".to_string(), TypedValue::Text("from old sender".to_string()));

        // Incoming has no column HLCs — use row-grain HLC as fallback.
        let incoming_col_hlcs = ColumnHLCMap::default();
        let row_hlc = hlc(500, 0, 1);

        // Local column HLC is older (T=100 < T=500) — incoming wins.
        let local_col_hlcs = col_map(&[("note", hlc(100, 0, 1))]);

        let (apply, _) = field_lww_merge(
            incoming,
            &incoming_col_hlcs,
            row_hlc,
            &local_col_hlcs,
        );
        assert!(apply.contains_key("note"), "row-grain fallback must allow win when row HLC is newer");

        // Now test stale row-grain fallback: row HLC older than local column.
        let mut incoming2: BTreeMap<String, TypedValue> = BTreeMap::new();
        incoming2.insert("note".to_string(), TypedValue::Text("stale old sender".to_string()));
        let (apply2, _) = field_lww_merge(
            incoming2,
            &ColumnHLCMap::default(),
            hlc(50, 0, 1),  // row HLC older than local column T=100
            &local_col_hlcs,
        );
        assert!(apply2.is_empty(), "stale row-grain fallback must not overwrite newer local column");
    }

    // ── tombstone_wins ───────────────────────────────────────────────────────

    /// Empty local column HLCs → tombstone wins unconditionally.
    /// Mirrors Swift: "An empty localColumnHLCs means this row has never been
    /// written under fieldLevelLWW — tombstone wins unconditionally."
    #[test]
    fn tombstone_wins_empty_local_map() {
        assert!(
            tombstone_wins(hlc(100, 0, 1), &ColumnHLCMap::default()),
            "tombstone must win when local column HLC map is empty"
        );
    }

    /// Tombstone HLC >= all local column HLCs → tombstone wins.
    #[test]
    fn tombstone_wins_when_hlc_ge_all_columns() {
        let local = col_map(&[
            ("title", hlc(100, 0, 1)),
            ("body",  hlc(80,  0, 1)),
        ]);
        // Tombstone at T=100 equals the highest column HLC (>= semantics).
        assert!(
            tombstone_wins(hlc(100, 0, 1), &local),
            "tombstone at T=100 must beat all local columns (max local HLC = 100, >= semantics)"
        );
        // Tombstone at T=200 clearly beats all.
        assert!(
            tombstone_wins(hlc(200, 0, 1), &local),
            "tombstone at T=200 must beat all local columns"
        );
    }

    /// One local column HLC strictly greater than tombstone → tombstone loses.
    /// This is the "edit-beats-delete" case: the row was edited after the delete.
    #[test]
    fn tombstone_loses_when_one_column_newer() {
        let local = col_map(&[
            ("title", hlc(50,  0, 1)),
            ("body",  hlc(200, 0, 1)), // newer than tombstone
        ]);
        // Tombstone at T=100 loses because "body" is at T=200.
        assert!(
            !tombstone_wins(hlc(100, 0, 1), &local),
            "tombstone must lose when one local column (body at T=200) is newer"
        );
    }

    /// All local columns equal to tombstone HLC — tombstone wins (>= semantics).
    #[test]
    fn tombstone_wins_on_exact_tie() {
        let tie = hlc(100, 0, 1);
        let local = col_map(&[("title", tie), ("body", tie)]);
        assert!(
            tombstone_wins(tie, &local),
            "tombstone must win on exact tie with all columns (>= semantics)"
        );
    }

    // ── cross-leg golden (ColumnHLCMap wire format) ──────────────────────────

    /// Verify that the Rust decoder accepts a JSON string produced by Swift's
    /// JSONEncoder for a ColumnHLCMap. The Swift golden was generated with:
    ///   JSONEncoder().encode(ColumnHLCMap(entries: [
    ///       "colA": PackedHLC(physicalTime: 100, logicalCount: 0, nodeID: 1),
    ///       "colB": PackedHLC(physicalTime: 200, logicalCount: 5, nodeID: 3),
    ///   ]))
    /// Swift's JSONEncoder sorts dictionary keys alphabetically, producing
    /// "colA" before "colB" — matching Rust's BTreeMap serialisation.
    #[test]
    fn column_hlc_map_cross_leg_golden() {
        let golden = r#"{"entries":{"colA":{"physicalTime":100,"logicalCount":0,"nodeID":1},"colB":{"physicalTime":200,"logicalCount":5,"nodeID":3}}}"#;
        let map: ColumnHLCMap = serde_json::from_str(golden)
            .expect("Rust must decode Swift-golden ColumnHLCMap JSON");

        let col_a = map.entries.get("colA").expect("colA must be present");
        let col_b = map.entries.get("colB").expect("colB must be present");
        assert_eq!(col_a.physical_time, 100, "colA physical_time");
        assert_eq!(col_a.logical_count, 0,   "colA logical_count");
        assert_eq!(col_a.node_id, 1,          "colA node_id");
        assert_eq!(col_b.physical_time, 200, "colB physical_time");
        assert_eq!(col_b.logical_count, 5,   "colB logical_count");
        assert_eq!(col_b.node_id, 3,          "colB node_id");

        // Round-trip: Rust output must be byte-identical to the golden.
        let encoded = serde_json::to_string(&map).expect("Rust must encode ColumnHLCMap");
        assert_eq!(
            encoded, golden,
            "Rust-encoded ColumnHLCMap must be byte-identical to the Swift golden"
        );
    }
}
