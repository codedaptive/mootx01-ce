//! Incremental replication dirty-set (§6).
//!
//! Mirrors Swift's `IncrementalReplicationSession` in PersistenceKitReplication.
//!
//! DESIGN CHOICE — watermark + re-scan (not a durable dirty table):
//!
//!   Two approaches exist:
//!   A) Durable dirty table: write (table, pk) to a separate table on each observer
//!      event; drain on sync; delete drained rows.
//!   B) In-memory accumulation + watermark: accumulate (table, pkValues) in a
//!      Mutex-guarded set while the session is alive; re-scan dirty rows from the
//!      source on sync; persist only the HLC watermark in the cursor.
//!
//!   We chose (B) for three reasons:
//!   1. The cursor already carries an HLC watermark; extending it to own the
//!      dirty-set is a natural fit and requires no new schema.
//!   2. A durable dirty table would bind this module to a specific backend schema,
//!      violating the module's backend-agnostic design.
//!   3. Re-read on sync is O(dirty count) — cheap.
//!
//!   TWO GRANULARITIES OF DIRT — why (B) alone is not enough:
//!
//!   Approach (B) can only name a row when the observer event carries that
//!   row's primary-key values. The durable backends do not always supply them:
//!   SQLite emits `values: None` for predicate `update` and `delete` in both
//!   ports, and the PostgreSQL backend emits neither `values` nor `row_key` for
//!   either verb. Nothing else in the change identifies the row —
//!   `TableChange.hlc` is `None` at every emission site, no schema-wide
//!   modified-at column exists, and `row_key` is a UUID derived from only the
//!   FIRST primary-key column (hashed for non-UUID TEXT keys), so it is not
//!   invertible and does not identify a row under a composite key.
//!
//!   So the session tracks dirt at two granularities:
//!     ROW dirt   — the change carried its primary-key values. Re-scan exactly
//!                  that row; absent in the source means "delete at the
//!                  destination", present means "upsert".
//!     TABLE dirt — the change did not. The row cannot be named, but the TABLE
//!                  can, so the whole table is re-scanned and reconciled: every
//!                  source row is upserted, and every destination row whose
//!                  primary key is absent from the source is deleted. The
//!                  deletion half is what carries an expunge, a tombstone, or
//!                  an erasure across; without it a value-less delete would
//!                  vanish. It is the row-level form of the rule the
//!                  full-snapshot path already applies to blobs (SECFIX-WS2-PK
//!                  F5): a replica that holds keys the source does not is
//!                  divergence.
//!
//!   A change the session cannot resolve at EITHER granularity — a table that
//!   declares no primary key, so there is no column set to reconcile on — does
//!   not vanish either. It marks the cycle INCOMPLETE (see the watermark
//!   contract below). An observed change always produces propagation or a
//!   surfaced refusal; it is never silently dropped.
//!
//!   MIRROR ASSUMPTION: table-granularity dirt reconciles the destination
//!   against the source, so this module's declared model — destination mirrors
//!   source — is load-bearing. A destination fanned in from several sources
//!   would lose the other sources' rows. That model is already assumed by the
//!   restart semantics below and by the blob reconciliation in the snapshot
//!   path.
//!
//!   RESTART SEMANTICS: the dirty-set is in-memory. On process restart, the
//!   caller falls back to a full snapshot. Correct: full snapshot is always a
//!   valid substitute.
//!
//! WATERMARK CONTRACT:
//!   The audit watermark advances only for a cycle that resolved every change
//!   it observed. A cycle carrying an unresolvable change copies no audit
//!   events and returns the incoming watermark unchanged, so the next cycle
//!   re-reads the same audit range. Advancing the watermark past work that was
//!   not done is what would make a missed row permanent: the destination would
//!   record that it had replicated a deletion it never received, and only a
//!   forced full snapshot could repair it.
//!
//! FAIL-LOUD CONTRACT:
//!   A StorageError encountered during a dirty-row read aborts the entire sync
//!   run immediately with the error surfaced. No partial destination state is
//!   committed — the destination transaction rolls back. Skipping corrupt rows
//!   would silently poison the destination. See §15 fail-loud read-back.
//!
//! RUST NOTES:
//!   Swift uses AsyncStream for the observer channel; Rust uses
//!   `std::sync::mpsc::Receiver<TableChange>`. The session drains the channel
//!   via `try_recv` in a non-blocking loop before each sync run, accumulating
//!   all pending changes into the dirty-set. This is the synchronous equivalent
//!   of Swift's `for await change in stream { ... }` task.
//!
//!   SURFACING AN INCOMPLETE CYCLE: the Swift port logs the refusal through
//!   OSLog as well as returning it. This crate has no logging framework — its
//!   only observability seam is Intellectus `report!`, a metrics sampler gated
//!   on `is_enabled()`, and a counter nobody consumes is not evidence. So on
//!   this port the returned `IncrementalSyncOutcome` IS the surface: it names
//!   the unresolved tables, and the held-back watermark inside it makes the
//!   refusal impossible to lose even for a caller that reads only the cursor.

use crate::audit_log::AuditEvent;
use crate::blob_store::BlobKey;
// StorageError and StorageResult are used transitively via ReplicationError::from.
use crate::observer::{BlobChange, BlobEvent, StorageEvent, TableChange};
use crate::predicate::StoragePredicate;
use crate::replication::{ReplicationCursor, ReplicationError};
use crate::schema::SchemaDeclaration;
use crate::storage::{IsolationLevel, Storage};
use crate::types::{Column, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::Receiver;
use std::sync::Mutex;
use substrate_types::hlc::HLC;

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

// MARK: - DirtyKey

/// A (table, primary-key-values) pair that identifies exactly one row.
/// Ordering is (table, pk_encoded) — deterministic sync ordering.
///
/// Manual PartialOrd/Ord/Hash/PartialEq/Eq impls use only (table, pk_encoded)
/// because TypedValue does not implement Ord/Hash. pk_values is carried for the
/// re-scan predicate and is logically redundant with pk_encoded.
#[derive(Debug, Clone)]
pub struct DirtyKey {
    pub table: String,
    /// Canonically encoded PK: "col1=Debug(val1),col2=Debug(val2)" in column-name order.
    /// Stable equality and ordering; not human-readable but deterministic.
    pub pk_encoded: String,
    /// Raw PK column values for the re-scan predicate.
    pub pk_values: BTreeMap<String, TypedValue>,
}

impl PartialEq for DirtyKey {
    fn eq(&self, other: &Self) -> bool {
        self.table == other.table && self.pk_encoded == other.pk_encoded
    }
}

impl Eq for DirtyKey {}

impl std::hash::Hash for DirtyKey {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.table.hash(state);
        self.pk_encoded.hash(state);
    }
}

impl PartialOrd for DirtyKey {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for DirtyKey {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (&self.table, &self.pk_encoded).cmp(&(&other.table, &other.pk_encoded))
    }
}

impl DirtyKey {
    /// Construct a DirtyKey from the table name and PK column values.
    pub fn new(table: impl Into<String>, pk_values: BTreeMap<String, TypedValue>) -> Self {
        let table = table.into();
        let pk_encoded = pk_values
            .iter()
            .map(|(k, v)| format!("{}={:?}", k, v))
            .collect::<Vec<_>>()
            .join(",");
        DirtyKey {
            table,
            pk_encoded,
            pk_values,
        }
    }
}

// MARK: - DirtyDrain

/// One atomic drain of the dirty-set, at all three resolutions the session
/// tracks. Draining is all-or-nothing: a caller can never take the keys and
/// leave the table-granularity dirt behind, which is what would let a
/// value-less change fall out of the cycle unnoticed.
#[derive(Debug, Clone, Default)]
pub struct DirtyDrain {
    /// Rows the session could name, because their change carried its
    /// primary-key values.
    pub keys: Vec<DirtyKey>,
    /// Tables carrying at least one change the session could NOT name, but
    /// CAN re-scan. Each is re-read in full and reconciled against the
    /// destination during the sync run.
    pub rescan_tables: Vec<String>,
    /// Tables carrying a change the session can neither name nor re-scan,
    /// because the table declares no primary key and reconciliation has no
    /// column set to compare on. A cycle carrying any of these is INCOMPLETE.
    pub unresolvable_tables: Vec<String>,
}

impl DirtyDrain {
    /// True only when the session observed nothing at all. Changes the session
    /// could not key are NOT nothing, and must never collapse into this signal
    /// — that collapse is the whole of the silence.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty() && self.rescan_tables.is_empty() && self.unresolvable_tables.is_empty()
    }
}

// MARK: - DirtySet

/// Thread-safe accumulator for dirty (table, pk) pairs.
///
/// Populated by the observer-consumer thread via `accumulate`; drained
/// before each sync run via `drain`.
pub struct DirtySet {
    entries: Mutex<BTreeSet<DirtyKey>>,
    /// Tables with an observed change whose row could not be identified.
    /// See `DirtyDrain::rescan_tables`.
    rescan_tables: Mutex<BTreeSet<String>>,
    /// Tables with an observed change that can be neither identified nor
    /// reconciled. See `DirtyDrain::unresolvable_tables`.
    unresolvable_tables: Mutex<BTreeSet<String>>,
    /// Primary-key column names per table, from the schema at session start.
    primary_keys: BTreeMap<String, Vec<String>>,
}

impl DirtySet {
    pub fn new(schema: &SchemaDeclaration) -> Self {
        let primary_keys = schema
            .tables
            .iter()
            .map(|t| (t.name.clone(), t.primary_key.clone()))
            .collect();
        DirtySet {
            entries: Mutex::new(BTreeSet::new()),
            rescan_tables: Mutex::new(BTreeSet::new()),
            unresolvable_tables: Mutex::new(BTreeSet::new()),
            primary_keys,
        }
    }

    /// Record a change for replication.
    ///
    /// BINDING INVARIANT: a change this method observes is never treated as no
    /// change. It resolves to one of three outcomes, and the two fallbacks are
    /// the reason updates and deletes reach the replica at all:
    ///
    /// 1. **Row dirt.** The change carried every primary-key column, so the
    ///    exact row is recorded. Inserts, updates, and deletes all add the same
    ///    DirtyKey — there is no tombstone sentinel type. At sync time the
    ///    re-scan determines intent: absent in the source means delete at the
    ///    destination, present means upsert.
    /// 2. **Table dirt.** `values` is `None`, or present but missing a
    ///    primary-key column, so the row cannot be named. The TABLE is recorded
    ///    for a whole-table re-scan instead. This is the path every predicate
    ///    `update` and `delete` on a durable backend takes: SQLite emits
    ///    `values: None` for both verbs, and PostgreSQL emits neither `values`
    ///    nor `row_key`. Dropping them here would silently discard every update
    ///    and delete on a durable backend — expunge, tombstoning, withdrawal,
    ///    and erasure included — so they are kept.
    /// 3. **Unresolvable.** The table declares no primary key, so there is no
    ///    column set to reconcile source against destination on. Recorded as
    ///    unresolvable, which holds the audit watermark back for the cycle
    ///    rather than letting it advance past work that was not done.
    ///
    /// A change for a table absent from this session's schema is still ignored:
    /// that table is not ours to replicate, which is a scope judgement, not a
    /// failure to resolve.
    pub fn accumulate(&self, change: &TableChange) {
        let pk_cols = match self.primary_keys.get(&change.table) {
            Some(cols) => cols,
            None => return, // not our table to replicate
        };
        if pk_cols.is_empty() {
            // No declared primary key: neither naming nor reconciliation is
            // possible. Surface it rather than swallowing it.
            self.unresolvable_tables
                .lock()
                .unwrap()
                .insert(change.table.clone());
            return;
        }
        // TableChange.values carries the full row on insert/upsert; the durable
        // backends leave it None on predicate update and delete.
        let values = match &change.values {
            Some(v) => v,
            None => {
                self.rescan_tables
                    .lock()
                    .unwrap()
                    .insert(change.table.clone());
                return;
            }
        };
        let mut pk_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        for col in pk_cols {
            match values.get(col) {
                Some(v) => {
                    pk_values.insert(col.clone(), v.clone());
                }
                None => {
                    // Values present but not carrying the full key — same
                    // remedy as no values at all: the row is unnameable, the
                    // table is not.
                    self.rescan_tables
                        .lock()
                        .unwrap()
                        .insert(change.table.clone());
                    return;
                }
            }
        }
        let key = DirtyKey::new(change.table.clone(), pk_values);
        self.entries.lock().unwrap().insert(key);
    }

