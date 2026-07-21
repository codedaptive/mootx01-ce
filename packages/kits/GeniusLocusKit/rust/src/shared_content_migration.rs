//! The resumable, fail-dark legacy migration (GLK shared-content 1.1, P4).
//! Rust twin of Swift `SharedContentMigration.swift`.
//!
//! discovered → canonicalValidated → legacyInventoryCaptured →
//! legacyDerivedCleared → legacySchemaRetired → drawerIndexRebuilt →
//! verified → reclaimPending → complete
//!
//! Every transition is idempotent and persisted in a record INDEPENDENT of
//! the derived tables being replaced; a crash or cancellation resumes from
//! the last verified transition. The Corpus lane stays dark until
//! `verified`; LocusKit recall is available throughout. Protected state —
//! Drawers, relationships, unrelated/shared vectors — is never
//! reconstructed or deleted (baseline folds prove it at verification).

use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::handle::EstateHandle;
use crate::intake::LocusDrawerContentSource;
use corpus_kit::content::CorpusContentSource;
use corpus_kit::corpus_provider_counts_store::CorpusProviderCountsStore;
use corpus_kit::{    BasisStore, CorpusContentConfiguration, CorpusContentEngine, CorpusIndexStateStore,
    CorpusIndexUnitPolicy, CorpusOperatingMode, EmbeddingModelConfig,
};
use persistence_kit::{
    Column, ColumnDeclaration, Migration, SchemaDeclaration, SchemaOperation, Storage,
    StoragePredicate, TableDeclaration, TypedValue,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use vectorkit::{VectorExactKey, VectorRepresentationClaims, VectorStore};

// MARK: - State machine

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SharedContentMigrationState {
    Discovered,
    CanonicalValidated,
    LegacyInventoryCaptured,
    LegacyDerivedCleared,
    LegacySchemaRetired,
    DrawerIndexRebuilt,
    BasesTrained,
    ProvidersCovered,
    Verified,
    ReclaimPending,
    Complete,
}

/// Migration/reclaim status for the estate status/admin surface
/// (`shared_content_reclaim_status`). Mirrors Swift
/// `SharedContentReclaimStatus`.
#[derive(Debug, Clone, PartialEq)]
pub struct SharedContentReclaimStatus {
    /// The persisted migration state; None when no record exists.
    pub state: Option<SharedContentMigrationState>,
    /// The estimate captured at `reclaimPending`.
    pub estimated_reclaimable_bytes: Option<i64>,
    /// Filesystem bytes the completed maintenance pass actually released.
    pub reclaimed_bytes: Option<i64>,
    /// LIVE estimate from the storage maintenance surface (freelist + WAL
    /// bytes right now); None when the backend reports no estimate.
    pub live_reclaimable_bytes: Option<i64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SharedContentMigrationReport {
    pub state: SharedContentMigrationState,
    pub legacy_chunk_count: usize,
    pub legacy_vector_key_count: usize,
    pub rebuilt_content_count: usize,
    pub estimated_reclaimable_bytes: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SharedContentMigrationError {
    OrphanedLegacySources {
        ids: Vec<String>,
        state: SharedContentMigrationState,
    },
    VerificationFailed {
        reason: String,
    },
    StorageFailure {
        state: SharedContentMigrationState,
        reason: String,
    },
    InjectedFault {
        after: SharedContentMigrationState,
    },
}

// MARK: - Durable record

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SharedContentMigrationRecord {
    pub state: SharedContentMigrationState,
    #[serde(rename = "detectedLayout")]
    pub detected_layout: String,
    #[serde(rename = "legacyChunkIDs")]
    pub legacy_chunk_ids: Vec<String>,
    #[serde(rename = "legacyVectorKeys")]
    pub legacy_vector_keys: Vec<String>,
    #[serde(rename = "protectedBaseline")]
    pub protected_baseline: BTreeMap<String, String>,
    #[serde(rename = "rebuildCursor")]
    pub rebuild_cursor: Option<String>,
    #[serde(rename = "rebuiltContentCount")]
    pub rebuilt_content_count: usize,
    #[serde(rename = "estimatedReclaimableBytes")]
    pub estimated_reclaimable_bytes: Option<i64>,
    /// Filesystem bytes actually released by the maintenance pass at
    /// completion (None until `complete_shared_content_reclaim` runs).
    #[serde(rename = "reclaimedBytes", default)]
    pub reclaimed_bytes: Option<i64>,
    /// Inventory counts persisted at completion so the bulky ID lists can be
    /// TRIMMED from the record (P6: a 1.1M-key inventory held ~60 MB in the
    /// record row forever; the evidence is consumed at verification).
    #[serde(rename = "legacyChunkCount", default)]
    pub legacy_chunk_count: Option<usize>,
    #[serde(rename = "legacyVectorKeyCount", default)]
    pub legacy_vector_key_count: Option<usize>,
    /// The ensemble/configuration fingerprint the migration completed
    /// under (corrective pass). Wiring a DIFFERENT configuration over a
    /// completed record is a follow-on upgrade, never trusted as complete.
    #[serde(rename = "ensembleFingerprint", default)]
    pub ensemble_fingerprint: Option<String>,
    /// Per-provider basis generations (model_id → basis digest) recorded
    /// at `basesTrained` and re-verified at `verified`.
    #[serde(rename = "providerGenerations", default)]
    pub provider_generations: Option<BTreeMap<String, String>>,
}

const SINGLETON_ID: &str = "shared-content-1.1";

pub struct SharedContentMigrationStore {
    storage: Arc<dyn Storage>,
}

impl SharedContentMigrationStore {
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "GLKSharedContentMigration",
            1,
            vec![TableDeclaration::new(
                "glk_shared_content_migration",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::text("state"),
                    ColumnDeclaration::json("record"),
                    ColumnDeclaration::timestamp("updated_at"),
                ],
                vec!["id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        SharedContentMigrationStore { storage }
    }

    pub fn load(&self) -> Result<Option<SharedContentMigrationRecord>, SharedContentMigrationError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "glk_shared_content_migration",
                Some(&StoragePredicate::Eq(
                    Column::new("glk_shared_content_migration", "id"),
                    TypedValue::Text(SINGLETON_ID.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| SharedContentMigrationError::StorageFailure {
                state: SharedContentMigrationState::Discovered,
                reason: format!("{e:?}"),
            })?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        // Primitive tolerance: JSON columns may come back as Json, Blob, or Text.
        let data: Vec<u8> = match row.get("record") {
            Some(TypedValue::Json(d)) => d.clone(),
            Some(TypedValue::Blob(d)) => d.clone(),
            Some(TypedValue::Text(t)) => t.clone().into_bytes(),
            _ => return Ok(None),
        };
        serde_json::from_slice(&data)
            .map(Some)
            .map_err(|e| SharedContentMigrationError::StorageFailure {
                state: SharedContentMigrationState::Discovered,
                reason: format!("record decode: {e}"),
            })
    }

    pub fn save(
        &self,
        record: &SharedContentMigrationRecord,
        now_millis: i64,
    ) -> Result<(), SharedContentMigrationError> {
        let bytes = serde_json::to_vec(record).map_err(|e| {
            SharedContentMigrationError::StorageFailure {
                state: record.state,
                reason: format!("record encode: {e}"),
            }
        })?;
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("id".into(), TypedValue::Text(SINGLETON_ID.to_string()));
        values.insert(
            "state".into(),
            TypedValue::Text(format!("{:?}", record.state)),
        );
        values.insert("record".into(), TypedValue::Json(bytes));
        values.insert("updated_at".into(), TypedValue::Timestamp(now_millis));
        self.storage
            .row_store()
            .upsert("glk_shared_content_migration", values, &["id".to_string()])
            .map_err(|e| SharedContentMigrationError::StorageFailure {
                state: record.state,
                reason: format!("{e:?}"),
            })?;
        Ok(())
    }
}

// MARK: - Detection + retirement

/// Structural legacy detection — never a version literal.
pub fn detect_legacy_layout(storage: &Arc<dyn Storage>) -> Option<String> {
    let row_store = storage.row_store();
    if row_store.count("chunks", None).is_err() {
        return None;
    }
    if row_store.count("corpus_metadata", None).is_ok() {
        Some("legacy-chunks+metadata".to_string())
    } else {
        Some("legacy-chunks".to_string())
    }
}

/// The DECLARED PersistenceKit migration retiring the copy-lane tables.
fn retirement_declaration() -> SchemaDeclaration {
    let operations = vec![
        SchemaOperation::DropIndex {
            name: "idx_chunks_source".to_string(),
        },
        SchemaOperation::DropIndex {
            name: "idx_chunks_hlc".to_string(),
        },
        SchemaOperation::DropTable {
            name: "chunks".to_string(),
        },
        SchemaOperation::DropTable {
            name: "corpus_metadata".to_string(),
        },
        SchemaOperation::DropTable {
            name: "removed_sources".to_string(),
        },
    ];
    SchemaDeclaration::new("CorpusKit", 4, vec![]).with_migrations(vec![
        Migration {
            from_version: 2,
            to_version: 3,
            operations: vec![],
        },
        Migration {
            from_version: 3,
            to_version: 4,
            operations,
        },
    ])
}

// MARK: - Runner

impl EstateCoordinator {
    /// Install the fault-injection seam (test-only; single-use).
    pub fn set_shared_content_fault(&mut self, state: Option<SharedContentMigrationState>) {
        self.shared_content_fault_after = state;
    }

    fn check_shared_content_fault(
        &mut self,
        after: SharedContentMigrationState,
    ) -> Result<(), SharedContentMigrationError> {
        if self.shared_content_fault_after == Some(after) {
            self.shared_content_fault_after = None;
            return Err(SharedContentMigrationError::InjectedFault { after });
        }
        Ok(())
    }

    /// Whether the estate's Corpus lane must stay DARK (legacy lane present
    /// and the migration has not reached `Verified`).
    pub fn shared_content_lane_must_stay_dark(
        storage: &Arc<dyn Storage>,
        wired_fingerprint: Option<&str>,
    ) -> bool {
        let legacy = detect_legacy_layout(storage).is_some();
        let _ = storage.migrate(&SharedContentMigrationStore::schema_declaration());
        match SharedContentMigrationStore::new(Arc::clone(storage)).load() {
            Ok(Some(record)) => {
                // Any persisted record short of `verified` keeps the lane
                // dark — including post-retirement states where the legacy
                // tables are already gone and structural detection alone
                // would light a partially rebuilt lane.
                if record.state < SharedContentMigrationState::Verified {
                    return true;
                }
                if let Some(wired) = wired_fingerprint {
                    if record.ensemble_fingerprint.as_deref() != Some(wired) {
                        return true;
                    }
                }
                false
            }
            Ok(None) => legacy,
            Err(_) => legacy,
        }
    }

    /// The migration record's current state (None when no record exists).
    pub fn shared_content_migration_state(
        &self,
        handle: &EstateHandle,
    ) -> Option<SharedContentMigrationState> {
        let storage = self.storages.get(handle)?;
        let _ = storage.migrate(&SharedContentMigrationStore::schema_declaration());
        SharedContentMigrationStore::new(Arc::clone(storage))
            .load()
            .ok()
            .flatten()
            .map(|r| r.state)
    }

    /// Run the physical reclamation and mark the reclaim outcome (the P5
    /// completion hook). Idempotent: a record not in `ReclaimPending`
    /// returns Ok(None) without touching storage.
    ///
    /// The reclamation itself is the PersistenceKit maintenance pass (WAL
    /// checkpoint + VACUUM on SQLite) via `Storage::perform_maintenance` —
    /// call during a maintenance window; the pass requires quiescence and
    /// enough free disk for the live-page rewrite, and a failure leaves the
    /// record at `ReclaimPending` for retry. Backends whose maintenance is
    /// a no-op (in-memory, PostgreSQL) complete with their no-op report —
    /// the record still flips to `Complete`. Mirrors the Swift
    /// `completeSharedContentReclaim`.
    pub fn complete_shared_content_reclaim(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<Option<persistence_kit::maintenance::MaintenanceReport>, SharedContentMigrationError>
    {
        let Some(storage) = self.storages.get(handle) else {
            return Ok(None);
        };
        let store = SharedContentMigrationStore::new(Arc::clone(storage));
        let Some(mut record) = store.load()? else {
            return Ok(None);
        };
        if record.state != SharedContentMigrationState::ReclaimPending {
            return Ok(None);
        }
        let report = storage.perform_maintenance(None, None).map_err(|e| {
            SharedContentMigrationError::StorageFailure {
                state: SharedContentMigrationState::ReclaimPending,
                reason: e.to_string(),
            }
        })?;
        record.reclaimed_bytes = Some(report.reclaimed_bytes);
        // Trim the consumed evidence (P6): the deletion inventory and the
        // protected baseline exist to drive and verify the migration; once
        // physically reclaimed, only the outcome (state, counts, cursor,
        // reclaimed bytes) stays durable — a 110k-chunk / 1.1M-key estate
        // otherwise carries ~60 MB of record forever.
        record.legacy_chunk_count = Some(record.legacy_chunk_ids.len());
        record.legacy_vector_key_count = Some(record.legacy_vector_keys.len());
        record.legacy_chunk_ids = vec![];
        record.legacy_vector_keys = vec![];
        record.protected_baseline = BTreeMap::new();
        record.state = SharedContentMigrationState::Complete;
        store.save(&record, now_millis)?;
        Ok(Some(report))
    }

    /// Migration/reclaim status for the estate status/admin surface: the
    /// persisted state and estimates plus the LIVE reclaimable-bytes figure
    /// from the storage maintenance surface. Read-only; safe to poll.
    /// Mirrors the Swift `sharedContentReclaimStatus`.
    pub fn shared_content_reclaim_status(
        &self,
        handle: &EstateHandle,
    ) -> SharedContentReclaimStatus {
        let Some(storage) = self.storages.get(handle) else {
            return SharedContentReclaimStatus {
                state: None,
                estimated_reclaimable_bytes: None,
                reclaimed_bytes: None,
                live_reclaimable_bytes: None,
            };
        };
        let _ = storage.migrate(&SharedContentMigrationStore::schema_declaration());
        let record = SharedContentMigrationStore::new(Arc::clone(storage))
            .load()
            .ok()
            .flatten();
        let live = storage.estimated_reclaimable_bytes().ok();
        SharedContentReclaimStatus {
            state: record.as_ref().map(|r| r.state),
            estimated_reclaimable_bytes: record.as_ref().and_then(|r| r.estimated_reclaimable_bytes),
            reclaimed_bytes: record.as_ref().and_then(|r| r.reclaimed_bytes),
            live_reclaimable_bytes: live,
        }
    }

    /// Run (or resume) the shared-content migration. Idempotent and
    /// resumable from the persisted state.
    pub fn run_shared_content_migration(
        &mut self,
        handle: &EstateHandle,
        now_millis: i64,
        models: Vec<EmbeddingModelConfig>,
    ) -> Result<SharedContentMigrationReport, SharedContentMigrationError> {
        let wired_fingerprint = CorpusContentEngine::configuration_fingerprint_for(
            CorpusOperatingMode::Attached,
            &models,
        );
        let storage = self
            .storages
            .get(handle)
            .cloned()
            .ok_or(SharedContentMigrationError::StorageFailure {
                state: SharedContentMigrationState::Discovered,
                reason: "no storage registered for estate".to_string(),
            })?;
        let estate = self
            .estate_for(handle)
            .map_err(|e: GeniusLocusKitError| SharedContentMigrationError::StorageFailure {
                state: SharedContentMigrationState::Discovered,
                reason: format!("{e:?}"),
            })?
            .clone();
        let source = LocusDrawerContentSource::new(estate);
        storage
            .migrate(&SharedContentMigrationStore::schema_declaration())
            .map_err(|e| SharedContentMigrationError::StorageFailure {
                state: SharedContentMigrationState::Discovered,
                reason: format!("{e:?}"),
            })?;
        let store = SharedContentMigrationStore::new(Arc::clone(&storage));

        let mut record = match store.load()? {
            Some(existing) => existing,
            None => {
                let layout = detect_legacy_layout(&storage);
                let mut record = SharedContentMigrationRecord {
                    state: SharedContentMigrationState::Discovered,
                    detected_layout: layout.clone().unwrap_or_else(|| "fresh".to_string()),
                    legacy_chunk_ids: vec![],
                    legacy_vector_keys: vec![],
                    protected_baseline: BTreeMap::new(),
                    rebuild_cursor: None,
                    rebuilt_content_count: 0,
                    estimated_reclaimable_bytes: None,
                    reclaimed_bytes: None,
                    legacy_chunk_count: None,
                    legacy_vector_key_count: None,
                    ensemble_fingerprint: None,
                    provider_generations: None,
                };
                if layout.is_none() {
                    // Fresh estate: bypass — record the wired configuration
                    // so the bypass record is complete UNDER it (no phantom
                    // upgrade on the next run).
                    record.state = SharedContentMigrationState::Complete;
                    record.ensemble_fingerprint = Some(wired_fingerprint.clone());
                }
                store.save(&record, now_millis)?;
                self.check_shared_content_fault(record.state)?;
                record
            }
        };
        if record.state == SharedContentMigrationState::Complete {
            if record.ensemble_fingerprint.as_deref() == Some(wired_fingerprint.as_str()) {
                return Ok(report_for(&record));
            }
            // Follow-on ENSEMBLE UPGRADE: the completed record's recorded
            // configuration differs from the wired one. The structural
            // rebuild is intact; re-enter at the provider phases — train
            // what is missing, backfill only absent coverage, re-verify,
            // and restamp the fingerprint.
            eprintln!(
                "shared-content upgrade: recorded ensemble {:?} != wired {wired_fingerprint} — entering provider upgrade",
                record.ensemble_fingerprint
            );
            record.state = SharedContentMigrationState::DrawerIndexRebuilt;
            store.save(&record, now_millis)?;
        }

        // 2. canonicalValidated
        if record.state < SharedContentMigrationState::CanonicalValidated {
            let source_ids = legacy_source_ids(&storage)?;
            let mut orphans: Vec<String> = Vec::new();
            for id in &source_ids {
                let resolved = source.record(id).map_err(|e| {
                    SharedContentMigrationError::StorageFailure {
                        state: SharedContentMigrationState::CanonicalValidated,
                        reason: format!("{e:?}"),
                    }
                })?;
                if resolved.is_none() {
                    orphans.push(id.clone());
                }
            }
            if !orphans.is_empty() {
                orphans.sort();
                return Err(SharedContentMigrationError::OrphanedLegacySources {
                    ids: orphans,
                    state: SharedContentMigrationState::CanonicalValidated,
                });
            }
            record.state = SharedContentMigrationState::CanonicalValidated;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // 3. legacyInventoryCaptured
        if record.state < SharedContentMigrationState::LegacyInventoryCaptured {
            let chunk_ids = legacy_chunk_ids(&storage)?;
            let chunk_set: BTreeSet<String> = chunk_ids.iter().cloned().collect();
            record.legacy_vector_keys = legacy_vector_keys(&storage, &chunk_set)?;
            record.legacy_chunk_ids = chunk_ids;
            record.protected_baseline = protected_baseline(
                &storage,
                &record.legacy_vector_keys.iter().cloned().collect(),
            )?;
            record.state = SharedContentMigrationState::LegacyInventoryCaptured;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // 4. legacyDerivedCleared — exact-key vector deletes + wholesale
        //    clears on corpus-exclusive tables.
        if record.state < SharedContentMigrationState::LegacyDerivedCleared {
            let vector_store = VectorStore::new(
                Arc::clone(&storage),
                VectorStore::default_sidecar_path(&storage),
            );
            let mut exact: Vec<VectorExactKey> = Vec::new();
            for encoded in &record.legacy_vector_keys {
                let parts: Vec<&str> = encoded.split('|').collect();
                if parts.len() == 3 {
                    if let Ok(index) = parts[1].parse::<u32>() {
                        exact.push(VectorExactKey::new(parts[0], index, parts[2]));
                    }
                }
            }
            vector_store.delete_vectors(&exact).map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::LegacyDerivedCleared,
                    reason: format!("{e:?}"),
                }
            })?;
            // Rust BM25 sidecar shares the estate file on SQLite; clear via
            // the store handle.
            if let Ok(iix) = corpus_kit::InvertedIndexStore::open_for_storage(&storage) {
                let _ = iix.clear_all();
            }
            let _ = storage.migrate(&BasisStore::schema_declaration());
            let _ = BasisStore::new(Arc::clone(&storage)).delete_all();
            let _ = storage.migrate(&CorpusProviderCountsStore::schema_declaration());
            let _ = CorpusProviderCountsStore::new(Arc::clone(&storage)).delete_all();
            let _ = storage.migrate(&CorpusIndexStateStore::schema_declaration());
            let _ = CorpusIndexStateStore::new(Arc::clone(&storage)).clear_all();
            record.state = SharedContentMigrationState::LegacyDerivedCleared;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // 5. legacySchemaRetired — declared dropTable retirement + attached
        //    profile install.
        if record.state < SharedContentMigrationState::LegacySchemaRetired {
            storage
                .migrate(&retirement_declaration())
                .map_err(|e| SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::LegacySchemaRetired,
                    reason: format!("{e:?}"),
                })?;
            let _ = storage.migrate(&corpus_kit::attached_declaration());
            let _ = storage.migrate(&VectorRepresentationClaims::schema_declaration());
            record.state = SharedContentMigrationState::LegacySchemaRetired;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // The migration engine over the WIRED configuration (never a
        // hardcoded model set). Constructed AFTER schema retirement — an
        // earlier construction would load the legacy bases and mask the
        // untrained state — and reused by every provider phase. The
        // registered attached engine is reused when present.
        let engine: Option<Arc<CorpusContentEngine>> =
            if record.state < SharedContentMigrationState::Verified {
                let built = match self.corpus_kits.get(handle) {
                    Some(registered) => Arc::clone(registered),
                    None => Arc::new(
                        CorpusContentEngine::open(
                            Arc::clone(&storage),
                            CorpusContentConfiguration::new(
                                CorpusOperatingMode::Attached,
                                CorpusIndexUnitPolicy::WholeContent,
                            )
                            .map_err(|e| SharedContentMigrationError::StorageFailure {
                                state: SharedContentMigrationState::DrawerIndexRebuilt,
                                reason: format!("{e:?}"),
                            })?,
                            Arc::new(LocusDrawerContentSource::new(
                                self.estate_for(handle)
                                    .map_err(|e| SharedContentMigrationError::StorageFailure {
                                        state: SharedContentMigrationState::DrawerIndexRebuilt,
                                        reason: format!("{e:?}"),
                                    })?
                                    .clone(),
                            )),
                            models,
                        )
                        .map_err(|e| SharedContentMigrationError::StorageFailure {
                            state: SharedContentMigrationState::DrawerIndexRebuilt,
                            reason: format!("{e:?}"),
                        })?,
                    ),
                };
                Some(built)
            } else {
                None
            };

        // 6. drawerIndexRebuilt — streamed, cursor-checkpointed. STRUCTURAL
        //    only: BM25 + checkpoints + stateless-slot vectors; trainable
        //    slots are deferred to basesTrained + providersCovered.
        if record.state < SharedContentMigrationState::DrawerIndexRebuilt {
            let engine = engine.as_ref().expect("engine exists below Verified");
            let all_ids = source.active_content_ids().map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::DrawerIndexRebuilt,
                    reason: format!("{e:?}"),
                }
            })?;
            let resume_from = match &record.rebuild_cursor {
                Some(cursor) => all_ids.iter().position(|id| id > cursor).unwrap_or(all_ids.len()),
                None => 0,
            };
            // Deferred-index window (P6 scale fix): the engine's vector write
            // path rebuilds the resident binary index from the full snapshot
            // per call — O(n) per Drawer, quadratic over a 100k-drawer
            // rebuild (measured: throughput decayed from ~17/s to ~8/s within
            // the first 3k drawers of a 98k-drawer estate). The deferred
            // window makes every write O(batch) and rebuilds the resident
            // index ONCE at publish. Crash-safe: the vectors TABLE is the
            // durable source of truth; a crash inside the window loses only
            // the resident index, which the next open rebuilds from the
            // table, and the resumed run opens a fresh window.
            let deferred_vs = engine.shared_vector_store();
            deferred_vs.begin_deferred_index().map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::DrawerIndexRebuilt,
                    reason: format!("begin_deferred_index: {e:?}"),
                }
            })?;
            let mut processed = record.rebuilt_content_count;
            let mut since_checkpoint = 0usize;
            for id in &all_ids[resume_from..] {
                engine.index_content_structural(id, now_millis).map_err(|e| {
                    SharedContentMigrationError::StorageFailure {
                        state: SharedContentMigrationState::DrawerIndexRebuilt,
                        reason: format!("{e:?}"),
                    }
                })?;
                processed += 1;
                since_checkpoint += 1;
                if since_checkpoint >= 500 {
                    record.rebuild_cursor = Some(id.clone());
                    record.rebuilt_content_count = processed;
                    store.save(&record, now_millis)?;
                    since_checkpoint = 0;
                }
            }
            deferred_vs.publish_resident_index().map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::DrawerIndexRebuilt,
                    reason: format!("publish_resident_index: {e:?}"),
                }
            })?;
            record.rebuild_cursor = all_ids.last().cloned();
            record.rebuilt_content_count = processed;
            record.state = SharedContentMigrationState::DrawerIndexRebuilt;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // 7. basesTrained — stream-train every trainable provider lacking a
        //    current basis (bounded pages; per-provider atomic basis+counts
        //    commit). Restart-idempotent per provider.
        if record.state < SharedContentMigrationState::BasesTrained {
            let engine = engine.as_ref().expect("engine exists below Verified");
            engine.train_trainable_slots(now_millis, false).map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::BasesTrained,
                    reason: format!("{e:?}"),
                }
            })?;
            record.provider_generations =
                Some(engine.provider_generations().into_iter().collect());
            record.state = SharedContentMigrationState::BasesTrained;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // 8. providersCovered — backfill ONLY the missing (Drawer, provider)
        //    representations under each provider's CURRENT basis generation.
        //    The durable coverage rows are the resume authority: progress
        //    figures may lag them, never lead.
        if record.state < SharedContentMigrationState::ProvidersCovered {
            let engine = engine.as_ref().expect("engine exists below Verified");
            // Engine generations are the durable truth (atomic commits);
            // reconcile the record's bookkeeping to them on resume.
            record.provider_generations =
                Some(engine.provider_generations().into_iter().collect());
            let deferred_vs = engine.shared_vector_store();
            deferred_vs.begin_deferred_index().map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::ProvidersCovered,
                    reason: format!("begin_deferred_index: {e:?}"),
                }
            })?;
            engine.backfill_provider_coverage(now_millis, 500).map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::ProvidersCovered,
                    reason: format!("{e:?}"),
                }
            })?;
            deferred_vs.publish_resident_index().map_err(|e| {
                SharedContentMigrationError::StorageFailure {
                    state: SharedContentMigrationState::ProvidersCovered,
                    reason: format!("publish_resident_index: {e:?}"),
                }
            })?;
            record.state = SharedContentMigrationState::ProvidersCovered;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // 9. verified — structural checks PLUS per-provider coverage: every
        //    wired provider covers every active Drawer under its recorded
        //    basis generation.
        if record.state < SharedContentMigrationState::Verified {
            let engine_ref = engine.as_ref().expect("engine exists below Verified");
            verify(&record, &storage, &source, engine_ref)?;
            record.ensemble_fingerprint = Some(engine_ref.configuration_fingerprint());
            record.state = SharedContentMigrationState::Verified;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        // 10. reclaimPending — capture the live reclaimable estimate through
        //    the P5 maintenance surface (freelist pages × page size + WAL
        //    bytes; 0 on backends with nothing client-reclaimable).
        if record.state < SharedContentMigrationState::ReclaimPending {
            record.estimated_reclaimable_bytes = storage.estimated_reclaimable_bytes().ok();
            record.state = SharedContentMigrationState::ReclaimPending;
            store.save(&record, now_millis)?;
            self.check_shared_content_fault(record.state)?;
        }

        Ok(report_for(&record))
    }
}

