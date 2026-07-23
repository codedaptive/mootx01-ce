// hydration.rs — GLK-level hydrate-on-launch integration (Rust port).
//
// Wires `persistence_kit::replication::hydrate` into the EstateCoordinator
// startup sequence so an in-memory estate can be rebuilt from a durable
// (SQLite) backend on launch.
//
// HYDRATE SEQUENCE (authoritative, from REPLICATION_GROUND_TRUTH.md §7):
//
//   1. Schema open    — open both in_memory and durable with the composite
//                       GLK schema (LocusKit + VectorKit + CorpusKit + grants).
//                       This advances both storages to the composite version so
//                       the replication schema gate (global version check) passes.
//   2. Row snapshot   — replication::hydrate copies all schema-declared
//                       tables (including tombstones and append-only rows)
//                       verbatim from durable into in_memory.
//   3. Audit events   — replication::hydrate also copies _storagekit_audit
//                       events via the AuditLog protocol path.
//   4. Estate open    — InMemoryDrawerStore::with_storage opens the LocusKit
//                       schema on the already-populated in_memory storage (the
//                       open() call is a no-op because the LocusKit per-kit
//                       schema version is below the already-applied composite
//                       version). Estate::open reads the manifest that was
//                       copied in step 2.
//   5. Audit log feed — walk all drawers in the estate; for each drawer call
//                       estate.audit_trail(id) and bridge each
//                       substrate_types::AuditEvent → [UnifiedAuditEntry].
//   5b. Synthetic feed — RUST-AUDIT-DURABILITY (2026-07-09): read
//                       `_storagekit_audit` directly for the six grant-
//                       lifecycle / sensitivity-unlock synthetic verbs. Five
//                       of the six are keyed on a synthetic id (a grant or
//                       denial id, not a drawer id), so step 5's per-drawer
//                       walk cannot reach them — this step recovers them.
//                       Idempotent union with step 5's result via the G-Set.
//   6. Matrix rebuild — MatrixTier::full_rebuild(log) runs both passes:
//                         Pass 1 (rebuild)          → F, O, C, live_row_count
//                         Pass 2 (rebuild_temporal) → T, temporal_watermark_hlc
//                       Both MUST run for temporal state to be populated.
//
// WHY rows-then-Estate-open ordering: Estate::open reads the manifest from
// storage to derive the estate UUID and zoom window. If open runs before
// the row-snapshot is present, the manifest is absent and open fails.
//
// Schema gate note: the Rust replication::replicate_full checks the GLOBAL
// current_schema_version() on both backends (not per-kit). The composite
// GLK schema is opened on BOTH sides so MAX(versions) matches on
// both, satisfying the gate. Because the composite version is the SUM of the
// component versions it is always >= every component's per-kit version, so
// opening the composite always advances the global counter to the composite version.
//
// Reference: REPLICATION_GROUND_TRUTH.md §Required hydrate ordering,
//            REPLICATION_TRACK_PLAN.md §3 GLK estate-level hydrate integration.

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

use std::sync::Arc;

use locus_kit::{
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate::Estate,
    estate_types::OwnerCredentials,
    error::LocusKitError,
};
use persistence_kit::{
    inmemory::InMemoryStorage,
    replication,
    replication::{ReplicationCursor, ReplicationError},
    schema::SchemaDeclaration,
    storage::Storage,
};
use crate::audit::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb,
};
use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::grants::GrantStore;
use crate::handle::EstateHandle;
use crate::matrix::{MatrixTier, MatrixSnapshotStore};
use uuid::Uuid;

// MARK: - Composite GLK SchemaDeclaration

/// The explicit composite SchemaDeclaration for a GeniusLocus estate.
///
/// Mirrors `GeniusLocusKitSchema.estateSchemaDeclaration` in Swift.
///
/// A GeniusLocus estate is a composition of three kits plus GLK-owned tables.
/// The composite schema aggregates all user-visible tables and uses the SUM of
/// the component versions plus two GLK-owned addends:
///   +1 grants         — security-sensitive estate authorization state
///   +1 matrix_snapshot — matrix tier calibration persistence
/// (BasisStore is the separate "CorpusKitBasis" kit-ID schema, not part of
/// this composite, so its version is not summed.) The version is computed
/// from the live component declarations below, so a future component bump
/// self-corrects the composite without a hand-edited literal — matching
/// Swift's sum convention.
///
/// IMPORTANT: matrix_snapshot MUST be in this composite so replication::hydrate
/// copies it from the durable SQLite backend into the in-memory backend before
/// rebuild_derived_accelerators runs. Without it, hydrated estates silently
/// cold-rebuild the matrix tier, discarding persisted calibration state.
///
/// The composite schema is opened on both source and destination storages
/// before calling `replication::hydrate` or `replication::flush` so the
/// replication gate (which checks the global current_schema_version against
/// schema.version) sees the same composite version on both sides.
///
/// # Version rationale
///
/// The Rust replication primitive checks the global schema version, not a
/// per-kit version like Swift. Opening the composite schema advances the
/// global version to max(existing, composite). Because the composite is the
/// SUM of the component versions it is always >= every component version,
/// so opening it writes exactly the composite version to the migrations table
/// without touching existing data tables (CREATE TABLE IF NOT EXISTS). For
/// fresh in-memory storages it creates all component tables plus the GLK-owned
/// tables at once.
pub fn composite_schema() -> SchemaDeclaration {
    let lk = locus_kit::schema::schema();
    let vk = vectorkit::VectorStore::schema_declaration();
    let ck = corpus_kit::BundleStore::schema_declaration();

    // Composite version = sum of the three GLK-composed component versions
    // plus two GLK-owned addends:
    //   +1 grants        — security-sensitive estate authorization state
    //   +1 matrix_snapshot — matrix tier calibration persistence
    //
    // IMPORTANT: matrix_snapshot MUST be in this composite so replication::hydrate
    // copies it from the durable SQLite backend into the in-memory backend before
    // rebuild_derived_accelerators runs. Without it, hydrated estates always
    // cold-rebuild the matrix tier, discarding persisted calibration state.
    //
    // Mirrors Swift `GeniusLocusKitSchema.version` (= 18).
    let grants_schema_version = 1;
    let matrix_snapshot_schema_version = MatrixSnapshotStore::schema_declaration().version;
    let composite_version = lk.version + vk.version + ck.version
        + grants_schema_version
        + matrix_snapshot_schema_version;

    let mx_snapshot = MatrixSnapshotStore::schema_declaration();

    let mut tables = Vec::new();
    tables.extend(lk.tables);
    tables.extend(vk.tables);
    tables.extend(ck.tables);
    tables.push(GrantStore::grants_table());
    // matrix_snapshot: must be last so version ordering matches Swift composite.
    tables.extend(mx_snapshot.tables);

    let mut indices = Vec::new();
    indices.extend(lk.indices);
    indices.extend(vk.indices);
    indices.extend(ck.indices);

    SchemaDeclaration {
        kit_id: "GeniusLocusKit".to_string(),
        // LocusKit v9 + VectorKit v4 + CorpusKit v3 + Grants v1 + MatrixSnapshot v1 = 18
        version: composite_version,
        tables,
        indices,
        // No cross-kit migrations at the composite level — each component kit
        // manages its own schema evolution. The composite version is derived
        // from the component versions above plus the two GLK-owned addends,
        // so a component bump self-corrects the composite.
        migrations: vec![],
    }
}

