//! SQLite-backed `DrawerStore` implementation.
//!
//! `SqliteDrawerStore` is a thin public newtype over `DrawerStoreCore` backed
//! by a `SqliteStorage` handle. All verb logic — drawer CRUD, supersession
//! cascade, bitmap mutation paths, tunnel / kg-fact / diary CRUD, recall
//! trace, audit reads, and summary projections — lives once in
//! `DrawerStoreCore`, which delegates every operation through its
//! `Arc<dyn Storage>` handle. Because `SqliteStorage` and `InMemoryStorage`
//! both implement the same `Storage` trait, the entire verb surface works
//! without duplication.
//!
//! ## Backend-identity rule
//!
//! `SqliteDrawerStore` constructs a `SqliteStorage` and hands it directly to
//! `DrawerStoreCore::new`. It does NOT wrap `InMemoryDrawerStore` — that
//! newtype allocates `InMemoryStorage` internally and wrapping it would be
//! semantically wrong (an in-memory estate inside a durable one). Backend
//! identity is visible at the construction site:
//!
//! - `InMemoryDrawerStore` = ephemeral, in-process `InMemoryStorage`
//! - `SqliteDrawerStore` = durable WAL-mode `SqliteStorage`
//!
//! Both newtypes delegate through the same `DrawerStoreCore`, so verb
//! behaviour is byte-identical across backends.
//!
//! ## Why a newtype rather than a type alias
//!
//! A type alias (`type SqliteDrawerStore = InMemoryDrawerStore`) would expose
//! the in-memory constructor as the public API. A newtype hides the inner
//! type, enforces the SQLite-specific constructor (`from_path`), and lets
//! callers import `SqliteDrawerStore` without coupling to
//! `DrawerStoreCore`'s or `InMemoryDrawerStore`'s existence.
//!
//! ## Schema invariants
//!
//! Inherited from `DrawerStoreCore`:
//! - Dates stored as TEXT ISO-8601 (never REAL). PersistenceKit's
//!   SQLite backend serialises `TypedValue::Timestamp` as an ISO-8601
//!   string via its `iso8601()` helper; the schema declares those
//!   columns as `TEXT` (schema invariant).
//! - Boolean state lives in `i64` bitmap columns, never `bool`
//!   columns. No `bool` columns are declared in the LocusKit schema.
//! - Forbidden adjective combinations (I-22 secret+exportable) are
//!   rejected by the write gate (`audit_gate::admit`) before any
//!   projection commits; enforced identically for both backends since
//!   the gate is substrate-level code, not backend-level.
//!
//! ## WAL mode
//!
//! `SqliteStorage::new` sets `PRAGMA journal_mode=WAL` and
//! `PRAGMA synchronous=NORMAL`, matching the spec's durability posture.
//! The connection is serialised behind an `Arc<Mutex<Inner>>` inside
//! `SqliteStorage`; no additional locking is needed here.

use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::DrawerStoreCore;
use crate::error::LocusKitError;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::SqliteStorage;
use std::sync::Arc;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLCGenerator;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// SqliteDrawerStore — WAL-mode durable backend.
// ---------------------------------------------------------------------------
//
// Two public constructors:
//
//   from_path       — opens a SQLite estate with the default EstateConfiguration
//                     (cache disabled, plaintext, HMM tagger). Used by tests and
//                     any caller that wants bare SQLite with no cache tier.
//
//   from_path_with_config — opens a SQLite estate with a caller-supplied
//                     EstateConfiguration. The path/busy-timeout fields of the
//                     supplied config's Sqlite backend are authoritative; the
//                     cache_config, encryption_config, and novel_token_tagger
//                     fields are threaded into SqliteStorage, which means
//                     cache_config.enabled=true wraps row_store() in a
//                     CachingRowStore LRU hot tier — exactly what the
//                     InMemory path does. Hosts that want the hot cache ON
//                     (e.g. the moot-mgr resident host) use this constructor.
//
// Both constructors produce an identical DrawerStore verb surface. The only
// difference is whether the underlying SqliteStorage's row_store() is wrapped
// in CachingRowStore.

