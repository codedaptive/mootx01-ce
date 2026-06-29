// estate_admin.rs — the ADMIN-PLANE engine for moot-mgr, the Rust twin of the
// Swift EstateAdmin.swift. Estate provisioning + lifecycle, driven through
// GeniusLocusKit's EstateCoordinator.
//
// ========================== SECURITY BOUNDARY (ADMIN) ========================
// This engine performs the resident host's PRIVILEGED writes: it creates real
// MOOTs through the GLK substrate (manifest + write-gate + audit + clock — never
// a side-door SQLite file) and tears their backing stores down. It is NEVER
// reachable from the unauthenticated read surface. The only paths in are the
// admin verb cases in `HttpReadApi::apply_control`, which BOTH gated surfaces
// dispatch through: the UDS control channel (socket 0600) and the token+Origin
// HTTP control path. `apply_control` reaches this engine only AFTER the gate has
// admitted the caller. `destroy` carries a second guard at this layer: the
// operator must re-type the estate's exact name (a name mismatch refuses the
// destroy even for an authenticated caller).
// ===========================================================================
//
// ── THE TWO LOAD-BEARING PARITY DEBTS THIS PORT RESOLVES ──────────────────────
//
// DEBT-1 (cache-on default): the cache-on default lived only in Swift
//   `EstateAdmin.resolveCacheConfig`. This module gives it a Rust home —
//   `resolve_cache_config` reads MOOTX01_ESTATE_CACHE / _BYTES and otherwise
//   returns the cache-ON default, exactly as the Swift resolver does. The
//   resolved config is threaded into every `EstateConfiguration` the engine
//   builds, so the backing storage wraps the tested `CachingRowStore` LRU tier.
//
// PROVISION vs OPEN: the current ARIA registry wires semantic recall (BM25 +
//   vector) after `coord.open` for all backend constructors, so a bare open is
//   no longer dark. This engine still uses `coord.provision(...)` — the GLK path
//   that explicitly wires + registers a Corpus — which remains the correct
//   estate-construction path for the admin plane (cache + corpus registration).
//
// Determinism: provisioning carries no time-dependent computation. The engine
// threads an explicit `now` (epoch seconds) into provision/capture so no clock
// is read inside the engine, per the Rust substrate determinism convention.

use std::collections::HashMap;
use std::sync::Arc;

// The 1.0 default recall ensemble (RI/PPMI/LSA/NMF/FDC). Lives in the providers
// crate because it NEWs the concrete providers; moot-mgr is the production caller
// that owns the default (Rust has no default arguments).
use corpus_kit_providers::default_ensemble;
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::{
    EstateCoordinator, EstateKind, EstateMountState, EstateProvisionParams, GeniusLocusKitError,
    SyncMode,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::cache_config::EstateCacheConfig;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};

use crate::admin_payloads::{
    EstateAdminEntry, EstateAdminPayload, EstateAdminRequest, EstateAdminResult, EstateBackendKind,
    EstateLifecycleRequest,
};

/// The busy-timeout for SQLite-backed admin estates, in seconds. Matches the
/// 5-second default the ARIA_MCP Rust server uses for its SQLite estates.
const SQLITE_BUSY_TIMEOUT_SECS: f64 = 5.0;

/// The default cache ceiling for a live estate when the environment does not
/// override it: 64 MiB of hot-tier LRU. Identical to Swift
/// `EstateAdmin.defaultCacheCeilingBytes` — a sane working-set ceiling for an
/// interactive single-estate resident host: large enough that the recall hot
/// path stays in-cache, small enough to bound RSS.
const DEFAULT_CACHE_CEILING_BYTES: i64 = 64 * 1024 * 1024;

/// Highest sensitivity level eligible for the cache. Level 2 is the maximum the
/// cache contract permits — `EstateCacheConfig` hard-clamps Secret (level 3) out
/// regardless. Mirrors Swift `EstateAdmin.defaultCacheSensitivityThreshold`.
const DEFAULT_CACHE_SENSITIVITY_THRESHOLD: i32 = 2;

/// Errors raised by the admin engine before it reaches GLK. Structured per the
/// project error rule. Mirrors Swift `AdminError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdminError {
    /// A request field failed validation. `detail` names the offending field.
    InvalidRequest { detail: String },
    /// A lifecycle verb named an estate UUID the engine is not hosting.
    UnknownEstate { uuid: String },
    /// A destroy request's confirm-name did not match the estate's stored name.
    DestroyConfirmMismatch,
    /// GLK provision/lifecycle or backend construction failed. Carries the cause.
    EngineFailure { reason: String },
}