#[cfg(test)]
mod composite_version_tests {
    use super::*;

    /// The composite version is the SUM of the three GLK-composed component
    /// versions plus two GLK-owned addends: grants (+1) and matrix_snapshot (+1).
    /// LocusKit v9 + VectorKit v4 + CorpusKit/BundleStore v3 + Grants v1
    ///   + MatrixSnapshot v1 = 18.
    /// VectorKit bumped to v4 when idx_vectors_filed_at_item was added
    /// (VK-PERF-FIX-2026-07-13). This guards the coupling the global-MAX
    /// replication gate depends on: a drift between composite and components
    /// would let a fresh estate open at a version the gate rejects.
    /// Mirrors Swift `CompositeSchemaVersionTests`.
    #[test]
    fn composite_version_equals_component_sum() {
        let lk = locus_kit::schema::SCHEMA_VERSION;
        let vk = vectorkit::VectorStore::schema_declaration().version;
        let ck = corpus_kit::BundleStore::schema_declaration().version;
        let mx = MatrixSnapshotStore::schema_declaration().version;
        let s = composite_schema();
        // Two GLK-owned addends: +1 grants, +matrix_snapshot version
        // LocusKit v10 (FINDING-3 associations unique constraint) +
        // VectorKit v4 + CorpusKit v3 + Grants v1 + MatrixSnapshot v1 = 19.
        assert_eq!(s.version, lk + vk + ck + 1 + mx);
        assert_eq!(s.version, 19);
        assert!(s.tables.iter().any(|t| t.name == "grants"));
        // matrix_snapshot must be in composite for hydration to copy it from durable storage
        assert!(s.tables.iter().any(|t| t.name == "matrix_snapshot"));
        assert_eq!(s.kit_id, "GeniusLocusKit");
    }
}

#[cfg(test)]
mod audit_bridge_anchor_tests {
    // Lattice-anchor bridging for the diffusion zone series (node motion modeling
    // §5, Option 3a). Mirrors Swift AuditBridgeTests.
    use super::*;
    use substrate_types::audit_event::AuditEvent;
    use substrate_types::hlc::HLC;
    use substrate_types::lattice_anchor::LatticeAnchor;
    use substrate_types::row::RowId;

    fn event(verb: &str, before: Option<LatticeAnchor>, after: LatticeAnchor) -> AuditEvent {
        AuditEvent {
            event_id: 1,
            estate_uuid: 1,
            row_id: RowId(1),
            hlc: HLC { physical_time: 100, logical_count: 0, node_id: 1 },
            verb: verb.to_string(),
            before_bitmaps: if verb == "capture" { None } else { Some((0, 0, 0)) },
            after_bitmaps: (0, 0, 0),
            before_lattice_anchor: before,
            after_lattice_anchor: after,
            actor: "capture".to_string(),
            reason: None,
        }
    }

    fn code(s: &str) -> i64 {
        LatticeAnchor::udc(s).udc_code as i64
    }

    #[test]
    fn capture_emits_anchor() {
        let entries = bridge_audit_event(&event("capture", None, LatticeAnchor::udc("530")));
        let anchors: Vec<_> = entries.iter().filter(|e| e.field_path == "latticeAnchor").collect();
        assert_eq!(anchors.len(), 1);
        assert_eq!(anchors[0].before_value, UnifiedAuditValue::Null);
        assert_eq!(anchors[0].after_value, UnifiedAuditValue::Integer(code("530")));
    }

    #[test]
    fn reanchor_emits_before_after() {
        let entries = bridge_audit_event(&event(
            "reanchor",
            Some(LatticeAnchor::udc("530")),
            LatticeAnchor::udc("004"),
        ));
        let anchors: Vec<_> = entries.iter().filter(|e| e.field_path == "latticeAnchor").collect();
        assert_eq!(anchors.len(), 1);
        assert_eq!(anchors[0].before_value, UnifiedAuditValue::Integer(code("530")));
        assert_eq!(anchors[0].after_value, UnifiedAuditValue::Integer(code("004")));
    }

    #[test]
    fn unchanged_anchor_emits_nothing() {
        let entries = bridge_audit_event(&event(
            "mutate",
            Some(LatticeAnchor::udc("530")),
            LatticeAnchor::udc("530"),
        ));
        assert!(entries.iter().all(|e| e.field_path != "latticeAnchor"));
    }
}

