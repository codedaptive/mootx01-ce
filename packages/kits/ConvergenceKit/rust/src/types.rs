//! Core ConvergenceKit types.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use uuid::Uuid;
use persistence_kit::Storage;

/// Direction of replication per synced table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncDirection {
    Bidirectional,
    PushOnly,
    PullOnly,
}

impl std::fmt::Display for SyncDirection {
    /// Parity contract: must match Swift `SyncDirection.rawValue` which are
    /// camelCase string raw values: "bidirectional", "pushOnly", "pullOnly".
    /// Used in `format_sync_state_token` so sync status tokens are identical
    /// between Swift and Rust. The `{direction:?}` (Debug) form was wrong:
    /// it emits PascalCase ("Bidirectional", "PushOnly", "PullOnly") which
    /// diverges from Swift's camelCase rawValue output.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SyncDirection::Bidirectional => write!(f, "bidirectional"),
            SyncDirection::PushOnly => write!(f, "pushOnly"),
            SyncDirection::PullOnly => write!(f, "pullOnly"),
        }
    }
}

/// Conflict resolution policy applied at the receive boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConflictPolicy {
    /// Default. HLC on the incoming record vs HLC on the local row wins.
    LastWriterWinsByHLC,
    /// (event_id, hlc) compound key makes duplicate appends idempotent.
    /// Used for the audit log.
    AppendOnly,
    /// Receiver discards remote changes on conflict.
    LocalWins,
    /// Receiver overwrites local on conflict.
    RemoteWins,
    /// (v1.2-draft) Per-column HLC last-writer-wins. See B-8 in
    /// CONVERGENCEKIT_SPEC.md and FieldLWW/ in the Swift source.
    /// Serialises as "fieldLevelLWW" (camelCase via serde rename_all).
    FieldLevelLWW,
}

/// Declaration of a single synced table within a manifest.
/// JSON contract: camelCase field names matching Swift's property names.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncedTable {
    pub name: String,
    #[serde(default = "default_direction")]
    pub direction: SyncDirection,
    pub primary_key_column: String,
    #[serde(default = "default_conflict_policy")]
    pub conflict_policy: ConflictPolicy,
    /// (v1.2-draft, R2) Columns excluded from sync. Locally recomputed on every device.
    /// Exclusion semantics only — not inclusion. JSON key "excludedColumns"; omitted when
    /// empty for backward compat (serde default = empty set). Swift twin: `excludedColumns`.
    #[serde(default, skip_serializing_if = "HashSet::is_empty")]
    pub excluded_columns: HashSet<String>,
}

fn default_direction() -> SyncDirection {
    SyncDirection::Bidirectional
}

fn default_conflict_policy() -> ConflictPolicy {
    ConflictPolicy::LastWriterWinsByHLC
}

impl SyncedTable {
    pub fn new(name: impl Into<String>, primary_key_column: impl Into<String>) -> Self {
        SyncedTable {
            name: name.into(),
            direction: SyncDirection::Bidirectional,
            primary_key_column: primary_key_column.into(),
            conflict_policy: ConflictPolicy::LastWriterWinsByHLC,
            excluded_columns: HashSet::new(),
        }
    }

    pub fn with_direction(mut self, direction: SyncDirection) -> Self {
        self.direction = direction;
        self
    }

    pub fn with_conflict_policy(mut self, policy: ConflictPolicy) -> Self {
        self.conflict_policy = policy;
        self
    }

    /// Builder: set columns to exclude from sync. Locally recomputed on every device.
    pub fn with_excluded_columns(mut self, columns: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.excluded_columns = columns.into_iter().map(Into::into).collect();
        self
    }
}

/// Summary of one inbound pull batch delivered to the post-apply integrity hook.
///
/// The hook receives this value after every pull in which at least one record
/// was applied. The `storage` handle is the same `Arc<dyn Storage>` the pull
/// used; writes made through it use `upsert`/`insert`/`delete` (not the
/// `_sync` variants), so they emit `ChangeOrigin::Local` and flow into the
/// observer workers' outbox — satisfying the hook-writes-must-ship invariant
/// (Kong Q2 adjudication).
///
/// ## Atomicity caveat
///
/// PersistenceKit exposes no batch-transaction API. The hook runs after all
/// batch records have been applied but NOT in a containing transaction. Design
/// hooks to be idempotent.
pub struct AppliedBatch {
    /// PersistenceKit storage the pull applied against.
    pub storage: Arc<dyn Storage>,
    /// Row keys upserted (inserted or updated) during this batch, keyed by
    /// table name. Rows rejected by LWW do not appear here.
    pub applied_by_table: HashMap<String, Vec<Uuid>>,
    /// Row keys whose tombstones were applied (hard-deleted), keyed by table.
    pub deleted_by_table: HashMap<String, Vec<Uuid>>,
}

