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
//! Every method has a default impl returning either an empty result
//! (read paths) or `LocusKitError::DatabaseUnavailable` (write paths).
//! This keeps minimal fake stores in tests — see `estate.rs::FakeStore`
//! — compiling without overriding methods they do not exercise. Real
//! backends override the methods their callers exercise.
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
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use crate::adjectives::State;
use crate::association::Association;
use crate::error::LocusKitError;
use crate::estate_types::RowID;
use crate::kg_fact::KGFact;
use crate::learned_reference::LearnedReference;
use crate::manifest::ManifestValues;
use crate::proposal::Proposal;
use crate::recall_trace_item::RecallTraceItem;
use crate::summaries::{RoomSummary, WingSummary};
use crate::tunnel::Tunnel;
use substrate_lib::row_state::RowVerb;

/// Contract every LocusKit storage backend conforms to.
///
/// `Send + Sync` lets an `Arc<dyn DrawerStore>` cross thread
/// boundaries inside the `Estate` handle, which is the shape future
/// async wrappers and FFI consumers need.
///
/// Every method below has a default impl so minimal fakes (LP-1B
/// `FakeStore`, future net-new test stubs) compile without overriding
/// what they do not exercise. Production backends — the LP-1E
/// `InMemoryDrawerStore` and `SqliteDrawerStore` (both wrapping
/// `DrawerStoreCore`) — override every method.
#[allow(clippy::too_many_arguments)]
pub trait DrawerStore: Send + Sync {
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
    fn get_meta(&self, _key: &str) -> Result<Option<String>, LocusKitError> {
        Ok(None)
    }

    // -----------------------------------------------------------------
    // Drawer CRUD
    // -----------------------------------------------------------------

    /// Insert a drawer. When the drawer's `lineage_id` matches an
    /// active predecessor, the insert runs as a supersession cascade
    /// per spec § 6.2 / § 6.3: capture the new drawer through the
    /// gate (a genesis `AuditEvent`), flip the predecessor's state
    /// nibble to `Superseded` via
    /// `mutate_state(State::Superseded, RowVerb::Supersede)` (which
    /// appends one sealed `AuditEvent`), and file a directional
    /// `supersedes` tunnel. Otherwise a plain gated capture.
    fn add_drawer(&self, _drawer: &Drawer, _now: i64) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_drawer not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a drawer by id. Returns `None` on miss.
    fn get_drawer(&self, _id: &str) -> Result<Option<Drawer>, LocusKitError> {
        Ok(None)
    }

    /// All non-tombstoned drawers in a wing, ordered by `filed_at` ascending.
    fn drawers_in_wing(&self, _wing: &str) -> Result<Vec<Drawer>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned drawers in a wing/room pair, ordered by
    /// `filed_at` ascending.
    fn drawers_in_wing_room(&self, _wing: &str, _room: &str) -> Result<Vec<Drawer>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned drawers for one source file, ordered by
    /// `chunk_index` ascending then `filed_at` ascending.
    fn drawers_by_source(&self, _source_file: &str) -> Result<Vec<Drawer>, LocusKitError> {
        Ok(Vec::new())
    }

    /// Full-corpus scan ordered by `filed_at` ascending, including
    /// tombstoned rows. The bitmap evaluator excludes tombstones at
    /// its own tier (§ 7.9.4); callers needing a pre-filtered set use
    /// `drawers_in_wing` / `drawers_in_wing_room` instead.
    fn all_drawers(&self) -> Result<Vec<Drawer>, LocusKitError> {
        Ok(Vec::new())
    }