// MARK: - Flush convenience

/// Flush an in-memory storage into a durable storage.
///
/// Opens both backends with the composite GLK schema before calling
/// `replication::flush` so the schema gate passes. For the in-memory backend
/// this is idempotent if it was already opened at the composite version. For
/// the durable backend (SQLite) this writes the composite version to the
/// migrations table without altering existing data tables.
///
/// Mirrors `GeniusLocusKit.flush(from:into:)` in Swift.
pub fn flush(
    in_memory: &dyn Storage,
    durable: &dyn Storage,
) -> Result<ReplicationCursor, ReplicationError> {
    let schema = composite_schema();
    // Open both sides with composite schema so gate passes on both.
    in_memory
        .open(&schema)
        .map_err(|e| ReplicationError::StorageFailure { detail: e.to_string() })?;
    durable
        .open(&schema)
        .map_err(|e| ReplicationError::StorageFailure { detail: e.to_string() })?;
    replication::flush(in_memory, durable, &schema)
}

// MARK: - Simplified hydration entry point

/// Result of a hydration: the Estate, its UnifiedAuditLog, and its MatrixTier.
pub struct HydratedEstate {
    pub estate: Estate,
    pub unified_log: UnifiedAuditLog,
    pub matrix_tier: MatrixTier,
    /// The in-memory storage the hydrated estate runs on. Retained so the
    /// coordinator can register it in `storages[handle]` exactly as `coord.open`
    /// does — `Estate::open` moves the `DrawerStore` Arc, so this is the only
    /// surviving handle to the backing storage after open.
    pub storage: Arc<dyn Storage>,
}

/// Hydrate a fresh in-memory estate from a durable storage, returning the
/// opened `HydratedEstate`.
///
/// Performs the full six-step hydrate sequence:
///   1. Schema open (composite GLK schema on both sides)
///   2. Row snapshot + audit events via `replication::hydrate`
///   3. Estate open over the populated in-memory storage
///   4. Audit-log feed (all_drawers → audit_trail → bridge → UnifiedAuditLog)
///   5. MatrixTier::full_rebuild (both passes: F/O/C + T)
///
/// # Arguments
///
/// - `in_memory`: A freshly-created `InMemoryStorage` (not yet opened).
/// - `durable`:   An already-open durable storage (SQLite or equivalent).
/// - `owner`:     Owner credentials forwarded to `Estate::open`.
/// - `now`:       Monotonic timestamp (Unix seconds) for the `InMemoryDrawerStore`.
///
/// # Errors
///
/// - `HydrateError::Replication` if the schema gate fails or a storage error occurs.
/// - `HydrateError::Estate` if `Estate::open` fails.
/// - `HydrateError::AuditFeed` if audit-trail reading fails.
pub fn open_hydrating(
    in_memory: Arc<InMemoryStorage>,
    durable: &dyn Storage,
    owner: OwnerCredentials,
    now: i64,
) -> Result<HydratedEstate, HydrateError> {
    let schema = composite_schema();

    // Step 1 — Schema gate: register GLK composite version on both backends.
    in_memory
        .open(&schema)
        .map_err(|e| HydrateError::Replication(format!("{e:?}")))?;
    durable
        .open(&schema)
        .map_err(|e| HydrateError::Replication(format!("{e:?}")))?;

    // Step 2 + 3 — Row snapshot + audit events from durable into in_memory.
    replication::hydrate(in_memory.as_ref(), durable, &schema)
        .map_err(|e| HydrateError::Replication(format!("{e:?}")))?;

    // Step 4 — Open DrawerStore and Estate over the populated in_memory.
    // DrawerStoreCore::new calls storage.open(locus_schema) — a no-op: the
    // LocusKit per-kit version is below the already-applied composite version
    // (the storage was advanced to the composite version in step 1), so the
    // open does not re-create or downgrade anything.
    // Retain a handle to the backing storage before it is moved into the
    // DrawerStore — `Estate::open` consumes the DrawerStore Arc, so this clone is
    // the only surviving reference, and it is what the coordinator registers in
    // `storages[handle]` (parity with `coord.open`'s `store.storage()` capture).
    let storage: Arc<dyn Storage> = in_memory.clone();
    let store = InMemoryDrawerStore::with_storage(in_memory, now, None)
        .map_err(|e| HydrateError::Estate(format!("{e:?}")))?;
    let store_arc: Arc<dyn DrawerStore> = Arc::new(store);
    let estate = Estate::open(store_arc, owner)
        .map_err(|e| HydrateError::Estate(format!("{e:?}")))?;

    // Step 5 — Audit log feed: walk all drawers and convert their audit trail
    // into UnifiedAuditEntry items. Bridge converts the substrate-level bitmap
    // snapshots into the GLK-level field-path entries required by MatrixTier.
    let mut unified_log = feed_audit_log_from_estate(&estate)
        .map_err(|e| HydrateError::AuditFeed(format!("{e:?}")))?;

    // Step 5b — Synthetic audit feed (RUST-AUDIT-DURABILITY): recover
    // grant-lifecycle and sensitivity-unlock entries directly from
    // `_storagekit_audit`. Five of the six synthetic verbs have no drawer
    // backing them, so the per-drawer walk above cannot reach them —
    // without this step a durably-written grant/sensitivity entry is
    // silently dropped on every hydrate, exactly reproducing the bug this
    // mission fixes. Reads from `storage` (the retained clone of the
    // now-hydrated `in_memory` backend), so this sees rows
    // `replication::hydrate` already copied from `durable` in step 2.
    feed_synthetic_audit_entries(storage.as_ref(), &mut unified_log)
        .map_err(|e| HydrateError::AuditFeed(format!("{e:?}")))?;

    // Step 6 — Matrix rebuild (full: both passes). Build the event_time map
    // (row_id → authored-in-world epoch ms) so the temporal (T) pass keys off
    // event_time, not the capture HLC — authored event time. event_time and the fold's
    // physical_time are both epoch-ms, so it flows through directly.
    // The row_id key mirrors bridge_audit_event's `EntryUUID(row_uuid.to_be_bytes())`.
    let event_times: std::collections::HashMap<EntryUUID, i64> = estate
        .all_drawers()
        .map_err(|e| HydrateError::AuditFeed(format!("{e:?}")))?
        .iter()
        .filter_map(|d| {
            uuid::Uuid::parse_str(&d.id)
                .ok()
                .map(|u| (EntryUUID(u.as_u128().to_be_bytes()), d.event_time))
        })
        .collect();
    let matrix_tier = MatrixTier::full_rebuild(&unified_log, &event_times);

    Ok(HydratedEstate { estate, unified_log, matrix_tier, storage })
}

