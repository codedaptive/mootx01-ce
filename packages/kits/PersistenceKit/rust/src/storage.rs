//! Storage trait and EstateConfiguration.

use crate::audit_log::AuditLog;
use crate::blob_store::BlobStore;
use crate::cache_config::EstateCacheConfig;
use crate::dataset_store::DatasetStore;
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
    /// controls whether kits hold computed indexes in heap
    /// between queries (RamResident) or load from the durable store
    /// on demand (DiskBacked, the default).
    pub residency_hint: ResidencyHint,
}

/// controls whether kits hold computed indexes in heap
/// between queries or load from the durable store on demand.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResidencyHint {
    /// Indexes loaded from disk on demand; OS page cache manages RAM.
    DiskBacked,
    /// All indexes cached in heap for minimum query latency.
    RamResident,
}

impl Default for ResidencyHint {
    fn default() -> Self { Self::DiskBacked }
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
            residency_hint: ResidencyHint::default(),
        }
    }

    /// Derive a sibling `EstateConfiguration` pointing at a per-estate queue
    /// database file beside the estate's own database file.
    ///
    /// The sibling file is named `<estate-stem>.<filename>` (e.g. for estate
    /// `<dir>/<uuid>.sqlite` and filename `"queue.sqlite"` the result is
    /// `<dir>/<uuid>.queue.sqlite`). This guarantees cross-estate isolation:
    /// two estates in the same directory produce DIFFERENT sibling paths, so
    /// one estate's encode/dreaming queue is never accessible to another estate's
    /// workers. Within the same estate, the path is deterministic across
    /// processes — all processes that open the same estate file share exactly
    /// one queue file (recall-driven dreaming: one per-estate queue).
    ///
    /// The encryption configuration is carried over verbatim — an encrypted
    /// estate produces an encrypted queue, sharing the cipher key so QueueKit
    /// can open the queue file without additional key distribution.
    ///
    /// # Backend behaviour
    ///
    /// - `Sqlite { path, busy_timeout_secs }` — returns a new `Sqlite` config
    ///   at `<estate-dir>/<estate-stem>.<filename>`, preserving `busy_timeout_secs`
    ///   and carrying the same `encryption_config`.
    /// - `InMemory` — returns an InMemory config. The queue is ephemeral
    ///   alongside the ephemeral estate, which is correct for testing and
    ///   transient session estates.
    /// - `Postgresql {... }` — **deferred**. The queue sibling is SQLite-first;
    ///   this branch returns `StorageError::FeatureGated` with a clear message.
    ///   A caller relying on a Postgres-backed queue will learn immediately
    ///   that this path is not yet implemented, rather than receiving a
    ///   silently wrong or half-initialised configuration.
    ///
    /// # Estate-id derivation
    ///
    /// The sibling's `estate_id` is derived deterministically from this
    /// estate's `estate_id` and the `filename` parameter using an XOR-fold.
    /// The fold mixes the filename's UTF-8 bytes into a 16-byte tag, then
    /// XORs that tag with the estate UUID bytes. This guarantees:
    /// - Distinct from the parent — the XOR is never an identity for any
    ///   non-empty filename (the tag has at least one non-zero byte).
    /// - Deterministic — same estate UUID + same filename → same sibling UUID.
    /// - No random minting — `Uuid::new_v4()` is never called on this path.
    ///
    /// Mirrors Swift `EstateConfiguration.queueSibling(filename:)`.
    pub fn queue_sibling(&self, filename: &str) -> StorageResult<EstateConfiguration> {
        let sibling_id = derive_queue_sibling_id(self.estate_id, filename);

        match &self.backend {
            BackendConfiguration::Sqlite { path, busy_timeout_secs } => {
                // Derive the per-estate sibling filename from the estate's own
                // file stem so two estates in the same directory never share a
                // queue file (recall-driven dreaming isolation correctness).
                // Estate: <dir>/<stem>.sqlite → sibling: <dir>/<stem>.<filename>
                // E.g. <dir>/abc123.sqlite + "queue.sqlite" → <dir>/abc123.queue.sqlite
                let estate_path = std::path::Path::new(path);
                let stem = estate_path
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let per_estate_filename = if stem.is_empty() {
                    filename.to_owned()
                } else {
                    format!("{}.{}", stem, filename)
                };
                let parent = estate_path
                    .parent()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let sibling_path = if parent.is_empty() {
                    per_estate_filename
                } else {
                    format!("{}/{}", parent, per_estate_filename)
                };
                Ok(EstateConfiguration {
                    estate_id: sibling_id,
                    backend: BackendConfiguration::Sqlite {
                        path: sibling_path,
                        busy_timeout_secs: *busy_timeout_secs,
                    },
                    encryption_config: self.encryption_config.clone(),
                    cache_config: self.cache_config.clone(),
                    novel_token_tagger: self.novel_token_tagger,
                    residency_hint: self.residency_hint,
                })
            }

            BackendConfiguration::InMemory => {
                // An InMemory estate gets an InMemory queue: both are ephemeral
                // and live only for the duration of the session. Correct for
                // tests and transient session estates.
                Ok(EstateConfiguration {
                    estate_id: sibling_id,
                    backend: BackendConfiguration::InMemory,
                    encryption_config: self.encryption_config.clone(),
                    cache_config: self.cache_config.clone(),
                    novel_token_tagger: self.novel_token_tagger,
                    residency_hint: self.residency_hint,
                })
            }

            BackendConfiguration::Postgresql { .. } => {
                // TODO: implement the PostgreSQL queue-sibling
                // path. The Postgres backend requires coordination primitives beyond
                // a simple file-sibling (connection-string scoping, schema namespacing)
                // and is explicitly deferred while queue storage remains SQLite-first.
                // Fail loud so any caller depending on a Postgres queue learns
                // immediately that this is not implemented, rather than receiving a
                // silently wrong or half-initialised configuration.
                Err(StorageError::FeatureGated {
                    feature: "queue_sibling for PostgreSQL backend is deferred. \
                              Use SQLite or InMemory estates \
                              for per-estate queue configuration."
                        .to_owned(),
                })
            }
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
            residency_hint: ResidencyHint::default(),
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

    /// Dataset store for user-defined tabular data (MX-TAB-1).
    ///
    /// Returns `Err(StorageError::FeatureGated { feature: "datasetStore" })` by
    /// default so existing `Storage` conformers — including Postgres (deferred,
    /// MX-TAB-2) and any third-party conformers — keep compiling without
    /// modification. Only `SqliteStorage` and `InMemoryStorage` override this.
    ///
    /// Mirrors Swift's `var datasetStore: any DatasetStore { get throws }` with
    /// the same default-throws protocol-extension pattern.
    fn dataset_store(&self) -> StorageResult<Arc<dyn DatasetStore>> {
        Err(StorageError::FeatureGated {
            feature: "datasetStore".to_string(),
        })
    }

    /// Open the backend (run migrations up to the declared
    /// schema version).
    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()>;

    /// Close the backend cleanly. Idempotent.
    fn close(&self) -> StorageResult<()>;

    /// Current schema version applied to the backend.
    fn current_schema_version(&self) -> StorageResult<i32>;

    /// Current schema version for a specific kit on this backend.
    /// Each kit migrates independently when multiple kits share one storage;
    /// this method returns the version recorded for `kit_id` alone, not the
    /// global maximum across all kits. Returns 0 if no migrations have been
    /// applied for this kit yet.
    fn current_schema_version_for(&self, _kit_id: &str) -> StorageResult<i32> {
        // Default falls back to the global version for backwards compatibility.
        // Backends that track per-kit versions override this.
        self.current_schema_version()
    }

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

// ---------------------------------------------------------------------------
// Queue-sibling ID derivation — deterministic, no random minting
// ---------------------------------------------------------------------------

/// Derive a deterministic `Uuid` for a queue sibling from the parent estate's
/// `Uuid` and the sibling `filename`. Mirrors Swift's `deriveQueueSiblingID`.
///
/// Algorithm: fold the filename's UTF-8 bytes into a 16-byte tag by cycling
/// through each byte position (XOR-reduce). Then XOR that tag with the parent
/// UUID's raw bytes. For any non-empty filename the tag is never all-zeros, so
/// the result always differs from the parent ID — they can never collide.
///
/// Guarantees:
/// - Deterministic: same `parent_id` + same `filename` → same result.
/// - Distinct: result != `parent_id` for all non-empty filenames.
/// - No random minting: `Uuid::new_v4()` is never called on this path.
fn derive_queue_sibling_id(parent_id: uuid::Uuid, filename: &str) -> uuid::Uuid {
    let filename_bytes = filename.as_bytes();
    if filename_bytes.is_empty() {
        // Empty filename is a programming error; return the parent ID so the
        // caller sees a detectable mismatch rather than a silent wrong config.
        return parent_id;
    }

    // Fold filename UTF-8 bytes into a 16-byte tag (XOR-reduce cycling positions).
    let mut tag = [0u8; 16];
    for (i, &byte) in filename_bytes.iter().enumerate() {
        tag[i % 16] ^= byte;
    }

    // XOR the parent UUID's raw bytes with the derived tag.
    let mut bytes = *parent_id.as_bytes();
    for i in 0..16 {
        bytes[i] ^= tag[i];
    }

    uuid::Uuid::from_bytes(bytes)
}