/// Hook type: a shareable, cloneable sync callback invoked once per pull batch.
/// `Arc<dyn Fn>` is Clone (pointer clone), so `SyncManifest: Clone`.
/// Closures that implement `Fn(&AppliedBatch) -> Result<(), SyncError>` are
/// `Send + Sync` when all captured data is `Send + Sync`.
pub type IntegrityHookFn = Arc<dyn Fn(&AppliedBatch) -> Result<(), SyncError> + Send + Sync>;

/// Declarative configuration for a sync session.
/// JSON contract: camelCase field names matching Swift's property names.
///
/// ## Not fully Debug-derived
///
/// `SyncManifest` no longer derives `Debug` automatically because
/// `Arc<dyn Fn(...)>` does not implement `Debug`. A manual `Debug` impl is
/// provided below that prints the hook presence without the closure body.
///
/// ## post_apply_integrity_hook — not serialised
///
/// The hook field uses `#[serde(skip)]` so it is omitted from JSON output
/// and defaults to `None` on deserialization. `SyncManifest` JSON remains
/// the same wire-compatible shape as before (kitID, schemaVersion,
/// zoneIdentifier, tables). The hook is a local runtime callback only.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncManifest {
    /// Serializes as "kitID" to match Swift's property name (not "kitId").
    #[serde(rename = "kitID")]
    pub kit_id: String,
    pub schema_version: i32,
    pub zone_identifier: String,
    pub tables: Vec<SyncedTable>,
    /// (v1.2-draft) Optional callback invoked once per pull batch AFTER all
    /// inbound records have been applied. See `AppliedBatch` for the contract.
    /// Not serialised — closures cannot be transmitted over the wire.
    #[serde(skip)]
    pub post_apply_integrity_hook: Option<IntegrityHookFn>,
}

impl std::fmt::Debug for SyncManifest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncManifest")
            .field("kit_id", &self.kit_id)
            .field("schema_version", &self.schema_version)
            .field("zone_identifier", &self.zone_identifier)
            .field("tables", &self.tables)
            .field("post_apply_integrity_hook",
                   &self.post_apply_integrity_hook.as_ref().map(|_| "<hook>"))
            .finish()
    }
}

impl SyncManifest {
    pub fn new(
        kit_id: impl Into<String>,
        schema_version: i32,
        zone_identifier: impl Into<String>,
        tables: Vec<SyncedTable>,
    ) -> Self {
        SyncManifest {
            kit_id: kit_id.into(),
            schema_version,
            zone_identifier: zone_identifier.into(),
            tables,
            post_apply_integrity_hook: None,
        }
    }

    pub fn with_integrity_hook(mut self, hook: IntegrityHookFn) -> Self {
        self.post_apply_integrity_hook = Some(hook);
        self
    }

    pub fn table_named(&self, name: &str) -> Option<&SyncedTable> {
        self.tables.iter().find(|t| t.name == name)
    }
}

/// Result summary for one push or pull cycle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncReceipt {
    pub pushed: usize,
    pub pulled: usize,
    pub conflicts: usize,
    /// Unix epoch seconds at completion.
    pub timestamp_secs: i64,
}

impl SyncReceipt {
    pub const fn empty() -> Self {
        SyncReceipt {
            pushed: 0,
            pulled: 0,
            conflicts: 0,
            timestamp_secs: 0,
        }
    }

    pub fn now(pushed: usize, pulled: usize, conflicts: usize) -> Self {
        SyncReceipt {
            pushed,
            pulled,
            conflicts,
            timestamp_secs: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0),
        }
    }
}

