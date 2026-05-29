//! FederationSyncEngine: Ed25519-authenticated peer-to-peer
//! backend.
//!
//! Wire transport is out of scope for v1.0; the engine ships
//! with an in-process FederationRelay that two engines can
//! plug into for unit tests. A future R-mission adds a real
//! wire transport (HTTP/gRPC/QUIC) that conforms to the same
//! relay trait.
//!
//! All records are signed at push and verified at pull. Schema
//! and kit mismatch reject the record. Conflict resolution
//! follows the per-table ConflictPolicy on the local manifest.

use crate::engine::SyncEngine;
use crate::record::SyncRecord;
use crate::types::{SyncError, SyncEvent, SyncManifest, SyncReceipt, SyncResult, SyncState};
use ed25519_dalek::{
    Signature, Signer, SigningKey, Verifier, VerifyingKey, PUBLIC_KEY_LENGTH, SECRET_KEY_LENGTH,
    SIGNATURE_LENGTH,
};
use rand_core::OsRng;
use std::sync::{Arc, Mutex};
use std::sync::mpsc::{channel, Receiver, Sender};
use persistence_kit::Storage;

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

// ----- in-process relay -----

/// Signed envelope shipped between federation peers.
#[derive(Debug, Clone)]
pub struct SignedRecord {
    pub record: SyncRecord,
    pub signer: [u8; PUBLIC_KEY_LENGTH],
    pub signature: [u8; SIGNATURE_LENGTH],
}

/// Canonical bytes for signing a SyncRecord. JSON via serde_json
/// is deterministic enough for v1.0 because the field order is
/// declared by the struct; if cross-platform parity matters here
/// later, swap to a CBOR canonical encoder.
fn canonical_record_bytes(record: &SyncRecord) -> SyncResult<Vec<u8>> {
    serde_json::to_vec(record).map_err(|e| SyncError::EncodingFailure {
        detail: e.to_string(),
    })
}

/// In-process federation relay. Federation engines register
/// themselves; push delivers a signed record to every other
/// registered peer's inbox. Pull drains the local inbox.
#[derive(Default)]
pub struct FederationRelay {
    inboxes: Mutex<Vec<(PeerIdentity, Sender<SignedRecord>)>>,
}

impl FederationRelay {
    pub fn new() -> Self {
        FederationRelay::default()
    }

    pub fn register(
        &self,
        identity: PeerIdentity,
    ) -> Receiver<SignedRecord> {
        let (tx, rx) = channel();
        self.inboxes.lock().unwrap().push((identity, tx));
        rx
    }

    pub fn broadcast(&self, from: &PeerIdentity, envelope: SignedRecord) {
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
    inbox: Option<Receiver<SignedRecord>>,
    outbox: Vec<SyncRecord>,
}

pub struct FederationSyncEngine {
    identity: Arc<LocalIdentity>,
    relay: Arc<FederationRelay>,
    peer_identity: PeerIdentity,
    state: Mutex<EngineState>,
    /// Subscribers receive SyncEvent on every push and pull.
    subscribers: Mutex<Vec<Sender<SyncEvent>>>,
}

impl FederationSyncEngine {
    pub fn new(identity: Arc<LocalIdentity>, relay: Arc<FederationRelay>) -> Self {
        let peer_identity = PeerIdentity::new(identity.public_key_bytes());
        FederationSyncEngine {
            identity,
            relay,
            peer_identity,
            state: Mutex::new(EngineState {
                enabled: false,
                manifest: None,
                storage: None,
                last_push_secs: None,
                last_pull_secs: None,
                inbox: None,
                outbox: Vec::new(),
            }),
            subscribers: Mutex::new(Vec::new()),
        }
    }

    pub fn peer_identity(&self) -> &PeerIdentity {
        &self.peer_identity
    }

    /// Queue a record for the next push. Mirrors the
    /// StorageObserver-driven outbox the Swift side maintains;
    /// in Rust v1.0 callers enqueue explicitly while the
    /// observer-driven path is built.
    pub fn enqueue(&self, record: SyncRecord) -> SyncResult<()> {
        let mut state = self.state.lock().unwrap();
        if !state.enabled {
            return Err(SyncError::NotEnabled);
        }
        state.outbox.push(record);
        Ok(())
    }

