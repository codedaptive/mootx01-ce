//! Estate registry — keyed by UUID, with a default estate.
//!
//! Mirrors the Swift `ToolDispatcher` multi-estate routing: one default
//! estate plus a map of additional estates keyed by UUID. Unknown or
//! malformed `estateID` is an `invalidParams` error, consistent with the
//! Swift dispatcher's `resolveHandle(_:)` behavior.
//!
//! # v1 boundary
//!
//! v1 supports in-memory estates only. The server opens one in-memory
//! estate at startup (the default). Additional in-memory estates can be
//! registered via `register()` (the test seam). Persistent storage
//! backends (SQLite, CloudKit) are v2 work — stated plainly as a
//! behavioral fact of v1 in the README.

use std::collections::HashMap;
use std::sync::Arc;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

// Compile-time constant for the default estate owner identifier — stable
// across runs so log messages identify the server's own estate clearly.
const DEFAULT_OWNER: &str = "aria-mcp-default";

// Arbitrary wall-clock anchor for the in-memory estate. In-memory estates
// are ephemeral and discarded when the server exits; using a fixed value
// keeps test behavior deterministic.
const INIT_NOW: i64 = 1_700_000_000;

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
/// All estates are in-memory for v1 (see module-level doc for the boundary).
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
    /// This is the v1 production and test path.
    pub fn new_inmemory() -> Self {
        let coord = Arc::new(std::sync::Mutex::new(EstateCoordinator::new()));
        let estate_id = Uuid::new_v4();
        let storage = Arc::new(InMemoryStorage::with_estate(estate_id));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, INIT_NOW, None).unwrap());
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

    /// Register an additional in-memory estate. Returns its UUID.
    /// Used by the `moot_open_estate` test seam and integration tests.
    pub fn register_inmemory(&mut self, owner: &str) -> Uuid {
        let estate_id = Uuid::new_v4();
        let storage = Arc::new(InMemoryStorage::with_estate(estate_id));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, INIT_NOW, None).unwrap());
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
