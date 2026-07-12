//! Drawer-store contract. The trait every LocusKit storage backend
//! conforms to.
//!
//! ## Why this is a trait, not a struct
//!
//! The Swift port's `DrawerStore` is a concrete actor wrapping a
//! `Storage` (PersistenceKit) handle. The Rust port keeps the contract
//! and the concrete implementation separate: the trait is the surface
//! consumers (`Estate`, the bitmap evaluator) program against, and one
//! concrete newtype per backend lives next to it. Two newtypes ship over
//! [`DrawerStoreCore`](crate::drawer_store_inmemory::DrawerStoreCore)
//! (the storage-agnostic verb-logic core):
//! - [`crate::drawer_store_inmemory`] — `InMemoryDrawerStore` over
//!   `InMemoryStorage` (test fixture, no persistence across process runs)
//! - [`crate::drawer_store_sqlite`] — `SqliteDrawerStore` over
//!   `SqliteStorage` (WAL-mode SQLite, durable across restarts)
//!
//! ## Trait surface
//!
//! Most read-path defaults return `LocusKitError::DatabaseUnavailable` so
//! any backend that forgets to implement a method fails loud rather than
//! silently returning zero rows or `None`: an abstract trait default that
//! returns empty-success hides a missing implementation (math-provenance gate
//! FINDING-3, 2026-06-12).
//!
//! Write-path defaults return the same error for the same reason.
//!
//! **Required methods — no default at all (compile-time enforcement):**
//! `all_drawers` and `room_level_fingerprints` carry NO default. Per Bob's SDK
//! ruling, a backend that forgets a corpus-scan / container-fingerprint read
//! must fail to COMPILE rather than fail loud at runtime. The three production
//! stores already implement both.
//!
//! **Exceptions — three no-op/delegation defaults that are deliberately
//! non-fail-loud:**
//! - `all_drawers_bounded` — derives from `all_drawers()`; not silently empty.
//! - `all_drawers_bounded_projected` — derives from `all_drawers_bounded()`;
//!   not silently empty.
//! - `taxonomy` — delegates to `list_wings()`; inherits fail-loud via delegation.
//!
//! **Exceptions — storage-layer optional capabilities (no data to return is
//! semantically correct for non-implementing stores):**
//! - `or_in_container_fingerprint` — write/maintenance hook; no-op is correct
//!   for backends without a container aggregate table (spec § 11.5).
//! - `rebuild_container_fingerprints` — same; no-op for backends without
//!   container aggregate.
//! - `get_container_fingerprint` — returns `Ok(None)` because an absent
//!   aggregate MUST NOT prune, which is the sound safe-side behaviour for
//!   backends that do not maintain the aggregate (spec § 11.5).
//!
//! **Test fakes** (`estate.rs::FakeStore`) override the methods they
//! exercise (`read_manifest`, `set_meta`, `drawer_ids`) PLUS the two
//! now-required reads (`all_drawers`, `room_level_fingerprints`) with trivial
//! empty-returns, because those two carry no default. For other methods not
//! called by their tests, they must explicitly override with the appropriate
//! empty-return if the test requires it — relying on the trait default is no
//! longer allowed.
//!
//! ## Async story
//!
//! The Swift surface is async because every method touches the actor's
//! isolated `Storage`. The Rust persistence-kit trait is currently
//! synchronous (see `persistence-kit/src/storage.rs` v1.0 doc) so the
//! Rust trait mirrors that — methods return `Result<T, LocusKitError>`
//! directly. When persistence-kit grows an async surface, this trait moves
//! with it.

use crate::diary_entry::DiaryEntry;
use crate::drawer::Drawer;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use crate::adjectives::State;
use crate::association::Association;
use crate::container_fingerprint_store::RoomLevelEntry;
use crate::error::LocusKitError;
use crate::estate_types::RowID;
use crate::kg_fact::KGFact;
use crate::learned_reference::LearnedReference;
use crate::manifest::ManifestValues;
use crate::proposal::Proposal;
use crate::recall_trace_item::RecallTraceItem;
use crate::source_catalog_entry::SourceCatalogEntry;
use crate::summaries::{RoomSummary, WingSummary};
use crate::tunnel::Tunnel;
use persistence_kit::storage::Storage;
use std::collections::BTreeMap;
use std::sync::Arc;
use substrate_lib::row_state::RowVerb;
use substrate_types::fingerprint256::Fingerprint256;

/// Contract every LocusKit storage backend conforms to.
///
/// `Send + Sync` lets an `Arc<dyn DrawerStore>` cross thread
/// boundaries inside the `Estate` handle, which is the shape future
/// async wrappers and FFI consumers need.
///
/// Most methods below have a default impl so minimal fakes (LP-1B
/// `FakeStore`, future net-new test stubs) compile without overriding
/// what they do not exercise. The exceptions are the manifest contract
/// (`read_manifest` / `set_meta`) and the two compile-enforced reads
/// (`all_drawers`, `room_level_fingerprints`) which have NO default — every
/// store, including minimal fakes, must implement them. Production backends —
/// the LP-1E `InMemoryDrawerStore` and `SqliteDrawerStore` (both wrapping
/// `DrawerStoreCore`) — override every method.
#[allow(clippy::too_many_arguments)]
pub trait DrawerStore: Send + Sync {
    // -----------------------------------------------------------------
    // Storage access (ADR-017 NT-L2)
    // -----------------------------------------------------------------

    /// The underlying storage backing this store. Used by Estate to
    /// construct a NodeStore over the same storage. Returns `None` by
    /// default; concrete production stores override.
    fn storage(&self) -> Option<Arc<dyn Storage>> {
        None
    }

    // -----------------------------------------------------------------
    // Node-name resolution (ADR-017)
    // -----------------------------------------------------------------

    /// Resolve `parent_node_id` values to `(wing_name, room_name)` pairs
    /// by querying the nodes table. Used by the bitmap evaluator and
    /// estate verbs to resolve display names after ADR-017 removed
    /// wing/room from the Drawer struct.
    ///
    /// Mirrors Swift `DrawerStore.resolveNodeNames(parentNodeIds:)`.
    /// The default returns an empty map; concrete stores that hold a
    /// node tree override this.
    fn resolve_node_names(
        &self,
        _parent_node_ids: &[String],
    ) -> Result<BTreeMap<String, (String, String)>, LocusKitError> {
        Ok(BTreeMap::new())
    }

    // -----------------------------------------------------------------
    // Manifest (LP-1B contract, retained verbatim)
    // -----------------------------------------------------------------

    /// Read the full manifest as a typed snapshot. Synthesised from
    /// the `manifest` key-value table the same way Swift does. Returns
    /// `LocusKitError::DatabaseUnavailable` or `SqliteError` for
    /// substrate-level faults.
    fn read_manifest(&self) -> Result<ManifestValues, LocusKitError>;

    /// Write a single manifest row. Implementations must be idempotent
    /// on equal `(key, value)` pairs and atomic per call.
    fn set_meta(&self, key: &str, value: &str) -> Result<(), LocusKitError>;

    /// Read a single manifest value. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no manifest keys.
    fn get_meta(&self, _key: &str) -> Result<Option<String>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_meta not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Drawer CRUD
    // -----------------------------------------------------------------