impl AdminError {
    /// Human-readable detail for the verb result, mirroring Swift
    /// `HTTPReadAPI.adminErrorDetail`.
    pub fn detail(&self) -> String {
        match self {
            AdminError::InvalidRequest { detail } => format!("invalid request: {detail}"),
            AdminError::UnknownEstate { uuid } => format!("unknown estate '{uuid}'"),
            AdminError::DestroyConfirmMismatch => {
                "destroy refused: confirm name does not match the estate name".to_string()
            }
            AdminError::EngineFailure { reason } => format!("estate operation failed: {reason}"),
        }
    }
}

/// Per-estate provenance the engine remembers to drive lifecycle and the read
/// reflection. Mirrors the Swift `EstateAdmin.Provenance` struct.
struct Provenance {
    handle: EstateHandle,
    /// The persistence-kit `Storage` the estate's DrawerStore opened over. Held
    /// so `backing_storage_is_caching` can inspect its resolved cache config —
    /// the introspection seam the DEBT-1 verify line reaches through (parity of
    /// Swift's `backingStorageIsCaching`, which downcasts `Provenance.storage`).
    storage: Arc<dyn Storage>,
    /// The composition kind requested at provision time, retained for the read
    /// badge (the coordinator does not expose the kind back across its boundary).
    kind: EstateKind,
    /// The backend kind requested at provision time, retained for the read badge.
    backend: EstateBackendKind,
    /// The estate display name, retained for the read badge and the destroy
    /// double-confirm guard (the coordinator's handle carries only the UUID).
    estate_name: String,
}

/// Render an `EstateMountState` as its wire raw-value string, matching the Swift
/// `EstateMountState.rawValue` ("mounted" | "quiesced" | "draining"). The
/// transitional `Unmounted` state never reaches a read payload (the estate is
/// dropped from the registry on close), but is mapped for completeness.
fn mount_state_raw(state: EstateMountState) -> &'static str {
    match state {
        EstateMountState::Mounted => "mounted",
        EstateMountState::Quiesced => "quiesced",
        EstateMountState::Draining => "draining",
        EstateMountState::Unmounted => "unmounted",
    }
}

/// The admin-plane engine: owns a `GeniusLocusKit` coordinator, provisions and
/// tears down estates, and reflects their mount state back for the read plane.
/// One instance per resident host. Mirrors the Swift `EstateAdmin` actor; the
/// Rust port serializes access through a single owner (the host holds it behind
/// the host's own lock — the coordinator is not internally synchronized here).
pub struct EstateAdmin {
    /// The composition layer the engine drives. Each provisioned estate is one
    /// open estate in this coordinator's registry.
    coordinator: EstateCoordinator,
    /// Per-estate provenance, keyed by estate UUID string so a lifecycle verb
    /// can resolve a request by id.
    hosted: HashMap<String, Provenance>,
    /// Directory under which SQLite-backed admin estates are created (one file
    /// per estate). InMemory estates ignore it.
    estates_directory: String,
    /// Cache configuration applied to every estate this engine provisions
    /// (DEBT-1). Resolved once at construction so the live resident host runs
    /// the hot cache ON by default; a test or operator can override it. Threaded
    /// into every `EstateConfiguration` the engine builds.
    cache_config: EstateCacheConfig,
}

impl EstateAdmin {
    /// Create an admin engine with the cache-ON default resolved from the
    /// environment (DEBT-1). `estates_directory` is the filesystem directory for
    /// SQLite-backed estate stores (created on demand at provision time).
    ///
    /// Mirrors Swift `EstateAdmin.init(estatesDirectory:)` whose `cacheConfig`
    /// defaults to `EstateAdmin.resolveCacheConfig()`.
    pub fn new(estates_directory: impl Into<String>) -> Self {
        Self::with_cache_config(estates_directory, Self::resolve_cache_config())
    }

    /// Create an admin engine with an explicit cache config (tests pin behaviour
    /// here, e.g. `EstateCacheConfig::disabled()`). Mirrors the Swift memberwise
    /// initialiser `EstateAdmin.init(estatesDirectory:cacheConfig:)`.
    pub fn with_cache_config(
        estates_directory: impl Into<String>,
        cache_config: EstateCacheConfig,
    ) -> Self {
        EstateAdmin {
            coordinator: EstateCoordinator::new(),
            hosted: HashMap::new(),
            estates_directory: estates_directory.into(),
            cache_config,
        }
    }

