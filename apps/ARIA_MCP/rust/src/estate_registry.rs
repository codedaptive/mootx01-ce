//! Estate registry — keyed by UUID, with a default estate.
//!
//! Mirrors the Swift `ToolDispatcher` multi-estate routing: one default
//! estate plus a map of additional estates keyed by UUID. Unknown or
//! malformed `estateID` is an `invalidParams` error, consistent with the
//! Swift dispatcher's `resolveHandle(_:)` behavior.
//!
//! # Backend constructors
//!
//! Two backend shapes are available:
//! - **In-memory** (`new_inmemory`, `register_inmemory`): ephemeral, discarded
//!   on process exit. Used by default when `ARIA_MCP_SQLITE_PATH` is unset.
//! - **SQLite** (`new_sqlite`, `register_sqlite`): WAL-mode durable estate
//!   at a caller-supplied filesystem path. Database file is created if absent.
//!   Persistence is server-internal — no wire change; the JSON-RPC surface is
//!   identical for both backends. See `server::ServerConfig::from_env` for how
//!   the env var selects between them at startup.
//!
//! NOTE: PostgreSQL backend support requires `locus_kit::PostgresDrawerStore`,
//! which does not yet exist. The persistence-kit `PostgresStorage` struct is
//! available, but `EstateCoordinator::open` requires `Arc<dyn DrawerStore>`
//! and `DrawerStoreCore::new` is `pub(crate)` within locus-kit. A
//! `PostgresDrawerStore` newtype must be added to locus-kit before this
//! registry can offer `new_postgres` / `register_postgres`. See
//! ARIA_MCP_POSTGRES_001 completion report for the full rescope finding.

use std::collections::HashMap;
use std::sync::Arc;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use uuid::Uuid;

// Compile-time constant for the default estate owner identifier — stable
// across runs so log messages identify the server's own estate clearly.
const DEFAULT_OWNER: &str = "aria-mcp-default";

// Arbitrary wall-clock anchor for the in-memory estate. In-memory estates
// are ephemeral and discarded when the server exits; using a fixed value
// keeps test behavior deterministic.
const INIT_NOW: i64 = 1_700_000_000;

// Default busy-timeout for SQLite estates: 5.0 seconds. Single-process
// server model means concurrent writers are unlikely, but the timeout
// prevents instant failure if a background tool call and the startup
// open race on the same file.
const SQLITE_BUSY_TIMEOUT_SECS: f64 = 5.0;

/// An opened estate in the registry: coordinator + handle pair.
///
/// The coordinator is the dispatch surface; the handle identifies which
/// estate within the coordinator to target for a given tool call.
#[derive(Clone)]
pub struct OpenEstate {
    /// Shared coordinator — all estates registered on the same server
    /// share one coordinator so they can be cross-addressed by the
    /// federated lenses.
    pub coord: Arc<std::sync::Mutex<EstateCoordinator>>,
    pub handle: EstateHandle,
    pub estate_id: Uuid,
}

/// The estate registry the dispatcher uses to resolve `estateID` arguments.
///
/// One default estate; zero or more additional estates keyed by UUID.
/// The default estate is either in-memory (when `ARIA_MCP_SQLITE_PATH` is
/// unset) or SQLite-backed (when the env var is set) — selection happens in
/// `ServerConfig::from_env`. Wire surface is identical for both backends.
pub struct EstateRegistry {
    /// The default estate — targeted when a tool call omits `estateID`.
    pub default: OpenEstate,
    /// All registered estates including the default, keyed by UUID.
    extras: HashMap<Uuid, OpenEstate>,
    /// The shared coordinator (same Arc as in every OpenEstate — single
    /// coordinator for all estates so the federated lenses can cross-address).
    pub coord: Arc<std::sync::Mutex<EstateCoordinator>>,
}

