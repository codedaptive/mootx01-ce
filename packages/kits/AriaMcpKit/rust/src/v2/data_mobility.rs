//! Typed v2 data-mobility foundation.
//!
//! This module owns the frozen Mission02 request grammar and the direct lower
//! boundary for maintenance, imports, datasets, and vault jobs.  It does not
//! call the v1 dispatcher, `interface_tools`, `dataset_tools`, or
//! `vault_tools`: those runners render legacy text and would lose both typed
//! result evidence and the selected-estate authorization boundary.

use std::collections::BTreeMap;

use genius_locus_kit::EstateHandle;
use uuid::Uuid;

use crate::jsonrpc::JsonValue;

use super::codec::{
    optional_integer, optional_string, optional_uuid, required_string, required_uuid,
    strict_object, V2DecodeResult, V2InvalidArgument,
};

pub const REINDEX_TOOL: &str = "moot_reindex";
pub const RECLASSIFY_FDC_TOOL: &str = "moot_reclassify_fdc";
pub const PALACE_IMPORT_TOOL: &str = "moot_palace_import";
pub const JSON_IMPORT_TOOL: &str = "moot_json_import";
pub const FILE_DATASET_TOOL: &str = "moot_file_dataset";
pub const DATASET_QUERY_TOOL: &str = "moot_dataset_query";
pub const DATASET_STATS_TOOL: &str = "moot_dataset_stats";
pub const VAULT_EXPORT_TOOL: &str = "moot_vault_export";
pub const VAULT_IMPORT_TOOL: &str = "moot_vault_import";
pub const VAULT_STATUS_TOOL: &str = "moot_vault_status";
pub const VAULT_RECONCILE_TOOL: &str = "moot_vault_reconcile";
pub const VAULT_JOB_TOOL: &str = "moot_vault_job";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2DataMobilityOperation {
    Reindex,
    ReclassifyFdc,
    PalaceImport,
    JsonImport,
    FileDataset,
    DatasetQuery,
    DatasetStats,
    VaultExport,
    VaultImport,
    VaultStatus,
    VaultReconcile,
    VaultJob,
}

impl V2DataMobilityOperation {
    pub const fn tool_name(self) -> &'static str {
        match self {
            Self::Reindex => REINDEX_TOOL,
            Self::ReclassifyFdc => RECLASSIFY_FDC_TOOL,
            Self::PalaceImport => PALACE_IMPORT_TOOL,
            Self::JsonImport => JSON_IMPORT_TOOL,
            Self::FileDataset => FILE_DATASET_TOOL,
            Self::DatasetQuery => DATASET_QUERY_TOOL,
            Self::DatasetStats => DATASET_STATS_TOOL,
            Self::VaultExport => VAULT_EXPORT_TOOL,
            Self::VaultImport => VAULT_IMPORT_TOOL,
            Self::VaultStatus => VAULT_STATUS_TOOL,
            Self::VaultReconcile => VAULT_RECONCILE_TOOL,
            Self::VaultJob => VAULT_JOB_TOOL,
        }
    }
}

/// Surface-owned proof that one operation may address the selected estate.
/// The context binds jobs and filesystem operations to the admitted caller;
/// callers never supply a substitute identity through tool arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2DataMobilityAdmission {
    pub estate_id: Uuid,
    pub estate_handle: EstateHandle,
    pub caller_binding: String,
    pub authorization_generation: String,
    pub now_millis: i64,
}

pub trait V2DataMobilityAuthority: Send + Sync {
    fn admit(
        &self,
        operation: V2DataMobilityOperation,
        requested_estate_id: Option<Uuid>,
    ) -> Result<V2DataMobilityAdmission, ()>;

    /// Revalidate after direct lower work and before an outcome is released.
    fn revalidate(&self, admission: &V2DataMobilityAdmission) -> Result<(), ()>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2ImportMode { Foreground, Background }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2DatasetSensitivity { Normal, Elevated, Restricted, Secret }

/// Reclassify mode for `moot_reclassify_fdc`. Wire values are `suspectOnly`
/// and `all`, exactly as they appear in the FDC re-lookup API. No case-folding
/// in v2: the caller must supply the exact string. Per data contract §2.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2FdcReclassifyMode {
    /// Only repairs drawers whose anchor change is a sentinel-adjacent or
    /// same-code QID-drift case. Default.
    SuspectOnly,
    /// Repairs every active drawer whose anchor would change.
    All,
}

