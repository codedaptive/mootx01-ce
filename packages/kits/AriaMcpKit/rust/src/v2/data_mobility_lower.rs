//! Direct Rust lower adapter for the M02 data-mobility surface.
//!
//! This adapter has no v1 dispatch dependency. It uses the typed VaultKit
//! snapshots exposed by `vault_tools` and deliberately refuses the operations
//! whose only current Rust implementation remains a private v1 runner.

use std::path::Path;

use locus_kit::drawer_operational::ContentKind;

use crate::estate_registry::{EstateRegistry, OpenEstate};
use crate::interface_tools::{
    classify_contents_in_parallel, normalized_fdc_code, normalized_qid,
    should_repair_fdc_anchor, FdcReclassifyMode,
    DEFAULT_LATTICE_CODE, FDC_RECALCED_DATA_VERSION_META_KEY,
};

use super::data_mobility::{
    V2DataMobilityAdmission, V2DataMobilityLower, V2DatasetFiled,
    V2DatasetQueryRequest, V2DatasetQueryResult, V2DatasetStatsRequest,
    V2DatasetStatsResult, V2DatasetSensitivity, V2FdcReclassifyChange,
    V2FdcReclassifyMode, V2FileDatasetRequest, V2JsonImportReport,
    V2ImportMode, V2JsonImportRequest, V2PalaceImportReport, V2PalaceImportRequest,
    V2ReclassifyFdcReport, V2ReclassifyFdcRequest, V2ReindexRequest,
    V2ReindexState, V2VaultCandidate, V2VaultExportRequest,
    V2VaultExportResult, V2VaultImportRequest, V2VaultImportResult,
    V2VaultJobRequest, V2VaultJobResult, V2VaultReconcileRequest,
    V2VaultReconcileResult, V2VaultStatusRequest, V2VaultStatusResult,
};

/// Direct selected-estate adapter for the lower operations that already expose
/// typed Rust receipts. The selected surface retains admission and revalidation;
/// this type only uses the estate admitted for the current request.
pub struct DirectDataMobilityLower<'a> {
    registry: &'a EstateRegistry,
}

impl<'a> DirectDataMobilityLower<'a> {
    pub const fn new(registry: &'a EstateRegistry) -> Self {
        Self { registry }
    }

    fn selected_open(&self, admission: &V2DataMobilityAdmission) -> Result<&OpenEstate, ()> {
        let open = &self.registry.default;
        (open.estate_id == admission.estate_id).then_some(open).ok_or(())
    }
}

