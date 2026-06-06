//! persistence-kit
//!
//! Storage abstraction layer mirroring the Swift PersistenceKit
//! package. Closed-enum predicate algebra, typed values, schema
//! declaration, Storage + RowStore + BlobStore + VectorIndex +
//! AuditLog + StorageObserver traits. InMemory, SQLite, and
//! PostgreSQL backends all ship at v1.0. PostgreSQL conformance
//! requires `PERSISTENCEKIT_PG_URL` to point at a live server.
//!
//! Swift parity:
//!   - TypedValue mirrors Swift's enum case-for-case
//!   - StoragePredicate is closed; same operator families
//!   - Traits are synchronous (Result<T, StorageError>); the
//!     Swift side is async because Swift actors require it, but
//!     the in-process Rust backends do no real async I/O. When
//!     a future backend (e.g. tokio-postgres) needs async, it
//!     can wrap its own runtime.

pub mod audit_log;
pub mod blob_store;
pub mod cache_config;
pub mod cache_invalidator;
pub mod caching_row_store;
pub mod encryption;
pub mod error;
pub mod generated_column;
pub mod inmemory;
pub mod observer;
pub mod postgres;
pub mod predicate;
pub mod replication;
pub mod row_store;
pub mod schema;
pub mod sqlite;
pub mod storage;
pub mod types;
pub mod vector_index;

pub use audit_log::*;
pub use blob_store::*;
pub use cache_config::*;
pub use cache_invalidator::CacheInvalidator;
pub use caching_row_store::CachingRowStore;
pub use encryption::{
    AeadProvider, AesGcmAeadProvider, EncryptionMode, EstateEncryptionConfig, RowCrypto,
};
pub use error::*;
pub use generated_column::*;
pub use observer::*;
pub use postgres::PostgresStorage;
pub use predicate::*;
// Replication types are not re-exported at crate root to avoid namespace collision.
// Import them as `use persistence_kit::replication::{replicate, flush, hydrate, ...}`.
pub use row_store::*;
pub use schema::*;
pub use sqlite::SqliteStorage;
pub use storage::*;
pub use types::*;
pub use vector_index::*;

#[cfg(test)]
mod cache_config_tests;
#[cfg(test)]
mod cache_wiring_tests;
#[cfg(test)]
mod caching_row_store_tests;
#[cfg(test)]
mod encryption_tests;