/// One anchor change recorded in `V2ReclassifyFdcReport.changes`. Capped at 25
/// entries per scan per the data contract §3 (changes_omitted carries the rest).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2FdcReclassifyChange {
    /// Drawer id.
    pub id: String,
    /// UDC code before reclassify.
    pub old_code: String,
    /// UDC code after reclassify.
    pub new_code: String,
    /// Wikidata QID before reclassify; omitted when the drawer had no QID.
    pub old_qid: Option<String>,
    /// Wikidata QID after re-lookup; omitted when the re-lookup produced no QID.
    pub new_qid: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ReindexRequest { pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ReclassifyFdcRequest {
    pub estate_id: Option<Uuid>,
    /// Apply anchor changes. Default false (dry run).
    pub apply: bool,
    /// Which anchors qualify as candidates. Default SuspectOnly.
    pub mode: V2FdcReclassifyMode,
    /// Cap the candidate set to at most this many drawers. None = no cap.
    /// Must be 1–50000 when present; out-of-range is an invalid-argument refusal.
    pub limit: Option<usize>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2PalaceImportRequest { pub palace_path: String, pub mode: Option<V2ImportMode>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2JsonImportRequest { pub path: String, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq)]
pub struct V2FileDatasetRequest {
    pub name: String,
    pub location: String,
    pub columns: Option<Vec<JsonValue>>,
    pub rows: Option<Vec<JsonValue>>,
    pub csv_path: Option<String>,
    pub wing: Option<String>,
    pub sensitivity: Option<V2DatasetSensitivity>,
    pub estate_id: Option<Uuid>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct V2DatasetQueryRequest {
    pub dataset_id: Uuid,
    pub where_clause: Option<BTreeMap<String, JsonValue>>,
    pub order_by: Option<Vec<JsonValue>>,
    pub limit: Option<usize>,
    pub columns: Option<Vec<JsonValue>>,
    pub estate_id: Option<Uuid>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2DatasetStatsRequest { pub dataset_id: Uuid, pub column: Option<String>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2VaultExportRequest { pub vault_path: String, pub scope: Option<String>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2VaultImportRequest { pub vault_path: String, pub mode: Option<String>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2VaultStatusRequest { pub vault_path: String }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2VaultReconcileRequest { pub vault_path: String, pub apply: Option<bool>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2VaultJobRequest { pub job_id: Uuid }

impl V2ReindexRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["estate_id"])?; Ok(Self { estate_id: optional_uuid(o, "estate_id")? }) } }
impl V2ReclassifyFdcRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let o = strict_object(value, ["estate_id", "apply", "mode", "limit"])?;
        // Mode: exactly "suspectOnly" or "all". No case-folding — v2 is strict.
        // An unrecognised mode value is an invalid-argument refusal per data contract §2.
        let mode = match optional_string(o, "mode")? {
            None | Some("suspectOnly") => V2FdcReclassifyMode::SuspectOnly,
            Some("all") => V2FdcReclassifyMode::All,
            Some(s) => return Err(V2InvalidArgument::new("$.mode",
                format!("must be \"suspectOnly\" or \"all\"; received {s}"))),
        };
        // Limit: must be 1–50000 when present. Out-of-range is a refusal.
        let limit = match optional_integer(o, "limit")? {
            None => None,
            Some(raw) => {
                if raw < 1 || raw > 50_000 {
                    return Err(V2InvalidArgument::new("$.limit",
                        format!("must be 1–50000; received {raw}")));
                }
                Some(raw as usize)
            }
        };
        Ok(Self {
            estate_id: optional_uuid(o, "estate_id")?,
            apply: optional_bool(o, "apply")?.unwrap_or(false),
            mode,
            limit,
        })
    }
}
impl V2PalaceImportRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let o = strict_object(value, ["palace_path", "mode", "estate_id"])?;
        let mode = match optional_string(o, "mode")? {
            None => None,
            Some("foreground") => Some(V2ImportMode::Foreground),
            Some("background") => Some(V2ImportMode::Background),
            Some(_) => return Err(V2InvalidArgument::new("$.mode", "must be foreground or background")),
        };
        Ok(Self { palace_path: required_string(o, "palace_path")?.to_owned(), mode, estate_id: optional_uuid(o, "estate_id")? })
    }
}
impl V2JsonImportRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["path", "estate_id"])?; Ok(Self { path: required_string(o, "path")?.to_owned(), estate_id: optional_uuid(o, "estate_id")? }) } }
impl V2FileDatasetRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let o = strict_object(value, ["name", "location", "columns", "rows", "csv_path", "wing", "sensitivity", "estate_id"])?;
        let rows = optional_array(o, "rows")?;
        let csv_path = optional_string(o, "csv_path")?.map(str::to_owned);
        if rows.is_some() == csv_path.is_some() {
            return Err(V2InvalidArgument::new("$", "provide exactly one of rows or csv_path"));
        }
        let sensitivity = match optional_string(o, "sensitivity")? {
            None => None,
            Some("normal") => Some(V2DatasetSensitivity::Normal),
            Some("elevated") => Some(V2DatasetSensitivity::Elevated),
            Some("restricted") => Some(V2DatasetSensitivity::Restricted),
            Some("secret") => Some(V2DatasetSensitivity::Secret),
            Some(_) => return Err(V2InvalidArgument::new("$.sensitivity", "must be normal, elevated, restricted, or secret")),
        };
        Ok(Self {
            name: required_string(o, "name")?.to_owned(), location: required_string(o, "location")?.to_owned(),
            columns: optional_array(o, "columns")?, rows,
            csv_path, wing: optional_string(o, "wing")?.map(str::to_owned),
            sensitivity, estate_id: optional_uuid(o, "estate_id")?,
        })
    }
}
impl V2DatasetQueryRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let o = strict_object(value, ["dataset_id", "where", "order_by", "limit", "columns", "estate_id"])?;
        let limit = optional_integer(o, "limit")?.map(|n| {
            usize::try_from(n).ok().filter(|value| (1..=1_000).contains(value)).ok_or_else(|| V2InvalidArgument::new("$.limit", "must be an integer between 1 and 1000"))
        }).transpose()?;
        let where_clause = optional_object(o, "where")?;
        if let Some(predicate) = &where_clause {
            let mut nodes = 0;
            validate_dataset_predicate(predicate, 1, &mut nodes, "$.where")?;
        }
        let order_by = optional_array(o, "order_by")?;
        if let Some(order) = &order_by { validate_dataset_order(order)?; }
        let columns = optional_array(o, "columns")?;
        if let Some(columns) = &columns {
            for (index, column) in columns.iter().enumerate() {
                if !matches!(column, JsonValue::String(value) if !value.is_empty()) {
                    return Err(V2InvalidArgument::new(format!("$.columns[{index}]"), "must be a non-empty string"));
                }
            }
        }
        Ok(Self {
            dataset_id: required_uuid(o, "dataset_id")?, where_clause,
            order_by, limit, columns,
            estate_id: optional_uuid(o, "estate_id")?,
        })
    }
}
impl V2DatasetStatsRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["dataset_id", "column", "estate_id"])?; Ok(Self { dataset_id: required_uuid(o, "dataset_id")?, column: optional_string(o, "column")?.map(str::to_owned), estate_id: optional_uuid(o, "estate_id")? }) } }
impl V2VaultExportRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["vaultPath", "scope", "estate_id"])?; Ok(Self { vault_path: required_string(o, "vaultPath")?.to_owned(), scope: optional_string(o, "scope")?.map(str::to_owned), estate_id: optional_uuid(o, "estate_id")? }) } }
impl V2VaultImportRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["vaultPath", "mode", "estate_id"])?; Ok(Self { vault_path: required_string(o, "vaultPath")?.to_owned(), mode: optional_string(o, "mode")?.map(str::to_owned), estate_id: optional_uuid(o, "estate_id")? }) } }
impl V2VaultStatusRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["vaultPath"])?; Ok(Self { vault_path: required_string(o, "vaultPath")?.to_owned() }) } }
impl V2VaultReconcileRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["vaultPath", "apply", "estate_id"])?; Ok(Self { vault_path: required_string(o, "vaultPath")?.to_owned(), apply: optional_bool(o, "apply")?, estate_id: optional_uuid(o, "estate_id")? }) } }
impl V2VaultJobRequest { pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(value, ["job_id"])?; Ok(Self { job_id: required_uuid(o, "job_id")? }) } }