    /// Insert a drawer. When the drawer's `lineage_id` matches an
    /// active predecessor, the insert runs as a supersession cascade
    /// per spec § 6.2 / § 6.3: capture the new drawer through the
    /// gate (a genesis `AuditEvent`), flip the predecessor's 6-bit
    /// state field to `Superseded` via
    /// `mutate_state(State::Superseded, RowVerb::Supersede)` (which
    /// appends one sealed `AuditEvent`), and file a directional
    /// `supersedes` tunnel. Otherwise a plain gated capture.
    ///
    /// ## Add-coverage guarantee (spec § 11.5 Option B)
    ///
    /// Every storage-backed implementation of this method MUST fold the
    /// container-fingerprint OR update inside itself, so coverage is
    /// structurally guaranteed: calling `add_drawer` is the one and only
    /// sanctioned add path, and it ALWAYS maintains the aggregate. It is
    /// impossible to add a drawer through this trait surface without
    /// updating the per-container OR aggregate (spec § 11.5). The clear-side
    /// (withdraw / bit-off) is intentionally a no-op — stale set bits are
    /// harmless over-approximations (see `ContainerFingerprintStore` header).
    fn add_drawer(&self, _drawer: &Drawer, _now: i64) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_drawer not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a drawer by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no drawers.
    fn get_drawer(&self, _id: &str) -> Result<Option<Drawer>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_drawer not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Find a living successor sharing `lineage_id`, excluding `excluding_id`.
    ///
    /// A "living successor" is any row in the same content lineage that
    /// currently occupies a Cluster-A state — active, pending, contested,
    /// or accepted (raw state < 16, the Cluster-B boundary per cookbook
    /// §2.3). This is the lineage head: the row that superseded the
    /// excluded predecessor (or a later link in the chain).
    ///
    /// The revive guard (`Estate::mutate` with `Revive`) consults this to
    /// decide whether reviving a superseded row would create two active
    /// rows claiming the same lineage position — a domain contradiction
    /// (cookbook §6.2). The predicate is `< 16`, wider than
    /// `find_active_predecessor`'s `< 3`: a living successor includes the
    /// audit-grade `accepted` state, which the supersession-cascade
    /// predecessor lookup intentionally excludes.
    ///
    /// `lineage_id` is the lineage UUID in string form (as stored in the
    /// `lineageID` column). Mirror of Swift `DrawerStore.livingSuccessorInLineage`.
    ///
    /// ## Default impl — fail-loud, never silently missing
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no living successors in any
    /// lineage (which would incorrectly allow duplicate-active-row creation).
    fn living_successor_in_lineage(
        &self,
        _lineage_id: &str,
        _excluding_id: &str,
    ) -> Result<Option<String>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "living_successor_in_lineage not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned drawers in a wing, ordered by `filed_at` ascending.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no drawers in any wing.
    fn drawers_in_wing(&self, _wing: &str) -> Result<Vec<Drawer>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "drawers_in_wing not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned drawers in a wing/room pair, ordered by
    /// `filed_at` ascending.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no drawers in any room.
    fn drawers_in_wing_room(&self, _wing: &str, _room: &str) -> Result<Vec<Drawer>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "drawers_in_wing_room not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned drawers for one source file, ordered by
    /// `chunk_index` ascending then `filed_at` ascending.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no drawers for any source file.
    fn drawers_by_source(&self, _source_file: &str) -> Result<Vec<Drawer>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "drawers_by_source not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Full-corpus scan ordered by `filed_at` ascending, including
    /// tombstoned rows. The bitmap evaluator excludes tombstones at
    /// its own tier (§ 7.9.4); callers needing a pre-filtered set use
    /// `drawers_in_wing` / `drawers_in_wing_room` instead.
    ///
    /// ## Required, no default — compile-time enforcement
    ///
    /// An empty-`Ok` default was the exact bug class that shipped on the
    /// Postgres backend before this fix: a store that did not override
    /// `all_drawers` returned ZERO rows on every recall scan
    /// (math-provenance gate FINDING-3, 2026-06-12). Per Bob's SDK ruling, a
    /// backend that forgets a corpus-scan method must fail to COMPILE rather
    /// than at runtime — so this is a required trait method with no default.
    /// All three production backends implement it.
    fn all_drawers(&self) -> Result<Vec<Drawer>, LocusKitError>;

    /// Bounded full-corpus scan ordered by `filed_at` ascending.
    ///
    /// Equivalent to `all_drawers()` with a row cap applied at the storage
    /// layer. `limit` of `None` is unbounded (same as `all_drawers`).
    ///
    /// This is the recall locus-lane scan path: the GLK `RecallDirector`
    /// drains at most `RECALL_CANDIDATE_CAP` (256) rows — capping the scan
    /// here yields the same drained set as the uncapped path while doing O(cap)
    /// I/O instead of O(estate). Mirrors Swift `DrawerStore.allDrawers(hydrationLevel:limit:)`.
    ///
    /// ## No-blob note (Rust ↔ Swift parity)
    ///
    /// The Swift implementation uses a column-projection query to omit the
    /// content blob when no content-tier predicate is present, saving the
    /// blob I/O. The Rust port now exposes the same capability via
    /// [`all_drawers_bounded_projected`](Self::all_drawers_bounded_projected),
    /// which the recall path calls for the no-blob (`.structured`) scan; this
    /// method always loads full rows (content included).
    ///
    /// ## Default impl — derive from `all_drawers`, never silently empty
    ///
    /// The default truncates [`all_drawers`](Self::all_drawers) to `limit`
    /// rather than returning an empty vector. An empty-`Ok` default is the
    /// exact bug class that shipped on the Postgres backend: a store that
    /// implemented `all_drawers` but not `all_drawers_bounded` returned ZERO
    /// rows on every recall. Deriving from `all_drawers` means any backend
    /// that can scan its corpus answers a bounded scan correctly without an
    /// explicit override; backends that want the storage-layer `LIMIT`
    /// optimisation override this directly (SQLite, InMemory, Postgres all do).
    fn all_drawers_bounded(&self, limit: Option<usize>) -> Result<Vec<Drawer>, LocusKitError> {
        let all = self.all_drawers()?;
        Ok(match limit {
            Some(n) => all.into_iter().take(n).collect(),
            None => all,
        })
    }

    /// Bounded page of active (non-tombstoned) drawers ordered by `id`
    /// ascending, optionally starting strictly after `after_id`. `id` is
    /// the declared TEXT primary key, present and indexed on every
    /// backend (SQLite, PostgreSQL, InMemory).
    ///
    /// Built for GeniusLocusKit's reindex-missing sweep (MEDIUM perf fix;
    /// mirrors Swift `DrawerStore.activeDrawersAfter(id:limit:)`): a caller
    /// walks the whole `drawers` table exactly once, in bounded pages,
    /// advancing `after_id` forward each call, instead of reloading the
    /// full table (via `all_drawers`) on every pass of a backfill loop —
    /// see `GeniusLocusKit::EstateCoordinator::sweep_reindex_missing`.
    ///
    /// Ordered by `id` (not `filed_at`) because callers of this method
    /// have no ordering requirement beyond "visit every row exactly
    /// once" — a simple `id > after_id` cursor is sufficient and does not
    /// need the `(filed_at, id)` compound key `all_drawers_bounded` uses
    /// for its recall-facing recency ordering.
    ///
    /// ## Default impl — derive from `all_drawers`, never silently empty
    ///
    /// The default loads the full corpus via [`all_drawers`](Self::all_drawers),
    /// filters out tombstoned rows and anything at or before `after_id`,
    /// sorts by `id`, and truncates to `limit` — correct for any backend
    /// but O(estate) per call. SQLite, Postgres, and InMemory override
    /// with a storage-tier `id > ? AND tombstonedAt IS NULL ORDER BY id
    /// LIMIT ?` query for O(limit) I/O.
    fn active_drawers_after(
        &self,
        after_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        let mut all: Vec<Drawer> = self
            .all_drawers()?
            .into_iter()
            .filter(|d| d.tombstoned_at.is_none())
            .filter(|d| match after_id {
                Some(cursor) => d.id.as_str() > cursor,
                None => true,
            })
            .collect();
        all.sort_by(|a, b| a.id.cmp(&b.id));
        all.truncate(limit);
        Ok(all)
    }

    /// Bounded full-corpus scan ordered by `filed_at` ascending, projected to
    /// the structured (no-blob) column set — the `content` column is omitted
    /// so decoded drawers carry `content == ""`.
    ///
    /// This is the Rust parity of Swift's `.structured` recall projection:
    /// when the filter chain has no content-tier predicate, the recall path
    /// scans no-blob, so a `.structured` caller receives `content == ""`
    /// (spec § 7.3: structured is "bitmap columns + structured-row fields only,
    /// no blob reads"). The `.full` recall path uses
    /// [`all_drawers_bounded`](Self::all_drawers_bounded) (content loaded), and
    /// a content-predicate chain also uses the blob path so the substring match
    /// can run.
    ///
    /// The default delegates to [`all_drawers_bounded`](Self::all_drawers_bounded)
    /// then clears the content field — correct for any backend; the SQLite,
    /// InMemory, and Postgres backends override with a true projected `SELECT`
    /// that never reads the blob column.
    fn all_drawers_bounded_projected(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        let mut rows = self.all_drawers_bounded(limit)?;
        for d in &mut rows {
            d.content = String::new();
        }
        Ok(rows)
    }

    // -----------------------------------------------------------------
    // P4-secfix: DESC-ordered bounded scan variants.
    //
    // The recall non-pruning path uses a bounded scan with RECALL_CANDIDATE_CAP
    // (256) rows. When ordered ASC, an estate with >256 drawers permanently
    // excludes the newest content from recall — the 256 oldest drawers fill the
    // candidate window and everything filed after drawer #256 is unreachable.
    // These DESC variants ensure the cap retains the NEWEST candidates.
    //
    // Default impls derive from the ASC counterparts (correct for all backends).
    // SQLite, Postgres, and InMemory override with efficient ORDER BY filed_at
    // DESC SQL so the DESC scan does O(cap) I/O, not O(estate)+reverse.
    // The Arc blanket forwards both methods so Arc<dyn DrawerStore> estates
    // (GLK's composited estate) work correctly.
    // -----------------------------------------------------------------

    /// Bounded full-corpus scan ordered by `filed_at` DESCENDING (newest first).
    ///
    /// P4-secfix: recall non-pruning path; ensures the bounded candidate window
    /// retains the most-recent drawers rather than the oldest 256. Mirrors Swift
    /// `DrawerStore.allDrawers(hydrationLevel:limit:direction: .descending)`.
    ///
    /// Default derives from [`all_drawers_bounded`](Self::all_drawers_bounded)
    /// by loading the full ASC result and reversing; backends override with a
    /// true DESC SQL query for O(cap) I/O.
    fn all_drawers_bounded_desc(&self, limit: Option<usize>) -> Result<Vec<Drawer>, LocusKitError> {
        // Load the full (unbounded) set and reverse to get DESC order.
        // `all_drawers()` uses (filed_at ASC, id ASC) compound ordering
        // (c-recall-portable fix; id is the declared TEXT primary key,
        // portable to PostgreSQL where rowid is undefined), so `.reverse()`
        // yields exactly (filed_at DESC, id DESC) — a deterministic total
        // order that is the byte-for-byte reverse of the ASC result for any
        // fixed dataset. This is correct but O(estate) — backends
        // (DrawerStoreCore) override with an efficient SQL ORDER BY DESC,
        // LIMIT query for O(cap) I/O.
        let mut all = self.all_drawers()?;
        all.reverse();
        Ok(match limit {
            Some(n) => all.into_iter().take(n).collect(),
            None => all,
        })
    }

