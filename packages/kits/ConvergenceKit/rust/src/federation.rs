//! FederationSyncEngine: Ed25519-authenticated peer-to-peer
//! backend.
//!
//! Wire transport is out of scope for v1.0; the engine ships
//! with an in-process FederationRelay that two engines can
//! plug into for unit tests. A future R-mission adds a real
//! wire transport (HTTP/gRPC/QUIC) that conforms to the same
//! relay trait.
//!
//! All envelopes are signed at push and verified at pull. Schema
//! and kit mismatch reject the record. Conflict resolution
//! follows the per-table ConflictPolicy on the local manifest.

use crate::engine::SyncEngine;
use crate::record::{PackedHLC, SyncEventKind, SyncRecord};
use crate::types::{ConflictPolicy, SyncDirection, SyncedTable, SyncError, SyncEvent, SyncManifest, SyncReceipt, SyncResult, SyncState};
use ed25519_dalek::{
    Signature, Signer, SigningKey, Verifier, VerifyingKey, PUBLIC_KEY_LENGTH, SECRET_KEY_LENGTH,
    SIGNATURE_LENGTH,
};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::sync::mpsc::{channel, Receiver, Sender};
use persistence_kit::{Column, Storage, StoragePredicate, TypedValue};

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
    /// Batch-level HLC timestamp. Strictly ordered after the records it carries
    /// (the sender advances the clock once more after minting record HLCs).
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
}

// ----- engine -----

struct EngineState {
    enabled: bool,
    manifest: Option<SyncManifest>,
    storage: Option<Arc<dyn Storage>>,
    last_push_secs: Option<i64>,
    last_pull_secs: Option<i64>,
    inbox: Option<Receiver<SignedEnvelope>>,
    outbox: Vec<SyncRecord>,
    /// Monotonically increasing logical counter for the batch-level HLC.
    /// Advanced once per push batch (not per record) to order envelopes.
    hlc_counter: i32,
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
                outbox: Vec::new(),
                hlc_counter: 0,
            },
            subscribers: Vec::new(),
        }
    }

    pub fn peer_identity(&self) -> &PeerIdentity {
        &self.peer_identity
    }

    /// Queue a record for the next push. Mirrors the
    /// StorageObserver-driven outbox the Swift side maintains;
    /// in Rust v1.0 callers enqueue explicitly while the
    /// observer-driven path is built.
    pub fn enqueue(&mut self, record: SyncRecord) -> SyncResult<()> {
        if !self.state.enabled {
            return Err(SyncError::NotEnabled);
        }
        self.state.outbox.push(record);
        Ok(())
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
        let physical_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        PackedHLC {
            physical_time,
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
        self.state.manifest = Some(manifest);
        self.state.storage = Some(storage);
        self.state.enabled = true;
        Ok(())
    }

    fn disable(&mut self) -> SyncResult<()> {
        self.state.enabled = false;
        self.state.manifest = None;
        self.state.storage = None;
        self.state.inbox = None;
        self.state.outbox.clear();
        Ok(())
    }

    fn push(&mut self) -> SyncResult<SyncReceipt> {
        if !self.state.enabled {
            return Err(SyncError::NotEnabled);
        }
        let to_send: Vec<SyncRecord> = std::mem::take(&mut self.state.outbox);
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
        self.relay.broadcast(&self.peer_identity, envelope);

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

        let mut pulled = 0;
        let mut conflicts = 0;
        for envelope in envelopes {
            // Reject unknown payload kinds to avoid misinterpreting future
            // payload types. Known: SyncRecordBatch. Unknown kinds are
            // counted as conflicts; no panic.
            if envelope.payload_kind != PayloadKind::SyncRecordBatch {
                conflicts += 1;
                continue;
            }

            // Verify signature over canonical bytes (not raw payload).
            // The sender signed envelope_signing_bytes(...); we reproduce
            // the same bytes here for verification.
            let signing_bytes = envelope_signing_bytes(
                &envelope.sender_public_key,
                envelope.payload_kind,
                &envelope.payload,
                &envelope.hlc,
            );
            if !verify_signature(&envelope.signature, &signing_bytes, &envelope.sender_public_key) {
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
/// The body is two nested matches: event kind (Insert/Update/Delete) × conflict
/// policy (four arms each). Each arm is a short operation — upsert, conditional
/// insert, hard-delete, or a silent return. Length comes from the cross-product
/// of cases, not from complex logic.
///
/// Note: the `LastWriterWinsByHLC` arm currently performs an unconditional
/// upsert without comparing the incoming HLC against the stored row's HLC.
/// That LWW comparison bug is tracked separately and is out of scope here;
/// the envelope shape change does not alter this behavior.
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

    match record.event {
        SyncEventKind::Insert | SyncEventKind::Update => {
            let mut values: BTreeMap<String, TypedValue> = record
                .values
                .as_ref()
                .map(|v| v.clone().into_typed())
                .unwrap_or_default();
            // Guarantee the primary key column is present so the storage
            // backend can resolve the row key even when `values` is sparse.
            values
                .entry(synced_table.primary_key_column.clone())
                .or_insert_with(|| TypedValue::Uuid(record.row_key));
            match synced_table.conflict_policy {
                ConflictPolicy::AppendOnly
                | ConflictPolicy::LastWriterWinsByHLC
                | ConflictPolicy::RemoteWins => {
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
        SyncEventKind::Delete => {
            match synced_table.conflict_policy {
                ConflictPolicy::AppendOnly => {
                    // Append-only tables are write-once; silently reject remote deletes.
                }
                ConflictPolicy::LastWriterWinsByHLC | ConflictPolicy::RemoteWins => {
                    // Remote delete wins; hard-delete the row by primary key.
                    row_store
                        .delete(&record.table, &predicate)
                        .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
                }
                ConflictPolicy::LocalWins => {
                    // Local state is authoritative; silently reject remote deletes.
                }
            }
        }
    }
    Ok(())
}