// MARK: - EstateCoordinator extension

impl EstateCoordinator {
    /// Open a hydrated estate and admit it into the registry.
    ///
    /// Mirrors `GeniusLocusKit.open(inMemory:owner:hydrateFrom:)` in Swift.
    ///
    /// Performs the full six-step hydrate sequence (see module-level comment),
    /// then registers the opened estate under a fresh `EstateHandle` and
    /// stores the rebuilt `MatrixTier` in the coordinator's matrix map.
    ///
    /// # Arguments
    ///
    /// - `in_memory`:         Fresh `InMemoryStorage`. Not yet opened.
    /// - `durable`:           Already-open durable storage (SQLite or equivalent).
    /// - `owner`:             Owner credentials forwarded to `Estate::open`.
    /// - `zoom_window_low`:   Zoom window lower bound (forwarded to `EstateHandle`).
    /// - `zoom_window_high`:  Zoom window upper bound.
    /// - `now`:               Monotonic timestamp (Unix seconds) for HLC generator.
    ///
    /// # Errors
    ///
    /// - `HydrateError::Replication` — schema gate failed or storage error.
    /// - `HydrateError::Estate`      — Estate::open failed.
    /// - `HydrateError::AuditFeed`   — audit trail reading failed.
    /// - `HydrateError::Coordinator` — estate UUID already registered (duplicate).
    pub fn open_hydrating(
        &mut self,
        in_memory: Arc<InMemoryStorage>,
        durable: &dyn Storage,
        owner: OwnerCredentials,
        zoom_window_low: i64,
        zoom_window_high: i64,
        now: i64,
    ) -> Result<(EstateHandle, UnifiedAuditLog, MatrixTier), HydrateError> {
        let hydrated = open_hydrating(in_memory, durable, owner.clone(), now)?;

        // Register the estate with the coordinator using the existing `open` path.
        // We need an Arc<dyn DrawerStore> for the estate. Since `open` takes a
        // DrawerStore and `open_hydrating` already constructed and opened an
        // Estate internally, we can't easily re-use the same DrawerStore.
        //
        // Resolution: `EstateCoordinator::open` takes `Arc<dyn DrawerStore>` and
        // calls `Estate::open` internally, but we already have a fully-opened
        // `Estate`. We need to register it directly.
        //
        // The coordinator's registry takes an Estate directly (it's a HashMap).
        // We use `open_estate_directly` which bypasses the DrawerStore layer.
        let handle = self
            .open_estate_directly(
                hydrated.estate,
                Arc::clone(&hydrated.storage),
                zoom_window_low,
                zoom_window_high,
            )
            .map_err(|e| HydrateError::Coordinator(format!("{e:?}")))?;

        // Install the rebuilt audit log and matrix tier on the coordinator so a
        // hydrated estate's `current_audit_log` reads the replayed history and
        // the matrixAware recall lane is live from the first recall — parity
        // with the Swift hydration path's `rebuildDerivedAccelerators` install.
        self.set_audit_log(&handle, hydrated.unified_log.clone());
        self.register_matrix_tier(&handle, hydrated.matrix_tier.clone());

        Ok((handle, hydrated.unified_log, hydrated.matrix_tier))
    }
}

// MARK: - Internal helper: open_estate_directly

impl EstateCoordinator {
    /// Register an already-opened `Estate` (and its backing storage) with the
    /// coordinator.
    ///
    /// Used by `open_hydrating` to admit a hydrated estate without going
    /// through the DrawerStore + Estate::open path a second time.
    ///
    /// Parity note: in Swift, `GeniusLocusKit.open(storage:owner:)` calls
    /// `Estate.open` and then registers BOTH the estate and `storages[handle]`.
    /// In Rust, `Estate::open` consumes the DrawerStore Arc, so this path cannot
    /// recover the storage from the estate; the caller passes the storage handle
    /// it retained before open. Registering it in `storages[handle]` is required
    /// so the matrix snapshot store (and any other storage-keyed accelerator)
    /// reaches the hydrated estate's backing storage — without it, a hydrated
    /// estate would silently fall back to a from-scratch matrix rebuild on every
    /// dream instead of the load-and-fold-forward path.
    pub fn open_estate_directly(
        &mut self,
        estate: Estate,
        storage: Arc<dyn Storage>,
        zoom_window_low: i64,
        zoom_window_high: i64,
    ) -> Result<EstateHandle, GeniusLocusKitError> {
        use crate::handle::EstateUuid;
        let estate_uuid: EstateUuid = estate.estate_uuid().into_bytes();
        let handle = EstateHandle::new(estate_uuid, zoom_window_low, zoom_window_high)
            .map_err(|_| GeniusLocusKitError::InvalidManifest {
                key: "estate_uuid".to_string(),
                detail: "could not construct EstateHandle from hydrated estate UUID".to_string(),
            })?;
        if self.registry().contains_key(&handle) {
            return Err(GeniusLocusKitError::DuplicateEstate { estate_uuid });
        }
        self.register_estate(handle, estate);
        // Retain the backing storage exactly as `coord.open` does, so every
        // storage-keyed accelerator resolves for a hydrated estate too.
        // The same hydrated storage also backs GrantStore so copied grant
        // issuance/revocation rows are the authorization source immediately.
        let grant_store = GrantStore::new(Arc::clone(&storage))
            .map_err(|e| GeniusLocusKitError::InvalidManifest {
                key: "grants".to_string(),
                detail: format!("could not open hydrated grant store: {e:?}"),
            })?;
        self.set_grant_store(handle, grant_store);
        self.storages.insert(handle, storage);
        Ok(handle)
    }
}