    /// Bounded no-blob full-corpus scan ordered by `filed_at` DESCENDING.
    ///
    /// P4-secfix projected variant: same as [`all_drawers_bounded_desc`] but
    /// clears content (mirrors Swift `.structured` hydration). Default derives
    /// from `all_drawers_bounded_desc`; backends override for efficiency.
    fn all_drawers_bounded_projected_desc(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        let mut rows = self.all_drawers_bounded_desc(limit)?;
        for d in &mut rows {
            d.content = String::new();
        }
        Ok(rows)
    }

    /// Batch-insert a slice of recall-trace rows in a single operation.
    ///
    /// Replaces the per-drawer `insert_recall_trace` loop that wrote one
    /// SQLite INSERT per filtered drawer (O(N) inserts). The batch path
    /// writes all rows inside a single transaction, which is O(1) overhead
    /// amortised over the candidate count. Mirrors Swift
    /// `DrawerStore.insertRecallTraces(_:)`.
    ///
    /// Silently succeeds on an empty slice. On storage error, returns the
    /// first `LocusKitError` encountered; partial inserts are rolled back.
    fn insert_recall_traces(&self, _items: &[RecallTraceItem]) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "insert_recall_traces not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All drawer row identifiers in insertion order.
    ///
    /// Used by tests and future verbs that need a complete ID set. The
    /// LP-1E concrete store overrides this to return every drawer's id.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no drawer IDs. The `FakeStore`
    /// in `estate.rs` explicitly overrides this to return `Ok(Vec::new())`
    /// because its tests operate on an empty store — the override makes the
    /// intent visible rather than relying on a silent default.
    fn drawer_ids(&self) -> Result<Vec<RowID>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "drawer_ids not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Bitmap mutation paths
    // -----------------------------------------------------------------

