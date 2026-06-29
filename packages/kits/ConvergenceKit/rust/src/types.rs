//! Core ConvergenceKit types.

use serde::{Deserialize, Serialize};

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
}

/// Declarative configuration for a sync session.
/// JSON contract: camelCase field names matching Swift's property names.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncManifest {
    /// Serializes as "kitID" to match Swift's property name (not "kitId").
    #[serde(rename = "kitID")]
    pub kit_id: String,
    pub schema_version: i32,
    pub zone_identifier: String,
    pub tables: Vec<SyncedTable>,
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
        }
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
        }
    }
}

impl std::error::Error for SyncError {}

pub type SyncResult<T> = Result<T, SyncError>;
