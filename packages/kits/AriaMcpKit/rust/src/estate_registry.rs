//! Estate registry — keyed by UUID, with a default estate.
//!
//! Mirrors the Swift `ToolDispatcher` multi-estate routing: one default
//! estate plus a map of additional estates keyed by UUID. Unknown or
//! malformed `estateID` is an `invalidParams` error, consistent with the
//! Swift dispatcher's `resolveHandle(_:)` behavior.
//!
//! # Backend constructors
//!
//! Three backend shapes are available, all wiring semantic recall (BM25 +
//! vector lanes via Corpus + VectorStore) after `coord.open`:
//!
//! - **In-memory** (`new_inmemory`, `new_inmemory_with`, `register_inmemory`):
//!   ephemeral, discarded on process exit. Reached from the product only by
//!   `--in-memory`, which serves it as a transient estate (R8, 2026-09-08):
//!   no federation identity and no charter seeding.
//!   **Semantic recall lanes are wired** via a separate `InMemoryStorage`
//!   handle used exclusively by the Corpus + VectorStore. The LocusKit tables
//!   (drawers, tunnels, kg_facts) and the CorpusKit/SynapseKit tables (chunks,
//!   vectors) are disjoint namespaces — two handles on the same ephemeral store
//!   is the in-memory equivalent of the SQLite two-handle pattern.
//! - **SQLite** (`new_sqlite`, `new_sqlite_for_maintenance`, `register_sqlite`): WAL-mode durable estate
//!   at a caller-supplied filesystem path. Database file is created if absent.
//!   **Semantic recall lanes (BM25 + vector) are wired** after `coord.open` by
//!   registering a `Corpus` and borrowing its single dense `VectorStore`
//!   (`Corpus::shared_vector_store`) for the scored-recall lane — one store over
//!   the `vectors` table, not a second instance. Mirrors the Swift wiring:
//!   `Corpus(storage:)` + `kit.registerCorpus` +
//!   `kit.registerVectorStore(corpus.sharedVectorStore)`. Idempotent across
//!   restarts: Corpus runs the schema migrations via `migrate` (idempotent
//!   upsert), and the registry writes are plain replacements.
//! - **PostgreSQL** (`new_postgres`, `register_postgres`): pooled durable estate
//!   at a libpq connection string. Pool defaults match the Swift leg (size=10,
//!   connect_timeout=5.0s, idle_timeout=300.0s). **Semantic recall lanes are
//!   wired** after `coord.open` using the same `PostgresStorage` handle as the
//!   DrawerStore (shared lazy connection pool, same PG schema). Schema migrations
//!   are idempotent; construction does not open a TCP connection.
//!
//! Persistence is server-internal — no wire change; the JSON-RPC surface is
//! identical for all three backends. The host resolves its estate from the
//! estate catalog and passes it in as a `server::RuntimeEstate`; nothing here
//! reads an estate path, a connection string or a backend from the
//! environment. See `server::ServerConfig::for_estate`.

use std::collections::HashMap;
use std::sync::Arc;

// The default recall ensemble (RI then LSA).
// Lives in the providers
// crate because it NEWs the concrete providers; this crate is downstream of it.
use corpus_kit_providers::default_ensemble;
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
// Re-exported for downstream binaries (mootx01's `drain` command) that consume
// `EstateCoordinator::drain_statuses` through this registry but do not depend
// on genius_locus_kit directly. Gives them the type name for the T5 finisher
// gate `DrainStatus::encode_settled` (PERF_W1_DRAIN_RIDER Finding 3).
pub use genius_locus_kit::DrainStatus;
use genius_locus_kit_migrations::run_geometry_normalization;
use genius_locus_kit_migrations::MigrationChainExt;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_postgres::PostgresDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::postgres::PostgresStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
use persistence_kit::storage::Storage;
use uuid::Uuid;

// Compile-time constant for the default estate owner identifier — stable
// across runs so log messages identify the server's own estate clearly.
const DEFAULT_OWNER: &str = "aria-mcp-default";

// Arbitrary wall-clock anchor for the in-memory estate. In-memory estates
// are ephemeral and discarded when the server exits; using a fixed value
// keeps test behavior deterministic.
const INIT_NOW: i64 = 1_700_000_000_000;

// Default busy-timeout for SQLite estates: 5.0 seconds. Single-process
// server model means concurrent writers are unlikely, but the timeout
// prevents instant failure if a background tool call and the startup
// open race on the same file.
const SQLITE_BUSY_TIMEOUT_SECS: f64 = 5.0;

/// An opened estate in the registry: coordinator + handle + store triple.
///
/// The coordinator is the dispatch surface; the handle identifies which
/// estate within the coordinator to target for a given tool call. The store
/// is the same `Arc<dyn DrawerStore>` that was passed to `coord.open(...)` —
/// retained here so the AutonomicGovernor can construct its sinks against the
/// live estate without needing the coordinator lock for write access.
#[derive(Clone)]
pub struct OpenEstate {
    /// Shared coordinator — all estates registered on the same server
    /// share one coordinator so they can be cross-addressed by the
    /// federated lenses.
    pub coord: Arc<std::sync::Mutex<EstateCoordinator>>,
    pub handle: EstateHandle,
    pub estate_id: Uuid,
    /// Human-readable estate name. Defaults to the UUID string when no
    /// name is provided (mirrors Swift's `EstateHandle.estateName`).
    pub estate_name: String,
    /// The live DrawerStore backing this estate. The same Arc is held by
    /// the coordinator internally; this clone lets callers (e.g. AutonomicGovernor)
    /// write proposals/diary entries directly without routing through the
    /// coordinator's MCP verb layer.
    pub store: Arc<dyn DrawerStore>,
    /// The backend THIS estate was opened on. Per entry, not per registry: a
    /// registry whose default is SQLite can carry a PostgreSQL or in-memory
    /// extra (`register_postgres`, `register_inmemory`), and
    /// `/api/admin/estates` must report each one for what it is. Twin of the
    /// Swift admin snapshot reading `kit.storageBackend(for: handle)` inside
    /// its per-handle loop.
    pub backend: EstateStorageBackend,
}

/// The estate registry the dispatcher uses to resolve `estateID` arguments.
///
/// One default estate; zero or more additional estates keyed by UUID.
/// Which persistence backend the registry's default estate runs on, as the
/// admin surface reports it. Twin of Swift `GeniusLocusKit.storageBackend(for:)`
/// (`EstateStorageBackend`): the same three words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateStorageBackend {
    Sqlite,
    Postgresql,
    InMemory,
}

