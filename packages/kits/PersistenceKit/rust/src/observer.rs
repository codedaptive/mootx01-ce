//! StorageObserver: change-notification primitive.
//!
//! Downstream kits subscribe to table changes to wake on writes
//! (QueueKit's watch(), Brain layer standing signals, ConvergenceKit's
//! outbound replication).
//!
//! Rust uses `std::sync::mpsc::Receiver<TableChange>` as the
//! delivery channel since Rust's async story varies by runtime;
//! synchronous channels are the lowest common denominator. The
//! Swift side returns an `AsyncStream<TableChange>`; the
//! semantics are identical (single producer per write, multiple
//! consumers via multiple subscriptions). A future tokio-based
//! Rust backend can wrap the receiver in `tokio_stream`.

use crate::error::StorageResult;
use crate::types::{RowKey, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Mutex;
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum StorageEvent {
    Insert,
    Update,
    Delete,
}

#[derive(Debug, Clone)]
pub struct TableChange {
    pub table: String,
    pub event: StorageEvent,
    pub row_key: Option<RowKey>,
    pub values: Option<BTreeMap<String, TypedValue>>,
    pub hlc: Option<HLC>,
}

// MARK: - BlobEvent / BlobChange

/// Type of blob mutation. Mirrors Swift's `BlobEvent`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlobEvent {
    Put,
    Delete,
}

/// A single blob change notification. Mirrors Swift's `BlobChange`.
///
/// `bytes` carries the payload for `Put` events (last-write-wins semantics
/// in the incremental dirty accumulator). For `Delete` events `bytes` is `None`.
#[derive(Debug, Clone)]
pub struct BlobChange {
    pub key: String,
    pub event: BlobEvent,
    /// Payload on `Put`; `None` on `Delete`.
    pub bytes: Option<Vec<u8>>,
}

// MARK: - StorageObserver trait

pub trait StorageObserver: Send + Sync {
    /// Subscribe to changes on `table` for the listed events.
    /// Multiple observers on the same table coexist.
    fn observe(
        &self,
        table: &str,
        events: BTreeSet<StorageEvent>,
    ) -> StorageResult<Receiver<TableChange>>;

    /// Subscribe to blob put/delete events.
    ///
    /// Returns a channel that delivers one `BlobChange` per put or delete
    /// on the blob store. The `NoOpObserver` and the SQLite observer return
    /// a disconnected (already-closed) receiver because `sqlite3_update_hook`
    /// does not fire for `_storagekit_blobs` (a virtual-table hook limitation).
    /// The InMemory observer delivers live events.
    fn observe_blobs(&self) -> Receiver<BlobChange> {
        // Default implementation: return a disconnected receiver.
        // Backends that support blob observation override this method.
        let (_tx, rx) = channel::<BlobChange>();
        rx
    }
}

/// A no-op observer that produces empty receivers. Mirror of
/// Swift's `NoOpObserver`. Useful when the backend does not
/// support change notification.
pub struct NoOpObserver;

impl NoOpObserver {
    pub fn new() -> Self {
        NoOpObserver
    }
}

impl Default for NoOpObserver {
    fn default() -> Self {
        Self::new()
    }
}

impl StorageObserver for NoOpObserver {
    fn observe(
        &self,
        _table: &str,
        _events: BTreeSet<StorageEvent>,
    ) -> StorageResult<Receiver<TableChange>> {
        let (_tx, rx) = channel::<TableChange>();
        // _tx is dropped immediately so rx receives no events and
        // returns Disconnected on first recv. Mirrors Swift's
        // immediate `continuation.finish()`.
        Ok(rx)
    }
    // observe_blobs() uses the default (disconnected) implementation.
}

// MARK: - BlobObserverHub

/// Channel multiplexer for blob events. Parallel to `ObserverHub` but
/// for `BlobChange` notifications. Used by `InMemoryStorage` to fan out
/// blob put/delete events to all active incremental replication sessions.
pub(crate) struct BlobObserverHub {
    subscribers: Mutex<Vec<Sender<BlobChange>>>,
}

impl BlobObserverHub {
    pub fn new() -> Self {
        BlobObserverHub {
            subscribers: Mutex::new(Vec::new()),
        }
    }

    /// Register a new subscriber and return its receiver.
    pub fn subscribe(&self) -> Receiver<BlobChange> {
        let (tx, rx) = channel();
        self.subscribers.lock().unwrap().push(tx);
        rx
    }

    /// Emit a blob change to all active subscribers. Closed channels are
    /// pruned on each emit (same pattern as `ObserverHub::emit`).
    pub fn emit(&self, change: BlobChange) {
        let mut subs = self.subscribers.lock().unwrap();
        subs.retain(|tx| tx.send(change.clone()).is_ok());
    }
}

// MARK: - ObserverHub (row changes)

/// Channel multiplexer used by InMemoryStorage. Maintains a list
/// of (table, events_filter, sender) tuples; `emit` fans out to
/// matching subscribers. Closed senders are pruned on next emit.
pub(crate) struct ObserverHub {
    subscribers: Mutex<Vec<Subscriber>>,
}

struct Subscriber {
    table: String,
    events: BTreeSet<StorageEvent>,
    tx: Sender<TableChange>,
}

impl ObserverHub {
    pub fn new() -> Self {
        ObserverHub {
            subscribers: Mutex::new(Vec::new()),
        }
    }

    pub fn subscribe(
        &self,
        table: impl Into<String>,
        events: BTreeSet<StorageEvent>,
    ) -> Receiver<TableChange> {
        let (tx, rx) = channel();
        let mut subs = self.subscribers.lock().unwrap();
        subs.push(Subscriber {
            table: table.into(),
            events,
            tx,
        });
        rx
    }

    pub fn emit(&self, change: TableChange) {
        let mut subs = self.subscribers.lock().unwrap();
        // Drop closed channels on each emit.
        let mut keep: Vec<bool> = Vec::with_capacity(subs.len());
        for sub in subs.iter() {
            if sub.table != change.table || !sub.events.contains(&change.event) {
                keep.push(true);
                continue;
            }
            // Try sending; if the receiver is gone, mark for removal.
            keep.push(sub.tx.send(change.clone()).is_ok());
        }
        // Compact in place by retaining only the live indices.
        let mut i = 0;
        subs.retain(|_| {
            let live = keep[i];
            i += 1;
            live
        });
    }
}
