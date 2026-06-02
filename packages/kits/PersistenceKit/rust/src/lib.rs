//! persistence-kit
//!
//! Storage abstraction layer mirroring the Swift PersistenceKit
//! package. Closed-enum predicate algebra, typed values, schema
//! declaration, Storage + RowStore + BlobStore + VectorIndex +
//! AuditLog + StorageObserver traits. InMemory backend ships at
//! v1.0; SQLite backend lands as a follow-on (see TODO at the
//! bottom of this file).
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
pub mod error;
pub mod generated_column;
pub mod inmemory;
pub mod observer;
pub mod postgres;
pub mod predicate;
pub mod row_store;
pub mod schema;
pub mod sqlite;
pub mod storage;
pub mod types;
pub mod vector_index;

pub use audit_log::*;
pub use blob_store::*;
pub use error::*;
pub use generated_column::*;
pub use observer::*;
pub use postgres::PostgresStorage;
pub use predicate::*;
pub use row_store::*;
pub use schema::*;
pub use sqlite::SqliteStorage;
pub use storage::*;
pub use types::*;
pub use vector_index::*;