fn report_for(record: &SharedContentMigrationRecord) -> SharedContentMigrationReport {
    SharedContentMigrationReport {
        state: record.state,
        legacy_chunk_count: record
            .legacy_chunk_count
            .unwrap_or(record.legacy_chunk_ids.len()),
        legacy_vector_key_count: record
            .legacy_vector_key_count
            .unwrap_or(record.legacy_vector_keys.len()),
        rebuilt_content_count: record.rebuilt_content_count,
        estimated_reclaimable_bytes: record.estimated_reclaimable_bytes,
    }
}

fn storage_failure(
    state: SharedContentMigrationState,
    e: impl std::fmt::Debug,
) -> SharedContentMigrationError {
    SharedContentMigrationError::StorageFailure {
        state,
        reason: format!("{e:?}"),
    }
}

fn legacy_source_ids(
    storage: &Arc<dyn Storage>,
) -> Result<Vec<String>, SharedContentMigrationError> {
    let rows = storage
        .row_store()
        .query("chunks", None, &[], None, None)
        .map_err(|e| storage_failure(SharedContentMigrationState::CanonicalValidated, e))?;
    let mut out: BTreeSet<String> = BTreeSet::new();
    for row in &rows {
        if let Some(TypedValue::Text(source_id)) = row.get("source_id") {
            out.insert(source_id.clone());
        }
    }
    Ok(out.into_iter().collect())
}