    /// Drain everything accumulated since the last drain, sorted for
    /// deterministic sync ordering. All three sets are cleared atomically —
    /// see `DirtyDrain`.
    pub fn drain(&self) -> DirtyDrain {
        let mut entries = self.entries.lock().unwrap();
        let mut rescan = self.rescan_tables.lock().unwrap();
        let mut unresolvable = self.unresolvable_tables.lock().unwrap();
        let drained = DirtyDrain {
            keys: entries.iter().cloned().collect(),
            rescan_tables: rescan.iter().cloned().collect(),
            unresolvable_tables: unresolvable.iter().cloned().collect(),
        };
        entries.clear();
        rescan.clear();
        unresolvable.clear();
        drained
    }

    /// Restore previously-drained keys into the dirty-set after a failed sync run.
    ///
    /// RETRY-PRESERVATION CONTRACT: when sync aborts after a drain, the caller
    /// restores the drained keys so a subsequent retry re-attempts the same rows.
    ///
    /// Union semantics: keys dirtied DURING the failed run (accumulated between
    /// the drain and the restore call) are preserved unchanged. `BTreeSet::insert`
    /// is a no-op when the element already exists, so newer dirt for the same row
    /// is never overwritten by a stale restored key. This is correct: the newer
    /// event subsumes the restored one, and retrying with it is safe and sufficient.
    ///
    /// All three resolutions are restored together. Restoring only the keys
    /// would drop the table-granularity dirt on a failed run, which is the same
    /// silent loss this session exists to prevent — just moved to the retry path.
    ///
    /// Locks are taken in the same order as `drain` (entries, rescan,
    /// unresolvable); nothing in this type takes them in any other order.
    pub fn restore(&self, drained: &DirtyDrain) {
        let mut entries = self.entries.lock().unwrap();
        let mut rescan = self.rescan_tables.lock().unwrap();
        let mut unresolvable = self.unresolvable_tables.lock().unwrap();
        for key in &drained.keys {
            entries.insert(key.clone());
        }
        for table in &drained.rescan_tables {
            rescan.insert(table.clone());
        }
        for table in &drained.unresolvable_tables {
            unresolvable.insert(table.clone());
        }
    }

    /// Count of individually-named dirty rows — for tests. Table-granularity
    /// dirt is deliberately NOT counted here: one entry stands for an unknown
    /// number of rows, so folding it into this number would make the count mean
    /// two different things. Use `pending_rescan_tables` for that.
    pub fn count(&self) -> usize {
        self.entries.lock().unwrap().len()
    }

    /// Tables awaiting a whole-table re-scan, sorted — for tests.
    pub fn pending_rescan_tables(&self) -> Vec<String> {
        self.rescan_tables.lock().unwrap().iter().cloned().collect()
    }

    /// Tables carrying a change that can be neither named nor reconciled,
    /// sorted — for tests.
    pub fn pending_unresolvable_tables(&self) -> Vec<String> {
        self.unresolvable_tables
            .lock()
            .unwrap()
            .iter()
            .cloned()
            .collect()
    }
}

// MARK: - BlobDirtyAccumulator

/// Thread-safe accumulator for dirty blob keys with last-write-wins semantics.
///
/// Mirrors Swift's `BlobDirtySet` actor. Populated via `accumulate` when the
/// observer channel delivers a `BlobChange`; drained before each sync run via
/// `drain`.
///
/// LAST-WRITE-WINS: a subsequent `Put` for the same key replaces an earlier
/// `Put` or `Delete`. A `Delete` after a `Put` for the same key records the
/// deletion — the destination will delete it on next sync.
///
/// `entries` is a BTreeMap keyed on BlobKey for deterministic drain ordering.
pub struct BlobDirtyAccumulator {
    entries: Mutex<BTreeMap<BlobKey, BlobDirtyEntry>>,
}

/// One entry in the blob dirty accumulator.
#[derive(Clone)]
pub(crate) struct BlobDirtyEntry {
    pub event: BlobEvent,
    /// Payload for Put events; None for Delete events.
    pub bytes: Option<Vec<u8>>,
}

impl BlobDirtyAccumulator {
    pub fn new() -> Self {
        BlobDirtyAccumulator {
            entries: Mutex::new(BTreeMap::new()),
        }
    }

    /// Record a blob change. Last-write-wins: a later event for the same key
    /// always replaces the earlier one.
    pub fn accumulate(&self, change: &BlobChange) {
        let mut guard = self.entries.lock().unwrap();
        guard.insert(change.key.clone(), BlobDirtyEntry {
            event: change.event,
            bytes: change.bytes.clone(),
        });
    }

    /// Drain all accumulated entries. The accumulator is cleared atomically.
    /// Returns entries in sorted key order for deterministic sync ordering.
    pub(crate) fn drain(&self) -> Vec<(BlobKey, BlobDirtyEntry)> {
        let mut guard = self.entries.lock().unwrap();
        let drained: Vec<(BlobKey, BlobDirtyEntry)> = guard
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        guard.clear();
        drained
    }

    /// Restore previously-drained entries after a failed sync run.
    ///
    /// RETRY-PRESERVATION: union semantics — keys dirtied DURING the failed run
    /// (already in the accumulator) are never overwritten by stale restored entries.
    /// Only entries whose key is NOT yet in the accumulator are inserted.
    pub(crate) fn restore(&self, entries: &[(BlobKey, BlobDirtyEntry)]) {
        let mut guard = self.entries.lock().unwrap();
        for (key, entry) in entries {
            guard.entry(key.clone()).or_insert_with(|| entry.clone());
        }
    }

    /// Current count — for tests.
    pub fn count(&self) -> usize {
        self.entries.lock().unwrap().len()
    }

    /// Insert a Put entry with nil bytes directly into the accumulator.
    ///
    /// Used only in tests to trigger the fail-loud nil-bytes path in
    /// `sync()` without going through the observer channel.
    /// The production `accumulate()` API always carries real bytes for
    /// Put events, so this path is unreachable from non-test code.
    #[cfg(test)]
    pub(crate) fn inject_nil_bytes_put(&self, key: BlobKey) {
        let mut guard = self.entries.lock().unwrap();
        guard.insert(key, BlobDirtyEntry { event: BlobEvent::Put, bytes: None });
    }
}

// MARK: - IncrementalSyncOutcome

/// The result of one incremental sync cycle: the cursor to persist, plus what
/// the cycle had to do to resolve what it observed.
///
/// The cursor alone cannot carry this. `ReplicationCursor` is the DURABLE
/// watermark a caller stores and passes back on the next run; cycle resolution
/// is a report about a single run and has no meaning once persisted. Keeping
/// them apart also means a caller that only wants the watermark keeps reading
/// `.cursor` and is unaffected by anything here.
///
/// A caller that ignores `unresolved_tables` still cannot lose data silently:
/// the watermark in `cursor` did not advance for an incomplete cycle, so the
/// next run re-reads the same audit range.
#[derive(Debug, Clone, PartialEq)]
pub struct IncrementalSyncOutcome {
    /// The watermark to persist and pass to the next `sync` call.
    ///
    /// For an incomplete cycle this carries the INCOMING watermark unchanged —
    /// see `unresolved_tables`.
    pub cursor: ReplicationCursor,

    /// Tables this cycle re-scanned in full because it observed a change it
    /// could not attribute to a row (sorted).
    ///
    /// Non-empty is normal, not an error: every predicate update and delete on
    /// a durable backend arrives without values and lands here. It is reported
    /// because a whole-table re-scan costs O(table), not O(dirty rows), and a
    /// caller watching replication cost needs to see when that happens.
    pub rescanned_tables: Vec<String>,

    /// Tables carrying a change this cycle could resolve at NO granularity —
    /// the table declares no primary key, so it can be neither named nor
    /// reconciled (sorted).
    ///
    /// Non-empty means the cycle is INCOMPLETE: no audit events were copied and
    /// `cursor.hlc_watermark` is the incoming watermark, unmoved. Row work that
    /// COULD be resolved was still propagated — an unresolvable change withholds
    /// the watermark, it does not veto the rest of the cycle.
    pub unresolved_tables: Vec<String>,
}

impl IncrementalSyncOutcome {
    /// Whether every observed change was resolved. `false` means the audit
    /// watermark deliberately did not advance.
    pub fn is_complete(&self) -> bool {
        self.unresolved_tables.is_empty()
    }
}

// MARK: - IncrementalReplicationSession

/// An active incremental replication session for one source storage.
///
/// Lifecycle:
///   1. Create with `IncrementalReplicationSession::start`.
///   2. Keep alive while the process is running.
///   3. Call `sync` to push dirty rows to a destination.
///   4. Drop to release observer channel.
///
/// The session holds a `Receiver<TableChange>` per table. Before each sync
/// run, `drain_channels()` pulls all pending messages from every channel into
/// the DirtySet. This is the synchronous parity of Swift's async stream task.
///
/// Thread safety: `IncrementalReplicationSession` is `Send + Sync` because
/// all mutable state lives inside `Mutex`-guarded fields (`DirtySet.entries`,
/// `channels`).
pub struct IncrementalReplicationSession {
    pub dirty_set: DirtySet,
    /// Blob dirty accumulator: receives put/delete events from the blob observer.
    pub blob_dirty: BlobDirtyAccumulator,
    schema: SchemaDeclaration,
    /// One channel receiver per table subscribed via `observer.observe`.
    channels: Mutex<Vec<Receiver<TableChange>>>,
    /// Channel receiver for blob changes from `observer.observe_blobs()`.
    blob_channel: Mutex<Receiver<BlobChange>>,
}

impl IncrementalReplicationSession {
    // MARK: - Factory

    /// Start an incremental replication session on `source`.
    ///
    /// Subscribes to all schema-declared tables for insert, update, and delete
    /// events, and to blob events via `observe_blobs()`. Changes are accumulated
    /// in the session's DirtySet/BlobDirtyAccumulator until
    /// `sync(source, destination, from_cursor)` is called.
    pub fn start(source: &dyn Storage, schema: &SchemaDeclaration) -> Self {
        let dirty = DirtySet::new(schema);
        let mut channels: Vec<Receiver<TableChange>> = Vec::new();

        let observer = source.observer();
        for table in &schema.tables {
            let mut events = BTreeSet::new();
            events.insert(StorageEvent::Insert);
            events.insert(StorageEvent::Update);
            events.insert(StorageEvent::Delete);
            if let Ok(rx) = observer.observe(&table.name, events) {
                channels.push(rx);
            }
        }

        // Subscribe to blob changes. observe_blobs() returns a disconnected
        // receiver for backends that don't support blob observation (e.g. SQLite,
        // NoOp). In that case drain_blob_channel() produces no events, which is
        // correct — full-snapshot handles those backends on restart.
        let blob_rx = observer.observe_blobs();

        IncrementalReplicationSession {
            dirty_set: dirty,
            blob_dirty: BlobDirtyAccumulator::new(),
            schema: schema.clone(),
            channels: Mutex::new(channels),
            blob_channel: Mutex::new(blob_rx),
        }
    }

