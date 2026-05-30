//! Concrete persistence-kit-backed `DrawerStore` impl. Ports
//! `DrawerStore.swift`.
//!
//! Wraps a `persistence_kit::Storage` and implements the full LocusKit
//! verb surface — drawer CRUD, supersession cascade, bitmap mutation
//! paths (with their audit-row writes), tunnel / kg-fact / diary CRUD,
//! the recall-trace surface, the audit reads, and the summary
//! projections.
//!
//! ## Swift-to-Rust shape changes
//!
//! - Swift `public actor DrawerStore` → Rust sync `struct
//!   InMemoryDrawerStore`. The persistence-kit Rust trait surface is sync;
//!   the underlying `InMemoryStorage` backend serialises access via an
//!   internal `Mutex`, which gives every multi-step path the
//!   atomicity the Swift `storage.transaction(isolation:)` provides.
//!   Same shape as `ContainerFingerprintStore` (LP-1C) and
//!   `NodeBundleStore` (LP-1D).
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
//!   internal UUID and does not surface a public auto-id, so this
//!   store carries an `AtomicI64` counter and writes the assigned
//!   value into the audit row's `id` column. Audit ids are dense and
//!   monotone within a process and ordered by insertion.

use crate::adjectives::State;
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
use substrate_lib::row_state::BitmapFields;
use substrate_lib::row_state::RowVerb;
use substrate_types::hlc::HLCGenerator;
use substrate_lib::audit_gate;
use persistence_kit::audit_log::AuditEvent as PkAuditEvent;
use crate::association::Association;
use crate::drawer_store::DrawerStore;
use crate::error::LocusKitError;
use crate::estate_types::{LatticeAnchor, RowID};
use crate::kg_fact::KGFact;
use crate::manifest::{ManifestKey, ManifestValues};
use crate::proposal::Proposal;
use crate::recall_trace_item::RecallTraceItem;
use crate::schema;
use crate::summaries::{RoomSummary, WingSummary};
use crate::tunnel::Tunnel;
use crate::tunnel_operational::TunnelKind;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::sync::Mutex;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use uuid::Uuid;
use substrate_kernel::bit_field;

// ---------------------------------------------------------------------------
// Table names
// ---------------------------------------------------------------------------

const T_DRAWERS: &str = "drawers";
const T_TUNNELS: &str = "tunnels";
const T_KG_FACTS: &str = "kg_facts";
const T_PROPOSALS: &str = "proposals";
const T_ASSOCIATIONS: &str = "associations";
const T_DIARY: &str = "diary";
const T_MANIFEST: &str = "manifest";
const T_RECALL_TRACE: &str = "recall_trace";

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Concrete `DrawerStore` impl backed by a persistence-kit `Storage`.
///
/// Today this is the in-memory test fixture and the substrate the
/// Estate verbs run against. The same struct will sit in front of the
/// future SQLite backend once persistence-kit's `Sqlite` variant ships:
/// the trait surface here is the contract, not the backend identity.
pub struct InMemoryDrawerStore {
    storage: Arc<dyn Storage>,
    /// Monotonic audit-id counter. SQLite would assign these as the
    /// integer primary key (rowid); the InMemory backend has no such
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

impl InMemoryDrawerStore {
    /// Open the store over a `Storage` handle. Opens the LocusKit
    /// schema (idempotent — re-opening an existing estate is a no-op
    /// for tables, generated columns, and indices) and writes the v1
    /// manifest defaults using `INSERT OR IGNORE` semantics (values
    /// written on a prior open stay authoritative).
    ///
    /// `now` is the deterministic clock value used to seed the
    /// `created_at` and `last_modified` manifest rows on first open.
    pub fn new(
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
        let mut store = InMemoryDrawerStore {
            storage,
            // Temporary; replaced below once the manifest exists.
            hlc: Mutex::new(HLCGenerator::new(0)),
            vocabulary: seed_vocab,
            estate_uuid: Uuid::nil(),
        };
        store.populate_v1_manifest_defaults(now)?;
        // Establish the clock: injected (holder) or made here (top).
        let generator = match hlc {
            Some(g) => g,
            None => HLCGenerator::new(store.maker_node_id()),
        };
        *store.hlc.lock().unwrap() = generator;
        // Freeze the write-gate vocabulary once (freeze-at-instantiation).
        store.vocabulary = crate::vocabulary::frozen().map_err(|e| {
            LocusKitError::InvalidContent(format!("LocusKit vocabulary failed to freeze: {:?}", e))
        })?;
        // Resolve estate uuid once; absent/malformed ⇒ fresh random.
        store.estate_uuid = store.resolve_estate_uuid().unwrap_or_else(Uuid::new_v4);
        Ok(store)
    }

