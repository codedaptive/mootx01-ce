//! SQLite-backed `DrawerStore` impl.
//!
//! `SqliteDrawerStore` is a thin constructor wrapper around
//! `InMemoryDrawerStore`. All verb logic — drawer CRUD, supersession
//! cascade, bitmap mutation paths, tunnel / kg-fact / diary CRUD,
//! recall trace, audit reads, and summary projections — lives once in
//! `InMemoryDrawerStore`, which delegates every operation through the
//! `Arc<dyn Storage>` abstraction layer. Because `SqliteStorage`
//! implements the same `Storage` trait as `InMemoryStorage`, the
//! entire verb surface works without duplication: `SqliteDrawerStore`
//! merely constructs a `SqliteStorage` and hands it to
//! `InMemoryDrawerStore::new`.
//!
//! ## Why a newtype rather than a type alias
//!
//! A type alias (`type SqliteDrawerStore = InMemoryDrawerStore`) would
//! expose the in-memory constructor as the public API. A newtype hides
//! the inner type, enforces the SQLite-specific constructor
//! (`from_path`), and lets callers import `SqliteDrawerStore` without
//! coupling to `InMemoryDrawerStore`'s existence.
//!
//! ## Schema invariants
//!
//! Inherited from `InMemoryDrawerStore`:
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
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::error::LocusKitError;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
use persistence_kit::SqliteStorage;
use std::sync::Arc;
use substrate_types::hlc::HLCGenerator;
use uuid::Uuid;

/// WAL-mode SQLite-backed `DrawerStore`. Durable across process
/// restarts. Constructed from a filesystem path; the database file is
/// created if absent. Multiple opens of the same path share the
/// physical WAL log; the single-connection-per-estate model means only
/// one `SqliteDrawerStore` should hold a path at any time (sqlite
/// serialises writes via its own locking when journal_mode=WAL).
///
/// All verb behaviour is identical to `InMemoryDrawerStore` — this
/// type delegates through the same `InMemoryDrawerStore` infrastructure
/// backed by a `SqliteStorage` handle rather than `InMemoryStorage`.
pub struct SqliteDrawerStore(InMemoryDrawerStore);

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
        // A fresh estate_id is minted here; the manifest stores the
        // canonical estate uuid (written once on first open) so this
        // transient id is used only to satisfy the EstateConfiguration
        // constructor — the InMemoryDrawerStore overwrites estate_uuid
        // from the manifest after population.
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string(),
                busy_timeout_secs,
            },
        );
        let storage = SqliteStorage::new(config)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        let inner = InMemoryDrawerStore::new(Arc::new(storage), now, hlc)?;
        Ok(SqliteDrawerStore(inner))
    }
}

// ---------------------------------------------------------------------------
// DrawerStore delegation — all methods forward to the inner store.
// ---------------------------------------------------------------------------

impl DrawerStore for SqliteDrawerStore {
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

    fn expunge_gated(
        &self,
        drawer_id: &str,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0.expunge_gated(drawer_id, changed_by, reason, now)
    }

    fn reanchor_gated(
        &self,
        drawer_id: &str,
        to_room: Option<&str>,
        to_lattice: Option<crate::estate_types::LatticeAnchor>,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.0
            .reanchor_gated(drawer_id, to_room, to_lattice, changed_by, reason, now)
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

    fn add_kg_fact(&self, fact: &crate::kg_fact::KGFact) -> Result<(), LocusKitError> {
        self.0.add_kg_fact(fact)
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

    fn mark_recall_trace_used(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.0.mark_recall_trace_used(id, now)
    }

    fn audit_events_for_row(
        &self,
        row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        self.0.audit_events_for_row(row_id)
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
}
