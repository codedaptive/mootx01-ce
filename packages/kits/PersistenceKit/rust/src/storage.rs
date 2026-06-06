//! Storage trait and EstateConfiguration.

use crate::audit_log::AuditLog;
use crate::blob_store::BlobStore;
use crate::cache_config::EstateCacheConfig;
use crate::encryption::EstateEncryptionConfig;
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
    /// At-rest encryption configuration for this estate (PAR-5-PK). Defaults
    /// to `EstateEncryptionConfig::plaintext()` so existing call sites are
    /// unchanged: a plaintext estate behaves exactly as before, with no crypto
    /// on any path. Mirrors Swift's `EstateConfiguration.encryptionConfig`.
    pub encryption_config: EstateEncryptionConfig,
    /// Cache configuration for this estate (Mission PK-CACHE-A). Defaults
    /// to `EstateCacheConfig::disabled()` so existing call sites are unchanged:
    /// a disabled-cache estate behaves exactly as before.
    pub cache_config: EstateCacheConfig,
}

impl EstateConfiguration {
    /// Construct an estate configuration with plaintext encryption (the default)
    /// and disabled cache. Existing call sites compile and behave identically.
    pub fn new(estate_id: uuid::Uuid, backend: BackendConfiguration) -> Self {
        EstateConfiguration {
            estate_id,
            backend,
            encryption_config: EstateEncryptionConfig::plaintext(),
            cache_config: EstateCacheConfig::disabled(),
        }
    }
}

#[derive(Debug, Clone)]
pub enum BackendConfiguration {
    InMemory,
    /// SQLite backend (sqlite.rs) — WAL-mode rusqlite over a
    /// filesystem path; the durable backend behind SqliteDrawerStore
    /// and the servers' ARIA_MCP_SQLITE_PATH configuration.
    Sqlite {
        path: String,
        busy_timeout_secs: f64,
    },
    /// PostgreSQL backend (postgres.rs) — synchronous postgres
    /// crate, one client per estate; conformance verified against a
    /// live server via PERSISTENCEKIT_PG_URL.
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

/// The transactional view handed to a `Storage::transaction` block. Its
/// stores participate in the active transaction; the unit commits or rolls
/// back when the block returns. Mirrors Swift's `StorageTransaction` (minus
/// the observer, which fires on commit).
pub trait StorageTransaction {
    fn row_store(&self) -> Arc<dyn RowStore>;
    fn blob_store(&self) -> Arc<dyn BlobStore>;
    fn vector_index(&self) -> Arc<dyn VectorIndex>;
    fn audit_log(&self) -> Arc<dyn AuditLog>;
}

/// Storage trait. Mirror of Swift's Storage protocol. One adaptation:
/// Swift's `transaction<T>(_:)` returns a generic value, but Rust's trait
/// must stay object-safe (`dyn Storage` is used throughout), so the Rust
/// `transaction` is non-generic — the block returns `StorageResult<()>`
/// (Ok commits, Err rolls back) and surfaces results via its own closure
/// environment.
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

    /// Run `block` inside a transaction. The block receives a
    /// `StorageTransaction` whose stores participate in the transaction;
    /// returning `Ok(())` commits, returning `Err` rolls back and propagates
    /// the error. Object-safe (no generic return): the block captures any
    /// results through its own environment.
    fn transaction(
        &self,
        isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()>;
}