    /// Resolve the cache configuration from the process environment (DEBT-1).
    ///
    /// The hot cache is ON by default for the live resident host. The
    /// environment can override:
    ///   - `MOOTX01_ESTATE_CACHE=0` (or `false`/`off`/`disabled`/`no`) → cache
    ///     OFF. Any other value (or an unset variable) leaves the cache ON.
    ///   - `MOOTX01_ESTATE_CACHE_BYTES=<int>` → override the byte ceiling.
    ///     Non-integer or absent values fall back to `DEFAULT_CACHE_CEILING_BYTES`.
    ///
    /// Reading the environment here is a one-shot configuration read at engine
    /// construction, not a per-operation clock call — it does not violate the
    /// determinism rule (no time read; the value is frozen at construction).
    /// Byte-for-byte parity with Swift `EstateAdmin.resolveCacheConfig`.
    pub fn resolve_cache_config() -> EstateCacheConfig {
        let enabled = match std::env::var("MOOTX01_ESTATE_CACHE") {
            Ok(v) => !matches!(
                v.to_lowercase().as_str(),
                "0" | "false" | "off" | "disabled" | "no"
            ),
            // Unset → cache ON (the default).
            Err(_) => true,
        };
        let ceiling = std::env::var("MOOTX01_ESTATE_CACHE_BYTES")
            .ok()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(DEFAULT_CACHE_CEILING_BYTES);
        EstateCacheConfig::new(enabled, ceiling, DEFAULT_CACHE_SENSITIVITY_THRESHOLD)
    }

    /// The resolved cache config this engine applies to every estate it
    /// provisions. Exposed so the DEBT-1 verify line can assert the resolved
    /// default is enabled with the expected ceiling. Mirrors Swift
    /// `EstateAdmin.resolvedCacheConfig`.
    pub fn resolved_cache_config(&self) -> &EstateCacheConfig {
        &self.cache_config
    }

