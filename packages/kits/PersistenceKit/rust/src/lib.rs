//! persistence-kit
//!
//! Storage abstraction layer mirroring the Swift PersistenceKit
//! package. Closed-enum predicate algebra, typed values, schema
//! declaration, Storage + RowStore + BlobStore + AuditLog +
//! StorageObserver traits. PersistenceKit owns no vector-search
//! engine — dense-embedding k-NN lives in VectorKit; every
//! backend instead accommodates vector workloads' storage needs
//! through the general RowStore / BlobStore surfaces. InMemory,
//! SQLite, and PostgreSQL backends all ship at v1.0. PostgreSQL
//! conformance requires `PERSISTENCEKIT_PG_URL` to point at a live server.
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
pub mod database_inventory;
pub mod dataset_store;
pub mod encryption;
pub mod error;
pub mod estate_migration;
// gc_pin and snapshot_registry types accessed via module path (like replication).
pub mod gc_pin;
pub mod generated_column;
pub mod hashing_row_store;
pub mod inmemory;
pub mod introspection;
// Canonical schema layout signatures + deterministic table inventories
// (GLK shared-content 1.1, P0). Accessed via module path or the re-exports
// below.
pub mod layout_signature;
// Physical storage maintenance — WAL checkpoint + page reclamation
// (GLK shared-content 1.1, P5).
pub mod maintenance;
pub mod observer;
pub mod postgres;
pub mod postgres_tls;
pub mod predicate;
pub mod incremental_replication;
pub mod replication;
pub mod row_key_derivation;
pub mod row_store;
pub mod schema;
pub mod snapshot_registry;
pub mod sqlite;
pub mod storage;
// cp-persistencekit-report (2026-06-06): self-report telemetry via IntellectusLib.
// report_storage_stats wraps StorageIntrospection::stats and emits persistence.db.*
// metrics. Off by default — zero cost when monitoring is disabled.
pub mod telemetry;
pub mod types;

pub use audit_log::*;
pub use blob_store::*;
pub use cache_config::*;
pub use cache_invalidator::CacheInvalidator;
pub use caching_row_store::{CachingRowStore, ParentChainProvider};
pub use hashing_row_store::{HashingRowStore, HashOnWriteConfig, ContentHashProvider, HashParentChainProvider};
pub use encryption::{
    apply_install_encryption_to_conn, attach_with_install_key, ensure_install_key,
    AeadProvider, AesGcmAeadProvider, EncryptionMode, EstateEncryptionConfig,
    RowCrypto, INSTALL_KEY_FILE,
};
pub use error::*;
pub use generated_column::*;
pub use introspection::{StorageIntrospection, StorageStats};
pub use layout_signature::{layout_signature_digest, layout_signature_text};
pub use database_inventory::{capture_inventory, TableInventory};
pub use telemetry::report_storage_stats;
pub use observer::*;
pub use postgres::PostgresStorage;
pub use predicate::*;
// Replication types are not re-exported at crate root to avoid namespace collision.
// Import them as `use persistence_kit::replication::{replicate, flush, hydrate, ...}`.
pub use row_key_derivation::deterministic_row_key;
pub use row_store::*;
pub use schema::*;
pub use sqlite::SqliteStorage;
pub use storage::*;
pub use types::*;

#[cfg(test)]
mod cache_config_tests;
#[cfg(test)]
mod cache_wiring_tests;
#[cfg(test)]
mod caching_row_store_tests;
#[cfg(test)]
mod encryption_tests;