fn optional_array(o: &BTreeMap<String, JsonValue>, key: &str) -> V2DecodeResult<Option<Vec<JsonValue>>> {
    match o.get(key) { None => Ok(None), Some(JsonValue::Array(values)) => Ok(Some(values.clone())), Some(_) => Err(V2InvalidArgument::new(format!("$.{key}"), "must be an array")) }
}
fn optional_object(o: &BTreeMap<String, JsonValue>, key: &str) -> V2DecodeResult<Option<BTreeMap<String, JsonValue>>> {
    match o.get(key) { None => Ok(None), Some(JsonValue::Object(value)) => Ok(Some(value.clone())), Some(_) => Err(V2InvalidArgument::new(format!("$.{key}"), "must be an object")) }
}
fn optional_bool(o: &BTreeMap<String, JsonValue>, key: &str) -> V2DecodeResult<Option<bool>> {
    match o.get(key) { None => Ok(None), Some(JsonValue::Bool(value)) => Ok(Some(*value)), Some(_) => Err(V2InvalidArgument::new(format!("$.{key}"), "must be a boolean")) }
}

fn validate_dataset_predicate(
    object: &BTreeMap<String, JsonValue>,
    depth: usize,
    nodes: &mut usize,
    path: &str,
) -> V2DecodeResult<()> {
    if depth > 8 {
        return Err(V2InvalidArgument::new(path, "may be at most 8 levels deep"));
    }
    *nodes += 1;
    if *nodes > 128 {
        return Err(V2InvalidArgument::new(path, "may contain at most 128 nodes"));
    }

    for compound in ["and", "or"] {
        if let Some(value) = object.get(compound) {
            if object.len() != 1 {
                return Err(V2InvalidArgument::new(path, "compound predicates must contain exactly one operator"));
            }
            let JsonValue::Array(children) = value else {
                return Err(V2InvalidArgument::new(format!("{path}.{compound}"), "must be an array"));
            };
            if children.is_empty() {
                return Err(V2InvalidArgument::new(format!("{path}.{compound}"), "must not be empty"));
            }
            for (index, child) in children.iter().enumerate() {
                let JsonValue::Object(child) = child else {
                    return Err(V2InvalidArgument::new(format!("{path}.{compound}[{index}]"), "must be an object"));
                };
                validate_dataset_predicate(
                    child,
                    depth + 1,
                    nodes,
                    &format!("{path}.{compound}[{index}]"),
                )?;
            }
            return Ok(());
        }
    }

    if !matches!(object.get("col"), Some(JsonValue::String(value)) if !value.is_empty()) {
        return Err(V2InvalidArgument::new(format!("{path}.col"), "must be a non-empty string"));
    }
    let operation = object.get("op").and_then(JsonValue::as_str)
        .ok_or_else(|| V2InvalidArgument::new(format!("{path}.op"), "must be a string"))?;
    if matches!(operation, "is_null" | "is_not_null") {
        if object.len() != 2 || !object.contains_key("col") || !object.contains_key("op") {
            return Err(V2InvalidArgument::new(path, "null predicates accept col and op only"));
        }
        return Ok(());
    }
    if !matches!(operation, "eq" | "neq" | "lt" | "lte" | "gt" | "gte")
        || object.len() != 3
        || !object.contains_key("val")
    {
        return Err(V2InvalidArgument::new(path, "comparison predicates require exactly col, op, and val"));
    }
    match object.get("val").expect("validated comparison value") {
        JsonValue::String(_) | JsonValue::Integer(_) | JsonValue::Double(_) => Ok(()),
        JsonValue::Bool(_) if matches!(operation, "eq" | "neq") => Ok(()),
        _ => Err(V2InvalidArgument::new(
            format!("{path}.val"),
            "must be a non-null scalar; booleans support eq or neq only",
        )),
    }
}