    /// Provision a new estate from a validated admin request — the DEBT-1+2 core.
    ///
    /// Validates the request, constructs the cache-on backing storage + DrawerStore
    /// for the chosen backend (DEBT-1), and calls the coordinator's `provision`
    /// (DEBT-2) — the substrate creation path that wires the manifest, write-gate,
    /// audit, clock, the sub-stores the kind requires, AND registers the Corpus so
    /// the BM25 lane is lit. On success the estate is mounted and recorded.
    ///
    /// `now` is the provision instant in epoch seconds (the caller owns the clock).
    /// Mirrors Swift `EstateAdmin.provision(_:)`.
    pub fn provision(
        &mut self,
        request: &EstateAdminRequest,
        now: i64,
    ) -> Result<EstateAdminResult, AdminError> {
        // Validate scalar fields and enums BEFORE creating any storage so a bad
        // request never leaves an orphan store on disk.
        if request.estate_name.is_empty() {
            return Err(AdminError::InvalidRequest {
                detail: "estateName must not be empty".to_string(),
            });
        }
        if request.owner.is_empty() {
            return Err(AdminError::InvalidRequest {
                detail: "owner must not be empty".to_string(),
            });
        }
        let kind = parse_kind(&request.kind).ok_or_else(|| AdminError::InvalidRequest {
            detail: format!("unknown kind '{}'", request.kind),
        })?;
        let backend = EstateBackendKind::from_raw(&request.backend).ok_or_else(|| {
            AdminError::InvalidRequest {
                detail: format!("unknown backend '{}'", request.backend),
            }
        })?;
        let sync_mode = parse_sync_mode(&request.sync_mode).ok_or_else(|| {
            AdminError::InvalidRequest {
                detail: format!("unknown syncMode '{}'", request.sync_mode),
            }
        })?;
        if request.zoom_window_low > request.zoom_window_high {
            return Err(AdminError::InvalidRequest {
                detail: format!(
                    "zoomWindowLow ({}) must be <= zoomWindowHigh ({})",
                    request.zoom_window_low, request.zoom_window_high
                ),
            });
        }

        // DEBT-1: build the cache-on backing storage + the DrawerStore over it.
        let (store, storage) = self.make_storage(backend)?;
        let owner = OwnerCredentials::new(&request.owner);
        let params = EstateProvisionParams {
            estate_name: request.estate_name.clone(),
            kind,
            zoom_window_low: request.zoom_window_low,
            zoom_window_high: request.zoom_window_high,
            framework_profile: request.framework_profile.clone(),
            sync_mode,
        };

        // DEBT-2: provision-with-corpus. The coordinator creates → opens → wires
        // sub-stores (Corpus + VectorStore for GLK; Corpus for CorpusOnly) and
        // registers the Corpus so the BM25 + dense vector recall lanes (Lane D)
        // are lit. This is the construction the Rust host MUST use instead of
        // `open` (which leaves the vector recall lanes dark).
        // `default_ensemble()` is the canonical 1.0 five-signal recall default
        // (RI/PPMI/LSA/NMF/FDC) — no CoreML, trained on-corpus and reproducible
        // cross-port. moot-mgr is the production caller and owns the default,
        // since Rust has no default arguments. The learned model-weight embedding
        // providers are v1.1 (not wired here).
        let handle = self
            .coordinator
            .provision(
                Arc::clone(&store),
                Arc::clone(&storage),
                None,
                owner,
                params,
                default_ensemble(),
            )
            .map_err(|e| AdminError::EngineFailure {
                reason: glk_error_reason(&e),
            })?;
        // `store` was moved into the coordinator's registry by value via the Arc;
        // we keep `storage` for the cache-introspection seam. Drop our DrawerStore
        // Arc clone — the coordinator owns the live one now.
        drop(store);

        let uuid = uuid_string(&handle);
        let state = self
            .coordinator
            .mount_state(&handle)
            .unwrap_or(EstateMountState::Mounted);
        self.hosted.insert(
            uuid.clone(),
            Provenance {
                handle,
                storage,
                kind,
                backend,
                estate_name: request.estate_name.clone(),
            },
        );
        // `now` is currently unused by the construction path (provisioning carries
        // no time-dependent computation), but is threaded so a future audit-stamp
        // step reuses the caller's clock rather than reading one here.
        let _ = now;

        Ok(EstateAdminResult {
            ok: true,
            detail: format!(
                "provisioned {} estate '{}'",
                kind_raw(kind),
                request.estate_name
            ),
            estate_uuid: Some(uuid),
            mount_state: Some(mount_state_raw(state).to_string()),
        })
    }

    /// Quiesce a hosted estate — stop accepting new work, keep it mounted.
    /// Mirrors Swift `EstateAdmin.quiesce(_:)`.
    pub fn quiesce(
        &mut self,
        request: &EstateLifecycleRequest,
    ) -> Result<EstateAdminResult, AdminError> {
        let handle = self.handle_for(&request.estate_uuid)?;
        self.coordinator
            .quiesce(&handle)
            .map_err(|e| AdminError::EngineFailure {
                reason: glk_error_reason(&e),
            })?;
        let state = self
            .coordinator
            .mount_state(&handle)
            .unwrap_or(EstateMountState::Quiesced);
        Ok(EstateAdminResult {
            ok: true,
            detail: "quiesced".to_string(),
            estate_uuid: Some(request.estate_uuid.clone()),
            mount_state: Some(mount_state_raw(state).to_string()),
        })
    }

    /// Drain a hosted estate — wait for in-flight work, then quiesce.
    /// Mirrors Swift `EstateAdmin.drain(_:)`.
    pub fn drain(
        &mut self,
        request: &EstateLifecycleRequest,
    ) -> Result<EstateAdminResult, AdminError> {
        let handle = self.handle_for(&request.estate_uuid)?;
        self.coordinator
            .drain(&handle)
            .map_err(|e| AdminError::EngineFailure {
                reason: glk_error_reason(&e),
            })?;
        let state = self
            .coordinator
            .mount_state(&handle)
            .unwrap_or(EstateMountState::Quiesced);
        Ok(EstateAdminResult {
            ok: true,
            detail: "drained".to_string(),
            estate_uuid: Some(request.estate_uuid.clone()),
            mount_state: Some(mount_state_raw(state).to_string()),
        })
    }

