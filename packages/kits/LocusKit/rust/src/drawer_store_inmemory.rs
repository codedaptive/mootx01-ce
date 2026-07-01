//! Drawer-store implementations backed by persistence-kit `Storage`.
//! Ports `DrawerStore.swift`.
//!
//! ## Architecture — core + three newtypes
//!
//! Backend identity is **structurally visible at every construction site**
//! and **deliberately erased at the trait surface**.  The module exposes:
//!
//! - [`DrawerStoreCore`] — the storage-agnostic verb-logic core over
//!   `Arc<dyn Storage>`.  Its constructor is `pub(crate)` — no external
//!   crate may construct a bare storage-unknown core.  Kit-internal code
//!   (e.g. tests that share a single `InMemoryStorage` across two opens)
//!   may call `DrawerStoreCore::new` directly.
//!
//! - [`InMemoryDrawerStore`] — thin public newtype wrapping
//!   `DrawerStoreCore` over an `InMemoryStorage` backend.  This is what
//!   every external construction site names.  Its constructor allocates
//!   the `InMemoryStorage` internally so callers name their backend in
//!   the type.
//!
//! - [`SqliteDrawerStore`] — symmetric newtype over a `SqliteStorage`
//!   backend (WAL-mode, durable); see `drawer_store_sqlite.rs`.
//!
//! - [`PostgresDrawerStore`] — symmetric newtype over a `PostgresStorage`
//!   backend (pooled, durable); see `drawer_store_postgres.rs`.
//!
//! The Swift parallel is the single storage-parameterised `actor
//! DrawerStore` — no per-backend types exist on the Swift side, so only
//! the shared trait name `DrawerStore` is cross-leg-meaningful and it
//! does NOT change here.  This split is Rust-internal.
//!
//! ## Swift-to-Rust shape changes
//!
//! - Swift `public actor DrawerStore` → Rust sync `DrawerStoreCore`. The
//!   persistence-kit Rust trait surface is sync; the underlying
//!   `InMemoryStorage` backend serialises access via an internal `Mutex`,
//!   which gives every multi-step path the atomicity the Swift
//!   `storage.transaction(isolation:)` provides.  Same shape as
//!   `ContainerFingerprintStore` (LP-1C) and `NodeBundleStore` (LP-1D).
//! - Swift `async throws` → `Result<T, LocusKitError>`.
//! - Swift `Date` everywhere → Rust `i64` epoch-seconds parameter on
//!   every mutation method, threading the deterministic-clock rule
//!   explicitly.
//! - Swift `storage.transaction(isolation: .serializable) { txn in
//!   ... }` → sequential `row_store.insert/update/query` calls. The
//!   InMemory backend's `State` mutex serialises operations; no
//!   formal `transaction()` exists on the Rust persistence-kit yet (its
//!   `storage.rs` doc defers transaction support to when the SQLite
//!   backend lands). Each multi-step path carries an explicit
//!   comment noting the Swift transaction it mirrors. When
//!   persistence-kit grows transactions, the wrapper drops in with no
//!   behaviour change.
//! - Audit-row id assignment: SQLite assigns the rowid to omitted
//!   `id` columns. The InMemory persistence-kit backend keys rows by an
//!   internal UUID and does not surface a public auto-id. Audit ids
//!   are dense and monotone within a process and ordered by insertion.

use crate::adjectives::State;
use crate::diary_entry::DiaryEntry;
use crate::drawer::Drawer;
use crate::drawer_fingerprint::EstateFingerprintFamilies;
use persistence_kit::inmemory::InMemoryStorage;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::RowState;
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
use crate::association::Association;
use crate::container_fingerprint_store::{ContainerFingerprintStore, RoomLevelEntry};
use crate::node::Node;
use crate::node_store::T_NODES;
use crate::drawer_store::DrawerStore;
use crate::error::LocusKitError;
use crate::estate_types::{LatticeAnchor, RowID};
use crate::kg_fact::KGFact;
use crate::learned_reference::LearnedReference;
use crate::manifest::{ManifestKey, ManifestValues};
use crate::proposal::Proposal;
use crate::recall_trace_item::RecallTraceItem;
use crate::schema;
use crate::source_catalog_entry::{SourceCatalogEntry, SourceKind};
use crate::summaries::{RoomSummary, WingSummary};
use crate::tunnel::Tunnel;
use crate::tunnel_operational::TunnelKind;
use persistence_kit::audit_log::AuditEvent as PkAuditEvent;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::sync::Mutex;
use substrate_kernel::bit_field;
use substrate_lib::audit_gate;
use substrate_lib::row_state::BitmapFields;
use substrate_lib::row_state::RowVerb;
use substrate_types::hlc::HLCGenerator;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Table names
// ---------------------------------------------------------------------------

const T_DRAWERS: &str = "drawers";
const T_TUNNELS: &str = "tunnels";
const T_KG_FACTS: &str = "kg_facts";
const T_PROPOSALS: &str = "proposals";
const T_ASSOCIATIONS: &str = "associations";
const T_LEARNED_REFERENCES: &str = "learned_references";
const T_SOURCE_CATALOG: &str = "source_catalog";
const T_DIARY: &str = "diary";
const T_MANIFEST: &str = "manifest";
const T_RECALL_TRACE: &str = "recall_trace";

/// The structured (no-blob) column projection for the `drawers` table: every
/// drawer column EXCEPT `content`. Used by `all_drawers_bounded_projected` so a
/// `.structured` recall scan never reads the content blob and the decoded
/// drawer carries `content == ""` (LocusKit spec § 7.3). Must stay in sync with
/// `schema::drawers_table` minus `content`; `drawer_from_row` decodes the absent
/// `content` column to `""` via `string_value_of(None)`.
const DRAWER_STRUCTURED_COLUMNS: &[&str] = &[
    "id",
    "parent_node_id",
    "sourceFile",
    "chunkIndex",
    "addedBy",
    "filedAt",
    "eventTime",
    "embeddingModelID",
    "tombstonedAt",
    "removedByBatch",
    "provenance",
    "adjectiveBitmap",
    "operationalBitmap",
    "lineageID",
    "udcCode",
    "udcFacets",
    "wikidataQID",
    "wikidataQidsSecondary",
    "ext",
];

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Storage-agnostic verb-logic core over `Arc<dyn Storage>`.
///
/// Implements the full LocusKit `DrawerStore` trait: drawer CRUD, bitmap
/// mutation paths, tunnel / kg-fact / diary CRUD, recall-trace, audit
/// reads, and summary projections. All verb logic lives once here; backend
/// identity lives at the construction boundary — callers use the typed
/// newtypes (`InMemoryDrawerStore`, `SqliteDrawerStore`) rather than
/// constructing this core directly.
///
/// This struct fronts both `InMemoryStorage` (ephemeral estates, test
/// fixtures) and `SqliteStorage` (durable WAL-mode estates), via the
/// respective newtype constructors. The trait surface is the contract;
/// the backend is invisible to verb logic.
///
/// `pub(crate)` constructor: external crates must go through a newtype
/// so that the backend is always named at the construction site.
pub struct DrawerStoreCore {
    storage: Arc<dyn Storage>,
    /// The HLC clock this store stamps audit events with. Per the clock
    /// decision (DECISION_CLOCK_TRIANGLE_TIME_MODEL): the top entity
    /// *makes* the clock, holders *receive* it. `new(.., None)` = top
    /// mode (make own, node id from estate uuid); `Some(gen)` = holder
    /// mode (GLK's one estate-wide maker). One generator, `send()` once
    /// per write. Interior-mutable because `send` mutates and the store
    /// methods take `&self`.
    hlc: Mutex<HLCGenerator>,
    /// Frozen write-gate vocabulary, validated once at open
    /// (freeze-at-instantiation). Mirrors Swift `vocabulary`.
    vocabulary: substrate_lib::audit_gate::Vocabulary,
    /// This estate's uuid, resolved from the manifest once at open and
    /// held for stamping audit events. Mirrors Swift `estateUuid`.
    estate_uuid: Uuid,
}

/// The classification of the manifest's `estate_uuid` value at open.
/// `Present` carries the parsed UUID (for stamping) plus the raw stored
/// text (hashed for the maker node id, byte-identical to Swift). `Absent`
/// means the key was never written (fresh estate). A present-but-malformed
/// value is NOT a variant here — it surfaces as `Err(CorruptStoredValue)`
/// from `classify_estate_uuid`, because conflating corruption with a fresh
/// estate would mask data loss (P1-7). Parity: Swift `EstateUuidState`.
#[derive(Debug)]
enum EstateUuidState {
    Present { uuid: Uuid, raw_text: String },
    Absent,
}

impl DrawerStoreCore {
    /// Open the core over a `Storage` handle. Opens the LocusKit schema
    /// (idempotent — re-opening an existing estate is a no-op for tables,
    /// generated columns, and indices) and writes the v1 manifest defaults
    /// using `INSERT OR IGNORE` semantics (values written on a prior open
    /// stay authoritative).
    ///
    /// `now` is the deterministic clock value used to seed the
    /// `created_at` and `last_modified` manifest rows on first open.
    ///
    /// `pub(crate)`: external callers must go through `InMemoryDrawerStore`
    /// or another backend-typed newtype so the backend is always visible at
    /// the construction site.
    pub(crate) fn new(
        storage: Arc<dyn Storage>,
        now: i64,
        hlc: Option<HLCGenerator>,
    ) -> Result<Self, LocusKitError> {
        storage
            .open(&schema::schema())
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        // vocabulary/estate_uuid are set after manifest population below;
        // freeze can't fail for the static union but we seed a valid one.
        let seed_vocab = crate::vocabulary::frozen().map_err(|e| {
            LocusKitError::InvalidContent(format!("LocusKit vocabulary failed to freeze: {:?}", e))
        })?;
        let mut store = DrawerStoreCore {
            storage,
            // Temporary; replaced below once the manifest exists.
            hlc: Mutex::new(HLCGenerator::new(0)),
            vocabulary: seed_vocab,
            estate_uuid: Uuid::nil(),
        };
        store.populate_v1_manifest_defaults(now)?;
        // Classify the persisted estate identity ONCE, distinguishing two
        // cases that must NOT be conflated (P1-7):
        //   • Absent manifest value (fresh estate, key never written) →
        //     the legitimate fresh-estate path.
        //   • Present-but-malformed UUID (non-parseable text) → data
        //     corruption: fail loud with `CorruptStoredValue` rather than
        //     fabricating a random UUID / node 0, which would mask it.
        // The same classified value feeds BOTH the estate uuid and the HLC
        // maker node id so they can never disagree (mirrors Swift
        // `DrawerStore.classifyEstateUuid`).
        let identity = store.classify_estate_uuid()?;
        // Establish the clock: injected (holder) or made here (top).
        let generator = match hlc {
            Some(g) => g,
            None => HLCGenerator::new(Self::maker_node_id(&identity)),
        };
        *store.hlc.lock().unwrap() = generator;
        // Freeze the write-gate vocabulary once (freeze-at-instantiation).
        store.vocabulary = crate::vocabulary::frozen().map_err(|e| {
            LocusKitError::InvalidContent(format!("LocusKit vocabulary failed to freeze: {:?}", e))
        })?;
        // Resolve estate uuid from the SAME classified value: present ⇒ the
        // persisted identity; absent ⇒ a fresh mint for this store. A
        // corrupt value already returned `Err` above, so it never reaches
        // here.
        store.estate_uuid = match identity {
            EstateUuidState::Present { uuid, .. } => uuid,
            EstateUuidState::Absent => Uuid::new_v4(),
        };
        Ok(store)
    }

    /// Read the manifest `estate_uuid` value and classify it as a fresh
    /// estate (`Absent`), a valid persisted identity (`Present`), or data
    /// corruption (`Err(CorruptStoredValue)`). The three outcomes are
    /// mutually exclusive and exhaustive:
    ///   • row missing / value missing / non-text → `Absent` (fresh).
    ///   • value present and parses as a UUID → `Present`.
    ///   • value present but does NOT parse → `Err(CorruptStoredValue {
    ///     table: "manifest", column: "estate_uuid", stored_text })`,
    ///     fail-loud, never a fabricated default.
    /// Parity: Swift `DrawerStore.classifyEstateUuid`.
    fn classify_estate_uuid(&self) -> Result<EstateUuidState, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_MANIFEST,
                Some(&StoragePredicate::Eq(
                    Column::new(T_MANIFEST, "key"),
                    TypedValue::Text("estate_uuid".to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        // Absent: no row, no value, or a non-text value. A fresh,
        // never-written estate — legitimate, assign a new identity.
        let raw = match rows.first().and_then(|r| r.get("value")) {
            Some(TypedValue::Text(s)) => s.clone(),
            _ => return Ok(EstateUuidState::Absent),
        };
        // Present: the value exists, so it MUST parse. A non-parseable
        // value is corruption — fail loud rather than mint a random UUID.
        match Uuid::parse_str(&raw) {
            Ok(uuid) => Ok(EstateUuidState::Present { uuid, raw_text: raw }),
            Err(_) => Err(LocusKitError::CorruptStoredValue {
                table: T_MANIFEST.to_string(),
                column: "estate_uuid".to_string(),
                stored_text: raw,
            }),
        }
    }

    /// Derive a stable maker node id from an already-classified estate
    /// uuid (FNV-1a 32-bit, masked non-negative). A present value hashes
    /// its RAW stored text — byte-identical to what Swift hashes — so both
    /// ports derive the same node id. An absent value (fresh estate)
    /// yields 0. Corrupt values never reach here (`classify_estate_uuid`
    /// returns `Err` first). Mirrors Swift `makerNodeID(for:)`.
    fn maker_node_id(state: &EstateUuidState) -> i32 {
        match state {
            EstateUuidState::Absent => 0,
            EstateUuidState::Present { raw_text, .. } => {
                // FNV-1a 32-bit (SubstrateLib), masked to non-negative i32.
                let h = substrate_types::fnv::hash32(raw_text);
                (h & 0x7FFF_FFFF) as i32
            }
        }
    }

    /// Populate the v1 well-known manifest keys. Uses a presence check
    /// per key so the `estate_uuid` written on first open stays stable
    /// across every subsequent open. `federation_group_id` is
    /// intentionally absent (its absence means "not federated").
    /// `active_storage_mode` = "8" is L1 lossless page compression per
    /// the Q10a leaning. Mirrors Swift `populateV1ManifestDefaults`.
    fn populate_v1_manifest_defaults(&self, now: i64) -> Result<(), LocusKitError> {
        let timestamp = format_iso8601(now);
        let estate_uuid = Uuid::new_v4().to_string();

        let defaults: [(&str, String); 18] = [
            ("manifest_version", "1.0".to_string()),
            ("schema_version", "1.0".to_string()),
            ("estate_uuid", estate_uuid),
            ("estate_name", String::new()),
            ("owner_identifier", String::new()),
            ("lattice_citation", "UDC:2024+Wikidata:2024-Q3".to_string()),
            ("framework_profile", "unspecified_v0".to_string()),
            ("framework_profile_definition", "{}".to_string()),
            ("zoom_window_low", "0".to_string()),
            ("zoom_window_high", "99".to_string()),
            ("access_posture", "0".to_string()),
            ("provenance_defaults", "0".to_string()),
            ("active_storage_mode", "8".to_string()),
            ("tables_present", String::new()),
            ("created_at", timestamp.clone()),
            ("last_modified", timestamp),
            ("bitmap_layout_version", "v1.0".to_string()),
            ("provenance_bitmap_version", "v1.0".to_string()),
        ];

        let row_store = self.storage.row_store();
        for (key, value) in &defaults {
            // Insert-when-absent: a presence check first so the
            // estate_uuid written on first open is preserved. Plain
            // insert would surface a DuplicateKey on the second open.
            let existing = row_store
                .query(
                    T_MANIFEST,
                    Some(&StoragePredicate::Eq(
                        Column::new(T_MANIFEST, "key"),
                        TypedValue::Text((*key).to_string()),
                    )),
                    &[],
                    Some(1),
                    None,
                )
                .map_err(map_storage_err)?;
            if existing.is_empty() {
                let mut values = BTreeMap::new();
                values.insert("key".to_string(), TypedValue::Text((*key).to_string()));
                values.insert("value".to_string(), TypedValue::Text(value.clone()));
                row_store
                    .insert(T_MANIFEST, values)
                    .map_err(map_storage_err)?;
            }
        }
        Ok(())
    }

    /// Find an active predecessor (Cluster-A state; raw < 16 per
    /// `RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW`) sharing the
    /// drawer's `lineage_id`, excluding the row being inserted.
    /// Mirrors Swift `findActivePredecessor`. Used by the supersession
    /// cascade.
    fn find_active_predecessor(
        &self,
        lineage_id: &Uuid,
        excluding_id: &str,
    ) -> Result<Option<String>, LocusKitError> {
        let row_store = self.storage.row_store();
        let rows = row_store
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "lineageID"),
                        TypedValue::Text(lineage_id.to_string()),
                    ),
                    StoragePredicate::Neq(
                        Column::new(T_DRAWERS, "id"),
                        TypedValue::Text(excluding_id.to_string()),
                    ),
                    StoragePredicate::Lt(
                        Column::new(T_DRAWERS, "g_state_cluster"),
                        TypedValue::Int(3),
                    ),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(|r| string_value_of(r.get("id"))))
    }

    /// Supersession cascade. Mirrors Swift `DrawerStore.addDrawerWithCascade`.
    ///
    /// ## Atomicity (Swift vs Rust)
    ///
    /// In the Swift port the successor drawer INSERT + genesis audit event and
    /// the supersedes tunnel INSERT share a single
    /// `storage.transaction(isolation: .serializable)` so both land atomically
    /// or both roll back.  The predecessor state flip (`mutate_state`) is a
    /// separate operation that runs AFTER the transaction.
    ///
    /// The Rust PersistenceKit has no transaction surface yet (`storage.rs`
    /// defers that to the SQLite backend).  To preserve failure atomicity
    /// between the successor INSERT and the tunnel INSERT this port:
    ///
    /// 1. Inserts the successor drawer + genesis audit event (`gated_capture`).
    /// 2. Builds and inserts the tunnel.
    /// 3. If the tunnel insert fails, performs a **compensating delete** of the
    ///    just-inserted drawer row so no orphaned successor is left visible to
    ///    queries.  The genesis audit event cannot be compensated (append-only),
    ///    but the drawer row — which is the entity queries search — is removed.
    /// 4. Flips the predecessor state via `mutate_state` only AFTER the tunnel
    ///    insert succeeds (mirrors Swift order).  This means a tunnel-insert
    ///    failure does not leave the predecessor stuck in `Superseded` without
    ///    an active successor.
    ///
    /// When PersistenceKit grows a transaction surface, replace steps 1–3 with
    /// a single transaction block; behaviour stays the same.
    fn add_drawer_with_cascade(
        &self,
        new_drawer: &Drawer,
        prior_id: &str,
    ) -> Result<(), LocusKitError> {
        let row_store = self.storage.row_store();

        // Read the predecessor's location before any writes so the tunnel
        // carries the predecessor's place and the state-flip audit row
        // records the exact prior adjective value.
        let prior_rows = row_store
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(prior_id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        let prior_row = prior_rows
            .first()
            .ok_or_else(|| LocusKitError::DrawerNotFound {
                id: prior_id.to_string(),
            })?;
        let prior_adjective = i64_value_of(prior_row.get("adjectiveBitmap"));
        let _ = prior_adjective;

        // ADR-017 §3: resolve wing/room display names from node tree for
        // the supersedes tunnel. Both the new drawer and the predecessor
        // carry parent_node_id; resolve to display names via node tree.
        let prior_parent_node_id = string_value_of(prior_row.get("parent_node_id"));
        let node_names = self.resolve_node_names(
            &[new_drawer.parent_node_id.clone(), prior_parent_node_id.clone()],
        )?;
        let source_names = node_names
            .get(&new_drawer.parent_node_id)
            .cloned()
            .unwrap_or_default();
        let prior_names = node_names
            .get(&prior_parent_node_id)
            .cloned()
            .unwrap_or_default();

        // Step 1: Successor's gated capture (genesis) event + projection row.
        self.gated_capture(new_drawer, new_drawer.filed_at)?;

        // Step 2: Directional supersedes tunnel: new → prior.
        // This insert and the gated_capture above are logically atomic:
        // if the tunnel insert fails, we compensate by deleting the drawer
        // row (step 3 below) so no orphaned successor is visible to queries.
        let mut tunnel = Tunnel::new(
            format!("supersedes:{}:{}", new_drawer.id, prior_id),
            source_names.0.clone(),
            source_names.1.clone(),
            prior_names.0.clone(),
            prior_names.1.clone(),
            "supersedes".to_string(),
            new_drawer.added_by.clone(),
            new_drawer.filed_at,
        );
        tunnel.kind = TunnelKind::Supersedes;
        tunnel.source_drawer_id = Some(new_drawer.id.clone());
        tunnel.target_drawer_id = Some(prior_id.to_string());
        if let Err(tunnel_err) = row_store
            .insert(T_TUNNELS, tunnel_values(&tunnel))
            .map_err(map_storage_err)
        {
            // Step 3: Compensating delete — remove the successor drawer row
            // so no orphaned successor is left in the database.  The genesis
            // audit event cannot be compensated (the audit_log is append-only)
            // but the drawer row — which is what lineage and recall queries
            // search — is removed.  When PersistenceKit gains transaction
            // support, replace this compensation with a proper rollback.
            let _ = row_store.delete(
                T_DRAWERS,
                &StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(new_drawer.id.clone()),
                ),
            );
            return Err(tunnel_err);
        }

        // Step 4: Flip the predecessor active → superseded via the validated
        // state path — only AFTER the tunnel insert succeeds (mirrors Swift
        // ordering: state flip is not part of the successor+tunnel transaction
        // but follows it).  Earlier code smuggled the state through a manual
        // adjective-bitmap write + bitmap_audit row, bypassing the transition
        // automaton (F8 anti-pattern, same as withdraw).  The write gate now
        // forbids moving state through a field edit, so the supersede
        // transition MUST go through mutate_state, which validates
        // active --supersede--> superseded and appends the sealed audit event.
        // changed_by is the triggering successor's author.
        self.mutate_state(
            prior_id,
            State::Superseded,
            RowVerb::Supersede,
            &new_drawer.added_by,
            Some(&format!(
                "supersession cascade, lineageID {}",
                new_drawer.lineage_id
            )),
            new_drawer.filed_at,
        )?;

        Ok(())
    }

    /// Read a single bitmap column for a drawer, returning
    /// `LocusKitError::DrawerNotFound` when the row is absent.
    /// Centralises the prior-value read shared by every mutation path.
    /// Mirrors Swift `readBitmap`.
    fn read_drawer_bitmap(&self, drawer_id: &str, column: &str) -> Result<i64, LocusKitError> {
        let row_store = self.storage.row_store();
        let rows = row_store
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(drawer_id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        let row = rows.first().ok_or_else(|| LocusKitError::DrawerNotFound {
            id: drawer_id.to_string(),
        })?;
        Ok(i64_value_of(row.get(column)))
    }

    /// Read a drawer's udcCode text (the lattice-anchor source), or
    /// empty string when absent. Mirrors the Swift anchor read.
    fn read_drawer_udc(&self, drawer_id: &str) -> Result<String, LocusKitError> {
        let row_store = self.storage.row_store();
        let rows = row_store
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(drawer_id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        let row = rows.first().ok_or_else(|| LocusKitError::DrawerNotFound {
            id: drawer_id.to_string(),
        })?;
        Ok(string_value_of(row.get("udcCode")))
    }

    /// Decompose a whole-column replacement value into per-field
    /// FieldWrites for that column's declared slots, then route through
    /// the gate. Closes F8: legacy whole-column mutators wrote an entire
    /// bitmap with no per-field validation; here every field is validated
    /// and the basis combination checked (incl. I-22). The state field
    /// (adjective 0-5) is verb-driven and is excluded — a field edit can
    /// never move state. verb = Mutate (the active→active self-loop).
    ///
    /// Slots come from the authoritative LocusKit-owned definitions
    /// (substrate basis for adjective; vocabulary::union_slots for
    /// operational/provenance), NOT from the frozen Vocabulary object —
    /// the Rust Vocabulary intentionally does not expose its union, and
    /// LocusKit already owns these slot definitions.
    fn gated_column_write(
        &self,
        drawer_id: &str,
        column: audit_gate::Column,
        new_column_value: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let row_uuid = require_uuid(drawer_id, "drawerId")?;

        // Declared slots for this column, excluding the verb-driven state
        // field (adjective shift 0). Read each slot's value out of the
        // incoming column value and emit a FieldWrite.
        let slots: Vec<audit_gate::FieldSlot> = match column {
            audit_gate::Column::Adjective => audit_gate::basis()
                .into_iter()
                .filter(|s| !(matches!(s.column, audit_gate::Column::Adjective) && s.shift == 0))
                .collect(),
            audit_gate::Column::Operational => crate::vocabulary::union_slots()
                .into_iter()
                .filter(|s| matches!(s.column, audit_gate::Column::Operational))
                .collect(),
            audit_gate::Column::Provenance => crate::vocabulary::union_slots()
                .into_iter()
                .filter(|s| matches!(s.column, audit_gate::Column::Provenance))
                .collect(),
        };
        let writes: Vec<audit_gate::FieldWrite> = slots
            .into_iter()
            .map(|slot| {
                let value = bit_field::extract_field(new_column_value, slot.shift, slot.width);
                audit_gate::FieldWrite { slot, value }
            })
            .collect();

        let prior_adj = self.read_drawer_bitmap(drawer_id, "adjectiveBitmap")?;
        let prior_op = self.read_drawer_bitmap(drawer_id, "operationalBitmap")?;
        let prior_prov = self.read_drawer_bitmap(drawer_id, "provenance")?;
        let prior = BitmapFields {
            adjective: prior_adj as u64,
            operational: prior_op as u64,
            provenance: prior_prov as u64,
        };
        let udc = self.read_drawer_udc(drawer_id)?;
        let anchor = substrate_lib::verbs::LatticeAnchor::udc(&udc);
        let stamp = self.hlc.lock().unwrap().send(now * 1000);

        let event = audit_gate::admit(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            RowVerb::Mutate,
            Some(prior),
            Some(anchor),
            &writes,
            anchor,
            &self.vocabulary,
            stamp,
            changed_by,
        )
        .map_err(|v| {
            // Use Display ({}) not Debug ({:?}) so internal Rust type names
            // (BasisViolation, IllegalTransition) do not leak into user-visible
            // error messages at the ARIA boundary. GateViolation::Display
            // produces clean English text.
            LocusKitError::InvalidContent(format!(
                "{:?} mutation rejected by gate: {}",
                column, v
            ))
        })?;

        // Materialized projection: write the merged column back.
        let (col_name, merged) = match column {
            audit_gate::Column::Adjective => ("adjectiveBitmap", event.after_bitmaps.0),
            audit_gate::Column::Operational => ("operationalBitmap", event.after_bitmaps.1),
            audit_gate::Column::Provenance => ("provenance", event.after_bitmaps.2),
        };
        let row_store = self.storage.row_store();
        let mut update_vals = BTreeMap::new();
        update_vals.insert(col_name.to_string(), TypedValue::Bitmap(merged));
        row_store
            .update(
                T_DRAWERS,
                update_vals,
                &StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(drawer_id.to_string()),
                ),
            )
            .map_err(map_storage_err)?;
        // Thread the caller-supplied reason into the event so it is
        // persisted in the audit table's `reason` column.
        let event = substrate_lib::verbs::AuditEvent {
            reason: reason.map(|s| s.to_string()),
            ..event
        };
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&event))
            .map_err(map_storage_err)?;
        Ok(())
    }

    /// Emit a gated capture (genesis) event for a new drawer and insert
    /// its materialized projection row. Capture has no prior state, so it
    /// routes through `audit_gate::admit` with verb=Capture and prior=None:
    /// the gate validates the initial state (Active/Pending), runs the
    /// basis/forbidden-combination check (I-22 included), and seals the
    /// genesis snapshot. Every declared slot of all three columns —
    /// INCLUDING the state slot, which only capture may set — is
    /// decomposed from the drawer's bitmaps. This makes the audit log
    /// self-sufficient from birth (cold-rebuild + federation need it).
    fn gated_capture(&self, drawer: &Drawer, now: i64) -> Result<(), LocusKitError> {
        let row_uuid = require_uuid(&drawer.id, "id")?;

        let mut writes: Vec<audit_gate::FieldWrite> = Vec::new();
        // Adjective: all basis slots, state INCLUDED (capture sets it).
        for slot in audit_gate::basis() {
            if matches!(slot.column, audit_gate::Column::Adjective) {
                let value =
                    bit_field::extract_field(drawer.adjective_bitmap, slot.shift, slot.width);
                writes.push(audit_gate::FieldWrite { slot, value });
            }
        }
        for slot in crate::vocabulary::union_slots() {
            let (col_value, is_match) = match slot.column {
                audit_gate::Column::Operational => (drawer.operational_bitmap, true),
                audit_gate::Column::Provenance => (drawer.provenance, true),
                audit_gate::Column::Adjective => (0, false),
            };
            if is_match {
                let value = bit_field::extract_field(col_value, slot.shift, slot.width);
                writes.push(audit_gate::FieldWrite { slot, value });
            }
        }

        // Carry the drawer's varied Q-ID into the sealed anchor (not just the
        // often-uniform UDC class) so the matrix O/T lanes get per-content signal.
        // Mirrors Swift DrawerStore capture seal.
        let anchor = substrate_lib::verbs::LatticeAnchor::udc_qid(
            &drawer.udc_code,
            drawer.wikidata_qid.as_deref().unwrap_or(""),
        );
        let stamp = self.hlc.lock().unwrap().send(now * 1000);

        let event = audit_gate::admit(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            RowVerb::Capture,
            None,
            None,
            &writes,
            anchor,
            &self.vocabulary,
            stamp,
            &drawer.added_by,
        )
        // Use Display ({}) not Debug ({:?}) at all gate boundaries so internal
        // Rust type names never reach user-visible error messages.
        .map_err(|v| LocusKitError::InvalidContent(format!("capture rejected by gate: {}", v)))?;

        // Materialized projection row + sealed genesis event.
        self.storage
            .row_store()
            .insert(T_DRAWERS, drawer_values(drawer))
            .map_err(map_storage_err)?;
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&event))
            .map_err(map_storage_err)?;
        Ok(())
    }

    // ------------------------------------------------------------------
    // Node-tree helpers (ADR-017 §3)
    //
    // Query the nodes table directly through the shared Storage to resolve
    // wing/room names ↔ node IDs. Mirrors the Swift DrawerStore private
    // helpers roomNodeIdsInWing, roomNodeId, resolveNodeNames.
    // ------------------------------------------------------------------

    /// All room node IDs under a wing identified by display name.
    ///
    /// Finds the active wing node (depth=1) by lookup_name, then returns
    /// the IDs of all active room nodes (depth=2) under it.
    fn room_node_ids_in_wing(&self, wing: &str) -> Result<Vec<String>, LocusKitError> {
        let wing_lookup = Node::normalize_lookup_name(wing);
        let row_store = self.storage.row_store();
        let wing_rows = row_store
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "lookup_name"),
                        TypedValue::Text(wing_lookup),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "depth"),
                        TypedValue::Int(1),
                    ),
                    StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        let wing_id = match wing_rows.first() {
            Some(row) => string_value_of(row.get("id")),
            None => return Ok(Vec::new()),
        };
        let room_rows = row_store
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "parent_id"),
                        TypedValue::Text(wing_id.clone()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "depth"),
                        TypedValue::Int(2),
                    ),
                    StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                ])),
                &[],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(room_rows.iter().map(|r| string_value_of(r.get("id"))).collect())
    }

    /// Find a specific room node by wing name + room name.
    /// Returns the room node ID, or None if the pair doesn't exist.
    fn room_node_id(&self, wing: &str, room: &str) -> Result<Option<String>, LocusKitError> {
        let wing_lookup = Node::normalize_lookup_name(wing);
        let row_store = self.storage.row_store();
        let wing_rows = row_store
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "lookup_name"),
                        TypedValue::Text(wing_lookup),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "depth"),
                        TypedValue::Int(1),
                    ),
                    StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        let wing_id = match wing_rows.first() {
            Some(row) => string_value_of(row.get("id")),
            None => return Ok(None),
        };
        let room_lookup = Node::normalize_lookup_name(room);
        let room_rows = row_store
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "parent_id"),
                        TypedValue::Text(wing_id.clone()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "lookup_name"),
                        TypedValue::Text(room_lookup),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "depth"),
                        TypedValue::Int(2),
                    ),
                    StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(room_rows.first().map(|r| string_value_of(r.get("id"))))
    }

    /// Resolve parent_node_id values to (wing_name, room_name) pairs.
    ///
    /// Fetches room nodes by their IDs, then fetches their parent wing
    /// nodes to build the display-name lookup. Used by the supersession
    /// cascade to populate tunnel wing/room fields from node tree.
    fn resolve_node_names(
        &self,
        parent_node_ids: &[String],
    ) -> Result<BTreeMap<String, (String, String)>, LocusKitError> {
        if parent_node_ids.is_empty() {
            return Ok(BTreeMap::new());
        }
        let unique: BTreeSet<_> = parent_node_ids.iter().cloned().collect();
        let row_store = self.storage.row_store();
        let room_predicates: Vec<StoragePredicate> = unique
            .iter()
            .map(|id| {
                StoragePredicate::Eq(
                    Column::new(T_NODES, "id"),
                    TypedValue::Text(id.to_string()),
                )
            })
            .collect();
        let room_rows = row_store
            .query(
                T_NODES,
                Some(&StoragePredicate::any(room_predicates)),
                &[],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let mut room_map: BTreeMap<String, (String, String)> = BTreeMap::new();
        let mut wing_ids: BTreeSet<String> = BTreeSet::new();
        for row in &room_rows {
            let id = string_value_of(row.get("id"));
            let display_name = string_value_of(row.get("display_name"));
            let parent_id = string_value_of(row.get("parent_id"));
            wing_ids.insert(parent_id.clone());
            room_map.insert(id, (display_name, parent_id));
        }
        let mut wing_names: BTreeMap<String, String> = BTreeMap::new();
        if !wing_ids.is_empty() {
            let wing_predicates: Vec<StoragePredicate> = wing_ids
                .iter()
                .map(|id| {
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "id"),
                        TypedValue::Text(id.to_string()),
                    )
                })
                .collect();
            let wing_rows = row_store
                .query(
                    T_NODES,
                    Some(&StoragePredicate::any(wing_predicates)),
                    &[],
                    None,
                    None,
                )
                .map_err(map_storage_err)?;
            for row in &wing_rows {
                wing_names.insert(
                    string_value_of(row.get("id")),
                    string_value_of(row.get("display_name")),
                );
            }
        }
        let mut result: BTreeMap<String, (String, String)> = BTreeMap::new();
        for (room_id, (room_display, parent_id)) in &room_map {
            let wing_name = wing_names.get(parent_id).cloned().unwrap_or_default();
            result.insert(room_id.clone(), (wing_name, room_display.clone()));
        }
        Ok(result)
    }

}