fn validate_dataset_order(values: &[JsonValue]) -> V2DecodeResult<()> {
    for (index, value) in values.iter().enumerate() {
        let path = format!("$.order_by[{index}]");
        let JsonValue::Object(object) = value else {
            return Err(V2InvalidArgument::new(&path, "must be an object"));
        };
        if object.keys().any(|key| key != "col" && key != "dir") {
            return Err(V2InvalidArgument::new(&path, "contains an unknown field"));
        }
        if !matches!(object.get("col"), Some(JsonValue::String(value)) if !value.is_empty()) {
            return Err(V2InvalidArgument::new(format!("{path}.col"), "must be a non-empty string"));
        }
        if let Some(direction) = object.get("dir") {
            if !matches!(direction, JsonValue::String(value) if matches!(value.as_str(), "asc" | "desc")) {
                return Err(V2InvalidArgument::new(format!("{path}.dir"), "must be asc or desc"));
            }
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)] pub enum V2ReindexState { Running, AlreadyRunning }

/// Typed report for one `moot_reclassify_fdc` run. 18 properties per data contract §3.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ReclassifyFdcReport {
    /// True when the run wrote anchor changes.
    pub applied: bool,
    /// Resolved mode: "suspectOnly" or "all".
    pub mode: String,
    /// UUID of the estate scanned.
    pub estate_id: uuid::Uuid,
    /// Human-readable estate name (from OpenEstate.estate_name).
    /// Mirrors Swift's EstateHandle.estateName; used by the compact-text builder
    /// to emit "estate: {name} [{uuid}]" matching the Swift canonical output.
    pub estate_name: String,
    /// FDC classifier data version string (non-empty).
    pub fdc_data_version: String,
    /// FDC recalculation version string (non-empty).
    pub fdc_recalculation_version: String,
    /// Active drawers examined.
    pub scanned: u64,
    /// Anchors that re-derived identically (code and QID both unchanged).
    pub unchanged: u64,
    /// Drawers whose content was blank at scan time.
    pub empty_content: u64,
    /// Anchors the mode admitted as candidates.
    pub candidates: u64,
    /// Anchors written; 0 on a dry run.
    pub updated: u64,
    /// Candidates on a dry run; 0 when applied.
    pub would_update: u64,
    /// Candidates whose new code is the "000" sentinel.
    pub unclassified_after: u64,
    /// Changed anchors the mode declined to repair.
    pub skipped_non_candidate_changes: u64,
    /// Floor stamp status. One of the five verbatim strings in data contract §4.
    pub floor_stamp: String,
    /// Estate floor before the run; None when no floor was stored.
    pub estate_recalced_data_version_before: Option<String>,
    /// Estate floor after the run; None when no floor was written.
    pub estate_recalced_data_version_after: Option<String>,
    /// Change list, capped at 25 entries, in scan order.
    pub changes: Vec<V2FdcReclassifyChange>,
    /// candidates − changes.len(); 0 when nothing was cut.
    pub changes_omitted: u64,
}
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2PalaceImportReport { pub drawers_written: u64, pub drawers_updated: u64, pub drawers_skipped_unchanged: u64, pub drawers_skipped_tombstoned: u64, pub drawers_skipped_partial_write: u64, pub tunnels_created: u64, pub items_skipped: u64, pub fdc_classified: u64, pub fdc_unclassified: u64, pub fields_dropped: BTreeMap<String, u64>, pub enqueued_for_encode: u64 }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2JsonImportReport { pub seed_name: String, pub drawers_written: u64, pub facts_written: u64, pub tunnels_created: u64, pub enqueued_for_encode: u64, pub subjects_provided: u64, pub subjects_debt: u64, pub seed_sha256: String, pub id_map: Option<BTreeMap<String, Uuid>> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2DatasetFiled { pub dataset_id: Uuid, pub handle_memory_id: Uuid, pub name: String, pub location: String, pub wing: Option<String>, pub columns: u64, pub rows: u64, pub source: String, pub sensitivity: String, pub signatures: String }
#[derive(Debug, Clone, PartialEq)] pub struct V2DatasetQueryResult { pub dataset_id: Uuid, pub handle_memory_id: Uuid, pub state: String, pub sensitivity: String, pub rows_returned: u64, pub limit: u64, pub rows: Vec<BTreeMap<String, JsonValue>>, pub columns: Option<Vec<String>>, pub handle_row_count: Option<u64> }
#[derive(Debug, Clone, PartialEq)] pub struct V2DatasetColumnStats { pub count: u64, pub distinct_count: u64, pub null_count: u64, pub min: JsonValue, pub max: JsonValue }
#[derive(Debug, Clone, PartialEq)] pub struct V2DatasetStatsResult { pub dataset_id: Uuid, pub handle_memory_id: Uuid, pub stats: BTreeMap<String, V2DatasetColumnStats> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2VaultExportResult { pub job_id: Uuid, pub vault: String, pub scope: String, pub datasets_exported: Option<u64>, pub warnings: Option<Vec<String>> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2VaultImportResult { pub job_id: Uuid, pub vault: String, pub note_count: u64, pub status: String, pub drawers_written: Option<u64>, pub drawers_updated: Option<u64>, pub items_skipped: Option<u64>, pub tunnels_created: Option<u64>, pub fdc_classified: Option<u64>, pub fdc_unclassified: Option<u64>, pub datasets_imported: Option<u64>, pub warnings: Option<Vec<String>> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2VaultStatusResult { pub manifest_present: bool, pub path: String, pub last_export: Option<String>, pub note_count: Option<u64> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2VaultCandidate { pub stable_source_key: String, pub vault_path: String, pub sha256: String }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2VaultReconcileResult { pub added: Vec<String>, pub modified: Vec<String>, pub deleted: Vec<String>, pub missing: Vec<String>, pub import_set_count: u64, pub candidate_count: u64, pub missing_count: u64, pub applied: bool, pub candidates: Option<Vec<V2VaultCandidate>> }
/// Typed terminal receipt for a vault job.  The Rust worker is synchronous,
/// so the concrete vault adapter supplies one of these at launch/poll time
/// instead of manufacturing a running result or re-reading v1 text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2VaultJobTerminal {
    Imported {
        drawers_written: u64,
        drawers_updated: u64,
        items_skipped: u64,
        tunnels_created: u64,
        fdc_classified: u64,
        fdc_unclassified: u64,
        drawers_skipped_unchanged: u64,
        drawers_skipped_tombstoned: u64,
    },
    Exported { note_count: u64, exported_at: String },
}
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2VaultJobResult {
    pub job_id: Uuid,
    pub kind: String,
    pub vault: String,
    pub status: String,
    pub elapsed_millis: u64,
    pub terminal: Option<V2VaultJobTerminal>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum V2DataMobilityResult {
    Reindex(V2ReindexState), ReclassifyFdc(V2ReclassifyFdcReport), PalaceImport(V2PalaceImportReport), JsonImport(V2JsonImportReport),
    DatasetFiled(V2DatasetFiled), DatasetQuery(V2DatasetQueryResult), DatasetStats(V2DatasetStatsResult), VaultExport(V2VaultExportResult),
    VaultImport(V2VaultImportResult), VaultStatus(V2VaultStatusResult), VaultReconcile(V2VaultReconcileResult), VaultJob(V2VaultJobResult),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)] pub enum V2DataMobilityError { Unavailable, OutcomeUnverified(V2DataMobilityOperation) }