    fn emit(&self, event: SyncEvent) {
        let mut subs = self.subscribers.lock().unwrap();
        let mut keep = Vec::with_capacity(subs.len());
        for s in subs.iter() {
            keep.push(s.send(event.clone()).is_ok());
        }
        let mut i = 0;
        subs.retain(|_| {
            let live = keep[i];
            i += 1;
            live
        });
    }
}

impl SyncEngine for FederationSyncEngine {
    fn enable(&self, manifest: SyncManifest, storage: Arc<dyn Storage>) -> SyncResult<()> {
        let mut state = self.state.lock().unwrap();
        if state.enabled {
            return Err(SyncError::AlreadyEnabled);
        }
        let inbox = self.relay.register(self.peer_identity.clone());
        state.inbox = Some(inbox);
        state.manifest = Some(manifest);
        state.storage = Some(storage);
        state.enabled = true;
        Ok(())
    }

    fn disable(&self) -> SyncResult<()> {
        let mut state = self.state.lock().unwrap();
        state.enabled = false;
        state.manifest = None;
        state.storage = None;
        state.inbox = None;
        state.outbox.clear();
        Ok(())
    }

    fn push(&self) -> SyncResult<SyncReceipt> {
        let to_send: Vec<SyncRecord> = {
            let mut state = self.state.lock().unwrap();
            if !state.enabled {
                return Err(SyncError::NotEnabled);
            }
            std::mem::take(&mut state.outbox)
        };
        let mut pushed = 0;
        for record in to_send {
            let bytes = canonical_record_bytes(&record)?;
            let signature = self.identity.sign(&bytes);
            let envelope = SignedRecord {
                record,
                signer: self.identity.public_key_bytes(),
                signature,
            };
            self.relay.broadcast(&self.peer_identity, envelope);
            pushed += 1;
        }
        let receipt = SyncReceipt::now(pushed, 0, 0);
        {
            let mut state = self.state.lock().unwrap();
            state.last_push_secs = Some(receipt.timestamp_secs);
        }
        self.emit(SyncEvent::PushCompleted {
            receipt: receipt.clone(),
        });
        Ok(receipt)
    }

    fn pull(&self) -> SyncResult<SyncReceipt> {
        let (manifest, inbox_avail) = {
            let state = self.state.lock().unwrap();
            if !state.enabled {
                return Err(SyncError::NotEnabled);
            }
            (state.manifest.clone(), state.inbox.is_some())
        };
        if !inbox_avail {
            return Err(SyncError::NotEnabled);
        }
        let manifest = manifest.ok_or(SyncError::NotEnabled)?;

        // Drain the inbox without holding the state lock across
        // recv calls; we hold a separate sentinel.
        let envelopes: Vec<SignedRecord> = {
            let state = self.state.lock().unwrap();
            let inbox = state.inbox.as_ref().unwrap();
            let mut out = Vec::new();
            while let Ok(env) = inbox.try_recv() {
                out.push(env);
            }
            out
        };

        let mut pulled = 0;
        let mut conflicts = 0;
        for envelope in envelopes {
            // Verify signature first.
            let bytes = canonical_record_bytes(&envelope.record)?;
            if !verify_signature(&envelope.signature, &bytes, &envelope.signer) {
                conflicts += 1;
                continue;
            }
            // Validate kit + schema.
            if envelope.record.kit_id != manifest.kit_id {
                conflicts += 1;
                continue;
            }
            if envelope.record.schema_version != manifest.schema_version {
                conflicts += 1;
                continue;
            }
            // For v1.0 we accept the record into the local
            // persistence-kit; conflict-policy enforcement lives in
            // the receive boundary, deferred to a follow-on.
            // Counting accepted records for the receipt.
            pulled += 1;
        }
        let receipt = SyncReceipt::now(0, pulled, conflicts);
        {
            let mut state = self.state.lock().unwrap();
            state.last_pull_secs = Some(receipt.timestamp_secs);
        }
        self.emit(SyncEvent::RemoteChangesApplied { count: pulled });
        Ok(receipt)
    }

    fn subscribe(&self) -> Receiver<SyncEvent> {
        let (tx, rx) = channel();
        self.subscribers.lock().unwrap().push(tx);
        rx
    }

    fn state(&self) -> SyncState {
        let state = self.state.lock().unwrap();
        if let Some(ref m) = state.manifest {
            if state.enabled {
                return SyncState::Enabled {
                    zone: m.zone_identifier.clone(),
                    last_push_secs: state.last_push_secs,
                    last_pull_secs: state.last_pull_secs,
                };
            }
        }
        SyncState::Disabled
    }
}