// ---------------------------------------------------------------------------
// DrawerStore trait impl
// ---------------------------------------------------------------------------

impl DrawerStore for DrawerStoreCore {
    fn storage(&self) -> Option<Arc<dyn Storage>> {
        Some(Arc::clone(&self.storage))
    }

    fn resolve_node_names(
        &self,
        parent_node_ids: &[String],
    ) -> Result<BTreeMap<String, (String, String)>, LocusKitError> {
        // Delegate to the private helper that queries the nodes table.
        DrawerStoreCore::resolve_node_names(self, parent_node_ids)
    }

    fn read_manifest(&self) -> Result<ManifestValues, LocusKitError> {
        let row_store = self.storage.row_store();
        let rows = row_store
            .query(T_MANIFEST, None, &[], None, None)
            .map_err(map_storage_err)?;
        let mut map: BTreeMap<String, String> = BTreeMap::new();
        for row in &rows {
            let key = string_value_of(row.get("key"));
            let value = string_value_of(row.get("value"));
            map.insert(key, value);
        }
        let get = |k: ManifestKey| map.get(k.as_str()).cloned().unwrap_or_default();
        let get_int = |k: ManifestKey, default: i64| -> i64 {
            map.get(k.as_str())
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(default)
        };
        let get_opt = |k: ManifestKey| map.get(k.as_str()).cloned();
        let get_opt_int = |k: ManifestKey| -> Option<i64> {
            map.get(k.as_str()).and_then(|s| s.parse::<i64>().ok())
        };
        let get_date = |k: ManifestKey| -> i64 {
            map.get(k.as_str())
                .and_then(|s| parse_iso8601(s))
                .unwrap_or(0)
        };

        Ok(ManifestValues {
            manifest_version: if get(ManifestKey::ManifestVersion).is_empty() {
                "1.0".to_string()
            } else {
                get(ManifestKey::ManifestVersion)
            },
            schema_version: if get(ManifestKey::SchemaVersion).is_empty() {
                "1.0".to_string()
            } else {
                get(ManifestKey::SchemaVersion)
            },
            estate_uuid: get(ManifestKey::EstateUUID),
            estate_name: get(ManifestKey::EstateName),
            owner_identifier: get(ManifestKey::OwnerIdentifier),
            lattice_citation: if get(ManifestKey::LatticeCitation).is_empty() {
                "UDC:2024+Wikidata:2024-Q3".to_string()
            } else {
                get(ManifestKey::LatticeCitation)
            },
            framework_profile: if get(ManifestKey::FrameworkProfile).is_empty() {
                "unspecified_v0".to_string()
            } else {
                get(ManifestKey::FrameworkProfile)
            },
            framework_profile_definition: if get(ManifestKey::FrameworkProfileDefinition).is_empty()
            {
                "{}".to_string()
            } else {
                get(ManifestKey::FrameworkProfileDefinition)
            },
            zoom_window_low: get_int(ManifestKey::ZoomWindowLow, 0),
            zoom_window_high: get_int(ManifestKey::ZoomWindowHigh, 99),
            access_posture: get_int(ManifestKey::AccessPosture, 0),
            provenance_defaults: get_int(ManifestKey::ProvenanceDefaults, 0),
            active_storage_mode: get_int(ManifestKey::ActiveStorageMode, 8),
            tables_present: get(ManifestKey::TablesPresent),
            created_at: get_date(ManifestKey::CreatedAt),
            last_modified: get_date(ManifestKey::LastModified),
            bitmap_layout_version: if get(ManifestKey::BitmapLayoutVersion).is_empty() {
                "v1.0".to_string()
            } else {
                get(ManifestKey::BitmapLayoutVersion)
            },
            provenance_bitmap_version: if get(ManifestKey::ProvenanceBitmapVersion).is_empty() {
                "v1.0".to_string()
            } else {
                get(ManifestKey::ProvenanceBitmapVersion)
            },
            federation_group_id: get_opt(ManifestKey::FederationGroupID),
            mining_patterns_hash: get_opt(ManifestKey::MiningPatternsHash),
            tiny_model_id: get_opt(ManifestKey::TinyModelID),
            tiny_model_training_corpus_size: get_opt_int(ManifestKey::TinyModelTrainingCorpusSize),
            operational_bitmap_layouts: get_opt(ManifestKey::OperationalBitmapLayouts),
            ed25519_public_key: get_opt(ManifestKey::Ed25519PublicKey),
            ed25519_private_key_wrapped: get_opt(ManifestKey::Ed25519PrivateKeyWrapped),
        })
    }