    /// Destroy a hosted estate — DOUBLE-CONFIRMED, then torn down through GLK.
    ///
    /// The operator must re-type the estate's exact name in `confirm_name`. A
    /// mismatch refuses the destroy with `AdminError::DestroyConfirmMismatch` —
    /// no data is touched. On a match, the coordinator's `destroy` closes the
    /// estate and tears down every sub-store the kind wired, then the estate is
    /// dropped from the provenance map. Mirrors Swift `EstateAdmin.destroy(_:)`.
    pub fn destroy(
        &mut self,
        request: &EstateLifecycleRequest,
    ) -> Result<EstateAdminResult, AdminError> {
        let prov = self
            .hosted
            .get(&request.estate_uuid)
            .ok_or_else(|| AdminError::UnknownEstate {
                uuid: request.estate_uuid.clone(),
            })?;
        // Double-confirm: the re-typed name must equal the estate's stored name.
        if request.confirm_name.as_deref() != Some(prov.estate_name.as_str()) {
            return Err(AdminError::DestroyConfirmMismatch);
        }
        let handle = prov.handle;
        let name = prov.estate_name.clone();
        self.coordinator
            .destroy(&handle)
            .map_err(|e| AdminError::EngineFailure {
                reason: glk_error_reason(&e),
            })?;
        self.hosted.remove(&request.estate_uuid);
        Ok(EstateAdminResult {
            ok: true,
            detail: format!("destroyed '{name}'"),
            estate_uuid: Some(request.estate_uuid.clone()),
            mount_state: None,
        })
    }

    /// Snapshot the hosted estates for the read plane's Estates view. One entry
    /// per hosted estate, sorted by UUID so the wire output is byte-stable.
    /// Mirrors Swift `EstateAdmin.payload()`.
    pub fn payload(&self) -> EstateAdminPayload {
        let mut entries: Vec<EstateAdminEntry> = self
            .hosted
            .iter()
            .map(|(uuid, prov)| {
                let state = self
                    .coordinator
                    .mount_state(&prov.handle)
                    .unwrap_or(EstateMountState::Mounted);
                EstateAdminEntry {
                    estate_uuid: uuid.clone(),
                    estate_name: prov.estate_name.clone(),
                    kind: kind_raw(prov.kind).to_string(),
                    backend: prov.backend.raw_value().to_string(),
                    mount_state: mount_state_raw(state).to_string(),
                }
            })
            .collect();
        entries.sort_by(|a, b| a.estate_uuid.cmp(&b.estate_uuid));
        EstateAdminPayload { hosted: entries }
    }

    // MARK: - Introspection seams (DEBT-1 + DEBT-2 verify lines)

    /// Whether a hosted estate's backing storage is running the hot cache —
    /// i.e. it was constructed with `cache_config.enabled` true, which makes its
    /// `row_store()` a `CachingRowStore` (DEBT-1). Returns `None` for an unknown
    /// UUID. The introspection seam tests reach through, parity of Swift's
    /// `backingStorageIsCaching(for:)`.
    ///
    /// The Rust `RowStore` trait exposes no downcast, so the host asserts on the
    /// resolved `cache_config.enabled` carried by the storage's own configuration
    /// — the exact flag PersistenceKit's `Storage::row_store` branches on to wrap
    /// the bare row store in `CachingRowStore` (see `inmemory.rs` / `sqlite.rs`).
    /// The behavioural CachingRowStore wrap itself is conformance-gated inside
    /// PersistenceKit (`cache_wiring_tests`); here the host proves it threaded the
    /// cache-on config through to the storage the estate opened over.
    pub fn backing_storage_is_caching(&self, uuid: &str) -> Option<bool> {
        self.hosted
            .get(uuid)
            .map(|prov| prov.storage.configuration().cache_config.enabled)
    }

    /// Whether a hosted estate has a Corpus registered — i.e. it was constructed
    /// via the provision-with-corpus path, not `open` (DEBT-2). Returns `None`
    /// for an unknown UUID. The introspection seam the DEBT-2 verify line reaches
    /// through; parity of the Swift `kit.corpusKits[handle] != nil` assertion.
    pub fn backing_estate_has_corpus(&self, uuid: &str) -> Option<bool> {
        self.hosted
            .get(uuid)
            .map(|prov| self.coordinator.has_corpus(&prov.handle))
    }

    /// Immutable access to the owned coordinator, for the in-process read
    /// reflection and the DEBT-2 BM25 proof (a `recall_scored` call against the
    /// provisioned estate). Mirrors Swift `ResidentHost.adminHandle()` exposing
    /// the engine for in-process consumers/tests.
    pub fn coordinator(&self) -> &EstateCoordinator {
        &self.coordinator
    }

