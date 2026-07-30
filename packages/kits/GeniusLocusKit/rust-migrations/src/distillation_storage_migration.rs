//! Distillation storage migration (A.1 steps c–e).
//! Rust twin of Swift `DistillationStorageMigration.swift`.
//!
//! Step ordering (load-bearing — spec Appendix A.1 note):
//!   (c) Re-key distillation-features-v1 lane entries from factoid IDs to
//!       source drawer IDs; ambiguous provenance (≠1 _distilled_from tunnel)
//!       drops the entry; also deletes orphaned factoid-keyed lane entries
//!       (items whose item_id no longer exists in drawers at all — FINDING
//!       11X_CUSTODIAN_WALK item 1).
//!   (b) Drop all factoid drawers (addedBy = "distillation-daemon"). These
//!       are the retired distilled-view rows; content is never converted.
//!   (d) Drop all _distilled_from tunnels (provenance link retired in 1.1.x).
//!   (e) Add the four representation columns to `drawers` with NULL initial
//!       values: distilled, distilled_pipeline_version, distilled_token_count,
//!       distilled_at. Tracked under kit_id "GLKDistillationStorageMigration"
//!       so migration state is independent of the LocusKit schema version.
//!       AddColumn is idempotent (PersistenceKit skips columns that already
//!       exist, covering the fresh-1.1.x-estate path).
//!
//! (c) must precede (b) because it reads factoid drawer IDs, and must
//! precede (d) because it reads _distilled_from tunnels.
//!
//! Steps (c)–(d) are wrapped in a single storage transaction. A crash
//! during the transaction rolls back to the pre-migration state; the
//! migration resumes cleanly on the next run since the estate-format
//! stamp at v1_1 (written by SharedContentMigration at the end of the
//! full migration chain) has not been written yet.
//!
//! Vault protocol (A.0.5) is expressed as a struct with boxed closure
//! fields to keep this module free of a VaultKit dependency. The app
//! layer supplies vault operations. Mirrors Swift's
//! `DistillationStorageMigrationVaultProtocol`.
//!
//! Swift twin: Sources/GLKMigrationV1_0ToV1_1/DistillationStorageMigration.swift

use persistence_kit::error::StorageResult;
use persistence_kit::schema::{ColumnDeclaration, Migration, SchemaDeclaration, SchemaOperation};
use persistence_kit::types::{Column, TypedValue};
use persistence_kit::{IsolationLevel, Storage, StoragePredicate, StorageTransaction};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use vectorkit::VectorStore;

// MARK: - Domain constants

/// VectorKit model lane holding structural fingerprints.
/// 1.0.x: keyed by factoid drawer ID. 1.1.x: keyed by source drawer ID.
const K_DISTILLATION_LANE_MODEL_ID: &str = "distillation-features-v1";

/// addedBy value for all factoid drawers (the retired view layer).
const K_DISTILLATION_DAEMON_ADDED_BY: &str = "distillation-daemon";

/// Tunnel label linking a factoid drawer (source) to the original content
/// drawer (target). Retired in 1.1.x.
const K_DISTILLED_FROM_LABEL: &str = "_distilled_from";

// MARK: - Vault protocol (A.0.5)

/// Closure-based vault operations for migration. Expressed as closures
/// (not a trait object) so the migration module stays free of a
/// VaultKit import. The app layer constructs this struct with real vault
/// operations. Mirrors Swift `DistillationStorageMigrationVaultProtocol`.
pub struct DistillationStorageMigrationVaultProtocol {
    /// Pre-migration vault reconcile. Returns:
    ///   - `None`   when no vault is configured for the estate.
    ///   - `Some(true)` when the vault is clean — migration may proceed.
    ///   - `Some(false)` when the vault is unclean — migration must abort.
    pub reconcile: Box<dyn Fn() -> Result<Option<bool>, Box<dyn std::error::Error>> + Send + Sync>,

    /// Archive the current vault file by renaming it in place to the
    /// archival suffix path. Called before the A.1 data migration.
    /// The original file MUST NOT be deleted — only renamed.
    pub archive: Box<dyn Fn() -> Result<(), Box<dyn std::error::Error>> + Send + Sync>,

    /// Re-export the estate to the ORIGINAL vault position in the new
    /// 1.1.x format (without the retired distilled_from_sources key).
    /// Called after the A.1 data migration completes.
    pub export_fresh: Box<dyn Fn() -> Result<(), Box<dyn std::error::Error>> + Send + Sync>,

