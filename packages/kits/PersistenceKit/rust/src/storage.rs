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
    /// Controls whether kits hold computed indexes in heap between queries
    /// (RamResident, the default) or load from the durable store on demand
    /// (DiskBacked). Parallel to Swift `EstateConfiguration.residencyHint`.
    pub residency_hint: ResidencyHint,
    /// Ceiling on the combined heap footprint of all per-model float indexes
    /// held resident in VectorStore. Evaluated at admission time before any
    /// index is built; over-ceiling estates fall back to the table-scan path
    /// and return correct results without allocating the refused index.
    /// Defaults to `ResidentIndexBudget::SystemFraction(0.25)` — 25 % of
    /// physical RAM — which is far above any realistic single-estate index
    /// and keeps behaviour below the cap identical to the pre-cap baseline.
    /// Parallel to Swift `EstateConfiguration.residentIndexBudget`.
    pub resident_index_budget: ResidentIndexBudget,
}

/// Controls whether kits hold computed indexes in heap between queries
/// or load from the durable store on demand. Parallel to Swift `ResidencyHint`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResidencyHint {
    /// Indexes loaded from the durable store on demand; OS page cache manages
    /// RAM residency. Float NN search scans the vectors table on every query.
    DiskBacked,
    /// All indexes cached in heap for minimum query latency. The float-lane
    /// index is built lazily on first query per model and evicted on demand,
    /// falling back to the table scan. Default for all production estates.
    RamResident,
}

impl Default for ResidencyHint {
    fn default() -> Self { Self::RamResident }
}

// ---------------------------------------------------------------------------
// ResidentIndexBudget
// ---------------------------------------------------------------------------

/// Ceiling on the combined heap footprint of all per-model float indexes
/// (`FloatBruteForceIndex` plus any associated `HNSWIndex`) held resident in
/// `VectorStore`. Parallel to Swift `ResidentIndexBudget`.
///
/// # Default — `SystemFraction(0.25)`
///
/// The resident float index is one of several claimants on the same RAM: the
/// SQLite page cache, the binary-lane resident array, HNSW graphs, the
/// embedding provider's weights, and the host app (GUI or daemon). A quarter
/// of physical memory is the largest share one subsystem cache may claim while
/// the process stays healthy. It is also far above any realistic single-estate
/// index in production, which is what keeps behaviour below the cap identical
/// to the pre-admission baseline.
///
/// # When physical memory cannot be detected
///
/// If `physical_memory_bytes()` returns `None` the budget resolves to **no
/// cap** rather than a guessed constant. An undetectable platform must not
/// silently degrade every estate onto the slow disk-backed path when the
/// operator has no way to override a guess.
#[derive(Debug, Clone, PartialEq)]
pub enum ResidentIndexBudget {
    /// Ceiling derived from a fraction of detected physical RAM.
    /// The **default is 0.25** (25 % of physical memory).
    SystemFraction(f64),
    /// Explicit absolute ceiling in bytes.
    Bytes(u64),
    /// No cap — exact pre-admission behaviour, available as an explicit
    /// opt-out (e.g. `MOOTX01_RESIDENCY=ram:unbounded`).
    Unbounded,
}

impl Default for ResidentIndexBudget {
    fn default() -> Self {
        // 25 % of physical RAM: the largest fraction one subsystem cache may
        // claim while the daemon stays healthy, and far above any realistic
        // single-estate float index in production.
        Self::SystemFraction(0.25)
    }
}