impl EstateStorageBackend {
    /// The label `/api/admin/estates` reports.
    pub fn label(self) -> &'static str {
        match self {
            EstateStorageBackend::Sqlite => "SQLite",
            EstateStorageBackend::Postgresql => "PostgreSQL",
            EstateStorageBackend::InMemory => "InMemory",
        }
    }
}

/// The default estate is in-memory, SQLite-backed, or PostgreSQL-backed
/// depending on the `RuntimeEstate` the host resolved from the estate catalog
/// (`ServerConfig::for_estate`). Wire surface is identical for all three
/// backends.
#[derive(Clone)]
pub struct EstateRegistry {
    /// The default estate — targeted when a tool call omits `estateID`.
    pub default: OpenEstate,
    /// The backend the default estate runs on; a fact of the open, never
    /// read from the environment.
    pub backend: EstateStorageBackend,
    /// All registered estates including the default, keyed by UUID.
    pub(crate) extras: HashMap<Uuid, OpenEstate>,
    /// The shared coordinator (same Arc as in every OpenEstate — single
    /// coordinator for all estates so the federated lenses can cross-address).
    pub coord: Arc<std::sync::Mutex<EstateCoordinator>>,
    /// The host identity written into rows filed by this server (memories,
    /// tunnels, facts). Set to "mootx01" by all constructors; the
    /// production entry point (`runtime::run`) overrides it with the banner
    /// so the shared dispatcher stamps the correct provenance for whichever
    /// binary is hosting it. Mirrors Swift `ToolDispatcher.serverIdentity`.
    pub server_identity: String,
}

/// How an estate is opened: the choices the estate's catalog record decides.
/// Twin of the Swift `ServeCommand` decisions taken from `EstateRecord.kind`:
/// a registered estate federates and seeds its charters; a transient one does
/// neither; a maintenance open (`mootx01 upgrade`) converges what exists and
/// creates nothing.
///
/// Every backend constructor takes one — SQLite, in-memory and PostgreSQL —
/// so federation and charter seeding are decided by the record, never by the
/// backend. The `Sqlite` in the name records where the type entered the
/// codebase, not the set of backends it governs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EstateOpening {
    /// Whether this open establishes the estate's Ed25519 federation identity.
    pub federate: bool,
    /// Whether the seven default wings and their charter hints are seeded.
    pub seed_charters: bool,
}

impl EstateOpening {
    /// A registered estate served by this machine: federates, seeds charters.
    pub const REGISTERED: Self = Self { federate: true, seed_charters: true };
    /// A transient estate (`--db <dir>/<name>`): holds exactly what was
    /// imported into it, no identity, no charters.
    pub const TRANSIENT: Self = Self { federate: false, seed_charters: false };
    /// A maintenance open: converges existing content and creates none.
    pub const MAINTENANCE: Self = Self { federate: false, seed_charters: false };

    /// The opening a catalog record calls for when served.
    pub fn for_record(record: &genius_locus_kit::EstateRecord) -> Self {
        match record.kind {
            genius_locus_kit::EstateRecordKind::Registered => Self::REGISTERED,
            genius_locus_kit::EstateRecordKind::Transient => Self::TRANSIENT,
        }
    }
}

impl EstateRegistry {
    /// Construct a registry with one new in-memory default estate: charters
    /// seeded, no federation.
    ///
    /// The test and development default, and the two halves have different
    /// reasons. Charters are seeded because a test estate should look like a
    /// served one, with the seven default wings in place. Federation is off
    /// because it mints the estate's Ed25519 identity into a manifest that
    /// dies with the process, leaving no identity for a peer to address
    /// later; every caller of this constructor took that posture before the
    /// opening argument existed, and none of them issues a grant.
    ///
    /// The product's `--in-memory` never arrives here. It calls
    /// `new_inmemory_with(EstateOpening::TRANSIENT)`, so a RAM benchmark arm
    /// measures a candidate pool with no charter drawers in it (R8,
    /// 2026-09-08).
    pub fn new_inmemory() -> Self {
        Self::new_inmemory_with(EstateOpening { federate: false, seed_charters: true })
    }

    /// Construct a registry with one new in-memory default estate under the
    /// opening the caller's catalog record decides.
    ///
    /// **Semantic recall lanes (BM25 + vector) are wired** — a `Corpus` and
    /// a `VectorStore` are registered on a second `InMemoryStorage` handle so BM25
    /// and vector recall are live from the first capture, matching the production
    /// wiring of the Swift `AriaMCPMain.swift` in-memory branch.
    ///
    /// Two `InMemoryStorage` handles are used: one inside `InMemoryDrawerStore`
    /// (the LocusKit tables — drawers, tunnels, kg_facts, audit log) and one
    /// allocated here for the Corpus + VectorStore tables (chunks, vectors). Both
    /// handles are `Arc<dyn Storage>` over separate `InMemoryStorage` allocations;
    /// they are disjoint table namespaces and do not interfere with each other.
    /// This is the in-memory equivalent of the SQLite two-handle pattern.
    pub fn new_inmemory_with(opening: EstateOpening) -> Self {
        let coord = Arc::new(std::sync::Mutex::new(EstateCoordinator::new()));
        let estate_id = Uuid::new_v4();
        // InMemoryDrawerStore::new allocates its own InMemoryStorage internally;
        // backend identity is visible at the type, not the argument.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(INIT_NOW, None).unwrap());
        let handle = coord
            .lock()
            .unwrap()
            .open_with_federation(
                Arc::clone(&store), OwnerCredentials::new(DEFAULT_OWNER), 0, 100, opening.federate)
            .expect("default estate open must succeed");
        // A fresh in-memory estate is born with the span encoder as its default
        // recall stage; written before wiring so this open activates it.
        coord
            .lock()
            .unwrap()
            .provision_default_encoder_if_absent(&handle)
            .expect("default encoder provisioning must succeed on a fresh in-memory estate");
        // Wire semantic recall lanes on a second InMemoryStorage handle.
        // Panics on corpus/vector-store construction failure — this must not
        // fail in a correct build; the InMemory backend never returns I/O errors.
        wire_inmemory_semantic_recall(&handle, &coord)
            .expect("in-memory semantic recall wiring must succeed");
        if opening.seed_charters {
            // Idempotently seed the seven default wings. Non-fatal: seeding
            // failure logs and continues — the estate is open and functional.
            // Mirrors Swift ServeCommand's seedDefaultWings call, which runs for
            // a registered estate only: a transient estate — and `--in-memory`
            // always serves one (R8, 2026-09-08) — holds exactly what was
            // imported into it, so a RAM benchmark arm measures a pool with no
            // charter drawers in it.
            seed_wings_non_fatal(&coord, &handle, "in-memory");
        }
        let default_estate = OpenEstate {
            coord: Arc::clone(&coord),
            handle,
            estate_name: estate_id.to_string(),
            estate_id,
            store,
            backend: EstateStorageBackend::InMemory,
        };
        let mut extras = HashMap::new();
        extras.insert(estate_id, default_estate.clone());
        EstateRegistry {
            default: default_estate,
            backend: EstateStorageBackend::InMemory,
            extras,
            coord,
            // Default identity; production entry point overrides via server_identity.
            server_identity: "mootx01".to_owned(),
        }
    }