    fn set_meta(&self, key: &str, value: &str) -> Result<(), LocusKitError> {
        let mut values = BTreeMap::new();
        values.insert("key".to_string(), TypedValue::Text(key.to_string()));
        values.insert("value".to_string(), TypedValue::Text(value.to_string()));
        self.storage
            .row_store()
            .upsert(T_MANIFEST, values, &["key".to_string()])
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn get_meta(&self, key: &str) -> Result<Option<String>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_MANIFEST,
                Some(&StoragePredicate::Eq(
                    Column::new(T_MANIFEST, "key"),
                    TypedValue::Text(key.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(|r| string_value_of(r.get("value"))))
    }

    // -----------------------------------------------------------------
    // Drawer CRUD
    // -----------------------------------------------------------------

    fn add_drawer(&self, drawer: &Drawer, _now: i64) -> Result<(), LocusKitError> {
        validate_non_empty(&drawer.parent_node_id, "parent_node_id")?;
        validate_non_empty(&drawer.content, "content")?;
        validate_non_empty(&drawer.added_by, "addedBy")?;
        validate_non_empty(&drawer.embedding_model_id, "embeddingModelID")?;
        // I-22 + initial-field legality enforced by the gate on the
        // capture event (prior==None branch runs ForbiddenCombinations),
        // so the standalone validator is retired here as for the mutators.

        // Capture start instant before I/O for latency telemetry.
        // Off-path cost when monitoring is disabled: one Instant::now()
        // call per add_drawer, which is dominated by the storage write.
        let _tel_start = std::time::Instant::now();
        let _tel_now = _now as f64;

        let predecessor = self.find_active_predecessor(&drawer.lineage_id, &drawer.id)?;
        let result = match predecessor {
            Some(prior_id) => self.add_drawer_with_cascade(drawer, &prior_id),
            None => {
                // Gated capture: genesis event + projection row. Capture is
                // the moment of remembering — a gated write, not a bare INSERT.
                self.gated_capture(drawer, _now)
            }
        };

        // Atomically maintain the per-container OR aggregate (spec § 11.5)
        // so recall pruning stays current. Folded here so every add_drawer
        // call — regardless of which code path invokes it — maintains
        // coverage. This is the structural add-coverage guarantee: it is now
        // impossible to add a drawer without updating the container aggregate.
        //
        // The clear-side (withdraw / bit-off) is intentionally a no-op
        // everywhere — a stale set bit is a harmless over-approximation
        // that only forgoes a prune, never causes a false prune. Tightening
        // is done by rebuild_container_fingerprints (called at estate open).
        //
        // Mirrors Swift `Estate.addDrawerCovered`, which is the only public
        // add path on the Swift side and bundles store.addDrawer + FP update.
        if result.is_ok() {
            // Construct a ContainerFingerprintStore view over the same
            // backing Storage and OR the drawer's bitmaps into the room-level
            // and wing-rollup rows. The schema re-open is idempotent.
            //
            // Drawer no longer carries wing/room display names (ADR-017);
            // resolve them from parent_node_id via the node tree.
            let fp_store = ContainerFingerprintStore::new(Arc::clone(&self.storage))?;
            let names = self.resolve_node_names(&[drawer.parent_node_id.clone()])?;
            let (wing, room) = names
                .get(&drawer.parent_node_id)
                .cloned()
                .unwrap_or_default();
            fp_store.or_in(
                &wing,
                &room,
                drawer.adjective_bitmap,
                drawer.operational_bitmap,
                drawer.provenance,
                _now,
            )?;
        }

        // Emit capture telemetry at the post-write operation boundary.
        // This is additive: the return value and all side effects are
        // already determined before emit_drawer_capture is called.
        if result.is_ok() {
            crate::telemetry::emit_drawer_capture(&_tel_start, _tel_now, &self.estate_uuid);
        }
        result
    }

    fn get_drawer(&self, id: &str) -> Result<Option<Drawer>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        match rows.first().map(drawer_from_row).transpose()? {
            Some(d) => Ok(Some(d)),
            None => Ok(None),
        }
    }

    fn living_successor_in_lineage(
        &self,
        lineage_id: &str,
        excluding_id: &str,
    ) -> Result<Option<String>, LocusKitError> {
        // Cluster-A membership is
        // `g_state_cluster < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW`
        // (the Cluster-B floor, 16, per cookbook §2.3). `g_state_cluster`
        // stores the raw 6-bit state value, so active/pending/contested/
        // accepted = 0..=3 all qualify as living. Boundary sourced from
        // the RowState automaton. Mirror of Swift `livingSuccessorInLineage`.
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "lineageID"),
                        TypedValue::Text(lineage_id.to_string()),
                    ),
                    StoragePredicate::Neq(
                        Column::new(T_DRAWERS, "id"),
                        TypedValue::Text(excluding_id.to_string()),
                    ),
                    StoragePredicate::Lt(
                        Column::new(T_DRAWERS, "g_state_cluster"),
                        TypedValue::Int(RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW as i64),
                    ),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(|r| string_value_of(r.get("id"))))
    }

    fn drawers_in_wing(&self, wing: &str) -> Result<Vec<Drawer>, LocusKitError> {
        let _tel_start = std::time::Instant::now();

        // ADR-017 NT-L2: resolve wing name → room node IDs via node tree,
        // then query drawers by parent_node_id IN (...).
        let room_ids = self.room_node_ids_in_wing(wing)?;
        if room_ids.is_empty() {
            crate::telemetry::emit_drawer_query(&_tel_start, 0.0, 0, &self.estate_uuid, "wing");
            return Ok(Vec::new());
        }
        let predicates: Vec<StoragePredicate> = room_ids
            .iter()
            .map(|id| {
                StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "parent_node_id"),
                    TypedValue::Text(id.clone()),
                )
            })
            .collect();
        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_skip_corrupt(
                T_DRAWERS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::any(predicates),
                    StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_DRAWERS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let drawers = decode_rows_skip_corrupt(&rows, "drawers_in_wing")?;

        crate::telemetry::emit_drawer_query(&_tel_start, 0.0, drawers.len(), &self.estate_uuid, "wing");
        Ok(drawers)
    }

    fn drawers_in_wing_room(&self, wing: &str, room: &str) -> Result<Vec<Drawer>, LocusKitError> {
        // ADR-017 NT-L2: resolve wing/room → room node ID via node tree.
        let room_id = match self.room_node_id(wing, room)? {
            Some(id) => id,
            None => return Ok(Vec::new()),
        };
        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_skip_corrupt(
                T_DRAWERS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "parent_node_id"),
                        TypedValue::Text(room_id),
                    ),
                    StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_DRAWERS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let drawers = decode_rows_skip_corrupt(&rows, "drawers_in_wing_room")?;

        Ok(drawers)
    }

    fn drawers_by_source(&self, source_file: &str) -> Result<Vec<Drawer>, LocusKitError> {
        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_skip_corrupt(
                T_DRAWERS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "sourceFile"),
                        TypedValue::Text(source_file.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
                ])),
                &[
                    OrderClause::new(
                        Column::new(T_DRAWERS, "chunkIndex"),
                        OrderDirection::Ascending,
                    ),
                    OrderClause::new(Column::new(T_DRAWERS, "filedAt"), OrderDirection::Ascending),
                ],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let drawers = decode_rows_skip_corrupt(&rows, "drawers_by_source")?;

        Ok(drawers)
    }

    fn all_drawers(&self) -> Result<Vec<Drawer>, LocusKitError> {
        // Capture start instant before I/O for latency telemetry.
        let _tel_start = std::time::Instant::now();

        // Use query_skip_corrupt so rows with corrupt timestamp columns (e.g.
        // a poison filedAt like "+58432-..." from a bad Vault import or
        // millisecond-vs-seconds epoch confusion) are skipped at the SQLite
        // cursor level and do not abort the entire corpus scan.
        //
        // Compound sort key: (filedAt ASC, id ASC). The id secondary term
        // breaks ties within the same filedAt so the result is a deterministic
        // total order. id is the declared TEXT primary key of the drawers
        // table — present in SQLite, PostgreSQL, and InMemory backends.
        // Using id (not rowid) makes the tie-break portable to PostgreSQL where
        // rowid is undefined (c-recall-portable fix). DESC variants use
        // (filedAt DESC, id DESC), which is exactly reverse(ASC).
        // Mirrors Swift's compound OrderClause in DrawerStore.allDrawers.
        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_skip_corrupt(
                T_DRAWERS,
                None,
                &[
                    OrderClause::new(Column::new(T_DRAWERS, "filedAt"), OrderDirection::Ascending),
                    OrderClause::new(Column::new(T_DRAWERS, "id"), OrderDirection::Ascending),
                ],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        // decode_rows_skip_corrupt handles any remaining drawer_from_row failures.
        let drawers = decode_rows_skip_corrupt(&rows, "all_drawers")?;


        // Emit query telemetry at the post-query operation boundary.
        crate::telemetry::emit_drawer_query(&_tel_start, 0.0, drawers.len(), &self.estate_uuid, "all");
        Ok(drawers)
    }

    fn all_drawers_bounded(&self, limit: Option<usize>) -> Result<Vec<Drawer>, LocusKitError> {
        // Bounded corpus scan for the recall locus lane. Passes `limit` to
        // the storage query so only the first `limit` rows (in filedAt order)
        // are materialised. When `limit` is `None` this is equivalent to
        // `all_drawers()`.
        //
        // This path loads full rows including the content blob — it is the
        // `.full` recall scan. The no-blob `.structured` scan goes through
        // `all_drawers_bounded_projected`, which uses `RowStore::query_projected`
        // to omit the content column. The behavioral contract (bounded scan,
        // filedAt order, correct result set) matches the Swift port.
        //
        // Compound sort key: (filedAt ASC, id ASC) for deterministic total
        // order — ties in filedAt are broken by id (declared TEXT primary key,
        // portable across SQLite + PostgreSQL + InMemory). DESC variant uses
        // the same compound key with both directions flipped.
        let _tel_start = std::time::Instant::now();

        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_skip_corrupt(
                T_DRAWERS,
                None,
                &[
                    OrderClause::new(Column::new(T_DRAWERS, "filedAt"), OrderDirection::Ascending),
                    OrderClause::new(Column::new(T_DRAWERS, "id"), OrderDirection::Ascending),
                ],
                limit,
                None,
            )
            .map_err(map_storage_err)?;
        let drawers = decode_rows_skip_corrupt(&rows, "all_drawers_bounded")?;


        crate::telemetry::emit_drawer_query(
            &_tel_start,
            0.0,
            drawers.len(),
            &self.estate_uuid,
            "all_bounded",
        );
        Ok(drawers)
    }

    fn all_drawers_bounded_projected(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        // No-blob bounded corpus scan for the `.structured` recall lane.
        // Projects to the structured column set (every drawer column except
        // `content`) via `query_projected`, so the content blob is never read
        // off disk and `drawer_from_row` decodes the absent column to `""`.
        // This is the Rust parity of Swift's `.structured` recall projection
        // (spec § 7.3). `limit` is pushed to the storage layer, filedAt order.
        let _tel_start = std::time::Instant::now();

        // Use query_projected_skip_corrupt so corrupt timestamp columns in the
        // structured projection (filedAt is still included; only content is
        // excluded) do not abort the scan. Skipped rows are logged at the
        // storage level; decode_rows_skip_corrupt handles any remaining
        // drawer_from_row failures.
        //
        // Compound sort key: (filedAt ASC, id ASC) — same deterministic total
        // order as all_drawers_bounded (full path) and all_drawers. id is the
        // declared TEXT primary key, portable across all backends.
        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_projected_skip_corrupt(
                T_DRAWERS,
                DRAWER_STRUCTURED_COLUMNS,
                None,
                &[
                    OrderClause::new(Column::new(T_DRAWERS, "filedAt"), OrderDirection::Ascending),
                    OrderClause::new(Column::new(T_DRAWERS, "id"), OrderDirection::Ascending),
                ],
                limit,
                None,
            )
            .map_err(map_storage_err)?;
        let drawers = decode_rows_skip_corrupt(&rows, "all_drawers_bounded_projected")?;


        crate::telemetry::emit_drawer_query(
            &_tel_start,
            0.0,
            drawers.len(),
            &self.estate_uuid,
            "all_bounded_structured",
        );
        Ok(drawers)
    }

    // -----------------------------------------------------------------
    // P4-secfix: DESC-ordered bounded scan overrides.
    //
    // The trait defaults for all_drawers_bounded_desc and
    // all_drawers_bounded_projected_desc call all_drawers() then reverse
    // in memory — correct but O(N). These overrides push the ORDER BY
    // Descending + LIMIT directly to the storage layer so only `limit`
    // rows are materialised, matching the efficiency of the ASC path.
    // -----------------------------------------------------------------

    fn all_drawers_bounded_desc(&self, limit: Option<usize>) -> Result<Vec<Drawer>, LocusKitError> {
        // Newest-first bounded scan. Supplies (filedAt DESC, id DESC) to the
        // storage layer so the most-recently-filed drawers are returned within
        // the cap. The id secondary term (declared TEXT primary key) breaks
        // ties within the same filedAt, making this the exact reverse of the
        // (filedAt ASC, id ASC) total order from all_drawers / all_drawers_bounded.
        // Using id (not rowid) is portable to PostgreSQL (c-recall-portable fix).
        // Mirrors Swift's compound OrderClause.
        let _tel_start = std::time::Instant::now();

        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_skip_corrupt(
                T_DRAWERS,
                None,
                &[
                    OrderClause::new(Column::new(T_DRAWERS, "filedAt"), OrderDirection::Descending),
                    OrderClause::new(Column::new(T_DRAWERS, "id"), OrderDirection::Descending),
                ],
                limit,
                None,
            )
            .map_err(map_storage_err)?;
        let drawers = decode_rows_skip_corrupt(&rows, "all_drawers_bounded_desc")?;

        crate::telemetry::emit_drawer_query(
            &_tel_start,
            0.0,
            drawers.len(),
            &self.estate_uuid,
            "all_bounded_desc",
        );
        Ok(drawers)
    }

    fn all_drawers_bounded_projected_desc(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        // Newest-first no-blob bounded scan. Combines (filedAt DESC, id DESC)
        // ordering with the structured projection (content column omitted) for
        // the common recall path where content predicates are absent and
        // hydration is Structured. The id tie-break (declared TEXT primary key)
        // makes this the exact reverse of the ASC projected path, and is
        // portable to PostgreSQL where rowid is undefined (c-recall-portable).
        let _tel_start = std::time::Instant::now();

        let (rows, _skipped) = self
            .storage
            .row_store()
            .query_projected_skip_corrupt(
                T_DRAWERS,
                DRAWER_STRUCTURED_COLUMNS,
                None,
                &[
                    OrderClause::new(Column::new(T_DRAWERS, "filedAt"), OrderDirection::Descending),
                    OrderClause::new(Column::new(T_DRAWERS, "id"), OrderDirection::Descending),
                ],
                limit,
                None,
            )
            .map_err(map_storage_err)?;
        let drawers = decode_rows_skip_corrupt(&rows, "all_drawers_bounded_projected_desc")?;

        crate::telemetry::emit_drawer_query(
            &_tel_start,
            0.0,
            drawers.len(),
            &self.estate_uuid,
            "all_bounded_structured_desc",
        );
        Ok(drawers)
    }

    fn drawer_ids(&self) -> Result<Vec<RowID>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(T_DRAWERS, None, &[], None, None)
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(|r| string_value_of(r.get("id"))).collect())
    }

    // -----------------------------------------------------------------
    // Bitmap mutation paths
    // -----------------------------------------------------------------

    fn mutate_provenance(
        &self,
        drawer_id: &str,
        new_provenance: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        validate_non_empty(drawer_id, "drawerId")?;
        validate_non_empty(changed_by, "changedBy")?;
        self.gated_column_write(
            drawer_id,
            audit_gate::Column::Provenance,
            new_provenance,
            changed_by,
            reason,
            now,
        )
    }

    fn mutate_adjective(
        &self,
        drawer_id: &str,
        new_adjective: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        validate_non_empty(drawer_id, "drawerId")?;
        validate_non_empty(changed_by, "changedBy")?;
        // I-22 (secret+exportable) is enforced inside the gate's basis
        // check now (SubstrateLib), so no separate validator is needed.
        self.gated_column_write(
            drawer_id,
            audit_gate::Column::Adjective,
            new_adjective,
            changed_by,
            reason,
            now,
        )
    }

    fn mutate_operational(
        &self,
        drawer_id: &str,
        new_operational: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        validate_non_empty(drawer_id, "drawerId")?;
        validate_non_empty(changed_by, "changedBy")?;
        self.gated_column_write(
            drawer_id,
            audit_gate::Column::Operational,
            new_operational,
            changed_by,
            reason,
            now,
        )
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
        validate_non_empty(drawer_id, "drawerId")?;
        validate_non_empty(changed_by, "changedBy")?;

        // S-1 cascade (2026-05-27): read all three bitmaps so we can
        // construct BitmapFields and route through SubstrateLib's full
        // validate (legality + ForbiddenCombinations.check enforcing
        // cookbook §9.5.1 "accepted ⇒ trust ≥ canonical"). S-5
        // (tombstone bitmap-scrub) defused in SubstrateLib pending F17.
        // Use the existing read_drawer_bitmap helper for all three
        // columns. Three queries vs one is wasteful but the alternative
        // refactor would touch the helper signature; keeping it simple
        // for this cascade.
        let prior_bitmap = self.read_drawer_bitmap(drawer_id, "adjectiveBitmap")?;
        let prior_operational = self.read_drawer_bitmap(drawer_id, "operationalBitmap")?;
        let prior_provenance = self.read_drawer_bitmap(drawer_id, "provenance")?;

        // F18: cookbook §2.3 state at bits 0-5; read + rewrite via bit_field.
        let prior_state = State::from_raw(bit_field::extract_field(prior_bitmap, 0, 6));
        let new_bitmap = bit_field::write_field(new_state.raw_value(), prior_bitmap, 0, 6);

        let _ = (
            prior_operational,
            prior_provenance,
            prior_state,
            new_bitmap,
        );

        // Route through the substrate write gate (DECISION_CLOCK_TRIANGLE_
        // TIME_MODEL): RMW the state field into the snapshot, run the
        // basis automaton + I-22 (subsuming validate_with_fields), enforce
        // verb/state consistency, assign the deterministic content-id, and
        // emit the sealed snapshot event. State is verb-driven, expressed
        // as a FieldWrite.
        let row_uuid = require_uuid(drawer_id, "drawerId")?;
        let prior = BitmapFields {
            adjective: prior_bitmap as u64,
            operational: prior_operational as u64,
            provenance: prior_provenance as u64,
        };
        // mutate_state does not touch the lattice anchor; before == after.
        let udc = self.read_drawer_udc(drawer_id)?;
        let anchor = substrate_lib::verbs::LatticeAnchor::udc(&udc);
        let state_slot = audit_gate::FieldSlot::with_values(
            audit_gate::Column::Adjective,
            0,
            6,
            "state",
            &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33],
        );
        // One tick per logical mutation.
        let stamp = self.hlc.lock().unwrap().send(now * 1000);
        let event = audit_gate::admit(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            via,
            Some(prior),
            Some(anchor),
            &[audit_gate::FieldWrite {
                slot: state_slot,
                value: new_state.raw_value(),
            }],
            anchor,
            &self.vocabulary,
            stamp,
            changed_by,
        )
        .map_err(|v| {
            // Use Display ({}) not Debug ({:?}) so GateViolation's internal type
            // chain (BasisViolation(IllegalTransition(...))) does not appear in
            // user-visible error text. GateViolation::Display emits clean English.
            LocusKitError::InvalidContent(format!("state mutation rejected by gate: {}", v))
        })?;

        // Materialized projection: write the merged snapshot to the live
        // drawers row. Append the sealed event to the audit log (truth).
        let row_store = self.storage.row_store();
        let mut update_vals = BTreeMap::new();
        update_vals.insert(
            "adjectiveBitmap".to_string(),
            TypedValue::Bitmap(event.after_bitmaps.0),
        );
        row_store
            .update(
                T_DRAWERS,
                update_vals,
                &StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(drawer_id.to_string()),
                ),
            )
            .map_err(map_storage_err)?;
        // Thread the caller-supplied reason into the event so it is
        // persisted in the audit table's `reason` column.
        let event = substrate_lib::verbs::AuditEvent {
            reason: reason.map(|s| s.to_string()),
            ..event
        };
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&event))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn lineage_chain(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        let row_store = self.storage.row_store();
        // Step 1: look up the drawer's lineageID.
        let rows = row_store
            .query_projected(
                T_DRAWERS,
                &["lineageID"],
                Some(&StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(drawer_id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        let lineage_id = match rows.first().and_then(|r| r.get("lineageID")) {
            Some(TypedValue::Text(s)) if !s.is_empty() => s.clone(),
            _ => return Ok(vec![]),
        };
        // Step 2: query all drawers sharing this lineageID.
        let chain = row_store
            .query_projected(
                T_DRAWERS,
                &["id"],
                Some(&StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "lineageID"),
                    TypedValue::Text(lineage_id),
                )),
                &[],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(chain.iter().map(|r| string_value_of(r.get("id"))).collect())
    }

    fn expunge_gated(
        &self,
        drawer_id: &str,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
        seal_audit: bool,
    ) -> Result<substrate_lib::verbs::AuditEvent, LocusKitError> {
        validate_non_empty(drawer_id, "drawerId")?;
        validate_non_empty(changed_by, "changedBy")?;

        // Resolve the full lineage chain. All members — active,
        // superseded, tombstoned — are in scope for content scrub.
        let lineage_ids = self.lineage_chain(drawer_id)?;

        // Read all three bitmaps so we can construct BitmapFields and
        // route through SubstrateLib's full validate.
        let prior_bitmap = self.read_drawer_bitmap(drawer_id, "adjectiveBitmap")?;
        let prior_operational = self.read_drawer_bitmap(drawer_id, "operationalBitmap")?;
        let prior_provenance = self.read_drawer_bitmap(drawer_id, "provenance")?;

        let row_uuid = require_uuid(drawer_id, "drawerId")?;
        let prior = BitmapFields {
            adjective: prior_bitmap as u64,
            operational: prior_operational as u64,
            provenance: prior_provenance as u64,
        };
        let udc = self.read_drawer_udc(drawer_id)?;
        let anchor = substrate_lib::verbs::LatticeAnchor::udc(&udc);

        // Two FieldWrites in one admit call.
        // 1) State slot: shift 0, width 6 → 33 (tombstoned).
        let state_slot = audit_gate::FieldSlot::with_values(
            audit_gate::Column::Adjective,
            0,
            6,
            "state",
            &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33],
        );
        // 2) Flags slot: shift 24, width 3 (F17.2 widening, commit
        //    5a8ea56). Bit 24 = state_extension; bit 25 =
        //    lineage_clustering; bit 26 = dreaming_recalc_required.
        //    Expunge sets bit 26 (the third bit of the 3-bit field,
        //    raw value 0b100) while preserving bits 24-25.
        let flags_slot = audit_gate::FieldSlot::new(audit_gate::Column::Adjective, 24, 3, "flags");
        let prior_flags_value = bit_field::extract_field(prior_bitmap, 24, 3);
        let new_flags_value = (prior_flags_value & 0b011) | 0b100;

        // One tick per logical mutation.
        let stamp = self.hlc.lock().unwrap().send(now * 1000);
        let event = audit_gate::admit(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            RowVerb::Tombstone,
            Some(prior),
            Some(anchor),
            &[
                audit_gate::FieldWrite {
                    slot: state_slot.clone(),
                    value: State::Tombstoned.raw_value(),
                },
                audit_gate::FieldWrite {
                    slot: flags_slot.clone(),
                    value: new_flags_value,
                },
            ],
            anchor,
            &self.vocabulary,
            stamp,
            changed_by,
        )
        .map_err(|v| LocusKitError::InvalidContent(format!("expunge rejected by gate: {}", v)))?;

        // Materialized projection: write the merged adjective snapshot,
        // zero the content blob, stamp tombstonedAt.
        let row_store = self.storage.row_store();
        let mut update_vals = BTreeMap::new();
        update_vals.insert(
            "adjectiveBitmap".to_string(),
            TypedValue::Bitmap(event.after_bitmaps.0),
        );
        update_vals.insert("content".to_string(), TypedValue::Text(String::new()));
        update_vals.insert("tombstonedAt".to_string(), TypedValue::Timestamp(now));
        row_store
            .update(
                T_DRAWERS,
                update_vals,
                &StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "id"),
                    TypedValue::Text(drawer_id.to_string()),
                ),
            )
            .map_err(map_storage_err)?;

        // Record head drawer in the erasure ledger (ADR-017 §17).
        // Direct row_store insert — mirrors Swift ErasureLedgerOps.
        let mut ledger_vals = BTreeMap::new();
        ledger_vals.insert(
            "drawer_id".to_string(),
            TypedValue::Text(drawer_id.to_string()),
        );
        ledger_vals.insert("erased_hlc".to_string(), TypedValue::Hlc(stamp));
        let _ = row_store.insert("erasure_ledger", ledger_vals);
        // Ignore duplicate-key if already in the ledger.

        // ── Scrub every lineage sibling ──
        for sibling_id in &lineage_ids {
            if sibling_id == drawer_id {
                continue;
            }
            let sib_bitmap = match self.read_drawer_bitmap(sibling_id, "adjectiveBitmap") {
                Ok(v) => v,
                Err(_) => continue,
            };
            let sib_state = bit_field::extract_field(sib_bitmap, 0, 6);

            if sib_state == State::Tombstoned.raw_value() {
                // Already tombstoned — just ensure content is empty.
                let mut vals = BTreeMap::new();
                vals.insert("content".to_string(), TypedValue::Text(String::new()));
                let _ = row_store.update(
                    T_DRAWERS,
                    vals,
                    &StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "id"),
                        TypedValue::Text(sibling_id.to_string()),
                    ),
                );
            } else {
                // Gate the sibling through the state machine.
                let sib_uuid = require_uuid(sibling_id, "siblingId")?;
                let sib_operational =
                    self.read_drawer_bitmap(sibling_id, "operationalBitmap")?;
                let sib_provenance = self.read_drawer_bitmap(sibling_id, "provenance")?;
                let sib_prior = BitmapFields {
                    adjective: sib_bitmap as u64,
                    operational: sib_operational as u64,
                    provenance: sib_provenance as u64,
                };
                let sib_udc = self.read_drawer_udc(sibling_id)?;
                let sib_anchor = substrate_lib::verbs::LatticeAnchor::udc(&sib_udc);
                let sib_flags_value = bit_field::extract_field(sib_bitmap, 24, 3);
                let sib_new_flags = (sib_flags_value & 0b011) | 0b100;

                let sib_stamp = self.hlc.lock().unwrap().send(now * 1000);
                let sib_result = audit_gate::admit(
                    self.estate_uuid.as_u128(),
                    substrate_lib::verbs::RowId(sib_uuid.as_u128()),
                    substrate_lib::verbs::NounType::Drawer,
                    RowVerb::Tombstone,
                    Some(sib_prior),
                    Some(sib_anchor),
                    &[
                        audit_gate::FieldWrite {
                            slot: state_slot.clone(),
                            value: State::Tombstoned.raw_value(),
                        },
                        audit_gate::FieldWrite {
                            slot: flags_slot.clone(),
                            value: sib_new_flags,
                        },
                    ],
                    sib_anchor,
                    &self.vocabulary,
                    sib_stamp,
                    changed_by,
                );

                if let Ok(sib_event) = sib_result {
                    let mut vals = BTreeMap::new();
                    vals.insert(
                        "adjectiveBitmap".to_string(),
                        TypedValue::Bitmap(sib_event.after_bitmaps.0),
                    );
                    vals.insert("content".to_string(), TypedValue::Text(String::new()));
                    vals.insert("tombstonedAt".to_string(), TypedValue::Timestamp(now));
                    let _ = row_store.update(
                        T_DRAWERS,
                        vals,
                        &StoragePredicate::Eq(
                            Column::new(T_DRAWERS, "id"),
                            TypedValue::Text(sibling_id.to_string()),
                        ),
                    );
                    if seal_audit {
                        let sib_event = substrate_lib::verbs::AuditEvent {
                            reason: Some(format!(
                                "lineage expunge cascade from {}",
                                drawer_id
                            )),
                            ..sib_event
                        };
                        let _ = self
                            .storage
                            .audit_log()
                            .append(pk_audit_event_from(&sib_event));
                    }
                }
                // If the gate rejects (e.g. accepted → tombstoned is
                // S-3 forbidden), skip silently. Accepted rows survive.
            }

            // Record sibling in the erasure ledger.
            let mut sib_ledger = BTreeMap::new();
            sib_ledger.insert(
                "drawer_id".to_string(),
                TypedValue::Text(sibling_id.to_string()),
            );
            sib_ledger.insert("erased_hlc".to_string(), TypedValue::Hlc(stamp));
            let _ = row_store.insert("erasure_ledger", sib_ledger);
        }

        if seal_audit {
            self.storage
                .audit_log()
                .append(pk_audit_event_from(&event))
                .map_err(map_storage_err)?;
        }

        let event = substrate_lib::verbs::AuditEvent {
            reason: reason.map(|s| s.to_string()),
            ..event
        };
        Ok(event)
    }

    fn seal_expunge_audit(
        &self,
        event: &substrate_lib::verbs::AuditEvent,
    ) -> Result<(), LocusKitError> {
        // Append the gate-produced success event produced earlier by
        // expunge_gated(seal_audit: false). This is the §B-2a success seal:
        // storage (step 1) + cross-kit delete (step 2) both succeeded.
        self.storage
            .audit_log()
            .append(pk_audit_event_from(event))
            .map_err(map_storage_err)
    }

    fn seal_expunge_orphan_audit(
        &self,
        drawer_id: &str,
        success_event: &substrate_lib::verbs::AuditEvent,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        // Construct an "expungeOrphan" audit event to record the partial
        // expunge honestly: storage tombstoned+scrubbed (step 1 succeeded),
        // but the cross-kit vector delete (step 2) failed. The verb string
        // "expungeOrphan" is preserved in the substrate audit trail for
        // forensic inspection; verb_from_str maps it to
        // UnifiedAuditVerb::Expunge in the unified log so downstream
        // consumers see the storage-level expunge without requiring a
        // distinct ARIA verb.
        let _ = drawer_id; // rowId is carried by success_event.row_id
        let stamp = self.hlc.lock().unwrap().send(now * 1000);
        let event_id = substrate_lib::audit_gate::content_id(
            success_event.estate_uuid,
            success_event.row_id,
            &stamp,
            "expungeOrphan",
            success_event.after_bitmaps,
            success_event.after_lattice_anchor.clone(),
        );
        let orphan = substrate_lib::verbs::AuditEvent {
            event_id,
            estate_uuid: success_event.estate_uuid,
            row_id: success_event.row_id,
            hlc: stamp,
            verb: "expungeOrphan".to_string(),
            before_bitmaps: success_event.before_bitmaps,
            after_bitmaps: success_event.after_bitmaps,
            before_lattice_anchor: success_event.before_lattice_anchor.clone(),
            after_lattice_anchor: success_event.after_lattice_anchor.clone(),
            actor: changed_by.to_string(),
            // orphan events have no caller-supplied reason.
            reason: None,
        };
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&orphan))
            .map_err(map_storage_err)
    }

    fn seal_expunge_orphan_for_sweep(
        &self,
        drawer_id: &str,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        // Build a synthetic "expungeOrphan" audit event from the drawer's
        // current on-disk state. The original step-1 gate event was lost
        // (crash window or double-failure); we reconstruct using the
        // tombstoned drawer's current bitmaps.
        //
        // "before_bitmaps" is set to None (unknown) because the pre-tombstone
        // snapshot is unavailable. The audit event accurately records the
        // expunge happened and the vector orphan state; the missing before
        // bitmaps are acceptable for crash-recovery forensics.
        let row_uuid = require_uuid(drawer_id, "drawerId")?;
        let adj_bitmap = self.read_drawer_bitmap(drawer_id, "adjectiveBitmap")?;
        let op_bitmap = self.read_drawer_bitmap(drawer_id, "operationalBitmap")?;
        let prov_bitmap = self.read_drawer_bitmap(drawer_id, "provenance")?;
        let udc = self.read_drawer_udc(drawer_id)?;
        let anchor = substrate_lib::verbs::LatticeAnchor::udc(&udc);
        let after_bitmaps: (i64, i64, i64) = (adj_bitmap, op_bitmap, prov_bitmap);

        let stamp = self.hlc.lock().unwrap().send(now * 1000);
        let event_id = substrate_lib::audit_gate::content_id(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            &stamp,
            "expungeOrphan",
            after_bitmaps,
            anchor.clone(),
        );
        let orphan = substrate_lib::verbs::AuditEvent {
            event_id,
            estate_uuid: self.estate_uuid.as_u128(),
            row_id: substrate_lib::verbs::RowId(row_uuid.as_u128()),
            hlc: stamp,
            verb: "expungeOrphan".to_string(),
            before_bitmaps: None,       // pre-tombstone snapshot unavailable (sweep path)
            after_bitmaps,
            before_lattice_anchor: None, // pre-tombstone anchor unavailable (sweep path)
            after_lattice_anchor: anchor,
            actor: changed_by.to_string(),
            // sweep-path orphan events have no caller-supplied reason.
            reason: None,
        };
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&orphan))
            .map_err(map_storage_err)
    }

    /// Zero the `content` column for every row in the `drawers` table.
    /// Used by `GLKCoordinator::destroy` to erase all drawer content blobs
    /// from LocusKit's SQLite storage as part of the estate destruction
    /// sequence (secfix/ws2-coredelete). Runs before `close()` so the
    /// storage connection is still live.
    ///
    /// The operation is a bulk UPDATE with a `1=1` predicate — one SQL
    /// statement regardless of row count. On the InMemory backend the
    /// predicate resolves to `StoragePredicate::IsTrue`.
    ///
    /// Does NOT delete the manifest row or audit events — those remain as
    /// a forensic record that the estate existed. The SQLite FILE is
    /// deleted by the application layer (moot-mgr) after this call returns.
    fn wipe_all_content(&self) -> Result<(), LocusKitError> {
        let row_store = self.storage.row_store();
        let mut values = std::collections::BTreeMap::new();
        values.insert("content".to_string(), TypedValue::Text(String::new()));
        row_store
            .update(T_DRAWERS, values, &StoragePredicate::IsTrue)
            .map_err(map_storage_err)?;
        Ok(())
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
        validate_non_empty(drawer_id, "drawerId")?;
        validate_non_empty(changed_by, "changedBy")?;

        // Read all three bitmaps so we can construct BitmapFields.
        let prior_bitmap = self.read_drawer_bitmap(drawer_id, "adjectiveBitmap")?;
        let prior_operational = self.read_drawer_bitmap(drawer_id, "operationalBitmap")?;
        let prior_provenance = self.read_drawer_bitmap(drawer_id, "provenance")?;

        let row_uuid = require_uuid(drawer_id, "drawerId")?;
        let prior = BitmapFields {
            adjective: prior_bitmap as u64,
            operational: prior_operational as u64,
            provenance: prior_provenance as u64,
        };

        // Prior anchor is read from the row's current udcCode.
        let prior_udc = self.read_drawer_udc(drawer_id)?;
        let prior_anchor = substrate_lib::verbs::LatticeAnchor::udc(&prior_udc);

        // After anchor: the new lattice if provided, else the prior anchor.
        let after_udc: String;
        let after_anchor = if let Some(ref new_lat) = to_lattice {
            after_udc = new_lat.udc_code.clone();
            substrate_lib::verbs::LatticeAnchor::udc(&after_udc)
        } else {
            after_udc = prior_udc.clone();
            prior_anchor
        };

        // Reanchor is a placement move — no FieldWrites. The gate records the
        // anchor delta via prior/after anchor and validates verb=Mutate
        // (active→active self-loop). Empty writes slice is correct here.
        let stamp = self.hlc.lock().unwrap().send(now * 1000);
        let event = audit_gate::admit(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            RowVerb::Mutate,
            Some(prior),
            Some(prior_anchor),
            &[],
            after_anchor,
            &self.vocabulary,
            stamp,
            changed_by,
        )
        .map_err(|v| {
            LocusKitError::InvalidContent(format!("reanchor rejected by gate: {}", v))
        })?;

        // Materialized projection: update placement columns + append the
        // sealed event. Bitmaps are unchanged by a reanchor.
        let row_store = self.storage.row_store();
        let mut update_vals = BTreeMap::new();
        if let Some(ref new_lat) = to_lattice {
            update_vals.insert(
                "udcCode".to_string(),
                TypedValue::Text(new_lat.udc_code.clone()),
            );
            update_vals.insert(
                "udcFacets".to_string(),
                new_lat
                    .udc_facets
                    .as_deref()
                    .map(|s| TypedValue::Text(s.to_string()))
                    .unwrap_or(TypedValue::Null),
            );
            update_vals.insert(
                "wikidataQID".to_string(),
                new_lat
                    .wikidata_qid
                    .as_deref()
                    .map(|s| TypedValue::Text(s.to_string()))
                    .unwrap_or(TypedValue::Null),
            );
            update_vals.insert(
                "wikidataQidsSecondary".to_string(),
                new_lat
                    .wikidata_qids_secondary
                    .as_deref()
                    .map(|s| TypedValue::Text(s.to_string()))
                    .unwrap_or(TypedValue::Null),
            );
        }
        // ADR-017: resolve wing/room names to parent_node_id via
        // NodeStore create-on-demand, then update parent_node_id.
        if to_room.is_some() || to_wing.is_some() {
            let current_parent_id = {
                let rows = self
                    .storage
                    .row_store()
                    .query(
                        T_DRAWERS,
                        Some(&StoragePredicate::Eq(
                            Column::new(T_DRAWERS, "id"),
                            TypedValue::Text(drawer_id.to_string()),
                        )),
                        &[],
                        Some(1),
                        None,
                    )
                    .map_err(map_storage_err)?;
                rows.first()
                    .map(|r| string_value_of(r.get("parent_node_id")))
                    .unwrap_or_default()
            };
            let current_names = self
                .resolve_node_names(&[current_parent_id.clone()])?;
            let current = current_names
                .get(&current_parent_id)
                .cloned()
                .unwrap_or_default();
            let resolved_wing = to_wing.unwrap_or(&current.0);
            let resolved_room = to_room.unwrap_or(&current.1);
            // Create-on-demand via NodeStore over the same storage.
            let ns = crate::node_store::NodeStore::new(
                Arc::clone(&self.storage), None);
            if let Some(root) = ns.root_node()? {
                let wing_node = ns.create_node(resolved_wing, root.id, now)?;
                let room_node = ns.create_node(resolved_room, wing_node.id, now)?;
                update_vals.insert(
                    "parent_node_id".to_string(),
                    TypedValue::Text(room_node.id.to_string()),
                );
            }
        }
        if !update_vals.is_empty() {
            row_store
                .update(
                    T_DRAWERS,
                    update_vals,
                    &StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "id"),
                        TypedValue::Text(drawer_id.to_string()),
                    ),
                )
                .map_err(map_storage_err)?;
        }
        // Thread the caller-supplied reason into the event before persisting.
        let event = substrate_lib::verbs::AuditEvent {
            reason: reason.map(|s| s.to_string()),
            ..event
        };
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&event))
            .map_err(map_storage_err)?;
        let _ = after_udc; // after_udc is not persisted as a separate column
        Ok(())
    }

    // -----------------------------------------------------------------
    // Tunnel CRUD
    // -----------------------------------------------------------------

    fn add_tunnel(&self, tunnel: &Tunnel) -> Result<(), LocusKitError> {
        validate_non_empty(&tunnel.source_wing, "sourceWing")?;
        validate_non_empty(&tunnel.source_room, "sourceRoom")?;
        validate_non_empty(&tunnel.target_wing, "targetWing")?;
        validate_non_empty(&tunnel.target_room, "targetRoom")?;
        validate_non_empty(&tunnel.label, "label")?;
        validate_non_empty(&tunnel.added_by, "addedBy")?;

        // One parent per child (ADR-017 §11): a drawer may have at
        // most one active Parent tunnel. Kit-level constraint
        // (not a DB-level partial unique index, which PersistenceKit's
        // schema declaration does not expose).
        if tunnel.kind == TunnelKind::Parent {
            if let Some(child_id) = &tunnel.source_drawer_id {
                let existing = self
                    .storage
                    .row_store()
                    .query(
                        T_TUNNELS,
                        Some(&StoragePredicate::all(vec![
                            StoragePredicate::Eq(
                                Column::new(T_TUNNELS, "kind_id"),
                                TypedValue::Int(TunnelKind::Parent.raw_value()),
                            ),
                            StoragePredicate::Eq(
                                Column::new(T_TUNNELS, "sourceDrawerId"),
                                TypedValue::Text(child_id.clone()),
                            ),
                            StoragePredicate::IsNull(Column::new(
                                T_TUNNELS,
                                "tombstonedAt",
                            )),
                        ])),
                        &[],
                        Some(1),
                        None,
                    )
                    .map_err(map_storage_err)?;
                if !existing.is_empty() {
                    return Err(LocusKitError::InvalidContent(format!(
                        "Drawer {} already has a parent tunnel",
                        child_id
                    )));
                }
            }
        }

        self.storage
            .row_store()
            .insert(T_TUNNELS, tunnel_values(tunnel))
            .map_err(map_storage_err)?;

        // Emit tunnel-add telemetry at the post-insert boundary.
        // Tracks link density growth between drawers per estate.
        crate::telemetry::emit_tunnel_add(0.0, &self.estate_uuid);
        Ok(())
    }

    fn get_tunnel(&self, id: &str) -> Result<Option<Tunnel>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_TUNNELS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_TUNNELS, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(tunnel_from_row))
    }

    fn tunnels_from_wing(&self, wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_TUNNELS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "sourceWing"),
                        TypedValue::Text(wing.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_TUNNELS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_TUNNELS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(tunnel_from_row).collect())
    }

    fn tunnels_from_wing_room(&self, wing: &str, room: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_TUNNELS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "sourceWing"),
                        TypedValue::Text(wing.to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "sourceRoom"),
                        TypedValue::Text(room.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_TUNNELS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_TUNNELS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(tunnel_from_row).collect())
    }

    fn tunnels_to_wing(&self, wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_TUNNELS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "targetWing"),
                        TypedValue::Text(wing.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_TUNNELS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_TUNNELS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(tunnel_from_row).collect())
    }

    fn all_tunnels(&self) -> Result<Vec<Tunnel>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_TUNNELS,
                Some(&StoragePredicate::IsNull(Column::new(T_TUNNELS, "tombstonedAt"))),
                &[OrderClause::new(
                    Column::new(T_TUNNELS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(tunnel_from_row).collect())
    }

    // -----------------------------------------------------------------
    // Tunnel retirement (T13 / ADR-021 Phase 7)
    // -----------------------------------------------------------------

    fn retire_tunnel(
        &self,
        tunnel_id: &str,
        _changed_by: &str,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        // Fetch the current tunnel to ensure it exists and get the current bitmap.
        let existing = self.get_tunnel(tunnel_id)?
            .ok_or_else(|| LocusKitError::TunnelNotFound { id: tunnel_id.to_string() })?;
        let retired = existing.with_retired();
        let mut vals = std::collections::BTreeMap::new();
        vals.insert("operationalBitmap".to_string(), TypedValue::Bitmap(retired.operational_bitmap));
        self.storage
            .row_store()
            .update(
                T_TUNNELS,
                vals,
                &StoragePredicate::Eq(
                    Column::new(T_TUNNELS, "id"),
                    TypedValue::Text(tunnel_id.to_string()),
                ),
            )
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn unretire_tunnel(
        &self,
        tunnel_id: &str,
        _changed_by: &str,
        _now: i64,
    ) -> Result<(), LocusKitError> {
        let existing = self.get_tunnel(tunnel_id)?
            .ok_or_else(|| LocusKitError::TunnelNotFound { id: tunnel_id.to_string() })?;
        let active = existing.with_unretired();
        let mut vals = std::collections::BTreeMap::new();
        vals.insert("operationalBitmap".to_string(), TypedValue::Bitmap(active.operational_bitmap));
        self.storage
            .row_store()
            .update(
                T_TUNNELS,
                vals,
                &StoragePredicate::Eq(
                    Column::new(T_TUNNELS, "id"),
                    TypedValue::Text(tunnel_id.to_string()),
                ),
            )
            .map_err(map_storage_err)?;
        Ok(())
    }

    // -----------------------------------------------------------------
    // Outline helpers (ADR-017 §11, NT-L5)
    // -----------------------------------------------------------------

    fn outline_children(&self, parent_drawer_id: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_TUNNELS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "kind_id"),
                        TypedValue::Int(TunnelKind::Parent.raw_value()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "targetDrawerId"),
                        TypedValue::Text(parent_drawer_id.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_TUNNELS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_TUNNELS, "order_key"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(tunnel_from_row).collect())
    }

    fn outline_ancestors(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        let mut ancestors: Vec<String> = Vec::new();
        let mut current = drawer_id.to_string();
        let max_depth = 256;
        while ancestors.len() < max_depth {
            let rows = self
                .storage
                .row_store()
                .query(
                    T_TUNNELS,
                    Some(&StoragePredicate::all(vec![
                        StoragePredicate::Eq(
                            Column::new(T_TUNNELS, "kind_id"),
                            TypedValue::Int(TunnelKind::Parent.raw_value()),
                        ),
                        StoragePredicate::Eq(
                            Column::new(T_TUNNELS, "sourceDrawerId"),
                            TypedValue::Text(current.clone()),
                        ),
                        StoragePredicate::IsNull(Column::new(T_TUNNELS, "tombstonedAt")),
                    ])),
                    &[],
                    Some(1),
                    None,
                )
                .map_err(map_storage_err)?;
            let row = match rows.first() {
                Some(r) => r,
                None => break,
            };
            let tunnel = tunnel_from_row(row);
            match tunnel.target_drawer_id {
                Some(parent_id) => {
                    ancestors.push(parent_id.clone());
                    current = parent_id;
                }
                None => break,
            }
        }
        ancestors.reverse();
        Ok(ancestors)
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
        // Tombstone the existing parent tunnel for this child.
        let existing = self
            .storage
            .row_store()
            .query(
                T_TUNNELS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "kind_id"),
                        TypedValue::Int(TunnelKind::Parent.raw_value()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "sourceDrawerId"),
                        TypedValue::Text(child_id.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_TUNNELS, "tombstonedAt")),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        if let Some(row) = existing.first() {
            let old_tunnel = tunnel_from_row(row);
            self.storage
                .row_store()
                .update(
                    T_TUNNELS,
                    {
                        let mut vals = std::collections::BTreeMap::new();
                        vals.insert(
                            "tombstonedAt".to_string(),
                            TypedValue::Timestamp(now),
                        );
                        vals
                    },
                    &StoragePredicate::Eq(
                        Column::new(T_TUNNELS, "id"),
                        TypedValue::Text(old_tunnel.id),
                    ),
                )
                .map_err(map_storage_err)?;
        }

        // Create the new parent tunnel if new_parent_id is provided.
        if let Some(parent_id) = new_parent_id {
            let mut tunnel = Tunnel::new(
                uuid::Uuid::new_v4().to_string(),
                wing.to_string(),
                room.to_string(),
                wing.to_string(),
                room.to_string(),
                "parent".to_string(),
                added_by.to_string(),
                now,
            );
            tunnel.kind = TunnelKind::Parent;
            tunnel.source_drawer_id = Some(child_id.to_string());
            tunnel.target_drawer_id = Some(parent_id.to_string());
            tunnel.order_key = Some(order_key);
            self.add_tunnel(&tunnel)?;
        }

        Ok(())
    }

    // -----------------------------------------------------------------
    // KGFact CRUD
    // -----------------------------------------------------------------

    fn add_kg_fact(&self, fact: &KGFact) -> Result<(), LocusKitError> {
        validate_non_empty(&fact.subject, "subject")?;
        validate_non_empty(&fact.predicate, "predicate")?;
        validate_non_empty(&fact.object, "object")?;
        validate_non_empty(&fact.source_drawer_id, "sourceDrawerID")?;
        self.storage
            .row_store()
            .insert(T_KG_FACTS, kg_fact_values(fact))
            .map_err(map_storage_err)?;

        // Emit KGFact-add telemetry at the post-insert boundary.
        // Tracks knowledge-graph growth rate per estate.
        crate::telemetry::emit_kgfact_add(0.0, &self.estate_uuid);
        Ok(())
    }

    fn withdraw_kg_fact(&self, id: &str, _now: i64) -> Result<(), LocusKitError> {
        validate_non_empty(id, "id")?;
        let fact = self
            .get_kg_fact(id)?
            .ok_or_else(|| LocusKitError::InvalidContent(format!("kgFact not found: {id}")))?;
        // Preserve adjective bits above the State field (bits 6+) and set
        // bits 0-5 to Withdrawn (raw 18). Mirrors Swift DrawerStore.withdrawKGFact.
        let new_bitmap = (fact.adjective_bitmap & !0x3Fi64) | State::Withdrawn.raw_value();
        let mut update_vals = BTreeMap::new();
        update_vals.insert(
            "adjectiveBitmap".to_string(),
            TypedValue::Bitmap(new_bitmap),
        );
        self.storage
            .row_store()
            .update(
                T_KG_FACTS,
                update_vals,
                &StoragePredicate::Eq(
                    Column::new(T_KG_FACTS, "id"),
                    TypedValue::Text(id.to_string()),
                ),
            )
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn get_kg_fact(&self, id: &str) -> Result<Option<KGFact>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_KG_FACTS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_KG_FACTS, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(kg_fact_from_row))
    }

    fn kg_facts_for_drawer(&self, source_drawer_id: &str) -> Result<Vec<KGFact>, LocusKitError> {
        // Active-cluster (A) facts from one source drawer. `g_state_cluster`
        // holds the raw 6-bit RowState, so the active set is
        // `raw < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW` (the cluster-B
        // floor, 16) — equivalent to RowState Cluster-A for every defined
        // raw. Boundary sourced from the automaton, never a bare literal.
        let rows = self
            .storage
            .row_store()
            .query(
                T_KG_FACTS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_KG_FACTS, "sourceDrawerID"),
                        TypedValue::Text(source_drawer_id.to_string()),
                    ),
                    StoragePredicate::Lt(
                        Column::new(T_KG_FACTS, "g_state_cluster"),
                        TypedValue::Int(RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW as i64),
                    ),
                ])),
                &[OrderClause::new(
                    Column::new(T_KG_FACTS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let facts: Vec<KGFact> = rows.iter().map(kg_fact_from_row).collect();

        // Emit KGFact-query telemetry at the post-query boundary.
        // query="drawer" identifies the per-drawer query path.
        crate::telemetry::emit_kgfact_query(0.0, facts.len(), &self.estate_uuid, "drawer");
        Ok(facts)
    }

    // -----------------------------------------------------------------
    // Proposal CRUD
    // -----------------------------------------------------------------

    fn add_proposal(&self, proposal: &Proposal) -> Result<(), LocusKitError> {
        // Lattice anchor required per cookbook §2.7 (I-16). target_row_id
        // is intentionally not validated — brand-new-object proposals
        // carry no existing target.
        validate_non_empty(&proposal.lattice_anchor.udc_code, "latticeAnchor.udcCode")?;
        self.storage
            .row_store()
            .insert(T_PROPOSALS, proposal_values(proposal))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn get_proposal(&self, id: &str) -> Result<Option<Proposal>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_PROPOSALS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_PROPOSALS, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(proposal_from_row))
    }

    fn proposals_for_target(&self, target_row_id: &str) -> Result<Vec<Proposal>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_PROPOSALS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_PROPOSALS, "targetRowID"),
                    TypedValue::Text(target_row_id.to_string()),
                )),
                &[OrderClause::new(
                    Column::new(T_PROPOSALS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(proposal_from_row).collect())
    }

    // -----------------------------------------------------------------
    // Association CRUD
    // -----------------------------------------------------------------

    fn add_association(&self, association: &Association) -> Result<(), LocusKitError> {
        // Edge endpoints + added_by required (mirroring add_tunnel); lattice
        // anchor required per cookbook §2.7 (I-16, mirroring add_proposal).
        validate_non_empty(&association.source_wing, "sourceWing")?;
        validate_non_empty(&association.source_room, "sourceRoom")?;
        validate_non_empty(&association.target_wing, "targetWing")?;
        validate_non_empty(&association.target_room, "targetRoom")?;
        validate_non_empty(&association.label, "label")?;
        validate_non_empty(&association.added_by, "addedBy")?;
        validate_non_empty(
            &association.lattice_anchor.udc_code,
            "latticeAnchor.udcCode",
        )?;
        self.storage
            .row_store()
            .insert(T_ASSOCIATIONS, association_values(association))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn get_association(&self, id: &str) -> Result<Option<Association>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_ASSOCIATIONS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_ASSOCIATIONS, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(association_from_row))
    }

    fn associations_from(&self, wing: &str, room: &str) -> Result<Vec<Association>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_ASSOCIATIONS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_ASSOCIATIONS, "sourceWing"),
                        TypedValue::Text(wing.to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_ASSOCIATIONS, "sourceRoom"),
                        TypedValue::Text(room.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_ASSOCIATIONS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_ASSOCIATIONS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(association_from_row).collect())
    }

    fn associations_to(&self, wing: &str, room: &str) -> Result<Vec<Association>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_ASSOCIATIONS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_ASSOCIATIONS, "targetWing"),
                        TypedValue::Text(wing.to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_ASSOCIATIONS, "targetRoom"),
                        TypedValue::Text(room.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_ASSOCIATIONS, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_ASSOCIATIONS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(association_from_row).collect())
    }

    // -----------------------------------------------------------------
    // LearnedReference CRUD
    // -----------------------------------------------------------------

    fn add_learned_reference(&self, reference: &LearnedReference) -> Result<(), LocusKitError> {
        // handle + added_by required; lattice anchor required per cookbook
        // §2.7 (I-16, mirroring add_association). source_catalog_id is
        // intentionally not validated — a reference may be ungrounded.
        validate_non_empty(&reference.handle, "handle")?;
        validate_non_empty(&reference.added_by, "addedBy")?;
        validate_non_empty(&reference.lattice_anchor.udc_code, "latticeAnchor.udcCode")?;
        self.storage
            .row_store()
            .insert(T_LEARNED_REFERENCES, learned_reference_values(reference))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn get_learned_reference(&self, id: &str) -> Result<Option<LearnedReference>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_LEARNED_REFERENCES,
                Some(&StoragePredicate::Eq(
                    Column::new(T_LEARNED_REFERENCES, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(learned_reference_from_row))
    }

    fn learned_references_from_source(
        &self,
        source_catalog_id: &str,
    ) -> Result<Vec<LearnedReference>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_LEARNED_REFERENCES,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_LEARNED_REFERENCES, "sourceCatalogID"),
                        TypedValue::Text(source_catalog_id.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_LEARNED_REFERENCES, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_LEARNED_REFERENCES, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(learned_reference_from_row).collect())
    }

    // -----------------------------------------------------------------
    // Source catalog CRUD
    // -----------------------------------------------------------------

    fn add_source_catalog_entry(&self, entry: &SourceCatalogEntry) -> Result<(), LocusKitError> {
        // handle + added_by required; lattice anchor required per cookbook
        // §2.7 (I-16). The genuine anchor recorded here is what the learn
        // verb copies onto each LearnedReference, so an empty anchor would
        // propagate a fabricated identity — hence the hard rejection.
        validate_non_empty(&entry.handle, "handle")?;
        validate_non_empty(&entry.added_by, "addedBy")?;
        validate_non_empty(&entry.lattice_anchor.udc_code, "latticeAnchor.udcCode")?;
        self.storage
            .row_store()
            .insert(T_SOURCE_CATALOG, source_catalog_values(entry))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn get_source_catalog_entry(
        &self,
        id: &str,
    ) -> Result<Option<SourceCatalogEntry>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_SOURCE_CATALOG,
                Some(&StoragePredicate::Eq(
                    Column::new(T_SOURCE_CATALOG, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(source_catalog_from_row))
    }

    fn source_catalog_entry_for_handle(
        &self,
        handle: &str,
    ) -> Result<Option<SourceCatalogEntry>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_SOURCE_CATALOG,
                Some(&StoragePredicate::Eq(
                    Column::new(T_SOURCE_CATALOG, "handle"),
                    TypedValue::Text(handle.to_string()),
                )),
                &[OrderClause::new(
                    Column::new(T_SOURCE_CATALOG, "firstSeen"),
                    OrderDirection::Ascending,
                )],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(source_catalog_from_row))
    }

    // -----------------------------------------------------------------
    // Diary CRUD
    // -----------------------------------------------------------------

    fn add_diary_entry(&self, entry: &DiaryEntry) -> Result<(), LocusKitError> {
        validate_non_empty(&entry.agent_name, "agentName")?;
        validate_non_empty(&entry.entry, "entry")?;
        validate_non_empty(&entry.topic, "topic")?;
        validate_non_empty(&entry.wing, "wing")?;
        validate_non_empty(&entry.room, "room")?;
        validate_non_empty(&entry.embedding_model_id, "embeddingModelID")?;
        self.storage
            .row_store()
            .insert(T_DIARY, diary_values(entry))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn get_diary_entry(&self, id: &str) -> Result<Option<DiaryEntry>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DIARY,
                Some(&StoragePredicate::Eq(
                    Column::new(T_DIARY, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(diary_from_row))
    }

    fn read_diary(
        &self,
        agent_name: &str,
        last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DIARY,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DIARY, "agentName"),
                        TypedValue::Text(agent_name.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_DIARY, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_DIARY, "filedAt"),
                    OrderDirection::Descending,
                )],
                Some(last_n),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(diary_from_row).collect())
    }

    fn read_diary_in_wing(
        &self,
        agent_name: &str,
        wing: &str,
        last_n: usize,
    ) -> Result<Vec<DiaryEntry>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DIARY,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DIARY, "agentName"),
                        TypedValue::Text(agent_name.to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_DIARY, "wing"),
                        TypedValue::Text(wing.to_string()),
                    ),
                    StoragePredicate::IsNull(Column::new(T_DIARY, "tombstonedAt")),
                ])),
                &[OrderClause::new(
                    Column::new(T_DIARY, "filedAt"),
                    OrderDirection::Descending,
                )],
                Some(last_n),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(diary_from_row).collect())
    }

    // -----------------------------------------------------------------
    // Recall trace CRUD
    // -----------------------------------------------------------------

    fn insert_recall_trace(&self, item: &RecallTraceItem) -> Result<(), LocusKitError> {
        self.storage
            .row_store()
            .insert(T_RECALL_TRACE, recall_trace_values(item))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn insert_recall_traces(&self, items: &[RecallTraceItem]) -> Result<(), LocusKitError> {
        // Batch-insert all trace rows. An empty slice is a no-op.
        // Each item is inserted individually through the row_store interface
        // (PersistenceKit's Rust RowStore has no multi-row insert primitive);
        // the I/O advantage over the single-item loop is that errors from any
        // row abort the rest immediately rather than continuing silently.
        // For SQLite the real amortisation comes from the WAL — individual
        // INSERTs inside the same write burst are batched by the WAL writer.
        for item in items {
            self.storage
                .row_store()
                .insert(T_RECALL_TRACE, recall_trace_values(item))
                .map_err(map_storage_err)?;
        }
        Ok(())
    }

    fn get_recall_trace(&self, id: &str) -> Result<Option<RecallTraceItem>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_RECALL_TRACE,
                Some(&StoragePredicate::Eq(
                    Column::new(T_RECALL_TRACE, "id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.first().map(recall_trace_from_row))
    }

    fn recall_trace_since(&self, since: &str) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_RECALL_TRACE,
                Some(&StoragePredicate::Gte(
                    Column::new(T_RECALL_TRACE, "recalledAt"),
                    TypedValue::Text(since.to_string()),
                )),
                &[OrderClause::new(
                    Column::new(T_RECALL_TRACE, "recalledAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(recall_trace_from_row).collect())
    }

    fn recent_recall_traces(
        &self,
        since: &str,
        now: &str,
    ) -> Result<Vec<RecallTraceItem>, LocusKitError> {
        // The in-memory store uses TEXT ISO8601 timestamps for `recalledAt`.
        // Lexicographic comparison is correct for canonical ISO8601 strings
        // (same guarantee as Swift's `recallTraceSince`).
        let rows = self
            .storage
            .row_store()
            .query(
                T_RECALL_TRACE,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Gte(
                        Column::new(T_RECALL_TRACE, "recalledAt"),
                        TypedValue::Text(since.to_string()),
                    ),
                    StoragePredicate::Lte(
                        Column::new(T_RECALL_TRACE, "recalledAt"),
                        TypedValue::Text(now.to_string()),
                    ),
                ])),
                &[OrderClause::new(
                    Column::new(T_RECALL_TRACE, "recalledAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(recall_trace_from_row).collect())
    }

    fn mark_recall_trace_used(&self, id: &str, _now: i64) -> Result<(), LocusKitError> {
        let item = self
            .get_recall_trace(id)?
            .ok_or_else(|| LocusKitError::RecallTraceItemNotFound { id: id.to_string() })?;
        if item.used() {
            // Idempotent — already-marked rows skip the update.
            return Ok(());
        }
        let updated = item.with_used();
        self.storage
            .row_store()
            .update(
                T_RECALL_TRACE,
                recall_trace_values(&updated),
                &StoragePredicate::Eq(
                    Column::new(T_RECALL_TRACE, "id"),
                    TypedValue::Text(id.to_string()),
                ),
            )
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn prune_recall_traces(&self, cutoff: &str) -> Result<usize, LocusKitError> {
        // Delete trace rows with recalledAt < cutoff. `cutoff` is an ISO8601
        // TEXT string; lexicographic `<` on canonical UTC ISO8601 strings
        // equals numeric less-than on the timestamps (fleet date rule). Mirrors
        // Swift `DrawerStore.pruneRecallTraces(olderThan:)`. `delete` returns
        // the number of rows removed.
        self.storage
            .row_store()
            .delete(
                T_RECALL_TRACE,
                &StoragePredicate::Lt(
                    Column::new(T_RECALL_TRACE, "recalledAt"),
                    TypedValue::Text(cutoff.to_string()),
                ),
            )
            .map_err(map_storage_err)
    }

    fn mark_recall_traces_used(
        &self,
        target: &str,
        since: &str,
        now: &str,
    ) -> Result<usize, LocusKitError> {
        // Fetch all trace rows for `target` in the window [since, now].
        // ISO8601 string comparison is equivalent to numeric timestamp
        // comparison for canonical UTC ISO8601 strings (fleet date rule).
        // Mirrors Swift `DrawerStore.markRecallTracesUsed(target:since:now:)`.
        let rows = self
            .storage
            .row_store()
            .query(
                T_RECALL_TRACE,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(T_RECALL_TRACE, "target"),
                        TypedValue::Text(target.to_string()),
                    ),
                    StoragePredicate::Gte(
                        Column::new(T_RECALL_TRACE, "recalledAt"),
                        TypedValue::Text(since.to_string()),
                    ),
                    StoragePredicate::Lte(
                        Column::new(T_RECALL_TRACE, "recalledAt"),
                        TypedValue::Text(now.to_string()),
                    ),
                ])),
                &[],
                None,
                None,
            )
            .map_err(map_storage_err)?;

        let mut touched = 0usize;
        for row in &rows {
            let item = recall_trace_from_row(row);
            if item.used() {
                // Idempotent — already-marked rows are skipped.
                continue;
            }
            let updated = item.with_used();
            self.storage
                .row_store()
                .update(
                    T_RECALL_TRACE,
                    recall_trace_values(&updated),
                    &StoragePredicate::Eq(
                        Column::new(T_RECALL_TRACE, "id"),
                        TypedValue::Text(updated.id.clone()),
                    ),
                )
                .map_err(map_storage_err)?;
            touched += 1;
        }
        Ok(touched)
    }

    fn count_recall_traces(&self) -> Result<usize, LocusKitError> {
        // Query all rows in the recall_trace table (no predicate = full scan).
        // The table is bounded by retention pruning so this is not unbounded.
        // Mirrors Swift `DrawerStore.countRecallTraces()`.
        let rows = self
            .storage
            .row_store()
            .query(T_RECALL_TRACE, None, &[], None, None)
            .map_err(map_storage_err)?;
        Ok(rows.len())
    }

    fn count_drawer_rows(&self) -> Result<usize, LocusKitError> {
        // COUNT(*) on the drawers table — bypasses all row-decode logic so
        // corrupt rows (e.g. a poison timestamp) are still counted. Used by the
        // vault-export fail-loud path: a non-zero count when recall returns 0
        // means the corpus is bricked, not empty.
        //
        // Hint drawers (AI_Charter_Hint room) are normal recallable drawers
        // and are counted like any other drawer.
        // Mirrors Swift `DrawerStore.countDrawerRows()` — count all rows.
        self.storage
            .row_store()
            .count(T_DRAWERS, None)
            .map_err(map_storage_err)
    }

    // -----------------------------------------------------------------
    // Audit reads
    // -----------------------------------------------------------------

    fn audit_events_for_row(
        &self,
        row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        let uuid = require_uuid(row_id, "rowID")?;
        let pk_events = self
            .storage
            .audit_log()
            .events_for_row(uuid)
            .map_err(map_storage_err)?;
        Ok(pk_events.iter().map(substrate_audit_event_from).collect())
    }

    fn tombstoned_rows_without_expunge_audit(&self) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        // Step 1: fetch all tombstoned drawers (tombstonedAt IS NOT NULL),
        // ordered by tombstonedAt ascending so the result is deterministic.
        // The idx_drawers_tombstoned index covers this predicate on SQL backends.
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::IsNotNull(Column::new(
                    T_DRAWERS,
                    "tombstonedAt",
                ))),
                &[OrderClause::new(
                    Column::new(T_DRAWERS, "tombstonedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let tombstoned: Vec<crate::drawer::Drawer> = rows
            .iter()
            .map(drawer_from_row)
            .collect::<Result<Vec<_>, _>>()?;

        if tombstoned.is_empty() {
            return Ok(Vec::new());
        }

        // Step 2: parse drawer IDs as UUIDs — the audit log uses RowKey = Uuid.
        // Every drawer ID stored in the database must be a valid UUID (the write
        // gate validates this at insert time). An unparseable ID here means the
        // row is corrupt; propagate as an error rather than silently skipping.
        let row_keys: Vec<uuid::Uuid> = tombstoned
            .iter()
            .map(|d| require_uuid(&d.id, "drawerId"))
            .collect::<Result<Vec<_>, _>>()?;

        // Step 3: batch query — which of these tombstoned row_ids already have
        // a "tombstone" or "expungeOrphan" audit event?
        //
        // On SQL backends (SQLite, PostgreSQL) this resolves to a single
        // indexed query equivalent to:
        //   SELECT DISTINCT row_id FROM _storagekit_audit
        //   WHERE row_id IN (...) AND verb IN ('tombstone', 'expungeOrphan')
        //
        // On the InMemory backend the AuditLog scans its event vec once.
        // Either way: two total queries (drawers + audit batch) instead of
        // N+1 (drawers + one events_for_row per tombstoned drawer).
        let covered = self
            .storage
            .audit_log()
            .row_ids_with_audit_verbs(&row_keys, &["tombstone", "expungeOrphan"])
            .map_err(map_storage_err)?;

        // Step 4: return only those tombstoned drawers whose UUID is absent
        // from the covered set — these are the crash-window orphans.
        let orphans = tombstoned
            .into_iter()
            .zip(row_keys.into_iter())
            .filter(|(_, key)| !covered.contains(key))
            .map(|(drawer, _)| drawer)
            .collect();

        Ok(orphans)
    }

    // -----------------------------------------------------------------
    // Summary surface
    // -----------------------------------------------------------------

    fn list_wings(&self) -> Result<Vec<WingSummary>, LocusKitError> {
        // ADR-017: enumerate wings from the node tree (depth=1, active).
        let row_store = self.storage.row_store();
        let wing_rows = row_store
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "depth"),
                        TypedValue::Int(1),
                    ),
                    StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                ])),
                &[],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let mut result: Vec<WingSummary> = Vec::new();
        for wing_row in &wing_rows {
            let wing_id = string_value_of(wing_row.get("id"));
            let wing_name = string_value_of(wing_row.get("display_name"));
            let room_rows = row_store
                .query(
                    T_NODES,
                    Some(&StoragePredicate::And(vec![
                        StoragePredicate::Eq(
                            Column::new(T_NODES, "parent_id"),
                            TypedValue::Text(wing_id.clone()),
                        ),
                        StoragePredicate::Eq(
                            Column::new(T_NODES, "depth"),
                            TypedValue::Int(2),
                        ),
                        StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                    ])),
                    &[],
                    None,
                    None,
                )
                .map_err(map_storage_err)?;
            let room_ids: Vec<String> =
                room_rows.iter().map(|r| string_value_of(r.get("id"))).collect();
            let drawer_count = if room_ids.is_empty() {
                0
            } else {
                let predicates: Vec<StoragePredicate> = room_ids
                    .iter()
                    .map(|id| {
                        StoragePredicate::Eq(
                            Column::new(T_DRAWERS, "parent_node_id"),
                            TypedValue::Text(id.clone()),
                        )
                    })
                    .collect();
                let drawer_rows = row_store
                    .query(
                        T_DRAWERS,
                        Some(&StoragePredicate::all(vec![
                            StoragePredicate::any(predicates),
                            StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
                        ])),
                        &[],
                        None,
                        None,
                    )
                    .map_err(map_storage_err)?;
                drawer_rows.len() as i64
            };
            result.push(WingSummary {
                name: wing_name,
                drawer_count,
                room_count: room_ids.len() as i64,
            });
        }
        result.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(result)
    }

    fn list_rooms(&self, wing: Option<&str>) -> Result<Vec<RoomSummary>, LocusKitError> {
        // ADR-017: enumerate rooms from the node tree. Wing nodes are
        // depth=1, room nodes are depth=2 under them.
        let row_store = self.storage.row_store();
        let wing_predicate = match wing {
            Some(w) => {
                let wing_lookup = Node::normalize_lookup_name(w);
                StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "lookup_name"),
                        TypedValue::Text(wing_lookup),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_NODES, "depth"),
                        TypedValue::Int(1),
                    ),
                    StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                ])
            }
            None => StoragePredicate::And(vec![
                StoragePredicate::Eq(
                    Column::new(T_NODES, "depth"),
                    TypedValue::Int(1),
                ),
                StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
            ]),
        };
        let wing_rows = row_store
            .query(T_NODES, Some(&wing_predicate), &[], None, None)
            .map_err(map_storage_err)?;
        let mut result: Vec<RoomSummary> = Vec::new();
        for wing_row in &wing_rows {
            let wing_id = string_value_of(wing_row.get("id"));
            let wing_name = string_value_of(wing_row.get("display_name"));
            let room_rows = row_store
                .query(
                    T_NODES,
                    Some(&StoragePredicate::And(vec![
                        StoragePredicate::Eq(
                            Column::new(T_NODES, "parent_id"),
                            TypedValue::Text(wing_id.clone()),
                        ),
                        StoragePredicate::Eq(
                            Column::new(T_NODES, "depth"),
                            TypedValue::Int(2),
                        ),
                        StoragePredicate::IsNull(Column::new(T_NODES, "tombstoned_hlc")),
                    ])),
                    &[],
                    None,
                    None,
                )
                .map_err(map_storage_err)?;
            for room_row in &room_rows {
                let room_id = string_value_of(room_row.get("id"));
                let room_name = string_value_of(room_row.get("display_name"));
                let drawer_rows = row_store
                    .query(
                        T_DRAWERS,
                        Some(&StoragePredicate::all(vec![
                            StoragePredicate::Eq(
                                Column::new(T_DRAWERS, "parent_node_id"),
                                TypedValue::Text(room_id),
                            ),
                            StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
                        ])),
                        &[],
                        None,
                        None,
                    )
                    .map_err(map_storage_err)?;
                result.push(RoomSummary {
                    wing: wing_name.clone(),
                    name: room_name,
                    drawer_count: drawer_rows.len() as i64,
                });
            }
        }
        result.sort_by(|a, b| {
            let key_a = format!("{}\0{}", a.wing, a.name);
            let key_b = format!("{}\0{}", b.wing, b.name);
            key_a.cmp(&key_b)
        });
        Ok(result)
    }

    // -----------------------------------------------------------------
    // Unfiltered full-corpus reads (recall surface)
    // -----------------------------------------------------------------

    fn all_proposals(&self) -> Result<Vec<Proposal>, LocusKitError> {
        // All rows — no predicate filters out any state. Order by filedAt
        // ascending so results are stable and repeatable.
        let rows = self
            .storage
            .row_store()
            .query(
                T_PROPOSALS,
                None,
                &[OrderClause::new(
                    Column::new(T_PROPOSALS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(proposal_from_row).collect())
    }

    fn all_associations(&self) -> Result<Vec<Association>, LocusKitError> {
        // Non-tombstoned associations, filedAt ascending. Mirrors the
        // tombstone guard in associations_from/associations_to.
        let rows = self
            .storage
            .row_store()
            .query(
                T_ASSOCIATIONS,
                Some(&StoragePredicate::IsNull(Column::new(
                    T_ASSOCIATIONS,
                    "tombstonedAt",
                ))),
                &[OrderClause::new(
                    Column::new(T_ASSOCIATIONS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(association_from_row).collect())
    }

    fn all_learned_references(&self) -> Result<Vec<LearnedReference>, LocusKitError> {
        // Non-tombstoned learned references, filedAt ascending. Mirrors
        // the tombstone guard in learned_references_from_source.
        let rows = self
            .storage
            .row_store()
            .query(
                T_LEARNED_REFERENCES,
                Some(&StoragePredicate::IsNull(Column::new(
                    T_LEARNED_REFERENCES,
                    "tombstonedAt",
                ))),
                &[OrderClause::new(
                    Column::new(T_LEARNED_REFERENCES, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(learned_reference_from_row).collect())
    }

    fn all_kg_facts(&self) -> Result<Vec<KGFact>, LocusKitError> {
        // KG-facts in the active cluster (A). `g_state_cluster` stores the
        // raw 6-bit RowState (0..=63), so the active set is exactly
        // `raw < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW` (the cluster-B
        // floor, 16) — equivalent to RowState Cluster-A for every defined
        // raw (active/pending/contested/accepted included; the retired
        // B/C states from 16/32 excluded). The boundary is sourced from
        // the RowState automaton, never a bare literal. Mirrors
        // kg_facts_for_drawer but without the source-drawer predicate.
        let rows = self
            .storage
            .row_store()
            .query(
                T_KG_FACTS,
                Some(&StoragePredicate::Lt(
                    Column::new(T_KG_FACTS, "g_state_cluster"),
                    TypedValue::Int(RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW as i64),
                )),
                &[OrderClause::new(
                    Column::new(T_KG_FACTS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let facts: Vec<KGFact> = rows.iter().map(kg_fact_from_row).collect();

        // Emit KGFact-query telemetry at the post-query boundary.
        // query="all" identifies the estate-wide query path.
        crate::telemetry::emit_kgfact_query(0.0, facts.len(), &self.estate_uuid, "all");
        Ok(facts)
    }

    fn all_kg_facts_including_retired(&self) -> Result<Vec<KGFact>, LocusKitError> {
        // No state-cluster predicate — return every row, all lifecycle states,
        // so callers can trace the full evolution of structured knowledge.
        // This is the backing query for `moot_fact_timeline`.
        let rows = self
            .storage
            .row_store()
            .query(
                T_KG_FACTS,
                None,
                &[OrderClause::new(
                    Column::new(T_KG_FACTS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let facts: Vec<KGFact> = rows.iter().map(kg_fact_from_row).collect();

        // Emit KGFact-query telemetry at the post-query boundary.
        // query="timeline" distinguishes the all-history path from the
        // active-only "all" path in emitted telemetry.
        crate::telemetry::emit_kgfact_query(0.0, facts.len(), &self.estate_uuid, "timeline");
        Ok(facts)
    }

    fn all_diary_entries(&self) -> Result<Vec<DiaryEntry>, LocusKitError> {
        // Non-tombstoned diary entries, filedAt ascending. Mirrors the
        // tombstone guard used in read_diary / read_diary_in_wing.
        let rows = self
            .storage
            .row_store()
            .query(
                T_DIARY,
                Some(&StoragePredicate::IsNull(Column::new(
                    T_DIARY,
                    "tombstonedAt",
                ))),
                &[OrderClause::new(
                    Column::new(T_DIARY, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(diary_from_row).collect())
    }

    // ── Temporal reads ───────────────────────────────────────────────────────

    fn fingerprints_captured_in(
        &self,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<Fingerprint256>, LocusKitError> {
        // The OR branch covers rows with a NULL eventTime column (backfill to
        // filedAt per ING-01). In practice all Rust-authored rows have a
        // concrete eventTime (resolved eagerly in estate_verbs), but rows
        // originally written by the Swift leg may carry NULL for captures
        // predating the ING-01 two-clock column.
        let pred = StoragePredicate::all(vec![
            StoragePredicate::any(vec![
                StoragePredicate::And(vec![
                    StoragePredicate::IsNotNull(Column::new(T_DRAWERS, "eventTime")),
                    StoragePredicate::Gte(
                        Column::new(T_DRAWERS, "eventTime"),
                        TypedValue::Timestamp(start_epoch),
                    ),
                    StoragePredicate::Lte(
                        Column::new(T_DRAWERS, "eventTime"),
                        TypedValue::Timestamp(end_epoch),
                    ),
                ]),
                StoragePredicate::And(vec![
                    StoragePredicate::IsNull(Column::new(T_DRAWERS, "eventTime")),
                    StoragePredicate::Gte(
                        Column::new(T_DRAWERS, "filedAt"),
                        TypedValue::Timestamp(start_epoch),
                    ),
                    StoragePredicate::Lte(
                        Column::new(T_DRAWERS, "filedAt"),
                        TypedValue::Timestamp(end_epoch),
                    ),
                ]),
            ]),
            StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
        ]);
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                Some(&pred),
                &[OrderClause::new(
                    Column::new(T_DRAWERS, "id"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        // Construct on-demand — one FNV hash per call.
        let families = EstateFingerprintFamilies::new(&self.estate_uuid.to_string());
        rows.iter()
            .map(|row| drawer_from_row(row).map(|d| families.fingerprint(&d)))
            .collect::<Result<Vec<_>, _>>()
    }

    fn fingerprint_bit_series(
        &self,
        bit: usize,
        bucket_seconds: i64,
        bucket_count: usize,
        ending_at: i64,
    ) -> Result<Vec<bool>, LocusKitError> {
        if bit > 255 {
            return Err(LocusKitError::InvalidContent(format!(
                "fingerprint_bit_series: bit {} out of range [0, 255]",
                bit
            )));
        }
        if bucket_seconds < 1 {
            return Err(LocusKitError::InvalidContent(format!(
                "fingerprint_bit_series: bucket_seconds {} must be ≥ 1",
                bucket_seconds
            )));
        }
        if bucket_count == 0 {
            return Ok(Vec::new());
        }

        let window_start = ending_at - (bucket_count as i64) * bucket_seconds;
        let pred = StoragePredicate::all(vec![
            StoragePredicate::any(vec![
                StoragePredicate::And(vec![
                    StoragePredicate::IsNotNull(Column::new(T_DRAWERS, "eventTime")),
                    StoragePredicate::Gte(
                        Column::new(T_DRAWERS, "eventTime"),
                        TypedValue::Timestamp(window_start),
                    ),
                    StoragePredicate::Lte(
                        Column::new(T_DRAWERS, "eventTime"),
                        TypedValue::Timestamp(ending_at),
                    ),
                ]),
                StoragePredicate::And(vec![
                    StoragePredicate::IsNull(Column::new(T_DRAWERS, "eventTime")),
                    StoragePredicate::Gte(
                        Column::new(T_DRAWERS, "filedAt"),
                        TypedValue::Timestamp(window_start),
                    ),
                    StoragePredicate::Lte(
                        Column::new(T_DRAWERS, "filedAt"),
                        TypedValue::Timestamp(ending_at),
                    ),
                ]),
            ]),
            StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
        ]);
        let rows = self
            .storage
            .row_store()
            .query(T_DRAWERS, Some(&pred), &[], None, None)
            .map_err(map_storage_err)?;
        let families = EstateFingerprintFamilies::new(&self.estate_uuid.to_string());
        // Pre-compute (event_time, fingerprint) for all drawers in the window.
        // drawer.event_time carries the ING-01 filedAt backfill from drawer_from_row.
        let captures: Vec<(i64, Fingerprint256)> = rows
            .iter()
            .map(|row| {
                let d = drawer_from_row(row)?;
                Ok((d.event_time, families.fingerprint(&d)))
            })
            .collect::<Result<Vec<_>, LocusKitError>>()?;

        Ok((0..bucket_count)
            .map(|i| {
                let bucket_lower = ending_at - (bucket_count - i) as i64 * bucket_seconds;
                let is_last = i == bucket_count - 1;
                captures.iter().any(|(t, fp)| {
                    let in_bucket = if is_last {
                        // Final bucket: [lower, ending_at] inclusive upper.
                        *t >= bucket_lower && *t <= ending_at
                    } else {
                        // [lower, upper): exclusive upper so edge belongs to later bucket.
                        let bucket_upper =
                            ending_at - (bucket_count - i - 1) as i64 * bucket_seconds;
                        *t >= bucket_lower && *t < bucket_upper
                    };
                    in_bucket && temporal_bit_set(fp, bit)
                })
            })
            .collect())
    }

    fn room_level_fingerprints(&self) -> Result<Vec<RoomLevelEntry>, LocusKitError> {
        // The container-fingerprint aggregate lives in the same backing
        // `Storage` this core wraps; build a read-only view over it and
        // enumerate the room-level rows. `ContainerFingerprintStore::new`
        // re-opens the LocusKit schema, a no-op once the estate is open
        // (the version gate short-circuits). No drawer scan happens here —
        // the OR aggregates are read straight from `container_fingerprints`.
        let fp_store = ContainerFingerprintStore::new(Arc::clone(&self.storage))?;
        fp_store.room_level_entries()
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
        // The container-fingerprint aggregate lives in the same backing
        // `Storage` this core wraps; build a view over it and OR the
        // drawer's bitmaps into the room-level and wing-rollup rows.
        // `ContainerFingerprintStore::new` re-opens the LocusKit schema, a
        // no-op once the estate is open (the version gate short-circuits).
        // Mirrors Swift `Estate.capture`'s `containerFP.orIn(...)`.
        let fp_store = ContainerFingerprintStore::new(Arc::clone(&self.storage))?;
        fp_store.or_in(wing, room, adjective, operational, provenance, now)
    }

    fn rebuild_container_fingerprints(&self, now: i64) -> Result<(), LocusKitError> {
        // Backfill so the aggregate covers every active row and is therefore
        // sound to prune against (spec § 11.5). One full scan at open,
        // mirroring Swift `Estate.open`/`create`'s
        // `containerFP.rebuildAll(activeDrawers:)`. Tombstoned drawers are
        // excluded — they are not part of the active set the OR must cover.
        let active: Vec<Drawer> = self
            .all_drawers()?
            .into_iter()
            .filter(|d| d.tombstoned_at.is_none())
            .collect();
        // ADR-017 §3: resolve parent_node_id → (wing, room) display names
        // from the node tree so the fingerprint store can group by container.
        let parent_ids: Vec<String> = active.iter().map(|d| d.parent_node_id.clone()).collect();
        let node_names = self.resolve_node_names(&parent_ids)?;
        let fp_store = ContainerFingerprintStore::new(Arc::clone(&self.storage))?;
        fp_store.rebuild_all(&active, &node_names, now)
    }

    fn get_container_fingerprint(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Option<crate::container_fingerprint_store::ContainerFingerprint>, LocusKitError>
    {
        // Point lookup for one (wing, room) pair — used by the recall
        // pruning path to check the wing-level rollup (room == "") before
        // scanning individual rooms. `ContainerFingerprintStore::new`
        // re-opens the LocusKit schema, a no-op once the estate is open.
        let fp_store = ContainerFingerprintStore::new(Arc::clone(&self.storage))?;
        fp_store.get(wing, room)
    }
}

// ---------------------------------------------------------------------------
// InMemoryDrawerStore — thin public newtype for the in-memory backend
// ---------------------------------------------------------------------------

/// Public newtype fronting `DrawerStoreCore` over an `InMemoryStorage`
/// backend.
///
/// This is what every construction site that wants an in-memory estate
/// names.  The backend (`InMemoryStorage`) is allocated here, making the
/// backend identity visible at the type level rather than buried in a
/// runtime argument.
///
/// Symmetric with the `SqliteDrawerStore` and `PostgresDrawerStore` newtypes:
/// each newtype names its backend, constructs it, and delegates every
/// `DrawerStore` method to the shared `DrawerStoreCore`.
pub struct InMemoryDrawerStore {
    inner: DrawerStoreCore,
}

impl InMemoryDrawerStore {
    /// Open a new in-memory estate.
    ///
    /// Allocates an `InMemoryStorage` backend tagged with a fresh estate
    /// UUID, then delegates to `DrawerStoreCore::new` which opens the
    /// LocusKit schema and writes v1 manifest defaults.
    ///
    /// `now` seeds the `created_at` / `last_modified` manifest rows on
    /// first open.  `hlc` is an optional injected `HLCGenerator`; pass
    /// `None` to create a top-level estate that owns its own clock.
    pub fn new(now: i64, hlc: Option<HLCGenerator>) -> Result<Self, LocusKitError> {
        let estate_id = Uuid::new_v4();
        let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(estate_id));
        let inner = DrawerStoreCore::new(storage, now, hlc)?;
        Ok(InMemoryDrawerStore { inner })
    }

    /// Open a new in-memory estate over an externally-supplied
    /// `InMemoryStorage`.
    ///
    /// Use this variant when you need to share a single `InMemoryStorage`
    /// across two `DrawerStoreCore` opens (e.g. to verify manifest
    /// idempotency across re-opens).  For all other in-memory construction
    /// sites, prefer `new(now, hlc)`.
    pub fn with_storage(
        storage: Arc<InMemoryStorage>,
        now: i64,
        hlc: Option<HLCGenerator>,
    ) -> Result<Self, LocusKitError> {
        let inner = DrawerStoreCore::new(storage as Arc<dyn Storage>, now, hlc)?;
        Ok(InMemoryDrawerStore { inner })
    }

    /// Kit-internal accessor — the underlying persistence-kit `Storage`
    /// handle.  `#[cfg(test)]` only: used by inline tests that need to
    /// verify audit-log contents directly through the storage handle.
    #[cfg(test)]
    pub(crate) fn storage(&self) -> &Arc<dyn Storage> {
        &self.inner.storage
    }
}

impl DrawerStore for InMemoryDrawerStore {
    fn storage(&self) -> Option<Arc<dyn Storage>> {
        self.inner.storage()
    }

    fn resolve_node_names(
        &self,
        parent_node_ids: &[String],
    ) -> Result<BTreeMap<String, (String, String)>, LocusKitError> {
        self.inner.resolve_node_names(parent_node_ids)
    }

    fn read_manifest(&self) -> Result<crate::manifest::ManifestValues, LocusKitError> {
        self.inner.read_manifest()
    }
    fn set_meta(&self, key: &str, value: &str) -> Result<(), LocusKitError> {
        self.inner.set_meta(key, value)
    }
    fn get_meta(&self, key: &str) -> Result<Option<String>, LocusKitError> {
        self.inner.get_meta(key)
    }
    fn add_drawer(&self, drawer: &crate::drawer::Drawer, now: i64) -> Result<(), LocusKitError> {
        self.inner.add_drawer(drawer, now)
    }
    fn get_drawer(&self, id: &str) -> Result<Option<crate::drawer::Drawer>, LocusKitError> {
        self.inner.get_drawer(id)
    }
    fn living_successor_in_lineage(
        &self,
        lineage_id: &str,
        excluding_id: &str,
    ) -> Result<Option<String>, LocusKitError> {
        self.inner.living_successor_in_lineage(lineage_id, excluding_id)
    }
    fn drawers_in_wing(&self, wing: &str) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.drawers_in_wing(wing)
    }
    fn drawers_in_wing_room(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.drawers_in_wing_room(wing, room)
    }
    fn drawers_by_source(
        &self,
        source_file: &str,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.drawers_by_source(source_file)
    }
    fn all_drawers(&self) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.all_drawers()
    }
    fn all_drawers_bounded(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.all_drawers_bounded(limit)
    }
    fn all_drawers_bounded_projected(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.all_drawers_bounded_projected(limit)
    }

    // Forwarding overrides for the DESC bounded scan methods. Without these,
    // Arc<dyn DrawerStore> callers hit the O(estate) trait default (load
    // all_drawers, reverse, truncate) rather than DrawerStoreCore's efficient
    // (filed_at DESC, id DESC, LIMIT) path. Forwarding here ensures the
    // InMemoryDrawerStore wrapper routes correctly for in-process estates
    // (c-recall-portable fix).

    fn all_drawers_bounded_desc(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.all_drawers_bounded_desc(limit)
    }

    fn all_drawers_bounded_projected_desc(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.all_drawers_bounded_projected_desc(limit)
    }

    fn drawer_ids(&self) -> Result<Vec<crate::estate_types::RowID>, LocusKitError> {
        self.inner.drawer_ids()
    }
    fn mutate_provenance(
        &self,
        drawer_id: &str,
        new_provenance: i64,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.inner
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
        self.inner
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
        self.inner
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
        self.inner
            .mutate_state(drawer_id, new_state, via, changed_by, reason, now)
    }
    fn lineage_chain(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        self.inner.lineage_chain(drawer_id)
    }
    fn expunge_gated(
        &self,
        drawer_id: &str,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
        seal_audit: bool,
    ) -> Result<substrate_lib::verbs::AuditEvent, LocusKitError> {
        self.inner.expunge_gated(drawer_id, changed_by, reason, now, seal_audit)
    }
    fn seal_expunge_audit(
        &self,
        event: &substrate_lib::verbs::AuditEvent,
    ) -> Result<(), LocusKitError> {
        self.inner.seal_expunge_audit(event)
    }
    fn seal_expunge_orphan_audit(
        &self,
        drawer_id: &str,
        success_event: &substrate_lib::verbs::AuditEvent,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.inner.seal_expunge_orphan_audit(drawer_id, success_event, changed_by, now)
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
        self.inner
            .reanchor_gated(drawer_id, to_room, to_wing, to_lattice, changed_by, reason, now)
    }
    fn add_tunnel(&self, tunnel: &crate::tunnel::Tunnel) -> Result<(), LocusKitError> {
        self.inner.add_tunnel(tunnel)
    }
    fn get_tunnel(&self, id: &str) -> Result<Option<crate::tunnel::Tunnel>, LocusKitError> {
        self.inner.get_tunnel(id)
    }
    fn tunnels_from_wing(&self, wing: &str) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.inner.tunnels_from_wing(wing)
    }
    fn tunnels_from_wing_room(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.inner.tunnels_from_wing_room(wing, room)
    }
    fn tunnels_to_wing(&self, wing: &str) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.inner.tunnels_to_wing(wing)
    }
    fn all_tunnels(&self) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.inner.all_tunnels()
    }
    // Retirement forwarding — T13 / ADR-021 Phase 7.
    fn retire_tunnel(&self, tunnel_id: &str, changed_by: &str, now: i64) -> Result<(), LocusKitError> {
        self.inner.retire_tunnel(tunnel_id, changed_by, now)
    }
    fn unretire_tunnel(&self, tunnel_id: &str, changed_by: &str, now: i64) -> Result<(), LocusKitError> {
        self.inner.unretire_tunnel(tunnel_id, changed_by, now)
    }
    fn outline_children(&self, parent_drawer_id: &str) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.inner.outline_children(parent_drawer_id)
    }
    fn outline_ancestors(&self, drawer_id: &str) -> Result<Vec<String>, LocusKitError> {
        self.inner.outline_ancestors(drawer_id)
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
        self.inner.reparent_drawer(child_id, new_parent_id, order_key, wing, room, added_by, now)
    }
    fn add_kg_fact(&self, fact: &crate::kg_fact::KGFact) -> Result<(), LocusKitError> {
        self.inner.add_kg_fact(fact)
    }
    fn withdraw_kg_fact(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.inner.withdraw_kg_fact(id, now)
    }
    fn get_kg_fact(&self, id: &str) -> Result<Option<crate::kg_fact::KGFact>, LocusKitError> {
        self.inner.get_kg_fact(id)
    }
    fn kg_facts_for_drawer(
        &self,
        source_drawer_id: &str,
    ) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.inner.kg_facts_for_drawer(source_drawer_id)
    }
    fn add_proposal(&self, proposal: &crate::proposal::Proposal) -> Result<(), LocusKitError> {
        self.inner.add_proposal(proposal)
    }
    fn get_proposal(&self, id: &str) -> Result<Option<crate::proposal::Proposal>, LocusKitError> {
        self.inner.get_proposal(id)
    }
    fn proposals_for_target(
        &self,
        target_row_id: &str,
    ) -> Result<Vec<crate::proposal::Proposal>, LocusKitError> {
        self.inner.proposals_for_target(target_row_id)
    }
    fn add_association(
        &self,
        association: &crate::association::Association,
    ) -> Result<(), LocusKitError> {
        self.inner.add_association(association)
    }
    fn get_association(
        &self,
        id: &str,
    ) -> Result<Option<crate::association::Association>, LocusKitError> {
        self.inner.get_association(id)
    }
    fn associations_from(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::association::Association>, LocusKitError> {
        self.inner.associations_from(wing, room)
    }
    fn associations_to(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::association::Association>, LocusKitError> {
        self.inner.associations_to(wing, room)
    }
    fn add_learned_reference(
        &self,
        reference: &crate::learned_reference::LearnedReference,
    ) -> Result<(), LocusKitError> {
        self.inner.add_learned_reference(reference)
    }
    fn get_learned_reference(
        &self,
        id: &str,
    ) -> Result<Option<crate::learned_reference::LearnedReference>, LocusKitError> {
        self.inner.get_learned_reference(id)
    }
    fn learned_references_from_source(
        &self,
        source_catalog_id: &str,
    ) -> Result<Vec<crate::learned_reference::LearnedReference>, LocusKitError> {
        self.inner.learned_references_from_source(source_catalog_id)
    }
    fn add_source_catalog_entry(
        &self,
        entry: &crate::source_catalog_entry::SourceCatalogEntry,
    ) -> Result<(), LocusKitError> {
        self.inner.add_source_catalog_entry(entry)
    }
    fn get_source_catalog_entry(
        &self,
        id: &str,
    ) -> Result<Option<crate::source_catalog_entry::SourceCatalogEntry>, LocusKitError> {
        self.inner.get_source_catalog_entry(id)
    }
    fn source_catalog_entry_for_handle(
        &self,
        handle: &str,
    ) -> Result<Option<crate::source_catalog_entry::SourceCatalogEntry>, LocusKitError> {
        self.inner.source_catalog_entry_for_handle(handle)
    }
    fn add_diary_entry(&self, entry: &crate::diary_entry::DiaryEntry) -> Result<(), LocusKitError> {
        self.inner.add_diary_entry(entry)
    }
    fn get_diary_entry(
        &self,
        id: &str,
    ) -> Result<Option<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.inner.get_diary_entry(id)
    }
    fn read_diary(
        &self,
        agent_name: &str,
        last_n: usize,
    ) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.inner.read_diary(agent_name, last_n)
    }
    fn read_diary_in_wing(
        &self,
        agent_name: &str,
        wing: &str,
        last_n: usize,
    ) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.inner.read_diary_in_wing(agent_name, wing, last_n)
    }
    fn insert_recall_trace(
        &self,
        item: &crate::recall_trace_item::RecallTraceItem,
    ) -> Result<(), LocusKitError> {
        self.inner.insert_recall_trace(item)
    }
    fn insert_recall_traces(
        &self,
        items: &[crate::recall_trace_item::RecallTraceItem],
    ) -> Result<(), LocusKitError> {
        self.inner.insert_recall_traces(items)
    }
    fn get_recall_trace(
        &self,
        id: &str,
    ) -> Result<Option<crate::recall_trace_item::RecallTraceItem>, LocusKitError> {
        self.inner.get_recall_trace(id)
    }
    fn recall_trace_since(
        &self,
        since: &str,
    ) -> Result<Vec<crate::recall_trace_item::RecallTraceItem>, LocusKitError> {
        self.inner.recall_trace_since(since)
    }
    fn recent_recall_traces(
        &self,
        since: &str,
        now: &str,
    ) -> Result<Vec<crate::recall_trace_item::RecallTraceItem>, LocusKitError> {
        self.inner.recent_recall_traces(since, now)
    }
    fn mark_recall_trace_used(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.inner.mark_recall_trace_used(id, now)
    }
    fn prune_recall_traces(&self, cutoff: &str) -> Result<usize, LocusKitError> {
        self.inner.prune_recall_traces(cutoff)
    }
    fn mark_recall_traces_used(
        &self,
        target: &str,
        since: &str,
        now: &str,
    ) -> Result<usize, LocusKitError> {
        self.inner.mark_recall_traces_used(target, since, now)
    }
    fn count_recall_traces(&self) -> Result<usize, LocusKitError> {
        self.inner.count_recall_traces()
    }
    fn count_drawer_rows(&self) -> Result<usize, LocusKitError> {
        self.inner.count_drawer_rows()
    }
    fn audit_events_for_row(
        &self,
        row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        self.inner.audit_events_for_row(row_id)
    }
    fn tombstoned_rows_without_expunge_audit(&self) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.inner.tombstoned_rows_without_expunge_audit()
    }
    fn seal_expunge_orphan_for_sweep(
        &self,
        drawer_id: &str,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.inner.seal_expunge_orphan_for_sweep(drawer_id, changed_by, now)
    }
    fn wipe_all_content(&self) -> Result<(), LocusKitError> {
        self.inner.wipe_all_content()
    }
    fn list_wings(&self) -> Result<Vec<crate::summaries::WingSummary>, LocusKitError> {
        self.inner.list_wings()
    }
    fn list_rooms(
        &self,
        wing: Option<&str>,
    ) -> Result<Vec<crate::summaries::RoomSummary>, LocusKitError> {
        self.inner.list_rooms(wing)
    }
    fn taxonomy(&self) -> Result<Vec<crate::summaries::WingSummary>, LocusKitError> {
        self.inner.taxonomy()
    }
    fn all_proposals(&self) -> Result<Vec<crate::proposal::Proposal>, LocusKitError> {
        self.inner.all_proposals()
    }
    fn all_associations(&self) -> Result<Vec<crate::association::Association>, LocusKitError> {
        self.inner.all_associations()
    }
    fn all_learned_references(
        &self,
    ) -> Result<Vec<crate::learned_reference::LearnedReference>, LocusKitError> {
        self.inner.all_learned_references()
    }
    fn all_kg_facts(&self) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.inner.all_kg_facts()
    }
    fn all_kg_facts_including_retired(&self) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.inner.all_kg_facts_including_retired()
    }
    fn all_diary_entries(&self) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.inner.all_diary_entries()
    }
    fn fingerprints_captured_in(
        &self,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<Fingerprint256>, LocusKitError> {
        self.inner.fingerprints_captured_in(start_epoch, end_epoch)
    }
    fn fingerprint_bit_series(
        &self,
        bit: usize,
        bucket_seconds: i64,
        bucket_count: usize,
        ending_at: i64,
    ) -> Result<Vec<bool>, LocusKitError> {
        self.inner
            .fingerprint_bit_series(bit, bucket_seconds, bucket_count, ending_at)
    }
    fn room_level_fingerprints(&self) -> Result<Vec<RoomLevelEntry>, LocusKitError> {
        self.inner.room_level_fingerprints()
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
        self.inner
            .or_in_container_fingerprint(wing, room, adjective, operational, provenance, now)
    }
    fn rebuild_container_fingerprints(&self, now: i64) -> Result<(), LocusKitError> {
        self.inner.rebuild_container_fingerprints(now)
    }
    fn get_container_fingerprint(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Option<crate::container_fingerprint_store::ContainerFingerprint>, LocusKitError>
    {
        self.inner.get_container_fingerprint(wing, room)
    }
}

// ---------------------------------------------------------------------------
// Row encode helpers
// ---------------------------------------------------------------------------

fn drawer_values(d: &Drawer) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(d.id.clone()));
    m.insert("content".to_string(), TypedValue::Text(d.content.clone()));
    m.insert(
        "parent_node_id".to_string(),
        TypedValue::Text(d.parent_node_id.clone()),
    );
    m.insert(
        "sourceFile".to_string(),
        d.source_file
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "chunkIndex".to_string(),
        d.chunk_index
            .map(TypedValue::Int)
            .unwrap_or(TypedValue::Null),
    );
    m.insert("addedBy".to_string(), TypedValue::Text(d.added_by.clone()));
    m.insert("filedAt".to_string(), TypedValue::Timestamp(d.filed_at));
    // event_time is always non-optional; always persist the resolved value.
    // The SQLite column is nullable TEXT to support legacy rows pre-dating
    // the column, but new writes always supply the ISO8601 timestamp.
    m.insert(
        "eventTime".to_string(),
        TypedValue::Timestamp(d.event_time),
    );
    m.insert(
        "embeddingModelID".to_string(),
        TypedValue::Text(d.embedding_model_id.clone()),
    );
    m.insert(
        "tombstonedAt".to_string(),
        d.tombstoned_at
            .map(TypedValue::Timestamp)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "removedByBatch".to_string(),
        d.removed_by_batch
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert("provenance".to_string(), TypedValue::Bitmap(d.provenance));
    m.insert(
        "adjectiveBitmap".to_string(),
        TypedValue::Bitmap(d.adjective_bitmap),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(d.operational_bitmap),
    );
    m.insert(
        "lineageID".to_string(),
        TypedValue::Text(d.lineage_id.to_string()),
    );
    m.insert("udcCode".to_string(), TypedValue::Text(d.udc_code.clone()));
    m.insert(
        "udcFacets".to_string(),
        d.udc_facets
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQID".to_string(),
        d.wikidata_qid
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQidsSecondary".to_string(),
        d.wikidata_qids_secondary
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m
}

fn tunnel_values(t: &Tunnel) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(t.id.clone()));
    m.insert(
        "sourceWing".to_string(),
        TypedValue::Text(t.source_wing.clone()),
    );
    m.insert(
        "sourceRoom".to_string(),
        TypedValue::Text(t.source_room.clone()),
    );
    m.insert(
        "sourceDrawerId".to_string(),
        t.source_drawer_id
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "targetWing".to_string(),
        TypedValue::Text(t.target_wing.clone()),
    );
    m.insert(
        "targetRoom".to_string(),
        TypedValue::Text(t.target_room.clone()),
    );
    m.insert(
        "targetDrawerId".to_string(),
        t.target_drawer_id
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert("label".to_string(), TypedValue::Text(t.label.clone()));
    m.insert("addedBy".to_string(), TypedValue::Text(t.added_by.clone()));
    m.insert("filedAt".to_string(), TypedValue::Timestamp(t.filed_at));
    m.insert(
        "tombstonedAt".to_string(),
        t.tombstoned_at
            .map(TypedValue::Timestamp)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "removedByBatch".to_string(),
        t.removed_by_batch
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert("kind_id".to_string(), TypedValue::Int(t.kind.raw_value()));
    m.insert(
        "adjectiveBitmap".to_string(),
        TypedValue::Bitmap(t.adjective_bitmap),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(t.operational_bitmap),
    );
    m.insert(
        "provenanceBitmap".to_string(),
        TypedValue::Bitmap(t.provenance_bitmap),
    );
    m.insert(
        "order_key".to_string(),
        t.order_key
            .map(TypedValue::Float)
            .unwrap_or(TypedValue::Null),
    );
    m
}

fn diary_values(e: &DiaryEntry) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(e.id.clone()));
    m.insert(
        "agentName".to_string(),
        TypedValue::Text(e.agent_name.clone()),
    );
    m.insert("entry".to_string(), TypedValue::Text(e.entry.clone()));
    m.insert("topic".to_string(), TypedValue::Text(e.topic.clone()));
    m.insert("wing".to_string(), TypedValue::Text(e.wing.clone()));
    m.insert("room".to_string(), TypedValue::Text(e.room.clone()));
    m.insert("filedAt".to_string(), TypedValue::Timestamp(e.filed_at));
    m.insert(
        "embeddingModelID".to_string(),
        TypedValue::Text(e.embedding_model_id.clone()),
    );
    m.insert(
        "tombstonedAt".to_string(),
        e.tombstoned_at
            .map(TypedValue::Timestamp)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "removedByBatch".to_string(),
        e.removed_by_batch
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(e.operational_bitmap),
    );
    // Explicit reward channel (NEURONKIT_SPEC § 3.1 step 1a).
    // REAL nullable: bind f64 or Null.
    m.insert(
        "reward".to_string(),
        e.reward.map(TypedValue::Float).unwrap_or(TypedValue::Null),
    );
    m.insert(
        "rewardProvenance".to_string(),
        e.reward_provenance
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m
}

fn kg_fact_values(f: &KGFact) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(f.id.clone()));
    m.insert("subject".to_string(), TypedValue::Text(f.subject.clone()));
    m.insert(
        "predicate".to_string(),
        TypedValue::Text(f.predicate.clone()),
    );
    m.insert("object".to_string(), TypedValue::Text(f.object.clone()));
    m.insert(
        "sourceDrawerID".to_string(),
        TypedValue::Text(f.source_drawer_id.clone()),
    );
    m.insert(
        "adjectiveBitmap".to_string(),
        TypedValue::Bitmap(f.adjective_bitmap),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(f.operational_bitmap),
    );
    m.insert(
        "provenanceBitmap".to_string(),
        TypedValue::Bitmap(f.provenance_bitmap),
    );
    m.insert("filedAt".to_string(), TypedValue::Timestamp(f.filed_at));
    m
}

fn association_values(a: &Association) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(a.id.clone()));
    m.insert(
        "sourceWing".to_string(),
        TypedValue::Text(a.source_wing.clone()),
    );
    m.insert(
        "sourceRoom".to_string(),
        TypedValue::Text(a.source_room.clone()),
    );
    m.insert(
        "sourceDrawerId".to_string(),
        a.source_drawer_id
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "targetWing".to_string(),
        TypedValue::Text(a.target_wing.clone()),
    );
    m.insert(
        "targetRoom".to_string(),
        TypedValue::Text(a.target_room.clone()),
    );
    m.insert(
        "targetDrawerId".to_string(),
        a.target_drawer_id
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert("label".to_string(), TypedValue::Text(a.label.clone()));
    m.insert("addedBy".to_string(), TypedValue::Text(a.added_by.clone()));
    m.insert("filedAt".to_string(), TypedValue::Timestamp(a.filed_at));
    m.insert(
        "tombstonedAt".to_string(),
        a.tombstoned_at
            .map(TypedValue::Timestamp)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "removedByBatch".to_string(),
        a.removed_by_batch
            .as_ref()
            .map(|s| TypedValue::Text(s.clone()))
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "udcCode".to_string(),
        TypedValue::Text(a.lattice_anchor.udc_code.clone()),
    );
    m.insert(
        "udcFacets".to_string(),
        a.lattice_anchor
            .udc_facets
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQID".to_string(),
        a.lattice_anchor
            .wikidata_qid
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQidsSecondary".to_string(),
        a.lattice_anchor
            .wikidata_qids_secondary
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "adjectiveBitmap".to_string(),
        TypedValue::Bitmap(a.adjective_bitmap),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(a.operational_bitmap),
    );
    m.insert(
        "provenanceBitmap".to_string(),
        TypedValue::Bitmap(a.provenance_bitmap),
    );
    m
}

fn proposal_values(p: &Proposal) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(p.id.clone()));
    m.insert(
        "targetRowID".to_string(),
        TypedValue::Text(p.target_row_id.clone()),
    );
    m.insert(
        "justification".to_string(),
        p.justification
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "candidateState".to_string(),
        TypedValue::Bitmap(p.candidate_state),
    );
    m.insert(
        "adjectiveBitmap".to_string(),
        TypedValue::Bitmap(p.adjective_bitmap),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(p.operational_bitmap),
    );
    m.insert(
        "provenanceBitmap".to_string(),
        TypedValue::Bitmap(p.provenance_bitmap),
    );
    m.insert(
        "udcCode".to_string(),
        TypedValue::Text(p.lattice_anchor.udc_code.clone()),
    );
    m.insert(
        "udcFacets".to_string(),
        p.lattice_anchor
            .udc_facets
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQID".to_string(),
        p.lattice_anchor
            .wikidata_qid
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQidsSecondary".to_string(),
        p.lattice_anchor
            .wikidata_qids_secondary
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert("filedAt".to_string(), TypedValue::Timestamp(p.filed_at));
    m
}

fn recall_trace_values(item: &RecallTraceItem) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(item.id.clone()));
    m.insert("target".to_string(), TypedValue::Text(item.target.clone()));
    // recalled_at is stored as TEXT ISO8601 per the fleet rule. The
    // RecallTraceItem already carries the ISO8601 string, so no
    // conversion happens here.
    m.insert(
        "recalledAt".to_string(),
        TypedValue::Text(item.recalled_at.clone()),
    );
    m.insert(
        "score".to_string(),
        item.score
            .map(TypedValue::Float)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(item.operational_bitmap),
    );
    m
}

// ---------------------------------------------------------------------------
// Row decode helpers
// ---------------------------------------------------------------------------

/// Returns true when the given bit (0-based) is set in `fp`.
/// Layout: block0=bits 0–63, block1=64–127, block2=128–191, block3=192–255.
/// Callers must pre-validate that bit ∈ [0, 255].
fn temporal_bit_set(fp: &Fingerprint256, bit: usize) -> bool {
    match bit {
        0..=63 => (fp.block0 >> (bit as u32)) & 1 != 0,
        64..=127 => (fp.block1 >> ((bit - 64) as u32)) & 1 != 0,
        128..=191 => (fp.block2 >> ((bit - 128) as u32)) & 1 != 0,
        _ => (fp.block3 >> ((bit - 192) as u32)) & 1 != 0,
    }
}

/// Decode a `drawers` row into a `Drawer`.
///
/// Returns `Err(LocusKitError::CorruptStoredValue)` when the stored
/// `lineageID` TEXT is non-empty but cannot be parsed as a UUID.
/// An empty-string `lineageID` is the intentional "unset" sentinel —
/// it becomes a fresh `Uuid::new_v4()` so unset rows never collapse
/// onto one lineage. A non-empty unparseable string is corruption:
/// manufacturing a new random UUID would fabricate a lineage that
/// never existed, silently misleading federation routing and
/// Bradley-Terry reward matching. Parity with Swift `drawerFromRow`
/// and PersistenceKit commit 0ff08d93.
///
/// `filed_at` and other Timestamp columns are declared
/// `ColumnType::Timestamp` in the schema; PersistenceKit's
/// `read_value` already throws `StorageError::CorruptStoredValue`
/// there before the row reaches this function.
fn drawer_from_row(row: &StorageRow) -> Result<Drawer, LocusKitError> {
    let raw_lineage = string_value_of(row.get("lineageID"));
    let lineage_id = if raw_lineage.is_empty() {
        Uuid::new_v4()
    } else {
        Uuid::parse_str(&raw_lineage).map_err(|_| LocusKitError::CorruptStoredValue {
            table: "drawers".to_string(),
            column: "lineageID".to_string(),
            stored_text: raw_lineage.clone(),
        })?
    };
    let filed_at = i64_value_of(row.get("filedAt"));
    Ok(Drawer {
        id: string_value_of(row.get("id")),
        lineage_id,
        content: string_value_of(row.get("content")),
        parent_node_id: string_value_of(row.get("parent_node_id")),
        source_file: opt_string_value_of(row.get("sourceFile")),
        chunk_index: opt_int_value_of(row.get("chunkIndex")),
        added_by: string_value_of(row.get("addedBy")),
        filed_at,
        // Two-clock ingest (ING-01): coalesce NULL/absent eventTime to
        // filed_at at the decode boundary. Rows written before the column
        // existed carry NULL in SQLite; they decode to event_time == filed_at
        // (the streaming-capture identity) without requiring ALTER+UPDATE.
        // The in-struct type is non-optional, mirroring Swift Drawer.eventTime.
        event_time: opt_int_value_of(row.get("eventTime")).unwrap_or(filed_at),
        embedding_model_id: string_value_of(row.get("embeddingModelID")),
        tombstoned_at: opt_int_value_of(row.get("tombstonedAt")),
        removed_by_batch: opt_string_value_of(row.get("removedByBatch")),
        provenance: i64_value_of(row.get("provenance")),
        adjective_bitmap: i64_value_of(row.get("adjectiveBitmap")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
        udc_code: string_value_of(row.get("udcCode")),
        udc_facets: opt_string_value_of(row.get("udcFacets")),
        wikidata_qid: opt_string_value_of(row.get("wikidataQID")),
        wikidata_qids_secondary: opt_string_value_of(row.get("wikidataQidsSecondary")),
    })
}

/// Decode a slice of `StorageRow` into `Drawer` values, skipping rows that
/// fail with `LocusKitError::CorruptStoredValue`.
///
/// ## Scan-level resilience (data-integrity fix 2026-06-18)
///
/// The per-value strict decode in `drawer_from_row` (fail-loud, no silent
/// identity lie) is preserved for POINT LOOKUPS. For CORPUS SCANS
/// (all_drawers, drawers_in_wing, etc.) a single corrupt row must NOT brick
/// the entire estate's recall and recall-adjacent paths. This helper
/// implements the skip-and-log policy for `drawer_from_row` failures (e.g.
/// unparseable lineageID UUID).
///
/// Timestamp corruption is handled one level up: scan functions call
/// `RowStore::query_skip_corrupt` (implemented at the SQLite cursor level in
/// `SqliteRowStore`) so rows with unparseable timestamp columns are skipped
/// before they ever reach `drawer_from_row`. This helper handles any
/// remaining decode failures that `drawer_from_row` surfaces.
///
///   - `CorruptStoredValue` from `drawer_from_row` → log a warning, skip, continue.
///   - Any other error (backend connectivity, SQL errors, lock failures) →
///     re-raise immediately (systemic failure, not a data problem).
///
/// The log line is written to stderr so it appears in the process log without
/// requiring a tracing/logging dependency in PersistenceKit's crate.
fn decode_rows_skip_corrupt(rows: &[StorageRow], scan: &str) -> Result<Vec<Drawer>, LocusKitError> {
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        match drawer_from_row(row) {
            Ok(d) => out.push(d),
            Err(LocusKitError::CorruptStoredValue { ref table, ref column, ref stored_text }) => {
                eprintln!(
                    "[locus_kit] WARNING: skipping corrupt row in {} scan \
                     (table='{}' column='{}' stored_text='{}'). \
                     The row is readable by its id but will not appear in corpus scans \
                     until the corrupt value is repaired. Fix the upstream write path \
                     that produced this value.",
                    scan, table, column, stored_text
                );
                // Continue — skip this row, collect the rest.
            }
            Err(other) => return Err(other), // systemic failure — re-raise
        }
    }
    Ok(out)
}

fn tunnel_from_row(row: &StorageRow) -> Tunnel {
    Tunnel {
        id: string_value_of(row.get("id")),
        source_wing: string_value_of(row.get("sourceWing")),
        source_room: string_value_of(row.get("sourceRoom")),
        source_drawer_id: opt_string_value_of(row.get("sourceDrawerId")),
        target_wing: string_value_of(row.get("targetWing")),
        target_room: string_value_of(row.get("targetRoom")),
        target_drawer_id: opt_string_value_of(row.get("targetDrawerId")),
        label: string_value_of(row.get("label")),
        kind: TunnelKind::from_raw(i64_value_of(row.get("kind_id"))),
        adjective_bitmap: i64_value_of(row.get("adjectiveBitmap")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
        provenance_bitmap: i64_value_of(row.get("provenanceBitmap")),
        added_by: string_value_of(row.get("addedBy")),
        filed_at: i64_value_of(row.get("filedAt")),
        tombstoned_at: opt_int_value_of(row.get("tombstonedAt")),
        removed_by_batch: opt_string_value_of(row.get("removedByBatch")),
        order_key: opt_float_value_of(row.get("order_key")),
    }
}

fn learned_reference_values(reference: &LearnedReference) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(reference.id.clone()));
    m.insert(
        "sourceCatalogID".to_string(),
        TypedValue::Text(reference.source_catalog_id.clone()),
    );
    m.insert(
        "handle".to_string(),
        TypedValue::Text(reference.handle.clone()),
    );
    m.insert(
        "addedBy".to_string(),
        TypedValue::Text(reference.added_by.clone()),
    );
    m.insert(
        "filedAt".to_string(),
        TypedValue::Timestamp(reference.filed_at),
    );
    m.insert(
        "tombstonedAt".to_string(),
        reference
            .tombstoned_at
            .map(TypedValue::Timestamp)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "removedByBatch".to_string(),
        reference
            .removed_by_batch
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "udcCode".to_string(),
        TypedValue::Text(reference.lattice_anchor.udc_code.clone()),
    );
    m.insert(
        "udcFacets".to_string(),
        reference
            .lattice_anchor
            .udc_facets
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQID".to_string(),
        reference
            .lattice_anchor
            .wikidata_qid
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQidsSecondary".to_string(),
        reference
            .lattice_anchor
            .wikidata_qids_secondary
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "adjectiveBitmap".to_string(),
        TypedValue::Bitmap(reference.adjective_bitmap),
    );
    m.insert(
        "operationalBitmap".to_string(),
        TypedValue::Bitmap(reference.operational_bitmap),
    );
    m.insert(
        "provenanceBitmap".to_string(),
        TypedValue::Bitmap(reference.provenance_bitmap),
    );
    m
}

fn association_from_row(row: &StorageRow) -> Association {
    Association {
        id: string_value_of(row.get("id")),
        source_wing: string_value_of(row.get("sourceWing")),
        source_room: string_value_of(row.get("sourceRoom")),
        source_drawer_id: opt_string_value_of(row.get("sourceDrawerId")),
        target_wing: string_value_of(row.get("targetWing")),
        target_room: string_value_of(row.get("targetRoom")),
        target_drawer_id: opt_string_value_of(row.get("targetDrawerId")),
        label: string_value_of(row.get("label")),
        lattice_anchor: LatticeAnchor::new(
            string_value_of(row.get("udcCode")),
            opt_string_value_of(row.get("udcFacets")),
            opt_string_value_of(row.get("wikidataQID")),
            opt_string_value_of(row.get("wikidataQidsSecondary")),
        ),
        adjective_bitmap: i64_value_of(row.get("adjectiveBitmap")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
        provenance_bitmap: i64_value_of(row.get("provenanceBitmap")),
        added_by: string_value_of(row.get("addedBy")),
        filed_at: i64_value_of(row.get("filedAt")),
        tombstoned_at: opt_int_value_of(row.get("tombstonedAt")),
        removed_by_batch: opt_string_value_of(row.get("removedByBatch")),
    }
}

fn learned_reference_from_row(row: &StorageRow) -> LearnedReference {
    LearnedReference {
        id: string_value_of(row.get("id")),
        source_catalog_id: string_value_of(row.get("sourceCatalogID")),
        handle: string_value_of(row.get("handle")),
        lattice_anchor: LatticeAnchor::new(
            string_value_of(row.get("udcCode")),
            opt_string_value_of(row.get("udcFacets")),
            opt_string_value_of(row.get("wikidataQID")),
            opt_string_value_of(row.get("wikidataQidsSecondary")),
        ),
        adjective_bitmap: i64_value_of(row.get("adjectiveBitmap")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
        provenance_bitmap: i64_value_of(row.get("provenanceBitmap")),
        added_by: string_value_of(row.get("addedBy")),
        filed_at: i64_value_of(row.get("filedAt")),
        tombstoned_at: opt_int_value_of(row.get("tombstonedAt")),
        removed_by_batch: opt_string_value_of(row.get("removedByBatch")),
    }
}

fn source_catalog_values(entry: &SourceCatalogEntry) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(entry.id.clone()));
    m.insert("kind".to_string(), TypedValue::Int(entry.kind.raw_value()));
    m.insert("handle".to_string(), TypedValue::Text(entry.handle.clone()));
    m.insert(
        "addedBy".to_string(),
        TypedValue::Text(entry.added_by.clone()),
    );
    m.insert(
        "firstSeen".to_string(),
        TypedValue::Timestamp(entry.first_seen),
    );
    m.insert(
        "udcCode".to_string(),
        TypedValue::Text(entry.lattice_anchor.udc_code.clone()),
    );
    m.insert(
        "udcFacets".to_string(),
        entry
            .lattice_anchor
            .udc_facets
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQID".to_string(),
        entry
            .lattice_anchor
            .wikidata_qid
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m.insert(
        "wikidataQidsSecondary".to_string(),
        entry
            .lattice_anchor
            .wikidata_qids_secondary
            .clone()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
    );
    m
}

fn source_catalog_from_row(row: &StorageRow) -> SourceCatalogEntry {
    SourceCatalogEntry {
        id: string_value_of(row.get("id")),
        kind: SourceKind::from_raw(i64_value_of(row.get("kind"))),
        handle: string_value_of(row.get("handle")),
        lattice_anchor: LatticeAnchor::new(
            string_value_of(row.get("udcCode")),
            opt_string_value_of(row.get("udcFacets")),
            opt_string_value_of(row.get("wikidataQID")),
            opt_string_value_of(row.get("wikidataQidsSecondary")),
        ),
        first_seen: i64_value_of(row.get("firstSeen")),
        added_by: string_value_of(row.get("addedBy")),
    }
}

fn diary_from_row(row: &StorageRow) -> DiaryEntry {
    DiaryEntry {
        id: string_value_of(row.get("id")),
        agent_name: string_value_of(row.get("agentName")),
        entry: string_value_of(row.get("entry")),
        topic: string_value_of(row.get("topic")),
        wing: string_value_of(row.get("wing")),
        room: string_value_of(row.get("room")),
        filed_at: i64_value_of(row.get("filedAt")),
        embedding_model_id: string_value_of(row.get("embeddingModelID")),
        tombstoned_at: opt_int_value_of(row.get("tombstonedAt")),
        removed_by_batch: opt_string_value_of(row.get("removedByBatch")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
        // Explicit reward channel (NEURONKIT_SPEC § 3.1 step 1a).
        // SQLite returns Float or Null; opt_float_value_of handles both.
        reward: opt_float_value_of(row.get("reward")),
        reward_provenance: opt_string_value_of(row.get("rewardProvenance")),
    }
}

fn kg_fact_from_row(row: &StorageRow) -> KGFact {
    KGFact {
        id: string_value_of(row.get("id")),
        subject: string_value_of(row.get("subject")),
        predicate: string_value_of(row.get("predicate")),
        object: string_value_of(row.get("object")),
        source_drawer_id: string_value_of(row.get("sourceDrawerID")),
        adjective_bitmap: i64_value_of(row.get("adjectiveBitmap")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
        provenance_bitmap: i64_value_of(row.get("provenanceBitmap")),
        filed_at: i64_value_of(row.get("filedAt")),
    }
}

fn proposal_from_row(row: &StorageRow) -> Proposal {
    Proposal {
        id: string_value_of(row.get("id")),
        target_row_id: string_value_of(row.get("targetRowID")),
        justification: opt_string_value_of(row.get("justification")),
        candidate_state: i64_value_of(row.get("candidateState")),
        lattice_anchor: LatticeAnchor::new(
            string_value_of(row.get("udcCode")),
            opt_string_value_of(row.get("udcFacets")),
            opt_string_value_of(row.get("wikidataQID")),
            opt_string_value_of(row.get("wikidataQidsSecondary")),
        ),
        adjective_bitmap: i64_value_of(row.get("adjectiveBitmap")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
        provenance_bitmap: i64_value_of(row.get("provenanceBitmap")),
        filed_at: i64_value_of(row.get("filedAt")),
    }
}

fn recall_trace_from_row(row: &StorageRow) -> RecallTraceItem {
    RecallTraceItem {
        id: string_value_of(row.get("id")),
        target: string_value_of(row.get("target")),
        recalled_at: recalled_at_string(row.get("recalledAt")),
        score: opt_float_value_of(row.get("score")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
    }
}

/// Decode the `recalledAt` column to its ISO8601 string, tolerating both the
/// `Text` form (the InMemory backend round-trips the raw string) and the
/// `Timestamp` form (the SQLite / Postgres backends parse the TEXT column to
/// epoch seconds on read because the column is declared `.timestamp`, then we
/// re-render the canonical ISO8601). Without the Timestamp arm, a persisted
/// reopen would surface an empty `recalled_at`, breaking the dreaming reward
/// sweep's `recalledAt` windowing on durable backends (the InMemory-only tests
/// hide this). Mirrors the read-back tolerance every other LocusKit decoder
/// applies to timestamp columns.
fn recalled_at_string(v: Option<&TypedValue>) -> String {
    match v {
        Some(TypedValue::Text(s)) => s.clone(),
        Some(TypedValue::Timestamp(secs)) => format_iso8601(*secs),
        _ => String::new(),
    }
}

// ---------------------------------------------------------------------------
// TypedValue accessors
// ---------------------------------------------------------------------------

fn string_value_of(v: Option<&TypedValue>) -> String {
    match v {
        Some(TypedValue::Text(s)) => s.clone(),
        Some(TypedValue::Uuid(u)) => u.to_string(),
        _ => String::new(),
    }
}

/// Parse a UUID string to `TypedValue::Uuid` for node-tree predicate
fn opt_string_value_of(v: Option<&TypedValue>) -> Option<String> {
    match v {
        Some(TypedValue::Text(s)) => Some(s.clone()),
        _ => None,
    }
}

fn i64_value_of(v: Option<&TypedValue>) -> i64 {
    match v {
        Some(TypedValue::Int(i)) | Some(TypedValue::Bitmap(i)) | Some(TypedValue::Timestamp(i)) => {
            *i
        }
        Some(TypedValue::Bool(b)) => i64::from(*b),
        _ => 0,
    }
}

fn opt_int_value_of(v: Option<&TypedValue>) -> Option<i64> {
    match v {
        Some(TypedValue::Int(i)) | Some(TypedValue::Bitmap(i)) | Some(TypedValue::Timestamp(i)) => {
            Some(*i)
        }
        _ => None,
    }
}

fn opt_float_value_of(v: Option<&TypedValue>) -> Option<f64> {
    match v {
        Some(TypedValue::Float(f)) => Some(*f),
        Some(TypedValue::Int(i)) => Some(*i as f64),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

fn validate_non_empty(value: &str, label: &str) -> Result<(), LocusKitError> {
    if value.is_empty() {
        return Err(LocusKitError::InvalidContent(format!(
            "{} must not be empty",
            label
        )));
    }
    Ok(())
}

fn map_storage_err(e: persistence_kit::error::StorageError) -> LocusKitError {
    LocusKitError::DatabaseUnavailable(e.to_string())
}

// ---------------------------------------------------------------------------
// ISO8601 helpers
// ---------------------------------------------------------------------------
//
// The manifest stores `created_at` and `last_modified` in its TEXT
// value column as plain strings (not as the schema's `timestamp` type),
// so the store formats and parses these two values manually. Other
// timestamp columns flow through `TypedValue::Timestamp(i64)` and need
// no formatter at this layer.
//
// The format matches the Swift `LKISO8601` formatter
// (`.withInternetDateTime + .withFractionalSeconds`) so a value
// written by either side round-trips through the other.

fn format_iso8601(epoch_seconds: i64) -> String {
    // Minimal ISO8601-Z formatter. Avoids pulling in chrono / time at
    // this layer; the manifest stores two timestamps and they only
    // need round-trip equality with the parser below.
    let (year, month, day, hour, minute, second) = epoch_to_components(epoch_seconds);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.000Z",
        year, month, day, hour, minute, second
    )
}

fn parse_iso8601(s: &str) -> Option<i64> {
    // Accept "YYYY-MM-DDTHH:MM:SS[.fff]Z" — the shape `format_iso8601`
    // emits and the shape Swift's `ISO8601DateFormatter`
    // `.withInternetDateTime` produces. Fractional seconds are parsed
    // and dropped (epoch seconds, not subsecond).
    let bytes = s.as_bytes();
    if bytes.len() < 20 {
        return None;
    }
    let year: i64 = std::str::from_utf8(&bytes[0..4]).ok()?.parse().ok()?;
    let month: i64 = std::str::from_utf8(&bytes[5..7]).ok()?.parse().ok()?;
    let day: i64 = std::str::from_utf8(&bytes[8..10]).ok()?.parse().ok()?;
    let hour: i64 = std::str::from_utf8(&bytes[11..13]).ok()?.parse().ok()?;
    let minute: i64 = std::str::from_utf8(&bytes[14..16]).ok()?.parse().ok()?;
    let second: i64 = std::str::from_utf8(&bytes[17..19]).ok()?.parse().ok()?;
    Some(components_to_epoch(year, month, day, hour, minute, second))
}

/// Days from 0000-03-01 to year-month-1. The shifted year start
/// (March 1) is the standard trick that absorbs leap-day math at the
/// end of the year — see Howard Hinnant's chrono algorithms.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // 0..399
    let mp = if m > 2 { m - 3 } else { m + 9 }; // 0..11, Mar-based
    let doy = (153 * mp + 2) / 5 + d - 1; // 0..365
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // 0..146096
    era * 146097 + doe - 719468 // 1970-01-01 → 0
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // 0..146096
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // 0..399
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // 0..365
    let mp = (5 * doy + 2) / 153; // 0..11
    let d = doy - (153 * mp + 2) / 5 + 1; // 1..31
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // 1..12
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn components_to_epoch(y: i64, m: i64, d: i64, hh: i64, mm: i64, ss: i64) -> i64 {
    let days = days_from_civil(y, m, d);
    days * 86_400 + hh * 3_600 + mm * 60 + ss
}

fn epoch_to_components(t: i64) -> (i64, i64, i64, i64, i64, i64) {
    let days = t.div_euclid(86_400);
    let secs = t.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    let hh = secs / 3600;
    let mm = (secs % 3600) / 60;
    let ss = secs % 60;
    (y, m, d, hh, mm, ss)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Parse a row id string to a UUID for the audit event, or error.
/// DECISION_ROW_IDENTITY_UUID: row identity is a UUID; a non-UUID id at
/// a gated write is a contract violation, surfaced loudly, never bridged.
pub(crate) fn require_uuid(s: &str, label: &str) -> Result<Uuid, LocusKitError> {
    Uuid::parse_str(s)
        .map_err(|_| LocusKitError::InvalidContent(format!("{} is not a UUID: {}", label, s)))
}

/// Bridge the substrate gate's AuditEvent to PersistenceKit's flattened
/// AuditEvent for append. Swift PersistenceKit reuses SubstrateLib's type
/// directly; the Rust leg has its own flat type, so the conversion lives
/// here. Field-for-field, ids as u128 → Uuid. reason is threaded through.
fn pk_audit_event_from(e: &substrate_lib::verbs::AuditEvent) -> PkAuditEvent {
    PkAuditEvent {
        event_id: Uuid::from_u128(e.event_id),
        estate_uuid: Uuid::from_u128(e.estate_uuid),
        row_id: Uuid::from_u128(e.row_id.0),
        hlc: e.hlc,
        verb: e.verb.clone(),
        before_adjective: e.before_bitmaps.map(|b| b.0),
        before_operational: e.before_bitmaps.map(|b| b.1),
        before_provenance: e.before_bitmaps.map(|b| b.2),
        after_adjective: e.after_bitmaps.0,
        after_operational: e.after_bitmaps.1,
        after_provenance: e.after_bitmaps.2,
        before_lattice_anchor: e.before_lattice_anchor.map(|a| a.udc_code),
        after_lattice_anchor: e.after_lattice_anchor.udc_code,
        before_lattice_qid: e.before_lattice_anchor.map(|a| a.qid_pointer),
        after_lattice_qid: e.after_lattice_anchor.qid_pointer,
        actor: e.actor.clone(),
        // reason is threaded from the verb call site through the substrate
        // AuditEvent and forwarded here to PersistenceKit's flat type.
        reason: e.reason.clone(),
    }
}

/// Bridge a PersistenceKit flat AuditEvent (as read from the audit log)
/// back to the substrate verbs::AuditEvent the AuditLogFold consumes.
/// Inverse of `pk_audit_event_from`. Rust-only: Swift's PersistenceKit
/// reuses the substrate type, so no bridge is needed there. before_*
/// fields are all-or-nothing (a snapshot event either has a prior or is
/// the first event), mirrored here.
pub(crate) fn substrate_audit_event_from(e: &PkAuditEvent) -> substrate_lib::verbs::AuditEvent {
    let before = match (
        e.before_adjective,
        e.before_operational,
        e.before_provenance,
    ) {
        (Some(a), Some(o), Some(p)) => Some((a, o, p)),
        _ => None,
    };
    substrate_lib::verbs::AuditEvent {
        event_id: e.event_id.as_u128(),
        estate_uuid: e.estate_uuid.as_u128(),
        row_id: substrate_lib::verbs::RowId(e.row_id.as_u128()),
        hlc: e.hlc,
        verb: e.verb.clone(),
        before_bitmaps: before,
        after_bitmaps: (e.after_adjective, e.after_operational, e.after_provenance),
        before_lattice_anchor: e.before_lattice_anchor.map(|a| {
            substrate_lib::verbs::LatticeAnchor::new(a, e.before_lattice_qid.unwrap_or(0))
        }),
        after_lattice_anchor: substrate_lib::verbs::LatticeAnchor::new(
            e.after_lattice_anchor,
            e.after_lattice_qid,
        ),
        actor: e.actor.clone(),
        // reason is threaded back through the bridge for full round-trip fidelity.
        reason: e.reason.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State, Trust};
    use crate::estate::Estate;
    use crate::estate_types::OwnerCredentials;

    const NOW: i64 = 1_700_000_000;

    // open_store returns InMemoryDrawerStore — the public newtype.  Tests
    // that need to share storage across two opens use DrawerStoreCore::new
    // directly (it is pub(crate) and therefore reachable here).
    fn open_store() -> InMemoryDrawerStore {
        InMemoryDrawerStore::new(NOW, None).unwrap()
    }

    /// Deterministic test UUID from a short label, so tests can keep
    /// using readable ids ("d1") while the stored row id is a real UUID
    /// (capture is now a gated write and requires a UUID row identity).
    fn tid(label: &str) -> String {
        // Deterministic UUID from a label without needing the uuid v5
        // feature. Builds on the FNV-1a 64-bit primitive (offset basis +
        // prime, same constants as substrate_types::fnv::hash64), but is
        // *not* a pure FNV-1a string hash: it interleaves the hash-step
        // with byte placement to scatter influence across all 16 output
        // bytes. Keeping it inline here — refactoring to call `hash64`
        // would change the output bytes and break the determinism
        // contract these test UUIDs encode. Stable across runs.
        let mut bytes = [0u8; 16];
        let mut h: u64 = 0xcbf29ce484222325;
        for (i, b) in label.bytes().enumerate() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
            bytes[i % 16] ^= (h & 0xff) as u8;
            bytes[(i + 7) % 16] ^= ((h >> 32) & 0xff) as u8;
        }
        // Mix the hash across all bytes so short labels differ well.
        // The loop uses `i` both to read and write bytes[i], so a direct
        // iterator would need split borrows. The range loop is correct here.
        #[allow(clippy::needless_range_loop)]
        for i in 0..16 {
            h ^= bytes[i] as u64;
            h = h.wrapping_mul(0x100000001b3);
            bytes[i] = bytes[i].wrapping_add((h & 0xff) as u8);
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
        Uuid::from_bytes(bytes).to_string()
    }

    fn sample_drawer(id: &str, wing: &str, room: &str, content: &str) -> Drawer {
        // If the caller passed a UUID already, keep it; otherwise derive a
        // deterministic UUID from the label.
        let resolved = match Uuid::parse_str(id) {
            Ok(_) => id.to_string(),
            Err(_) => tid(id),
        };
        // parent_node_id is a deterministic test value derived from
        // wing+room so tests that group by parent_node_id remain stable.
        let parent_id = tid(&format!("node-{}-{}", wing, room));
        let mut d = Drawer::new(&resolved, content, &parent_id, "alice", NOW, "test-v1");
        d.udc_code = "001".to_string();
        d
    }

    /// Seed a node tree for tests: root → wing (depth=1) → room (depth=2).
    /// Returns the room node ID string. The wing and room display names
    /// are stored as-is; lookup_name is normalized. The returned room
    /// node ID matches what sample_drawer produces for the same wing/room.
    fn seed_node_tree(store: &InMemoryDrawerStore, wing: &str, room: &str) -> String {
        use crate::node_store::NodeStore;
        let storage = Arc::clone(store.storage());
        let ns = NodeStore::new(storage, None);
        let root = ns.create_root("Estate", NOW).unwrap();
        let wing_node = ns.create_node(wing, root.id, NOW).unwrap();
        let room_node = ns.create_node(room, wing_node.id, NOW).unwrap();
        room_node.id.to_string()
    }

    /// Seed nodes and create a drawer whose parent_node_id points to the
    /// room node. Replaces sample_drawer for tests that need node-tree
    /// resolution (drawers_in_wing, drawers_in_wing_room, list_wings, etc.).
    fn sample_drawer_with_nodes(
        store: &InMemoryDrawerStore,
        id: &str,
        wing: &str,
        room: &str,
        content: &str,
    ) -> Drawer {
        let room_node_id = seed_node_tree(store, wing, room);
        let resolved = match Uuid::parse_str(id) {
            Ok(_) => id.to_string(),
            Err(_) => tid(id),
        };
        let mut d = Drawer::new(&resolved, content, &room_node_id, "alice", NOW, "test-v1");
        d.udc_code = "001".to_string();
        d
    }

    // -----------------------------------------------------------------
    // Manifest defaults
    // -----------------------------------------------------------------

    #[test]
    fn manifest_defaults_populated_on_first_open() {
        let store = open_store();
        let m = store.read_manifest().unwrap();
        assert_eq!(m.manifest_version, "1.0");
        assert_eq!(m.bitmap_layout_version, "v1.0");
        assert_eq!(m.provenance_bitmap_version, "v1.0");
        assert_eq!(m.active_storage_mode, 8);
        assert_eq!(m.zoom_window_high, 99);
        // estate_uuid is a fresh UUID — non-empty and parseable.
        assert!(Uuid::parse_str(&m.estate_uuid).is_ok());
        assert!(m.federation_group_id.is_none());
    }

    #[test]
    fn manifest_defaults_preserved_across_reopen() {
        // Two opens share one InMemoryStorage — requires DrawerStoreCore::new
        // (pub(crate)) because InMemoryDrawerStore::new always allocates a
        // fresh storage.  This is the only scenario that needs the bare core.
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store_a =
            DrawerStoreCore::new(Arc::clone(&storage) as Arc<dyn Storage>, NOW, None).unwrap();
        let uuid_a = store_a.read_manifest().unwrap().estate_uuid;
        // Second open must see the same estate_uuid written by the first.
        let store_b = DrawerStoreCore::new(storage as Arc<dyn Storage>, NOW + 1, None).unwrap();
        let uuid_b = store_b.read_manifest().unwrap().estate_uuid;
        assert_eq!(uuid_a, uuid_b);
    }

    // -----------------------------------------------------------------
    // P1-7: estate_uuid manifest classification — absent vs corrupt vs
    // valid. An ABSENT value (fresh estate) is legitimate (node 0, no
    // error); a PRESENT-but-malformed value is data corruption and MUST
    // fail loud (CorruptStoredValue), never collapse to node 0 / a random
    // UUID which would mask the corruption. Parity with the Swift port's
    // `DrawerStoreClassifyEstateUuidTests`.
    // -----------------------------------------------------------------

    /// VALID persisted UUID → the correct, stable node id is derived
    /// (FNV-1a 32-bit of the raw stored text, masked non-negative), and
    /// the estate uuid resolves to that persisted value.
    #[test]
    fn estate_uuid_valid_persisted_derives_correct_node_id() {
        let stored = "11111111-1111-1111-1111-111111111111";
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let core =
            DrawerStoreCore::new(Arc::clone(&storage) as Arc<dyn Storage>, NOW, None).unwrap();
        // Overwrite the manifest with a known UUID, then re-open over the
        // same storage so classification runs against the known value.
        core.set_meta("estate_uuid", stored).unwrap();
        let reopened =
            DrawerStoreCore::new(storage as Arc<dyn Storage>, NOW + 1, None).unwrap();

        // estate uuid resolves to the persisted value (not a fresh mint).
        assert_eq!(reopened.estate_uuid.to_string(), stored);

        // node id is the FNV hash of the raw stored text, masked. This is
        // the same expression Swift evaluates on the identical bytes.
        let expected = (substrate_types::fnv::hash32(stored) & 0x7FFF_FFFF) as i32;
        let state = reopened.classify_estate_uuid().unwrap();
        assert!(matches!(state, EstateUuidState::Present { .. }));
        assert_eq!(DrawerStoreCore::maker_node_id(&state), expected);
        // Sanity: a real persisted uuid never derives node 0.
        assert_ne!(DrawerStoreCore::maker_node_id(&state), 0);
        // The live clock carries that node id.
        assert_eq!(reopened.hlc.lock().unwrap().node_id, expected);
    }

    /// ABSENT manifest value (fresh estate, key never written) → the
    /// legitimate fresh-estate path: classification is `Absent`, node id
    /// is 0, and open does NOT error.
    #[test]
    fn estate_uuid_absent_opens_fresh_no_throw() {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let core =
            DrawerStoreCore::new(Arc::clone(&storage) as Arc<dyn Storage>, NOW, None).unwrap();
        // Delete the estate_uuid row so the value is genuinely absent,
        // simulating an unseeded manifest (the legitimate fresh case).
        let deleted = storage
            .row_store()
            .delete(
                T_MANIFEST,
                &StoragePredicate::Eq(
                    Column::new(T_MANIFEST, "key"),
                    TypedValue::Text("estate_uuid".to_string()),
                ),
            )
            .unwrap();
        assert_eq!(deleted, 1, "exactly one estate_uuid row removed");

        // Classification reports Absent; node id is 0; no error.
        let state = core.classify_estate_uuid().unwrap();
        assert!(matches!(state, EstateUuidState::Absent));
        assert_eq!(DrawerStoreCore::maker_node_id(&state), 0);
    }

    /// PRESENT-but-malformed UUID (data corruption) → fail loud with
    /// `CorruptStoredValue { table: "manifest", column: "estate_uuid" }`.
    /// NOT node 0, NOT a random UUID, NOT a silent default.
    #[test]
    fn estate_uuid_corrupt_fails_loud() {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let core =
            DrawerStoreCore::new(Arc::clone(&storage) as Arc<dyn Storage>, NOW, None).unwrap();
        // Corrupt the persisted value in place.
        core.set_meta("estate_uuid", "not-a-uuid").unwrap();

        // classify_estate_uuid fails loud — never a silent fallback.
        let err = core.classify_estate_uuid().unwrap_err();
        match err {
            LocusKitError::CorruptStoredValue {
                ref table,
                ref column,
                ref stored_text,
            } => {
                assert_eq!(table, T_MANIFEST);
                assert_eq!(column, "estate_uuid");
                assert_eq!(stored_text, "not-a-uuid");
            }
            other => panic!("expected CorruptStoredValue, got {:?}", other),
        }

        // And the corruption propagates through the production open path:
        // re-opening over the same corrupt storage must Err, not collapse
        // to node 0 / a random UUID.
        let reopen =
            DrawerStoreCore::new(storage as Arc<dyn Storage>, NOW + 1, None);
        assert!(
            matches!(
                reopen,
                Err(LocusKitError::CorruptStoredValue { ref column, .. }) if column == "estate_uuid"
            ),
            "open over corrupt estate_uuid must fail loud, got {:?}",
            reopen.map(|_| "Ok"),
        );
    }

    // -----------------------------------------------------------------
    // room_level_fingerprints + all_drawers_bounded accessors
    // -----------------------------------------------------------------

    #[test]
    fn room_level_fingerprints_reads_container_aggregate() {
        // Seed the container_fingerprints aggregate through a
        // ContainerFingerprintStore over the SAME storage the DrawerStoreCore
        // wraps, then read it back through the DrawerStore accessor. Proves the
        // accessor reads the maintained aggregate rather than a separate table.
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store =
            DrawerStoreCore::new(Arc::clone(&storage) as Arc<dyn Storage>, NOW, None).unwrap();
        let fp_store =
            ContainerFingerprintStore::new(Arc::clone(&storage) as Arc<dyn Storage>).unwrap();
        fp_store.or_in("study", "notes", 0b0011, 0b0100, 0, NOW).unwrap();
        fp_store.or_in("study", "drafts", 0b1000, 0, 0, NOW).unwrap();

        let mut entries = store.room_level_fingerprints().unwrap();
        entries.sort_by(|a, b| a.room.cmp(&b.room));
        assert_eq!(entries.len(), 2, "two room-level containers, no wing rollup");
        assert_eq!(entries[0].room, "drafts");
        assert_eq!(entries[0].fingerprint.adjective, 0b1000);
        assert_eq!(entries[1].room, "notes");
        assert_eq!(entries[1].fingerprint.adjective, 0b0011);
        assert_eq!(entries[1].fingerprint.operational, 0b0100);
    }

    #[test]
    fn room_level_fingerprints_empty_on_fresh_estate() {
        let store = open_store();
        assert!(store.room_level_fingerprints().unwrap().is_empty());
    }

    #[test]
    fn all_drawers_bounded_caps_and_reads_full_on_none() {
        let store = open_store();
        for i in 0..5 {
            let d = sample_drawer(&format!("d{i}"), "w", "r", "c");
            store.add_drawer(&d, NOW + i).unwrap();
        }
        assert_eq!(store.all_drawers_bounded(Some(2)).unwrap().len(), 2);
        assert_eq!(store.all_drawers_bounded(None).unwrap().len(), 5);
    }

    #[test]
    fn first_open_audit_estate_uuid_matches_manifest() {
        // Regression: on a fresh estate the uuid stamped into audit
        // events must equal the manifest estate_uuid. (The Swift port
        // diverged here — store uuid vs manifest uuid — until the init
        // ordering was fixed to match this leg.)
        let store = open_store();
        let d = sample_drawer("d1", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        let manifest_uuid = Uuid::parse_str(&store.read_manifest().unwrap().estate_uuid).unwrap();
        let row = Uuid::parse_str(&tid("d1")).unwrap();
        let events = store.storage().audit_log().events_for_row(row).unwrap();
        assert!(
            !events.is_empty(),
            "capture must emit a genesis audit event"
        );
        assert_eq!(
            events[0].estate_uuid, manifest_uuid,
            "audit event estate uuid must equal the manifest estate uuid on first open"
        );
    }

    #[test]
    fn set_meta_overwrites_and_read_manifest_picks_it_up() {
        let store = open_store();
        store
            .set_meta(ManifestKey::EstateName.as_str(), "lab")
            .unwrap();
        assert_eq!(store.read_manifest().unwrap().estate_name, "lab");
        assert_eq!(
            store
                .get_meta(ManifestKey::EstateName.as_str())
                .unwrap()
                .as_deref(),
            Some("lab")
        );
    }

    // -----------------------------------------------------------------
    // Estate handshake — verify the LP-1B FakeStore contract still
    // works against the LP-1E concrete store
    // -----------------------------------------------------------------

    #[test]
    fn estate_open_reads_manifest_from_concrete_store() {
        let store: Arc<dyn DrawerStore> = Arc::new(open_store());
        let owner = OwnerCredentials::new("alice");
        let estate = Estate::open(store, owner).unwrap();
        let m = estate.manifest().unwrap();
        assert_eq!(m.bitmap_layout_version, "v1.0");
    }

    // -----------------------------------------------------------------
    // Drawer CRUD
    // -----------------------------------------------------------------

    #[test]
    fn add_drawer_then_get_round_trips() {
        let store = open_store();
        let d = sample_drawer("d1", "w", "kitchen", "hello");
        store.add_drawer(&d, NOW).unwrap();
        let back = store.get_drawer(&tid("d1")).unwrap().unwrap();
        assert_eq!(back.content, "hello");
        // ADR-017: wing/room are no longer stored in the drawers table;
        // they default to empty on read-back (populated by node-tree
        // JOIN at fetch time in production paths).
        assert_eq!(back.parent_node_id, d.parent_node_id);
    }

    #[test]
    fn add_drawer_rejects_empty_parent_node_id() {
        let store = open_store();
        let mut d = sample_drawer("d1", "w", "kitchen", "hello");
        d.parent_node_id = String::new();
        let err = store.add_drawer(&d, NOW).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => assert!(msg.contains("parent_node_id")),
            other => panic!("expected InvalidContent, got {:?}", other),
        }
    }

    #[test]
    fn add_drawer_rejects_secret_plus_exportable() {
        let store = open_store();
        let mut d = sample_drawer("d-bad", "w", "kitchen", "secret stuff");
        d.adjective_bitmap = (AdjectiveSensitivity::Secret.raw_value() << 6)
            | (AdjectiveExportability::Public.raw_value() << 12);
        let err = store.add_drawer(&d, NOW).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                // The gate's prior==None branch runs ForbiddenCombinations,
                // catching I-22 (secret + exportable) on the capture event.
                assert!(
                    msg.contains("I-22"),
                    "expected I-22 gate rejection, got: {}",
                    msg
                );
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }
        // The capture was rejected, so neither row nor audit event landed.
        assert!(store.get_drawer(&tid("d-bad")).unwrap().is_none());
    }

    #[test]
    fn drawers_in_wing_excludes_tombstoned_and_orders_by_filed_at() {
        let store = open_store();
        let mut d1 = sample_drawer_with_nodes(&store, "d1", "w", "k", "first");
        d1.filed_at = NOW + 10;
        let mut d2 = sample_drawer_with_nodes(&store, "d2", "w", "k", "second");
        d2.filed_at = NOW + 20;
        // Same parent_node_id as d1/d2 (same wing+room nodes already exist).
        d2.parent_node_id = d1.parent_node_id.clone();
        let mut d3 = sample_drawer_with_nodes(&store, "d3", "w", "k", "tombstoned");
        d3.filed_at = NOW + 30;
        d3.tombstoned_at = Some(NOW + 31);
        d3.parent_node_id = d1.parent_node_id.clone();
        store.add_drawer(&d1, NOW).unwrap();
        store.add_drawer(&d2, NOW).unwrap();
        store.add_drawer(&d3, NOW).unwrap();
        let rows = store.drawers_in_wing("w").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].id, tid("d1"));
        assert_eq!(rows[1].id, tid("d2"));
    }

    #[test]
    fn drawers_in_wing_room_filters_on_both() {
        let store = open_store();
        let d1 = sample_drawer_with_nodes(&store, "d1", "w", "k", "kitchen-row");
        let d2 = sample_drawer_with_nodes(&store, "d2", "w", "study", "study-row");
        store.add_drawer(&d1, NOW).unwrap();
        store.add_drawer(&d2, NOW).unwrap();
        let kitchen = store.drawers_in_wing_room("w", "k").unwrap();
        assert_eq!(kitchen.len(), 1);
        assert_eq!(kitchen[0].id, tid("d1"));
    }

    #[test]
    fn drawers_by_source_orders_by_chunk_index_then_filed_at() {
        let store = open_store();
        let mut d1 = sample_drawer("d1", "w", "k", "chunk-2");
        d1.source_file = Some("file.txt".to_string());
        d1.chunk_index = Some(2);
        d1.filed_at = NOW + 5;
        let mut d2 = sample_drawer("d2", "w", "k", "chunk-0");
        d2.source_file = Some("file.txt".to_string());
        d2.chunk_index = Some(0);
        d2.filed_at = NOW + 10;
        let mut d3 = sample_drawer("d3", "w", "k", "chunk-1");
        d3.source_file = Some("file.txt".to_string());
        d3.chunk_index = Some(1);
        d3.filed_at = NOW + 3;
        store.add_drawer(&d1, NOW).unwrap();
        store.add_drawer(&d2, NOW).unwrap();
        store.add_drawer(&d3, NOW).unwrap();
        let rows = store.drawers_by_source("file.txt").unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].id, tid("d2"));
        assert_eq!(rows[1].id, tid("d3"));
        assert_eq!(rows[2].id, tid("d1"));
    }

    #[test]
    fn drawer_ids_returns_every_drawer_id() {
        let store = open_store();
        store
            .add_drawer(&sample_drawer("a", "w", "k", "one"), NOW)
            .unwrap();
        store
            .add_drawer(&sample_drawer("b", "w", "k", "two"), NOW)
            .unwrap();
        let mut ids = store.drawer_ids().unwrap();
        ids.sort();
        let mut want = vec![tid("a"), tid("b")];
        want.sort();
        assert_eq!(ids, want);
    }

    // -----------------------------------------------------------------
    // Supersession cascade
    // -----------------------------------------------------------------

    #[test]
    fn supersession_cascade_flips_predecessor_state_and_files_tunnel() {
        let store = open_store();
        let lineage = Uuid::new_v4();
        let mut prior = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "v1");
        prior.lineage_id = lineage;
        prior.filed_at = NOW;
        let mut next = sample_drawer("22222222-2222-4222-8222-222222222222", "w", "k", "v2");
        next.lineage_id = lineage;
        next.filed_at = NOW + 100;

        store.add_drawer(&prior, NOW).unwrap();
        store.add_drawer(&next, NOW + 100).unwrap();

        // Predecessor 6-bit state field set to Superseded (raw 16).
        let p_back = store
            .get_drawer("11111111-1111-4111-8111-111111111111")
            .unwrap()
            .unwrap();
        assert_eq!(
            p_back.adjective_bitmap & 0x3F,
            State::Superseded.raw_value()
        );

        // The flip went through the gate → one audit event for the
        // predecessor with after-state superseded (bitmap_audit retired).
        let prow = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage().audit_log().events_for_row(prow).unwrap();
        assert_eq!(events.len(), 2); // predecessor's capture + the supersede flip
        assert_eq!(events[0].verb, "capture");
        assert_eq!(
            events[1].after_adjective & 0x3F,
            State::Superseded.raw_value()
        );

        // Directional supersedes tunnel exists from new → prior.
        let tunnel = store
            .get_tunnel(&format!(
                "supersedes:{}:{}",
                "22222222-2222-4222-8222-222222222222", "11111111-1111-4111-8111-111111111111"
            ))
            .unwrap()
            .unwrap();
        assert_eq!(tunnel.kind, TunnelKind::Supersedes);
        assert_eq!(
            tunnel.source_drawer_id.as_deref(),
            Some("22222222-2222-4222-8222-222222222222")
        );
        assert_eq!(
            tunnel.target_drawer_id.as_deref(),
            Some("11111111-1111-4111-8111-111111111111")
        );
    }

    /// B1 Finding #3 regression — atomic cascade ordering.
    ///
    /// Pre-fix: `mutate_state` (predecessor flip to Superseded) ran BEFORE the
    /// `supersedes` tunnel insert. A tunnel insert failure would leave the
    /// predecessor permanently Superseded with no active successor — a silent
    /// lineage corruption. Post-fix ordering:
    ///   1. `gated_capture` (new drawer + audit event)
    ///   2. Tunnel insert
    ///   3. Compensating delete of new drawer on tunnel failure
    ///   4. `mutate_state` (predecessor flip) ONLY if tunnel insert succeeded
    ///
    /// This test verifies the post-fix happy path: all three invariants hold
    /// simultaneously — new drawer present, tunnel filed, predecessor flipped.
    /// If the ordering were wrong (flip before tunnel), a failed tunnel insert
    /// in step 2 would leave the predecessor Superseded with the new drawer
    /// absent — a state that cannot be verified by a success-path test but is
    /// prevented structurally by the ordering change.
    ///
    /// (Full fault-injection test requires a FailingStorage fixture not yet
    /// present in the test harness. The happy-path test regression-guards the
    /// fix did not break the success path. See planned B3 fault-injection task.)
    #[test]
    fn cascade_ordering_drawer_tunnel_and_predecessor_flip_all_consistent() {
        let store = open_store();
        let lineage = Uuid::new_v4();
        let mut prior = sample_drawer("aaaa1111-0000-4000-8000-000000000001", "w", "k", "v1");
        prior.lineage_id = lineage;
        prior.filed_at = NOW;
        let mut next = sample_drawer("aaaa2222-0000-4000-8000-000000000002", "w", "k", "v2");
        next.lineage_id = lineage;
        next.filed_at = NOW + 50;

        store.add_drawer(&prior, NOW).unwrap();
        store.add_drawer(&next, NOW + 50).unwrap();

        // Post-condition 1: new drawer is present.
        let new_row = store
            .get_drawer("aaaa2222-0000-4000-8000-000000000002")
            .unwrap()
            .expect("new drawer must be present");
        assert_eq!(new_row.content, "v2");

        // Post-condition 2: supersedes tunnel was filed (new → prior).
        let tunnel_key = format!(
            "supersedes:{}:{}",
            "aaaa2222-0000-4000-8000-000000000002",
            "aaaa1111-0000-4000-8000-000000000001"
        );
        let tunnel = store
            .get_tunnel(&tunnel_key)
            .unwrap()
            .expect("supersedes tunnel must be filed");
        assert_eq!(tunnel.kind, TunnelKind::Supersedes);

        // Post-condition 3: predecessor state flipped to Superseded — ONLY AFTER
        // the tunnel insert, so the lineage graph is always consistent.
        let prior_row = store
            .get_drawer("aaaa1111-0000-4000-8000-000000000001")
            .unwrap()
            .expect("predecessor must still be present");
        assert_eq!(
            prior_row.adjective_bitmap & 0x3F,
            State::Superseded.raw_value(),
            "predecessor must be Superseded after a successful cascade"
        );
    }

    // -----------------------------------------------------------------
    // Mutation paths
    // -----------------------------------------------------------------

    #[test]
    fn mutate_provenance_writes_provenance_audit_row() {
        let store = open_store();
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        // source_type=2 | channel=1 | confidence=16 — all gate-legal.
        let prov: i64 = 0x10000042;
        store
            .mutate_provenance(
                "11111111-1111-4111-8111-111111111111",
                prov,
                "alice",
                Some("test"),
                NOW + 1,
            )
            .unwrap();
        assert_eq!(
            store
                .get_drawer("11111111-1111-4111-8111-111111111111")
                .unwrap()
                .unwrap()
                .provenance,
            prov
        );
        // Gate appended one event carrying the provenance write.
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage().audit_log().events_for_row(row).unwrap();
        assert_eq!(events.len(), 2); // capture + provenance mutation
        assert_eq!(events[1].after_provenance, prov);
    }

    #[test]
    fn mutate_adjective_writes_audit_and_persists() {
        let store = open_store();
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        // Trust at bits 18-23 (cookbook §2.3); canonical = raw 3.
        let trust_canonical = Trust::Canonical.raw_value() << 18;
        store
            .mutate_adjective(
                "11111111-1111-4111-8111-111111111111",
                trust_canonical,
                "alice",
                Some("uplift"),
                NOW + 1,
            )
            .unwrap();
        assert_eq!(
            store
                .get_drawer("11111111-1111-4111-8111-111111111111")
                .unwrap()
                .unwrap()
                .adjective_bitmap,
            trust_canonical
        );
        // One audit event whose after-adjective carries the trust write
        // (the gate appended it; bitmap_audit is retired for this path).
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage().audit_log().events_for_row(row).unwrap();
        assert_eq!(events.len(), 2); // capture (genesis) + the adjective mutation
        assert_eq!(events[0].verb, "capture");
        assert_eq!(
            (events[1].after_adjective >> 18) & 0x3F,
            Trust::Canonical.raw_value()
        );
    }

    #[test]
    fn mutate_adjective_rejects_forbidden_combo() {
        let store = open_store();
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        let bad = (AdjectiveSensitivity::Secret.raw_value() << 6)
            | (AdjectiveExportability::Public.raw_value() << 12);
        let err = store
            .mutate_adjective(
                "11111111-1111-4111-8111-111111111111",
                bad,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                assert!(
                    msg.contains("I-22"),
                    "expected I-22 gate rejection, got: {}",
                    msg
                );
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }
        // Drawer unchanged; the rejected mutation appended NO new event,
        // but the genesis capture event remains (it is the only event).
        assert_eq!(
            store
                .get_drawer("11111111-1111-4111-8111-111111111111")
                .unwrap()
                .unwrap()
                .adjective_bitmap,
            0
        );
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage().audit_log().events_for_row(row).unwrap();
        assert_eq!(
            events.len(),
            1,
            "only the genesis capture event; the rejected mutation appended nothing"
        );
        assert_eq!(events[0].verb, "capture");
    }

    #[test]
    fn mutate_operational_writes_audit() {
        let store = open_store();
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        store
            .mutate_operational(
                "11111111-1111-4111-8111-111111111111",
                0x100,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap();
        assert_eq!(
            store
                .get_drawer("11111111-1111-4111-8111-111111111111")
                .unwrap()
                .unwrap()
                .operational_bitmap,
            0x100
        );
        // Gate appended one event carrying the operational write.
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage().audit_log().events_for_row(row).unwrap();
        assert_eq!(events.len(), 2); // capture + operational mutation
        assert_eq!(events[1].after_operational, 0x100);
    }

    #[test]
    fn mutate_state_validates_and_preserves_upper_axes() {
        let store = open_store();
        let mut d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        d.adjective_bitmap = Trust::Canonical.raw_value() << 18; // state=Active=0, trust=Canonical (cookbook §2.3)
        store.add_drawer(&d, NOW).unwrap();
        store
            .mutate_state(
                "11111111-1111-4111-8111-111111111111",
                State::Contested,
                RowVerb::Contest,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap();
        let back = store
            .get_drawer("11111111-1111-4111-8111-111111111111")
            .unwrap()
            .unwrap();
        // Upper axes preserved, state flipped.
        assert_eq!(back.adjective_bitmap & 0x3F, State::Contested.raw_value());
        assert_eq!(
            (back.adjective_bitmap >> 18) & 0x3F,
            Trust::Canonical.raw_value()
        );
    }

    #[test]
    fn mutate_state_rejects_illegal_transition() {
        let store = open_store();
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        // Active → Accepted via MutateConfirm is not in the legal table.
        let err = store
            .mutate_state(
                "11111111-1111-4111-8111-111111111111",
                State::Accepted,
                RowVerb::Observe,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                // After the Display fix, the message uses English names rather
                // than the Debug variant name "IllegalTransition". Assert on the
                // semantic substring that survives the change.
                assert!(
                    msg.contains("illegal state transition"),
                    "expected gate-rejection message containing 'illegal state transition', got: {}",
                    msg
                );
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }
    }

    // -----------------------------------------------------------------
    // S-1 enforcement (cookbook §9.5.1)
    // Mirrors the Swift tests in StateTransitionTests.swift.
    // -----------------------------------------------------------------

    #[test]
    fn mutate_state_s1_rejects_low_trust_promote() {
        let store = open_store();
        let mut d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        // Cookbook §2.3: state at bits 0-5 (active = raw 0), trust at
        // bits 18-23. Trust=Observed (raw 1) is BELOW Canonical (raw 3),
        // so promoting to Accepted must violate S-1.
        d.adjective_bitmap = Trust::Observed.raw_value() << 18;
        store.add_drawer(&d, NOW).unwrap();

        let err = store
            .mutate_state(
                "11111111-1111-4111-8111-111111111111",
                State::Accepted,
                RowVerb::Promote,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                assert!(
                    msg.contains("S-1"),
                    "expected S-1 invariant violation via gate, got: {}",
                    msg
                );
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }

        // Row state unchanged after rejected mutation.
        let back = store
            .get_drawer("11111111-1111-4111-8111-111111111111")
            .unwrap()
            .unwrap();
        assert_eq!(back.adjective_bitmap & 0x3F, State::Active.raw_value());
        assert_eq!(
            (back.adjective_bitmap >> 18) & 0x3F,
            Trust::Observed.raw_value()
        );
    }

    #[test]
    fn mutate_state_s1_accepts_canonical_trust_promote() {
        let store = open_store();
        let mut d = sample_drawer("22222222-2222-4222-8222-222222222222", "w", "k", "hi");
        // Trust=Canonical (raw 3) satisfies S-1.
        d.adjective_bitmap = Trust::Canonical.raw_value() << 18;
        store.add_drawer(&d, NOW).unwrap();

        store
            .mutate_state(
                "22222222-2222-4222-8222-222222222222",
                State::Accepted,
                RowVerb::Promote,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap();

        let back = store
            .get_drawer("22222222-2222-4222-8222-222222222222")
            .unwrap()
            .unwrap();
        assert_eq!(back.adjective_bitmap & 0x3F, State::Accepted.raw_value());
        assert_eq!(
            (back.adjective_bitmap >> 18) & 0x3F,
            Trust::Canonical.raw_value()
        );
    }

    // -----------------------------------------------------------------
    // Tunnel / KGFact / Diary CRUD
    // -----------------------------------------------------------------

    #[test]
    fn add_tunnel_and_query_by_source_wing() {
        let store = open_store();
        let mut t = Tunnel::new(
            "t1".to_string(),
            "w".to_string(),
            "k".to_string(),
            "w".to_string(),
            "p".to_string(),
            "supplies".to_string(),
            "alice".to_string(),
            NOW,
        );
        t.source_drawer_id = Some(tid("d1"));
        store.add_tunnel(&t).unwrap();
        let from = store.tunnels_from_wing("w").unwrap();
        assert_eq!(from.len(), 1);
        let from_room = store.tunnels_from_wing_room("w", "k").unwrap();
        assert_eq!(from_room.len(), 1);
        let to = store.tunnels_to_wing("w").unwrap();
        assert_eq!(to.len(), 1);
    }

    #[test]
    fn add_kg_fact_and_kg_facts_for_drawer() {
        let store = open_store();
        let f = KGFact::new(
            "f1".to_string(),
            "alice".to_string(),
            "livesIn".to_string(),
            "berlin".to_string(),
            tid("d1"),
            NOW,
        );
        store.add_kg_fact(&f).unwrap();
        let rows = store.kg_facts_for_drawer(&tid("d1")).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].subject, "alice");
    }

    #[test]
    fn diary_round_trip_and_lastn_ordering() {
        let store = open_store();
        let e1 = DiaryEntry {
            id: "e1".to_string(),
            agent_name: "skippy".to_string(),
            entry: "first".to_string(),
            topic: "log".to_string(),
            wing: "wing_skippy".to_string(),
            room: "diary".to_string(),
            filed_at: NOW + 1,
            embedding_model_id: "test-v1".to_string(),
            tombstoned_at: None,
            removed_by_batch: None,
            operational_bitmap: 0,
            reward: None,
            reward_provenance: None,
        };
        let mut e2 = e1.clone();
        e2.id = "e2".to_string();
        e2.entry = "second".to_string();
        e2.filed_at = NOW + 2;
        store.add_diary_entry(&e1).unwrap();
        store.add_diary_entry(&e2).unwrap();
        let last = store.read_diary("skippy", 1).unwrap();
        // Newest first.
        assert_eq!(last.len(), 1);
        assert_eq!(last[0].id, "e2");
        let in_wing = store
            .read_diary_in_wing("skippy", "wing_skippy", 5)
            .unwrap();
        assert_eq!(in_wing.len(), 2);
    }

    // -----------------------------------------------------------------
    // Recall trace
    // -----------------------------------------------------------------

    #[test]
    fn recall_trace_insert_get_and_mark_used() {
        let store = open_store();
        let item = RecallTraceItem::new(
            "trace-1",
            "drawer-1",
            "2024-01-01T00:00:00.000Z",
            Some(0.75),
            0,
        );
        store.insert_recall_trace(&item).unwrap();
        let back = store.get_recall_trace("trace-1").unwrap().unwrap();
        assert!(!back.used());
        store.mark_recall_trace_used("trace-1", NOW + 5).unwrap();
        let after = store.get_recall_trace("trace-1").unwrap().unwrap();
        assert!(after.used());
        // Idempotent.
        store.mark_recall_trace_used("trace-1", NOW + 6).unwrap();
        // Missing id surfaces RecallTraceItemNotFound.
        let err = store
            .mark_recall_trace_used("missing", NOW + 7)
            .unwrap_err();
        match err {
            LocusKitError::RecallTraceItemNotFound { id } => assert_eq!(id, "missing"),
            other => panic!("expected RecallTraceItemNotFound, got {:?}", other),
        }
    }

    #[test]
    fn recall_trace_since_filters_and_orders_ascending() {
        let store = open_store();
        let early = RecallTraceItem::new("early", "d-a", "2024-01-01T00:00:00.000Z", None, 0);
        let mid = RecallTraceItem::new("mid", "d-b", "2024-06-01T00:00:00.000Z", None, 0);
        let late = RecallTraceItem::new("late", "d-c", "2024-12-01T00:00:00.000Z", None, 0);
        store.insert_recall_trace(&early).unwrap();
        store.insert_recall_trace(&late).unwrap();
        store.insert_recall_trace(&mid).unwrap();
        let rows = store
            .recall_trace_since("2024-06-01T00:00:00.000Z")
            .unwrap();
        let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, vec!["mid", "late"]);
    }

    #[test]
    fn recent_recall_traces_windowed_filter() {
        let store = open_store();
        let before = RecallTraceItem::new("before", "d-a", "2024-01-01T00:00:00.000Z", None, 0);
        let at_since = RecallTraceItem::new("at-since", "d-b", "2024-06-01T00:00:00.000Z", None, 0);
        let inside = RecallTraceItem::new("inside", "d-c", "2024-09-01T00:00:00.000Z", None, 0);
        let at_now = RecallTraceItem::new("at-now", "d-d", "2024-12-01T00:00:00.000Z", None, 0);
        let after = RecallTraceItem::new("after", "d-e", "2025-01-01T00:00:00.000Z", None, 0);
        for item in &[&before, &at_since, &inside, &at_now, &after] {
            store.insert_recall_trace(item).unwrap();
        }
        let rows = store
            .recent_recall_traces("2024-06-01T00:00:00.000Z", "2024-12-01T00:00:00.000Z")
            .unwrap();
        let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        // Lower and upper bounds inclusive; "before" and "after" excluded.
        assert!(ids.contains(&"at-since"));
        assert!(ids.contains(&"inside"));
        assert!(ids.contains(&"at-now"));
        assert!(!ids.contains(&"before"));
        assert!(!ids.contains(&"after"));
    }

    #[test]
    fn recent_recall_traces_empty_when_window_has_no_rows() {
        let store = open_store();
        store
            .insert_recall_trace(&RecallTraceItem::new(
                "old",
                "d-x",
                "2023-01-01T00:00:00.000Z",
                None,
                0,
            ))
            .unwrap();
        let rows = store
            .recent_recall_traces("2024-01-01T00:00:00.000Z", "2024-12-31T00:00:00.000Z")
            .unwrap();
        assert!(rows.is_empty());
    }

    // -----------------------------------------------------------------
    // prune_recall_traces, mark_recall_traces_used, count_recall_traces
    // (Item A parity — mirrors Swift DrawerStore methods)
    // -----------------------------------------------------------------

    #[test]
    fn prune_recall_traces_removes_rows_before_cutoff() {
        let store = open_store();
        // Insert three rows at different timestamps.
        store.insert_recall_trace(&RecallTraceItem::new(
            "p-old1", "d-1", "2024-01-01T00:00:00.000Z", None, 0,
        )).unwrap();
        store.insert_recall_trace(&RecallTraceItem::new(
            "p-old2", "d-2", "2024-06-01T00:00:00.000Z", None, 0,
        )).unwrap();
        store.insert_recall_trace(&RecallTraceItem::new(
            "p-keep", "d-3", "2024-12-01T00:00:00.000Z", None, 0,
        )).unwrap();

        // Prune rows strictly before 2024-12-01 (ISO8601 lexicographic < is
        // numerically correct for canonical UTC strings — fleet date rule).
        let deleted = store.prune_recall_traces("2024-12-01T00:00:00.000Z").unwrap();
        assert_eq!(deleted, 2, "two rows before cutoff must be deleted");

        // The kept row survives.
        assert!(store.get_recall_trace("p-keep").unwrap().is_some(), "p-keep must survive");
        // The pruned rows are gone.
        assert!(store.get_recall_trace("p-old1").unwrap().is_none(), "p-old1 must be pruned");
        assert!(store.get_recall_trace("p-old2").unwrap().is_none(), "p-old2 must be pruned");
    }

    #[test]
    fn prune_recall_traces_returns_zero_when_nothing_to_prune() {
        let store = open_store();
        store.insert_recall_trace(&RecallTraceItem::new(
            "recent", "d-r", "2025-06-01T00:00:00.000Z", None, 0,
        )).unwrap();
        // Cutoff in the past — nothing qualifies.
        let deleted = store.prune_recall_traces("2020-01-01T00:00:00.000Z").unwrap();
        assert_eq!(deleted, 0);
        // Row is still present.
        assert!(store.get_recall_trace("recent").unwrap().is_some());
    }

    #[test]
    fn prune_recall_traces_empty_table_returns_zero() {
        let store = open_store();
        let deleted = store.prune_recall_traces("2099-01-01T00:00:00.000Z").unwrap();
        assert_eq!(deleted, 0);
    }

    #[test]
    fn mark_recall_traces_used_bulk_marks_matching_window() {
        let store = open_store();
        // Three rows for target "dt-A": two inside window, one outside.
        store.insert_recall_trace(&RecallTraceItem::new(
            "bt1", "dt-A", "2024-01-01T00:00:00.000Z", None, 0,
        )).unwrap();
        store.insert_recall_trace(&RecallTraceItem::new(
            "bt2", "dt-A", "2024-01-02T00:00:00.000Z", None, 0,
        )).unwrap();
        store.insert_recall_trace(&RecallTraceItem::new(
            "bt3", "dt-A", "2024-01-04T00:00:00.000Z", None, 0,
        )).unwrap(); // outside window
        store.insert_recall_trace(&RecallTraceItem::new(
            "bt4", "dt-B", "2024-01-01T12:00:00.000Z", None, 0,
        )).unwrap(); // different target

        let touched = store.mark_recall_traces_used(
            "dt-A",
            "2024-01-01T00:00:00.000Z",
            "2024-01-03T00:00:00.000Z",
        ).unwrap();
        assert_eq!(touched, 2, "two rows inside window must be marked");

        assert!(store.get_recall_trace("bt1").unwrap().unwrap().used(), "bt1 must be marked");
        assert!(store.get_recall_trace("bt2").unwrap().unwrap().used(), "bt2 must be marked");
        assert!(!store.get_recall_trace("bt3").unwrap().unwrap().used(), "bt3 outside window");
        assert!(!store.get_recall_trace("bt4").unwrap().unwrap().used(), "bt4 different target");
    }

    #[test]
    fn mark_recall_traces_used_is_idempotent() {
        let store = open_store();
        store.insert_recall_trace(&RecallTraceItem::new(
            "idem-x", "dt-X", "2024-06-01T00:00:00.000Z", None, 0,
        )).unwrap();
        let first = store.mark_recall_traces_used(
            "dt-X", "2024-01-01T00:00:00.000Z", "2025-01-01T00:00:00.000Z",
        ).unwrap();
        assert_eq!(first, 1);
        let second = store.mark_recall_traces_used(
            "dt-X", "2024-01-01T00:00:00.000Z", "2025-01-01T00:00:00.000Z",
        ).unwrap();
        assert_eq!(second, 0, "second call on already-marked row must return 0");
    }

    #[test]
    fn mark_recall_traces_used_unknown_target_returns_zero() {
        let store = open_store();
        let n = store.mark_recall_traces_used(
            "no-such-target",
            "2000-01-01T00:00:00.000Z",
            "2099-01-01T00:00:00.000Z",
        ).unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn count_recall_traces_reports_total_including_used() {
        let store = open_store();
        assert_eq!(store.count_recall_traces().unwrap(), 0, "empty table → 0");

        for i in 1..=3u32 {
            store.insert_recall_trace(&RecallTraceItem::new(
                &format!("ct-{i}"),
                &format!("d-{i}"),
                "2024-06-01T00:00:00.000Z",
                None,
                0,
            )).unwrap();
        }
        store.mark_recall_trace_used("ct-2", NOW).unwrap();
        // count must include marked rows.
        assert_eq!(store.count_recall_traces().unwrap(), 3, "three rows total");
    }

    #[test]
    fn all_tunnels_returns_all_non_tombstoned() {
        let store = open_store();
        let t1 = Tunnel::new(
            "t1".to_string(), "wA".to_string(), "r1".to_string(),
            "wB".to_string(), "r2".to_string(), "link-a".to_string(),
            "test".to_string(), NOW,
        );
        let t2 = Tunnel::new(
            "t2".to_string(), "wC".to_string(), "r3".to_string(),
            "wD".to_string(), "r4".to_string(), "link-b".to_string(),
            "test".to_string(), NOW,
        );
        store.add_tunnel(&t1).unwrap();
        store.add_tunnel(&t2).unwrap();
        let all = store.all_tunnels().unwrap();
        assert_eq!(all.len(), 2);
        let ids: Vec<&str> = all.iter().map(|t| t.id.as_str()).collect();
        assert!(ids.contains(&"t1"));
        assert!(ids.contains(&"t2"));
    }

    #[test]
    fn all_tunnels_returns_empty_for_fresh_store() {
        let store = open_store();
        let all = store.all_tunnels().unwrap();
        assert!(all.is_empty());
    }

    // -----------------------------------------------------------------
    // Tunnel retirement tests (T13 / ADR-021 Phase 7)
    // -----------------------------------------------------------------

    fn dreamed_tunnel(id: &str) -> Tunnel {
        let mut t = Tunnel::new(
            id.to_string(), "src".to_string(), "r1".to_string(),
            "tgt".to_string(), "r2".to_string(), format!("edge-{}", id),
            "bilby".to_string(), NOW,
        );
        // stamp dreamed provenance (bit 0 of provenance_bitmap)
        t = t.with_dreamed_provenance();
        t
    }

    fn declared_tunnel(id: &str) -> Tunnel {
        Tunnel::new(
            id.to_string(), "src".to_string(), "r1".to_string(),
            "tgt".to_string(), "r2".to_string(), format!("edge-{}", id),
            "bilby".to_string(), NOW,
        )
        // provenance_bitmap = 0 (is_dreamed = false)
    }

    #[test]
    fn retire_tunnel_sets_bit_13_and_persists() {
        let store = open_store();
        let t = dreamed_tunnel("td-1");
        store.add_tunnel(&t).unwrap();

        store.retire_tunnel("td-1", "bilby", NOW).unwrap();

        let fetched = store.get_tunnel("td-1").unwrap().expect("tunnel must exist");
        assert!(fetched.is_retired(), "bit 13 must be set after retire_tunnel");
        assert_eq!(fetched.operational_bitmap & Tunnel::IS_RETIRED_BIT, Tunnel::IS_RETIRED_BIT);
    }

    #[test]
    fn unretire_tunnel_clears_bit_13() {
        let store = open_store();
        store.add_tunnel(&dreamed_tunnel("td-2")).unwrap();
        store.retire_tunnel("td-2", "bilby", NOW).unwrap();

        store.unretire_tunnel("td-2", "bilby", NOW).unwrap();

        let fetched = store.get_tunnel("td-2").unwrap().expect("tunnel must exist");
        assert!(!fetched.is_retired(), "bit 13 must be cleared after unretire_tunnel");
    }

    #[test]
    fn retire_tunnel_returns_not_found_for_unknown_id() {
        let store = open_store();
        let result = store.retire_tunnel("no-such-tunnel", "bilby", NOW);
        assert!(
            matches!(result, Err(LocusKitError::TunnelNotFound { .. })),
            "must return TunnelNotFound for unknown tunnel id"
        );
    }

    #[test]
    fn unretire_tunnel_returns_not_found_for_unknown_id() {
        let store = open_store();
        let result = store.unretire_tunnel("no-such-tunnel", "bilby", NOW);
        assert!(
            matches!(result, Err(LocusKitError::TunnelNotFound { .. })),
            "must return TunnelNotFound for unknown tunnel id"
        );
    }

    #[test]
    fn all_active_tunnels_excludes_retired() {
        let store = open_store();
        store.add_tunnel(&dreamed_tunnel("td-retire")).unwrap();
        store.add_tunnel(&declared_tunnel("td-active")).unwrap();

        store.retire_tunnel("td-retire", "bilby", NOW).unwrap();

        let active = store.all_active_tunnels().unwrap();
        assert_eq!(active.len(), 1, "retired tunnel must be excluded from all_active_tunnels");
        assert_eq!(active[0].id, "td-active");
    }

    #[test]
    fn all_tunnels_includes_retired_tunnels() {
        let store = open_store();
        store.add_tunnel(&dreamed_tunnel("td-r1")).unwrap();
        store.retire_tunnel("td-r1", "bilby", NOW).unwrap();

        let all = store.all_tunnels().unwrap();
        assert_eq!(all.len(), 1, "all_tunnels must include retired tunnels (full-history view)");
        assert!(all[0].is_retired());
    }

    #[test]
    fn all_active_tunnels_returns_all_when_none_retired() {
        let store = open_store();
        store.add_tunnel(&dreamed_tunnel("td-1")).unwrap();
        store.add_tunnel(&declared_tunnel("td-2")).unwrap();

        let active = store.all_active_tunnels().unwrap();
        assert_eq!(active.len(), 2);
    }

    #[test]
    fn retire_unretire_round_trip_preserves_other_bits() {
        let store = open_store();
        // Set direction=bidirectional (raw 1 in bits 0-2) and lifecycle=proposed (raw 1 in bits 3-5).
        let mut t = declared_tunnel("td-bits");
        t.operational_bitmap = 1 | (1 << 3); // direction=bidirectional, lifecycle=proposed
        store.add_tunnel(&t).unwrap();

        store.retire_tunnel("td-bits", "bilby", NOW).unwrap();
        store.unretire_tunnel("td-bits", "bilby", NOW).unwrap();

        let restored = store.get_tunnel("td-bits").unwrap().expect("must exist");
        assert_eq!(
            restored.operational_bitmap,
            t.operational_bitmap,
            "round-trip must leave operational_bitmap identical"
        );
    }

    #[test]
    fn retirement_does_not_disturb_other_operational_bits() {
        let store = open_store();
        let mut t = dreamed_tunnel("td-bits2");
        // direction=bidirectional (1), lifecycle=proposed (1 << 3)
        t.operational_bitmap = 1 | (1 << 3);
        store.add_tunnel(&t).unwrap();

        store.retire_tunnel("td-bits2", "bilby", NOW).unwrap();

        let fetched = store.get_tunnel("td-bits2").unwrap().expect("must exist");
        assert!(fetched.is_retired());
        assert_eq!(
            fetched.direction(),
            crate::tunnel_operational::TunnelDirection::Bidirectional,
            "direction bits must survive retirement"
        );
        assert_eq!(
            fetched.lifecycle(),
            crate::tunnel_operational::TunnelLifecycle::Proposed,
            "lifecycle bits must survive retirement"
        );
    }

    #[test]
    fn declared_tunnel_has_is_dreamed_false() {
        let t = declared_tunnel("td-declared");
        assert!(!t.is_dreamed(), "declared tunnel must have is_dreamed = false");
    }

    #[test]
    fn dreamed_tunnel_has_is_dreamed_true() {
        let t = dreamed_tunnel("td-dreamed");
        assert!(t.is_dreamed(), "dreamed tunnel must have is_dreamed = true");
    }

    // -----------------------------------------------------------------
    // Audit reads
    // -----------------------------------------------------------------

    // -----------------------------------------------------------------
    // Summary surface
    // -----------------------------------------------------------------

    #[test]
    fn list_wings_and_list_rooms() {
        let store = open_store();
        let d1 = sample_drawer_with_nodes(&store, "d1", "w1", "k", "a");
        let d2 = sample_drawer_with_nodes(&store, "d2", "w1", "study", "b");
        let d3 = sample_drawer_with_nodes(&store, "d3", "w2", "lab", "c");
        store.add_drawer(&d1, NOW).unwrap();
        store.add_drawer(&d2, NOW).unwrap();
        store.add_drawer(&d3, NOW).unwrap();
        let wings = store.list_wings().unwrap();
        assert_eq!(wings.len(), 2);
        assert_eq!(wings[0].name, "w1");
        assert_eq!(wings[0].drawer_count, 2);
        assert_eq!(wings[0].room_count, 2);
        let rooms = store.list_rooms(Some("w1")).unwrap();
        assert_eq!(rooms.len(), 2);
        assert_eq!(rooms[0].name, "k");
        assert_eq!(rooms[1].name, "study");
        let all_rooms = store.list_rooms(None).unwrap();
        assert_eq!(all_rooms.len(), 3);
    }

    #[test]
    fn taxonomy_equals_list_wings_for_now() {
        let store = open_store();
        let d1 = sample_drawer_with_nodes(&store, "d1", "w1", "k", "a");
        store.add_drawer(&d1, NOW).unwrap();
        assert_eq!(store.taxonomy().unwrap(), store.list_wings().unwrap());
    }

    // -----------------------------------------------------------------
    // ISO8601 helper
    // -----------------------------------------------------------------

    #[test]
    fn iso8601_round_trip_through_format_and_parse() {
        let epoch = 1_700_000_000;
        let s = format_iso8601(epoch);
        // Sanity-check the shape.
        assert!(s.ends_with(".000Z"));
        assert_eq!(parse_iso8601(&s), Some(epoch));
    }

    #[test]
    fn iso8601_known_epoch_components() {
        // 2023-11-14T22:13:20.000Z (the epoch 1_700_000_000 second).
        assert_eq!(format_iso8601(1_700_000_000), "2023-11-14T22:13:20.000Z");
        // 1970-01-01T00:00:00.000Z (the epoch zero).
        assert_eq!(format_iso8601(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(parse_iso8601("1970-01-01T00:00:00.000Z"), Some(0));
    }

    // -----------------------------------------------------------------
    // Expunge verb coverage (cookbook §10.5 + §9.5.1, F17 second pass
    // item 1). Mirror of Swift `ExpungeTests.swift`.
    // -----------------------------------------------------------------

    #[test]
    fn expunge_gated_tombstones_sets_bit_26_zeros_content_stamps_tombstoned_at() {
        let store = open_store();
        let d = sample_drawer(
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "w",
            "k",
            "content-aaaa",
        );
        store.add_drawer(&d, NOW).unwrap();

        // Before: active, content non-empty, no tombstone, bit 26 clear.
        let before = store
            .get_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            .unwrap()
            .unwrap();
        assert_eq!(before.adjective_bitmap & 0x3F, State::Active.raw_value());
        assert_eq!(before.content, "content-aaaa");
        assert!(before.tombstoned_at.is_none());
        assert_eq!(before.adjective_bitmap & (1 << 26), 0);

        // seal_audit: true — direct-caller path, audit appended immediately.
        store
            .expunge_gated(
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "alice",
                Some("GDPR delete request 2026-05-29"),
                NOW + 500,
                true,
            )
            .unwrap();

        let after = store
            .get_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            .unwrap()
            .unwrap();
        assert_eq!(after.adjective_bitmap & 0x3F, State::Tombstoned.raw_value());
        assert_eq!(after.content, "");
        assert!(after.tombstoned_at.is_some());
        assert_ne!(
            after.adjective_bitmap & (1 << 26),
            0,
            "dreaming_recalc_required (bit 26) must be set on tombstone via expunge"
        );
    }

    #[test]
    fn expunge_gated_preserves_bits_24_and_25_when_setting_bit_26() {
        let store = open_store();
        let mut d = sample_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "w", "k", "hi");
        // Bit 24 = state_extension; bit 25 = lineage_clustering.
        // Both pre-set on the captured row. Expunge must preserve them
        // and add bit 26 on top.
        d.adjective_bitmap = (1 << 24) | (1 << 25);
        store.add_drawer(&d, NOW).unwrap();

        // seal_audit: true — direct-caller path, audit appended immediately.
        store
            .expunge_gated(
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "alice",
                None,
                NOW + 500,
                true,
            )
            .unwrap();
        let after = store
            .get_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            .unwrap()
            .unwrap();
        assert_ne!(after.adjective_bitmap & (1 << 24), 0);
        assert_ne!(after.adjective_bitmap & (1 << 25), 0);
        assert_ne!(after.adjective_bitmap & (1 << 26), 0);
    }

    #[test]
    fn expunge_gated_rejects_accepted_row_per_s3() {
        let store = open_store();
        let mut d = sample_drawer("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "w", "k", "hi");
        // Trust=Canonical (raw 3) at shift 18 satisfies S-1, so the
        // promote to Accepted succeeds. Then we attempt the expunge,
        // which must fail because (.accepted, .tombstone) is absent
        // from RowStateAutomaton.transitions (cookbook §9.5 S-3).
        d.adjective_bitmap = 3 << 18;
        store.add_drawer(&d, NOW).unwrap();
        store
            .mutate_state(
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                State::Accepted,
                RowVerb::Promote,
                "alice",
                None,
                NOW + 100,
            )
            .unwrap();

        let err = store
            .expunge_gated(
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "alice",
                None,
                NOW + 200,
                true,
            )
            .unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                // After the Display fix, messages use English words rather than
                // Rust Debug variant names. "illegal state transition" is the
                // canonical text from GateViolation::Display → RowStateError::Display.
                assert!(
                    msg.contains("illegal state transition")
                        || msg.contains("safety invariant violation"),
                    "expected gate-rejection message from S-3, got: {}",
                    msg
                );
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }

        // Row state must be unchanged; bit 26 must still be clear.
        let after = store
            .get_drawer("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            .unwrap()
            .unwrap();
        assert_eq!(after.adjective_bitmap & 0x3F, State::Accepted.raw_value());
        assert_eq!(after.adjective_bitmap & (1 << 26), 0);
    }

    #[test]
    fn expunge_gated_rejects_absent_row() {
        let store = open_store();
        let err = store
            .expunge_gated(
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                "alice",
                None,
                NOW + 100,
                true,
            )
            .unwrap_err();
        match err {
            LocusKitError::DrawerNotFound { .. } => {}
            other => panic!("expected DrawerNotFound, got {:?}", other),
        }
    }

    // ----------------------------------------------------------------
    // Force-tests: all_kg_facts_including_retired (math-provenance gate)
    // ----------------------------------------------------------------
    //
    // These guard FINDING-3: the trait default must fail loud on stores that
    // do not override the method; concrete production stores (InMemory here,
    // SQLite in drawer_store_sqlite.rs) must return real results.

    /// Concrete store — empty estate returns empty vec (not an error).
    /// A genuinely-empty estate is a valid state that is NOT a missing impl.
    #[test]
    fn all_kg_facts_including_retired_empty_estate_returns_empty_vec() {
        let store = open_store();
        let result = store.all_kg_facts_including_retired().unwrap();
        assert!(result.is_empty(), "empty estate should return empty vec");
    }

    /// Concrete store — active facts are visible in the timeline.
    /// Regression guard: the real impl must see active facts.
    #[test]
    fn all_kg_facts_including_retired_includes_active_facts() {
        let store = open_store();
        let f = KGFact::new(
            tid("f1"),
            "alice".to_string(),
            "livesIn".to_string(),
            "berlin".to_string(),
            tid("d1"),
            NOW,
        );
        store.add_kg_fact(&f).unwrap();
        let rows = store.all_kg_facts_including_retired().unwrap();
        assert_eq!(rows.len(), 1, "active fact must appear in timeline");
        assert_eq!(rows[0].subject, "alice");
    }

    /// Concrete store — retired (withdrawn) facts are visible in the
    /// timeline even though they are excluded from `all_kg_facts()`.
    /// This is the specific contract of the timeline path.
    #[test]
    fn all_kg_facts_including_retired_includes_retired_facts() {
        let store = open_store();
        let f = KGFact::new(
            tid("f2"),
            "bob".to_string(),
            "worksAt".to_string(),
            "acme".to_string(),
            tid("d2"),
            NOW,
        );
        store.add_kg_fact(&f).unwrap();
        // Retire the fact: transitions state to Withdrawn (≥ 7).
        store.withdraw_kg_fact(&tid("f2"), NOW + 1).unwrap();

        // all_kg_facts (active-only) must NOT see it.
        let active = store.all_kg_facts().unwrap();
        assert!(active.is_empty(), "withdrawn fact must not appear in active-only scan");

        // all_kg_facts_including_retired (full timeline) MUST see it.
        let timeline = store.all_kg_facts_including_retired().unwrap();
        assert_eq!(timeline.len(), 1, "withdrawn fact must appear in timeline");
        assert_eq!(timeline[0].subject, "bob");
    }

    /// Concrete store — mixed estate (one active + one retired) returns
    /// both rows from the timeline, preserving filed_at ascending order.
    #[test]
    fn all_kg_facts_including_retired_returns_active_and_retired_ordered() {
        let store = open_store();
        let f_active = KGFact::new(
            tid("fa"),
            "carol".to_string(),
            "knows".to_string(),
            "dave".to_string(),
            tid("d3"),
            NOW,
        );
        let f_retired = KGFact::new(
            tid("fr"),
            "eve".to_string(),
            "uses".to_string(),
            "tool".to_string(),
            tid("d4"),
            NOW + 1,
        );
        store.add_kg_fact(&f_active).unwrap();
        store.add_kg_fact(&f_retired).unwrap();
        store.withdraw_kg_fact(&tid("fr"), NOW + 2).unwrap();

        let timeline = store.all_kg_facts_including_retired().unwrap();
        assert_eq!(timeline.len(), 2, "timeline must include both active and retired");
        // filed_at ascending: f_active (NOW) before f_retired (NOW+1).
        assert_eq!(timeline[0].subject, "carol");
        assert_eq!(timeline[1].subject, "eve");
    }

    // -----------------------------------------------------------------
    // HLC unit contract — physical_time must be milliseconds
    //
    // Swift feeds HLCGenerator::send() in milliseconds (DrawerStore.swift:
    // `let nowMillis = Int64(now.timeIntervalSince1970 * 1000)`).
    // Rust callers pass epoch-seconds; the fix multiplies by 1000 at each
    // send() site. These tests verify the contract post-fix so a future
    // regression is caught at CI rather than at federation time.
    //
    // Implementation note: we read the HLC back from the audit log via
    // `store.storage().audit_log().events_for_row(uuid)` — the same
    // pattern used by existing audit-log tests in this module.
    // -----------------------------------------------------------------

    /// After add_drawer with a known `now` in epoch seconds, the HLC
    /// physical_time in the genesis audit event must be the millisecond
    /// magnitude (now * 1000), and physical_seconds_since_epoch() must
    /// round-trip back to the original seconds value.
    #[test]
    fn hlc_physical_time_is_milliseconds_after_capture() {
        // A concrete epoch-seconds value (2025-12-01 ~00:00 UTC).
        const CAPTURE_SECS: i64 = 1_765_000_000;
        const CAPTURE_MILLIS: i64 = CAPTURE_SECS * 1000;

        let store = open_store_at(CAPTURE_SECS);
        let d = sample_drawer("hlc-ms-d1", "wing", "room", "content");
        store.add_drawer(&d, CAPTURE_SECS).unwrap();

        let row_uuid = Uuid::parse_str(&tid("hlc-ms-d1")).unwrap();
        let events = store
            .storage()
            .audit_log()
            .events_for_row(row_uuid)
            .unwrap();
        assert!(!events.is_empty(), "capture must emit a genesis audit event");

        let hlc = events[0].hlc;
        // physical_time MUST be milliseconds — matching Swift's contract.
        assert_eq!(
            hlc.physical_time,
            CAPTURE_MILLIS,
            "HLC physical_time must be epoch milliseconds (now * 1000 = {}), \
             got {} — a value near zero indicates the unit bug (seconds fed \
             instead of milliseconds)",
            CAPTURE_MILLIS,
            hlc.physical_time
        );

        // physical_seconds_since_epoch() divides by 1000; must return
        // the original seconds value — not 1970.
        assert_eq!(
            hlc.physical_seconds_since_epoch(),
            CAPTURE_SECS,
            "physical_seconds_since_epoch() must return original epoch seconds {}, \
             got {} (near zero = 1970-era indicates unit mismatch)",
            CAPTURE_SECS,
            hlc.physical_seconds_since_epoch()
        );
    }

    /// Two add_drawer calls at the same `now` must produce monotonically
    /// increasing HLCs (logical counter bumps when physical doesn't advance).
    /// This validates the HLC generator works correctly with millis as input.
    #[test]
    fn hlc_monotonic_within_same_second() {
        const CAPTURE_SECS: i64 = 1_765_000_000;

        let store = open_store_at(CAPTURE_SECS);
        let d1 = sample_drawer("hlc-mono-d1", "wing", "room", "alpha");
        let d2 = sample_drawer("hlc-mono-d2", "wing", "room", "beta");
        store.add_drawer(&d1, CAPTURE_SECS).unwrap();
        store.add_drawer(&d2, CAPTURE_SECS).unwrap();

        let row1 = Uuid::parse_str(&tid("hlc-mono-d1")).unwrap();
        let row2 = Uuid::parse_str(&tid("hlc-mono-d2")).unwrap();
        let hlc1 = store.storage().audit_log().events_for_row(row1).unwrap()[0].hlc;
        let hlc2 = store.storage().audit_log().events_for_row(row2).unwrap()[0].hlc;

        assert!(
            hlc1 < hlc2,
            "HLCs must be strictly increasing: {:?} should be < {:?}",
            hlc1, hlc2
        );
        // Both share the same physical ms since wall clock didn't advance.
        assert_eq!(hlc1.physical_time, CAPTURE_SECS * 1000);
        assert_eq!(hlc2.physical_time, CAPTURE_SECS * 1000);
        // Logical counter must have bumped.
        assert_eq!(hlc2.logical_count, hlc1.logical_count + 1);
    }

    // Helper: open a store seeded with a specific `now`.
    fn open_store_at(now: i64) -> InMemoryDrawerStore {
        InMemoryDrawerStore::new(now, None).unwrap()
    }
}
