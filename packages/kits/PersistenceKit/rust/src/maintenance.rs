//! Physical storage maintenance — WAL checkpoint + page reclamation.
//!
//! Mirrors Swift `PersistenceKit/StorageMaintenance.swift` (shared-content
//! 1.1 P5). The shared-content migration retires legacy tables through
//! declared schema migrations, which moves their pages to the SQLite
//! freelist but does NOT shrink the database file; this surface returns
//! those pages to the filesystem.
//!
//! Per-backend contract:
//!
//! | Behaviour                  | SQLite            | PostgreSQL      | InMemory |
//! |----------------------------|-------------------|-----------------|----------|
//! | estimated_reclaimable_bytes| freelist×page_size| 0               | 0        |
//! |                            |  + WAL file bytes |                 |          |
//! | perform_maintenance        | checkpoint+VACUUM | no-op (server-  | no-op    |
//! |                            |                   |  managed)       |          |
//! | quiescence check           | rejects when a    | n/a             | n/a      |
//! |                            |  txn is open      |                 |          |
//! | disk-capacity check        | preflight against | n/a             | n/a      |
//! |                            |  live-page bytes  |                 |          |
//!
//! The API lives on the `Storage` trait (defaulted methods) rather than a
//! separate trait because Rust trait objects cannot be capability-probed
//! the way Swift's `as? StorageMaintenance` can; the default is the
//! explicit "backend does not implement physical maintenance" no-op.

/// The maintenance operation's phases, in execution order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MaintenancePhase {
    /// Quiescence and disk-capacity verification; before/after baselines.
    Preflight,
    /// `PRAGMA wal_checkpoint(TRUNCATE)` — flush and truncate the WAL.
    WalCheckpoint,
    /// `VACUUM` — rewrite the database, returning freelist pages to the
    /// filesystem. Atomic at the SQLite level: cancellation is honoured
    /// BETWEEN phases, never mid-VACUUM.
    Vacuum,
    /// Post-operation introspection (page counts, file sizes, report).
    Introspection,
}

/// A progress event emitted at the START of each phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MaintenanceProgress {
    pub phase: MaintenancePhase,
    /// Number of phases already completed (0-based progress numerator).
    pub completed_phases: usize,
    /// Total phases the operation will run (constant 4 for SQLite).
    pub total_phases: usize,
}

/// Post-operation introspection: what the maintenance pass found and freed.
///
/// `reclaimed_bytes` is measured against the FILESYSTEM (database file +
/// WAL file before vs. after), not the logical page count — the exit
/// contract of the shared-content migration is that free pages are returned
/// to the filesystem, so the report proves exactly that.
#[derive(Debug, Clone, PartialEq)]
pub struct MaintenanceReport {
    /// Backend discriminator: "sqlite", "postgresql", or "inmemory".
    pub backend: String,
    /// True when a physical operation actually ran (SQLite). False for the
    /// explicit no-op backends.
    pub performed: bool,
    /// Human-readable note for the no-op cases; None when `performed`.
    pub note: Option<String>,
    pub page_size_bytes: i64,
    pub page_count_before: i64,
    pub page_count_after: i64,
    pub freelist_pages_before: i64,
    pub freelist_pages_after: i64,
    /// Database file size on disk (bytes), before/after.
    pub file_size_bytes_before: i64,
    pub file_size_bytes_after: i64,
    /// WAL file size on disk (bytes), before/after. 0 when absent.
    pub wal_bytes_before: i64,
    pub wal_bytes_after: i64,
    /// Filesystem bytes released: (file+WAL before) − (file+WAL after),
    /// floored at 0.
    pub reclaimed_bytes: i64,
    /// Wall-clock duration of the operation in seconds.
    pub duration_seconds: f64,
}

impl MaintenanceReport {
    /// The canonical no-op report for backends with nothing to reclaim.
    pub fn no_op(backend: &str, note: &str) -> Self {
        MaintenanceReport {
            backend: backend.to_string(),
            performed: false,
            note: Some(note.to_string()),
            page_size_bytes: 0,
            page_count_before: 0,
            page_count_after: 0,
            freelist_pages_before: 0,
            freelist_pages_after: 0,
            file_size_bytes_before: 0,
            file_size_bytes_after: 0,
            wal_bytes_before: 0,
            wal_bytes_after: 0,
            reclaimed_bytes: 0,
            duration_seconds: 0.0,
        }
    }
}

/// Maintenance failure modes — mirrors Swift `StorageMaintenanceError`.
#[derive(Debug, Clone, PartialEq)]
pub enum MaintenanceError {
    /// A transaction is open on the maintenance connection. VACUUM cannot
    /// run inside a transaction; retry when the estate is quiescent.
    NotQuiescent { reason: String },
    /// VACUUM rewrites the live pages into a temporary copy, so the volume
    /// needs at least the live-content size free. Preflight refuses rather
    /// than failing mid-rewrite.
    InsufficientDiskCapacity {
        required_bytes: i64,
        available_bytes: i64,
    },
    /// `should_cancel` returned true at a phase boundary. Each phase is
    /// atomic, so a cancelled operation leaves the database exactly as the
    /// last completed phase left it.
    Cancelled { at_phase: MaintenancePhase },
    /// The underlying backend operation failed.
    BackendFailure { reason: String },
}

impl std::fmt::Display for MaintenanceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MaintenanceError::NotQuiescent { reason } => {
                write!(f, "storage not quiescent: {reason}")
            }
            MaintenanceError::InsufficientDiskCapacity {
                required_bytes,
                available_bytes,
            } => write!(
                f,
                "insufficient disk capacity: required {required_bytes} bytes, available {available_bytes}"
            ),
            MaintenanceError::Cancelled { at_phase } => {
                write!(f, "maintenance cancelled at phase {at_phase:?}")
            }
            MaintenanceError::BackendFailure { reason } => {
                write!(f, "maintenance backend failure: {reason}")
            }
        }
    }
}

impl std::error::Error for MaintenanceError {}
