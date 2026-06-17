// hydration.rs — GLK-level hydrate-on-launch integration (Rust port).
//
// Wires `persistence_kit::replication::hydrate` into the EstateCoordinator
// startup sequence so an in-memory estate can be rebuilt from a durable
// (SQLite) backend on launch.
//
// HYDRATE SEQUENCE (authoritative, from REPLICATION_GROUND_TRUTH.md §7):
//
//   1. Schema open    — open both in_memory and durable with the composite
//                       GLK schema (version 3: LocusKit v1 + VectorKit v1 +
//                       CorpusKit v1). This advances both storages to version 3
//                       so the replication schema gate (global version check)
//                       passes.
//   2. Row snapshot   — replication::hydrate copies all 14 schema-declared
//                       tables (including tombstones and append-only rows)
//                       verbatim from durable into in_memory.
//   3. Audit events   — replication::hydrate also copies _storagekit_audit
//                       events via the AuditLog protocol path.
//   4. Estate open    — InMemoryDrawerStore::with_storage opens the LocusKit
//                       schema on the already-populated in_memory storage (the
//                       open() call is a no-op because schema.version=1 <
//                       already-applied version=3). Estate::open reads the
//                       manifest that was copied in step 2.
//   5. Audit log feed — walk all drawers in the estate; for each drawer call
//                       estate.audit_trail(id) and bridge each
//                       substrate_types::AuditEvent → [UnifiedAuditEntry].
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
// GLK schema (version 3) is opened on BOTH sides so MAX(versions) = 3 on
// both, satisfying the gate.
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
use crate::handle::EstateHandle;
use crate::matrix::MatrixTier;

// MARK: - Composite GLK SchemaDeclaration

/// The explicit composite SchemaDeclaration for a GeniusLocus estate.
///
/// Mirrors `GeniusLocusKitSchema.estateSchemaDeclaration` in Swift.
///
/// A GeniusLocus estate is a composition of three kits, each with its own
/// per-kit schema. The composite schema aggregates all 14 user-visible tables
/// and uses version 3 (LocusKit v1 + VectorKit v1 + CorpusKit v1 = 3).
///
/// The composite schema is opened on both source and destination storages
/// before calling `replication::hydrate` or `replication::flush` so the
/// replication gate (which checks the global current_schema_version against
/// schema.version) sees version 3 on both sides.
///
/// # Version rationale
///
/// The Rust replication primitive checks the global schema version, not a
/// per-kit version like Swift. Opening the composite schema (version 3)
/// advances the global version to max(existing, 3). For durable SQLite
/// storages that were opened with the component kit schemas (each version 1),
/// calling `storage.open(composite_schema)` writes version 3 to the
/// migrations table without touching existing data tables (CREATE TABLE IF
/// NOT EXISTS). For fresh in-memory storages it creates all 14 tables at
/// once.
pub fn composite_schema() -> SchemaDeclaration {
    let lk = locus_kit::schema::schema();
    let vk = vectorkit::VectorStore::schema_declaration();
    let ck = corpus_kit::BundleStore::schema_declaration();

    let mut tables = Vec::new();
    tables.extend(lk.tables);
    tables.extend(vk.tables);
    tables.extend(ck.tables);

    let mut indices = Vec::new();
    indices.extend(lk.indices);
    indices.extend(vk.indices);
    indices.extend(ck.indices);

    SchemaDeclaration {
        kit_id: "GeniusLocusKit".to_string(),
        version: 3, // LocusKit v1 + VectorKit v1 + CorpusKit v1
        tables,
        indices,
        // No cross-kit migrations at the composite level — each component kit
        // manages its own schema evolution. Composite version bumps by
        // incrementing this field and adding entries here.
        migrations: vec![],
    }
}

// MARK: - Flush convenience

/// Flush an in-memory storage into a durable storage.
///
/// Opens both backends with the composite GLK schema before calling
/// `replication::flush` so the schema gate passes. For the in-memory backend
/// this is idempotent if it was already opened at version >= 3. For the
/// durable backend (SQLite) this writes version 3 to the migrations table
/// without altering existing data tables.
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
    // DrawerStoreCore::new calls storage.open(locus_schema) — a no-op since
    // version 1 < 3 is false, the storage is already at version 3 from step 1.
    let store = InMemoryDrawerStore::with_storage(in_memory, now, None)
        .map_err(|e| HydrateError::Estate(format!("{e:?}")))?;
    let store_arc: Arc<dyn DrawerStore> = Arc::new(store);
    let estate = Estate::open(store_arc, owner)
        .map_err(|e| HydrateError::Estate(format!("{e:?}")))?;

    // Step 5 — Audit log feed: walk all drawers and convert their audit trail
    // into UnifiedAuditEntry items. Bridge converts the substrate-level bitmap
    // snapshots into the GLK-level field-path entries required by MatrixTier.
    let unified_log = feed_audit_log_from_estate(&estate)
        .map_err(|e| HydrateError::AuditFeed(format!("{e:?}")))?;

    // Step 6 — Matrix rebuild (full: both passes).
    let matrix_tier = MatrixTier::full_rebuild(&unified_log);

    Ok(HydratedEstate { estate, unified_log, matrix_tier })
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
            .open_estate_directly(hydrated.estate, zoom_window_low, zoom_window_high)
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
    /// Register an already-opened `Estate` with the coordinator.
    ///
    /// Used by `open_hydrating` to admit a hydrated estate without going
    /// through the DrawerStore + Estate::open path a second time.
    ///
    /// Parity note: in Swift, `GeniusLocusKit.open(storage:owner:)` calls
    /// `Estate.open` and then registers the result. In Rust, the hydration
    /// path (which already ran `Estate::open`) calls this to register.
    pub fn open_estate_directly(
        &mut self,
        estate: Estate,
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
        Ok(handle)
    }
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
pub fn bridge_audit_event(event: &substrate_types::audit_event::AuditEvent) -> Vec<UnifiedAuditEntry> {
    let unified_verb = verb_from_str(&event.verb);
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