    /// Construct a registry with one in-memory estate and NO corpus or vector
    /// store registered — the dense recall lane is intentionally dark.
    ///
    /// Use this in tests that need to verify dark-lane behaviour (e.g. the
    /// `recall_provenance:` hint in `moot_fact_search` when no semantic index
    /// is present). For tests that require semantic recall to be live, use
    /// `new_inmemory()` instead.
    ///
    /// Also used to verify that `server_identity` overrides take effect: the
    /// field is `pub`, so callers can set `registry.server_identity =
    /// "mootx01".to_owned()` after construction.
    pub fn new_inmemory_bare() -> Self {
        let coord = Arc::new(std::sync::Mutex::new(EstateCoordinator::new()));
        let estate_id = Uuid::new_v4();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(INIT_NOW, None).unwrap());
        let handle = coord
            .lock()
            .unwrap()
            .open(Arc::clone(&store), OwnerCredentials::new(DEFAULT_OWNER), 0, 100)
            .expect("default bare estate open must succeed");
        // Intentionally skip wire_inmemory_semantic_recall — dense lane is dark.
        let default_estate = OpenEstate {
            coord: Arc::clone(&coord),
            handle,
            estate_name: estate_id.to_string(),
            estate_id,
            store,
            backend: EstateStorageBackend::InMemory,
        };
        let mut extras = HashMap::new();
        extras.insert(estate_id, default_estate.clone());
        EstateRegistry {
            default: default_estate,
            backend: EstateStorageBackend::InMemory,
            extras,
            coord,
            server_identity: "mootx01".to_owned(),
        }
    }

    /// Construct a registry with one SQLite-backed default estate at `path`.
    ///
    /// The database file is created if absent. Parent directories must exist
    /// (the caller — typically `ServerConfig::from_env` — creates them before
    /// calling here). Opens with WAL mode and a 5-second busy timeout so
    /// concurrent tool calls on the same estate serialize without instant
    /// failure.
    ///
    /// **Semantic recall lanes are wired** after `coord.open`: a `Corpus` and a
    /// `VectorStore` are constructed on a second `SqliteStorage` handle pointing
    /// at the same WAL-mode database file and registered with the coordinator.
    /// This mirrors the Swift `AriaMCPMain.swift` `wireSemanticRecall` branch:
    /// `Corpus(storage: .deterministic)` + `VectorStore(storage:)` +
    /// `kit.registerCorpus(_:for:)` + `kit.registerVectorStore(_:for:)`.
    /// Idempotent across restarts: both constructors run schema migrations via
    /// the backend's `migrate` (idempotent upsert), so re-opening an existing
    /// database re-registers against already-migrated tables without data loss.
    ///
    /// The encode queue is NOT mounted here — the mode-aware `capture` verb
    /// (`capture_with_mode`) mounts it on demand on the first regular write, and
    /// impatient writes ingest inline into the Corpus. This matches the Swift
    /// ARIA_MCP wiring comment: "The encode queue is NOT mounted here."
    ///
    /// `owner` identifies the estate in log messages and audit records; use
    /// `DEFAULT_OWNER` (`"aria-mcp-default"`) for the production default estate.
    ///
    /// # Errors
    ///
    /// Returns `Err(String)` with a human-readable message if `SqliteDrawerStore`
    /// cannot open the path (bad path, permission denied, corrupt database), or
    /// if the semantic-recall wiring (Corpus/VectorStore construction) fails.
    /// The caller should print this to stderr and exit with a nonzero code.
    pub fn new_sqlite(path: &str, owner: &str) -> Result<Self, String> {
        Self::open_sqlite(path, owner, EstateOpening::REGISTERED, false)
    }

    /// Open a SQLite estate with the opening its catalog record decides
    /// (`EstateOpening::for_record`): federation and charter seeding for a
    /// registered estate, neither for a transient one.
    pub fn new_sqlite_with(path: &str, owner: &str, opening: EstateOpening) -> Result<Self, String> {
        Self::open_sqlite(path, owner, opening, false)
    }

    /// Open a SQLite estate for maintenance callers (e.g. `mootx01 upgrade`).
    ///
    /// Same open path as `new_sqlite` except that **default-wing seeding and default-minter
    /// registration are skipped**. Upgrade is a migration vehicle: it converges what
    /// already exists and must never create content. If a user deleted their default
    /// wings, a maintenance open must not silently recreate them.
    ///
    /// Mirrors the shape of the Swift upgrade steps, which open through the bare
    /// `GeniusLocusKit.open(storage:owner:)` path (no `seedDefaultWings` call).
    ///
    /// Semantic recall lanes (BM25 + vector) are still wired so corpus operations
    /// (`reindex_corpus`, the span-encode backfill) work correctly.
    ///
    /// # Errors
    ///
    /// Same error conditions as `new_sqlite`.
    pub fn new_sqlite_for_maintenance(path: &str, owner: &str) -> Result<Self, String> {
        Self::open_sqlite(path, owner, EstateOpening::MAINTENANCE, true)
    }

    /// Shared SQLite open path behind `new_sqlite` and `new_sqlite_for_maintenance`.
    /// The public entry points differ only in `opening`; everything else
    /// (geometry normalization, store open, estate-id read-back, coordinator
    /// admission, semantic-recall wiring) is one implementation so the ports
    /// cannot drift between the serve and upgrade opens.
    fn open_sqlite(path: &str, owner: &str, opening: EstateOpening, offline_upgrade: bool) -> Result<Self, String> {
        // First run = no estate file before this open. Read before anything
        // below can create the file; it gates the create-time defaults.
        let first_run = !std::path::Path::new(path).exists();
        let frozen = crate::estate_posture::EstatePosture::from_process_environment().is_frozen();
        // This startup policy belongs to the selected v2 surface — the only
        // surface a running server opens through; there are no v1 opens.
        let preserve_v2_frozen_configuration = frozen;
        if frozen && first_run {
            return Err("frozen SQLite open requires an existing estate".to_string());
        }
        let coord = Arc::new(std::sync::Mutex::new(EstateCoordinator::new()));
        // Production model-directory resolver, installed before `coord.open`
        // and the semantic-recall wiring below: the wiring acts on the
        // manifest's `embedding_provider = "encoder"` by building the span
        // encoder from the active registry row, and it can only find the
        // bundled model through this resolver (the coordinator's default
        // answers None for every id, which leaves recall lexical-only).
        // Install-wide models live in the configuration directory, whichever
        // estate is opened; the estate's own directory holds only estate files.
        coord.lock().unwrap().set_model_directory_resolver(Box::new(
            genius_locus_kit::BundledModelDirectoryResolver::new(
                genius_locus_kit::EstateCatalog::configuration_directory(),
            ),
        ));
        // Geometry normalization must precede the estate connection so VACUUM and
        // all maintenance paths receive a reserve-0 file. SQLCipher's `attachFunc`
        // calls `sqlcipherCodecAttach(nKey=0)` for any keyless ATTACH when the main
        // database has nonzero reserved-bytes-per-page (file header byte 20 ≠ 0),
        // failing with SQLITE_ERROR. Running normalization here — before
        // `SqliteDrawerStore::from_path` opens its connection — ensures the
        // connection is always opened on the canonical normalized path; no stale fd
        // survives the atomic rename. Errors are parked so a geometry failure never
        // blocks the estate from opening (VACUUM will surface the issue later).
        if !frozen {
            if let Err(e) = run_geometry_normalization(std::path::Path::new(path)) {
                eprintln!(
                    "aria-mcp: geometry normalization for estate at {path:?}: {e} (parked; VACUUM will surface this)"
                );
            }
        }
        let store: Arc<dyn DrawerStore> = Arc::new(
            SqliteDrawerStore::from_path(path, INIT_NOW, None, SQLITE_BUSY_TIMEOUT_SECS)
                .map_err(|e| format!("aria-mcp: cannot open SQLite estate at {path:?}: {e}"))?,
        );
        // The estate_id is minted inside SqliteDrawerStore::from_path and stored
        // in the manifest as a UUID string. We read it back and parse it so our
        // registry UUID matches what the store considers canonical across restarts.
        let estate_id = {
            let manifest = store
                .read_manifest()
                .map_err(|e| format!("aria-mcp: cannot read estate manifest from {path:?}: {e}"))?;
            Uuid::parse_str(&manifest.estate_uuid).map_err(|e| {
                format!("aria-mcp: manifest estate_uuid is not a valid UUID at {path:?}: {e}")
            })?
        };
        // A registered estate federates (its identity is minted on first open);
        // a transient or maintenance open never mints one.
        let handle = coord
            .lock()
            .unwrap()
            .open_with_policy(Arc::clone(&store), OwnerCredentials::new(owner), 0, 100, opening.federate, frozen)
            .map_err(|e| format!("aria-mcp: cannot open SQLite estate at {path:?}: {e:?}"))?;

        // Semantic recall wiring (SQLite branch only — mirrors AriaMCPMain.swift).
        //
        // `coord.open` admits the estate and issues the handle, but it does NOT
        // register a Corpus or VectorStore — so on a bare open the BM25 + vector
        // recall lanes are DARK and `moot_memory_search` degrades to LocusKit
        // row recall. We mirror exactly what the Swift ARIA_MCP does after open:
        // build a Corpus (BM25 + internal vectors) and a VectorStore, both using
        // the SAME already-open, already-keyed storage connection as the DrawerStore.
        //
        // Sharing one storage instance (rather than opening a second SqliteStorage
        // handle) ensures the encryption key is already applied — the DrawerStore's
        // SqliteStorage received PRAGMA key at construction. A second independent
        // handle opening the same encrypted WAL-mode file must also call PRAGMA key;
        // on Windows ARM the SQLCipher build did not reliably propagate the key to
        // a second connection, producing NOTADB on storage.migrate() in Corpus::open_many.
        // Sharing the DrawerStore's storage eliminates the second connection entirely,
        // matching the Swift pattern and closing the platform-specific bug.
        //
        // Table namespaces remain disjoint: LocusKit owns drawers/tunnels/kg_facts;
        // CorpusKit/SynapseKit own chunks/vectors. WAL serialises all writes through
        // the single shared connection handle.
        //
        // Embedding model: Deterministic — reproducible across Swift/Rust ports,
        // no CoreML required. Matches the Swift leg's `model: .deterministic`.
        let shared_storage = store.storage().ok_or_else(|| {
            format!("aria-mcp: SqliteDrawerStore at {path:?} did not expose its backing Storage — cannot wire semantic recall")
        })?;
        // A fresh SQLite estate (no file before this open) is born with the span
        // encoder as its default recall stage; written before wiring so this
        // open activates it. Existing estates get the key from `mootx01
        // upgrade`, never from a serve open. Swift twin: ServeCommand isFirstRun.
        if first_run {
            coord
                .lock()
                .unwrap()
                .provision_default_encoder_if_absent(&handle)
                .map_err(|e| format!("aria-mcp: default encoder provisioning failed for {path:?}: {e:?}"))?;
        }
        wire_sqlite_semantic_recall(path, shared_storage, &handle, &coord, preserve_v2_frozen_configuration, offline_upgrade)
            .map_err(|e| format!("aria-mcp: cannot wire semantic recall for {path:?}: {e}"))?;
        if opening.seed_charters && !frozen {
            // Idempotently seed the seven default wings. Non-fatal: seeding
            // failure logs and continues — the estate is open and functional.
            // Mirrors Swift ServeCommand's seedDefaultWings call after
            // wireGLKSubstores, which runs for a registered estate only: a
            // transient estate holds exactly what was imported into it, and a
            // maintenance open (`mootx01 upgrade`) creates nothing.
            seed_wings_non_fatal(&coord, &handle, path);
        }

        let default_estate = OpenEstate {
            coord: Arc::clone(&coord),
            handle,
            estate_name: estate_id.to_string(),
            estate_id,
            store,
            backend: EstateStorageBackend::Sqlite,
        };
        let mut extras = HashMap::new();
        extras.insert(estate_id, default_estate.clone());
        Ok(EstateRegistry {
            default: default_estate,
            backend: EstateStorageBackend::Sqlite,
            extras,
            coord,
            // Default identity; production entry point overrides via server_identity.
            server_identity: "mootx01".to_owned(),
        })
    }

    /// Register an additional in-memory estate. Returns its UUID.
    ///
    /// **Semantic recall lanes (BM25 + vector) are wired** — same policy as
    /// `new_inmemory`. Used by the `moot_open_estate` test seam and integration tests.
    pub fn register_inmemory(&mut self, owner: &str) -> Uuid {
        let estate_id = Uuid::new_v4();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(INIT_NOW, None).unwrap());
        let handle = self
            .coord
            .lock()
            .unwrap()
            .open(Arc::clone(&store), OwnerCredentials::new(owner), 0, 100)
            .expect("additional estate open must succeed");
        // Wire semantic recall on a second InMemoryStorage handle — same policy as new_inmemory.
        wire_inmemory_semantic_recall(&handle, &self.coord)
            .expect("in-memory semantic recall wiring must succeed");
        let estate = OpenEstate {
            coord: Arc::clone(&self.coord),
            handle,
            estate_name: estate_id.to_string(),
            estate_id,
            store,
            backend: EstateStorageBackend::InMemory,
        };
        self.extras.insert(estate_id, estate);
        estate_id
    }

    /// Register an additional SQLite-backed estate at `path`. Returns its UUID.
    ///
    /// Same open semantics as `new_sqlite`: WAL mode, 5-second busy timeout,
    /// database created if absent. **Semantic recall lanes (BM25 + vector) are
    /// wired** — same as `new_sqlite`. Returns `Err(String)` on open failure or
    /// if semantic-recall wiring fails.
    pub fn register_sqlite(&mut self, path: &str, owner: &str) -> Result<Uuid, String> {
        // Same normalization-before-connection contract as `new_sqlite` — see that
        // function's comment for the full rationale. Errors parked identically.
        if let Err(e) = run_geometry_normalization(std::path::Path::new(path)) {
            eprintln!(
                "aria-mcp: geometry normalization for estate at {path:?}: {e} (parked; VACUUM will surface this)"
            );
        }
        let store: Arc<dyn DrawerStore> = Arc::new(
            SqliteDrawerStore::from_path(path, INIT_NOW, None, SQLITE_BUSY_TIMEOUT_SECS)
                .map_err(|e| format!("aria-mcp: cannot open SQLite estate at {path:?}: {e}"))?,
        );
        let estate_id = {
            let manifest = store
                .read_manifest()
                .map_err(|e| format!("aria-mcp: cannot read estate manifest from {path:?}: {e}"))?;
            Uuid::parse_str(&manifest.estate_uuid).map_err(|e| {
                format!("aria-mcp: manifest estate_uuid is not a valid UUID at {path:?}: {e}")
            })?
        };
        let handle = self
            .coord
            .lock()
            .unwrap()
            .open(Arc::clone(&store), OwnerCredentials::new(owner), 0, 100)
            .expect("additional sqlite estate open must succeed");
        // Wire semantic recall lanes — same policy as new_sqlite:
        // share the DrawerStore's already-keyed storage rather than opening
        // a second independent SqliteStorage handle on the encrypted estate.
        let shared_storage = store.storage().ok_or_else(|| {
            format!("aria-mcp: SqliteDrawerStore at {path:?} did not expose its backing Storage — cannot wire semantic recall")
        })?;
        let preserve_v2_frozen_configuration =
            crate::estate_posture::EstatePosture::from_process_environment().is_frozen();
        wire_sqlite_semantic_recall(path, shared_storage, &handle, &self.coord, preserve_v2_frozen_configuration, false)
            .map_err(|e| format!("aria-mcp: cannot wire semantic recall for {path:?}: {e}"))?;
        let estate = OpenEstate {
            coord: Arc::clone(&self.coord),
            handle,
            estate_name: estate_id.to_string(),
            estate_id,
            store,
            backend: EstateStorageBackend::Sqlite,
        };
        self.extras.insert(estate_id, estate);
        Ok(estate_id)
    }

    /// Construct a registry with one PostgreSQL-backed default estate at `conn_str`.
    ///
    /// `conn_str` must be a libpq-compatible connection string (e.g.
    /// `"postgresql://user:pass@host/db"`). The pool is lazy — connections are
    /// acquired on first use; construction succeeds even when the database is
    /// temporarily unreachable.
    ///
    /// Pool defaults match the Swift leg: `pool_size=10`,
    /// `connection_timeout_secs=5.0`, `idle_timeout_secs=300.0`.
    ///
    /// **Semantic recall lanes (BM25 + vector) are wired** after `coord.open` by
    /// building a `PostgresStorage` on the same connection string and registering
    /// a `Corpus` and `VectorStore` with the coordinator. The `PostgresStorage`
    /// handle uses the same lazy connection pool defaults. Schema migrations are
    /// idempotent; construction does not open a TCP connection — the pool is lazy.
    ///
    /// `owner` identifies the estate in log messages and audit records; use
    /// `DEFAULT_OWNER` (`"aria-mcp-default"`) for the production default estate.
    ///
    /// # Errors
    ///
    /// Returns `Err(String)` with a human-readable message if
    /// `PostgresDrawerStore` construction fails (malformed connection string,
    /// etc.) or if semantic-recall wiring fails. The pool itself is lazy; actual
    /// connection errors surface on first use, not here.
    pub fn new_postgres(conn_str: &str, owner: &str) -> Result<Self, String> {
        // Charters seeded, no federation — the posture every caller of this
        // constructor took before the opening argument existed. A host that
        // knows its catalog record calls `new_postgres_with` instead.
        Self::new_postgres_with(conn_str, owner, EstateOpening { federate: false, seed_charters: true })
    }

    /// Open a PostgreSQL estate with the opening its catalog record decides
    /// (`EstateOpening::for_record`): charter seeding for a registered estate,
    /// none for a transient one. Twin of `new_sqlite_with`.
    pub fn new_postgres_with(
        conn_str: &str,
        owner: &str,
        opening: EstateOpening,
    ) -> Result<Self, String> {
        let coord = Arc::new(std::sync::Mutex::new(EstateCoordinator::new()));
        let store: Arc<dyn DrawerStore> = Arc::new(
            PostgresDrawerStore::from_connection_string(conn_str, INIT_NOW, None).map_err(|e| {
                format!("aria-mcp: cannot open PostgreSQL estate at {conn_str:?}: {e}")
            })?,
        );
        // PostgresStorage does not store an estate_uuid in a manifest the same
        // way SQLite does. We mint a new UUID for this registry session; the
        // manifest uuid is reconciled by DrawerStoreCore on first write.
        let estate_id = {
            let manifest = store
                .read_manifest()
                .map_err(|e| format!("aria-mcp: cannot read estate manifest from postgres: {e}"))?;
            uuid::Uuid::parse_str(&manifest.estate_uuid).map_err(|e| {
                format!("aria-mcp: manifest estate_uuid is not a valid UUID (postgres): {e}")
            })?
        };
        let handle = coord
            .lock()
            .unwrap()
            .open_with_federation(
                Arc::clone(&store), OwnerCredentials::new(owner), 0, 100, opening.federate)
            .expect("default postgres estate open must succeed");
        // This entry point creates on every open (there is no first-run signal
        // for a connection string), so the create-time default belongs here:
        // the span encoder becomes the recall stage of an estate that names no
        // provider; an estate that already names one is left alone.
        coord
            .lock()
            .unwrap()
            .provision_default_encoder_if_absent(&handle)
            .map_err(|e| format!("aria-mcp: default encoder provisioning failed (postgres): {e:?}"))?;
        // Wire semantic recall lanes — same policy as new_sqlite.
        // Uses a separate PostgresStorage handle on the same connection string.
        wire_postgres_semantic_recall(conn_str, &handle, &coord)
            .map_err(|e| format!("aria-mcp: cannot wire semantic recall for postgres: {e}"))?;
        if opening.seed_charters {
            // Idempotently seed the seven default wings. Non-fatal: seeding
            // failure logs and continues — the estate is open and functional.
            // Same gate as the SQLite and in-memory constructors: the record's
            // kind decides charters, never the backend.
            seed_wings_non_fatal(&coord, &handle, "postgres");
        }
        let default_estate = OpenEstate {
            coord: Arc::clone(&coord),
            handle,
            estate_name: estate_id.to_string(),
            estate_id,
            store,
            backend: EstateStorageBackend::Postgresql,
        };
        let mut extras = HashMap::new();
        extras.insert(estate_id, default_estate.clone());
        Ok(EstateRegistry {
            default: default_estate,
            backend: EstateStorageBackend::Postgresql,
            extras,
            coord,
            // Default identity; production entry point overrides via server_identity.
            server_identity: "mootx01".to_owned(),
        })
    }

    /// Register an additional PostgreSQL-backed estate at `conn_str`.
    /// Returns the estate's UUID.
    ///
    /// Same pool semantics as `new_postgres`: lazy connections, Swift-parity
    /// defaults. **Semantic recall lanes are wired** — same policy as `new_postgres`.
    /// Returns `Err(String)` on construction failure or semantic-recall wiring failure.
    pub fn register_postgres(&mut self, conn_str: &str, owner: &str) -> Result<Uuid, String> {
        let store: Arc<dyn DrawerStore> = Arc::new(
            PostgresDrawerStore::from_connection_string(conn_str, INIT_NOW, None).map_err(|e| {
                format!("aria-mcp: cannot open PostgreSQL estate at {conn_str:?}: {e}")
            })?,
        );
        let estate_id = {
            let manifest = store
                .read_manifest()
                .map_err(|e| format!("aria-mcp: cannot read estate manifest from postgres: {e}"))?;
            Uuid::parse_str(&manifest.estate_uuid).map_err(|e| {
                format!("aria-mcp: manifest estate_uuid is not a valid UUID (postgres): {e}")
            })?
        };
        let handle = self
            .coord
            .lock()
            .unwrap()
            .open(Arc::clone(&store), OwnerCredentials::new(owner), 0, 100)
            .expect("additional postgres estate open must succeed");
        // Wire semantic recall lanes — same policy as new_postgres.
        wire_postgres_semantic_recall(conn_str, &handle, &self.coord)
            .map_err(|e| format!("aria-mcp: cannot wire semantic recall for postgres: {e}"))?;
        let estate = OpenEstate {
            coord: Arc::clone(&self.coord),
            handle,
            estate_name: estate_id.to_string(),
            estate_id,
            store,
            backend: EstateStorageBackend::Postgresql,
        };
        self.extras.insert(estate_id, estate);
        Ok(estate_id)
    }

    /// Return the store-manifest UUID (`EstateHandle.estate_uuid` as `uuid::Uuid`)
    /// for the registered estate keyed by `estate_id`. Returns `None` if the
    /// `estate_id` is not registered.
    ///
    /// This UUID is what the grant system uses for `grantee_estate_id`, and what
    /// `moot_federated_search` accepts as `requesterEstateID`. Tests that need to
    /// issue grants or call federated tools call this to bridge between the
    /// registry's estate_id key and the coordinator's handle UUID.
    pub fn handle_uuid_for(&self, estate_id: Uuid) -> Option<Uuid> {
        self.extras.get(&estate_id).map(|oe| Uuid::from_bytes(oe.handle.estate_uuid))
    }

    /// Resolve the estate targeted by a tool call's `estateID` argument.
    ///
    /// Absent `estateID` → default estate (preserves single-estate v1.0
    /// behavior). Present but malformed (not a UUID) → invalidParams.
    /// Present but unknown (UUID not registered) → invalidParams.
    /// Matches Swift `ToolDispatcher.resolveHandle(_:)` exactly.
    ///
    /// This method is unrestricted — it allows targeting any registered estate.
    /// Use `resolve_direct` for tool dispatch where the caller may only target
    /// the default estate.
    pub fn resolve(
        &self,
        args: &std::collections::BTreeMap<String, crate::jsonrpc::JsonValue>,
        key: &str,
    ) -> Result<&OpenEstate, crate::jsonrpc::JSONRPCError> {
        use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
        let raw = match args.get(key) {
            None => return Ok(&self.default),
            Some(JsonValue::String(s)) => s.to_owned(),
            Some(_) => {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!("{key} must be a UUID string; omit it to use the default estate"),
                ))
            }
        };
        let uuid = Uuid::parse_str(&raw).map_err(|_| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("Malformed {key} (not a UUID): {raw}"),
            )
        })?;
        self.extras.get(&uuid).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("Unknown {key}: {raw}"),
            )
        })
    }

    /// Resolve the estate targeted by a tool call's `estateID` argument,
    /// restricted to the default estate only.
    ///
    /// Security gate for Item 3 (secfix/batch2-aria): direct MCP tool calls
    /// may only target the default estate. Additional registered estates are
    /// addressable through `moot_federated_search`, which enforces active,
    /// unexpired, scope-narrowing grants before any cross-estate read or write.
    /// Allowing `estateID` to target any registered estate would bypass that
    /// grant gate. Mirrors Swift `ToolDispatcher.resolveHandle(_:)`.
    ///
    /// - Absent `estateID` → default estate (single-estate v1.0 path).
    /// - Present, malformed (not a UUID) → invalidParams.
    /// - Present, valid UUID, unknown (not registered) → invalidParams.
    /// - Present, valid UUID, registered but NOT the default → invalidParams
    ///   (security refusal).
    /// - Present, valid UUID, matches the default → returns the default estate.
    pub fn resolve_direct(
        &self,
        args: &std::collections::BTreeMap<String, crate::jsonrpc::JsonValue>,
    ) -> Result<&OpenEstate, crate::jsonrpc::JSONRPCError> {
        use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
        let raw = match args.get("estateID") {
            None => return Ok(&self.default),
            Some(JsonValue::String(s)) => s.to_owned(),
            Some(_) => {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "estateID must be a UUID string; omit it to use the default estate"
                        .to_string(),
                ))
            }
        };
        let uuid = Uuid::parse_str(&raw).map_err(|_| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("Malformed estateID (not a UUID): {raw}"),
            )
        })?;
        // Verify the UUID is registered at all before the default check, so that
        // both unknown and non-default UUIDs produce a meaningful error.
        if !self.extras.contains_key(&uuid) && uuid != self.default.estate_id {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("Unknown estateID: {raw}"),
            ));
        }
        if uuid != self.default.estate_id {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "Direct estateID routing is limited to the default estate; \
                 use moot_federated_search for grant-authorized cross-estate reads."
                    .to_string(),
            ));
        }
        Ok(&self.default)
    }
}