    /// User-visible notice that the vault was archived and re-exported.
    /// Called after export_fresh succeeds. Best-effort (never propagates
    /// errors). Mirrors Swift `DistillationStorageMigrationVaultProtocol.notifyUser`.
    pub notify_user: Box<dyn Fn() + Send + Sync>,
}

// MARK: - Migration report

/// Summary of what the A.1 migration changed.
/// Mirrors Swift `DistillationStorageMigrationReport`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DistillationStorageMigrationReport {
    /// Factoid drawers (addedBy = "distillation-daemon") deleted.
    pub factoid_drawer_count: usize,

    /// _distilled_from tunnels deleted.
    pub tunnel_count: usize,

    /// distillation-features-v1 lane entries re-keyed from factoid IDs
    /// to source drawer IDs (exactly-1-tunnel case).
    pub re_keyed_lane_count: usize,

    /// distillation-features-v1 lane entries deleted — factoids with
    /// ambiguous provenance (0 or >1 tunnels) plus pre-existing orphans
    /// (entries whose item_id no longer existed in drawers).
    pub dropped_lane_count: usize,
}

// MARK: - Migration error

/// Error type for the distillation storage migration.
/// Mirrors Swift `DistillationStorageMigrationError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DistillationStorageMigrationError {
    /// Storage was not registered for the estate handle.
    StorageUnavailable { reason: String },

    /// Vault reconcile returned false (unclean vault); A.0.5 abort.
    VaultUnclean,
}

impl std::fmt::Display for DistillationStorageMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => write!(
                f,
                "DistillationStorageMigration: storage unavailable — {reason}"
            ),
            Self::VaultUnclean => write!(
                f,
                "DistillationStorageMigration: vault reconcile failed (unclean); migration aborted"
            ),
        }
    }
}

impl std::error::Error for DistillationStorageMigrationError {}

// MARK: - Step (e) schema declaration

/// PersistenceKit schema declaration for the four representation columns.
///
/// Uses its own kit_id so the migration version is tracked independently
/// of the LocusKit schema version. AddColumn operations are idempotent:
/// PersistenceKit skips columns that already exist (covers the
/// fresh-1.1.x-estate path where the v1 CREATE TABLE already includes
/// these columns). Mirrors Swift `DistillationStorageMigrationSchema
/// .representationColumnsDeclaration`.
pub fn representation_columns_declaration() -> SchemaDeclaration {
    SchemaDeclaration::new("GLKDistillationStorageMigration", 1, vec![]).with_migrations(vec![
        Migration {
            from_version: 0,
            to_version: 1,
            operations: vec![
                // distilled: dense parallel rendering of `content`.
                // NULL until DistillationCycle populates it post-migration.
                SchemaOperation::AddColumn {
                    table: "drawers".to_string(),
                    column: ColumnDeclaration::text("distilled").nullable(),
                },
                // distilled_pipeline_version: contract identifier for the
                // pipeline that produced `distilled` (e.g. "v1").
                SchemaOperation::AddColumn {
                    table: "drawers".to_string(),
                    column: ColumnDeclaration::text("distilled_pipeline_version").nullable(),
                },
                // distilled_token_count: approximate token count of `distilled`.
                SchemaOperation::AddColumn {
                    table: "drawers".to_string(),
                    column: ColumnDeclaration::int("distilled_token_count").nullable(),
                },
                // distilled_at: ISO8601 timestamp of the distillation run.
                // TEXT per fleet date storage rule (ColumnType::Timestamp →
                // TEXT in SQLite, matching Swift .timestamp column type).
                SchemaOperation::AddColumn {
                    table: "drawers".to_string(),
                    column: ColumnDeclaration::timestamp("distilled_at").nullable(),
                },
            ],
        },
    ])
}

// MARK: - Core migration function