/// WAL-mode SQLite-backed `DrawerStore`. Durable across process restarts.
/// Constructed from a filesystem path; the database file is created if
/// absent. Multiple opens of the same path share the physical WAL log; the
/// single-connection-per-estate model means only one `SqliteDrawerStore`
/// should hold a path at any time (SQLite serialises writes via its own
/// locking when journal_mode=WAL).
///
/// All verb behaviour is identical to `InMemoryDrawerStore` — this type
/// wraps `DrawerStoreCore` directly with a `SqliteStorage` backend, not the
/// `InMemoryDrawerStore` newtype (which allocates `InMemoryStorage`
/// internally and would be semantically wrong here).
pub struct SqliteDrawerStore(DrawerStoreCore);

impl SqliteDrawerStore {
    /// Open (creating if absent) the SQLite estate at `path`.
    ///
    /// `now` seeds the `created_at` / `last_modified` manifest rows on
    /// first open; subsequent opens leave those values unchanged.
    ///
    /// `hlc` follows the clock-triangle convention: `None` = top mode
    /// (this store is the HLC maker, node-id derived from estate uuid);
    /// `Some(gen)` = holder mode (GLK's estate-wide clock is injected).
    ///
    /// `busy_timeout_secs` is forwarded to SQLite's busy handler; 5.0
    /// is a reasonable default for single-process estates.
    pub fn from_path(
        path: &str,
        now: i64,
        hlc: Option<HLCGenerator>,
        busy_timeout_secs: f64,
    ) -> Result<Self, LocusKitError> {
        // A fresh estate_id is minted here; the manifest stores the canonical
        // estate uuid (written once on first open by DrawerStoreCore) so this
        // transient id is used only to satisfy the EstateConfiguration
        // constructor — the core overwrites estate_uuid from the manifest after
        // population.
        //
        // Cache is disabled (EstateConfiguration::new default). Callers that
        // want the CachingRowStore hot tier should use from_path_with_config.
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string(),
                busy_timeout_secs,
            },
        );
        // DrawerStoreCore::new is pub(crate) — accessible here because
        // drawer_store_sqlite is in the same LocusKit crate. External crates
        // must use SqliteDrawerStore::from_path / from_path_with_config so the
        // backend is always named at the construction site.
        let storage = SqliteStorage::new(config)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        let core = DrawerStoreCore::new(Arc::new(storage), now, hlc)?;
        Ok(SqliteDrawerStore(core))
    }

    /// Open (creating if absent) the SQLite estate at `path`, applying a
    /// caller-supplied `EstateConfiguration`.
    ///
    /// The `Sqlite` backend fields of `config` (path, busy_timeout_secs) are
    /// used to open the database. The `cache_config` field controls whether
    /// `SqliteStorage::row_store` wraps the backing store in a `CachingRowStore`
    /// LRU hot tier — identical to how `InMemoryStorage::row_store` applies the
    /// same predicate (`config.cache_config.enabled`). Pass a config with
    /// `EstateCacheConfig::new(true, ...)` to enable the hot tier; pass the
    /// default `EstateConfiguration` (cache disabled) for the bare path.
    ///
    /// The `encryption_config` and `novel_token_tagger` fields of `config` are
    /// forwarded verbatim into `SqliteStorage`.
    ///
    /// `now` and `hlc` follow the same conventions as `from_path`.
    ///
    /// # Caller responsibility
    ///
    /// The caller is responsible for ensuring `config.backend` is a
    /// `BackendConfiguration::Sqlite` variant whose `path` matches `path`.
    /// `SqliteStorage::new` will return `StorageError::BackendError` if the
    /// backend variant is not `Sqlite`.
    pub fn from_path_with_config(
        config: EstateConfiguration,
        now: i64,
        hlc: Option<HLCGenerator>,
    ) -> Result<Self, LocusKitError> {
        // SqliteStorage::new reads the Sqlite { path, busy_timeout_secs } from
        // config.backend. It also reads config.cache_config — when
        // cache_config.enabled is true, Storage::row_store() wraps the backing
        // SqliteRowStore in a CachingRowStore LRU hot tier (sqlite.rs, line ~539).
        // This mirrors the InMemory path exactly (inmemory.rs, same predicate).
        let storage = SqliteStorage::new(config)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        let core = DrawerStoreCore::new(Arc::new(storage), now, hlc)?;
        Ok(SqliteDrawerStore(core))
    }
}