    /// Mutable access to the owned coordinator, for the in-process capture +
    /// drain pump the DEBT-2 BM25 proof drives (a `capture_with_mode` followed by
    /// `await_encode_drain`). Production callers reach the substrate only through
    /// the gated control surface; this is the in-process seam.
    pub fn coordinator_mut(&mut self) -> &mut EstateCoordinator {
        &mut self.coordinator
    }

    /// Resolve a hosted estate's handle by UUID string, or error. Mirrors the
    /// Swift `EstateAdmin.provenance(for:)` lookup.
    pub fn handle_for(&self, uuid: &str) -> Result<EstateHandle, AdminError> {
        self.hosted
            .get(uuid)
            .map(|p| p.handle)
            .ok_or_else(|| AdminError::UnknownEstate {
                uuid: uuid.to_string(),
            })
    }

    // MARK: - Internals

    /// Construct the cache-on backing storage and the DrawerStore over it for the
    /// requested backend (DEBT-1). Mirrors Swift `EstateAdmin.makeStorage(backend:)`.
    ///
    /// Returns `(store, storage)` where `store` is the `DrawerStore` the estate
    /// opens over and `storage` is the raw `Storage` handle the coordinator wires
    /// the Corpus/VectorStore on AND the cache-introspection seam inspects. The
    /// same configured storage backs both: the in-memory path wraps the configured
    /// `InMemoryStorage` as an `InMemoryDrawerStore` and hands the raw `Storage`
    /// clone through — the construction shape the Rust GLK `provision` expects.
    ///
    /// Both backends apply identical caching semantics: the resolved `cache_config`
    /// is threaded into their `EstateConfiguration`, and `Storage::row_store()`
    /// wraps the backing store in a `CachingRowStore` LRU hot tier when
    /// `cache_config.enabled` is true. The predicate is the same for InMemory and
    /// SQLite (`inmemory.rs` / `sqlite.rs`, same branch on `cache_config.enabled`).
    ///
    /// - InMemory: `InMemoryStorage::new(config)` with the resolved cache config.
    ///   `InMemoryDrawerStore::with_storage` opens the LocusKit schema over it.
    /// - SQLite: a file at `<estates_directory>/<uuid>.sqlite`. The cache-configured
    ///   `EstateConfiguration` is passed to `SqliteDrawerStore::from_path_with_config`,
    ///   which threads it through to `SqliteStorage`. A second `SqliteStorage` handle
    ///   over the same file is retained for Corpus sub-store wiring and the
    ///   cache-introspection seam — both handles carry the resolved cache config.
    fn make_storage(
        &self,
        backend: EstateBackendKind,
    ) -> Result<(Arc<dyn DrawerStore>, Arc<dyn Storage>), AdminError> {
        let estate_id = uuid::Uuid::new_v4();
        match backend {
            EstateBackendKind::InMemory => {
                // DEBT-1: pass the resolved cache config so InMemoryStorage::row_store
                // wraps the bare store in the tested CachingRowStore hot tier when
                // enabled. The live resident host runs with the cache ON.
                let mut config = EstateConfiguration::new(estate_id, BackendConfiguration::InMemory);
                config.cache_config = self.cache_config.clone();
                let storage = Arc::new(InMemoryStorage::new(config));
                // The DrawerStore opens over the SAME configured storage so the
                // estate's row path goes through the CachingRowStore tier.
                let drawer_store = InMemoryDrawerStore::with_storage(
                    Arc::clone(&storage),
                    // `now`-less ctor seed: InMemoryDrawerStore::with_storage stamps
                    // created_at/last_modified from this seed on first open. The
                    // coordinator's provision overwrites the estate_name + manifest
                    // fields immediately after, so this seed only sets the initial
                    // manifest timestamps — a stable anchor keeps construction
                    // deterministic (no clock read here).
                    INIT_NOW,
                    None,
                )
                .map_err(|e| AdminError::EngineFailure {
                    reason: format!("InMemoryDrawerStore::with_storage failed: {e:?}"),
                })?;
                let store: Arc<dyn DrawerStore> = Arc::new(drawer_store);
                let storage_dyn: Arc<dyn Storage> = storage;
                Ok((store, storage_dyn))
            }
            EstateBackendKind::Sqlite => {
                std::fs::create_dir_all(&self.estates_directory).map_err(|e| {
                    AdminError::EngineFailure {
                        reason: format!(
                            "create estates directory {:?} failed: {e}",
                            self.estates_directory
                        ),
                    }
                })?;
                let path = format!(
                    "{}/{}.sqlite",
                    self.estates_directory.trim_end_matches('/'),
                    estate_id
                );
                // Build a cache-configured EstateConfiguration and hand it to
                // SqliteDrawerStore::from_path_with_config. SqliteStorage::row_store
                // wraps the backing store in a CachingRowStore LRU hot tier when
                // config.cache_config.enabled is true — the same predicate the InMemory
                // path applies (InMemoryStorage::row_store, same branch). Both paths
                // now have identical caching semantics; the parity gap is closed.
                //
                // The same config is used for both the DrawerStore AND the raw Storage
                // handle retained for the Corpus sub-store wiring + the cache-
                // introspection seam (backing_storage_is_caching). Both open over the
                // same SQLite file and see the same cache config, so `row_store()`
                // wraps identically in both handles.
                let mut config = EstateConfiguration::new(
                    estate_id,
                    BackendConfiguration::Sqlite {
                        path: path.clone(),
                        busy_timeout_secs: SQLITE_BUSY_TIMEOUT_SECS,
                    },
                );
                config.cache_config = self.cache_config.clone();
                let drawer_store =
                    SqliteDrawerStore::from_path_with_config(config.clone(), INIT_NOW, None)
                        .map_err(|e| AdminError::EngineFailure {
                            reason: format!(
                                "SqliteDrawerStore::from_path_with_config failed: {e:?}"
                            ),
                        })?;
                // A second SqliteStorage handle over the same file for the Corpus
                // sub-store wiring and the cache-introspection seam. Both handles share
                // the WAL log; the single-write-connection-per-estate model serialises
                // writes through SQLite's own WAL locking.
                let storage = persistence_kit::SqliteStorage::new(config).map_err(|e| {
                    AdminError::EngineFailure {
                        reason: format!("SqliteStorage::new failed: {e:?}"),
                    }
                })?;
                let store: Arc<dyn DrawerStore> = Arc::new(drawer_store);
                let storage_dyn: Arc<dyn Storage> = Arc::new(storage);
                Ok((store, storage_dyn))
            }
        }
    }
}