    /// Mutate a drawer's provenance bitmap and append one sealed
    /// `AuditEvent` to the audit log in the same logical operation.
    /// The prior value is read first so the event's before/after
    /// snapshot reflects the actual transition.
    fn mutate_provenance(
        &self,
        _drawer_id: &str,
        _new_provenance: i64,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "mutate_provenance not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Mutate a drawer's adjective bitmap and append one sealed
    /// `AuditEvent` to the audit log. Rejects the forbidden
    /// secret+exportable combination (I-22) in the gate's basis
    /// validation before the projection commits.
    fn mutate_adjective(
        &self,
        _drawer_id: &str,
        _new_adjective: i64,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "mutate_adjective not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Mutate a drawer's operational bitmap and append one sealed
    /// `AuditEvent` to the audit log.
    fn mutate_operational(
        &self,
        _drawer_id: &str,
        _new_operational: i64,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "mutate_operational not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Mutate a drawer's state (bits 0–5 of adjective_bitmap),
    /// validating the transition against the spec § 6.2 legal-graph
    /// before any write. Illegal transitions return
    /// `LocusKitError::DisciplineViolation` and leave the row and
    /// audit table unchanged. Upper adjective axes are preserved.
    fn mutate_state(
        &self,
        _drawer_id: &str,
        _new_state: State,
        _via: RowVerb,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "mutate_state not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Return the ids of every drawer sharing the same lineage chain as
    /// the drawer identified by `drawer_id`.
    ///
    /// The lineage chain is all rows whose `lineageID` column matches the
    /// target drawer's `lineageID`. No state filter — active, superseded,
    /// and tombstoned rows are all included. The target drawer's own id
    /// is included in the result.
    ///
    /// Returns an empty vec when `drawer_id` does not exist.
    fn lineage_chain(&self, _drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "lineage_chain not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Expunge a drawer and all its lineage siblings: tombstone the state,
    /// synchronously zero the content blob, and stamp `tombstonedAt` — all in
    /// one transaction. Cookbook §10.5 storage-layer postconditions. Aggregates
    /// untouched per §9.5.1. The cross-kit RAG vector delete is GLK's
    /// orchestration responsibility.
    ///
    /// When `seal_audit` is `true` (the default for direct LocusKit callers),
    /// the gate-produced audit event is appended to the audit log inside this
    /// call — preserving the historical atomic single-call contract.
    ///
    /// When `seal_audit` is `false` (used by the GLK orchestration path), the
    /// audit event is produced and returned but NOT appended. The caller is
    /// responsible for calling `seal_expunge_audit` after the cross-kit vector
    /// delete succeeds, or `seal_expunge_orphan_audit` if it fails — satisfying
    /// the §B-2a ordering invariant without producing a false-success audit.
    fn expunge_gated(
        &self,
        _drawer_id: &str,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
        _seal_audit: bool,
    ) -> Result<substrate_lib::verbs::AuditEvent, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "expunge_gated not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Append a previously-produced expunge audit event to the audit log.
    ///
    /// Called by the GLK orchestration path after step 2 (cross-kit vector
    /// delete) succeeds. Completes the deferred seal initiated by calling
    /// `expunge_gated` with `seal_audit: false`. This satisfies the §B-2a
    /// ordering invariant: the success audit seals only after the full expunge
    /// (storage + cross-kit delete) has completed.
    fn seal_expunge_audit(
        &self,
        _event: &substrate_lib::verbs::AuditEvent,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "seal_expunge_audit not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Append an `"expungeOrphan"` audit event to the audit log when the
    /// cross-kit vector delete (step 2) failed after the storage half
    /// (step 1) already committed.
    ///
    /// The orphan event records the substrate-level fact of the partial
    /// expunge honestly: the row is tombstoned and content is zeroed, but
    /// the vector embedding was NOT removed from GLK's cross-kit stores. The
    /// verb string `"expungeOrphan"` is preserved in the substrate audit trail
    /// (for forensic inspection) and maps to `UnifiedAuditVerb::Expunge` in
    /// the unified log (via `verb_from_str`), so downstream consumers see a
    /// completed expunge at the ARIA level.
    fn seal_expunge_orphan_audit(
        &self,
        _drawer_id: &str,
        _success_event: &substrate_lib::verbs::AuditEvent,
        _changed_by: &str,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "seal_expunge_orphan_audit not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Reanchor a drawer: update its placement columns (`room` and/or lattice
    /// anchor columns) and emit one sealed audit event for the move — all in
    /// one logical operation. Routes through `AuditGate::admit` with
    /// `verb = Mutate` (the active→active self-loop; there is no `RowVerb::Reanchor`
    /// case). The anchor delta is expressed via differing `prior_lattice_anchor`
    /// and `after_lattice_anchor`. The three bitmaps are read from the current
    /// row and passed unchanged.
    ///
    /// At least one of `to_room` / `to_lattice` must be `Some`.
    fn reanchor_gated(
        &self,
        _drawer_id: &str,
        _to_room: Option<&str>,
        _to_wing: Option<&str>,
        _to_lattice: Option<crate::estate_types::LatticeAnchor>,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "reanchor_gated not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Tunnel CRUD
    // -----------------------------------------------------------------

    /// Insert a tunnel.
    fn add_tunnel(&self, _tunnel: &Tunnel) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_tunnel not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a tunnel by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_tunnel(&self, _id: &str) -> Result<Option<Tunnel>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_tunnel not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned tunnels from a source wing, ordered by
    /// `filed_at` ascending.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn tunnels_from_wing(&self, _wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "tunnels_from_wing not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned tunnels from a source wing/room pair.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn tunnels_from_wing_room(
        &self,
        _wing: &str,
        _room: &str,
    ) -> Result<Vec<Tunnel>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "tunnels_from_wing_room not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned tunnels to a target wing.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn tunnels_to_wing(&self, _wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "tunnels_to_wing not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned tunnels across all wings, ordered by `filed_at`
    /// ascending. The dreaming daemon reads this to build the tunnel-key
    /// set for duplicate suppression — candidates whose drawer pair already
    /// has a Tunnel are dropped before scoring. Mirrors Swift
    /// `DrawerStore.allTunnels()`.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real scan.
    /// A silent-empty default would cause the dreaming daemon to score
    /// every drawer pair as a candidate (no known tunnels), producing
    /// duplicate tunnel proposals (math-provenance gate FINDING-3,
    /// 2026-06-12).
    fn all_tunnels(&self) -> Result<Vec<Tunnel>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "all_tunnels not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Tunnel retirement (T13 / ADR-021 Phase 7)
    // -----------------------------------------------------------------

    /// All non-tombstoned, non-retired tunnels estate-wide, ordered by `filed_at`.
    ///
    /// The active-edge view: retired tunnels (bit 13 of `operational_bitmap` set)
    /// are excluded so that OMEGA retirement removes a tunnel from the dreaming
    /// suppression set — allowing a later co-recall to re-propose it. Full history
    /// (including retired tunnels) remains reachable via `all_tunnels()`.
    ///
    /// Default impl fetches `all_tunnels()` and filters in-memory: the bitmap
    /// filter is not expressible in the StoragePredicate DSL. Backends may
    /// override if a SQL-level filter is preferred.
    ///
    /// Mirrors Swift `DrawerStore.allActiveTunnels()`.
    fn all_active_tunnels(&self) -> Result<Vec<Tunnel>, LocusKitError> {
        Ok(self
            .all_tunnels()?
            .into_iter()
            .filter(|t| !t.is_retired())
            .collect())
    }

    /// Flip bit 13 of `operational_bitmap` to retire a tunnel (T13 / ADR-021 Phase 7).
    ///
    /// Fetches the current tunnel, sets `IS_RETIRED_BIT`, and persists the updated
    /// bitmap. Returns `TunnelNotFound` if no non-tombstoned tunnel with `tunnel_id`
    /// exists.
    ///
    /// Audit: the caller (NeuronKit via the GLK seam) is responsible for writing a
    /// diary entry that records the retirement decision and OMEGA cycle context.
    /// This method performs only the bitmap update (B-1 compliant: NeuronKit reaches
    /// this through the GLK seam, never directly).
    ///
    /// Reversible: call `unretire_tunnel` to clear bit 13 when subsequent co-recall
    /// reinforces the endpoints again.
    ///
    /// Mirrors Swift `DrawerStore.retireTunnel(id:changedBy:now:)`.
    fn retire_tunnel(
        &self,
        _tunnel_id: &str,
        _changed_by: &str,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "retire_tunnel not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Clear bit 13 of `operational_bitmap` to un-retire a tunnel (T13 / ADR-021 Phase 7).
    ///
    /// Reverses a prior `retire_tunnel`. The tunnel re-enters active reads
    /// (`all_active_tunnels`) and the dreaming suppression set once persisted.
    /// Returns `TunnelNotFound` if no non-tombstoned tunnel with `tunnel_id` exists.
    ///
    /// Mirrors Swift `DrawerStore.unretireTunnel(id:changedBy:now:)`.
    fn unretire_tunnel(
        &self,
        _tunnel_id: &str,
        _changed_by: &str,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "unretire_tunnel not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Review a `Proposed` tunnel: accept moves lifecycle (bits 3–5 of
    /// `operational_bitmap`) to `Active`; reject moves it to `Withdrawn`.
    ///
    /// Only tunnels currently in `Proposed` lifecycle are reviewable —
    /// reviewing a settled tunnel returns `InvalidContent`. Like
    /// `retire_tunnel`, this performs only the bitmap update; the caller
    /// records who reviewed and why.
    ///
    /// Mirrors Swift `DrawerStore.respondToTunnel(id:accept:changedBy:reason:now:)`.
    fn respond_to_tunnel(
        &self,
        _tunnel_id: &str,
        _accept: bool,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "respond_to_tunnel not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Outline helpers (ADR-017 §11, NT-L5)
    // -----------------------------------------------------------------

    /// Children of a parent drawer in the outline graph, sorted by
    /// `order_key` ascending. Returns only active (non-tombstoned)
    /// `Parent` tunnels where `target_drawer_id == parent_drawer_id`.
    fn outline_children(&self, _parent_drawer_id: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "outline_children not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Walk parent edges from `drawer_id` to the outline root.
    /// Returns the ancestor chain ordered root-first (deepest
    /// ancestor at index 0, `drawer_id` is NOT included).
    fn outline_ancestors(&self, _drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "outline_ancestors not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Move a child drawer under a new parent in the outline graph.
    /// Tombstones the existing `Parent` tunnel from `child_id` (if
    /// any) and creates a new one pointing at `new_parent_id` with
    /// the given `order_key`. Pass `None` for `new_parent_id` to
    /// make the child an outline root.
    #[allow(clippy::too_many_arguments)]
    fn reparent_drawer(
        &self,
        _child_id: &str,
        _new_parent_id: Option<&str>,
        _order_key: f64,
        _wing: &str,
        _room: &str,
        _added_by: &str,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "reparent_drawer not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // KGFact CRUD
    // -----------------------------------------------------------------

    /// Insert a kg-fact.
    fn add_kg_fact(&self, _fact: &KGFact) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_kg_fact not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Retire a kg-fact by transitioning its adjective_bitmap state to
    /// `State::Withdrawn` (raw 18). The row is preserved for audit
    /// purposes; `g_state_cluster` rises to 18 (RowState Cluster B) which
    /// excludes the fact from the active-recall filter
    /// (`g_state_cluster < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW`, the
    /// cluster-B floor of 16). Mirrors Swift `DrawerStore.withdrawKGFact(id:)`.
    fn withdraw_kg_fact(&self, _id: &str, _now: i64) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "withdraw_kg_fact not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a kg-fact by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_kg_fact(&self, _id: &str) -> Result<Option<KGFact>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_kg_fact not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All facts from a source drawer whose state cluster is below
    /// `RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW` (raw 16; excludes
    /// Cluster-B retired states and Cluster-C terminal states),
    /// ordered by `filed_at` ascending.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no facts for any drawer.
    fn kg_facts_for_drawer(&self, _source_drawer_id: &str) -> Result<Vec<KGFact>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "kg_facts_for_drawer not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Proposal CRUD
    // -----------------------------------------------------------------

    /// Insert a proposal. The lattice anchor is required per cookbook
    /// §2.7 (I-16): an empty `udc_code` is rejected with
    /// `LocusKitError::InvalidContent` before the insert. `target_row_id`
    /// is NOT validated non-empty — a brand-new-object proposal has no
    /// existing target row.
    fn add_proposal(&self, _proposal: &Proposal) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_proposal not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a proposal by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_proposal(&self, _id: &str) -> Result<Option<Proposal>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_proposal not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All proposals targeting a given row, ordered by `filed_at`
    /// ascending. Resolves through the `idx_proposals_target` index.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn proposals_for_target(&self, _target_row_id: &str) -> Result<Vec<Proposal>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "proposals_for_target not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Association CRUD
    // -----------------------------------------------------------------

    /// Insert an association. The edge endpoints and `added_by` are
    /// required (mirroring `add_tunnel`), and the lattice anchor is
    /// required per cookbook §2.7 (I-16): an empty `udc_code` is rejected
    /// with `LocusKitError::InvalidContent` before the insert.
    fn add_association(&self, _association: &Association) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_association not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch an association by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_association(&self, _id: &str) -> Result<Option<Association>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_association not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned associations from a source wing/room pair,
    /// ordered by `filed_at` ascending. Resolves through
    /// `idx_associations_source`.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn associations_from(
        &self,
        _wing: &str,
        _room: &str,
    ) -> Result<Vec<Association>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "associations_from not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned associations to a target wing/room pair, ordered
    /// by `filed_at` ascending. Resolves through `idx_associations_target`.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn associations_to(&self, _wing: &str, _room: &str) -> Result<Vec<Association>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "associations_to not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // LearnedReference CRUD
    // -----------------------------------------------------------------

    /// Insert a learned reference. `handle` and `added_by` are required, and
    /// the lattice anchor is required per cookbook §2.7 (I-16): an empty
    /// `udc_code` is rejected with `LocusKitError::InvalidContent` before the
    /// insert.
    fn add_learned_reference(&self, _reference: &LearnedReference) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_learned_reference not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a learned reference by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_learned_reference(&self, _id: &str) -> Result<Option<LearnedReference>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_learned_reference not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned references learned from a source catalog entry,
    /// ordered by `filed_at` ascending. Resolves through
    /// `idx_learned_references_source`.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn learned_references_from_source(
        &self,
        _source_catalog_id: &str,
    ) -> Result<Vec<LearnedReference>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "learned_references_from_source not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Source catalog CRUD
    // -----------------------------------------------------------------

    /// Insert a source catalog entry. `handle` and `added_by` are required,
    /// and the lattice anchor is required per cookbook §2.7 (I-16): an empty
    /// `udc_code` is rejected with `LocusKitError::InvalidContent` before the
    /// insert. The genuine anchor recorded here is what the `learn` verb
    /// copies onto each `LearnedReference`.
    fn add_source_catalog_entry(
        &self,
        _entry: &SourceCatalogEntry,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_source_catalog_entry not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a source catalog entry by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_source_catalog_entry(
        &self,
        _id: &str,
    ) -> Result<Option<SourceCatalogEntry>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_source_catalog_entry not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch the source catalog entry whose `handle` matches, if any.
    /// Resolves through `idx_source_catalog_handle` — the learn verb's
    /// source-resolution probe.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn source_catalog_entry_for_handle(
        &self,
        _handle: &str,
    ) -> Result<Option<SourceCatalogEntry>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "source_catalog_entry_for_handle not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Diary CRUD
    // -----------------------------------------------------------------

    /// Insert a diary entry.
    fn add_diary_entry(&self, _entry: &DiaryEntry) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_diary_entry not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a diary entry by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_diary_entry(&self, _id: &str) -> Result<Option<DiaryEntry>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_diary_entry not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Most-recent N non-tombstoned entries for an agent, newest first.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn read_diary(
        &self,
        _agent_name: &str,
        _last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "read_diary not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Most-recent N non-tombstoned entries for an agent in a wing.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn read_diary_in_wing(
        &self,
        _agent_name: &str,
        _wing: &str,
        _last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "read_diary_in_wing not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Recall trace CRUD
    // -----------------------------------------------------------------

    /// Insert a recall-trace row.
    fn insert_recall_trace(&self, _item: &RecallTraceItem) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "insert_recall_trace not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a recall-trace row by id. Returns `None` on miss.
    ///
    /// ## Default impl — fail-loud, never silently missing
    fn get_recall_trace(&self, _id: &str) -> Result<Option<RecallTraceItem>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "get_recall_trace not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All trace rows whose `recalled_at` is at or after `since`,
    /// ordered ascending (oldest first). `since` is an ISO8601 string
    /// matching the schema's TEXT timestamp; the in-memory store
    /// compares strings lexicographically, which is correct for the
    /// canonical ISO8601 format the schema enforces.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no recall trace history.
    fn recall_trace_since(&self, _since: &str) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "recall_trace_since not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Trace rows whose `recalled_at` falls in `[since, now]` (both
    /// bounds inclusive), ordered ascending. Both parameters are ISO8601
    /// strings. The dreaming daemon calls this in step 1 to build the
    /// reward map for one tick: rows outside `now` are excluded so future
    /// rows are never pulled into a past cycle. Mirrors Swift
    /// `DrawerStore.recentRecallTraces(since:now:)`.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently returning zero reward rows to the dreaming daemon.
    fn recent_recall_traces(
        &self,
        _since: &str,
        _now: &str,
    ) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "recent_recall_traces not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Mark a trace row's `used` flag (bit 0 of `operational_bitmap`).
    /// Idempotent on already-marked rows. Returns
    /// `LocusKitError::RecallTraceItemNotFound` when `id` is absent.
    fn mark_recall_trace_used(&self, _id: &str, _now: i64) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "mark_recall_trace_used not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Delete recall-trace rows whose `recalled_at` is strictly before
    /// `cutoff`. Returns the number of rows deleted.
    ///
    /// Called by the dreaming daemon's reward sweep (after step 1) so stale
    /// rows do not accumulate indefinitely. `cutoff` is an ISO8601 string
    /// matching the schema's TEXT `recalledAt` column; the comparison is
    /// `recalledAt < cutoff`, which is a lexicographic `<` on canonical UTC
    /// ISO8601 strings — equivalent to numeric less-than on the timestamps
    /// (the fleet date-storage rule guarantees UTC). Mirrors Swift
    /// `DrawerStore.pruneRecallTraces(olderThan:)`.
    ///
    /// The default returns an explicit error rather than a silent `Ok(0)`:
    /// a store that cannot prune must say so, not pretend it pruned. Backends
    /// that persist trace rows override this; minimal fakes that never write
    /// trace rows do not call it.
    ///
    /// - Parameter `cutoff`: rows with `recalledAt < cutoff` are deleted.
    /// - Returns: the number of rows deleted.
    fn prune_recall_traces(&self, _cutoff: &str) -> Result<usize, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "prune_recall_traces not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Bulk-mark recall-trace rows for a drawer `target` in the window
    /// `[since, now]` (both ISO8601 TEXT strings, inclusive bounds).
    ///
    /// Sets bit 0 (`flag_used`) on every row where `target == target` AND
    /// `recalledAt ∈ [since, now]` AND bit 0 is currently unset. Rows
    /// already marked are skipped — idempotent. Returns the number of rows
    /// whose bit was actually flipped. An unknown `target` returns `Ok(0)`.
    ///
    /// This is the production reward-wiring path: the ARIA boundary decides
    /// "drawer D was used" and calls this via GLK; the substrate flips
    /// whatever live trace rows exist for that drawer. The per-row
    /// `mark_recall_trace_used(id, now)` remains as the tested primitive;
    /// this method is the production path. Mirrors Swift
    /// `DrawerStore.markRecallTracesUsed(target:since:now:)`.
    fn mark_recall_traces_used(
        &self,
        _target: &str,
        _since: &str,
        _now: &str,
    ) -> Result<usize, LocusKitError> {
        // Default returns an explicit error: a backend that cannot mark
        // must say so rather than silently returning 0.
        Err(LocusKitError::DatabaseUnavailable(
            "mark_recall_traces_used not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Count all rows in the `recall_trace` table.
    ///
    /// Returns the total row count across all targets and windows, regardless
    /// of `used` status. An empty table returns `Ok(0)`. Used by estate-status
    /// reporting so trace-table growth is observable. Mirrors Swift
    /// `DrawerStore.countRecallTraces()`.
    ///
    /// ## Default impl — fail-loud, never silently zero
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have zero trace rows, which would
    /// give false estate-status observability (math-provenance gate
    /// FINDING-3, 2026-06-12).
    fn count_recall_traces(&self) -> Result<usize, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "count_recall_traces not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Count raw rows in the `drawers` table via SQL `COUNT(*)`, bypassing
    /// all row-decode logic. Corrupt rows (e.g. a poison timestamp) are still
    /// counted because `COUNT(*)` never reads column values. Used by the
    /// vault-export fail-loud path to distinguish "estate is genuinely empty"
    /// from "recall returned 0 because all rows are corrupt."
    ///
    /// An estate with no captured drawers returns `Ok(0)`. Mirrors Swift
    /// `DrawerStore.countDrawerRows()`.
    ///
    /// ## Default impl — fail-loud, never silently zero
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently reporting zero rows, which would mask a bricked
    /// corpus as an empty one and allow a silent 0-note vault export.
    fn count_drawer_rows(&self) -> Result<usize, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "count_drawer_rows not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Count all rows in the `tunnels` table using `COUNT(*)` — O(1), no
    /// row-decode. Used by the composite topology-change signature
    /// (`GeniusLocusKit.topologyChangeSignature`) so the autonomic governor
    /// detects standalone tunnel writes that produce no audit event. Mirrors
    /// Swift `DrawerStore.countTunnelRows()`.
    ///
    /// ## Default impl — fail-loud, never silently zero
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently reporting zero tunnels, which would mask a
    /// tunnel-rich estate as unchanged to the governor.
    fn count_tunnel_rows(&self) -> Result<usize, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "count_tunnel_rows not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Count all rows in the `kg_facts` table using `COUNT(*)` — O(1), no
    /// row-decode. Used by the composite topology-change signature
    /// (`GeniusLocusKit.topologyChangeSignature`) so the autonomic governor
    /// detects standalone KG-fact writes that produce no audit event. Mirrors
    /// Swift `DrawerStore.countKGFactRows()`.
    ///
    /// ## Default impl — fail-loud, never silently zero
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently reporting zero facts, which would mask a
    /// fact-rich estate as unchanged to the governor.
    fn count_kg_fact_rows(&self) -> Result<usize, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "count_kg_fact_rows not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Audit reads
    // -----------------------------------------------------------------

    /// The row's sealed audit events (substrate form), in append order —
    /// the audit-log source of truth that replaces bitmap_audit reads.
    /// `row_id` is a UUID string per DECISION_ROW_IDENTITY_UUID.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no audit history for any row
    /// (which would make the audit trail invisible rather than absent).
    fn audit_events_for_row(
        &self,
        _row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "audit_events_for_row not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Tombstoned drawers that have NO sealed "tombstone" or "expungeOrphan"
    /// audit event — the integrity-sweep input set.
    ///
    /// A row is in this set when:
    ///   - `tombstoned_at` is non-null (storage expunge step 1 completed), AND
    ///   - the audit log contains neither a `"tombstone"` event nor an
    ///     `"expungeOrphan"` event for that row (the audit step, step 3, never ran).
    ///
    /// This covers two crash-window scenarios:
    ///   1. The process crashed between step 1 (tombstone) and step 3 (audit seal).
    ///   2. Both step-2 and the orphan-seal write failed (double-failure),
    ///      leaving the row tombstoned with no audit record.
    ///
    /// The `run_expunge_integrity_sweep` maintenance function queries this set,
    /// re-attempts the cross-kit vector+corpus delete for each row, and seals
    /// the appropriate audit (expunge-complete on success, expungeOrphan if the
    /// re-attempt still fails). The query must be bounded — implementations
    /// MUST NOT issue a full-table scan per call when a JOIN-based or indexed
    /// query is possible.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have zero orphans — which would make
    /// the integrity sweep a silent no-op on an un-overridden backend, masking
    /// genuine orphans rather than surfacing them.
    fn tombstoned_rows_without_expunge_audit(&self) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "tombstoned_rows_without_expunge_audit not implemented for this DrawerStore impl"
                .to_string(),
        ))
    }

    /// Zero the `content` column for every row in the `drawers` table.
    ///
    /// Called by `GLKCoordinator::destroy` to erase all drawer content blobs
    /// from LocusKit's SQLite storage as part of the estate destruction
    /// sequence (destruction contract, secfix/ws2-coredelete §Cluster E).
    /// Must be called BEFORE `close()` so the storage connection is still
    /// open when the bulk UPDATE runs.
    ///
    /// Does NOT delete the manifest, audit events, or other metadata tables —
    /// those remain as a forensic record. The SQLite file itself is removed by
    /// the application layer (moot-mgr) after the GLK destroy call returns.
    ///
    /// ## Default impl — fail-loud
    ///
    /// Backends that do not override this return `DatabaseUnavailable` rather
    /// than silently skipping the wipe. A silent no-op would leave content
    /// blobs in place, violating the destruction contract.
    fn wipe_all_content(&self) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "wipe_all_content not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Append an `"expungeOrphan"` audit event synthesized from the drawer's
    /// current on-disk state. Used by `run_expunge_integrity_sweep` when the
    /// original step-1 gate event is unavailable (crash-window recovery).
    ///
    /// Unlike `seal_expunge_orphan_audit` (which derives the event from the
    /// in-memory gate event), this path reads the drawer's current bitmaps and
    /// lattice anchor directly from the store to reconstruct the event. The
    /// resulting event records the tombstoned state accurately; the "before"
    /// bitmaps are approximated as the current (post-tombstone) state because
    /// the pre-tombstone snapshot was lost in the crash. The approximation is
    /// acceptable for forensic completeness: the audit records the expunge
    /// happened, and the vector orphan state is recorded.
    ///
    /// ## Default impl — fail-loud
    fn seal_expunge_orphan_for_sweep(
        &self,
        _drawer_id: &str,
        _changed_by: &str,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "seal_expunge_orphan_for_sweep not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Summary surface
    // -----------------------------------------------------------------

    /// Wing-level taxonomy: one `WingSummary` per wing over
    /// non-tombstoned drawers.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// A backend that does not override this returns `DatabaseUnavailable`
    /// rather than silently appearing to have no wings — which would cause
    /// navigation and taxonomy consumers to display an empty estate.
    fn list_wings(&self) -> Result<Vec<WingSummary>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "list_wings not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Room-level taxonomy. `wing = None` returns every wing's rooms;
    /// otherwise restricted to that wing.
    ///
    /// ## Default impl — fail-loud, never silently empty
    fn list_rooms(&self, _wing: Option<&str>) -> Result<Vec<RoomSummary>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "list_rooms not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Wing-level projection, named distinctly from `list_wings`
    /// because future revisions extend the response shape with diary
    /// counts. Today it returns the same value as `list_wings`.
    fn taxonomy(&self) -> Result<Vec<WingSummary>, LocusKitError> {
        self.list_wings()
    }

    // -----------------------------------------------------------------
    // Unfiltered full-corpus reads (recall surface)
    // -----------------------------------------------------------------

    /// All non-tombstoned proposals estate-wide, ordered by `filed_at`
    /// ascending. The MCP recall surface calls this to list every pending
    /// or resolved proposal without a target-row filter.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real scan.
    /// A silent-empty default would cause the MCP recall surface to
    /// return zero proposals (math-provenance gate FINDING-3, 2026-06-12).
    fn all_proposals(&self) -> Result<Vec<Proposal>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "all_proposals not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned associations estate-wide, ordered by `filed_at`
    /// ascending. The MCP recall surface calls this when no source
    /// wing/room filter is needed.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real scan.
    fn all_associations(&self) -> Result<Vec<Association>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "all_associations not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned learned references estate-wide, ordered by
    /// `filed_at` ascending. The MCP recall surface calls this when no
    /// source catalog filter is needed.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real scan.
    fn all_learned_references(&self) -> Result<Vec<LearnedReference>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "all_learned_references not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All kg-facts estate-wide whose state cluster is below
    /// `RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW` (raw 16; excludes
    /// Cluster-B retired states and Cluster-C terminal states),
    /// ordered by `filed_at` ascending. Mirrors `kg_facts_for_drawer`
    /// but without the source-drawer predicate.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real scan.
    /// A silent-empty default would cause recall to return zero KG facts
    /// from a populated estate (math-provenance gate FINDING-3, 2026-06-12).
    fn all_kg_facts(&self) -> Result<Vec<KGFact>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "all_kg_facts not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All kg-facts estate-wide regardless of lifecycle state — active AND
    /// retired — ordered by `filed_at` ascending.
    ///
    /// No state-cluster predicate is applied; every row ever filed is returned
    /// so callers can trace how structured knowledge evolved over time.  Each
    /// returned `KGFact` carries its `adjective_bitmap` intact; the lifecycle
    /// state is `adjective_bitmap & 0x3F`, the raw RowState — values below
    /// `RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW` (16) are Cluster-A active,
    /// values at or above it are retired (see `Adjectives::State`).
    ///
    /// Use `all_kg_facts()` when you need only the currently-active set.
    /// Use this method only when you need the full history, e.g. to power
    /// `moot_fact_timeline`.
    ///
    /// Peer of the Swift `DrawerStore.allKGFactsIncludingRetired()`.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends (InMemory, SQLite, Postgres) override this
    /// with a real implementation. The default returns an explicit error so any
    /// future backend that forgets to implement this method fails loud instead of
    /// silently returning zero facts (math-provenance gate FINDING-3, 2026-06-12).
    fn all_kg_facts_including_retired(&self) -> Result<Vec<KGFact>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "all_kg_facts_including_retired not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// All non-tombstoned diary entries estate-wide, ordered by `filed_at`
    /// ascending. The MCP recall surface calls this when no agent-name
    /// filter is needed.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real scan.
    fn all_diary_entries(&self) -> Result<Vec<DiaryEntry>, LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "all_diary_entries not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Temporal reads
    // -----------------------------------------------------------------

    /// Returns the `Fingerprint256` of every non-tombstoned drawer whose
    /// effective capture time (`event_time`, ING-01 two-clock backfill)
    /// falls in `[start_epoch, end_epoch]` (both inclusive, epoch seconds),
    /// in ascending row-id order.
    ///
    /// Feeds the MomentSummary OR-fold (substrate math §15.1 predicate π₁
    /// — capture-time window membership).
    ///
    /// - `start_epoch`: window lower bound (inclusive), epoch seconds.
    /// - `end_epoch`: window upper bound (inclusive), epoch seconds.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real indexed scan.
    /// A silent-empty default would cause MomentSummary to fold zero
    /// fingerprints and produce a silent zero-bit result instead of a
    /// real OR-fold (math-provenance gate FINDING-3, 2026-06-12).
    fn fingerprints_captured_in(
        &self,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<Fingerprint256>, LocusKitError> {
        let _ = (start_epoch, end_epoch);
        Err(LocusKitError::DatabaseUnavailable(
            "fingerprints_captured_in not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Returns one bool per time bucket (oldest first): whether any
    /// non-tombstoned drawer captured in that bucket has the given
    /// fingerprint bit set.
    ///
    /// Feeds the FFT rhythm spectrum (substrate math §15.5). Default
    /// returns empty — backends override.
    ///
    /// Bucket layout (oldest first, index `i` ∈ `[0, bucket_count)`):
    ///   `lower_i = ending_at − (bucket_count − i) × bucket_seconds`
    ///   `upper_i = ending_at − (bucket_count − i − 1) × bucket_seconds`
    /// Interval `[lower_i, upper_i)` — lower inclusive, upper exclusive —
    /// so a capture on a shared boundary belongs to the later (larger-time)
    /// bucket. The final bucket uses `[lower, ending_at]` (inclusive).
    ///
    /// Bit layout: block0 covers bits 0–63, block1 covers 64–127,
    /// block2 covers 128–191, block3 covers 192–255.
    ///
    /// - `bit`: fingerprint bit index in `[0, 255]`.
    /// - `bucket_seconds`: width of each bucket in seconds; must be ≥ 1.
    /// - `bucket_count`: number of buckets; returns `[]` when 0.
    /// - `ending_at`: upper bound of the newest bucket (caller-supplied
    ///   deterministic clock — never read system time inside the kit).
    /// - Returns `Err(LocusKitError::InvalidContent)` when `bit > 255`
    ///   or `bucket_seconds < 1`.
    ///
    /// ## Default impl — fail-loud, never silently empty
    ///
    /// All three production backends override this with a real time-bucketed
    /// scan. A silent-empty default would cause FFT rhythm-spectrum callers
    /// to receive an all-false series instead of a real signal
    /// (math-provenance gate FINDING-3, 2026-06-12).
    fn fingerprint_bit_series(
        &self,
        bit: usize,
        bucket_seconds: i64,
        bucket_count: usize,
        ending_at: i64,
    ) -> Result<Vec<bool>, LocusKitError> {
        let _ = (bit, bucket_seconds, bucket_count, ending_at);
        Err(LocusKitError::DatabaseUnavailable(
            "fingerprint_bit_series not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Every room-level container fingerprint (room non-empty) with its
    /// bitwise-OR aggregate over the container's active drawers.
    ///
    /// The room/wing OR aggregates the recall pruner already maintains
    /// (`ContainerFingerprintStore`, spec § 11.5). The maintenance
    /// daemon's fingerprint-drift signal reads these as the live
    /// fingerprint per scope; the kit owns the store, so this is the
    /// kit-level accessor GLK forwards to rather than reaching around to
    /// the store's storage directly (B-1).
    ///
    /// ## Required, no default — compile-time enforcement
    ///
    /// All three production backends implement this with a real scan of the
    /// `container_fingerprints` table. A silent-empty default would cause the
    /// maintenance daemon's fingerprint-drift signal to silently see zero
    /// containers and skip drift detection entirely
    /// (math-provenance gate FINDING-3, 2026-06-12). Per Bob's SDK ruling, a
    /// backend that forgets this read must fail to COMPILE rather than at
    /// runtime — so this is a required trait method with no default.
    fn room_level_fingerprints(&self) -> Result<Vec<RoomLevelEntry>, LocusKitError>;

    /// OR one drawer's three bitmap fields into its room-level and
    /// wing-level container-fingerprint rows (spec § 11.5).
    ///
    /// ## Add-coverage guarantee (§11.5 Option B)
    ///
    /// Per-add coverage is now structurally guaranteed: `add_drawer` folds
    /// the fingerprint update INSIDE itself. This method is retained for
    /// rebuild/backfill paths (`rebuild_container_fingerprints`) and for
    /// callers that need to OR a fingerprint in independently of an
    /// `add_drawer` call (e.g. migration tooling, backfill sweeps). Callers
    /// that want per-drawer coverage MUST use `add_drawer` — calling
    /// `add_drawer` then `or_in_container_fingerprint` separately would
    /// double-OR, which is harmless (OR is idempotent) but wasteful.
    ///
    /// The kit owns the `ContainerFingerprintStore`, so the maintenance write
    /// goes through this kit-level hook rather than the verb surface
    /// reaching around to the store's storage directly (B-1).
    ///
    /// `now` is the deterministic epoch-seconds clock threaded from the
    /// verb boundary.
    ///
    /// Default is a no-op — backends without a container aggregate (the
    /// trait-default test fakes) carry no fingerprint table to maintain.
    /// The storage-backed core overrides to OR into `container_fingerprints`.
    fn or_in_container_fingerprint(
        &self,
        wing: &str,
        room: &str,
        adjective: i64,
        operational: i64,
        provenance: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let _ = (wing, room, adjective, operational, provenance, now);
        Ok(())
    }

    /// Rebuild the entire container-fingerprint aggregate from the active
    /// drawer set so it covers every active container (spec § 11.5
    /// soundness: the aggregate must cover every active row or pruning is
    /// unsound). Called once at estate open, mirroring Swift `Estate.open`
    /// /`create`'s `containerFP.rebuildAll(activeDrawers:)`.
    ///
    /// `now` is the deterministic epoch-seconds clock.
    ///
    /// Default is a no-op for backends without a container aggregate. The
    /// storage-backed core overrides to recompute every room and wing row.
    fn rebuild_container_fingerprints(&self, now: i64) -> Result<(), LocusKitError> {
        let _ = now;
        Ok(())
    }

    /// Look up one container fingerprint by (wing, room). The wing-level
    /// rollup row uses `room == ""` (`ContainerFingerprintStore::WING_ROLLUP_ROOM`).
    ///
    /// Returns `Ok(None)` when no row exists for that container — an absent
    /// aggregate is not an empty one; the recall path treats a missing rollup
    /// as surviving (sound: an absent aggregate must not prune, spec § 11.5).
    ///
    /// Used by `recall`'s fingerprint-pruning path to check the wing-level
    /// rollup before scanning individual rooms, mirroring Swift's
    /// `containerFP.get(wing:room:)` call in `Estate.liveRows`. The kit
    /// owns the store so this goes through the trait surface rather than the
    /// verb surface reaching around directly (B-1).
    ///
    /// Default returns `Ok(None)` — backends without a container aggregate
    /// treat every container as surviving, which is sound (no false prunes).
    fn get_container_fingerprint(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Option<crate::container_fingerprint_store::ContainerFingerprint>, LocusKitError>
    {
        let _ = (wing, room);
        Ok(None)
    }
}

// ── Blanket impl: Arc<dyn DrawerStore> as a DrawerStore ──────────────────────
//
// Allows callers that hold a type-erased `Arc<dyn DrawerStore>` to pass it
// directly into generic functions and types that require `S: DrawerStore`.
// The `AutonomicGovernor` in ARIA_MCP uses this: it receives the registry's
// `Arc<dyn DrawerStore>` at construction and passes it to `EstateDreamingSink`
// and `EstateMaintenanceSink`, both of which are generic over `S: DrawerStore`.
// Every method delegates to the inner trait object via `self.as_ref()`.
//
// `DrawerStore` is object-safe (no generic methods, no `Self`-sized bounds),
// so this blanket impl is sound. `Arc<dyn DrawerStore>` is `Send + Sync`
// because `DrawerStore: Send + Sync` — the underlying store is the same
// concrete object either way.
#[allow(clippy::too_many_arguments)]
impl DrawerStore for std::sync::Arc<dyn DrawerStore> {
    fn storage(&self) -> Option<Arc<dyn Storage>> {
        self.as_ref().storage()
    }
    fn resolve_node_names(
        &self,
        parent_node_ids: &[String],
    ) -> Result<BTreeMap<String, (String, String)>, LocusKitError> {
        self.as_ref().resolve_node_names(parent_node_ids)
    }
    fn read_manifest(&self) -> Result<ManifestValues, LocusKitError> {
        self.as_ref().read_manifest()
    }
    fn set_meta(&self, key: &str, value: &str) -> Result<(), LocusKitError> {
        self.as_ref().set_meta(key, value)
    }
    fn get_meta(&self, key: &str) -> Result<Option<String>, LocusKitError> {
        self.as_ref().get_meta(key)
    }
    fn add_drawer(&self, drawer: &Drawer, now: i64) -> Result<(), LocusKitError> {
        self.as_ref().add_drawer(drawer, now)
    }
    fn get_drawer(&self, id: &str) -> Result<Option<Drawer>, LocusKitError> {
        self.as_ref().get_drawer(id)
    }
    fn drawers_in_wing(&self, wing: &str) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().drawers_in_wing(wing)
    }
    fn drawers_in_wing_room(&self, wing: &str, room: &str) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().drawers_in_wing_room(wing, room)
    }
    fn drawers_by_source(&self, source_file: &str) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().drawers_by_source(source_file)
    }
    fn all_drawers(&self) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().all_drawers()
    }
    fn all_drawers_bounded(&self, limit: Option<usize>) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().all_drawers_bounded(limit)
    }
    fn all_drawers_bounded_projected(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().all_drawers_bounded_projected(limit)
    }
    fn active_drawers_after(
        &self,
        after_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().active_drawers_after(after_id, limit)
    }
    fn all_drawers_bounded_desc(&self, limit: Option<usize>) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().all_drawers_bounded_desc(limit)
    }
    fn all_drawers_bounded_projected_desc(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        self.as_ref().all_drawers_bounded_projected_desc(limit)
    }
    fn drawer_ids(&self) -> Result<Vec<RowID>, LocusKitError> {
        self.as_ref().drawer_ids()
    }
    fn mutate_provenance(
        &self,
        drawer_id: &str,
        new_provenance: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref().mutate_provenance(drawer_id, new_provenance, changed_by, reason, now)
    }
    fn mutate_adjective(
        &self,
        drawer_id: &str,
        new_adjective: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref().mutate_adjective(drawer_id, new_adjective, changed_by, reason, now)
    }
    fn mutate_operational(
        &self,
        drawer_id: &str,
        new_operational: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref().mutate_operational(drawer_id, new_operational, changed_by, reason, now)
    }
    fn mutate_state(
        &self,
        drawer_id: &str,
        new_state: State,
        via: RowVerb,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref().mutate_state(drawer_id, new_state, via, changed_by, reason, now)
    }
    fn lineage_chain(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        self.as_ref().lineage_chain(drawer_id)
    }
    fn expunge_gated(
        &self,
        drawer_id: &str,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
        seal_audit: bool,
    ) -> Result<substrate_lib::verbs::AuditEvent, LocusKitError> {
        self.as_ref().expunge_gated(drawer_id, changed_by, reason, now, seal_audit)
    }
    fn seal_expunge_audit(
        &self,
        event: &substrate_lib::verbs::AuditEvent,
    ) -> Result<(), LocusKitError> {
        self.as_ref().seal_expunge_audit(event)
    }
    fn seal_expunge_orphan_audit(
        &self,
        drawer_id: &str,
        success_event: &substrate_lib::verbs::AuditEvent,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref().seal_expunge_orphan_audit(drawer_id, success_event, changed_by, now)
    }
    fn reanchor_gated(
        &self,
        drawer_id: &str,
        to_room: Option<&str>,
        to_wing: Option<&str>,
        to_lattice: Option<crate::estate_types::LatticeAnchor>,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref().reanchor_gated(drawer_id, to_room, to_wing, to_lattice, changed_by, reason, now)
    }
    fn add_tunnel(&self, tunnel: &Tunnel) -> Result<(), LocusKitError> {
        self.as_ref().add_tunnel(tunnel)
    }
    fn get_tunnel(&self, id: &str) -> Result<Option<Tunnel>, LocusKitError> {
        self.as_ref().get_tunnel(id)
    }
    fn tunnels_from_wing(&self, wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        self.as_ref().tunnels_from_wing(wing)
    }
    fn tunnels_from_wing_room(&self, wing: &str, room: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        self.as_ref().tunnels_from_wing_room(wing, room)
    }
    fn tunnels_to_wing(&self, wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        self.as_ref().tunnels_to_wing(wing)
    }
    fn all_tunnels(&self) -> Result<Vec<Tunnel>, LocusKitError> {
        self.as_ref().all_tunnels()
    }
    fn all_active_tunnels(&self) -> Result<Vec<Tunnel>, LocusKitError> {
        self.as_ref().all_active_tunnels()
    }
    fn retire_tunnel(&self, tunnel_id: &str, changed_by: &str, now: i64) -> Result<(), LocusKitError> {
        self.as_ref().retire_tunnel(tunnel_id, changed_by, now)
    }
    fn unretire_tunnel(&self, tunnel_id: &str, changed_by: &str, now: i64) -> Result<(), LocusKitError> {
        self.as_ref().unretire_tunnel(tunnel_id, changed_by, now)
    }
    fn add_kg_fact(&self, fact: &KGFact) -> Result<(), LocusKitError> {
        self.as_ref().add_kg_fact(fact)
    }
    fn withdraw_kg_fact(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.as_ref().withdraw_kg_fact(id, now)
    }
    fn get_kg_fact(&self, id: &str) -> Result<Option<KGFact>, LocusKitError> {
        self.as_ref().get_kg_fact(id)
    }
    fn kg_facts_for_drawer(&self, source_drawer_id: &str) -> Result<Vec<KGFact>, LocusKitError> {
        self.as_ref().kg_facts_for_drawer(source_drawer_id)
    }
    fn add_proposal(&self, proposal: &Proposal) -> Result<(), LocusKitError> {
        self.as_ref().add_proposal(proposal)
    }
    fn get_proposal(&self, id: &str) -> Result<Option<Proposal>, LocusKitError> {
        self.as_ref().get_proposal(id)
    }
    fn proposals_for_target(&self, target_row_id: &str) -> Result<Vec<Proposal>, LocusKitError> {
        self.as_ref().proposals_for_target(target_row_id)
    }
    fn add_association(&self, association: &Association) -> Result<(), LocusKitError> {
        self.as_ref().add_association(association)
    }
    fn get_association(&self, id: &str) -> Result<Option<Association>, LocusKitError> {
        self.as_ref().get_association(id)
    }
    fn associations_from(&self, wing: &str, room: &str) -> Result<Vec<Association>, LocusKitError> {
        self.as_ref().associations_from(wing, room)
    }
    fn associations_to(&self, wing: &str, room: &str) -> Result<Vec<Association>, LocusKitError> {
        self.as_ref().associations_to(wing, room)
    }
    fn add_learned_reference(&self, reference: &LearnedReference) -> Result<(), LocusKitError> {
        self.as_ref().add_learned_reference(reference)
    }
    fn get_learned_reference(&self, id: &str) -> Result<Option<LearnedReference>, LocusKitError> {
        self.as_ref().get_learned_reference(id)
    }
    fn learned_references_from_source(
        &self,
        source_catalog_id: &str,
    ) -> Result<Vec<LearnedReference>, LocusKitError> {
        self.as_ref().learned_references_from_source(source_catalog_id)
    }
    fn add_source_catalog_entry(
        &self,
        entry: &SourceCatalogEntry,
    ) -> Result<(), LocusKitError> {
        self.as_ref().add_source_catalog_entry(entry)
    }
    fn get_source_catalog_entry(
        &self,
        id: &str,
    ) -> Result<Option<SourceCatalogEntry>, LocusKitError> {
        self.as_ref().get_source_catalog_entry(id)
    }
    fn source_catalog_entry_for_handle(
        &self,
        handle: &str,
    ) -> Result<Option<SourceCatalogEntry>, LocusKitError> {
        self.as_ref().source_catalog_entry_for_handle(handle)
    }
    fn add_diary_entry(&self, entry: &DiaryEntry) -> Result<(), LocusKitError> {
        self.as_ref().add_diary_entry(entry)
    }
    fn get_diary_entry(&self, id: &str) -> Result<Option<DiaryEntry>, LocusKitError> {
        self.as_ref().get_diary_entry(id)
    }
    fn read_diary(
        &self,
        agent_name: &str,
        last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        self.as_ref().read_diary(agent_name, last_n)
    }
    fn read_diary_in_wing(
        &self,
        agent_name: &str,
        wing: &str,
        last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        self.as_ref().read_diary_in_wing(agent_name, wing, last_n)
    }
    fn insert_recall_trace(&self, item: &RecallTraceItem) -> Result<(), LocusKitError> {
        self.as_ref().insert_recall_trace(item)
    }
    fn insert_recall_traces(&self, items: &[RecallTraceItem]) -> Result<(), LocusKitError> {
        self.as_ref().insert_recall_traces(items)
    }
    fn get_recall_trace(&self, id: &str) -> Result<Option<RecallTraceItem>, LocusKitError> {
        self.as_ref().get_recall_trace(id)
    }
    fn recall_trace_since(&self, since: &str) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        self.as_ref().recall_trace_since(since)
    }
    fn recent_recall_traces(
        &self,
        since: &str,
        now: &str,
    ) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        self.as_ref().recent_recall_traces(since, now)
    }
    fn mark_recall_trace_used(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.as_ref().mark_recall_trace_used(id, now)
    }
    fn prune_recall_traces(&self, cutoff: &str) -> Result<usize, LocusKitError> {
        self.as_ref().prune_recall_traces(cutoff)
    }
    fn mark_recall_traces_used(
        &self,
        target: &str,
        since: &str,
        now: &str,
    ) -> Result<usize, LocusKitError> {
        self.as_ref().mark_recall_traces_used(target, since, now)
    }
    fn count_recall_traces(&self) -> Result<usize, LocusKitError> {
        self.as_ref().count_recall_traces()
    }
    fn audit_events_for_row(
        &self,
        row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        self.as_ref().audit_events_for_row(row_id)
    }
    fn tombstoned_rows_without_expunge_audit(&self) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.as_ref().tombstoned_rows_without_expunge_audit()
    }
    fn seal_expunge_orphan_for_sweep(
        &self,
        drawer_id: &str,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref().seal_expunge_orphan_for_sweep(drawer_id, changed_by, now)
    }
    fn list_wings(&self) -> Result<Vec<WingSummary>, LocusKitError> {
        self.as_ref().list_wings()
    }
    fn list_rooms(&self, wing: Option<&str>) -> Result<Vec<RoomSummary>, LocusKitError> {
        self.as_ref().list_rooms(wing)
    }
    fn taxonomy(&self) -> Result<Vec<WingSummary>, LocusKitError> {
        self.as_ref().taxonomy()
    }
    fn all_proposals(&self) -> Result<Vec<Proposal>, LocusKitError> {
        self.as_ref().all_proposals()
    }
    fn all_associations(&self) -> Result<Vec<Association>, LocusKitError> {
        self.as_ref().all_associations()
    }
    fn all_learned_references(&self) -> Result<Vec<LearnedReference>, LocusKitError> {
        self.as_ref().all_learned_references()
    }
    fn all_kg_facts(&self) -> Result<Vec<KGFact>, LocusKitError> {
        self.as_ref().all_kg_facts()
    }
    fn all_kg_facts_including_retired(&self) -> Result<Vec<KGFact>, LocusKitError> {
        self.as_ref().all_kg_facts_including_retired()
    }
    fn all_diary_entries(&self) -> Result<Vec<DiaryEntry>, LocusKitError> {
        self.as_ref().all_diary_entries()
    }
    fn fingerprints_captured_in(
        &self,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<Fingerprint256>, LocusKitError> {
        self.as_ref().fingerprints_captured_in(start_epoch, end_epoch)
    }
    fn fingerprint_bit_series(
        &self,
        bit: usize,
        bucket_seconds: i64,
        bucket_count: usize,
        ending_at: i64,
    ) -> Result<Vec<bool>, LocusKitError> {
        self.as_ref()
            .fingerprint_bit_series(bit, bucket_seconds, bucket_count, ending_at)
    }
    fn room_level_fingerprints(&self) -> Result<Vec<RoomLevelEntry>, LocusKitError> {
        self.as_ref().room_level_fingerprints()
    }
    fn or_in_container_fingerprint(
        &self,
        wing: &str,
        room: &str,
        adjective: i64,
        operational: i64,
        provenance: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref()
            .or_in_container_fingerprint(wing, room, adjective, operational, provenance, now)
    }
    fn rebuild_container_fingerprints(&self, now: i64) -> Result<(), LocusKitError> {
        self.as_ref().rebuild_container_fingerprints(now)
    }
    fn get_container_fingerprint(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Option<crate::container_fingerprint_store::ContainerFingerprint>, LocusKitError>
    {
        self.as_ref().get_container_fingerprint(wing, room)
    }
    // P5-secfix: six methods whose trait defaults return a hard error were missing
    // from the Arc<dyn DrawerStore> blanket impl, so callers using the Arc surface
    // always got DatabaseUnavailable instead of delegating to the concrete backend.
    fn living_successor_in_lineage(
        &self,
        lineage_id: &str,
        excluding_id: &str,
    ) -> Result<Option<String>, LocusKitError> {
        self.as_ref().living_successor_in_lineage(lineage_id, excluding_id)
    }
    fn outline_children(&self, parent_drawer_id: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        self.as_ref().outline_children(parent_drawer_id)
    }
    fn outline_ancestors(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        self.as_ref().outline_ancestors(drawer_id)
    }
    #[allow(clippy::too_many_arguments)]
    fn reparent_drawer(
        &self,
        child_id: &str,
        new_parent_id: Option<&str>,
        order_key: f64,
        wing: &str,
        room: &str,
        added_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.as_ref()
            .reparent_drawer(child_id, new_parent_id, order_key, wing, room, added_by, now)
    }
    fn count_drawer_rows(&self) -> Result<usize, LocusKitError> {
        self.as_ref().count_drawer_rows()
    }
    fn wipe_all_content(&self) -> Result<(), LocusKitError> {
        self.as_ref().wipe_all_content()
    }
}