/// Execute A.1 steps (c)→(b)→(d)→(e).
///
/// Mirrors Swift `GeniusLocusKit._runDistillationDataMigration(storage:)`.
///
/// Steps (c)–(d) are wrapped in a single `IsolationLevel::Serializable`
/// transaction for crash safety. A crash inside the transaction rolls
/// back; on the next run the estate-format stamp (written by
/// SharedContentMigration) is still absent so the migration reruns.
///
/// Step (e) is applied outside the transaction; it is independently
/// idempotent via PersistenceKit's per-kit migration tracking.
pub fn run_distillation_data_migration(
    storage: &Arc<dyn Storage>,
) -> StorageResult<DistillationStorageMigrationReport> {
    // Ensure the VectorKit schema (vectors table) is registered before
    // querying it in step (c). On a 1.0.x estate the schema was already
    // applied; on a fresh 1.1.x estate the table may not exist yet.
    // Idempotent: if already at the current version, migrate() is a no-op.
    // Mirrors the pattern in SharedContentMigration (Rust twin, line ~833).
    storage.migrate(&VectorStore::schema_declaration())?;

    // Steps (c)→(b)→(d) inside a single transaction.
    // Ordering is load-bearing: (c) reads the tunnels that (d) drops
    // and the factoid IDs that (b) deletes.
    let mut re_keyed_count: usize = 0;
    let mut dropped_count: usize = 0;
    let mut factoid_delete_count: usize = 0;
    let mut tunnel_delete_count: usize = 0;

    storage.transaction(
        IsolationLevel::Serializable,
        &mut |txn: &dyn StorageTransaction| {
            let row_store = txn.row_store();

            // ── (c) Phase 1: build tunnel map ─────────────────────────────
            //
            // Load all _distilled_from tunnels.
            // sourceDrawerId = factoid drawer ID (the view node).
            // targetDrawerId = source drawer ID (the original content).
            let tunnel_rows = row_store.query(
                "tunnels",
                Some(&StoragePredicate::Eq(
                    Column::new("tunnels", "label"),
                    TypedValue::Text(K_DISTILLED_FROM_LABEL.to_string()),
                )),
                &[],
                None,
                None,
            )?;
            // Map: factoidID → Vec<sourceID>
            let mut tunnel_map: HashMap<String, Vec<String>> = HashMap::new();
            for row in &tunnel_rows {
                let Some(factoid_id) = text_value(row.get("sourceDrawerId")) else {
                    continue;
                };
                let Some(source_id) = text_value(row.get("targetDrawerId")) else {
                    continue;
                };
                tunnel_map.entry(factoid_id).or_default().push(source_id);
            }

            // ── (c) Phase 2: load factoid drawer IDs ──────────────────────
            let factoid_rows = row_store.query(
                "drawers",
                Some(&StoragePredicate::Eq(
                    Column::new("drawers", "addedBy"),
                    TypedValue::Text(K_DISTILLATION_DAEMON_ADDED_BY.to_string()),
                )),
                &[],
                None,
                None,
            )?;
            let factoid_ids: HashSet<String> = factoid_rows
                .iter()
                .filter_map(|r| text_value(r.get("id")))
                .collect();

            // ── (c) Phase 3: load lane item IDs ───────────────────────────
            //
            // All item_ids in the distillation-features-v1 lane.
            let lane_rows = row_store.query(
                "vectors",
                Some(&StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text(K_DISTILLATION_LANE_MODEL_ID.to_string()),
                )),
                &[],
                None,
                None,
            )?;
            let lane_item_ids: HashSet<String> = lane_rows
                .iter()
                .filter_map(|r| text_value(r.get("item_id")))
                .collect();

            // ── (c) Phase 4: detect and delete orphaned lane entries ───────
            //
            // Orphaned = item_id is in the lane but NOT a factoid and NOT
            // in the drawers table at all. Pre-existing data gaps
            // (FINDING_11X_CUSTODIAN_WALK item 1).
            let non_factoid_lane_ids: HashSet<String> =
                lane_item_ids.difference(&factoid_ids).cloned().collect();

            let mut valid_source_lane_ids: HashSet<String> = HashSet::new();
            let mut local_dropped: usize = 0;

            if !non_factoid_lane_ids.is_empty() {
                // Batch-check which of these exist in the drawers table.
                let in_values: Vec<TypedValue> = non_factoid_lane_ids
                    .iter()
                    .map(|id| TypedValue::Text(id.clone()))
                    .collect();
                let existing_rows = row_store.query(
                    "drawers",
                    Some(&StoragePredicate::In(
                        Column::new("drawers", "id"),
                        in_values,
                    )),
                    &[],
                    None,
                    None,
                )?;
                let existing_ids: HashSet<String> = existing_rows
                    .iter()
                    .filter_map(|r| text_value(r.get("id")))
                    .collect();

                // Orphans = in lane but no corresponding drawer.
                let orphan_ids: Vec<String> = non_factoid_lane_ids
                    .difference(&existing_ids)
                    .cloned()
                    .collect();
                // Valid = in lane and already keyed to an existing non-factoid
                // source drawer. Leave these alone; track them to detect
                // re-key collisions in phase 5.
                valid_source_lane_ids = non_factoid_lane_ids
                    .intersection(&existing_ids)
                    .cloned()
                    .collect();

                for orphan_id in &orphan_ids {
                    row_store.delete(
                        "vectors",
                        &StoragePredicate::And(vec![
                            StoragePredicate::Eq(
                                Column::new("vectors", "item_id"),
                                TypedValue::Text(orphan_id.clone()),
                            ),
                            StoragePredicate::Eq(
                                Column::new("vectors", "model_id"),
                                TypedValue::Text(K_DISTILLATION_LANE_MODEL_ID.to_string()),
                            ),
                        ]),
                    )?;
                    local_dropped += 1;
                }
            }

            // ── (c) Phase 5: re-key or drop factoid lane entries ──────────
            //
            // For each factoid that has a lane entry:
            //   - exactly 1 _distilled_from tunnel → re-key item_id to the
            //     source drawer ID (unless that source already has a lane
            //     entry, which would collide on the UNIQUE(item_id,
            //     vector_index, model_id) constraint; in that case drop).
            //   - 0 or >1 tunnels (ambiguous provenance) → drop entry.
            let mut local_re_keyed: usize = 0;

            // Collect factoid IDs with lane entries first (avoids borrowing
            // lane_item_ids inside the loop over factoid_ids).
            let factoids_in_lane: Vec<String> = factoid_ids
                .iter()
                .filter(|id| lane_item_ids.contains(*id))
                .cloned()
                .collect();

            for factoid_id in &factoids_in_lane {
                let sources = tunnel_map
                    .get(factoid_id)
                    .map(|v| v.as_slice())
                    .unwrap_or(&[]);

                if sources.len() == 1 {
                    let source_id = &sources[0];
                    if valid_source_lane_ids.contains(source_id) {
                        // Collision: source drawer already has a lane entry.
                        // Drop the factoid-keyed entry to preserve the unique
                        // constraint on (item_id, vector_index, model_id).
                        row_store.delete(
                            "vectors",
                            &StoragePredicate::And(vec![
                                StoragePredicate::Eq(
                                    Column::new("vectors", "item_id"),
                                    TypedValue::Text(factoid_id.clone()),
                                ),
                                StoragePredicate::Eq(
                                    Column::new("vectors", "model_id"),
                                    TypedValue::Text(K_DISTILLATION_LANE_MODEL_ID.to_string()),
                                ),
                            ]),
                        )?;
                        local_dropped += 1;
                    } else {
                        // Re-key: change item_id from the factoid UUID to the
                        // source drawer UUID.
                        let mut values = BTreeMap::new();
                        values.insert(
                            "item_id".to_string(),
                            TypedValue::Text(source_id.clone()),
                        );
                        row_store.update(
                            "vectors",
                            values,
                            &StoragePredicate::And(vec![
                                StoragePredicate::Eq(
                                    Column::new("vectors", "item_id"),
                                    TypedValue::Text(factoid_id.clone()),
                                ),
                                StoragePredicate::Eq(
                                    Column::new("vectors", "model_id"),
                                    TypedValue::Text(K_DISTILLATION_LANE_MODEL_ID.to_string()),
                                ),
                            ]),
                        )?;
                        // Mark this source as now having a lane entry so a
                        // second factoid pointing to the same source (shouldn't
                        // happen but defensive) doesn't collide on re-key.
                        valid_source_lane_ids.insert(source_id.clone());
                        local_re_keyed += 1;
                    }
                } else {
                    // Ambiguous provenance (0 or >1 tunnels): drop.
                    row_store.delete(
                        "vectors",
                        &StoragePredicate::And(vec![
                            StoragePredicate::Eq(
                                Column::new("vectors", "item_id"),
                                TypedValue::Text(factoid_id.clone()),
                            ),
                            StoragePredicate::Eq(
                                Column::new("vectors", "model_id"),
                                TypedValue::Text(K_DISTILLATION_LANE_MODEL_ID.to_string()),
                            ),
                        ]),
                    )?;
                    local_dropped += 1;
                }
            }

            // ── (b) Drop all factoid drawers ───────────────────────────────
            //
            // Content is never converted — these are retired view rows.
            // All associated vectors were handled above in step (c).
            let deleted_factoids = row_store.delete(
                "drawers",
                &StoragePredicate::Eq(
                    Column::new("drawers", "addedBy"),
                    TypedValue::Text(K_DISTILLATION_DAEMON_ADDED_BY.to_string()),
                ),
            )?;

            // ── (d) Drop all _distilled_from tunnels ───────────────────────
            //
            // Provenance links retired in 1.1.x; source-drawer lineage is
            // now recorded in the drawers columns added in step (e).
            let deleted_tunnels = row_store.delete(
                "tunnels",
                &StoragePredicate::Eq(
                    Column::new("tunnels", "label"),
                    TypedValue::Text(K_DISTILLED_FROM_LABEL.to_string()),
                ),
            )?;

            // Surface results through captured mutable environment.
            re_keyed_count = local_re_keyed;
            dropped_count = local_dropped;
            factoid_delete_count = deleted_factoids;
            tunnel_delete_count = deleted_tunnels;

            Ok(())
        },
    )?;

    // ── (e) Add four representation columns ────────────────────────────
    //
    // Uses its own kit_id so migration state is tracked independently of
    // the LocusKit schema version. Idempotent: AddColumn skips columns
    // that already exist (fresh-1.1.x-estate invariant). NULL initial
    // values — bit 19 (hasCurrentRepresentation) in operationalBitmap
    // is already 0 on all existing rows by construction.
    storage.migrate(&representation_columns_declaration())?;

    eprintln!(
        "DistillationStorageMigration complete — \
        factoids: {factoid_delete_count}, \
        tunnels: {tunnel_delete_count}, \
        re_keyed: {re_keyed_count}, \
        dropped: {dropped_count}"
    );

    Ok(DistillationStorageMigrationReport {
        factoid_drawer_count: factoid_delete_count,
        tunnel_count: tunnel_delete_count,
        re_keyed_lane_count: re_keyed_count,
        dropped_lane_count: dropped_count,
    })
}

