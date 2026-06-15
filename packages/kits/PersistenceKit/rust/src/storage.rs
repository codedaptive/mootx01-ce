//! Storage trait and EstateConfiguration.

use crate::audit_log::AuditLog;
use crate::blob_store::BlobStore;
use crate::cache_config::EstateCacheConfig;
use crate::encryption::EstateEncryptionConfig;
use crate::error::{StorageError, StorageResult};
use crate::observer::StorageObserver;
use crate::row_store::RowStore;
use crate::schema::SchemaDeclaration;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// NovelTokenTaggerChoice
// ---------------------------------------------------------------------------

/// Estate-creation-time selection of the novel-token tagger (Layer-2a, v1.0).
///
/// This choice is fixed at estate creation. Change-after-creation and
/// re-tagging migration are v1.1 features. Mirrors
/// `PersistenceKit.NovelTokenTaggerChoice` in Swift.
///
/// # Rust constraint
///
/// `NlTagger` is an **invalid** selection on Rust: the Apple
/// `NaturalLanguage` framework is not available outside the Apple ecosystem.
/// The variant exists in this enum for schema parity (an estate configuration
/// stored by the Swift port must be readable by the Rust port), but it cannot
/// be **constructed** via the safe `EstateConfiguration::new` or
/// `EstateConfiguration::new_with_tagger` entry points on Rust.
/// `new_with_tagger(NlTagger)` returns `StorageError::InvalidConfiguration`.
/// `new` defaults to `Hmm`.
///
/// # Federation constraint (v1.1 enforcement)
///
/// An estate tagged with `NlTagger` (on Swift/Apple) produces novel-token
/// classifications that differ from `Hmm` estates. Federating such an estate
/// with a Rust or HMM-configured Swift estate corrupts concept-bag recall.
/// Federation enforcement (refusing to sync incompatible estates) is out of
/// scope for v1.0 and will be added in v1.1. Document this constraint in any
/// cross-estate sync configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NovelTokenTaggerChoice {
    /// Deterministic HMM/Viterbi tagger — the default and cross-port baseline.
    ///
    /// Byte-identical to the Swift HMM port. Safe for all platforms and
    /// federatable with all other `Hmm` estates regardless of platform.
    Hmm,

    /// Apple NaturalLanguage `NLTagger` — Apple-only.
    ///
    /// This variant exists for schema parity with the Swift port. It is an
    /// **invalid** active selection on Rust. `EstateConfiguration::new_with_tagger`
    /// returns `StorageError::InvalidConfiguration` when called with this value.
    /// A configuration row written by the Swift port and read back by the Rust
    /// port will surface `NlTagger` from the stored field; the Rust tagging path
    /// will fall back to `Hmm` because no NaturalLanguage framework is available.
    NlTagger,
}

impl Default for NovelTokenTaggerChoice {
    fn default() -> Self {
        // HMM is the cross-platform default. Swift and Rust agree.
        NovelTokenTaggerChoice::Hmm
    }
}

// ---------------------------------------------------------------------------
// EstateConfiguration
// ---------------------------------------------------------------------------

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
    /// Novel-token tagger choice for this estate (Layer-2a, v1.0). Defaults
    /// to `NovelTokenTaggerChoice::Hmm` — the deterministic, cross-platform
    /// baseline. `NlTagger` is a stored schema-parity field only on Rust;
    /// the Rust tagging path falls back to HMM because NaturalLanguage is absent.
    /// On Rust, constructing a configuration with `NlTagger` via
    /// `new_with_tagger` returns an error (fail-closed).
    pub novel_token_tagger: NovelTokenTaggerChoice,
}

impl EstateConfiguration {
    /// Construct an estate configuration with plaintext encryption, disabled
    /// cache, and the HMM novel-token tagger (the cross-platform default).
    /// Existing call sites compile and behave identically.
    pub fn new(estate_id: uuid::Uuid, backend: BackendConfiguration) -> Self {
        EstateConfiguration {
            estate_id,
            backend,
            encryption_config: EstateEncryptionConfig::plaintext(),
            cache_config: EstateCacheConfig::disabled(),
            novel_token_tagger: NovelTokenTaggerChoice::Hmm,
        }
    }

    /// Construct an estate configuration with an explicit novel-token tagger
    /// choice. Returns an error if `NlTagger` is requested on Rust (no
    /// NaturalLanguage framework is available — fail-closed).
    pub fn new_with_tagger(
        estate_id: uuid::Uuid,
        backend: BackendConfiguration,
        novel_token_tagger: NovelTokenTaggerChoice,
    ) -> StorageResult<Self> {
        if novel_token_tagger == NovelTokenTaggerChoice::NlTagger {
            return Err(StorageError::InvalidConfiguration {
                reason: "NovelTokenTaggerChoice::NlTagger is unavailable on Rust: \
                         the Apple NaturalLanguage framework is not present on non-Apple \
                         platforms. Use NovelTokenTaggerChoice::Hmm instead."
                    .to_owned(),
            });
        }
        Ok(EstateConfiguration {
            estate_id,
            backend,
            encryption_config: EstateEncryptionConfig::plaintext(),
            cache_config: EstateCacheConfig::disabled(),
            novel_token_tagger,
        })
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