// MARK: - Synthetic (non-drawer) audit entries — RUST-AUDIT-DURABILITY
//
// Mirror of Swift `SyntheticAuditValueCodec` and `AuditBridge`'s synthetic-
// verb path (AuditBridge.swift). Grant-lifecycle (`GrantIssued`/
// `GrantRevoked`) and sensitivity-unlock (`SensitivityGrantIssued`/
// `SensitivityGrantDenied`/`SensitivityGrantRevoked`/
// `SensitivityReadUnderGrant`) events are not drawer mutations — they have
// no `adjective`/`operational`/`provenance` bitmap columns to diff. Both
// the durable-write side (`EstateCoordinator::append_sensitivity_audit_entry`,
// `append_grant_audit_entry` in coordinator.rs) and this read-back side
// repurpose the event's bitmap slots as a `(kind, payload)` pair instead of
// real column state: `adjective` carries the payload, `provenance` carries
// the type discriminant, `operational` is always 0/unused.

/// The six verbs that describe a grant-lifecycle or sensitivity-unlock
/// event rather than a drawer mutation. Mirrors Swift `AuditBridge.syntheticVerbs`.
pub(crate) fn is_synthetic_verb(verb: UnifiedAuditVerb) -> bool {
    matches!(
        verb,
        UnifiedAuditVerb::GrantIssued
            | UnifiedAuditVerb::GrantRevoked
            | UnifiedAuditVerb::SensitivityGrantIssued
            | UnifiedAuditVerb::SensitivityGrantDenied
            | UnifiedAuditVerb::SensitivityGrantRevoked
            | UnifiedAuditVerb::SensitivityReadUnderGrant
    )
}

/// Encodes a `UnifiedAuditValue` into the `(kind, payload)` i64 pair carried
/// in a synthetic (grant-lifecycle / sensitivity-unlock) audit event's
/// bitmap slot, and decodes it back. Mirrors Swift `SyntheticAuditValueCodec`
/// (AuditBridge.swift) byte-for-byte: `.null` -> `(0, 0)`, `.bitmap(v)` ->
/// `(1, v as i64)`, `.integer(v)` -> `(2, v)`. Only these three cases are
/// ever constructed by a synthetic append call site (grant active-bit
/// transitions and sensitivity expiry epoch-ms timestamps); `StringValue`/
/// `Bytes` cannot fit an i64 slot and degrade to `.null` on encode, matching
/// Swift's `assertionFailure` + null-degrade path.
pub(crate) struct SyntheticAuditValueCodec;

impl SyntheticAuditValueCodec {
    pub(crate) fn encode(value: &UnifiedAuditValue) -> (i64, i64) {
        match value {
            UnifiedAuditValue::Null => (0, 0),
            UnifiedAuditValue::Bitmap(v) => (1, *v as i64),
            UnifiedAuditValue::Integer(v) => (2, *v),
            UnifiedAuditValue::StringValue(_) | UnifiedAuditValue::Bytes(_) => {
                debug_assert!(
                    false,
                    "SyntheticAuditValueCodec: StringValue/Bytes cannot be encoded into a synthetic audit event's i64 slot"
                );
                (0, 0)
            }
        }
    }

    pub(crate) fn decode(kind: i64, payload: i64) -> UnifiedAuditValue {
        match kind {
            1 => UnifiedAuditValue::Bitmap(payload as u64),
            2 => UnifiedAuditValue::Integer(payload),
            _ => UnifiedAuditValue::Null,
        }
    }
}

/// Build the single `UnifiedAuditEntry` a synthetic (grant/sensitivity)
/// `substrate_types::AuditEvent` represents — the per-drawer-walk path
/// (`bridge_audit_event`, below). Reached only for `SensitivityReadUnderGrant`
/// in practice (the only synthetic verb whose `row_id` is a real drawer id,
/// so it is the only one a per-drawer `audit_trail` walk can surface); the
/// other five synthetic verbs use a non-drawer synthetic id and are instead
/// recovered by `feed_synthetic_audit_entries` (below), which reads
/// `_storagekit_audit` directly. Mirrors Swift
/// `AuditBridge.syntheticEntry(for:verb:)`.
fn synthetic_entry_from_substrate_event(
    event: &substrate_types::audit_event::AuditEvent,
    verb: UnifiedAuditVerb,
) -> UnifiedAuditEntry {
    let row_uuid: u128 = event.row_id.0;
    let entry_uuid = EntryUUID(row_uuid.to_be_bytes());
    let before = match event.before_bitmaps {
        Some((adjective, _operational, provenance)) => {
            SyntheticAuditValueCodec::decode(provenance, adjective)
        }
        None => UnifiedAuditValue::Null,
    };
    let (after_adj, _after_op, after_prov) = event.after_bitmaps;
    let after = SyntheticAuditValueCodec::decode(after_prov, after_adj);
    UnifiedAuditEntry::new(
        AuditTier::Locus,
        event.hlc,
        verb,
        entry_uuid,
        event.reason.clone().unwrap_or_default(),
        before,
        after,
        None,
    )
}