// ---------------------------------------------------------------------------
// Default wing seeding helper
// ---------------------------------------------------------------------------

/// Idempotently seed the seven default wings for `handle`.
///
/// Reads existing `AI_Charter_Hint` drawers and skips wings that are already
/// present — safe to call on re-opens of an existing estate. Failure is
/// non-fatal: a warning is printed to stderr and the caller continues.
/// This matches the Swift `ServeCommand` seeding policy (error.log + continue).
///
/// `estate_label` is a short description for the warning message (e.g. the
/// SQLite path, "in-memory", or "postgres") — it does not affect behaviour.
fn seed_wings_non_fatal(
    coord: &Arc<std::sync::Mutex<EstateCoordinator>>,
    handle: &EstateHandle,
    estate_label: &str,
) {
    // Epoch MILLISECONDS — the unit the store and HLC boundary consume
    // (`hlc.rs::send`, `sqlite.rs` timestamp codec). Supplying seconds here
    // backdates every seeded hint drawer to 1970 and corrupts audit ordering.
    let seed_now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(INIT_NOW);
    if let Err(e) = coord.lock().unwrap().seed_default_wings(handle, seed_now) {
        eprintln!(
            "aria-mcp: default wing seeding failed for {estate_label}: {e:?} — continuing"
        );
    }
}