    /// Read + parse the estate uuid manifest value, or None. Mirrors
    /// Swift `resolveEstateUuid`.
    fn resolve_estate_uuid(&self) -> Option<Uuid> {
        let rows = self.storage.row_store().query(
            T_MANIFEST,
            Some(&StoragePredicate::Eq(
                Column::new(T_MANIFEST, "key"),
                TypedValue::Text("estate_uuid".to_string()),
            )),
            &[], Some(1), None,
        ).ok()?;
        match rows.first().and_then(|r| r.get("value")) {
            Some(TypedValue::Text(s)) => Uuid::parse_str(s).ok(),
            _ => None,
        }
    }

    /// Derive a stable maker node id from the estate uuid manifest value
    /// (FNV-1a 32-bit, masked non-negative). 0 when absent. Mirrors
    /// Swift `makerNodeID`.
    fn maker_node_id(&self) -> i32 {
        let rows = match self.storage.row_store().query(
            T_MANIFEST,
            Some(&StoragePredicate::Eq(
                Column::new(T_MANIFEST, "key"),
                TypedValue::Text("estate_uuid".to_string()),
            )),
            &[],
            Some(1),
            None,
        ) {
            Ok(r) => r,
            Err(_) => return 0,
        };
        let uuid = match rows.first().and_then(|r| r.get("value")) {
            Some(TypedValue::Text(s)) => s.clone(),
            _ => return 0,
        };
        // FNV-1a 32-bit (SubstrateLib), masked to non-negative i32.
        let h = substrate_types::fnv::hash32(&uuid);
        (h & 0x7FFF_FFFF) as i32
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

    /// Find an active predecessor (state cluster < 3) sharing the
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

    /// Supersession cascade. Mirrors Swift `addDrawerWithCascade`.
    ///
    /// In the Swift port this whole sequence runs inside
    /// `storage.transaction(isolation: .serializable)`. The Rust
    /// persistence-kit has no transaction surface yet (its `storage.rs`
    /// doc defers that to the SQLite backend); the InMemory backend's
    /// internal `Mutex` serialises operations, which gives the same
    /// effective atomicity against this single backend. When
    /// persistence-kit grows transactions, wrap this block; behaviour
    /// stays the same.
    fn add_drawer_with_cascade(
        &self,
        new_drawer: &Drawer,
        prior_id: &str,
    ) -> Result<(), LocusKitError> {
        let row_store = self.storage.row_store();

        // Successor's gated capture (genesis) event + projection row.
        self.gated_capture(new_drawer, new_drawer.filed_at)?;

        // Read the predecessor's prior adjective + location so the
        // audit row's prior_value is exactly what the flip overwrites
        // and the supersedes tunnel carries the predecessor's place.
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
        let prior_wing = string_value_of(prior_row.get("wing"));
        let prior_room = string_value_of(prior_row.get("room"));

        let _ = prior_adjective;

        // Flip the predecessor active → superseded via the validated
        // state path. Earlier this smuggled the state through a manual
        // adjective-bitmap write + bitmap_audit row, bypassing the
        // transition automaton (F8 anti-pattern, same as withdraw). The
        // write gate now forbids moving state through a field edit, so
        // the supersede transition MUST go through mutate_state, which
        // validates active --supersede--> superseded and appends the
        // sealed audit event. changed_by is the triggering successor's
        // author (its insertion caused the flip).
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

        // Directional supersedes tunnel: new → prior.
        let mut tunnel = Tunnel::new(
            format!("supersedes:{}:{}", new_drawer.id, prior_id),
            new_drawer.wing.clone(),
            new_drawer.room.clone(),
            prior_wing,
            prior_room,
            "supersedes".to_string(),
            new_drawer.added_by.clone(),
            new_drawer.filed_at,
        );
        tunnel.kind = TunnelKind::Supersedes;
        tunnel.source_drawer_id = Some(new_drawer.id.clone());
        tunnel.target_drawer_id = Some(prior_id.to_string());
        row_store
            .insert(T_TUNNELS, tunnel_values(&tunnel))
            .map_err(map_storage_err)?;

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
        let row = rows
            .first()
            .ok_or_else(|| LocusKitError::DrawerNotFound {
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
                &[], Some(1), None,
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
        let stamp = self.hlc.lock().unwrap().send(now);

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
            LocusKitError::InvalidContent(format!("{:?} mutation rejected by gate: {:?}", column, v))
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
                let value = bit_field::extract_field(drawer.adjective_bitmap, slot.shift, slot.width);
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

        let anchor = substrate_lib::verbs::LatticeAnchor::udc(&drawer.udc_code);
        let stamp = self.hlc.lock().unwrap().send(now);

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
        .map_err(|v| LocusKitError::InvalidContent(format!("capture rejected by gate: {:?}", v)))?;

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


}

// ---------------------------------------------------------------------------
// DrawerStore trait impl
// ---------------------------------------------------------------------------

impl DrawerStore for InMemoryDrawerStore {
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
        validate_non_empty(&drawer.wing, "wing")?;
        validate_non_empty(&drawer.room, "room")?;
        validate_non_empty(&drawer.content, "content")?;
        validate_non_empty(&drawer.added_by, "addedBy")?;
        validate_non_empty(&drawer.embedding_model_id, "embeddingModelID")?;
        // I-22 + initial-field legality enforced by the gate on the
        // capture event (prior==None branch runs ForbiddenCombinations),
        // so the standalone validator is retired here as for the mutators.

        let predecessor = self.find_active_predecessor(&drawer.lineage_id, &drawer.id)?;
        match predecessor {
            Some(prior_id) => self.add_drawer_with_cascade(drawer, &prior_id),
            None => {
                // Gated capture: genesis event + projection row. Capture is
                // the moment of remembering — a gated write, not a bare INSERT.
                self.gated_capture(drawer, _now)
            }
        }
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
        Ok(rows.first().map(drawer_from_row))
    }

    fn drawers_in_wing(&self, wing: &str) -> Result<Vec<Drawer>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "wing"),
                        TypedValue::Text(wing.to_string()),
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
        Ok(rows.iter().map(drawer_from_row).collect())
    }

    fn drawers_in_wing_room(&self, wing: &str, room: &str) -> Result<Vec<Drawer>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "wing"),
                        TypedValue::Text(wing.to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(T_DRAWERS, "room"),
                        TypedValue::Text(room.to_string()),
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
        Ok(rows.iter().map(drawer_from_row).collect())
    }