impl EstateRegistry {
    /// Construct a registry with one new in-memory default estate.
    ///
    /// Used when `ARIA_MCP_SQLITE_PATH` is absent — behavior identical to v1.
    pub fn new_inmemory() -> Self {
        let coord = Arc::new(std::sync::Mutex::new(EstateCoordinator::new()));
        let estate_id = Uuid::new_v4();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally;
        // backend identity is visible at the type, not the argument.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(INIT_NOW, None).unwrap());
        let handle = coord
            .lock()
            .unwrap()
            .open(store, OwnerCredentials::new(DEFAULT_OWNER), 0, 100)
            .expect("default estate open must succeed");
        let default_estate = OpenEstate {
            coord: Arc::clone(&coord),
            handle,
            estate_id,
        };
        let mut extras = HashMap::new();
        extras.insert(estate_id, default_estate.clone());
        EstateRegistry {
            default: default_estate,
            extras,
            coord,
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
    /// `owner` identifies the estate in log messages and audit records; use
    /// `DEFAULT_OWNER` (`"aria-mcp-default"`) for the production default estate.
    ///
    /// # Errors
    ///
    /// Returns `Err(String)` with a human-readable message if `SqliteDrawerStore`
    /// cannot open the path (bad path, permission denied, corrupt database). The
    /// caller should print this to stderr and exit with a nonzero code.
    pub fn new_sqlite(path: &str, owner: &str) -> Result<Self, String> {
        let coord = Arc::new(std::sync::Mutex::new(EstateCoordinator::new()));
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
        let handle = coord
            .lock()
            .unwrap()
            .open(store, OwnerCredentials::new(owner), 0, 100)
            .expect("default sqlite estate open must succeed");
        let default_estate = OpenEstate {
            coord: Arc::clone(&coord),
            handle,
            estate_id,
        };
        let mut extras = HashMap::new();
        extras.insert(estate_id, default_estate.clone());
        Ok(EstateRegistry {
            default: default_estate,
            extras,
            coord,
        })
    }

    /// Register an additional in-memory estate. Returns its UUID.
    /// Used by the `moot_open_estate` test seam and integration tests.
    pub fn register_inmemory(&mut self, owner: &str) -> Uuid {
        let estate_id = Uuid::new_v4();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(INIT_NOW, None).unwrap());
        let handle = self
            .coord
            .lock()
            .unwrap()
            .open(store, OwnerCredentials::new(owner), 0, 100)
            .expect("additional estate open must succeed");
        let estate = OpenEstate {
            coord: Arc::clone(&self.coord),
            handle,
            estate_id,
        };
        self.extras.insert(estate_id, estate);
        estate_id
    }

    /// Register an additional SQLite-backed estate at `path`. Returns its UUID.
    ///
    /// Same open semantics as `new_sqlite`: WAL mode, 5-second busy timeout,
    /// database created if absent. Returns `Err(String)` on open failure.
    pub fn register_sqlite(&mut self, path: &str, owner: &str) -> Result<Uuid, String> {
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
            .open(store, OwnerCredentials::new(owner), 0, 100)
            .expect("additional sqlite estate open must succeed");
        let estate = OpenEstate {
            coord: Arc::clone(&self.coord),
            handle,
            estate_id,
        };
        self.extras.insert(estate_id, estate);
        Ok(estate_id)
    }

    /// Resolve the estate targeted by a tool call's `estateID` argument.
    ///
    /// Absent `estateID` → default estate (preserves single-estate v1.0
    /// behavior). Present but malformed (not a UUID) → invalidParams.
    /// Present but unknown (UUID not registered) → invalidParams.
    /// Matches Swift `ToolDispatcher.resolveHandle(_:)` exactly.
    pub fn resolve(
        &self,
        args: &std::collections::BTreeMap<String, crate::jsonrpc::JsonValue>,
        key: &str,
    ) -> Result<&OpenEstate, crate::jsonrpc::JSONRPCError> {
        use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode};
        let raw = match args.get(key).and_then(|v| v.as_str()) {
            None => return Ok(&self.default),
            Some(s) => s.to_owned(),
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
}