/// Direct lower-kit boundary.  A production adapter may use coordinator,
/// VaultKit, and DatasetStore calls, but must never delegate to an ARIA v1
/// runner or interpret rendered result text.  Any lower failure maps to the
/// same operational refusal, including an unknown vault job, to avoid an
/// existence oracle.
pub trait V2DataMobilityLower: Send + Sync {
    fn reindex(&self, admission: &V2DataMobilityAdmission, request: &V2ReindexRequest) -> Result<V2ReindexState, ()>;
    fn reclassify_fdc(&self, admission: &V2DataMobilityAdmission, request: &V2ReclassifyFdcRequest) -> Result<V2ReclassifyFdcReport, ()>;
    fn palace_import(&self, admission: &V2DataMobilityAdmission, request: &V2PalaceImportRequest) -> Result<V2PalaceImportReport, ()>;
    fn json_import(&self, admission: &V2DataMobilityAdmission, request: &V2JsonImportRequest) -> Result<V2JsonImportReport, ()>;
    fn file_dataset(&self, admission: &V2DataMobilityAdmission, request: &V2FileDatasetRequest) -> Result<V2DatasetFiled, ()>;
    fn dataset_query(&self, admission: &V2DataMobilityAdmission, request: &V2DatasetQueryRequest) -> Result<V2DatasetQueryResult, ()>;
    fn dataset_stats(&self, admission: &V2DataMobilityAdmission, request: &V2DatasetStatsRequest) -> Result<V2DatasetStatsResult, ()>;
    fn vault_export(&self, admission: &V2DataMobilityAdmission, request: &V2VaultExportRequest) -> Result<V2VaultExportResult, ()>;
    fn vault_import(&self, admission: &V2DataMobilityAdmission, request: &V2VaultImportRequest) -> Result<V2VaultImportResult, ()>;
    fn vault_status(&self, admission: &V2DataMobilityAdmission, request: &V2VaultStatusRequest) -> Result<V2VaultStatusResult, ()>;
    fn vault_reconcile(&self, admission: &V2DataMobilityAdmission, request: &V2VaultReconcileRequest) -> Result<V2VaultReconcileResult, ()>;
    fn vault_job(&self, admission: &V2DataMobilityAdmission, request: &V2VaultJobRequest) -> Result<V2VaultJobResult, ()>;
}

