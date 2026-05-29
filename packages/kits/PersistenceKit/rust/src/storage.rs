//! Storage trait and EstateConfiguration.

use crate::audit_log::AuditLog;
use crate::blob_store::BlobStore;
use crate::error::StorageResult;
use crate::observer::StorageObserver;
use crate::row_store::RowStore;
use crate::schema::SchemaDeclaration;
use crate::vector_index::VectorIndex;
use std::sync::Arc;

#[derive(Debug, Clone)]
pub struct EstateConfiguration {
    pub estate_id: uuid::Uuid,
    pub backend: BackendConfiguration,
}

impl EstateConfiguration {
    pub fn new(estate_id: uuid::Uuid, backend: BackendConfiguration) -> Self {
        EstateConfiguration { estate_id, backend }
    }
}

#[derive(Debug, Clone)]
pub enum BackendConfiguration {
    InMemory,
    /// SQLite backend, deferred to a follow-on R-mission. The
    /// variant is reserved so EstateConfiguration's enum is the
    /// stable shape it will be at v1.0.
    Sqlite {
        path: String,
        busy_timeout_secs: f64,
    },
    /// PostgreSQL backend, deferred. Reserved variant.
    Postgresql {
        connection_string: String,
        pool_size: usize,
        connection_timeout_secs: f64,
        idle_timeout_secs: f64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IsolationLevel {
    ReadCommitted,
    RepeatableRead,
    Serializable,
}

/// Storage trait. Mirror of Swift's Storage protocol with one
/// adaptation: where Swift uses `transaction(_:)` with a closure
/// returning `Sendable`, Rust's trait method takes `&dyn Fn`
/// awkwardly across async boundaries. v1.0 of Rust persistence-kit
/// omits the closure-based transaction in favor of explicit
/// begin/commit/rollback on a future StorageTransaction trait;
/// the InMemory backend treats every operation as auto-committed.
/// Transaction support lands when the SQLite backend lands.
pub trait Storage: Send + Sync {
    fn configuration(&self) -> &EstateConfiguration;
    fn row_store(&self) -> Arc<dyn RowStore>;
    fn blob_store(&self) -> Arc<dyn BlobStore>;
    fn vector_index(&self) -> Arc<dyn VectorIndex>;
    fn audit_log(&self) -> Arc<dyn AuditLog>;
    fn observer(&self) -> Arc<dyn StorageObserver>;

    /// Open the backend (run migrations up to the declared
    /// schema version).
    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()>;

    /// Close the backend cleanly. Idempotent.
    fn close(&self) -> StorageResult<()>;

    /// Current schema version applied to the backend.
    fn current_schema_version(&self) -> StorageResult<i32>;

    /// Apply migrations forward to the schema's declared version.
    /// Forward-only, fail-fast per Q4.
    fn migrate(&self, schema: &SchemaDeclaration) -> StorageResult<()>;
}