fn legacy_chunk_ids(
    storage: &Arc<dyn Storage>,
) -> Result<Vec<String>, SharedContentMigrationError> {
    let rows = storage
        .row_store()
        .query("chunks", None, &[], None, None)
        .map_err(|e| storage_failure(SharedContentMigrationState::LegacyInventoryCaptured, e))?;
    let mut out: Vec<String> = Vec::new();
    for row in &rows {
        match row.get("id") {
            Some(TypedValue::Uuid(id)) => out.push(id.to_string().to_uppercase()),
            Some(TypedValue::Text(id)) => out.push(id.to_uppercase()),
            _ => {}
        }
    }
    out.sort();
    Ok(out)
}

fn legacy_vector_keys(
    storage: &Arc<dyn Storage>,
    chunk_ids: &BTreeSet<String>,
) -> Result<Vec<String>, SharedContentMigrationError> {
    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .map_err(|e| storage_failure(SharedContentMigrationState::LegacyInventoryCaptured, e))?;
    let mut out: Vec<String> = Vec::new();
    for row in &rows {
        let (Some(TypedValue::Text(item_id)), Some(TypedValue::Int(vector_index)), Some(TypedValue::Text(model_id))) =
            (row.get("item_id"), row.get("vector_index"), row.get("model_id"))
        else {
            continue;
        };
        if chunk_ids.contains(&item_id.to_uppercase()) {
            out.push(format!("{item_id}|{vector_index}|{model_id}"));
        }
    }
    out.sort();
    Ok(out)
}