    // MARK: - Channel drain

    /// Pull all pending TableChange messages from every subscribed channel into
    /// the DirtySet. Channels return `TryRecvError::Empty` when no messages are
    /// pending (normal) and `TryRecvError::Disconnected` when the sender is gone
    /// (storage closed — silently ignore, the session is torn down soon).
    pub fn drain_channels(&self) {
        use std::sync::mpsc::TryRecvError;
        let channels = self.channels.lock().unwrap();
        for rx in channels.iter() {
            loop {
                match rx.try_recv() {
                    Ok(change) => self.dirty_set.accumulate(&change),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => break,
                }
            }
        }
    }

    /// Pull all pending BlobChange messages from the blob channel into the
    /// BlobDirtyAccumulator. Disconnected receiver (SQLite, NoOp backends) is
    /// silently ignored — those backends rely on full-snapshot on restart.
    pub fn drain_blob_channel(&self) {
        use std::sync::mpsc::TryRecvError;
        let rx = self.blob_channel.lock().unwrap();
        loop {
            match rx.try_recv() {
                Ok(change) => self.blob_dirty.accumulate(&change),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break,
            }
        }
    }

    // MARK: - Sync

    /// Replicate all dirty rows to `destination`.
    ///
    /// Drains the observer channels, then drains the dirty-set, reads each
    /// dirty row from `source`, and upserts (or deletes) it into `destination`
    /// inside a single serializable transaction.
    ///
    /// FAIL-LOUD: if any dirty row read encounters a StorageError (including
    /// corruptStoredValue), the error is wrapped in `ReplicationError::StorageFailure`
    /// and returned immediately. The destination transaction rolls back, leaving
    /// it in its last clean state. No partial state is committed.
    ///
    /// RETRY-PRESERVATION: if sync returns an error after the dirty-set is drained,
    /// the drained keys are restored before the error is returned. A subsequent
    /// retry will re-attempt the same rows. Keys dirtied DURING the failed run are
    /// preserved alongside the restored keys (union, no overwrite of newer dirt for
    /// the same row). This ensures no row silently escapes replication after a
    /// transient failure or a corrupt-value abort.
    ///
    /// DETERMINISTIC ORDERING: dirty keys are sorted (table, pk_encoded) before
    /// processing, producing the same upsert order for the same dirty-set across runs.
    ///
    /// AUDIT EVENTS: only events with HLC strictly after `from_cursor.hlc_watermark`
    /// are copied (`audit_log.iterate(after=watermark)` — exclusive lower bound).
    /// An INCOMPLETE cycle copies none at all — see the watermark contract below.
    ///
    /// TABLE-GRANULARITY DIRT: a change that arrived without primary-key values
    /// marks its whole table for re-scan (see `DirtySet::accumulate`). Every
    /// source row in such a table is upserted, and every destination row whose
    /// primary key is absent from the source is deleted. That deletion pass is
    /// what carries a value-less delete — an expunge, a tombstone, an erasure —
    /// across to the replica.
    ///
    /// WATERMARK: advances only for a cycle that resolved every change it
    /// observed. If any observed change was unresolvable, no audit events are
    /// copied and the returned cursor carries `from_cursor`'s watermark
    /// unchanged, so the next cycle re-reads the same range. Row work that
    /// could be resolved still propagates.
    ///
    /// - `source`: Source storage to read dirty rows from.
    /// - `destination`: Storage to write dirty rows to.
    /// - `from_cursor`: Watermark from the previous sync run. Pass a zero-watermark
    ///   cursor for the first incremental sync.
    /// - Returns: An `IncrementalSyncOutcome` carrying the cursor to persist and
    ///   this cycle's resolution report.
    pub fn sync(
        &self,
        source: &dyn Storage,
        destination: &dyn Storage,
        from_cursor: ReplicationCursor,
    ) -> Result<IncrementalSyncOutcome, ReplicationError> {
        // Schema gate: both backends must be at the same per-kit schema version.
        let src_version = source
            .current_schema_version_for(&self.schema.kit_id)
            .map_err(ReplicationError::from)?;
        let dst_version = destination
            .current_schema_version_for(&self.schema.kit_id)
            .map_err(ReplicationError::from)?;
        if src_version != dst_version || src_version != self.schema.version {
            return Err(ReplicationError::SchemaMismatch {
                source_version: src_version,
                destination_version: dst_version,
                kit_id: self.schema.kit_id.clone(),
            });
        }

        // Pull pending observer messages into the dirty-set and blob accumulator.
        self.drain_channels();
        self.drain_blob_channel();

        // Drain the dirty-set and blob accumulator. Sorted for deterministic ordering.
        // RETRY-PRESERVATION: we capture the drained keys before any fallible work.
        // Both dirty_keys and dirty_blobs are restored on every error path so the
        // next retry re-attempts the same rows and blobs.
        let drained = self.dirty_set.drain();
        let dirty_keys = &drained.keys;
        let dirty_blobs = self.blob_dirty.drain();

        // The early return fires ONLY when nothing at all was observed. It may
        // never stand in for "changes were observed but could not be keyed":
        // that equivalence is what would make a deletions-only cycle
        // indistinguishable from an idle one.
        if drained.is_empty() && dirty_blobs.is_empty() {
            return Ok(IncrementalSyncOutcome {
                cursor: from_cursor,
                rescanned_tables: Vec::new(),
                unresolved_tables: Vec::new(),
            });
        }

        // A cycle is complete when every observed change resolved to either a
        // named row or a re-scannable table. Unresolvable changes withhold the
        // watermark (see the watermark contract on the type).
        let cycle_resolved = drained.unresolvable_tables.is_empty();

        // Build a per-table index for PK columns and generated column names.
        let table_index: BTreeMap<&str, &crate::schema::TableDeclaration> = self
            .schema
            .tables
            .iter()
            .map(|t| (t.name.as_str(), t))
            .collect();

        // Snapshot dirty rows from source BEFORE opening the destination transaction.
        // On error: restore drained keys (and blobs) before propagating so retry sees them.
        let payload = self
            .snapshot_dirty_rows(
                source,
                dirty_keys,
                &drained.rescan_tables,
                &table_index,
                &from_cursor,
                cycle_resolved,
            )
            .map_err(|e| {
                self.dirty_set.restore(&drained);
                self.blob_dirty.restore(&dirty_blobs);
                e
            })?;

        // Write destination inside a serializable transaction.
        let mut rows_written: usize = 0;
        let mut deletes_written: usize = 0;
        let mut audit_events_written: usize = 0;
        let mut blobs_written: usize = 0;
        let mut max_hlc: Option<HLC> = from_cursor.hlc_watermark;

        let payload_ref = &payload;
        let dirty_blobs_ref = &dirty_blobs;
        let rows_written_ref = &mut rows_written;
        let deletes_written_ref = &mut deletes_written;
        let audit_events_written_ref = &mut audit_events_written;
        let blobs_written_ref = &mut blobs_written;
        let max_hlc_ref = &mut max_hlc;

        // On transaction error: restore drained keys AND blob ops so retry re-attempts them.
        destination
            .transaction(IsolationLevel::Serializable, &mut |txn| {
                let row_store = txn.row_store();
                let audit_log = txn.audit_log();
                let blob_store = txn.blob_store();

                // 1. Reconcile every wholly-dirty table: delete destination
                // rows whose primary key is absent from the source. This is the
                // half a value-less change cannot express — which rows went
                // away. Without it an expunge, tombstone, or erasure would leave
                // the removed content live at the destination.
                //
                // Same rule the full-snapshot path applies to blobs
                // (SECFIX-WS2-PK F5): keys the destination holds and the source
                // does not are divergence.
                //
                // ORDER IS DELIBERATE: this pass runs BEFORE the upserts in
                // step 2.
                //
                // Both sides are encoded through DirtyKey, but they are READ
                // through different decoders — the source via
                // `source.row_store()`, the destination via `txn.row_store()` —
                // and those coincide only when both ends are the same backend
                // type. The decoders in this repo do agree for the primary-key
                // column types the tests cover (verified SQLite→InMemory,
                // §10.C8), so this ordering is not fixing an observed bug. It
                // removes the DEPENDENCE on that agreement, which nothing
                // enforces.
                //
                // Why the order decides the blast radius: if a future backend
                // pair ever decoded a PK value into a different TypedValue
                // variant, every destination row would look absent from the
                // source. Deleting first makes that delete-then-reinsert churn
                // and the destination still ends up matching the source exactly.
                // Deleting AFTER the upserts would instead delete the rows just
                // written and leave the table empty. Correct under both
                // agreement and divergence is worth more than correct under
                // agreement alone.
                for rescan in &payload_ref.table_rescans {
                    let destination_rows =
                        row_store.query(&rescan.table, None, &[], None, None)?;
                    for row in &destination_rows {
                        let pk_values = extract_pk_values(&row.values, &rescan.primary_key)
                            .ok_or_else(|| {
                                // A destination row missing a declared PK column
                                // cannot be compared, and guessing would risk
                                // deleting a row the source still holds. Fail
                                // loud (§15).
                                crate::error::StorageError::BackendError {
                                    underlying: format!(
                                        "incremental re-scan of '{}': destination row is missing \
                                         a primary-key column; cannot reconcile against the source",
                                        rescan.table
                                    ),
                                }
                            })?;
                        let encoded =
                            DirtyKey::new(rescan.table.clone(), pk_values.clone()).pk_encoded;
                        if rescan.source_pk_encodings.contains(&encoded) {
                            continue;
                        }
                        // Note: on an append-only table the backend rejects
                        // DELETE by contract and this fails. That is unreachable
                        // in practice — an append-only table also rejects the
                        // UPDATE and DELETE that are the only sources of
                        // value-less changes — and a loud failure is the right
                        // answer if it ever is reached. A silent skip here would
                        // be exactly the quiet exemption this session exists to
                        // remove.
                        let predicate = pk_predicate(&pk_values, &rescan.table);
                        row_store.delete(&rescan.table, &predicate)?;
                        *deletes_written_ref += 1;
                    }
                }

                // 2. Row upserts and per-key deletes.
                for op in &payload_ref.row_ops {
                    match op {
                        RowOp::Upsert { table, primary_key, values } => {
                            // Track HLC values from row columns for watermark.
                            for value in values.values() {
                                if let TypedValue::Hlc(h) = value {
                                    match *max_hlc_ref {
                                        None => *max_hlc_ref = Some(*h),
                                        Some(ref current) if h > current => {
                                            *max_hlc_ref = Some(*h)
                                        }
                                        _ => {}
                                    }
                                }
                            }
                            row_store.upsert(table, values.clone(), primary_key)?;
                            *rows_written_ref += 1;
                        }
                        RowOp::Delete { table, predicate } => {
                            row_store.delete(table, predicate)?;
                            *deletes_written_ref += 1;
                        }
                    }
                }

                // 3. Audit events after the previous watermark.
                if !payload_ref.audit_events.is_empty() {
                    audit_log.append_batch(payload_ref.audit_events.clone())?;
                    *audit_events_written_ref = payload_ref.audit_events.len();
                    for event in &payload_ref.audit_events {
                        match *max_hlc_ref {
                            None => *max_hlc_ref = Some(event.hlc),
                            Some(ref current) if &event.hlc > current => {
                                *max_hlc_ref = Some(event.hlc)
                            }
                            _ => {}
                        }
                    }
                }

                // 4. Blob ops from the BlobDirtyAccumulator.
                // Put: write the captured bytes to the destination (fail-loud if bytes
                // are None — that would be a programmer error, not a runtime condition,
                // since accumulate always stores bytes for Put events).
                // Delete: remove the blob from the destination.
                for (key, entry) in dirty_blobs_ref {
                    match entry.event {
                        BlobEvent::Put => {
                            let bytes = entry.bytes.as_deref().ok_or_else(|| {
                                // BlobDirtyAccumulator invariant: a Put entry always
                                // carries bytes. A None here indicates a corrupt
                                // in-memory accumulator state.
                                crate::error::StorageError::BackendError {
                                    underlying: format!(
                                        "BlobDirtyAccumulator Put for key '{}' has no bytes",
                                        key
                                    ),
                                }
                            })?;
                            blob_store.put(key, bytes)?;
                            *blobs_written_ref += 1;
                        }
                        BlobEvent::Delete => {
                            blob_store.delete(key)?;
                            *blobs_written_ref += 1;
                        }
                    }
                }

                Ok(())
            })
            .map_err(|e| {
                // Transaction rolled back — restore drained keys AND blob ops so
                // retry re-attempts all of them.
                self.dirty_set.restore(&drained);
                self.blob_dirty.restore(&dirty_blobs);
                ReplicationError::from(e)
            })?;

        // WATERMARK GATE: an incomplete cycle keeps the incoming watermark.
        // `max_hlc` starts at `from_cursor.hlc_watermark` and only ever grows,
        // so pinning it back here is the whole of the gate.
        let watermark = if cycle_resolved {
            max_hlc
        } else {
            from_cursor.hlc_watermark
        };

        Ok(IncrementalSyncOutcome {
            cursor: ReplicationCursor {
                hlc_watermark: watermark,
                rows_written: rows_written + deletes_written,
                audit_events_written,
                blobs_written,
            },
            rescanned_tables: drained.rescan_tables.clone(),
            unresolved_tables: drained.unresolvable_tables.clone(),
        })
    }