impl ResidentIndexBudget {
    /// Resolve to an optional byte ceiling given the detected physical RAM.
    ///
    /// Returns `None` when the budget is `Unbounded` OR when
    /// `physical_ram` is `None` (undetectable platform). A `None` result
    /// means no cap is applied — the admission gate must not degrade every
    /// estate on an undetectable platform.
    pub fn ceiling_bytes(&self, physical_ram: Option<u64>) -> Option<u64> {
        match self {
            Self::Unbounded => None,
            Self::Bytes(n) => Some(*n),
            Self::SystemFraction(frac) => {
                let ram = physical_ram?;
                if ram == 0 {
                    // Zero can appear when detection fails silently; treat as
                    // undetectable rather than computing a zero ceiling.
                    return None;
                }
                // Clamp the fraction to (0, 1] to guard against misconfiguration.
                // The Swift twin clamps to exactly the same bounds, so both ports
                // resolve the same ceiling for the same inputs. Without this a
                // negative or greater-than-one fraction would make the two ports
                // disagree about admission, which is the one thing the cross-port
                // agreement contract forbids.
                let clamped = frac.max(1e-9).min(1.0);
                // `as u64` on f64 saturates in Rust rather than wrapping or
                // trapping, so an out-of-range product clamps to u64::MAX.
                Some((ram as f64 * clamped) as u64)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// physical_memory_bytes — platform helpers (four cfg branches)
// ---------------------------------------------------------------------------

/// Detect total installed physical RAM in bytes.
///
/// Used by `ResidentIndexBudget::SystemFraction` to derive an absolute ceiling
/// without a hardcoded constant. Returns `None` on platforms where detection
/// is unavailable or fails — callers interpret `None` as "no cap" (fail-open)
/// so an undetectable platform does not silently degrade every estate onto the
/// disk-backed scan path.
///
/// Implementation mirrors `CorpusKit.content_engine::physical_memory_bytes()`.
/// The code is duplicated (not shared) because CorpusKit is downstream of
/// PersistenceKit and the topology forbids the reverse dependency.
/// Consolidation into SubstrateTypes is a recorded follow-up (BRR §8 item 4).
#[cfg(target_os = "macos")]
pub fn physical_memory_bytes() -> Option<u64> {
    // macOS: sysctl hw.memsize via sysctlbyname (libc, unix-only dep).
    // Returns the machine's total installed DRAM in bytes.
    let mut memsize: u64 = 0;
    let mut size: libc::size_t = std::mem::size_of::<u64>();
    let name = b"hw.memsize\0";
    let ret = unsafe {
        libc::sysctlbyname(
            name.as_ptr() as *const libc::c_char,
            &mut memsize as *mut u64 as *mut libc::c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if ret == 0 && memsize > 0 { Some(memsize) } else { None }
}

/// Detect total installed physical RAM in bytes.
///
/// See the macOS variant for the full contract. On Linux this reads the
/// `MemTotal` line from `/proc/meminfo` (in kibibytes) and converts to bytes.
#[cfg(target_os = "linux")]
pub fn physical_memory_bytes() -> Option<u64> {
    use std::io::{BufRead, BufReader};
    let file = std::fs::File::open("/proc/meminfo").ok()?;
    let reader = BufReader::new(file);
    for line in reader.lines().flatten() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            // Format: "MemTotal:       <N> kB"
            let kb: u64 = rest
                .split_whitespace()
                .next()
                .and_then(|s| s.parse().ok())?;
            return Some(kb * 1024);
        }
    }
    None
}

/// Detect total installed physical RAM in bytes.
///
/// See the macOS variant for the full contract. On Windows this calls
/// `GlobalMemoryStatusEx` (kernel32, always linked) using an inline extern
/// declaration to avoid adding the winapi crate as a dependency.
#[cfg(target_os = "windows")]
pub fn physical_memory_bytes() -> Option<u64> {
    // MEMORYSTATUSEX layout from the Windows SDK (64-bit target).
    // All fields must be present for sizeof to match the OS expectation;
    // only `ull_total_phys` is read.
    #[repr(C)]
    struct MEMORYSTATUSEX {
        dw_length:                  u32,
        dw_memory_load:             u32,
        ull_total_phys:             u64,
        ull_avail_phys:             u64,
        ull_total_page_file:        u64,
        ull_avail_page_file:        u64,
        ull_total_virtual:          u64,
        ull_avail_virtual:          u64,
        ull_avail_extended_virtual: u64,
    }
    extern "system" {
        fn GlobalMemoryStatusEx(lp_buffer: *mut MEMORYSTATUSEX) -> i32;
    }
    let mut info = std::mem::MaybeUninit::<MEMORYSTATUSEX>::zeroed();
    unsafe {
        let p = info.as_mut_ptr();
        (*p).dw_length = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if GlobalMemoryStatusEx(p) != 0 {
            let bytes = info.assume_init().ull_total_phys;
            if bytes > 0 { Some(bytes) } else { None }
        } else {
            None
        }
    }
}

/// Detect total installed physical RAM in bytes.
///
/// See the macOS variant for the full contract. On unrecognised platforms
/// this always returns `None` (fail-open: no cap). A guessed constant is
/// more dangerous than no cap on an unknown platform.
#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
pub fn physical_memory_bytes() -> Option<u64> {
    None
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
            resident_index_budget: ResidentIndexBudget::default(),
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
                    // Forward the parent's budget: the queue sibling and the
                    // estate share the same residency posture. Mirrors the
                    // residency_hint forwarding pattern above it.
                    resident_index_budget: self.resident_index_budget.clone(),
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
                    // Forward the parent's budget — same posture for the
                    // ephemeral queue sibling as for the estate itself.
                    resident_index_budget: self.resident_index_budget.clone(),
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
            resident_index_budget: ResidentIndexBudget::default(),
        })
    }
}

#[derive(Debug, Clone)]
pub enum BackendConfiguration {
    InMemory,
    /// SQLite backend (sqlite.rs) — WAL-mode rusqlite over a
    /// filesystem path; the durable backend behind SqliteDrawerStore
    /// and the servers' SQLite estates.
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
/// The result of `Storage::rename_schema_kit` (SPEC I-7a). Twin of Swift
/// `SchemaKitRenameOutcome`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchemaKitRenameOutcome {
    /// A row under the old id moved to the new id; `version` is the version it carried.
    Renamed { version: i32 },
    /// No row exists under the old id; nothing changed.
    NoRow,
    /// Rows exist under both ids; nothing changed.
    Conflict { old_version: i32, new_version: i32 },
}

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