fn protected_baseline(
    storage: &Arc<dyn Storage>,
    legacy_vector_keys: &BTreeSet<String>,
) -> Result<BTreeMap<String, String>, SharedContentMigrationError> {
    let mut baseline: BTreeMap<String, String> = BTreeMap::new();
    let inventory = persistence_kit::capture_inventory(
        storage,
        &["drawers", "associations"],
        &BTreeMap::new(),
    )
    .map_err(|e| storage_failure(SharedContentMigrationState::LegacyInventoryCaptured, e))?;
    for entry in inventory {
        baseline.insert(entry.table, entry.content_fold);
    }
    baseline.insert(
        "vectors:protected".to_string(),
        protected_vectors_fold(storage, legacy_vector_keys)?,
    );
    Ok(baseline)
}

fn protected_vectors_fold(
    storage: &Arc<dyn Storage>,
    excluded_keys: &BTreeSet<String>,
) -> Result<String, SharedContentMigrationError> {
    // Pin the DECLARED VectorKit schema before reading (P6 scale finding):
    // row decode forms depend on the connection's accumulated schema view,
    // and the baseline capture runs BEFORE any engine has declared the
    // vectors schema while verification runs AFTER — same bytes decoded
    // through different views fold differently and fail verification as a
    // false positive. Idempotent migrate makes both folds read through the
    // same declared view. Mirrors the Swift twin.
    storage
        .migrate(&VectorStore::schema_declaration())
        .map_err(|e| storage_failure(SharedContentMigrationState::LegacyInventoryCaptured, e))?;
    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .map_err(|e| storage_failure(SharedContentMigrationState::LegacyInventoryCaptured, e))?;
    let mut combined: u64 = 0;
    let excluded_cols: BTreeSet<String> = ["id"].iter().map(|s| s.to_string()).collect();
    for row in &rows {
        let (Some(TypedValue::Text(item_id)), Some(TypedValue::Int(vector_index)), Some(TypedValue::Text(model_id))) =
            (row.get("item_id"), row.get("vector_index"), row.get("model_id"))
        else {
            continue;
        };
        let key = format!("{item_id}|{vector_index}|{model_id}");
        if excluded_keys.contains(&key) {
            continue;
        }
        let encoded = persistence_kit::database_inventory::canonical_row_encoding(row, &excluded_cols);
        let hash = persistence_kit::layout_signature::fnv1a64_fold(
            encoded.as_bytes(),
            persistence_kit::layout_signature::FNV1A64_OFFSET_BASIS,
        );
        combined = combined.wrapping_add(hash);
    }
    Ok(format!("{combined:016x}"))
}