pub struct V2DataMobilityService<A, L> { authority: A, lower: L }
impl<A, L> V2DataMobilityService<A, L> { pub fn new(authority: A, lower: L) -> Self { Self { authority, lower } } }

impl<A: V2DataMobilityAuthority, L: V2DataMobilityLower> V2DataMobilityService<A, L> {
    fn admitted(&self, operation: V2DataMobilityOperation, estate_id: Option<Uuid>) -> Result<V2DataMobilityAdmission, V2DataMobilityError> { self.authority.admit(operation, estate_id).map_err(|_| V2DataMobilityError::Unavailable) }
    fn finish(&self, admission: V2DataMobilityAdmission, operation: V2DataMobilityOperation, result: V2DataMobilityResult) -> Result<V2DataMobilityResult, V2DataMobilityError> { self.authority.revalidate(&admission).map_err(|_| V2DataMobilityError::OutcomeUnverified(operation))?; Ok(result) }
    pub fn reindex(&self, r: V2ReindexRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::Reindex,r.estate_id)?; let v=self.lower.reindex(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::Reindex,V2DataMobilityResult::Reindex(v)) }
    pub fn reclassify_fdc(&self, r: V2ReclassifyFdcRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::ReclassifyFdc,r.estate_id)?; let v=self.lower.reclassify_fdc(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::ReclassifyFdc,V2DataMobilityResult::ReclassifyFdc(v)) }
    pub fn palace_import(&self, r: V2PalaceImportRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::PalaceImport,r.estate_id)?; let v=self.lower.palace_import(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::PalaceImport,V2DataMobilityResult::PalaceImport(v)) }
    pub fn json_import(&self, r: V2JsonImportRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::JsonImport,r.estate_id)?; let v=self.lower.json_import(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::JsonImport,V2DataMobilityResult::JsonImport(v)) }
    pub fn file_dataset(&self, r: V2FileDatasetRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::FileDataset,r.estate_id)?; let v=self.lower.file_dataset(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::FileDataset,V2DataMobilityResult::DatasetFiled(v)) }
    pub fn dataset_query(&self, r: V2DatasetQueryRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::DatasetQuery,r.estate_id)?; let v=self.lower.dataset_query(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::DatasetQuery,V2DataMobilityResult::DatasetQuery(v)) }
    pub fn dataset_stats(&self, r: V2DatasetStatsRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::DatasetStats,r.estate_id)?; let v=self.lower.dataset_stats(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::DatasetStats,V2DataMobilityResult::DatasetStats(v)) }
    pub fn vault_export(&self, r: V2VaultExportRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::VaultExport,r.estate_id)?; let v=self.lower.vault_export(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::VaultExport,V2DataMobilityResult::VaultExport(v)) }
    pub fn vault_import(&self, r: V2VaultImportRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::VaultImport,r.estate_id)?; let v=self.lower.vault_import(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::VaultImport,V2DataMobilityResult::VaultImport(v)) }
    pub fn vault_status(&self, r: V2VaultStatusRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::VaultStatus,None)?; let v=self.lower.vault_status(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::VaultStatus,V2DataMobilityResult::VaultStatus(v)) }
    pub fn vault_reconcile(&self, r: V2VaultReconcileRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::VaultReconcile,r.estate_id)?; let v=self.lower.vault_reconcile(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::VaultReconcile,V2DataMobilityResult::VaultReconcile(v)) }
    pub fn vault_job(&self, r: V2VaultJobRequest) -> Result<V2DataMobilityResult, V2DataMobilityError> { let a=self.admitted(V2DataMobilityOperation::VaultJob,None)?; let v=self.lower.vault_job(&a,&r).map_err(|_|V2DataMobilityError::Unavailable)?; self.finish(a,V2DataMobilityOperation::VaultJob,V2DataMobilityResult::VaultJob(v)) }
}