// MARK: - Vault-protocol wrapper

/// Execute the distillation storage migration with the vault protocol
/// (SPEC_DISTILLATION_STORAGE Appendix A.0.5).
///
/// Order:
///   1. Pre-migration vault reconcile — abort if unclean.
///   2. Archive old vault file (in-place rename, never deleted).
///   3. A.1 data migration (steps c–e).
///   4. Fresh vault export in new format (no distilled_from_sources).
///   5. User notice.
///
/// Mirrors Swift
/// `GeniusLocusKit.runDistillationStorageMigrationWithVaultProtocol`.
pub fn run_distillation_data_migration_with_vault_protocol(
    storage: &Arc<dyn Storage>,
    vault_protocol: &DistillationStorageMigrationVaultProtocol,
) -> Result<DistillationStorageMigrationReport, Box<dyn std::error::Error>> {
    // 1. Pre-migration vault reconcile. None → no vault, proceed.
    if let Some(clean) = (vault_protocol.reconcile)()? {
        if !clean {
            return Err(Box::new(DistillationStorageMigrationError::VaultUnclean));
        }
    }

    // 2. Archive old vault (in-place rename at export point).
    (vault_protocol.archive)()?;

    // 3. A.1 data migration.
    let report = run_distillation_data_migration(storage)?;

    // 4. Fresh vault export — new format, no distilled_from_sources key.
    (vault_protocol.export_fresh)()?;

    // 5. User notice (best-effort; does not propagate errors).
    (vault_protocol.notify_user)();

    Ok(report)
}

// MARK: - Helpers

/// Extract a text string from a TypedValue.
/// Accepts both Text and Uuid forms; SQLite may return either for
/// TEXT-declared columns depending on how the value was stored.
/// Mirrors Swift `GeniusLocusKit._textValue(_:)`.
fn text_value(value: Option<&TypedValue>) -> Option<String> {
    match value {
        Some(TypedValue::Text(s)) => Some(s.clone()),
        Some(TypedValue::Uuid(u)) => Some(u.to_string()),
        _ => None,
    }
}