/// Same decode as `synthetic_entry_from_substrate_event`, but reading
/// directly off a durably-stored `persistence_kit::audit_log::AuditEvent`
/// (the flat `_storagekit_audit` row shape) rather than the LocusKit
/// per-drawer substrate `AuditEvent`. Used by `feed_synthetic_audit_entries`,
/// which bypasses the per-drawer walk entirely (there is no drawer to walk
/// from for a grant id or a denial's synthetic id).
fn synthetic_entry_from_pk_event(
    event: &persistence_kit::audit_log::AuditEvent,
    verb: UnifiedAuditVerb,
) -> UnifiedAuditEntry {
    let entry_uuid = EntryUUID(event.row_id.as_u128().to_be_bytes());
    let before = match (event.before_adjective, event.before_provenance) {
        (Some(payload), Some(kind)) => SyntheticAuditValueCodec::decode(kind, payload),
        _ => UnifiedAuditValue::Null,
    };
    let after = SyntheticAuditValueCodec::decode(event.after_provenance, event.after_adjective);
    UnifiedAuditEntry::new(
        AuditTier::Locus,
        event.hlc,
        verb,
        entry_uuid,
        event.reason.clone().unwrap_or_default(),
        before,
        after,
        None,
    )
}

/// Recover grant-lifecycle and sensitivity-unlock audit entries directly
/// from durable storage, bypassing the per-drawer walk.
///
/// `feed_audit_log_from_estate` (below) walks `estate.all_drawers()` and
/// pulls each drawer's `audit_trail` — but five of the six synthetic verbs
/// (`GrantIssued`/`GrantRevoked`/`SensitivityGrantIssued`/
/// `SensitivityGrantDenied`/`SensitivityGrantRevoked`) are keyed on a
/// synthetic grant/denial id, not any drawer's row id, so no per-drawer
/// walk can ever reach them — they would be silently dropped on every
/// hydrate. This reads `_storagekit_audit` directly (bounded, mirroring
/// Swift `auditLog(for:)`'s 50_000-row safety cap) and decodes only the
/// synthetic-verb rows into `log`. Idempotent: `UnifiedAuditLog::add` is
/// content-addressed, so an entry already fed by the per-drawer walk
/// (`SensitivityReadUnderGrant`, whose row_id IS a real drawer id) is a
/// G-Set no-op here, not a duplicate.
///
/// NOTE: this is deliberately narrower than the "full fix (direct
/// `AuditLog::iterate` bypassing per-drawer)" `current_audit_log`'s doc
/// comment defers to v1.1 — that full fix would replace the per-drawer walk
/// for ALL verbs (a broader performance/architecture change). This only
/// covers the six verbs the per-drawer walk structurally cannot reach.
pub(crate) fn feed_synthetic_audit_entries(
    storage: &dyn Storage,
    log: &mut UnifiedAuditLog,
) -> persistence_kit::error::StorageResult<()> {
    // Paginate with an HLC cursor. `iterate` returns HLC-ascending and
    // enforces the page limit, so a single fixed iterate(None, None, 50_000)
    // silently dropped every synthetic grant/sensitivity audit row past the
    // first 50k — a local client with many ordinary audited mutations could
    // push security-relevant records past the cap. Loop until a short page
    // signals the end, advancing the cursor past the last HLC each round.
    const PAGE: usize = 10_000;
    let mut after: Option<substrate_types::hlc::HLC> = None;
    loop {
        let page = storage.audit_log().iterate(after, None, PAGE)?;
        if page.is_empty() {
            break;
        }
        for event in &page {
            let verb = verb_from_str(&event.verb);
            if is_synthetic_verb(verb) {
                log.add(synthetic_entry_from_pk_event(event, verb));
            }
        }
        if page.len() < PAGE {
            break;
        }
        after = page.last().map(|e| e.hlc);
    }
    Ok(())
}

/// Durably append one synthetic (grant-lifecycle / sensitivity-unlock)
/// audit event through `storage.audit_log()` — the same `_storagekit_audit`
/// seam `appendAuditEvent` writes to on the Swift port (SQLiteStorage.swift)
/// and `replication::hydrate`/`feed_synthetic_audit_entries` (above) read
/// back from. Mirrors Swift `appendSensitivityAuditEntry`
/// (SensitivityAuditVerbs.swift) / `appendGrantAuditEntry`
/// (VerbSurface.swift): `before`/`after` are encoded via
/// `SyntheticAuditValueCodec` into the event's `adjective` (payload) and
/// `provenance` (kind) columns; `operational` is always 0/unused;
/// `field_path` rides in `reason`; the lattice-anchor columns are the
/// synthetic zero-anchor (`SubstrateTypes.LatticeAnchor(udcCode: 0,
/// qidPointer: 0)` on Swift). `event_id` is a fresh random UUID per call —
/// `AuditEvent.eventID` is generated at construction on both ports and
/// never reused, so the `(event_id, hlc)` idempotency key in
/// `_storagekit_audit` cannot collide two distinct synthetic writes.
#[allow(clippy::too_many_arguments)]
pub(crate) fn write_synthetic_audit_event(
    storage: &dyn Storage,
    estate_uuid: Uuid,
    row_id: Uuid,
    verb: UnifiedAuditVerb,
    field_path: &str,
    before_value: &UnifiedAuditValue,
    after_value: &UnifiedAuditValue,
    now_ms: i64,
    actor: &str,
) -> persistence_kit::error::StorageResult<()> {
    let (before_kind, before_payload) = SyntheticAuditValueCodec::encode(before_value);
    let (after_kind, after_payload) = SyntheticAuditValueCodec::encode(after_value);
    let event = persistence_kit::audit_log::AuditEvent {
        event_id: Uuid::new_v4(),
        estate_uuid,
        row_id,
        hlc: substrate_types::hlc::HLC {
            physical_time: now_ms,
            logical_count: 0,
            node_id: 0,
        },
        verb: verb.raw_value().to_string(),
        before_adjective: Some(before_payload),
        before_operational: Some(0),
        before_provenance: Some(before_kind),
        after_adjective: after_payload,
        after_operational: 0,
        after_provenance: after_kind,
        before_lattice_anchor: None,
        after_lattice_anchor: 0,
        before_lattice_qid: None,
        after_lattice_qid: 0,
        actor: actor.to_string(),
        reason: Some(field_path.to_string()),
    };
    storage.audit_log().append(event)
}