// ---------------------------------------------------------------------------
// DrawerStore delegation — all methods forward to DrawerStoreCore.
// The `DrawerStoreCore` type implements `DrawerStore` directly, so this
// delegation is a zero-overhead forward through the newtype wrapper.
// ---------------------------------------------------------------------------

impl DrawerStore for SqliteDrawerStore {
    fn storage(&self) -> Option<Arc<dyn Storage>> {
        self.0.storage()
    }

    fn resolve_node_names(
        &self,
        parent_node_ids: &[String],
    ) -> Result<std::collections::BTreeMap<String, (String, String)>, LocusKitError> {
        self.0.resolve_node_names(parent_node_ids)
    }

    fn read_manifest(&self) -> Result<crate::manifest::ManifestValues, LocusKitError> {
        self.0.read_manifest()
    }

    fn set_meta(&self, key: &str, value: &str) -> Result<(), LocusKitError> {
        self.0.set_meta(key, value)
    }

    fn get_meta(&self, key: &str) -> Result<Option<String>, LocusKitError> {
        self.0.get_meta(key)
    }

    fn add_drawer(&self, drawer: &crate::drawer::Drawer, now: i64) -> Result<(), LocusKitError> {
        self.0.add_drawer(drawer, now)
    }

    fn get_drawer(&self, id: &str) -> Result<Option<crate::drawer::Drawer>, LocusKitError> {
        self.0.get_drawer(id)
    }

    fn living_successor_in_lineage(
        &self,
        lineage_id: &str,
        excluding_id: &str,
    ) -> Result<Option<String>, LocusKitError> {
        self.0.living_successor_in_lineage(lineage_id, excluding_id)
    }

