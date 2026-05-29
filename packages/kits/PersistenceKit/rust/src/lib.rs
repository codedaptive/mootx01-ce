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

pub mod types;
pub mod predicate;
pub mod schema;
pub mod generated_column;
pub mod error;
pub mod row_store;
pub mod blob_store;
pub mod vector_index;
pub mod audit_log;
pub mod observer;
pub mod storage;
pub mod inmemory;

pub use types::*;
pub use predicate::*;
pub use schema::*;
pub use generated_column::*;
pub use error::*;
pub use row_store::*;
pub use blob_store::*;
pub use vector_index::*;
pub use audit_log::*;
pub use observer::*;
pub use storage::*;