// MARK: - Audit bridge (AuditEvent → [UnifiedAuditEntry])

/// Convert one `substrate_types::AuditEvent` into the `UnifiedAuditEntry`
/// items it represents for the `.locus` tier.
///
/// Mirrors `AuditBridge.bridge(_:)` in Swift. One entry is emitted per
/// bitmap column that changed. Three columns per event: adjective,
/// operational, provenance.
///
/// Field mapping:
///   - tier:        `AuditTier::Locus`
///   - hlc:         the event's HLC, verbatim
///   - verb:        mapped from `event.verb` (string) to `UnifiedAuditVerb`
///   - row_id:      `event.row_id.0` as a 16-byte array (`EntryUUID`)
///   - field_path:  `"adjective"` / `"operational"` / `"provenance"`
///   - before_value: `.bitmap(before_col)` or `.null` on capture
///   - after_value:  `.bitmap(after_col)`
///   - origin_row_id: None
///
/// Synthetic (grant-lifecycle / sensitivity-unlock) verbs are routed to
/// `synthetic_entry_from_substrate_event` instead — they have no bitmap
/// columns to diff (RUST-AUDIT-DURABILITY, mirrors Swift `AuditBridge.bridge`'s
/// `syntheticVerbs` early-return).
pub fn bridge_audit_event(event: &substrate_types::audit_event::AuditEvent) -> Vec<UnifiedAuditEntry> {
    let unified_verb = verb_from_str(&event.verb);
    if is_synthetic_verb(unified_verb) {
        return vec![synthetic_entry_from_substrate_event(event, unified_verb)];
    }
    let (after_adj, after_op, after_prov) = event.after_bitmaps;
    let before = event.before_bitmaps;

    let row_uuid: u128 = event.row_id.0;
    let row_bytes = row_uuid.to_be_bytes();
    let entry_uuid = EntryUUID(row_bytes);

    let columns: [(&str, i64, Option<i64>); 3] = [
        ("adjective",   after_adj,  before.map(|(a, _, _)| a)),
        ("operational", after_op,   before.map(|(_, o, _)| o)),
        ("provenance",  after_prov, before.map(|(_, _, p)| p)),
    ];

    let mut entries = Vec::new();
    for (name, after_val, before_val_opt) in columns {
        // Mutator path: skip columns that did not change.
        if let Some(bv) = before_val_opt {
            if bv == after_val {
                continue;
            }
        }
        let before_value = match before_val_opt {
            Some(bv) => UnifiedAuditValue::Bitmap(bv as u64),
            None => UnifiedAuditValue::Null, // capture — no prior state
        };
        let after_value = UnifiedAuditValue::Bitmap(after_val as u64);
        entries.push(UnifiedAuditEntry::new(
            AuditTier::Locus,
            event.hlc,
            unified_verb,
            entry_uuid,
            name.to_string(),
            before_value,
            after_value,
            None,
        ));
    }

    // Lattice anchor (the FDC zone) -> the diffusion zone / topic-trajectory
    // motion model (node motion modeling, Option 3a). Mirrors Swift AuditBridge:
    // the anchor is already on the event (before/after); bridging it through
    // gives the UnifiedAuditLog the zone time-series with no substrate change.
    // Emit on capture (no prior anchor) and whenever a reanchor changes it; a
    // mutate that leaves the anchor unchanged emits nothing here. value =
    // Integer of the u64 UDC code (bit-preserving, matching Swift's
    // Int64(bitPattern:)).
    let after_anchor = event.after_lattice_anchor.udc_code;
    let before_anchor = event.before_lattice_anchor.map(|a| a.udc_code);
    if before_anchor != Some(after_anchor) {
        let before_value = match before_anchor {
            Some(bc) => UnifiedAuditValue::Integer(bc as i64),
            None => UnifiedAuditValue::Null,
        };
        entries.push(UnifiedAuditEntry::new(
            AuditTier::Locus,
            event.hlc,
            unified_verb,
            entry_uuid,
            "latticeAnchor".to_string(),
            before_value,
            UnifiedAuditValue::Integer(after_anchor as i64),
            None,
        ));
    }

    // Q-ID pointer → its own O/T coordinate. The UDC code alone collapses to a
    // uniform class ("Knowledge") for most prose, so co-occurrence and temporal
    // causality gain no per-content structure from it. The Q-ID is the varied
    // per-content concept the FDC classifier resolved, so emit it as a distinct
    // coordinate. Gated on a non-null Q-ID (pointer != 0) so content without a
    // resolved concept adds no uniform-zero coordinate. Mirrors Swift AuditBridge.
    let after_qid = event.after_lattice_anchor.qid_pointer;
    let before_qid = event.before_lattice_anchor.map(|a| a.qid_pointer);
    if before_qid != Some(after_qid) && (after_qid != 0 || before_qid.unwrap_or(0) != 0) {
        let before_value = match before_qid {
            Some(bq) if bq != 0 => UnifiedAuditValue::Integer(bq as i64),
            _ => UnifiedAuditValue::Null,
        };
        let after_value = if after_qid != 0 {
            UnifiedAuditValue::Integer(after_qid as i64)
        } else {
            UnifiedAuditValue::Null
        };
        entries.push(UnifiedAuditEntry::new(
            AuditTier::Locus,
            event.hlc,
            unified_verb,
            entry_uuid,
            "wikidataQID".to_string(),
            before_value,
            after_value,
            None,
        ));
    }
    entries
}