    fn drawers_in_wing(&self, wing: &str) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.drawers_in_wing(wing)
    }

    fn drawers_in_wing_room(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.drawers_in_wing_room(wing, room)
    }

    fn drawers_by_source(
        &self,
        source_file: &str,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.drawers_by_source(source_file)
    }

    fn all_drawers(&self) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.all_drawers()
    }

    fn all_drawers_bounded(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.all_drawers_bounded(limit)
    }

    fn all_drawers_bounded_projected(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.all_drawers_bounded_projected(limit)
    }

    // Forwarding override for the reindex-sweep cursor scan. Without this,
    // trait-object dispatch (Arc<dyn DrawerStore>) hits the O(estate)
    // default (load all_drawers, filter, sort, truncate) instead of the
    // efficient (id > cursor, tombstonedAt IS NULL, LIMIT) query in
    // DrawerStoreCore.
    fn active_drawers_after(
        &self,
        after_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.active_drawers_after(after_id, limit)
    }

    // Forwarding overrides for the DESC bounded scan methods. Without these,
    // trait-object dispatch (Arc<dyn DrawerStore>) hits the O(estate) default
    // in the trait (load all_drawers, reverse, truncate) instead of the
    // efficient (filed_at DESC, id DESC, LIMIT) SQL query in DrawerStoreCore.
    // These forwards ensure the O(cap) path is taken for all wrapper callers
    // (c-recall-portable fix).

    fn all_drawers_bounded_desc(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.all_drawers_bounded_desc(limit)
    }

    fn all_drawers_bounded_projected_desc(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.0.all_drawers_bounded_projected_desc(limit)
    }

    fn drawer_ids(&self) -> Result<Vec<crate::estate_types::RowID>, LocusKitError> {
        self.0.drawer_ids()
    }

    fn mutate_provenance(
        &self,
        drawer_id: &str,
        new_provenance: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0
            .mutate_provenance(drawer_id, new_provenance, changed_by, reason, now)
    }

    fn mutate_adjective(
        &self,
        drawer_id: &str,
        new_adjective: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0
            .mutate_adjective(drawer_id, new_adjective, changed_by, reason, now)
    }

    fn mutate_operational(
        &self,
        drawer_id: &str,
        new_operational: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0
            .mutate_operational(drawer_id, new_operational, changed_by, reason, now)
    }

    fn mutate_state(
        &self,
        drawer_id: &str,
        new_state: crate::adjectives::State,
        via: substrate_lib::row_state::RowVerb,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0
            .mutate_state(drawer_id, new_state, via, changed_by, reason, now)
    }

    fn lineage_chain(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        self.0.lineage_chain(drawer_id)
    }

    fn expunge_gated(
        &self,
        drawer_id: &str,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
        seal_audit: bool,
    ) -> Result<substrate_lib::verbs::AuditEvent, LocusKitError> {
        self.0.expunge_gated(drawer_id, changed_by, reason, now, seal_audit)
    }
    fn seal_expunge_audit(
        &self,
        event: &substrate_lib::verbs::AuditEvent,
    ) -> Result<(), LocusKitError> {
        self.0.seal_expunge_audit(event)
    }
    fn seal_expunge_orphan_audit(
        &self,
        drawer_id: &str,
        success_event: &substrate_lib::verbs::AuditEvent,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0.seal_expunge_orphan_audit(drawer_id, success_event, changed_by, now)
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
        self.0
            .reanchor_gated(drawer_id, to_room, to_wing, to_lattice, changed_by, reason, now)
    }

    fn add_tunnel(&self, tunnel: &crate::tunnel::Tunnel) -> Result<(), LocusKitError> {
        self.0.add_tunnel(tunnel)
    }

    fn get_tunnel(&self, id: &str) -> Result<Option<crate::tunnel::Tunnel>, LocusKitError> {
        self.0.get_tunnel(id)
    }

    fn tunnels_from_wing(&self, wing: &str) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.0.tunnels_from_wing(wing)
    }

    fn tunnels_from_wing_room(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.0.tunnels_from_wing_room(wing, room)
    }

    fn tunnels_to_wing(&self, wing: &str) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.0.tunnels_to_wing(wing)
    }

    fn all_tunnels(&self) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        // Must forward: the trait default for all_tunnels is fail-loud
        // (DatabaseUnavailable). Omitting this forward would make the durable
        // SQLite backend hard-error on the dreaming-reader B-1 path
        // (Estate::all_tunnels), so the read is delegated to DrawerStoreCore's
        // real SQLite-backed implementation.
        self.0.all_tunnels()
    }

    // Retirement methods forward to DrawerStoreCore — T13 / ADR-021 Phase 7.
    fn retire_tunnel(&self, tunnel_id: &str, changed_by: &str, now: i64) -> Result<(), LocusKitError> {
        self.0.retire_tunnel(tunnel_id, changed_by, now)
    }

    fn unretire_tunnel(&self, tunnel_id: &str, changed_by: &str, now: i64) -> Result<(), LocusKitError> {
        self.0.unretire_tunnel(tunnel_id, changed_by, now)
    }

    fn outline_children(&self, parent_drawer_id: &str) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.0.outline_children(parent_drawer_id)
    }

    fn outline_ancestors(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        self.0.outline_ancestors(drawer_id)
    }

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
        self.0.reparent_drawer(child_id, new_parent_id, order_key, wing, room, added_by, now)
    }

    fn add_kg_fact(&self, fact: &crate::kg_fact::KGFact) -> Result<(), LocusKitError> {
        self.0.add_kg_fact(fact)
    }

    fn withdraw_kg_fact(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.0.withdraw_kg_fact(id, now)
    }

    fn get_kg_fact(&self, id: &str) -> Result<Option<crate::kg_fact::KGFact>, LocusKitError> {
        self.0.get_kg_fact(id)
    }

    fn kg_facts_for_drawer(
        &self,
        source_drawer_id: &str,
    ) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.0.kg_facts_for_drawer(source_drawer_id)
    }

    fn add_proposal(&self, proposal: &crate::proposal::Proposal) -> Result<(), LocusKitError> {
        self.0.add_proposal(proposal)
    }

    fn get_proposal(&self, id: &str) -> Result<Option<crate::proposal::Proposal>, LocusKitError> {
        self.0.get_proposal(id)
    }

    fn proposals_for_target(
        &self,
        target_row_id: &str,
    ) -> Result<Vec<crate::proposal::Proposal>, LocusKitError> {
        self.0.proposals_for_target(target_row_id)
    }

    fn add_association(
        &self,
        association: &crate::association::Association,
    ) -> Result<(), LocusKitError> {
        self.0.add_association(association)
    }

    fn get_association(
        &self,
        id: &str,
    ) -> Result<Option<crate::association::Association>, LocusKitError> {
        self.0.get_association(id)
    }

    fn associations_from(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::association::Association>, LocusKitError> {
        self.0.associations_from(wing, room)
    }

    fn associations_to(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::association::Association>, LocusKitError> {
        self.0.associations_to(wing, room)
    }

    fn add_learned_reference(
        &self,
        reference: &crate::learned_reference::LearnedReference,
    ) -> Result<(), LocusKitError> {
        self.0.add_learned_reference(reference)
    }

    fn get_learned_reference(
        &self,
        id: &str,
    ) -> Result<Option<crate::learned_reference::LearnedReference>, LocusKitError> {
        self.0.get_learned_reference(id)
    }

    fn learned_references_from_source(
        &self,
        source_catalog_id: &str,
    ) -> Result<Vec<crate::learned_reference::LearnedReference>, LocusKitError> {
        self.0.learned_references_from_source(source_catalog_id)
    }

    fn add_source_catalog_entry(
        &self,
        entry: &crate::source_catalog_entry::SourceCatalogEntry,
    ) -> Result<(), LocusKitError> {
        self.0.add_source_catalog_entry(entry)
    }

    fn get_source_catalog_entry(
        &self,
        id: &str,
    ) -> Result<Option<crate::source_catalog_entry::SourceCatalogEntry>, LocusKitError> {
        self.0.get_source_catalog_entry(id)
    }

    fn source_catalog_entry_for_handle(
        &self,
        handle: &str,
    ) -> Result<Option<crate::source_catalog_entry::SourceCatalogEntry>, LocusKitError> {
        self.0.source_catalog_entry_for_handle(handle)
    }

    fn add_diary_entry(&self, entry: &crate::diary_entry::DiaryEntry) -> Result<(), LocusKitError> {
        self.0.add_diary_entry(entry)
    }

    fn get_diary_entry(
        &self,
        id: &str,
    ) -> Result<Option<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.0.get_diary_entry(id)
    }

    fn read_diary(
        &self,
        agent_name: &str,
        last_n: usize,
    ) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.0.read_diary(agent_name, last_n)
    }

    fn read_diary_in_wing(
        &self,
        agent_name: &str,
        wing: &str,
        last_n: usize,
    ) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.0.read_diary_in_wing(agent_name, wing, last_n)
    }

    fn insert_recall_trace(
        &self,
        item: &crate::recall_trace_item::RecallTraceItem,
    ) -> Result<(), LocusKitError> {
        self.0.insert_recall_trace(item)
    }

    fn insert_recall_traces(
        &self,
        items: &[crate::recall_trace_item::RecallTraceItem],
    ) -> Result<(), LocusKitError> {
        self.0.insert_recall_traces(items)
    }

    fn get_recall_trace(
        &self,
        id: &str,
    ) -> Result<Option<crate::recall_trace_item::RecallTraceItem>, LocusKitError> {
        self.0.get_recall_trace(id)
    }

    fn recall_trace_since(
        &self,
        since: &str,
    ) -> Result<Vec<crate::recall_trace_item::RecallTraceItem>, LocusKitError> {
        self.0.recall_trace_since(since)
    }

    fn recent_recall_traces(
        &self,
        since: &str,
        now: &str,
    ) -> Result<Vec<crate::recall_trace_item::RecallTraceItem>, LocusKitError> {
        self.0.recent_recall_traces(since, now)
    }

    fn mark_recall_trace_used(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.0.mark_recall_trace_used(id, now)
    }

    fn prune_recall_traces(&self, cutoff: &str) -> Result<usize, LocusKitError> {
        self.0.prune_recall_traces(cutoff)
    }

    fn mark_recall_traces_used(
        &self,
        target: &str,
        since: &str,
        now: &str,
    ) -> Result<usize, LocusKitError> {
        self.0.mark_recall_traces_used(target, since, now)
    }

    fn count_recall_traces(&self) -> Result<usize, LocusKitError> {
        self.0.count_recall_traces()
    }

    fn count_drawer_rows(&self) -> Result<usize, LocusKitError> {
        self.0.count_drawer_rows()
    }

    fn count_tunnel_rows(&self) -> Result<usize, LocusKitError> {
        self.0.count_tunnel_rows()
    }

    fn count_kg_fact_rows(&self) -> Result<usize, LocusKitError> {
        self.0.count_kg_fact_rows()
    }

    fn audit_events_for_row(
        &self,
        row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        self.0.audit_events_for_row(row_id)
    }

    fn tombstoned_rows_without_expunge_audit(&self) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        // DrawerStoreCore::tombstoned_rows_without_expunge_audit runs two
        // queries that together are semantically equivalent to a SQL LEFT JOIN:
        //
        //   SELECT d.* FROM drawers d
        //   LEFT JOIN "_storagekit_audit" a
        //     ON UPPER(d.id) = a.row_id
        //     AND a.verb IN ('tombstone', 'expungeOrphan')
        //   WHERE d.tombstonedAt IS NOT NULL
        //     AND a.row_id IS NULL
        //   ORDER BY d.tombstonedAt ASC
        //
        // The first query fetches tombstoned drawers via the indexed
        // idx_drawers_tombstoned predicate; the second resolves to:
        //
        //   SELECT DISTINCT "row_id" FROM "_storagekit_audit"
        //   WHERE "row_id" IN (?) AND "verb" IN ('tombstone','expungeOrphan')
        //
        // via AuditLog::row_ids_with_audit_verbs, which SqliteAuditLog
        // implements as a single SQL query covered by the
        // idx_storagekit_audit_row_hlc index. Two queries total, not N+1.
        self.0.tombstoned_rows_without_expunge_audit()
    }

    fn seal_expunge_orphan_for_sweep(
        &self,
        drawer_id: &str,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0.seal_expunge_orphan_for_sweep(drawer_id, changed_by, now)
    }

    fn wipe_all_content(&self) -> Result<(), LocusKitError> {
        // DrawerStoreCore::wipe_all_content runs UPDATE drawers SET content=''
        // WHERE 1=1. All writes use the shared Arc<dyn Storage> which stays
        // live until coordinator::close() drops it; calling this before close()
        // ensures the SQLite connection is valid.
        self.0.wipe_all_content()
    }

    fn list_wings(&self) -> Result<Vec<crate::summaries::WingSummary>, LocusKitError> {
        self.0.list_wings()
    }

    fn list_rooms(
        &self,
        wing: Option<&str>,
    ) -> Result<Vec<crate::summaries::RoomSummary>, LocusKitError> {
        self.0.list_rooms(wing)
    }

    fn taxonomy(&self) -> Result<Vec<crate::summaries::WingSummary>, LocusKitError> {
        self.0.taxonomy()
    }

    fn all_proposals(&self) -> Result<Vec<crate::proposal::Proposal>, LocusKitError> {
        self.0.all_proposals()
    }

    fn all_associations(&self) -> Result<Vec<crate::association::Association>, LocusKitError> {
        self.0.all_associations()
    }

    fn all_learned_references(
        &self,
    ) -> Result<Vec<crate::learned_reference::LearnedReference>, LocusKitError> {
        self.0.all_learned_references()
    }

    fn all_kg_facts(&self) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.0.all_kg_facts()
    }

    fn all_kg_facts_including_retired(&self) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.0.all_kg_facts_including_retired()
    }

    fn all_diary_entries(&self) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.0.all_diary_entries()
    }
    fn fingerprints_captured_in(
        &self,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<Fingerprint256>, LocusKitError> {
        self.0.fingerprints_captured_in(start_epoch, end_epoch)
    }
    fn fingerprint_bit_series(
        &self,
        bit: usize,
        bucket_seconds: i64,
        bucket_count: usize,
        ending_at: i64,
    ) -> Result<Vec<bool>, LocusKitError> {
        self.0
            .fingerprint_bit_series(bit, bucket_seconds, bucket_count, ending_at)
    }
    fn room_level_fingerprints(
        &self,
    ) -> Result<Vec<crate::container_fingerprint_store::RoomLevelEntry>, LocusKitError> {
        self.0.room_level_fingerprints()
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
        self.0
            .or_in_container_fingerprint(wing, room, adjective, operational, provenance, now)
    }
    fn rebuild_container_fingerprints(&self, now: i64) -> Result<(), LocusKitError> {
        self.0.rebuild_container_fingerprints(now)
    }
    fn get_container_fingerprint(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Option<crate::container_fingerprint_store::ContainerFingerprint>, LocusKitError>
    {
        self.0.get_container_fingerprint(wing, room)
    }
}