    /// Sentinel hook for tests / future verbs that need a list of
    /// drawer row identifiers. Default returns empty — the LP-1B
    /// `FakeStore` relies on the default; the LP-1E concrete store
    /// overrides it to return every drawer's id.
    fn drawer_ids(&self) -> Result<Vec<RowID>, LocusKitError> {
        Ok(Vec::new())
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

    /// Mutate a drawer's state (bits 0–3 of adjective_bitmap),
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

    /// Expunge a drawer: tombstone the state, set the
    /// `dreaming_recalc_required` worklist marker (adjective bit 26)
    /// synchronously, zero the content blob, stamp `tombstonedAt`, and
    /// emit one sealed audit event — all in one transaction. Cookbook
    /// §10.5 storage-layer postconditions. Aggregates untouched per
    /// §9.5.1. The cross-kit RAG vector delete is GLK's orchestration
    /// responsibility (F17 second pass item 4) and not invoked here.
    fn expunge_gated(
        &self,
        _drawer_id: &str,
        _changed_by: &str,
        _reason: Option<&str>,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "expunge_gated not implemented for this DrawerStore impl".to_string(),
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
    fn get_tunnel(&self, _id: &str) -> Result<Option<Tunnel>, LocusKitError> {
        Ok(None)
    }

    /// All non-tombstoned tunnels from a source wing, ordered by
    /// `filed_at` ascending.
    fn tunnels_from_wing(&self, _wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned tunnels from a source wing/room pair.
    fn tunnels_from_wing_room(
        &self,
        _wing: &str,
        _room: &str,
    ) -> Result<Vec<Tunnel>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned tunnels to a target wing.
    fn tunnels_to_wing(&self, _wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned tunnels across all wings, ordered by `filed_at`
    /// ascending. The dreaming daemon reads this to build the tunnel-key
    /// set for duplicate suppression — candidates whose drawer pair already
    /// has a Tunnel are dropped before scoring. Mirrors Swift
    /// `DrawerStore.allTunnels()`.
    fn all_tunnels(&self) -> Result<Vec<Tunnel>, LocusKitError> {
        Ok(Vec::new())
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
    /// purposes; `g_state_cluster` rises to 18 which excludes the fact
    /// from the active-recall filter (`g_state_cluster < 7`). Mirrors
    /// Swift `DrawerStore.withdrawKGFact(id:)`.
    fn withdraw_kg_fact(&self, _id: &str, _now: i64) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "withdraw_kg_fact not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a kg-fact by id. Returns `None` on miss.
    fn get_kg_fact(&self, _id: &str) -> Result<Option<KGFact>, LocusKitError> {
        Ok(None)
    }

    /// All facts from a source drawer whose state cluster is below 7
    /// (excludes the rejected/accepted/tombstoned post-resolution
    /// states), ordered by `filed_at` ascending.
    fn kg_facts_for_drawer(&self, _source_drawer_id: &str) -> Result<Vec<KGFact>, LocusKitError> {
        Ok(Vec::new())
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
    fn get_proposal(&self, _id: &str) -> Result<Option<Proposal>, LocusKitError> {
        Ok(None)
    }

    /// All proposals targeting a given row, ordered by `filed_at`
    /// ascending. Resolves through the `idx_proposals_target` index.
    fn proposals_for_target(&self, _target_row_id: &str) -> Result<Vec<Proposal>, LocusKitError> {
        Ok(Vec::new())
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
    fn get_association(&self, _id: &str) -> Result<Option<Association>, LocusKitError> {
        Ok(None)
    }

    /// All non-tombstoned associations from a source wing/room pair,
    /// ordered by `filed_at` ascending. Resolves through
    /// `idx_associations_source`.
    fn associations_from(
        &self,
        _wing: &str,
        _room: &str,
    ) -> Result<Vec<Association>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned associations to a target wing/room pair, ordered
    /// by `filed_at` ascending. Resolves through `idx_associations_target`.
    fn associations_to(&self, _wing: &str, _room: &str) -> Result<Vec<Association>, LocusKitError> {
        Ok(Vec::new())
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
    fn get_learned_reference(&self, _id: &str) -> Result<Option<LearnedReference>, LocusKitError> {
        Ok(None)
    }

    /// All non-tombstoned references learned from a source catalog entry,
    /// ordered by `filed_at` ascending. Resolves through
    /// `idx_learned_references_source`.
    fn learned_references_from_source(
        &self,
        _source_catalog_id: &str,
    ) -> Result<Vec<LearnedReference>, LocusKitError> {
        Ok(Vec::new())
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
    fn get_diary_entry(&self, _id: &str) -> Result<Option<DiaryEntry>, LocusKitError> {
        Ok(None)
    }

    /// Most-recent N non-tombstoned entries for an agent, newest first.
    fn read_diary(
        &self,
        _agent_name: &str,
        _last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        Ok(Vec::new())
    }

    /// Most-recent N non-tombstoned entries for an agent in a wing.
    fn read_diary_in_wing(
        &self,
        _agent_name: &str,
        _wing: &str,
        _last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        Ok(Vec::new())
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
    fn get_recall_trace(&self, _id: &str) -> Result<Option<RecallTraceItem>, LocusKitError> {
        Ok(None)
    }

    /// All trace rows whose `recalled_at` is at or after `since`,
    /// ordered ascending (oldest first). `since` is an ISO8601 string
    /// matching the schema's TEXT timestamp; the in-memory store
    /// compares strings lexicographically, which is correct for the
    /// canonical ISO8601 format the schema enforces.
    fn recall_trace_since(&self, _since: &str) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        Ok(Vec::new())
    }

    /// Trace rows whose `recalled_at` falls in `[since, now]` (both
    /// bounds inclusive), ordered ascending. Both parameters are ISO8601
    /// strings. The dreaming daemon calls this in step 1 to build the
    /// reward map for one tick: rows outside `now` are excluded so future
    /// rows are never pulled into a past cycle. Mirrors Swift
    /// `DrawerStore.recentRecallTraces(since:now:)`.
    fn recent_recall_traces(
        &self,
        _since: &str,
        _now: &str,
    ) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        Ok(Vec::new())
    }

    /// Mark a trace row's `used` flag (bit 0 of `operational_bitmap`).
    /// Idempotent on already-marked rows. Returns
    /// `LocusKitError::RecallTraceItemNotFound` when `id` is absent.
    fn mark_recall_trace_used(&self, _id: &str, _now: i64) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "mark_recall_trace_used not implemented for this DrawerStore impl".to_string(),
        ))
    }

    // -----------------------------------------------------------------
    // Audit reads
    // -----------------------------------------------------------------

    /// The row's sealed audit events (substrate form), in append order —
    /// the audit-log source of truth that replaces bitmap_audit reads.
    /// `row_id` is a UUID string per DECISION_ROW_IDENTITY_UUID.
    fn audit_events_for_row(
        &self,
        _row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        Ok(Vec::new())
    }

    // -----------------------------------------------------------------
    // Summary surface
    // -----------------------------------------------------------------

    /// Wing-level taxonomy: one `WingSummary` per wing over
    /// non-tombstoned drawers.
    fn list_wings(&self) -> Result<Vec<WingSummary>, LocusKitError> {
        Ok(Vec::new())
    }

    /// Room-level taxonomy. `wing = None` returns every wing's rooms;
    /// otherwise restricted to that wing.
    fn list_rooms(&self, _wing: Option<&str>) -> Result<Vec<RoomSummary>, LocusKitError> {
        Ok(Vec::new())
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
    fn all_proposals(&self) -> Result<Vec<Proposal>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned associations estate-wide, ordered by `filed_at`
    /// ascending. The MCP recall surface calls this when no source
    /// wing/room filter is needed.
    fn all_associations(&self) -> Result<Vec<Association>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned learned references estate-wide, ordered by
    /// `filed_at` ascending. The MCP recall surface calls this when no
    /// source catalog filter is needed.
    fn all_learned_references(&self) -> Result<Vec<LearnedReference>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All kg-facts estate-wide where the state cluster is below 7
    /// (excludes rejected/accepted/tombstoned post-resolution states),
    /// ordered by `filed_at` ascending. Mirrors `kg_facts_for_drawer`
    /// but without the source-drawer predicate.
    fn all_kg_facts(&self) -> Result<Vec<KGFact>, LocusKitError> {
        Ok(Vec::new())
    }

    /// All non-tombstoned diary entries estate-wide, ordered by `filed_at`
    /// ascending. The MCP recall surface calls this when no agent-name
    /// filter is needed.
    fn all_diary_entries(&self) -> Result<Vec<DiaryEntry>, LocusKitError> {
        Ok(Vec::new())
    }
}