    // MARK: - Dirty-row snapshot

    /// Snapshot dirty rows from source before opening the destination transaction.
    /// Errors during read surface immediately (fail-loud) — no row is skipped.
    ///
    /// - `rescan_tables`: Tables to read in FULL because a change on them could
    ///   not be attributed to a row. Every source row is staged for upsert and
    ///   the table's source primary-key set is captured so the caller can delete
    ///   destination rows the source no longer has.
    /// - `copy_audit_events`: `false` for an incomplete cycle. Audit events and
    ///   the watermark move together: copying events for a cycle whose watermark
    ///   is held back would re-copy the same events on the next run, so an
    ///   incomplete cycle copies none.
    fn snapshot_dirty_rows(
        &self,
        source: &dyn Storage,
        dirty_keys: &[DirtyKey],
        rescan_tables: &[String],
        table_index: &BTreeMap<&str, &crate::schema::TableDeclaration>,
        from_cursor: &ReplicationCursor,
        copy_audit_events: bool,
    ) -> Result<IncrementalPayload, ReplicationError> {
        let row_store = source.row_store();
        let audit_log = source.audit_log();
        let mut row_ops: Vec<RowOp> = Vec::new();
        let mut table_rescans: Vec<TableRescan> = Vec::new();

        // Whole-table re-scan first, so per-key work on the same table can be
        // skipped below: a table being read in full already covers every row in
        // it, and re-querying those rows one at a time would be pure waste.
        let rescan_set: BTreeSet<&str> = rescan_tables.iter().map(|t| t.as_str()).collect();
        for table in rescan_tables {
            let table_decl = match table_index.get(table.as_str()) {
                Some(t) => t,
                None => continue, // Table left the schema; nothing to reconcile against.
            };
            let generated_names: BTreeSet<String> = table_decl
                .generated_columns
                .iter()
                .map(|g| g.name.clone())
                .collect();

            // Unbounded read: correctness first. A value-less change names no
            // row, so the only sound lower bound on what to re-read is the whole
            // table. This is why `IncrementalSyncOutcome::rescanned_tables`
            // reports which tables paid that cost.
            let source_rows = row_store
                .query(table, None, &[], None, None)
                .map_err(ReplicationError::from)?;

            let mut source_pk_encodings: BTreeSet<String> = BTreeSet::new();
            for row in &source_rows {
                let pk_values = extract_pk_values(&row.values, &table_decl.primary_key)
                    .ok_or_else(|| {
                        // A source row missing a declared PK column would make
                        // the reconciliation set incomplete, and an incomplete
                        // source set deletes destination rows that should have
                        // survived.
                        ReplicationError::StorageFailure {
                            detail: format!(
                                "incremental re-scan of '{}': source row is missing a \
                                 primary-key column; the re-scan set would be incomplete",
                                table
                            ),
                        }
                    })?;
                source_pk_encodings
                    .insert(DirtyKey::new(table.clone(), pk_values).pk_encoded);
                let filtered: BTreeMap<String, TypedValue> = row
                    .values
                    .iter()
                    .filter(|(k, _)| !generated_names.contains(*k))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                row_ops.push(RowOp::Upsert {
                    table: table.clone(),
                    primary_key: table_decl.primary_key.clone(),
                    values: filtered,
                });
            }
            table_rescans.push(TableRescan {
                table: table.clone(),
                primary_key: table_decl.primary_key.clone(),
                source_pk_encodings,
            });
        }

        for key in dirty_keys {
            if rescan_set.contains(key.table.as_str()) {
                continue; // Already covered by the whole-table re-scan above.
            }
            let table_decl = match table_index.get(key.table.as_str()) {
                Some(t) => t,
                None => continue, // Table not in schema.
            };
            let generated_names: BTreeSet<String> = table_decl
                .generated_columns
                .iter()
                .map(|g| g.name.clone())
                .collect();

            let predicate = pk_predicate(&key.pk_values, &key.table);

            // Query the source for this specific row. StorageError (including
            // corruptStoredValue) surfaces immediately — fail-loud.
            let rows = row_store
                .query(&key.table, Some(&predicate), &[], None, None)
                .map_err(ReplicationError::from)?;

            if rows.is_empty() {
                // Row was deleted in source between observer event and re-scan.
                // Issue a delete on the destination.
                row_ops.push(RowOp::Delete {
                    table: key.table.clone(),
                    predicate,
                });
            } else {
                // Filter generated columns before staging for upsert.
                let filtered: BTreeMap<String, TypedValue> = rows[0]
                    .values
                    .iter()
                    .filter(|(k, _)| !generated_names.contains(*k))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                row_ops.push(RowOp::Upsert {
                    table: key.table.clone(),
                    primary_key: table_decl.primary_key.clone(),
                    values: filtered,
                });
            }
        }

        // Audit events after the previous watermark. iterate(after=watermark) is
        // an exclusive lower bound — events at or before the watermark were already
        // delivered in a previous sync run.
        // iterate(after) is an exclusive lower bound (HLC > watermark).
        // Pass the watermark directly; HLC is Copy.
        //
        // An incomplete cycle copies none: its watermark stays where it was, so
        // copying events now would append them again on the next run.
        let audit_events = if copy_audit_events {
            audit_log
                .iterate(from_cursor.hlc_watermark, None, usize::MAX)
                .map_err(ReplicationError::from)?
        } else {
            Vec::new()
        };

        Ok(IncrementalPayload {
            row_ops,
            table_rescans,
            audit_events,
        })
    }
}

// MARK: - Primary-key helper

/// Pull the declared primary-key columns out of a row's values.
///
/// Returns `None` when any declared PK column is absent — the caller must treat
/// that as a failure rather than reconciling on a partial key, since a partial
/// key cannot distinguish two rows and would license deleting the wrong one.
fn extract_pk_values(
    values: &BTreeMap<String, TypedValue>,
    columns: &[String],
) -> Option<BTreeMap<String, TypedValue>> {
    let mut out: BTreeMap<String, TypedValue> = BTreeMap::new();
    for col in columns {
        out.insert(col.clone(), values.get(col)?.clone());
    }
    Some(out)
}

// MARK: - Predicate builder

/// Build a predicate selecting a row by its exact primary-key values.
/// Multiple PK columns are combined with And.
fn pk_predicate(pk_values: &BTreeMap<String, TypedValue>, table: &str) -> StoragePredicate {
    let clauses: Vec<StoragePredicate> = pk_values
        .iter()
        .map(|(col, val)| {
            StoragePredicate::Eq(
                Column::new(table.to_string(), col.clone()),
                val.clone(),
            )
        })
        .collect();

    match clauses.len() {
        0 => StoragePredicate::IsTrue,
        1 => clauses.into_iter().next().unwrap(),
        _ => StoragePredicate::And(clauses),
    }
}

// MARK: - Internal types

/// A row operation to apply during the incremental sync transaction.
enum RowOp {
    Upsert {
        table: String,
        primary_key: Vec<String>,
        values: BTreeMap<String, TypedValue>,
    },
    Delete {
        table: String,
        predicate: StoragePredicate,
    },
}

/// One wholly-dirty table: the source's complete primary-key set for it, so the
/// destination can be reconciled against the source inside the sync transaction.
///
/// Only the ENCODED keys are carried, not the rows — the upserts are already in
/// `IncrementalPayload::row_ops`, and all this pass needs is set membership.
struct TableRescan {
    table: String,
    primary_key: Vec<String>,
    /// `DirtyKey::pk_encoded` for every row present in the source at snapshot
    /// time. A destination row whose encoding is absent from this set was
    /// removed at the source and is deleted at the destination.
    source_pk_encodings: BTreeSet<String>,
}

/// Payload holding dirty-row operations, whole-table reconciliations, and new
/// audit events.
struct IncrementalPayload {
    row_ops: Vec<RowOp>,
    table_rescans: Vec<TableRescan>,
    audit_events: Vec<AuditEvent>,
}

// MARK: - Tests

#[cfg(test)]
mod incremental_replication_tests {
    use super::*;
    use crate::generated_column::{GeneratedColumn, GeneratedExpression};
    use crate::inmemory::InMemoryStorage;
    use crate::replication;
    use crate::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
    use crate::types::{ColumnType, TypedValue};
    // BackendConfiguration and EstateConfiguration used transitively by make_storage.
    use substrate_types::hlc::HLC;
    use uuid::Uuid;

    // ── Synthetic schema ────────────────────────────────────────────────