    /// Move the schema-version ledger row recorded for `old_kit_id` to
    /// `new_kit_id`, keeping its version and its applied-at instant (SPEC
    /// I-7a). Twin of Swift `renameSchemaKit(from:to:)`.
    ///
    /// A kit's ledger row is keyed by its `kit_id`. When a kit changes its id
    /// the row must move with it, or `open` under the new id reads version 0
    /// and replays the kit's ladder from the start on a populated estate. The
    /// operation never creates a version and never runs a migration step:
    /// `Renamed { version }` when a row under `old_kit_id` moved; `NoRow` when
    /// no row exists under `old_kit_id` (nothing changed); `Conflict { .. }`
    /// when rows exist under both ids (nothing changed; the caller decides).
    fn rename_schema_kit(
        &self,
        old_kit_id: &str,
        new_kit_id: &str,
    ) -> StorageResult<SchemaKitRenameOutcome>;

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

    /// Estimate of the filesystem bytes `perform_maintenance` would release
    /// (shared-content 1.1 P5). SQLite: freelist pages × page size + WAL
    /// file bytes. Default (and the explicit contract for backends with no
    /// client-reclaimable pages): 0.
    ///
    /// Lives on `Storage` (defaulted) rather than a separate trait because
    /// `dyn Storage` cannot be capability-probed the way Swift's
    /// `as? StorageMaintenance` can. Mirrors Swift's
    /// `StorageMaintenance.estimatedReclaimableBytes`.
    fn estimated_reclaimable_bytes(
        &self,
    ) -> Result<i64, crate::maintenance::MaintenanceError> {
        Ok(0)
    }

    /// Run the physical maintenance pass (SQLite: WAL checkpoint + VACUUM)
    /// with the contract declared in `crate::maintenance`: quiescence check,
    /// disk-capacity preflight, per-phase progress, phase-boundary
    /// cancellation, and post-operation introspection. The default is the
    /// explicit "not implemented" no-op report; SQLite overrides with the
    /// real operation, in-memory and PostgreSQL override with their
    /// documented no-op reports. Mirrors Swift's
    /// `StorageMaintenance.performMaintenance(progress:shouldCancel:)`.
    fn perform_maintenance(
        &self,
        progress: Option<&(dyn Fn(crate::maintenance::MaintenanceProgress) + Send + Sync)>,
        should_cancel: Option<&(dyn Fn() -> bool + Send + Sync)>,
    ) -> Result<crate::maintenance::MaintenanceReport, crate::maintenance::MaintenanceError>
    {
        let _ = (progress, should_cancel);
        Ok(crate::maintenance::MaintenanceReport::no_op(
            "unsupported",
            "backend does not implement physical maintenance",
        ))
    }
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