// ---------------------------------------------------------------------------
// Semantic recall wiring — one seam per backend, one wire body in GLK
// ---------------------------------------------------------------------------
// Every served estate gets its Corpus (attached-mode CorpusContentEngine over
// the LocusKit-backed adapter), the engine's shared dense VectorStore, the
// on_encoded encode rider, the provisioned embedding-provider activation and
// the eagerly mounted ingest queue from ONE place:
// `EstateCoordinator::wire_glk_substores` (GeniusLocusKit coordinator.rs), the
// twin of Swift `GeniusLocusKit.wireGLKSubstores`, which Swift's serve, upgrade,
// drain and dream commands all call. The helpers below own only what differs
// per backend before that call: which `Storage` carries the sub-store tables,
// and whether the migration chain must prepare a durable estate first.
// ---------------------------------------------------------------------------

/// Wire the semantic recall lanes for an in-memory estate.
///
/// Called by `new_inmemory` and `register_inmemory` after `coord.open`. Creates
/// a fresh `InMemoryStorage` handle dedicated to the Corpus + VectorStore
/// tables, stamps it at the current estate format, and hands it to
/// `wire_glk_substores`.
///
/// Two `InMemoryStorage` handles: the DrawerStore already owns one (allocated
/// inside `InMemoryDrawerStore::new`). The Corpus + VectorStore tables (chunks,
/// vectors) are disjoint from the LocusKit tables (drawers, tunnels, kg_facts)
/// so a second handle is safe — there is no shared table namespace to conflict.
/// This is the in-memory equivalent of the SQLite two-handle pattern.
///
/// `wire_inmemory_semantic_recall` never returns `Err` in a correct build —
/// `InMemoryStorage` never produces I/O errors. The `Result` wrapper aligns the
/// call site with `wire_sqlite_semantic_recall` and `wire_postgres_semantic_recall`
/// for uniform error propagation at `new_inmemory` (`.expect`).
fn wire_inmemory_semantic_recall(
    handle: &EstateHandle,
    coord: &Arc<std::sync::Mutex<EstateCoordinator>>,
) -> Result<(), String> {
    // Dedicated InMemoryStorage for Corpus + VectorStore. The estate_id is a
    // fresh UUID — this storage holds no LocusKit rows and is never read via
    // the DrawerStore path, so the estate_id is a logging hint only.
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(EstateFormatVersion::CURRENT, INIT_NOW)
        .map_err(|error| format!("estate-format stamp: {error:?}"))?;
    wire_glk(handle, coord, storage, INIT_NOW, false)
}