    fn drawers_by_source(&self, source_file: &str) -> Result<Vec<Drawer>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
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
                    OrderClause::new(
                        Column::new(T_DRAWERS, "filedAt"),
                        OrderDirection::Ascending,
                    ),
                ],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(drawer_from_row).collect())
    }

    fn all_drawers(&self) -> Result<Vec<Drawer>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                None,
                &[OrderClause::new(
                    Column::new(T_DRAWERS, "filedAt"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        Ok(rows.iter().map(drawer_from_row).collect())
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
        let _ = reason;
        self.gated_column_write(drawer_id, audit_gate::Column::Provenance, new_provenance, changed_by, now)
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
        let _ = reason;
        // I-22 (secret+exportable) is enforced inside the gate's basis
        // check now (SubstrateLib), so no separate validator is needed.
        self.gated_column_write(drawer_id, audit_gate::Column::Adjective, new_adjective, changed_by, now)
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
        let _ = reason;
        self.gated_column_write(drawer_id, audit_gate::Column::Operational, new_operational, changed_by, now)
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

        let _ = (prior_operational, prior_provenance, prior_state, new_bitmap, reason);

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
            audit_gate::Column::Adjective, 0, 6, "state",
            &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33]);
        // One tick per logical mutation.
        let stamp = self.hlc.lock().unwrap().send(now);
        let event = audit_gate::admit(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            via,
            Some(prior),
            Some(anchor),
            &[audit_gate::FieldWrite { slot: state_slot, value: new_state.raw_value() }],
            anchor,
            &self.vocabulary,
            stamp,
            changed_by,
        ).map_err(|v| LocusKitError::InvalidContent(format!("state mutation rejected by gate: {:?}", v)))?;

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
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&event))
            .map_err(map_storage_err)?;
        Ok(())
    }

    fn expunge_gated(
        &self,
        drawer_id: &str,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        validate_non_empty(drawer_id, "drawerId")?;
        validate_non_empty(changed_by, "changedBy")?;

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
        // Expunge does not touch the lattice anchor; before == after.
        let udc = self.read_drawer_udc(drawer_id)?;
        let anchor = substrate_lib::verbs::LatticeAnchor::udc(&udc);

        // Two FieldWrites in one admit call.
        // 1) State slot: shift 0, width 6 → 33 (tombstoned).
        let state_slot = audit_gate::FieldSlot::with_values(
            audit_gate::Column::Adjective, 0, 6, "state",
            &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33]);
        // 2) Flags slot: shift 24, width 3 (F17.2 widening, commit
        //    5a8ea56). Bit 24 = state_extension; bit 25 =
        //    lineage_clustering; bit 26 = dreaming_recalc_required.
        //    Expunge sets bit 26 (the third bit of the 3-bit field,
        //    raw value 0b100) while preserving bits 24-25.
        let flags_slot = audit_gate::FieldSlot::new(
            audit_gate::Column::Adjective, 24, 3, "flags");
        let prior_flags_value = bit_field::extract_field(prior_bitmap, 24, 3);
        let new_flags_value = (prior_flags_value & 0b011) | 0b100;

        // One tick per logical mutation.
        let stamp = self.hlc.lock().unwrap().send(now);
        let event = audit_gate::admit(
            self.estate_uuid.as_u128(),
            substrate_lib::verbs::RowId(row_uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            RowVerb::Tombstone,
            Some(prior),
            Some(anchor),
            &[
                audit_gate::FieldWrite {
                    slot: state_slot,
                    value: State::Tombstoned.raw_value(),
                },
                audit_gate::FieldWrite {
                    slot: flags_slot,
                    value: new_flags_value,
                },
            ],
            anchor,
            &self.vocabulary,
            stamp,
            changed_by,
        ).map_err(|v| LocusKitError::InvalidContent(format!("expunge rejected by gate: {:?}", v)))?;

        // Materialized projection: write the merged adjective snapshot,
        // zero the content blob, stamp tombstonedAt — all in the same
        // transaction as the gated event append. Per cookbook §10.5:
        // "Content blob zeroized in the same transaction as the state
        // transition (atomic; verbatim sacred only up to expunge)."
        let row_store = self.storage.row_store();
        let mut update_vals = BTreeMap::new();
        update_vals.insert(
            "adjectiveBitmap".to_string(),
            TypedValue::Bitmap(event.after_bitmaps.0),
        );
        update_vals.insert(
            "content".to_string(),
            TypedValue::Text(String::new()),
        );
        // tombstonedAt is a Timestamp column (i64 millis since epoch);
        // opt_int_value_of accepts TypedValue::Timestamp. Writing as
        // TypedValue::Text would silently parse back to None.
        update_vals.insert(
            "tombstonedAt".to_string(),
            TypedValue::Timestamp(now),
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
        self.storage
            .audit_log()
            .append(pk_audit_event_from(&event))
            .map_err(map_storage_err)?;
        let _ = reason;   // reason is captured in audit verb context;
                          // no separate audit-row column today, but the
                          // parameter is retained for future ProvFrame
                          // composition (cookbook §10.5 names a `reason`
                          // arg on the verb signature).
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
        self.storage
            .row_store()
            .insert(T_TUNNELS, tunnel_values(tunnel))
            .map_err(map_storage_err)?;
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

    fn tunnels_from_wing_room(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<Tunnel>, LocusKitError> {
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

    fn kg_facts_for_drawer(
        &self,
        source_drawer_id: &str,
    ) -> Result<Vec<KGFact>, LocusKitError> {
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
                        TypedValue::Int(7),
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
        Ok(rows.iter().map(kg_fact_from_row).collect())
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

    fn proposals_for_target(
        &self,
        target_row_id: &str,
    ) -> Result<Vec<Proposal>, LocusKitError> {
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
        validate_non_empty(&association.lattice_anchor.udc_code, "latticeAnchor.udcCode")?;
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

    fn associations_from(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<Association>, LocusKitError> {
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

    fn associations_to(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<Association>, LocusKitError> {
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

    fn recall_trace_since(
        &self,
        since: &str,
    ) -> Result<Vec<RecallTraceItem>, LocusKitError> {
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

    fn mark_recall_trace_used(&self, id: &str, _now: i64) -> Result<(), LocusKitError> {
        let item = self
            .get_recall_trace(id)?
            .ok_or_else(|| LocusKitError::RecallTraceItemNotFound {
                id: id.to_string(),
            })?;
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



    // -----------------------------------------------------------------
    // Summary surface
    // -----------------------------------------------------------------

    fn list_wings(&self) -> Result<Vec<WingSummary>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_DRAWERS,
                Some(&StoragePredicate::IsNull(Column::new(
                    T_DRAWERS,
                    "tombstonedAt",
                ))),
                &[],
                None,
                None,
            )
            .map_err(map_storage_err)?;
        let mut drawer_counts: BTreeMap<String, i64> = BTreeMap::new();
        let mut rooms: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for row in &rows {
            let wing = string_value_of(row.get("wing"));
            let room = string_value_of(row.get("room"));
            *drawer_counts.entry(wing.clone()).or_insert(0) += 1;
            rooms.entry(wing).or_default().insert(room);
        }
        // BTreeMap iterates keys in sorted order — matches the Swift
        // `drawerCounts.keys.sorted()` shape.
        Ok(drawer_counts
            .iter()
            .map(|(wing, count)| WingSummary {
                name: wing.clone(),
                drawer_count: *count,
                room_count: rooms.get(wing).map(|s| s.len() as i64).unwrap_or(0),
            })
            .collect())
    }

    fn list_rooms(&self, wing: Option<&str>) -> Result<Vec<RoomSummary>, LocusKitError> {
        let predicate = match wing {
            Some(w) => StoragePredicate::all(vec![
                StoragePredicate::Eq(
                    Column::new(T_DRAWERS, "wing"),
                    TypedValue::Text(w.to_string()),
                ),
                StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
            ]),
            None => StoragePredicate::IsNull(Column::new(T_DRAWERS, "tombstonedAt")),
        };
        let rows = self
            .storage
            .row_store()
            .query(T_DRAWERS, Some(&predicate), &[], None, None)
            .map_err(map_storage_err)?;
        let mut counts: BTreeMap<(String, String), i64> = BTreeMap::new();
        for row in &rows {
            let w = string_value_of(row.get("wing"));
            let r = string_value_of(row.get("room"));
            *counts.entry((w, r)).or_insert(0) += 1;
        }
        Ok(counts
            .into_iter()
            .map(|((w, r), c)| RoomSummary {
                wing: w,
                name: r,
                drawer_count: c,
            })
            .collect())
    }
}

// ---------------------------------------------------------------------------
// Row encode helpers
// ---------------------------------------------------------------------------

fn drawer_values(d: &Drawer) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Text(d.id.clone()));
    m.insert("content".to_string(), TypedValue::Text(d.content.clone()));
    m.insert("wing".to_string(), TypedValue::Text(d.wing.clone()));
    m.insert("room".to_string(), TypedValue::Text(d.room.clone()));
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
        item.score.map(TypedValue::Float).unwrap_or(TypedValue::Null),
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

fn drawer_from_row(row: &StorageRow) -> Drawer {
    Drawer {
        id: string_value_of(row.get("id")),
        // Empty-string or unparseable lineageID becomes a fresh
        // per-row UUID so unset rows never collapse onto one
        // lineage; matches the Swift `drawerFromRow`.
        lineage_id: Uuid::parse_str(&string_value_of(row.get("lineageID")))
            .unwrap_or_else(|_| Uuid::new_v4()),
        content: string_value_of(row.get("content")),
        wing: string_value_of(row.get("wing")),
        room: string_value_of(row.get("room")),
        source_file: opt_string_value_of(row.get("sourceFile")),
        chunk_index: opt_int_value_of(row.get("chunkIndex")),
        added_by: string_value_of(row.get("addedBy")),
        filed_at: i64_value_of(row.get("filedAt")),
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
    }
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
    }
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
        recalled_at: string_value_of(row.get("recalledAt")),
        score: opt_float_value_of(row.get("score")),
        operational_bitmap: i64_value_of(row.get("operationalBitmap")),
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
        Some(TypedValue::Bool(b)) => {
            if *b {
                1
            } else {
                0
            }
        }
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
/// here. Field-for-field, ids as u128 → Uuid.
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
        actor: e.actor.clone(),
    }
}

/// Bridge a PersistenceKit flat AuditEvent (as read from the audit log)
/// back to the substrate verbs::AuditEvent the AuditLogFold consumes.
/// Inverse of `pk_audit_event_from`. Rust-only: Swift's PersistenceKit
/// reuses the substrate type, so no bridge is needed there. before_*
/// fields are all-or-nothing (a snapshot event either has a prior or is
/// the first event), mirrored here.
pub(crate) fn substrate_audit_event_from(e: &PkAuditEvent) -> substrate_lib::verbs::AuditEvent {
    let before = match (e.before_adjective, e.before_operational, e.before_provenance) {
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
        before_lattice_anchor: e.before_lattice_anchor
            .map(|a| substrate_lib::verbs::LatticeAnchor::new(a, 0)),
        after_lattice_anchor: substrate_lib::verbs::LatticeAnchor::new(e.after_lattice_anchor, 0),
        actor: e.actor.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State, Trust};
    use crate::estate::Estate;
    use crate::estate_types::OwnerCredentials;
    use persistence_kit::inmemory::InMemoryStorage;

    const NOW: i64 = 1_700_000_000;

    fn open_store() -> InMemoryDrawerStore {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        InMemoryDrawerStore::new(storage, NOW, None).unwrap()
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
        let mut d = Drawer::new(&resolved, content, wing, room, "alice", NOW, "test-v1");
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
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store_a = InMemoryDrawerStore::new(storage.clone(), NOW, None).unwrap();
        let uuid_a = store_a.read_manifest().unwrap().estate_uuid;
        // Second open must see the same estate_uuid.
        let store_b = InMemoryDrawerStore::new(storage, NOW + 1, None).unwrap();
        let uuid_b = store_b.read_manifest().unwrap().estate_uuid;
        assert_eq!(uuid_a, uuid_b);
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
        let manifest_uuid =
            Uuid::parse_str(&store.read_manifest().unwrap().estate_uuid).unwrap();
        let row = Uuid::parse_str(&tid("d1")).unwrap();
        let events = store.storage.audit_log().events_for_row(row).unwrap();
        assert!(!events.is_empty(), "capture must emit a genesis audit event");
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
        assert_eq!(back.wing, "w");
        assert_eq!(back.room, "kitchen");
    }

    #[test]
    fn add_drawer_rejects_empty_wing() {
        let store = open_store();
        let mut d = sample_drawer("d1", "", "kitchen", "hello");
        // Force the wing field empty by direct mutation.
        d.wing = String::new();
        let err = store.add_drawer(&d, NOW).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => assert!(msg.contains("wing")),
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
                assert!(msg.contains("I-22"), "expected I-22 gate rejection, got: {}", msg);
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }
        // The capture was rejected, so neither row nor audit event landed.
        assert!(store.get_drawer(&tid("d-bad")).unwrap().is_none());
    }

    #[test]
    fn drawers_in_wing_excludes_tombstoned_and_orders_by_filed_at() {
        let store = open_store();
        let mut d1 = sample_drawer("d1", "w", "k", "first");
        d1.filed_at = NOW + 10;
        let mut d2 = sample_drawer("d2", "w", "k", "second");
        d2.filed_at = NOW + 20;
        let mut d3 = sample_drawer("d3", "w", "k", "tombstoned");
        d3.filed_at = NOW + 30;
        d3.tombstoned_at = Some(NOW + 31);
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
        let d1 = sample_drawer("d1", "w", "k", "kitchen-row");
        let d2 = sample_drawer("d2", "w", "study", "study-row");
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
        store.add_drawer(&sample_drawer("a", "w", "k", "one"), NOW).unwrap();
        store.add_drawer(&sample_drawer("b", "w", "k", "two"), NOW).unwrap();
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

        // Predecessor state nibble flipped to Superseded (raw 16).
        let p_back = store.get_drawer("11111111-1111-4111-8111-111111111111").unwrap().unwrap();
        assert_eq!(p_back.adjective_bitmap & 0x3F, State::Superseded.raw_value());

        // The flip went through the gate → one audit event for the
        // predecessor with after-state superseded (bitmap_audit retired).
        let prow = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage.audit_log().events_for_row(prow).unwrap();
        assert_eq!(events.len(), 2); // predecessor's capture + the supersede flip
        assert_eq!(events[0].verb, "capture");
        assert_eq!(events[1].after_adjective & 0x3F, State::Superseded.raw_value());

        // Directional supersedes tunnel exists from new → prior.
        let tunnel = store
            .get_tunnel(&format!("supersedes:{}:{}", "22222222-2222-4222-8222-222222222222", "11111111-1111-4111-8111-111111111111"))
            .unwrap()
            .unwrap();
        assert_eq!(tunnel.kind, TunnelKind::Supersedes);
        assert_eq!(tunnel.source_drawer_id.as_deref(), Some("22222222-2222-4222-8222-222222222222"));
        assert_eq!(tunnel.target_drawer_id.as_deref(), Some("11111111-1111-4111-8111-111111111111"));
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
            .mutate_provenance("11111111-1111-4111-8111-111111111111", prov, "alice", Some("test"), NOW + 1)
            .unwrap();
        assert_eq!(store.get_drawer("11111111-1111-4111-8111-111111111111").unwrap().unwrap().provenance, prov);
        // Gate appended one event carrying the provenance write.
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage.audit_log().events_for_row(row).unwrap();
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
            .mutate_adjective("11111111-1111-4111-8111-111111111111", trust_canonical, "alice", Some("uplift"), NOW + 1)
            .unwrap();
        assert_eq!(
            store.get_drawer("11111111-1111-4111-8111-111111111111").unwrap().unwrap().adjective_bitmap,
            trust_canonical
        );
        // One audit event whose after-adjective carries the trust write
        // (the gate appended it; bitmap_audit is retired for this path).
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage.audit_log().events_for_row(row).unwrap();
        assert_eq!(events.len(), 2); // capture (genesis) + the adjective mutation
        assert_eq!(events[0].verb, "capture");
        assert_eq!((events[1].after_adjective >> 18) & 0x3F, Trust::Canonical.raw_value());
    }

    #[test]
    fn mutate_adjective_rejects_forbidden_combo() {
        let store = open_store();
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        let bad = (AdjectiveSensitivity::Secret.raw_value() << 6)
            | (AdjectiveExportability::Public.raw_value() << 12);
        let err = store.mutate_adjective("11111111-1111-4111-8111-111111111111", bad, "alice", None, NOW + 1).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                assert!(msg.contains("I-22"), "expected I-22 gate rejection, got: {}", msg);
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }
        // Drawer unchanged; the rejected mutation appended NO new event,
        // but the genesis capture event remains (it is the only event).
        assert_eq!(store.get_drawer("11111111-1111-4111-8111-111111111111").unwrap().unwrap().adjective_bitmap, 0);
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage.audit_log().events_for_row(row).unwrap();
        assert_eq!(events.len(), 1, "only the genesis capture event; the rejected mutation appended nothing");
        assert_eq!(events[0].verb, "capture");
    }

    #[test]
    fn mutate_operational_writes_audit() {
        let store = open_store();
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        store
            .mutate_operational("11111111-1111-4111-8111-111111111111", 0x100, "alice", None, NOW + 1)
            .unwrap();
        assert_eq!(
            store.get_drawer("11111111-1111-4111-8111-111111111111").unwrap().unwrap().operational_bitmap,
            0x100
        );
        // Gate appended one event carrying the operational write.
        let row = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let events = store.storage.audit_log().events_for_row(row).unwrap();
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
            .mutate_state("11111111-1111-4111-8111-111111111111", State::Contested, RowVerb::Contest, "alice", None, NOW + 1)
            .unwrap();
        let back = store.get_drawer("11111111-1111-4111-8111-111111111111").unwrap().unwrap();
        // Upper axes preserved, state flipped.
        assert_eq!(back.adjective_bitmap & 0x3F, State::Contested.raw_value());
        assert_eq!((back.adjective_bitmap >> 18) & 0x3F, Trust::Canonical.raw_value());
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
                assert!(msg.contains("IllegalTransition"),
                    "expected gate IllegalTransition, got: {}", msg);
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
                    "expected S-1 invariant violation via gate, got: {}", msg
                );
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }

        // Row state unchanged after rejected mutation.
        let back = store.get_drawer("11111111-1111-4111-8111-111111111111").unwrap().unwrap();
        assert_eq!(back.adjective_bitmap & 0x3F, State::Active.raw_value());
        assert_eq!((back.adjective_bitmap >> 18) & 0x3F, Trust::Observed.raw_value());
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

        let back = store.get_drawer("22222222-2222-4222-8222-222222222222").unwrap().unwrap();
        assert_eq!(back.adjective_bitmap & 0x3F, State::Accepted.raw_value());
        assert_eq!((back.adjective_bitmap >> 18) & 0x3F, Trust::Canonical.raw_value());
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
        let mut e1 = DiaryEntry {
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
        let err = store.mark_recall_trace_used("missing", NOW + 7).unwrap_err();
        match err {
            LocusKitError::RecallTraceItemNotFound { id } => assert_eq!(id, "missing"),
            other => panic!("expected RecallTraceItemNotFound, got {:?}", other),
        }
    }

    #[test]
    fn recall_trace_since_filters_and_orders_ascending() {
        let store = open_store();
        let early = RecallTraceItem::new(
            "early",
            "d-a",
            "2024-01-01T00:00:00.000Z",
            None,
            0,
        );
        let mid = RecallTraceItem::new(
            "mid",
            "d-b",
            "2024-06-01T00:00:00.000Z",
            None,
            0,
        );
        let late = RecallTraceItem::new(
            "late",
            "d-c",
            "2024-12-01T00:00:00.000Z",
            None,
            0,
        );
        store.insert_recall_trace(&early).unwrap();
        store.insert_recall_trace(&late).unwrap();
        store.insert_recall_trace(&mid).unwrap();
        let rows = store.recall_trace_since("2024-06-01T00:00:00.000Z").unwrap();
        let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, vec!["mid", "late"]);
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
        store.add_drawer(&sample_drawer("d1", "w1", "k", "a"), NOW).unwrap();
        store.add_drawer(&sample_drawer("d2", "w1", "study", "b"), NOW).unwrap();
        store.add_drawer(&sample_drawer("d3", "w2", "lab", "c"), NOW).unwrap();
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
        store.add_drawer(&sample_drawer("d1", "w1", "k", "a"), NOW).unwrap();
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
        let d = sample_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "w", "k", "content-aaaa");
        store.add_drawer(&d, NOW).unwrap();

        // Before: active, content non-empty, no tombstone, bit 26 clear.
        let before = store.get_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap().unwrap();
        assert_eq!(before.adjective_bitmap & 0x3F, State::Active.raw_value());
        assert_eq!(before.content, "content-aaaa");
        assert!(before.tombstoned_at.is_none());
        assert_eq!(before.adjective_bitmap & (1 << 26), 0);

        store
            .expunge_gated(
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "alice",
                Some("GDPR delete request 2026-05-29"),
                NOW + 500,
            )
            .unwrap();

        let after = store.get_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap().unwrap();
        assert_eq!(after.adjective_bitmap & 0x3F, State::Tombstoned.raw_value());
        assert_eq!(after.content, "");
        assert!(after.tombstoned_at.is_some());
        assert_ne!(after.adjective_bitmap & (1 << 26), 0,
            "dreaming_recalc_required (bit 26) must be set on tombstone via expunge");
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

        store
            .expunge_gated(
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "alice",
                None,
                NOW + 500,
            )
            .unwrap();
        let after = store.get_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap().unwrap();
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
            )
            .unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                assert!(msg.contains("IllegalTransition")
                        || msg.contains("illegalTransition")
                        || msg.contains("basisViolation"),
                    "expected gate rejection from S-3, got: {}", msg);
            }
            other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
        }

        // Row state must be unchanged; bit 26 must still be clear.
        let after = store.get_drawer("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb").unwrap().unwrap();
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
            )
            .unwrap_err();
        match err {
            LocusKitError::DrawerNotFound { .. } => {}
            other => panic!("expected DrawerNotFound, got {:?}", other),
        }
    }
}