fn verify(
    record: &SharedContentMigrationRecord,
    storage: &Arc<dyn Storage>,
    source: &LocusDrawerContentSource,
    engine: &CorpusContentEngine,
) -> Result<(), SharedContentMigrationError> {
    let row_store = storage.row_store();
    if row_store.count("chunks", None).is_ok() {
        return Err(SharedContentMigrationError::VerificationFailed {
            reason: "legacy chunks table still present after retirement".to_string(),
        });
    }
    if row_store.count("corpus_metadata", None).is_ok() {
        return Err(SharedContentMigrationError::VerificationFailed {
            reason: "legacy corpus_metadata table still present after retirement".to_string(),
        });
    }
    let active_ids: BTreeSet<String> = source
        .active_content_ids()
        .map_err(|e| storage_failure(SharedContentMigrationState::Verified, e))?
        .into_iter()
        .collect();
    let legacy_chunks: BTreeSet<&String> = record.legacy_chunk_ids.iter().collect();
    let vector_rows = row_store
        .query("vectors", None, &[], None, None)
        .map_err(|e| storage_failure(SharedContentMigrationState::Verified, e))?;
    for row in &vector_rows {
        if let Some(TypedValue::Text(item_id)) = row.get("item_id") {
            if legacy_chunks.contains(&item_id.to_uppercase()) {
                return Err(SharedContentMigrationError::VerificationFailed {
                    reason: format!("chunk-keyed vector survived the selective delete: {item_id}"),
                });
            }
        }
    }
    let index_state = CorpusIndexStateStore::new(Arc::clone(storage));
    let indexed: BTreeSet<String> = index_state
        .all_states()
        .map_err(|e| storage_failure(SharedContentMigrationState::Verified, e))?
        .into_iter()
        .map(|s| s.content_id)
        .filter(|id| !id.starts_with('\u{1F}'))
        .collect();
    if !active_ids.is_subset(&indexed) {
        let missing: Vec<String> = active_ids.difference(&indexed).take(5).cloned().collect();
        return Err(SharedContentMigrationError::VerificationFailed {
            reason: format!("rebuild coverage gap — unindexed drawers: {}", missing.join(", ")),
        });
    }
    // Per-provider coverage: every wired provider must cover every active
    // Drawer under its CURRENT basis generation, and every trainable
    // provider must actually be trained (unless the estate is empty —
    // providers train at first ingest). The migration is not complete
    // while any configured lane is dark.
    for (model_id, basis_digest) in engine.provider_generations() {
        if basis_digest.is_empty() && !active_ids.is_empty() {
            return Err(SharedContentMigrationError::VerificationFailed {
                reason: format!("provider {model_id} is untrained after basesTrained"),
            });
        }
        let covered = engine
            .covered_count(&model_id)
            .map_err(|e| storage_failure(SharedContentMigrationState::Verified, e))?
            .unwrap_or(0);
        if covered < active_ids.len() {
            return Err(SharedContentMigrationError::VerificationFailed {
                reason: format!(
                    "provider {model_id} covers {covered}/{} drawers",
                    active_ids.len()
                ),
            });
        }
    }
    // Protected tables refold identically.
    let current = protected_baseline(storage, &BTreeSet::new())?;
    for (table, fold) in &record.protected_baseline {
        if table == "vectors:protected" {
            continue;
        }
        if current.get(table) != Some(fold) {
            return Err(SharedContentMigrationError::VerificationFailed {
                reason: format!("protected table {table} changed during migration"),
            });
        }
    }
    // Protected vector rows: exclude the rebuild's corpus-claimed rows and
    // the fold must equal the baseline.
    if let Some(baseline_fold) = record.protected_baseline.get("vectors:protected") {
        let claims = VectorRepresentationClaims::new(Arc::clone(storage));
        let corpus_models: BTreeSet<String> = claims
            .claims(corpus_kit::CLAIMS_CONSUMER)
            .map_err(|e| storage_failure(SharedContentMigrationState::Verified, e))?
            .into_iter()
            .map(|k| k.model_id)
            .collect();
        let rebuilt: BTreeSet<String> = indexed;
        let mut exclusions: BTreeSet<String> = BTreeSet::new();
        for row in &vector_rows {
            let (Some(TypedValue::Text(item_id)), Some(TypedValue::Int(vector_index)), Some(TypedValue::Text(model_id))) =
                (row.get("item_id"), row.get("vector_index"), row.get("model_id"))
            else {
                continue;
            };
            if rebuilt.contains(item_id) && corpus_models.contains(model_id) {
                exclusions.insert(format!("{item_id}|{vector_index}|{model_id}"));
            }
        }
        let refold = protected_vectors_fold(storage, &exclusions)?;
        if &refold != baseline_fold {
            return Err(SharedContentMigrationError::VerificationFailed {
                reason: "shared/unrelated vector bytes changed during migration".to_string(),
            });
        }
    }
    Ok(())
}