/// Map a free-form verb string from the substrate layer to the unified log's
/// `UnifiedAuditVerb` enum. Unknown verbs collapse to `.mutate`.
///
/// Mirrors `AuditBridge.verb(for:)` in Swift.
/// Map the substrate's free-form verb string to the unified log's verb enum.
/// Unknown verbs collapse to `.Mutate` (safe default for "a bitmap changed").
///
/// "tombstone" is the RowVerb the AuditGate seals for an expunge
/// (RowVerb::Tombstone.rawValue == "tombstone"). It maps to `.Expunge`
/// because that is the ARIA-level verb the operation represents. The
/// substrate uses the lower-level automaton term; the unified log uses
/// the ARIA noun–verb vocabulary.
///
/// "expungeOrphan" is written by `seal_expunge_orphan_audit` when the
/// storage half of an expunge succeeded but the cross-kit vector delete
/// (step 2) failed. It also maps to `.Expunge` so audit projection
/// consumers see the storage-level expunge in both the success and
/// orphan cases. Consumers that need to distinguish a clean expunge from
/// a partial one must read the substrate audit trail directly (the verb
/// string is preserved there as-is).
///
/// Grant-lifecycle (`EstateCoordinator::issue_grant`/`revoke_grant`,
/// coordinator.rs's `append_grant_audit_entry`, GLK-03 seam / FUP-C) and
/// sensitivity-unlock (`append_sensitivity_audit_entry`, out-of-band sensitivity grants) both
/// write their case's `raw_value()` verbatim as the durable event's `verb`
/// string — these six cases are the read-back symmetric to that write.
/// Before RUST-AUDIT-DURABILITY (2026-07-09) these six collapsed to
/// `.Mutate` here, which would have misrouted a durably-recovered synthetic
/// entry through the three-column bitmap-diff path instead of
/// `synthetic_entry_from_substrate_event`/`synthetic_entry_from_pk_event`.
///
/// Mirrors `AuditBridge.verb(for:)` in Swift.
fn verb_from_str(s: &str) -> UnifiedAuditVerb {
    match s {
        "capture"        => UnifiedAuditVerb::Capture,
        "withdraw"       => UnifiedAuditVerb::Withdraw,
        "tombstone"      => UnifiedAuditVerb::Expunge,   // AuditGate seals expunge as RowVerb::Tombstone
        "expungeOrphan"  => UnifiedAuditVerb::Expunge,   // cross-kit delete failed; storage half succeeded
        "expunge"        => UnifiedAuditVerb::Expunge,   // legacy / direct verb string (unused by current gate)
        "reanchor"       => UnifiedAuditVerb::Reanchor,
        "learn"          => UnifiedAuditVerb::Learn,
        "propose"        => UnifiedAuditVerb::Propose,
        "associate"      => UnifiedAuditVerb::Associate,
        "migrate"        => UnifiedAuditVerb::Migrate,
        "dreamCompact"   => UnifiedAuditVerb::DreamCompact,
        "grantIssued"               => UnifiedAuditVerb::GrantIssued,
        "grantRevoked"              => UnifiedAuditVerb::GrantRevoked,
        "sensitivityGrantIssued"    => UnifiedAuditVerb::SensitivityGrantIssued,
        "sensitivityGrantDenied"    => UnifiedAuditVerb::SensitivityGrantDenied,
        "sensitivityGrantRevoked"   => UnifiedAuditVerb::SensitivityGrantRevoked,
        "sensitivityReadUnderGrant" => UnifiedAuditVerb::SensitivityReadUnderGrant,
        _                => UnifiedAuditVerb::Mutate,
    }
}

// MARK: - feed_audit_log_from_estate

/// Walk all drawers in an estate, collect their audit trails, bridge each
/// substrate `AuditEvent` to `UnifiedAuditEntry`, and accumulate into a
/// `UnifiedAuditLog`.
///
/// Mirrors `GeniusLocusKit.feedAuditLog(for:)` in Swift. The unified log is
/// keyed on SHA-256 content addresses so this is idempotent — feeding the
/// same events twice is a G-Set no-op.
pub(crate) fn feed_audit_log_from_estate(
    estate: &Estate,
) -> Result<UnifiedAuditLog, LocusKitError> {
    let mut log = UnifiedAuditLog::new();
    let drawers = estate.all_drawers()?;
    for drawer in &drawers {
        let events = estate.audit_trail(&drawer.id)?;
        for event in &events {
            let entries = bridge_audit_event(event);
            for entry in entries {
                log.add(entry);
            }
        }
    }
    Ok(log)
}

// MARK: - HydrateError

/// Errors from the GLK hydration path.
///
/// `Replication` carries the error as a formatted `String` (via `Debug`)
/// rather than wrapping `ReplicationError` directly. `ReplicationError` only
/// derives `Debug + PartialEq` (no `Clone` or `Eq`), so owning it would
/// prevent `HydrateError` from deriving `Clone + Eq` — which callers need for
/// test assertions and error comparisons.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HydrateError {
    /// The replication primitive failed (schema gate, storage error).
    /// Formatted as `"{:?}"` from the underlying `ReplicationError`.
    Replication(String),
    /// Estate::open failed (manifest absent, malformed, or mismatched).
    Estate(String),
    /// Audit-trail reading failed during the audit-log feed step.
    AuditFeed(String),
    /// The coordinator rejected the estate (duplicate UUID).
    Coordinator(String),
}

impl std::fmt::Display for HydrateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Replication(s) => write!(f, "replication: {s}"),
            Self::Estate(s) => write!(f, "estate: {s}"),
            Self::AuditFeed(s) => write!(f, "audit_feed: {s}"),
            Self::Coordinator(s) => write!(f, "coordinator: {s}"),
        }
    }
}