impl V2DataMobilityLower for DirectDataMobilityLower<'_> {
    fn reindex(
        &self,
        admission: &V2DataMobilityAdmission,
        _: &V2ReindexRequest,
    ) -> Result<V2ReindexState, ()> {
        let open = self.selected_open(admission)?;
        match crate::interface_tools::start_reindex(open, admission.now_millis).map_err(|_| ())? {
            crate::interface_tools::ReindexLaunch::Running => Ok(V2ReindexState::Running),
        }
    }

    fn reclassify_fdc(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2ReclassifyFdcRequest,
    ) -> Result<V2ReclassifyFdcReport, ()> {
        let open = self.selected_open(admission)?;
        let apply = request.apply;
        // Convert from the v2 request enum to the shared FdcReclassifyMode.
        // Both enums carry identical semantics; the split exists because
        // data_mobility.rs is imported via `#[path = "..."]` in the unit
        // test and cannot access `crate::interface_tools`.
        let mode = match request.mode {
            V2FdcReclassifyMode::SuspectOnly => FdcReclassifyMode::SuspectOnly,
            V2FdcReclassifyMode::All => FdcReclassifyMode::All,
        };

        // FDC version strings from the pinned artifact bundle. Both methods
        // return `&'static str`; we own String in the report so convert here.
        let fdc_data_version = lattice_lib::Fdc::data_version().to_string();
        let fdc_recalculation_version = lattice_lib::Fdc::recalculation_version().to_string();

        // Read the stored estate floor before the scan.
        let prior_floor = open.store
            .get_meta(FDC_RECALCED_DATA_VERSION_META_KEY)
            .map_err(|_| ())?;

        // Load all active, classifiable drawers. Dataset handles carry
        // structured JSON rather than free text — classifying them corrupts
        // their DatasetHandleContent payload (MX-TAB-4 locked decision).
        let drawers = {
            let coord = open.coord.lock().unwrap();
            coord.all_drawers(&open.handle).map_err(|_| ())?
        };
        let mut active: Vec<_> = drawers
            .into_iter()
            .filter(|d| {
                d.tombstoned_at.is_none()
                    && d.is_currently_believed()
                    && d.content_kind() != ContentKind::Dataset
            })
            .collect();
        // Apply the limit cap before classification so the parallel pass
        // never classifies drawers that won't enter the candidate loop.
        if let Some(limit) = request.limit {
            active.truncate(limit);
        }

        // Phase A — PARALLEL classify. classify_contents_in_parallel returns
        // anchors in the same order as `active`, so the serial Phase B loop
        // below produces byte-identical output to a serial classify.
        let inputs: Vec<(&str, lattice_lib::FdcContentKind)> = active.iter().map(|d| {
            let kind = if d.content_kind() == ContentKind::Code {
                lattice_lib::FdcContentKind::Code
            } else {
                lattice_lib::FdcContentKind::Text
            };
            (d.content.as_str(), kind)
        }).collect();
        let anchors = classify_contents_in_parallel(&inputs);

        // Phase B — SERIAL, ORDERED scan and optional audited write.
        let mut scanned = 0u64;
        let mut empty_content = 0u64;
        let mut unchanged = 0u64;
        let mut candidate_count = 0u64;
        let mut applied_count = 0u64;
        let mut skipped_non_candidate_changes = 0u64;
        let mut unclassified_after = 0u64;
        let mut change_list: Vec<V2FdcReclassifyChange> = Vec::new();

        for (index, drawer) in active.iter().enumerate() {
            scanned += 1;
            if drawer.content.trim().is_empty() {
                empty_content += 1;
            }

            let old_code = normalized_fdc_code(&drawer.udc_code);
            let old_qid = normalized_qid(drawer.wikidata_qid.as_deref());
            let anchor = &anchors[index];
            let new_code = normalized_fdc_code(&anchor.code);
            let new_qid = normalized_qid(anchor.wikidata_qid.as_deref());

            if old_code == new_code && old_qid == new_qid {
                unchanged += 1;
                continue;
            }
            if !should_repair_fdc_anchor(mode, &old_code, old_qid.as_deref(), &new_code, new_qid.as_deref()) {
                skipped_non_candidate_changes += 1;
                continue;
            }

            candidate_count += 1;
            if new_code == DEFAULT_LATTICE_CODE {
                unclassified_after += 1;
            }
            if change_list.len() < 25 {
                change_list.push(V2FdcReclassifyChange {
                    id: drawer.id.clone(),
                    old_code: old_code.clone(),
                    new_code: new_code.clone(),
                    old_qid: old_qid.clone(),
                    new_qid: new_qid.clone(),
                });
            }

            if apply {
                // Repair only the primary udc_code and wikidata_qid from
                // the re-lookup. udc_facets and wikidata_qids_secondary are
                // carried forward unchanged — FDC re-lookup has no opinion on
                // secondary classification, so a reclassify apply must not
                // silently wipe facets or secondary QIDs a human or the
                // enrichment daemon attached. Per data contract §6.
                let new_anchor = locus_kit::estate_types::LatticeAnchor::new(
                    new_code,
                    drawer.udc_facets.clone(),
                    new_qid,
                    drawer.wikidata_qids_secondary.clone(),
                );
                let coord = open.coord.lock().unwrap();
                // reanchor_anchor (not the generic reanchor) so the audit event
                // names this tool as the actor with a tool-specific reason string,
                // matching Swift's reanchorAnchor changedBy: serverIdentity
                // reason: "FDC reclassified via moot_reclassify_fdc". The generic
                // coord.reanchor path stamps the estate owner and a generic reason,
                // misattributing this automated repair in the audit trail.
                coord.reanchor_anchor(
                    &open.handle,
                    &drawer.id,
                    new_anchor,
                    self.registry.server_identity.as_str(),
                    "FDC reclassified via moot_reclassify_fdc",
                ).map_err(|_| ())?;
                applied_count += 1;
            }
        }

        // Floor stamp: only case 1 writes the key. Cases 2–5 leave the stored
        // floor untouched. Selection order matches data contract §4.
        let mut floor_after = prior_floor.clone();
        let floor_stamp = if apply
            && mode == FdcReclassifyMode::All
            && request.limit.is_none()
            && skipped_non_candidate_changes == 0
        {
            open.coord.lock().unwrap()
                .stamp_fdc_recalculation_floor(&open.handle, &fdc_recalculation_version)
                .map_err(|_| ())?;
            floor_after = Some(fdc_recalculation_version.clone());
            "stamped".to_owned()
        } else if !apply {
            "dry-run".to_owned()
        } else if request.limit.is_some() {
            "skipped: limited run cannot update estate-wide floor".to_owned()
        } else if mode != FdcReclassifyMode::All {
            "skipped: mode=all is required for an estate-wide floor".to_owned()
        } else {
            "skipped: changed non-suspect anchors remain".to_owned()
        };

        let changes_omitted = candidate_count.saturating_sub(change_list.len() as u64);
        Ok(V2ReclassifyFdcReport {
            applied: apply,
            mode: mode.as_str().to_owned(),
            estate_id: open.estate_id,
            estate_name: open.estate_name.clone(),
            fdc_data_version,
            fdc_recalculation_version,
            // Carry the request limit so the compact-text builder can emit
            // " (limit N)" on the "scanned:" line, matching Swift:588+596.
            limit: request.limit.map(|l| l as u64),
            scanned,
            unchanged,
            empty_content,
            candidates: candidate_count,
            updated: applied_count,
            would_update: if apply { 0 } else { candidate_count },
            unclassified_after,
            skipped_non_candidate_changes,
            floor_stamp,
            estate_recalced_data_version_before: prior_floor,
            estate_recalced_data_version_after: floor_after,
            changes: change_list,
            changes_omitted,
        })
    }

    fn palace_import(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2PalaceImportRequest,
    ) -> Result<V2PalaceImportReport, ()> {
        let open = self.selected_open(admission)?;
        let mode = match request.mode.unwrap_or(V2ImportMode::Foreground) {
            V2ImportMode::Foreground => genius_locus_kit::EncodeSpeed::Foreground,
            V2ImportMode::Background => genius_locus_kit::EncodeSpeed::Background,
        };
        let receipt = crate::interface_tools::import_palace(
            open,
            Path::new(&request.palace_path),
            mode,
            admission.now_millis,
        ).map_err(|_| ())?;
        Ok(V2PalaceImportReport {
            drawers_written: u64::try_from(receipt.drawers_written).map_err(|_| ())?,
            drawers_updated: u64::try_from(receipt.drawers_updated).map_err(|_| ())?,
            drawers_skipped_unchanged: u64::try_from(receipt.drawers_skipped_unchanged).map_err(|_| ())?,
            drawers_skipped_tombstoned: u64::try_from(receipt.drawers_skipped_tombstoned).map_err(|_| ())?,
            drawers_skipped_partial_write: u64::try_from(receipt.drawers_skipped_partial_write).map_err(|_| ())?,
            tunnels_created: u64::try_from(receipt.tunnels_created).map_err(|_| ())?,
            items_skipped: u64::try_from(receipt.items_skipped).map_err(|_| ())?,
            fdc_classified: u64::try_from(receipt.fdc_classified).map_err(|_| ())?,
            fdc_unclassified: u64::try_from(receipt.fdc_unclassified).map_err(|_| ())?,
            fields_dropped: receipt.fields_dropped.into_iter()
                .map(|(field, count)| u64::try_from(count).map(|count| (field, count)))
                .collect::<Result<_, _>>().map_err(|_| ())?,
            enqueued_for_encode: u64::try_from(receipt.enqueued_for_encode).map_err(|_| ())?,
        })
    }

    fn json_import(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2JsonImportRequest,
    ) -> Result<V2JsonImportReport, ()> {
        let open = self.selected_open(admission)?;
        let receipt = crate::interface_tools::import_json_seed(
            open,
            Path::new(&request.path),
            None,
            genius_locus_kit::EncodeSpeed::Foreground,
            admission.now_millis,
        ).map_err(|_| ())?;
        let id_map = receipt.drawer_id_by_record_id.into_iter()
            .map(|(record_id, drawer_id)| {
                uuid::Uuid::parse_str(&drawer_id).map(|drawer_id| (record_id, drawer_id))
            })
            .collect::<Result<_, _>>().map_err(|_| ())?;
        Ok(V2JsonImportReport {
            seed_name: receipt.seed_name,
            drawers_written: u64::try_from(receipt.drawers_written).map_err(|_| ())?,
            facts_written: u64::try_from(receipt.facts_written).map_err(|_| ())?,
            tunnels_created: u64::try_from(receipt.tunnels_created).map_err(|_| ())?,
            enqueued_for_encode: u64::try_from(receipt.enqueued_for_encode).map_err(|_| ())?,
            subjects_provided: u64::try_from(receipt.subjects_provided).map_err(|_| ())?,
            subjects_debt: u64::try_from(receipt.subjects_debt).map_err(|_| ())?,
            seed_sha256: receipt.seed_sha256,
            id_map: Some(id_map),
        })
    }

    fn file_dataset(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2FileDatasetRequest,
    ) -> Result<V2DatasetFiled, ()> {
        let open = self.selected_open(admission)?;
        let sensitivity_raw = match request.sensitivity.unwrap_or(V2DatasetSensitivity::Normal) {
            V2DatasetSensitivity::Normal => 0,
            V2DatasetSensitivity::Elevated => 16,
            V2DatasetSensitivity::Restricted => 32,
            V2DatasetSensitivity::Secret => 48,
        };
        let snapshot = crate::dataset_tools::file_dataset_snapshot(open, crate::dataset_tools::DatasetFileInput {
            name: &request.name,
            location: &request.location,
            columns: request.columns.as_deref(),
            rows: request.rows.as_deref(),
            csv_path: request.csv_path.as_deref(),
            wing: request.wing.as_deref(),
            sensitivity_raw,
            now_millis: admission.now_millis,
        }).map_err(|_| ())?;
        Ok(V2DatasetFiled {
            dataset_id: snapshot.dataset_id,
            handle_memory_id: uuid::Uuid::parse_str(&snapshot.handle_memory_id).map_err(|_| ())?,
            name: snapshot.name,
            location: snapshot.location,
            wing: snapshot.wing,
            columns: u64::try_from(snapshot.columns).map_err(|_| ())?,
            rows: u64::try_from(snapshot.rows).map_err(|_| ())?,
            source: snapshot.source,
            sensitivity: snapshot.sensitivity,
            signatures: snapshot.signatures,
        })
    }

    fn dataset_query(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2DatasetQueryRequest,
    ) -> Result<V2DatasetQueryResult, ()> {
        let open = self.selected_open(admission)?;
        let snapshot = crate::dataset_tools::dataset_query_snapshot(
            open,
            request.dataset_id,
            request.where_clause.as_ref(),
            request.order_by.as_deref(),
            request.limit,
            request.columns.as_deref(),
        ).map_err(|_| ())?;
        Ok(V2DatasetQueryResult {
            dataset_id: snapshot.dataset_id,
            handle_memory_id: uuid::Uuid::parse_str(&snapshot.handle_memory_id).map_err(|_| ())?,
            state: snapshot.state,
            sensitivity: snapshot.sensitivity,
            rows_returned: u64::try_from(snapshot.rows_returned).map_err(|_| ())?,
            limit: u64::try_from(snapshot.limit).map_err(|_| ())?,
            rows: snapshot.rows,
            columns: snapshot.columns,
            handle_row_count: snapshot.handle_row_count.map(u64::try_from).transpose().map_err(|_| ())?,
        })
    }

    fn dataset_stats(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2DatasetStatsRequest,
    ) -> Result<V2DatasetStatsResult, ()> {
        let open = self.selected_open(admission)?;
        let snapshot = crate::dataset_tools::dataset_stats_snapshot(
            open, request.dataset_id, request.column.as_deref(),
        ).map_err(|_| ())?;
        Ok(V2DatasetStatsResult {
            dataset_id: snapshot.dataset_id,
            handle_memory_id: uuid::Uuid::parse_str(&snapshot.handle_memory_id).map_err(|_| ())?,
            stats: snapshot.stats.into_iter().map(|(column, stat)| Ok((column, super::data_mobility::V2DatasetColumnStats {
                count: u64::try_from(stat.count).map_err(|_| ())?,
                distinct_count: u64::try_from(stat.distinct_count).map_err(|_| ())?,
                null_count: u64::try_from(stat.null_count).map_err(|_| ())?,
                min: stat.min,
                max: stat.max,
            }))).collect::<Result<_, ()>>()?,
        })
    }

    fn vault_export(
        &self,
        _: &V2DataMobilityAdmission,
        _: &V2VaultExportRequest,
    ) -> Result<V2VaultExportResult, ()> {
        Err(())
    }

    fn vault_import(
        &self,
        _: &V2DataMobilityAdmission,
        _: &V2VaultImportRequest,
    ) -> Result<V2VaultImportResult, ()> {
        Err(())
    }

    fn vault_status(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2VaultStatusRequest,
    ) -> Result<V2VaultStatusResult, ()> {
        self.selected_open(admission)?;
        let snapshot = crate::vault_tools::vault_status_snapshot(Path::new(&request.vault_path))
            .map_err(|_| ())?;
        Ok(V2VaultStatusResult {
            manifest_present: snapshot.manifest_present,
            path: snapshot.path,
            last_export: snapshot.last_export,
            note_count: snapshot.note_count,
        })
    }

    fn vault_reconcile(
        &self,
        admission: &V2DataMobilityAdmission,
        request: &V2VaultReconcileRequest,
    ) -> Result<V2VaultReconcileResult, ()> {
        let open = self.selected_open(admission)?;
        let snapshot = crate::vault_tools::vault_reconcile_snapshot(
            open,
            Path::new(&request.vault_path),
            request.apply.unwrap_or(false),
        ).map_err(|_| ())?;
        Ok(V2VaultReconcileResult {
            added: snapshot.added,
            modified: snapshot.modified,
            deleted: snapshot.deleted,
            missing: snapshot.missing,
            import_set_count: snapshot.import_set_count,
            candidate_count: snapshot.candidate_count,
            missing_count: snapshot.missing_count,
            applied: snapshot.applied,
            candidates: snapshot.candidates.map(|candidates| candidates.into_iter().map(|candidate| {
                V2VaultCandidate {
                    stable_source_key: candidate.stable_source_key,
                    vault_path: candidate.vault_path,
                    sha256: candidate.sha256,
                }
            }).collect()),
        })
    }

    fn vault_job(
        &self,
        _: &V2DataMobilityAdmission,
        _: &V2VaultJobRequest,
    ) -> Result<V2VaultJobResult, ()> {
        Err(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jsonrpc::JsonValue;
    use std::collections::BTreeMap;
    use uuid::Uuid;

    fn admission(registry: &EstateRegistry) -> V2DataMobilityAdmission {
        V2DataMobilityAdmission {
            estate_id: registry.default.estate_id,
            estate_handle: registry.default.handle,
            caller_binding: "test".to_owned(),
            authorization_generation: "test".to_owned(),
            now_millis: 0,
        }
    }

    #[test]
    fn reclassify_uses_the_direct_fixed_dry_run_seam() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        let report =
            lower.reclassify_fdc(
                &admission(&registry),
                &V2ReclassifyFdcRequest {
                    estate_id: None,
                    apply: false,
                    mode: V2FdcReclassifyMode::SuspectOnly,
                    limit: None,
                },
            ).expect("empty estate has a valid typed dry-run report");
        assert!(!report.applied);
        assert_eq!(report.mode, "suspectOnly");
        assert_eq!(report.scanned, 0);
        assert_eq!(report.updated, 0);
    }

    #[test]
    fn reindex_starts_through_the_direct_selected_estate_seam() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        assert_eq!(
            lower.reindex(&admission(&registry), &V2ReindexRequest { estate_id: None }),
            Ok(V2ReindexState::Running),
        );
    }

    #[test]
    fn dataset_file_query_and_stats_use_direct_typed_seams() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        let admitted = admission(&registry);
        let filed = lower.file_dataset(
            &admitted,
            &V2FileDatasetRequest {
                name: "fruit-scores".to_owned(),
                location: "lab/produce".to_owned(),
                columns: Some(vec![
                    JsonValue::from(serde_json::json!({"name":"label","type":"text"})),
                    JsonValue::from(serde_json::json!({"name":"score","type":"int"})),
                ]),
                rows: Some(vec![
                    JsonValue::from(serde_json::json!({"label":"apple","score":95})),
                    JsonValue::from(serde_json::json!({"label":"banana","score":80})),
                ]),
                csv_path: None,
                wing: None,
                sensitivity: None,
                estate_id: None,
            },
        ).expect("typed file_dataset");
        assert_eq!(filed.columns, 2);
        assert_eq!(filed.rows, 2);

        let query = lower.dataset_query(
            &admitted,
            &V2DatasetQueryRequest {
                dataset_id: filed.dataset_id,
                where_clause: Some(BTreeMap::from([
                    ("col".to_owned(), JsonValue::String("score".to_owned())),
                    ("op".to_owned(), JsonValue::String("gte".to_owned())),
                    ("val".to_owned(), JsonValue::Integer(90)),
                ])),
                order_by: None,
                limit: Some(1000),
                columns: Some(vec![JsonValue::String("label".to_owned())]),
                estate_id: None,
            },
        ).expect("typed dataset_query");
        assert_eq!(query.rows_returned, 1);
        assert_eq!(query.rows[0].get("label"), Some(&JsonValue::String("apple".to_owned())));

        let stats = lower.dataset_stats(
            &admitted,
            &V2DatasetStatsRequest {
                dataset_id: filed.dataset_id,
                column: Some("score".to_owned()),
                estate_id: None,
            },
        ).expect("typed dataset_stats");
        assert_eq!(stats.stats["score"].count, 2);
    }

    #[test]
    fn selected_dataset_filing_refuses_quiesced_handle_before_creating_a_handle() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        let admitted = admission(&registry);
        {
            let mut coordinator = registry.default.coord.lock().unwrap();
            coordinator
                .quiesce(&registry.default.handle)
                .expect("quiesce selected estate");
        }

        let filing = lower.file_dataset(
            &admitted,
            &V2FileDatasetRequest {
                name: "must-not-file".to_owned(),
                location: "lab/blocked".to_owned(),
                columns: Some(vec![JsonValue::from(serde_json::json!({"name":"label","type":"text"}))]),
                rows: Some(vec![JsonValue::from(serde_json::json!({"label":"blocked"}))]),
                csv_path: None,
                wing: None,
                sensitivity: None,
                estate_id: None,
            },
        );
        assert_eq!(filing, Err(()), "typed filing must reject before DDL/handle capture");
        let coordinator = registry.default.coord.lock().unwrap();
        let estate = coordinator
            .estate_for(&registry.default.handle)
            .expect("quiesced estate remains readable for regression inspection");
        assert!(estate.all_drawers().expect("drawer inventory").is_empty(),
            "quiesced selected filing must not create a dataset handle");
    }

    #[test]
    fn direct_imports_preserve_source_missing_path_behavior() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        let missing = std::env::temp_dir().join(format!("aria-v2-missing-{}", Uuid::new_v4()));
        let palace = lower.palace_import(
            &admission(&registry),
            &V2PalaceImportRequest {
                palace_path: missing.display().to_string(),
                mode: Some(V2ImportMode::Foreground),
                estate_id: None,
            },
        ).expect("PalaceBridge treats a missing root as an empty import");
        assert_eq!(palace.drawers_written, 0);
        assert_eq!(palace.enqueued_for_encode, 0);
        assert_eq!(
            lower.json_import(
                &admission(&registry),
                &V2JsonImportRequest {
                    path: missing.display().to_string(),
                    estate_id: None,
                    return_id_map: false,
                },
            ),
            Err(()),
        );
    }

    #[test]
    fn json_import_malformed_source_then_corrected_retry_writes_once() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        let path = std::env::temp_dir().join(format!("aria-v2-json-retry-{}.json", Uuid::new_v4()));
        std::fs::write(&path, "{not-json").expect("write malformed seed");
        let request = V2JsonImportRequest { path: path.display().to_string(), estate_id: None, return_id_map: false };
        assert_eq!(lower.json_import(&admission(&registry), &request), Err(()));
        std::fs::write(&path, r#"{"format_version":1,"name":"retry","records":[{"id":"once","content":"corrected retry","event_time":"2026-09-09T00:00:00Z","room":"handoff/room","exportability":"public"}]}"#)
            .expect("write corrected seed");
        let report = lower.json_import(&admission(&registry), &request);
        let _ = std::fs::remove_file(&path);
        let report = report.expect("corrected retry imports");
        assert_eq!(report.drawers_written, 1);
        let id_map = report.id_map.expect("direct import retains record-to-drawer receipt");
        assert_eq!(id_map.len(), 1);
        assert!(id_map.contains_key("once"));
    }

    #[test]
    fn vault_status_projects_the_direct_manifest_snapshot() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        let path = std::env::temp_dir().join(format!("aria-v2-missing-{}", Uuid::new_v4()));
        let result = lower.vault_status(
            &admission(&registry),
            &V2VaultStatusRequest { vault_path: path.display().to_string() },
        ).expect("missing manifest is a typed status, not a refusal");
        assert!(!result.manifest_present);
        assert_eq!(result.note_count, None);
        assert_eq!(result.last_export, None);
    }

    #[test]
    fn selected_estate_must_match_admission() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = DirectDataMobilityLower::new(&registry);
        let mut rejected = admission(&registry);
        rejected.estate_id = Uuid::new_v4();
        assert!(matches!(lower.selected_open(&rejected), Err(())));
    }
}