/// Events emitted by `SyncEngine::subscribe`.
#[derive(Debug, Clone)]
pub enum SyncEvent {
    RemoteChangesApplied { count: usize },
    PushCompleted { receipt: SyncReceipt },
    PeerConnected { identity: String },
    PeerDisconnected { identity: String, reason: String },
    Error(SyncError),
    /// Records held in the schema-skew queue (R9, CVK-ICLOUD P3-M4).
    ///
    /// Emitted during pull when inbound records have a `schema_version` greater
    /// than the local manifest version (the sender is on a newer schema). Also
    /// emitted from enable() when records still-held in the queue have a
    /// `schema_version` that is still newer than the now-enabled manifest.
    ///
    /// `count` is the number of records currently held — zero is not emitted.
    /// The held records are replayed automatically on the next `enable()` after
    /// the consumer updates its manifest's `schema_version` to match.
    ///
    /// Swift twin: `SyncEvent.recordsHeldForMigration(count: Int)`.
    RecordsHeldForMigration { count: usize },
    /// A CloudKit silent-push notification arrived for the engine's zone and
    /// the engine responded by nudging the poll scheduler. Vocabulary-parity
    /// twin of Swift `SyncEvent.remoteWakeReceived`. CloudKit is Swift-only
    /// (§ 7 Exempt); this arm is present for cross-port vocabulary parity only
    /// and is never constructed or matched on the Rust side.
    RemoteWakeReceived,
}

/// Coarse state for UI bindings.
#[derive(Debug, Clone)]
pub enum SyncState {
    Disabled,
    Enabled {
        zone: String,
        last_push_secs: Option<i64>,
        last_pull_secs: Option<i64>,
    },
    Syncing {
        direction: SyncDirection,
    },
    Errored {
        error: SyncError,
        retry_at_secs: Option<i64>,
    },
}

/// Errors surfaced by ConvergenceKit operations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncError {
    NotEnabled,
    AlreadyEnabled,
    SchemaMismatch { expected: i32, received: i32 },
    KitMismatch { expected: String, received: String },
    TransportFailure { detail: String },
    DecodingFailure { detail: String },
    EncodingFailure { detail: String },
    PeerUnreachable { identity: String },
    AuthenticationFailed { detail: String },
    UnsupportedTable { name: String },
    // ── N2 slot-registry errors (v1.2-draft) ──────────────────────────────
    // Vocabulary parity with the Swift leg. These variants are thrown by the
    // CloudKit backend (Swift-only; CloudKit has no Rust API per N4). They
    // exist in the Rust error enum so error-handling code and tests can
    // reference the vocabulary without depending on CloudKit.
    //
    // Slot and fence epoch identify the writer across concurrent devices.

    /// This device's (slot, epoch) pair has been superseded: the slot was
    /// evicted and its epoch bumped while the device was inactive. Raised
    /// before any inbound records are applied. (Swift CloudKit engine only;
    /// present here for vocabulary parity. Never thrown by Rust code.)
    ReenrollRequired {
        slot: i32,
        stale_epoch: i64,
        current_epoch: i64,
    },
    /// All 15 assignable node-ID slots (1–15) are occupied by recently-active
    /// devices. No records are applied. (Swift CloudKit engine only; present
    /// here for vocabulary parity. Never thrown by Rust code.)
    SlotExhausted { active_count: usize },
}

impl std::fmt::Display for SyncError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SyncError::NotEnabled => write!(f, "sync not enabled"),
            SyncError::AlreadyEnabled => write!(f, "sync already enabled"),
            SyncError::SchemaMismatch { expected, received } => {
                write!(f, "schema mismatch: expected v{}, received v{}", expected, received)
            }
            SyncError::KitMismatch { expected, received } => {
                write!(f, "kit id mismatch: expected {}, received {}", expected, received)
            }
            SyncError::TransportFailure { detail } => write!(f, "transport failure: {}", detail),
            SyncError::DecodingFailure { detail } => write!(f, "decoding failure: {}", detail),
            SyncError::EncodingFailure { detail } => write!(f, "encoding failure: {}", detail),
            SyncError::PeerUnreachable { identity } => write!(f, "peer unreachable: {}", identity),
            SyncError::AuthenticationFailed { detail } => {
                write!(f, "authentication failed: {}", detail)
            }
            SyncError::UnsupportedTable { name } => write!(f, "unsupported table: {}", name),
            // N2 slot-registry errors — vocabulary parity with Swift leg
            SyncError::ReenrollRequired { slot, stale_epoch, current_epoch } => {
                write!(
                    f,
                    "reenroll required: slot {} stale epoch {} current epoch {}",
                    slot, stale_epoch, current_epoch
                )
            }
            SyncError::SlotExhausted { active_count } => {
                write!(f, "slot exhausted: {} active devices", active_count)
            }
        }
    }
}

impl std::error::Error for SyncError {}

pub type SyncResult<T> = Result<T, SyncError>;
