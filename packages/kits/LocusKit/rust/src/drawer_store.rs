//! Drawer-store contract. The trait every LocusKit storage backend
//! conforms to.
//!
//! ## Why this is a trait, not a struct
//!
//! The Swift port's `DrawerStore` is a concrete actor wrapping a
//! `Storage` (PersistenceKit) handle. The Rust port keeps the contract
//! and the concrete implementation separate: the trait is the surface
//! consumers (`Estate`, the bitmap evaluator) program against, and one
//! concrete impl per backend lives next to it. LP-1E ships the
//! persistence-kit-backed `InMemoryDrawerStore` (see
//! [`crate::drawer_store_inmemory`]); the future SQLite-backed
//! `SqliteDrawerStore` slots in by implementing the same trait.
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
use substrate_lib::row_state::RowVerb;
use crate::error::LocusKitError;
use crate::estate_types::RowID;
use crate::kg_fact::KGFact;
use crate::manifest::ManifestValues;
use crate::recall_trace_item::RecallTraceItem;
use crate::summaries::{RoomSummary, WingSummary};
use crate::adjectives::State;
use crate::tunnel::Tunnel;

/// Contract every LocusKit storage backend conforms to.
///
/// `Send + Sync` lets an `Arc<dyn DrawerStore>` cross thread
/// boundaries inside the `Estate` handle, which is the shape future
/// async wrappers and FFI consumers need.
///
/// Every method below has a default impl so minimal fakes (LP-1B
/// `FakeStore`, future net-new test stubs) compile without overriding
/// what they do not exercise. Production backends — the LP-1E
/// `InMemoryDrawerStore` is the first — override every method.
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

    // -----------------------------------------------------------------
    // KGFact CRUD
    // -----------------------------------------------------------------

    /// Insert a kg-fact.
    fn add_kg_fact(&self, _fact: &KGFact) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "add_kg_fact not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a kg-fact by id. Returns `None` on miss.
    fn get_kg_fact(&self, _id: &str) -> Result<Option<KGFact>, LocusKitError> {
        Ok(None)
    }

    /// All facts from a source drawer whose state cluster is below 7
    /// (excludes the rejected/accepted/tombstoned post-resolution
    /// states), ordered by `filed_at` ascending.
    fn kg_facts_for_drawer(
        &self,
        _source_drawer_id: &str,
    ) -> Result<Vec<KGFact>, LocusKitError> {
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
    fn insert_recall_trace(
        &self,
        _item: &RecallTraceItem,
    ) -> Result<(), LocusKitError> {
        Err(LocusKitError::DatabaseUnavailable(
            "insert_recall_trace not implemented for this DrawerStore impl".to_string(),
        ))
    }

    /// Fetch a recall-trace row by id. Returns `None` on miss.
    fn get_recall_trace(
        &self,
        _id: &str,
    ) -> Result<Option<RecallTraceItem>, LocusKitError> {
        Ok(None)
    }

    /// All trace rows whose `recalled_at` is at or after `since`,
    /// ordered ascending (oldest first). `since` is an ISO8601 string
    /// matching the schema's TEXT timestamp; the in-memory store
    /// compares strings lexicographically, which is correct for the
    /// canonical ISO8601 format the schema enforces.
    fn recall_trace_since(
        &self,
        _since: &str,
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
}