/// Wire the semantic recall lanes for a PostgreSQL-backed estate.
///
/// Called by `new_postgres` and `register_postgres` after `coord.open`. Builds a
/// `PostgresStorage` handle on the same `conn_str` and pool defaults as the
/// DrawerStore's underlying store, runs the compiled migration chain on the
/// estate, then hands the storage to `wire_glk_substores`.
///
/// Pool defaults match the Swift ARIA_MCP leg and the DrawerStore's defaults
/// (pool_size=10, connection_timeout=5.0s, idle_timeout=300.0s). The
/// `PostgresStorage` handle uses a lazy pool — construction does not open a TCP
/// connection. Schema migrations are idempotent: safe to call on an existing PG
/// schema and on a fresh one.
///
/// # Errors
///
/// Returns `Err(String)` if `PostgresStorage::new` fails (malformed connection
/// string), if the migration chain fails, or if the sub-store wiring fails.
fn wire_postgres_semantic_recall(
    conn_str: &str,
    handle: &EstateHandle,
    coord: &Arc<std::sync::Mutex<EstateCoordinator>>,
) -> Result<(), String> {
    // PostgresStorage on the same connection string as the DrawerStore.
    // Pool defaults mirror the DrawerStore's PostgresDrawerStore defaults and
    // the Swift AriaMCPMain.swift PostgreSQLStorage defaults.
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Postgresql {
            connection_string: conn_str.to_string(),
            pool_size: 10,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 300.0,
        },
    );
    let storage: Arc<dyn Storage> = Arc::new(
        PostgresStorage::new(config)
            .map_err(|e| format!("PostgresStorage for semantic recall at {conn_str:?}: {e}"))?,
    );

    // Geometry normalization is SQLite-specific (file header byte 20 = reserved
    // bytes per page). PostgreSQL manages its own storage geometry server-side
    // and has no file header to normalize; this step is intentionally omitted
    // for PostgreSQL estates (blast-radius INTENTIONALLY_LEFT classification).

    // This binary declares a 1.0 floor, so prepare the estate through the
    // separately compiled migration capsules before current-runtime wiring.
    // A crash leaves the persisted phase/cursor resumable on the next start.
    let now = wall_now_millis();
    {
        let mut guard = coord.lock().unwrap();
        guard
            .run_migration_chain(handle, now, default_ensemble())
            .map_err(|error| format!("estate migration chain: {error}"))?;
    }
    wire_glk(handle, coord, storage, now, false)
}