/// Arbitrary wall-clock anchor seeding the DrawerStore's first-open manifest
/// timestamps. Estates are re-stamped by `provision` immediately after; a fixed
/// value keeps construction deterministic (no clock read). Matches the
/// ARIA_MCP Rust registry's `INIT_NOW` convention.
const INIT_NOW: i64 = 1_700_000_000;

/// Parse the Swift `EstateKind` raw value, or `None` for an unknown value.
fn parse_kind(s: &str) -> Option<EstateKind> {
    match s {
        "GLK" => Some(EstateKind::Glk),
        "CorpusOnly" => Some(EstateKind::CorpusOnly),
        "LocusOnly" => Some(EstateKind::LocusOnly),
        _ => None,
    }
}

/// The Swift `EstateKind` raw value for a kind (the coordinator's `raw_value`
/// is on `coordinator::EstateKind` but is not re-exported as a method here, so
/// the host renders it locally to keep the badge string stable).
fn kind_raw(kind: EstateKind) -> &'static str {
    match kind {
        EstateKind::Glk => "GLK",
        EstateKind::CorpusOnly => "CorpusOnly",
        EstateKind::LocusOnly => "LocusOnly",
    }
}

/// Parse the Swift `SyncMode` raw value, or `None` for an unknown value.
fn parse_sync_mode(s: &str) -> Option<SyncMode> {
    match s {
        "None" => Some(SyncMode::None),
        "CloudKit" => Some(SyncMode::CloudKit),
        "Federation" => Some(SyncMode::Federation),
        _ => None,
    }
}

/// Render an `EstateHandle`'s UUID as the lowercase hyphenated string used as the
/// provenance map key and the wire `estateUUID`.
fn uuid_string(handle: &EstateHandle) -> String {
    uuid::Uuid::from_bytes(handle.estate_uuid).to_string()
}

/// A short reason string for a `GeniusLocusKitError`, surfaced in the verb result.
fn glk_error_reason(e: &GeniusLocusKitError) -> String {
    format!("{e:?}")
}