    fn synthetic_schema() -> SchemaDeclaration {
        let items_table = TableDeclaration {
            name: "items".into(),
            columns: vec![
                ColumnDeclaration { name: "id".into(), column_type: ColumnType::Uuid, nullable: false, default_value: None, role: None },
                ColumnDeclaration { name: "adjective_bitmap".into(), column_type: ColumnType::Bitmap, nullable: false, default_value: None, role: None },
                ColumnDeclaration { name: "payload".into(), column_type: ColumnType::Blob, nullable: false, default_value: None, role: None },
                ColumnDeclaration { name: "tombstoned_at".into(), column_type: ColumnType::Timestamp, nullable: true, default_value: None, role: None },
            ],
            primary_key: vec!["id".into()],
            unique_constraints: vec![],
            generated_columns: vec![GeneratedColumn {
                name: "state_cluster".into(),
                column_type: ColumnType::Int,
                expression: GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("adjective_bitmap".into())),
                    Box::new(GeneratedExpression::Literal(0xF)),
                ),
            }],
            append_only: false,
            hashable: false,
        };

        let events_table = TableDeclaration {
            name: "events".into(),
            columns: vec![
                ColumnDeclaration { name: "topic_id".into(), column_type: ColumnType::Uuid, nullable: false, default_value: None, role: None },
                ColumnDeclaration { name: "seq".into(), column_type: ColumnType::Int, nullable: false, default_value: None, role: None },
                ColumnDeclaration { name: "hlc_stamp".into(), column_type: ColumnType::Hlc, nullable: false, default_value: None, role: None },
                ColumnDeclaration { name: "content".into(), column_type: ColumnType::Text, nullable: false, default_value: None, role: None },
            ],
            primary_key: vec!["topic_id".into(), "seq".into()],
            unique_constraints: vec![],
            generated_columns: vec![],
            append_only: true,
            hashable: false,
        };

        SchemaDeclaration {
            kit_id: "RustIncrementalTestKit".into(),
            version: 1,
            tables: vec![items_table, events_table],
            indices: vec![],
            migrations: vec![],
        }
    }

    fn make_storage(schema: &SchemaDeclaration) -> InMemoryStorage {
        let storage = InMemoryStorage::with_estate(Uuid::new_v4());
        storage.open(schema).expect("open failed");
        storage
    }

    fn item_row(id: Uuid, bitmap: i64) -> BTreeMap<String, TypedValue> {
        let mut m = BTreeMap::new();
        m.insert("id".into(), TypedValue::Uuid(id));
        m.insert("adjective_bitmap".into(), TypedValue::Bitmap(bitmap));
        m.insert("payload".into(), TypedValue::Blob(vec![0xDE, 0xAD]));
        m.insert("tombstoned_at".into(), TypedValue::Null);
        m
    }

    fn event_row(topic_id: Uuid, seq: i64, hlc: HLC) -> BTreeMap<String, TypedValue> {
        let mut m = BTreeMap::new();
        m.insert("topic_id".into(), TypedValue::Uuid(topic_id));
        m.insert("seq".into(), TypedValue::Int(seq));
        m.insert("hlc_stamp".into(), TypedValue::Hlc(hlc));
        m.insert("content".into(), TypedValue::Text("test".into()));
        m
    }

    // ── §10.1 Only dirty rows replicated ─────────────────────────────────

    /// §10.1 — Write 100 rows to source (no session), full-flush baseline to
    /// destination, start session, update 3 rows → only 3 replicated.
    #[test]
    fn only_dirty_rows_replicated() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert 100 rows — session not started yet, so these won't dirty.
        let mut all_ids: Vec<Uuid> = Vec::new();
        for _ in 0..100 {
            let id = Uuid::new_v4();
            all_ids.push(id);
            source.row_store()
                .upsert("items", item_row(id, 0b0101), &["id".to_string()])
                .expect("upsert failed");
        }

        // Full-flush baseline.
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush failed");
        assert_eq!(full_cursor.rows_written, 100, "Baseline should copy 100 rows");

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Update exactly 3 rows — these 3 become dirty.
        let dirty_ids: Vec<Uuid> = all_ids[..3].to_vec();
        for &id in &dirty_ids {
            source.row_store()
                .upsert("items", item_row(id, 0b1111), &["id".to_string()])
                .expect("upsert dirty failed");
        }

        // Drain channels: pull the 3 update events from the observer.
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 3, "Should have exactly 3 dirty rows");

        // Incremental sync.
        let inc_cursor = session.sync(&source, &destination, full_cursor.clone())
            .expect("incremental sync failed").cursor;
        assert_eq!(inc_cursor.rows_written, 3, "Incremental sync should write only 3 dirty rows");

        // Destination must still have 100 rows.
        let dst_count = destination.row_store().count("items", None).expect("count failed");
        assert_eq!(dst_count, 100, "Destination must still have 100 rows");

        // The 3 dirty rows must have updated bitmap value.
        for &id in &dirty_ids {
            let predicate = StoragePredicate::Eq(
                Column::new("items", "id"),
                TypedValue::Uuid(id),
            );
            let rows = destination.row_store()
                .query("items", Some(&predicate), &[], None, None)
                .expect("query failed");
            assert_eq!(rows.len(), 1);
            assert_eq!(
                rows[0].values.get("adjective_bitmap"),
                Some(&TypedValue::Bitmap(0b1111)),
                "Dirty row should have updated bitmap"
            );
        }
    }

    // ── §10.2 Delete propagation ──────────────────────────────────────────

    /// §10.2 — Delete a row on source → destination deletes it on next sync.
    #[test]
    fn delete_propagation() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert one row, full-flush baseline.
        let row_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(row_id, 0b0101), &["id".to_string()])
            .expect("upsert failed");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(full_cursor.rows_written, 1);

        // Start session.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Delete the row from source.
        let del_pred = StoragePredicate::Eq(
            Column::new("items", "id"),
            TypedValue::Uuid(row_id),
        );
        source.row_store().delete("items", &del_pred).expect("delete failed");

        // Drain channels.
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "Delete should dirty 1 key");

        // Sync — re-scan finds no row → delete issued to destination.
        let del_cursor = session.sync(&source, &destination, full_cursor)
            .expect("sync failed").cursor;
        assert_eq!(del_cursor.rows_written, 1, "Delete sync should record 1 operation");

        let dst_count = destination.row_store().count("items", None).expect("count");
        assert_eq!(dst_count, 0, "Destination must not have the deleted row");
    }

    // ── §10.3 Restart-resume from watermark ──────────────────────────────

    /// §10.3 — New session with saved cursor; only new audit events after watermark.
    #[test]
    fn restart_resume_from_watermark() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);
        let estate_id = source.configuration().estate_id;

        // Insert row 1 + audit event 1, full-flush baseline.
        let id1 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id1, 0b0001), &["id".to_string()])
            .expect("upsert r1");
        let ae1 = tests_helpers::make_audit_event(estate_id, id1, 1_000);
        source.audit_log().append(ae1.clone()).expect("append ae1");

        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        let watermark = full_cursor.hlc_watermark;
        assert!(watermark.is_some(), "Watermark should be non-nil");

        // Start new session (simulates restart with saved cursor).
        let session2 = IncrementalReplicationSession::start(&source, &schema);

        // Insert row 2 + audit event 2 with HLC strictly after the watermark.
        let id2 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id2, 0b1010), &["id".to_string()])
            .expect("upsert r2");
        let ae2 = tests_helpers::make_audit_event(estate_id, id2, 2_000);
        source.audit_log().append(ae2).expect("append ae2");

        // Drain channels.
        session2.drain_channels();

        let cursor2 = session2.sync(&source, &destination, full_cursor)
            .expect("sync2 failed").cursor;

        assert_eq!(cursor2.rows_written, 1, "Second session should sync only the new row");
        assert_eq!(cursor2.audit_events_written, 1,
            "Second session should sync only the new audit event (after watermark)");

        let dst_count = destination.row_store().count("items", None).expect("count");
        assert_eq!(dst_count, 2, "Destination must have both rows");
    }

    // ── §10.4 Empty dirty-set returns cursor unchanged ────────────────────

    /// §10.4 — Empty dirty-set sync returns the fromCursor unchanged.
    #[test]
    fn empty_dirty_set_returns_cursor_unchanged() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        let hlc = HLC::new(42_000, 7, 3);
        let input_cursor = ReplicationCursor {
            hlc_watermark: Some(hlc),
            rows_written: 17,
            audit_events_written: 5,
            blobs_written: 0,
        };

        // No writes → empty dirty-set (after drain_channels).
        let output_cursor = session.sync(&source, &destination, input_cursor.clone())
            .expect("sync failed").cursor;

        assert_eq!(output_cursor.hlc_watermark, Some(hlc));
        assert_eq!(output_cursor.rows_written, 17);
        assert_eq!(output_cursor.audit_events_written, 5);
    }

    // ── §10.5 Session observes multiple tables ────────────────────────────

    /// §10.5 — Session subscribes to all tables; dirty keys from each accumulate.
    #[test]
    fn session_observes_multiple_tables() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Insert one item + one event.
        let item_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(item_id, 0b0110), &["id".to_string()])
            .expect("upsert item");

        let topic_id = Uuid::new_v4();
        let hlc = HLC::new(5_000, 0, 1);
        source.row_store()
            .upsert("events", event_row(topic_id, 1, hlc), &["topic_id".to_string(), "seq".to_string()])
            .expect("upsert event");

        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 2,
            "Session should have 2 dirty keys: 1 item + 1 event");

        let zero_cursor = ReplicationCursor { hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0 };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("sync failed").cursor;
        assert_eq!(cursor.rows_written, 2);

        let item_count = destination.row_store().count("items", None).expect("count items");
        let event_count = destination.row_store().count("events", None).expect("count events");
        assert_eq!(item_count, 1);
        assert_eq!(event_count, 1);
    }

    // ── §10.6 Audit event delta ────────────────────────────────────────────

    /// §10.6 — Only audit events after the watermark are sent on incremental sync.
    #[test]
    fn audit_event_delta_only_new_events_after_watermark() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);
        let estate_id = source.configuration().estate_id;

        // Append 2 audit events + 1 row; full-flush as baseline.
        let ae1 = tests_helpers::make_audit_event(estate_id, Uuid::new_v4(), 1_000);
        let ae2 = tests_helpers::make_audit_event(estate_id, Uuid::new_v4(), 2_000);
        source.audit_log().append_batch(vec![ae1, ae2]).expect("append batch");

        let id1 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id1, 0b0001), &["id".to_string()])
            .expect("upsert");

        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        let dst_audit_after_full = destination.audit_log().count().expect("count");
        assert_eq!(dst_audit_after_full, 2, "Baseline flush should deliver both audit events");

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Append event 3 with HLC strictly after watermark.
        let ae3 = tests_helpers::make_audit_event(estate_id, Uuid::new_v4(), 3_000);
        source.audit_log().append(ae3).expect("append ae3");

        // Insert another row so dirty-set is non-empty.
        let id2 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id2, 0b1000), &["id".to_string()])
            .expect("upsert2");

        session.drain_channels();

        let cursor2 = session.sync(&source, &destination, full_cursor)
            .expect("sync2 failed").cursor;
        assert_eq!(cursor2.audit_events_written, 1,
            "Incremental sync should deliver only the new audit event");

        let dst_audit_total = destination.audit_log().count().expect("count total");
        assert_eq!(dst_audit_total, 3, "Destination must have all 3 audit events");
    }

    // ── §10.7 Full-snapshot path unchanged ────────────────────────────────

    /// §10.7 — Full-snapshot flush still works alongside an active session.
    #[test]
    fn full_snapshot_path_unchanged_beside_session() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Insert 5 rows.
        for _ in 0..5 {
            source.row_store()
                .upsert("items", item_row(Uuid::new_v4(), 0b0001), &["id".to_string()])
                .expect("upsert");
        }

        // Full flush.
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(full_cursor.rows_written, 5);

        let dst_count = destination.row_store().count("items", None).expect("count");
        assert_eq!(dst_count, 5);

        // Second full flush — idempotent.
        let full_cursor2 = replication::flush(&source, &destination, &schema).expect("flush2");
        assert_eq!(full_cursor2.rows_written, 5);
        let dst_count2 = destination.row_store().count("items", None).expect("count2");
        assert_eq!(dst_count2, 5, "Second full flush must not duplicate rows");

        let _ = session; // session still usable
    }

    // ── §10.8 Abort-then-retry restores dirty keys ────────────────────────

    /// §10.8 — Abort-then-retry: drain the dirty-set (simulating what sync does
    /// before any fallible work), call restore (simulating the error-path restore),
    /// verify the keys survive, then do a clean sync that replicates them.
    ///
    /// This is the gate-return criterion from commit 654418f7:
    ///   1. Dirty rowA.
    ///   2. Drain the dirty-set into a local (simulates sync draining before work).
    ///   3. Call restore with the drained keys (simulates the error path).
    ///   4. Dirty-set must still contain rowA.
    ///   5. Clean sync → rowA replicates successfully.
    #[test]
    fn abort_then_retry_restores_dirty_keys() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert one row and full-flush as baseline.
        let row_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(row_id, 0b0001), &["id".to_string()])
            .expect("upsert failed");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush failed");
        assert_eq!(full_cursor.rows_written, 1, "Baseline should copy 1 row");

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Update the row to make it dirty.
        source.row_store()
            .upsert("items", item_row(row_id, 0b1111), &["id".to_string()])
            .expect("upsert dirty failed");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "Should have exactly 1 dirty row");

        // Simulate a failed sync: drain the keys, then restore them (as the error
        // path does). This verifies the restore mechanism without requiring a
        // concrete FailingStorage implementation.
        let drained = session.dirty_set.drain();
        assert_eq!(drained.keys.len(), 1, "Drain should return 1 key");
        assert_eq!(session.dirty_set.count(), 0, "After drain, dirty-set must be empty");

        // Restore — simulates what sync does when it encounters an error.
        session.dirty_set.restore(&drained);
        assert_eq!(session.dirty_set.count(), 1,
            "After restore, dirty-set must contain the drained key again");

        // Now do a real sync — it should replicate the restored dirty key.
        let cursor = session.sync(&source, &destination, full_cursor)
            .expect("retry sync failed").cursor;
        assert_eq!(cursor.rows_written, 1, "Retry sync must replicate the restored dirty row");

        // Verify the updated bitmap value arrived at destination.
        let predicate = StoragePredicate::Eq(
            Column::new("items", "id"),
            TypedValue::Uuid(row_id),
        );
        let rows = destination.row_store()
            .query("items", Some(&predicate), &[], None, None)
            .expect("query failed");
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].values.get("adjective_bitmap"),
            Some(&TypedValue::Bitmap(0b1111)),
            "Retry sync must have written the updated row"
        );
    }

    // ── §10.9 Keys dirtied during failed run survive alongside restored keys ──

    /// §10.9 — Keys dirtied DURING a failed sync run survive in the dirty-set
    /// alongside the restored drained keys (union, no overwrite of newer dirt).
    ///
    /// Setup:
    ///   1. Dirty rowA (will be drained).
    ///   2. Drain rowA into a local, then accumulate rowB (simulates new observer
    ///      event arriving DURING the failed run, after the drain).
    ///   3. Restore rowA — dirty-set now has both rowA and rowB.
    ///   4. Sync → both rowA and rowB replicate.
    #[test]
    fn keys_dirtied_during_failed_run_survive_alongside_restored_keys() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let row_a_id = Uuid::new_v4();
        let row_b_id = Uuid::new_v4();

        source.row_store()
            .upsert("items", item_row(row_a_id, 0b0001), &["id".to_string()])
            .expect("upsert rowA");
        source.row_store()
            .upsert("items", item_row(row_b_id, 0b0010), &["id".to_string()])
            .expect("upsert rowB");

        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush failed");
        assert_eq!(full_cursor.rows_written, 2, "Baseline should copy 2 rows");

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Update rowA — it gets dirtied.
        source.row_store()
            .upsert("items", item_row(row_a_id, 0b1001), &["id".to_string()])
            .expect("update rowA");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "Only rowA dirtied so far");

        // Drain (simulates sync draining before fallible work).
        let drained = session.dirty_set.drain();
        assert_eq!(drained.keys.len(), 1, "Drain must yield 1 key (rowA)");

        // Accumulate rowB AFTER drain (simulates observer event during inflight sync).
        source.row_store()
            .upsert("items", item_row(row_b_id, 0b1010), &["id".to_string()])
            .expect("update rowB");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "rowB accumulated after drain");

        // Restore rowA — dirty-set must now have both rowA and rowB (union).
        session.dirty_set.restore(&drained);
        assert_eq!(session.dirty_set.count(), 2,
            "After restore, dirty-set must contain both rowA (restored) and rowB (new)");

        // Sync must replicate both rows.
        let cursor = session.sync(&source, &destination, full_cursor)
            .expect("sync failed").cursor;
        assert_eq!(cursor.rows_written, 2,
            "Sync must replicate both rowA (restored) and rowB (new dirty)");

        // Verify updated values at destination.
        let pred_a = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_a_id));
        let rows_a = destination.row_store()
            .query("items", Some(&pred_a), &[], None, None).expect("query rowA");
        assert_eq!(rows_a[0].values.get("adjective_bitmap"), Some(&TypedValue::Bitmap(0b1001)));

        let pred_b = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_b_id));
        let rows_b = destination.row_store()
            .query("items", Some(&pred_b), &[], None, None).expect("query rowB");
        assert_eq!(rows_b[0].values.get("adjective_bitmap"), Some(&TypedValue::Bitmap(0b1010)));
    }

    // ── §10.B Blob propagation via incremental replication ────────────────

    /// §10.B1 — Blob write propagates on next incremental sync, byte-identical.
    #[test]
    fn incremental_blob_write_propagates() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Start session before any blobs exist.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a blob on source — the blob observer delivers a Put event.
        let blob_key = "incremental-blob-key";
        let blob_bytes: Vec<u8> = vec![0xFE, 0xED, 0xFA, 0xCE];
        source.blob_store().put(blob_key, &blob_bytes).expect("put blob");

        // Insert a row so the dirty-set is non-empty; drain both channels.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b0101), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();
        session.drain_blob_channel();

        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must contain the put event");

        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("incremental sync failed").cursor;
        assert!(cursor.blobs_written >= 1,
            "Incremental sync must propagate the blob put");

        let actual = destination.blob_store().get(blob_key).expect("get blob")
            .expect("blob must be present at destination");
        assert_eq!(actual, blob_bytes, "Blob must be byte-identical at destination");
    }

    /// §10.B2 — Blob delete propagates on next incremental sync.
    #[test]
    fn incremental_blob_delete_propagates() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Pre-populate blob on both source and destination (simulates prior full flush).
        let blob_key = "delete-me-blob";
        let blob_bytes: Vec<u8> = vec![0x11, 0x22, 0x33];
        source.blob_store().put(blob_key, &blob_bytes).expect("put src");
        destination.blob_store().put(blob_key, &blob_bytes).expect("put dst");

        // Start session AFTER pre-population.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Delete the blob from source.
        source.blob_store().delete(blob_key).expect("delete");

        // Insert a row so the dirty-set is non-empty.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b1010), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();
        session.drain_blob_channel();

        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("sync failed").cursor;
        assert!(cursor.blobs_written >= 1,
            "Incremental sync must propagate the blob delete");

        let result = destination.blob_store().get(blob_key).expect("get blob");
        assert!(result.is_none(),
            "Deleted blob must be absent from destination after sync");
    }

    // ── §10.B4 InMemory observer emits real blob events ───────────────────

    /// §10.B4 — InMemoryStorage delivers real BlobChange events through
    /// observe_blobs(). drain_blob_channel() accumulates them into BlobDirtyAccumulator;
    /// sync propagates the blob to the destination.
    ///
    /// This proves the observer mechanism is live for the InMemory backend.
    /// The SQLite backend mirrors this via putBlob/deleteBlob calling
    /// registry.notify_blob() directly (see SQLiteObserver.swift).
    #[test]
    fn inmemory_observer_delivers_real_blob_events() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Start session before any blobs are written.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a blob — InMemoryStorage emits the event through BlobObserverHub.
        let blob_key = "real-event-blob";
        let blob_bytes: Vec<u8> = vec![0x10, 0x20, 0x30, 0x40];
        source.blob_store().put(blob_key, &blob_bytes).expect("put blob");

        // Drain the blob channel — must pick up the live event.
        session.drain_blob_channel();

        // BlobDirtyAccumulator must contain the put event — proving the observer
        // delivered a real event rather than a disconnected (no-op) channel.
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must contain the put event after drain_blob_channel");

        // Insert a row so the row dirty-set is non-empty.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b0001), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();

        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("sync failed").cursor;
        assert!(cursor.blobs_written >= 1,
            "Incremental sync must propagate the blob put via real observer events");

        let actual = destination.blob_store().get(blob_key).expect("get")
            .expect("blob must be at destination");
        assert_eq!(actual, blob_bytes, "Blob must be byte-identical at destination");
    }

    // ── §10.B5 Real-abort restores dirty blob keys alongside row keys ────

    /// §10.B5 — A real sync failure (nil-bytes Put — fail-loud path in the transaction
    /// closure) after blob ops are drained from BlobDirtyAccumulator restores both the
    /// row dirty-set and the blob dirty-set before returning the error.
    /// A subsequent retry (after fixing the bad entry) replicates the blob.
    ///
    /// This is the mirror of the row-side §10.9 abort-then-retry test.
    /// It proves the REAL restore path rather than a manual drain/restore simulation:
    ///
    ///   1. Accumulate a real blob put (via InMemory observer + drain_blob_channel).
    ///   2. Accumulate a real row dirty key.
    ///   3. Inject a nil-bytes Put for a second key (fail-loud trigger).
    ///   4. sync() → drains both sets → snapshotDirtyRows OK → transaction closure
    ///      hits the nil-bytes Put → BackendError → rollback → catch → restore BOTH
    ///      dirty_keys and dirty_blobs → return Err.
    ///   5. After the error: blob_dirty.count() >= 1 (real blob restored), dirty_set.count() >= 1.
    ///   6. Remove the nil-bytes entry; retry → real blob replicates.
    #[test]
    fn real_abort_restores_dirty_blobs_alongside_rows() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert a row and full-flush as baseline.
        let row_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(row_id, 0b0001), &["id".to_string()])
            .expect("upsert baseline");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(full_cursor.rows_written, 1);

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a real blob — InMemory observer delivers the event.
        let real_key = "real-blob-key";
        let real_bytes: Vec<u8> = vec![0xDE, 0xAD, 0xBE, 0xEF];
        source.blob_store().put(real_key, &real_bytes).expect("put real blob");

        // Drain blob channel: accumulates the real Put event.
        session.drain_blob_channel();
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must hold the real Put before inject");

        // Inject a second blob key with nil bytes to trigger the fail-loud path
        // in the transaction closure (BlobEvent::Put with bytes: None).
        let poison_key = "poison-blob-key";
        session.blob_dirty.inject_nil_bytes_put(poison_key.to_string());
        assert!(session.blob_dirty.count() >= 2,
            "BlobDirtyAccumulator must hold both the real Put and the nil-bytes poison entry");

        // Dirty the row so it is also in the dirty-set.
        source.row_store()
            .upsert("items", item_row(row_id, 0b1111), &["id".to_string()])
            .expect("update row");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1,
            "dirty_set must hold the updated row before the failing sync");

        // --- First sync must fail on the nil-bytes Put. ---
        let result = session.sync(&source, &destination, full_cursor.clone());
        assert!(result.is_err(),
            "sync must fail when a blob Put entry has nil bytes (fail-loud contract)");

        // Destination blob must not have been written (transaction rolled back).
        assert!(destination.blob_store().get(real_key).expect("get after abort").is_none(),
            "real blob must not be at destination after the failed sync");

        // RETRY-PRESERVATION: both the real blob and the row dirty key must be restored.
        // No sleep: the restore in the Rust sync error path is synchronous (map_err runs
        // inline, not in a spawned task), so the restore is complete when sync() returns.
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must be restored after abort (got {})", session.blob_dirty.count());
        assert!(session.dirty_set.count() >= 1,
            "Row dirty-set must be restored after abort (got {})", session.dirty_set.count());

        // Remove the poison entry by draining and re-accumulating only the real blob.
        // (In production, the caller would fix the underlying issue — here we can't
        // easily re-accumulate via the public API, so we drain and re-accumulate.)
        let drained = session.blob_dirty.drain();
        let real_entries: Vec<_> = drained.into_iter()
            .filter(|(k, _)| k.as_str() != poison_key)
            .collect();
        session.blob_dirty.restore(&real_entries);

        // Drain the row dirty-set too so it survives for the retry.
        // (drain was NOT called by the abort — the restore brought it back; confirm count.)
        assert!(session.dirty_set.count() >= 1,
            "Row dirty-set must still be non-empty for retry");

        // --- Retry sync: real blob must replicate. ---
        let retry_cursor = session.sync(&source, &destination, full_cursor)
            .expect("retry sync must succeed after removing the poison entry").cursor;
        assert!(retry_cursor.blobs_written >= 1,
            "Retry must replicate the real blob that was drain-restored (got {})", retry_cursor.blobs_written);
        assert!(retry_cursor.rows_written >= 1,
            "Retry must replicate the row that was drain-restored (got {})", retry_cursor.rows_written);

        let actual = destination.blob_store().get(real_key).expect("get after retry")
            .expect("real blob must be at destination after retry");
        assert_eq!(actual, real_bytes, "Real blob must be byte-identical at destination after retry");
    }

    /// §10.B3 — Abort-then-retry restores dirty blob keys.
    #[test]
    fn abort_then_retry_restores_dirty_blob_keys() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a blob on source.
        let blob_key = "retry-blob";
        let blob_bytes: Vec<u8> = vec![0xAB, 0xCD, 0xEF];
        source.blob_store().put(blob_key, &blob_bytes).expect("put");

        // Insert a row to make dirty-set non-empty.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b0001), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();
        session.drain_blob_channel();

        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must contain the put event");

        // Drain the blob accumulator (simulates what sync does before fallible work).
        let drained = session.blob_dirty.drain();
        assert!(!drained.is_empty(), "Drain must return at least 1 entry");

        // Blob must not be in destination yet.
        assert!(destination.blob_store().get(blob_key).expect("get").is_none(),
            "Blob must not be in destination before sync");

        // Restore the drained blobs (simulates the error-path restore).
        session.blob_dirty.restore(&drained);
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must still contain the key after restore");

        // Clean sync — blob must propagate.
        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("retry sync failed").cursor;
        assert!(cursor.blobs_written >= 1, "Retry sync must replicate the blob");

        let actual = destination.blob_store().get(blob_key).expect("get")
            .expect("blob must be present after retry sync");
        assert_eq!(actual, blob_bytes,
            "Blob must be byte-identical at destination after retry sync");
    }

    // ── §10.C Value-less changes on a durable backend (MXE-IR) ────────────
    //
    // The whole §10.C block exercises the durable path, which is the one that
    // was dark. Every test above this point runs on InMemoryStorage, which
    // populates `TableChange.values` on all four verbs — so they passed while
    // SQLite, which emits `values: None` for predicate update and delete, was
    // dropping every update and delete on the floor.
    //
    // Codex finding 74e3b7f7e6288191ba31644e4fa4b43b.

    /// A schema carrying one keyed table and one table with NO declared primary
    /// key, for the unresolvable-cycle tests (§10.C6, §10.C7).
    ///
    /// An empty `primary_key` is legal — the DDL emitter guards with
    /// `if !decl.primary_key.is_empty()` and simply omits the PRIMARY KEY clause
    /// (rust/src/sqlite.rs:452). Such a table cannot be reconciled: there is no
    /// column set on which to compare a source row against a destination row, so
    /// a change the session cannot key on it is unresolvable at every
    /// granularity.
    fn pk_less_schema() -> SchemaDeclaration {
        let mut schema = synthetic_schema();
        schema.tables.push(TableDeclaration {
            name: "keyless".into(),
            columns: vec![
                ColumnDeclaration { name: "label".into(), column_type: ColumnType::Text, nullable: false, default_value: None, role: None },
                ColumnDeclaration { name: "counter".into(), column_type: ColumnType::Int, nullable: false, default_value: None, role: None },
            ],
            primary_key: vec![],
            unique_constraints: vec![],
            generated_columns: vec![],
            append_only: false,
            hashable: false,
        });
        schema
    }

    /// Open a durable SQLite estate in a fresh temp file.
    ///
    /// Uses the public `SqliteStorage` surface only — this mission does not
    /// modify `sqlite.rs`, which is reserved by TASK-MXE-2026-0220 / 0225.
    fn make_sqlite_storage(schema: &SchemaDeclaration) -> crate::sqlite::SqliteStorage {
        let path = std::env::temp_dir().join(format!("pk_mxe_ir_{}.sqlite", Uuid::new_v4()));
        let config = crate::storage::EstateConfiguration::new(
            Uuid::new_v4(),
            crate::storage::BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = crate::sqlite::SqliteStorage::new(config).expect("open sqlite storage");
        storage.open(schema).expect("open schema");
        storage
    }

    /// §10.C1 — An update through `row_store.update` on SQLite reaches the
    /// destination.
    ///
    /// REGRESSION TEST: fails against pre-fix code. `sqlite.rs` update emits
    /// `values: None`, the old `DirtySet::accumulate` returned without recording
    /// anything, the dirty set came back empty, and `sync` took the early
    /// return — reporting success having replicated nothing.
    #[test]
    fn update_through_row_store_propagates_on_sqlite() {
        let schema = synthetic_schema();
        let source = make_sqlite_storage(&schema);
        let destination = make_sqlite_storage(&schema);

        let row_id = Uuid::new_v4();
        source.row_store()
            .insert("items", item_row(row_id, 0b0001))
            .expect("insert");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(full_cursor.rows_written, 1);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Predicate update — the verb that emits no values on this backend.
        let mut set_values = BTreeMap::new();
        set_values.insert("adjective_bitmap".to_string(), TypedValue::Bitmap(0b1111));
        let predicate =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_id));
        let updated = source.row_store()
            .update("items", set_values, &predicate)
            .expect("update");
        assert_eq!(updated, 1, "Source update must affect exactly one row");

        session.drain_channels();
        assert_eq!(
            session.dirty_set.pending_rescan_tables(),
            vec!["items".to_string()],
            "A value-less update must mark its table for re-scan"
        );
        assert_eq!(
            session.dirty_set.count(), 0,
            "No row can be named from a value-less change"
        );

        let outcome = session.sync(&source, &destination, full_cursor).expect("sync");
        assert_eq!(outcome.rescanned_tables, vec!["items".to_string()]);
        assert!(outcome.is_complete(), "Nothing here is unresolvable");

        let rows = destination.row_store()
            .query("items", Some(&predicate), &[], None, None)
            .expect("query");
        assert_eq!(rows.len(), 1, "Destination must still hold the row");
        assert_eq!(
            rows[0].values.get("adjective_bitmap"),
            Some(&TypedValue::Bitmap(0b1111)),
            "Destination must carry the UPDATED value, not the pre-update one"
        );
    }

    /// §10.C2 — A delete through `row_store.delete` on SQLite removes the
    /// destination row.
    ///
    /// REGRESSION TEST: fails against pre-fix code for the same reason as
    /// §10.C1. This is the confidentiality case in its simplest form — the
    /// replica kept content the source had removed.
    #[test]
    fn delete_through_row_store_propagates_on_sqlite() {
        let schema = synthetic_schema();
        let source = make_sqlite_storage(&schema);
        let destination = make_sqlite_storage(&schema);

        let doomed_id = Uuid::new_v4();
        let survivor_id = Uuid::new_v4();
        for id in [doomed_id, survivor_id] {
            source.row_store().insert("items", item_row(id, 0b0101)).expect("insert");
        }
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(destination.row_store().count("items", None).expect("count"), 2);

        let session = IncrementalReplicationSession::start(&source, &schema);

        let doomed_pred =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(doomed_id));
        source.row_store().delete("items", &doomed_pred).expect("delete");

        session.drain_channels();
        assert_eq!(
            session.dirty_set.pending_rescan_tables(),
            vec!["items".to_string()],
            "A value-less delete must mark its table for re-scan"
        );

        let outcome = session.sync(&source, &destination, full_cursor).expect("sync");
        assert!(outcome.is_complete());

        assert!(
            destination.row_store().query("items", Some(&doomed_pred), &[], None, None)
                .expect("query doomed").is_empty(),
            "The deleted row must be gone from the destination"
        );
        // The reconciliation must not overreach: a row the source still has is
        // not collateral damage.
        let survivor_pred =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(survivor_id));
        assert_eq!(
            destination.row_store().query("items", Some(&survivor_pred), &[], None, None)
                .expect("query survivor").len(),
            1,
            "The row that survived at the source must survive at the destination"
        );
        assert_eq!(destination.row_store().count("items", None).expect("count"), 1);
    }

    /// §10.C3 — TOMBSTONE-THEN-REPLICATE, the confidentiality case stated
    /// directly rather than inferred from the generic update test.
    ///
    /// A withdrawal marks the row rather than removing it: `tombstoned_at` goes
    /// from null to a timestamp through a predicate update, which is exactly the
    /// value-less verb. If that update does not travel, the destination keeps
    /// presenting a withdrawn row as live — and because a later insert would
    /// advance the destination's audit watermark anyway, the system would record
    /// that it had replicated a withdrawal it never sent.
    ///
    /// Both shapes are asserted: the withdrawn row carries its tombstone at the
    /// destination, and an expunged (hard-deleted) row is absent entirely.
    #[test]
    fn tombstoned_and_expunged_rows_are_not_live_at_destination_after_one_cycle() {
        let schema = synthetic_schema();
        let source = make_sqlite_storage(&schema);
        let destination = make_sqlite_storage(&schema);

        let withdrawn_id = Uuid::new_v4();
        let expunged_id = Uuid::new_v4();
        let live_id = Uuid::new_v4();
        for id in [withdrawn_id, expunged_id, live_id] {
            source.row_store().insert("items", item_row(id, 0b0101)).expect("insert");
        }
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");

        let withdrawn_pred =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(withdrawn_id));

        // Baseline: the destination shows the row as live (no tombstone).
        let baseline = destination.row_store()
            .query("items", Some(&withdrawn_pred), &[], None, None)
            .expect("baseline query");
        assert_eq!(baseline.len(), 1);
        assert_eq!(
            baseline[0].values.get("tombstoned_at"),
            Some(&TypedValue::Null),
            "Before the withdrawal the destination copy must be live"
        );

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Withdrawal: tombstone the row at the source.
        let mut tombstone_values = BTreeMap::new();
        tombstone_values.insert(
            "tombstoned_at".to_string(),
            TypedValue::Timestamp(1_800_000_000),
        );
        source.row_store()
            .update("items", tombstone_values, &withdrawn_pred)
            .expect("tombstone update");
        // Expunge: remove the row at the source outright.
        let expunged_pred =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(expunged_id));
        source.row_store().delete("items", &expunged_pred).expect("expunge delete");

        session.drain_channels();
        let outcome = session.sync(&source, &destination, full_cursor).expect("sync");
        assert!(outcome.is_complete(), "Both changes are resolvable by re-scan");

        // The withdrawn row must carry its tombstone at the destination, so a
        // tombstone-honouring read no longer returns it as live.
        let withdrawn_rows = destination.row_store()
            .query("items", Some(&withdrawn_pred), &[], None, None)
            .expect("query withdrawn");
        assert_eq!(withdrawn_rows.len(), 1);
        assert_ne!(
            withdrawn_rows[0].values.get("tombstoned_at"),
            Some(&TypedValue::Null),
            "The destination must not still present a withdrawn row as live"
        );

        // The expunged row must be absent outright.
        assert!(
            destination.row_store().query("items", Some(&expunged_pred), &[], None, None)
                .expect("query expunged").is_empty(),
            "An expunged row must not be readable at the destination"
        );

        // The untouched row is unaffected.
        let live_pred =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(live_id));
        let live_rows = destination.row_store()
            .query("items", Some(&live_pred), &[], None, None)
            .expect("query live");
        assert_eq!(live_rows.len(), 1, "An untouched row must survive the reconciliation");
        assert_eq!(live_rows[0].values.get("tombstoned_at"), Some(&TypedValue::Null));
    }

    /// §10.C4 — A cycle whose only activity was deletions does not report as a
    /// no-op.
    ///
    /// The empty-dirty-set early return is what made this silent: a deletions-
    /// only cycle returned `from_cursor` verbatim, indistinguishable from an idle
    /// cycle. The cycle must now show its work.
    #[test]
    fn deletions_only_cycle_is_not_reported_as_a_no_op() {
        let schema = synthetic_schema();
        let source = make_sqlite_storage(&schema);
        let destination = make_sqlite_storage(&schema);

        for _ in 0..3 {
            source.row_store()
                .insert("items", item_row(Uuid::new_v4(), 0b0101))
                .expect("insert");
        }
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Deletions and nothing else.
        let deleted = source.row_store()
            .delete("items", &StoragePredicate::IsTrue)
            .expect("delete all");
        assert_eq!(deleted, 3);

        session.drain_channels();
        let outcome = session.sync(&source, &destination, full_cursor).expect("sync");

        assert!(
            !outcome.rescanned_tables.is_empty(),
            "A deletions-only cycle must report the work it did, not look idle"
        );
        assert_eq!(
            outcome.cursor.rows_written, 3,
            "All three deletions must be counted, got {}",
            outcome.cursor.rows_written
        );
        assert_eq!(
            destination.row_store().count("items", None).expect("count"), 0,
            "Destination must be emptied"
        );
    }

    /// §10.C5 — A change shaped like the PostgreSQL backend's predicate update
    /// and delete — no values AND no row_key — still resolves.
    ///
    /// The live-server legs of the PostgreSQL suite are gated on
    /// PERSISTENCEKIT_PG_URL and skip when it is unset, so they cannot establish
    /// that this shape resolves. This test feeds the exact emission shape
    /// (`postgres.rs` predicate update `values: None`, `row_key: None`) through
    /// the session on a backend that is always present, so the code path
    /// PostgreSQL takes is covered on every run.
    #[test]
    fn postgres_shaped_change_without_values_or_row_key_resolves() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let row_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(row_id, 0b0001), &["id".to_string()])
            .expect("upsert");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Mutate the source, then hand the session the PostgreSQL-shaped change
        // rather than the InMemory one (InMemory populates values, which would
        // exercise the row-dirt path instead of the one under test).
        let predicate =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_id));
        let mut set_values = BTreeMap::new();
        set_values.insert("adjective_bitmap".to_string(), TypedValue::Bitmap(0b1010));
        source.row_store()
            .update("items", set_values, &predicate)
            .expect("update");

        session.dirty_set.accumulate(&TableChange {
            table: "items".into(),
            event: StorageEvent::Update,
            row_key: None,
            values: None,
            hlc: None,
            origin: crate::observer::ChangeOrigin::Local,
            changed_columns: None,
        });

        let outcome = session.sync(&source, &destination, full_cursor).expect("sync");
        assert_eq!(outcome.rescanned_tables, vec!["items".to_string()]);

        let rows = destination.row_store()
            .query("items", Some(&predicate), &[], None, None)
            .expect("query");
        assert_eq!(
            rows[0].values.get("adjective_bitmap"),
            Some(&TypedValue::Bitmap(0b1010)),
            "A change with neither values nor row_key must still carry the update across"
        );
    }

    /// §10.C6 — The audit watermark does not advance past an unresolved cycle.
    ///
    /// A table with no declared primary key can be neither named nor
    /// reconciled. The cycle must refuse it out loud: report it, copy no audit
    /// events, and leave the watermark where it was so the next cycle re-reads
    /// the same range. Advancing it is what would make the miss permanent.
    #[test]
    fn watermark_does_not_advance_past_an_unresolved_cycle() {
        let schema = pk_less_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);
        let estate_id = source.configuration().estate_id;

        // An audit event that a resolved cycle WOULD carry the watermark to.
        source.audit_log()
            .append(tests_helpers::make_audit_event(estate_id, Uuid::new_v4(), 9_000))
            .expect("append audit event");

        let session = IncrementalReplicationSession::start(&source, &schema);

        let incoming = HLC::new(1_000, 0, 1);
        let from_cursor = ReplicationCursor {
            hlc_watermark: Some(incoming),
            rows_written: 0,
            audit_events_written: 0,
            blobs_written: 0,
        };

        // A value-less change on the primary-key-less table: unresolvable at
        // both granularities.
        session.dirty_set.accumulate(&TableChange {
            table: "keyless".into(),
            event: StorageEvent::Update,
            row_key: None,
            values: None,
            hlc: None,
            origin: crate::observer::ChangeOrigin::Local,
            changed_columns: None,
        });
        assert_eq!(
            session.dirty_set.pending_unresolvable_tables(),
            vec!["keyless".to_string()],
            "A change on a PK-less table must be recorded as unresolvable, not dropped"
        );

        let outcome = session.sync(&source, &destination, from_cursor).expect("sync");

        assert!(!outcome.is_complete(), "The cycle must report itself incomplete");
        assert_eq!(
            outcome.unresolved_tables,
            vec!["keyless".to_string()],
            "The refusal must name the table"
        );
        assert_eq!(
            outcome.cursor.hlc_watermark,
            Some(incoming),
            "The watermark must be unmoved, got {:?}",
            outcome.cursor.hlc_watermark
        );
        assert_eq!(
            outcome.cursor.audit_events_written, 0,
            "An incomplete cycle must copy no audit events — they move with the watermark"
        );
        assert!(
            destination.audit_log().iterate(None, None, usize::MAX).expect("iterate").is_empty(),
            "No audit event may reach the destination on an incomplete cycle"
        );
    }

    /// §10.C8 — The re-scan reconciliation is safe across DIFFERENT backend
    /// types: a durable SQLite source replicating into an InMemory destination.
    ///
    /// Every other test in this block runs SQLite→SQLite or InMemory→InMemory, so
    /// both ends decode through the same reader and their primary-key encodings
    /// necessarily agree. A cross-backend pair does not have that guarantee: the
    /// source is read through `source.row_store()` and the destination through
    /// `txn.row_store()`, and a value can round-trip into a different
    /// `TypedValue` variant between the two.
    ///
    /// The two decoders DO agree for this pair and these column types — this test
    /// passes with the reconcile pass on either side of the upserts, which was
    /// checked explicitly. So it is not a guard on the pass ordering; it is the
    /// only cross-backend coverage in the suite, pinning that a value-less
    /// update and delete both land correctly when the ends differ.
    #[test]
    fn rescan_reconciliation_is_safe_across_different_backend_types() {
        let schema = synthetic_schema();
        let source = make_sqlite_storage(&schema);
        let destination = make_storage(&schema); // InMemory — a DIFFERENT backend type

        let kept_id = Uuid::new_v4();
        let doomed_id = Uuid::new_v4();
        source.row_store().insert("items", item_row(kept_id, 0b0001)).expect("insert kept");
        source.row_store().insert("items", item_row(doomed_id, 0b0101)).expect("insert doomed");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(destination.row_store().count("items", None).expect("count"), 2);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // One value-less update and one value-less delete, both on the durable
        // source — so the table is re-scanned and reconciled against a
        // destination of a different backend type.
        let kept_pred =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(kept_id));
        let mut set_values = BTreeMap::new();
        set_values.insert("adjective_bitmap".to_string(), TypedValue::Bitmap(0b1111));
        source.row_store().update("items", set_values, &kept_pred).expect("update");
        let doomed_pred =
            StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(doomed_id));
        source.row_store().delete("items", &doomed_pred).expect("delete");

        session.drain_channels();
        let outcome = session.sync(&source, &destination, full_cursor).expect("sync");
        assert!(outcome.is_complete());

        // The destination must end up matching the source EXACTLY: the surviving
        // row present and updated, the deleted row gone, and — the property that
        // catches a reordering — the table not emptied.
        let all = destination.row_store()
            .query("items", None, &[], None, None)
            .expect("query all");
        assert_eq!(
            all.len(), 1,
            "Destination must hold exactly the surviving row, got {}",
            all.len()
        );
        assert_eq!(all[0].values.get("id"), Some(&TypedValue::Uuid(kept_id)));
        assert_eq!(
            all[0].values.get("adjective_bitmap"),
            Some(&TypedValue::Bitmap(0b1111)),
            "The surviving row must carry the updated value"
        );
    }

    /// §10.C7 — An unresolvable change withholds the watermark without vetoing
    /// the rest of the cycle: resolvable row work still propagates.
    #[test]
    fn unresolvable_change_still_lets_resolvable_work_through() {
        let schema = pk_less_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // One resolvable insert on the keyed table…
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b0101), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1);
        // …alongside one unresolvable change on the keyless table.
        session.dirty_set.accumulate(&TableChange {
            table: "keyless".into(),
            event: StorageEvent::Delete,
            row_key: None,
            values: None,
            hlc: None,
            origin: crate::observer::ChangeOrigin::Local,
            changed_columns: None,
        });

        let incoming = HLC::new(1_000, 0, 1);
        let outcome = session
            .sync(
                &source,
                &destination,
                ReplicationCursor {
                    hlc_watermark: Some(incoming),
                    rows_written: 0,
                    audit_events_written: 0,
                    blobs_written: 0,
                },
            )
            .expect("sync");

        assert!(!outcome.is_complete());
        assert_eq!(outcome.cursor.hlc_watermark, Some(incoming), "Watermark withheld");
        assert_eq!(
            destination.row_store().count("items", None).expect("count"), 1,
            "Resolvable row work must still reach the destination"
        );
    }
}

/// Test helpers for use in this module and replication module tests.
/// Not pub(crate) — the replication module's test uses its own helper.
/// This module has its own copy to be self-contained.
#[cfg(test)]
pub(crate) mod tests_helpers {
    use crate::audit_log::AuditEvent;
    use substrate_types::hlc::HLC;
    use uuid::Uuid;

    pub fn make_audit_event(estate_id: Uuid, row_id: Uuid, physical_time: i64) -> AuditEvent {
        AuditEvent {
            event_id: Uuid::new_v4(),
            estate_uuid: estate_id,
            row_id,
            hlc: HLC::new(physical_time, 0, 1),
            verb: "capture".into(),
            before_adjective: None,
            before_operational: None,
            before_provenance: None,
            after_adjective: 0,
            after_operational: 0,
            after_provenance: 0,
            before_lattice_anchor: None,
            after_lattice_anchor: 0, before_lattice_qid: None, after_lattice_qid: 0,
            actor: "test".into(),
            reason: None,
        }
    }
}