/// Wire the semantic recall lanes for a SQLite-backed estate.
///
/// Called by both `new_sqlite` and `register_sqlite` after `coord.open`.
///
/// `shared_storage` is the DrawerStore's already-open, already-keyed `Storage`
/// handle, obtained via `DrawerStore::storage()`. Sharing this connection (rather
/// than opening a second independent `SqliteStorage` on the same file) matches the
/// Swift `AriaMCPMain.swift` pattern exactly — one connection, all sub-stores — and
/// eliminates the Windows-ARM SQLCipher bug where a second connection to an encrypted
/// WAL-mode estate fails to receive `PRAGMA key` and returns NOTADB on the first SQL.
///
/// Table namespaces remain disjoint: LocusKit owns drawers/tunnels/kg_facts/…;
/// CorpusKit/SynapseKit own chunks/vectors. WAL serialises all writes through the
/// shared connection.
///
/// Recall ensemble is the deterministic signals (`default_ensemble()`:
/// RI then LSA) — reproducible
/// across Swift/Rust ports, no CoreML.
/// Matches `provision`'s default and the Swift `AriaMCPMain.swift` Lane D wiring
/// (`CorpusEnsemble.defaultEnsemble()`).
fn wire_sqlite_semantic_recall(
    path: &str,
    shared_storage: Arc<dyn Storage>,
    handle: &EstateHandle,
    coord: &Arc<std::sync::Mutex<EstateCoordinator>>,
    preserve_v2_frozen_configuration: bool,
    offline_upgrade: bool,
) -> Result<(), String> {
    let now = wall_now_millis();
    if preserve_v2_frozen_configuration {
        // A frozen v2 open must use a prepared estate. This reads the current
        // stamp without writing an unstamped or older estate forward.
        EstateFormatStore::new(Arc::clone(&shared_storage))
            .require_current()
            .map_err(|error| format!("frozen selected-v2 SQLite open requires current estate format: {error:?}"))?;
    } else {
        // This binary declares a 1.0 floor, so prepare the estate through the
        // separately compiled migration capsules before current-runtime wiring.
        let mut guard = coord.lock().unwrap();
        let result = if offline_upgrade {
            guard.run_offline_migration_chain(handle, now, default_ensemble())
        } else { guard.run_migration_chain(handle, now, default_ensemble()) };
        result.map_err(|error| format!("estate migration chain for {path:?}: {error}"))?;
    }
    wire_glk(handle, coord, shared_storage, now, preserve_v2_frozen_configuration)
}

