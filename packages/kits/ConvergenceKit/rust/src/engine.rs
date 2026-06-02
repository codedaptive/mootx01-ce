//! SyncEngine trait. Mirror of Swift's SyncEngine protocol.
//!
//! Backends conform to this trait to provide replication. Two
//! ship at v1.0: NoSyncEngine (passthrough) and
//! FederationSyncEngine (Ed25519-authenticated peer-to-peer).
//!
//! Like PersistenceKit's Rust version, the trait is synchronous; the
//! Swift side is async because Swift actors require it.
//! Subscribe returns a std::sync::mpsc::Receiver<SyncEvent>;
//! the Swift side returns AsyncStream<SyncEvent>.

use crate::types::{SyncEvent, SyncReceipt, SyncResult, SyncState};
use crate::SyncManifest;
use std::sync::Arc;
use std::sync::mpsc::Receiver;
use persistence_kit::Storage;

// The engine owns its replication state; the mutating verbs take
// `&mut self` (idiomatic Rust ownership). `Send` lets a caller move an
// engine onto another thread; `Sync` is intentionally NOT required —
// the engine holds mpsc `Sender`/`Receiver` ends (which are `!Sync`),
// and it is driven through exclusive `&mut` access, not shared `&`.
pub trait SyncEngine: Send {
    /// Enable sync against the given manifest and storage. Must
    /// be called once before push/pull/subscribe.
    fn enable(&mut self, manifest: SyncManifest, storage: Arc<dyn Storage>) -> SyncResult<()>;

    /// Tear down subscriptions, stop observing, release resources.
    /// Idempotent.
    fn disable(&mut self) -> SyncResult<()>;

    /// One-shot push of pending local changes to the remote.
    fn push(&mut self) -> SyncResult<SyncReceipt>;

    /// One-shot pull of pending remote changes.
    fn pull(&mut self) -> SyncResult<SyncReceipt>;

    /// Long-running subscription. The receiver fires SyncEvent
    /// values as sync activity happens.
    fn subscribe(&mut self) -> Receiver<SyncEvent>;

    /// Current state for UI bindings. Read-only, so `&self`.
    fn state(&self) -> SyncState;
}
