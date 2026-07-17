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
use crate::record::{PackedHLC, SyncEventKind, SyncRecord, SyncValueMap};
use crate::types::{ConflictPolicy, SyncDirection, SyncedTable, SyncError, SyncEvent, SyncManifest, SyncReceipt, SyncResult, SyncState};
use substrate_types::hlc::{HLC, HLCGenerator};
use ed25519_dalek::{
    Signature, Signer, SigningKey, Verifier, VerifyingKey, PUBLIC_KEY_LENGTH, SECRET_KEY_LENGTH,
    SIGNATURE_LENGTH,
};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use persistence_kit::{Column, RowStore, Storage, StorageEvent, StoragePredicate, TableChange, TypedValue};

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
/// `SyncRecordBatch` (0x01) is the only v1.0 variant. `FieldWriteEventBatch`
/// (0x02) is reserved for the next-gen write-path payload (C1 extension point).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum PayloadKind {
    /// A JSON-encoded array of `SyncRecord` values. The only v1.0 payload.
    SyncRecordBatch = 0x01,
    // FieldWriteEventBatch = 0x02  — reserved; add when FieldWriteEvent
    // wire format lands. Do not assign 0x02 to anything else.
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

    /// Pair with another engine. Both sides must call `pair` on each other
    /// (symmetric). After pairing, `push` will route envelopes through the
    /// relay; before pairing, `push` returns an empty receipt.
    ///
    /// Note: this method records only the caller-side peer. Swift's
    /// `FederationSyncEngine.pair(with:via:family:)` also registers the peer
    /// symmetrically through `acceptPeering`.
    pub fn pair(
        &mut self,
        peer: &FederationSyncEngine,
        family: crate::pairing::HyperplaneFamilySpec,
    ) -> SyncResult<()> {
        let peer_pk = peer.identity.public_key_bytes();
        self.state.paired_peers.push(PairedPeer {
            public_key: peer_pk,
            family,
        });
        self.emit(SyncEvent::PeerConnected {
            identity: format!("{:?}", &peer_pk[..8]),
        });
        Ok(())
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
                                change_to_record(change, schema_version, &kit_id, &hlc_generator)
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
        // Ensure the _fed_sync_meta side table exists before any apply. Mirrors
        // the Swift engine's ensureFedSyncMetaTable call in enable() (A6 unification).
        ensure_fed_sync_meta_table(&*storage)
            .map_err(|e| SyncError::TransportFailure { detail: format!("ensure _fed_sync_meta: {}", e) })?;
        // Subscribe the observer workers BEFORE marking enabled so the
        // write-capture path is live the moment the engine reports enabled.
        self.start_observers(&manifest, &storage)?;
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

            // Reject unknown payload kinds to avoid misinterpreting future
            // payload types. Known: SyncRecordBatch. Unknown kinds are
            // counted as conflicts; no panic.
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
                if record.schema_version != manifest.schema_version {
                    conflicts += 1;
                    continue;
                }
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
                    Ok(()) => { pulled += 1; }
                    Err(_) => { conflicts += 1; }
                }
            }
        }
        // Clear the pull guard: local writes from this point forward are user
        // mutations and must be captured by the observer workers as normal.
        self.state.pulling.store(false, Ordering::Release);

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

/// Side table name for Federation sync HLC storage (A6 unification).
/// Mirrors `_ck_sync_meta` in the CloudKit engine.
const FED_SYNC_META_TABLE: &str = "_fed_sync_meta";

/// Ensure the `_fed_sync_meta` side table exists.
///
/// Called from `enable()` before any `apply_record`. Mirrors Swift's
/// `FederationStateActor.ensureFedSyncMetaTable`. Uses `storage.migrate()`
/// which is forward-only and idempotent when the schema version already matches.
///
/// Returns an error string on failure (caller converts to SyncError).
fn ensure_fed_sync_meta_table(storage: &dyn Storage) -> Result<(), String> {
    use persistence_kit::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
    let schema = SchemaDeclaration::new(
        "ConvergenceKitFederation",
        1,
        vec![TableDeclaration::new(
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
        )],
    );
    storage.migrate(&schema).map_err(|e| e.to_string())
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