/// The one wire call every backend shares: `EstateCoordinator::wire_glk_substores`
/// with the canonical five-signal ensemble. It opens the attached-mode
/// CorpusContentEngine on `storage`, reconciles the configured providers,
/// registers the Corpus and its shared VectorStore, opens the GLK composite
/// schema, installs the on_encoded encode rider, acts on the estate's
/// `embedding_provider` manifest key (`"encoder"` registers the span encoder),
/// and eagerly mounts the Corpus ingest queue + drain worker — so a restarted
/// daemon resumes a persisted encode backlog at open, and a standalone
/// `drain` command (which never captures) drains. Rider before mount, encoder
/// activation after the VectorStore is registered: the same order Swift
/// `wireSubstores` keeps.
fn wire_glk(
    handle: &EstateHandle,
    coord: &Arc<std::sync::Mutex<EstateCoordinator>>,
    storage: Arc<dyn Storage>,
    now_millis: i64,
    preserve_v2_frozen_configuration: bool,
) -> Result<(), String> {
    let mut guard = coord.lock().unwrap();
    let result = if preserve_v2_frozen_configuration {
        guard.wire_glk_substores_readonly(handle, storage, default_ensemble(), now_millis)
    } else {
        guard.wire_glk_substores(handle, storage, default_ensemble(), now_millis)
    };
    result.map_err(|e| format!("wire_glk_substores failed: {e:?}"))
}

fn wall_now_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}
