//! dataset_tools.rs — MCP tool surface for user-defined tabular datasets (MX-TAB-7b).
//!
//! Rust twin of `AriaMcpKit/Sources/AriaMCP/DatasetTools.swift`.
//!
//! Three tools:
//!   moot_file_dataset   — create a dataset handle plus backend table, bulk-load rows
//!   moot_dataset_query  — predicate query over a dataset's rows
//!   moot_dataset_stats  — per-column aggregate statistics passthrough
//!
//! Design decisions mirrored from DatasetTools.swift header:
//!
//!   DISPATCH SHAPE: Follows VaultTools/LensTools pattern — public module-level
//!   is_dataset_tool(), dispatch(), and tools-schema helpers. Inserted in
//!   dispatch.rs after vault tools and before recipe tools, matching Swift's
//!   ToolDispatch.dispatch() insertion after VaultTools and before InterfaceTools.
//!
//!   PROVENANCE: .interface — dataset tools are user-facing CRUD operations that
//!   target a specific estate (they carry an optional estateID like all interface
//!   tools). The schema wraps with with_estate_id/with_teachme in tool_list.rs.
//!
//!   CSV SIZE CAP: CSV_SIZE_CAP_BYTES = 100 MiB. Mirrors Swift csvPathSizeCapBytes.
//!   Rationale: generous for substantial real-world datasets while bounding peak
//!   parse memory. Larger files should be pre-split or streamed (v2 path).
//!
//!   PATH SECURITY: csv_path is canonicalized (resolving symlinks) to get the REAL
//!   path, then checked that it lies within the allowed import root (HOME by default;
//!   MX-TAB-SEC-1 A1 confinement), then checked that it is a regular file (no
//!   directories, devices, non-file symlink targets). The handle's sourceDescription
//!   stores only the basename (MX-TAB-SEC-1 A2 redaction); the full resolved path
//!   goes to the server-side audit channel (stderr) only.
//!
//!   TYPE INFERENCE: try Int64 → try f64 → text. Applies to both CSV cells and
//!   JSON object scalar values. Empty string → null (TypedValue::Null).
//!   Both legs use the identical algorithm for parity.
//!
//!   REJECTION SEMANTICS: an invalid column name fails the whole import with a clear
//!   error before any DDL is emitted. No sanitize-and-continue path. If handle creation
//!   fails after the table is created, the table is dropped (atomic intent: either both
//!   succeed or neither persists).
//!
//!   WITHDRAWN HANDLE: moot_dataset_query and moot_dataset_stats call
//!   resolve_active_dataset_handle which returns LocusKitError::WithdrawnDatasetHandle
//!   for any dataset whose most recent cluster-A state is withdrawn. Both tools map
//!   this to a clear refusal.
//!
//!   FLOAT WIRE DISCIPLINE: all f64 values in tool output use format!("{}", d) which
//!   produces the ryu shortest-roundtrip decimal string. Never f32. Matches Swift's
//!   String(d) representation.
//!
//!   SIGNATURES (MX-TAB-5): moot_file_dataset computes tier-1 (table) and tier-2
//!   (column) signatures AFTER the handle is captured — sample first
//!   DATASET_SIGNATURE_SAMPLE_SIZE rows, gather per-column stats, call
//!   compute_dataset_signatures. Signature failure is NON-FATAL.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use uuid::Uuid;

use crate::dispatch::{describe_glk_error, error_result, optional_integer, optional_string, require_string, text_result, wall_now};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

use genius_locus_kit::dataset_signatures::{compute_dataset_signatures, DATASET_SIGNATURE_SAMPLE_SIZE};
use locus_kit::dataset_handle::{DatasetColumnSummary, DatasetHandleContent};
use locus_kit::error::LocusKitError;
use persistence_kit::dataset_store::{
    dataset_table_name, validate_dataset_column_identifier, ColumnStats, DatasetSchema,
};
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::schema::ColumnDeclaration;
use persistence_kit::types::{Column, ColumnType, TypedValue};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Maximum CSV file size accepted by moot_file_dataset.
///
/// 100 MiB (104,857,600 bytes). Mirrors Swift `csvPathSizeCapBytes`.
/// Rationale: generous for substantial real-world datasets while bounding peak
/// parse memory. Larger files should be pre-split or use a streaming import path.
const CSV_SIZE_CAP_BYTES: i64 = 100 * 1_048_576;

/// Server identity string used as the `added_by` field on dataset handle creation.
/// Matches Swift's `serverIdentity.isEmpty ? "aria-mcp-server" : serverIdentity`
/// when the server identity is not set (the default condition in this Rust server).
const DATASET_ADDED_BY: &str = "aria-mcp-server";

// ---------------------------------------------------------------------------
// Tool name membership
// ---------------------------------------------------------------------------

/// The three dataset tool names dispatched by this module.
pub const DATASET_TOOL_NAMES: &[&str] = &[
    "moot_file_dataset",
    "moot_dataset_query",
    "moot_dataset_stats",
];

/// True when `name` is a dataset tool dispatched before the recipe/lens tiers.
pub fn is_dataset_tool(name: &str) -> bool {
    DATASET_TOOL_NAMES.contains(&name)
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// Run the named dataset tool against `registry`.
///
/// Follows the same contract as `vault_tools::dispatch_vault` and
/// `recipe_tools::dispatch`: out-of-band faults throw `JSONRPCError`;
/// substrate refusals return `error_result` (isError: true).
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    match name {
        "moot_file_dataset" => run_file_dataset(args, registry),
        "moot_dataset_query" => run_dataset_query(args, registry),
        "moot_dataset_stats" => run_dataset_stats(args, registry),
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown dataset tool: {name}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// moot_file_dataset
// ---------------------------------------------------------------------------

fn run_file_dataset(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let open = registry.resolve_direct(args)?;

    // --- Parse parameters ---
    let name = require_string(args, "name")?;
    let location = require_string(args, "location")?;
    let wing = optional_string(args, "wing")?;
    let sensitivity_raw = decode_sensitivity_raw(args)?;

    // columns: array of {name, type?} objects.
    // Required when using inline rows; optional for csv_path (type inferred from header).
    let column_specs = parse_column_specs(args.get("columns"))?;

    // Source: exactly one of `rows` or `csv_path` (or neither → error).
    let has_csv_path = args.contains_key("csv_path");
    let has_rows = args.contains_key("rows");

    if has_csv_path && has_rows {
        return Ok(error_result(
            "moot_file_dataset: supply either rows or csv_path, not both",
        ));
    }

    // --- Validate all column identifiers BEFORE any DDL ---
    // Rejection fails the whole import — no sanitize-and-continue path.
    for spec in &column_specs {
        if let Err(e) = validate_dataset_column_identifier(&spec.name) {
            return Ok(error_result(&format!(
                "moot_file_dataset: invalid column identifier \"{}\". \
                Column names must match [A-Za-z_][A-Za-z0-9_]*. ({})",
                spec.name, e
            )));
        }
    }

    // --- Parse rows and build schema ---
    let parse_result: ParseResult;
    let source_description: String;

    if let Some(csv_path_val) = args.get("csv_path").and_then(|v| v.as_str()) {
        // csv_path path: canonicalize → security-check → size-check → parse.
        let resolved = match resolve_csv_path(csv_path_val) {
            Ok(r) => r,
            Err(msg) => return Ok(error_result(&msg)),
        };
        match parse_csv(&resolved, &column_specs) {
            Ok(r) => {
                // A2: Provenance path redaction (MX-TAB-SEC-1 A2).
                //
                // source_description is stored in the handle drawer and visible to the
                // client. To avoid leaking the full canonical filesystem path (which can
                // reveal personal directory layout to a prompt-injected client),
                // source_description carries only the basename.
                //
                // The full resolved path goes to the server-side audit channel (stderr)
                // ONLY — never to the client-facing response body or stored drawer content.
                eprintln!("csv_import: audit resolved={}", resolved);
                let basename = std::path::Path::new(&resolved)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| resolved.clone());
                source_description = format!("csv:{}", basename);
                parse_result = r;
            }
            Err(msg) => return Ok(error_result(&msg)),
        }
    } else if let Some(rows_val) = args.get("rows") {
        if column_specs.is_empty() {
            return Ok(error_result(
                "moot_file_dataset: columns is required when using inline rows",
            ));
        }
        match parse_inline_rows(rows_val, &column_specs) {
            Ok(r) => {
                source_description = format!("inline_rows:{}", name);
                parse_result = r;
            }
            Err(msg) => return Ok(error_result(&msg)),
        }
    } else {
        return Ok(error_result(
            "moot_file_dataset: either rows or csv_path is required",
        ));
    }

    let schema = parse_result.schema;
    let typed_rows = parse_result.rows;

    // --- Obtain the DatasetStore ---
    let dataset_id = Uuid::new_v4();
    let storage = match open.store.storage() {
        Some(s) => s,
        None => return Ok(error_result(
            "moot_file_dataset: estate storage does not support datasets (no storage layer)",
        )),
    };
    let dataset_store = match storage.dataset_store() {
        Ok(ds) => ds,
        Err(e) => return Ok(error_result(&format!(
            "moot_file_dataset: estate storage does not support datasets: {}",
            e
        ))),
    };

    // --- Create the backend table ---
    // On failure nothing has been committed yet; no cleanup needed.
    if let Err(e) = dataset_store.create_dataset(dataset_id, &schema, &[]) {
        return Ok(error_result(&format!(
            "moot_file_dataset: failed to create dataset table: {}",
            e
        )));
    }

    // --- Append rows in one transaction ---
    // On failure, drop the table so no orphaned backend table persists without
    // a matching handle (atomic intent: either both succeed or neither persists).
    if !typed_rows.is_empty() {
        if let Err(e) = dataset_store.append_rows(dataset_id, &typed_rows) {
            let _ = dataset_store.drop_dataset(dataset_id);
            return Ok(error_result(&format!(
                "moot_file_dataset: failed to append rows (table dropped): {}",
                e
            )));
        }
    }

    // --- Capture the dataset handle drawer ---
    // capture_dataset_handle is the ONLY authorised creation path for .dataset drawers.
    //
    // DatasetColumnSummary.data_type must match Swift's `$0.type.rawValue.uppercased()`:
    //   ColumnType::Int   → "INT"   (Swift rawValue "int", uppercased to "INT")
    //   ColumnType::Float → "FLOAT" (Swift rawValue "float", uppercased to "FLOAT")
    //   ColumnType::Text  → "TEXT"  (Swift rawValue "text", uppercased to "TEXT")
    //   ColumnType::Bool  → "BOOL"  (Swift rawValue "bool", uppercased to "BOOL")
    // Byte-identical data_type strings are required for signature parity (MX-TAB-5).
    let column_summaries: Vec<DatasetColumnSummary> = schema
        .columns
        .iter()
        .map(|c| DatasetColumnSummary {
            name: c.name.clone(),
            data_type: column_type_label(c.column_type),
        })
        .collect();

    // Acquire the coord lock to reach the estate and call the authorised handle path.
    let coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "moot_file_dataset: estate coordinator lock poisoned",
        )
    })?;
    let locus_estate = coord.estate_for(&open.handle).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("moot_file_dataset: estate not accessible: {}", describe_glk_error(&e)),
        )
    })?;

    let now = wall_now();
    let drawer = match locus_estate.capture_dataset_handle(
        dataset_id,
        column_summaries.clone(),
        typed_rows.len() as i64,
        &source_description,
        wing,
        location,
        DATASET_ADDED_BY,
        sensitivity_raw,
        // Dataset handles get UDC "000" (fallback/unclassified). Matches Swift
        // which passes LatticeAnchor.udc("000") as the lattice anchor.
        "000",
        now,
    ) {
        Ok(d) => d,
        Err(e) => {
            // Drop the orphaned table if handle creation fails.
            let _ = dataset_store.drop_dataset(dataset_id);
            return Ok(error_result(&format!(
                "moot_file_dataset: handle creation failed (table dropped): {}",
                e
            )));
        }
    };

    // --- Layered signatures (MX-TAB-5) ---
    // Tier 1 (table) + tier 2 (column) signatures computed at import per
    // spec §3: sample the first DATASET_SIGNATURE_SAMPLE_SIZE rows in backend
    // order, gather per-column stats, and patch the handle drawer.
    // NON-FATAL on failure: the dataset and handle are already committed —
    // a filed dataset without signatures is recoverable; dropping a loaded
    // table over a signature error is not.
    let mut signature_status = "computed".to_string();
    let sig_result: Result<_, String> = (|| {
        let sampled_rows = dataset_store
            .query_rows(
                dataset_id,
                None,
                &[],
                Some(DATASET_SIGNATURE_SAMPLE_SIZE),
                None,
                None,
            )
            .map_err(|e| e.to_string())?;
        let mut stats: HashMap<String, ColumnStats> = HashMap::new();
        for col in &schema.columns {
            let s = dataset_store
                .column_stats(dataset_id, &col.name)
                .map_err(|e| e.to_string())?;
            stats.insert(col.name.clone(), s);
        }
        compute_dataset_signatures(locus_estate, &drawer.id, &column_summaries, &stats, &sampled_rows)
            .map_err(|e| e.to_string())
    })();
    if let Err(ref e) = sig_result {
        signature_status = format!("pending ({})", e);
    }
    // coord lock released here (coord drops at end of scope)

    let wing_line = wing.map(|w| format!("\n  wing: {}", w)).unwrap_or_default();
    let sensitivity_label = format!("{:?}", locus_kit::adjectives::AdjectiveSensitivity::from_raw(sensitivity_raw)).to_lowercase();
    Ok(text_result(&format!(
        "dataset_filed:\n  id: {}\n  handle_id: {}\n  name: {}\n  location: {}{}\n  columns: {}\n  rows: {}\n  source: {}\n  sensitivity: {}\n  signatures: {}",
        dataset_id,
        drawer.id,
        name,
        location,
        wing_line,
        schema.columns.len(),
        typed_rows.len(),
        source_description,
        sensitivity_label,
        signature_status,
    )))
}

// ---------------------------------------------------------------------------
// moot_dataset_query
// ---------------------------------------------------------------------------

fn run_dataset_query(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let open = registry.resolve_direct(args)?;

    let id_str = require_string(args, "id")?;
    let dataset_id = Uuid::parse_str(id_str).map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("moot_dataset_query: id must be a valid UUID, got: {}", id_str),
        )
    })?;

    // Resolve estate and check for withdrawn handle.
    let coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "moot_dataset_query: estate coordinator lock poisoned",
        )
    })?;
    let locus_estate = coord.estate_for(&open.handle).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("moot_dataset_query: estate not accessible: {}", describe_glk_error(&e)),
        )
    })?;

    let handle_drawer = match locus_estate.resolve_active_dataset_handle(dataset_id) {
        Ok(d) => d,
        Err(LocusKitError::WithdrawnDatasetHandle { dataset_id: did }) => {
            return Ok(error_result(&format!(
                "moot_dataset_query: dataset is withdrawn (id: {}). \
                Restore it first with moot_update_memory mutation=revive before querying.",
                did
            )));
        }
        Err(e) => {
            return Ok(error_result(&format!(
                "moot_dataset_query: handle not found: {}",
                e
            )));
        }
    };
    // coord lock released after this block — handle_drawer is owned (cloned by resolve_active_dataset_handle)
    drop(coord);

    // Parse query parameters.
    let table_name = dataset_table_name(dataset_id);
    let predicate = parse_where_predicate(args.get("where"), &table_name)?;
    let order_by = parse_order_by(args.get("order_by"), &table_name)?;

    // Limit: default 100, cap 1000 (prevents scan exhaustion on large datasets).
    let raw_limit = optional_integer(args, "limit")?;
    let limit = match raw_limit {
        None => 100usize,
        Some(v) if v <= 0 => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "moot_dataset_query: limit must be 1 or greater",
            ));
        }
        Some(v) => (v as usize).min(1000),
    };

    // Optional column projection — array of name strings.
    let projected_columns: Option<Vec<String>> = match args.get("columns") {
        None => None,
        Some(JsonValue::Array(arr)) => {
            let cols: Vec<String> = arr
                .iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect();
            if cols.is_empty() { None } else { Some(cols) }
        }
        _ => None,
    };

    // Obtain the DatasetStore.
    let storage = match open.store.storage() {
        Some(s) => s,
        None => return Ok(error_result(
            "moot_dataset_query: estate storage does not support datasets",
        )),
    };
    let dataset_store = match storage.dataset_store() {
        Ok(ds) => ds,
        Err(e) => return Ok(error_result(&format!(
            "moot_dataset_query: estate storage does not support datasets: {}",
            e
        ))),
    };

    let rows = match dataset_store.query_rows(
        dataset_id,
        predicate.as_ref(),
        &order_by,
        Some(limit),
        None,
        projected_columns.as_deref(),
    ) {
        Ok(r) => r,
        Err(e) => return Ok(error_result(&format!(
            "moot_dataset_query: query failed: {}",
            e
        ))),
    };

    // Format output: handle metadata first, then rows.
    // Sort keys alphabetically for deterministic output across Swift/Rust legs.
    let handle_content = DatasetHandleContent::decode(&handle_drawer.content).ok();
    let mut lines: Vec<String> = Vec::new();
    lines.push("dataset_query:".to_string());
    lines.push(format!("  id: {}", dataset_id));
    lines.push(format!("  handle_id: {}", handle_drawer.id));
    if let Some(ref hc) = handle_content {
        let col_names: Vec<&str> = hc.columns.iter().map(|c| c.name.as_str()).collect();
        lines.push(format!("  columns: {}", col_names.join(", ")));
        lines.push(format!("  handle_row_count: {}", hc.row_count));
    }
    // Drawer.state is bits 0–5 of adjective_bitmap; Drawer.adjective_sensitivity is bits 6–11.
    lines.push(format!("  state: {:?}", handle_drawer.state()).to_lowercase());
    lines.push(format!("  sensitivity: {:?}", handle_drawer.adjective_sensitivity()).to_lowercase());
    lines.push(format!("  rows_returned: {}", rows.len()));
    lines.push(format!("  limit: {}", limit));
    if rows.is_empty() {
        lines.push("  (no rows)".to_string());
    } else {
        lines.push("rows:".to_string());
        for row in &rows {
            let mut col_names: Vec<&String> = row.values.keys().collect();
            col_names.sort();
            let fields: Vec<String> = col_names
                .iter()
                .map(|col| {
                    let tv = row.values.get(*col).unwrap_or(&TypedValue::Null);
                    format!("{}:{}", col, typed_value_to_string(tv))
                })
                .collect();
            lines.push(format!("  {{{}}}", fields.join(", ")));
        }
    }
    Ok(text_result(&lines.join("\n")))
}

// ---------------------------------------------------------------------------
// moot_dataset_stats
// ---------------------------------------------------------------------------

fn run_dataset_stats(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let open = registry.resolve_direct(args)?;

    let id_str = require_string(args, "id")?;
    let dataset_id = Uuid::parse_str(id_str).map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("moot_dataset_stats: id must be a valid UUID, got: {}", id_str),
        )
    })?;

    // Resolve estate and check for withdrawn handle.
    let coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "moot_dataset_stats: estate coordinator lock poisoned",
        )
    })?;
    let locus_estate = coord.estate_for(&open.handle).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("moot_dataset_stats: estate not accessible: {}", describe_glk_error(&e)),
        )
    })?;

    let handle_drawer = match locus_estate.resolve_active_dataset_handle(dataset_id) {
        Ok(d) => d,
        Err(LocusKitError::WithdrawnDatasetHandle { dataset_id: did }) => {
            return Ok(error_result(&format!(
                "moot_dataset_stats: dataset is withdrawn (id: {}). \
                Restore it first with moot_update_memory mutation=revive before querying.",
                did
            )));
        }
        Err(e) => {
            return Ok(error_result(&format!(
                "moot_dataset_stats: handle not found: {}",
                e
            )));
        }
    };
    drop(coord);

    let requested_column = optional_string(args, "column")?;
    let handle_content = DatasetHandleContent::decode(&handle_drawer.content).ok();

    // Obtain the DatasetStore.
    let storage = match open.store.storage() {
        Some(s) => s,
        None => return Ok(error_result(
            "moot_dataset_stats: estate storage does not support datasets",
        )),
    };
    let dataset_store = match storage.dataset_store() {
        Ok(ds) => ds,
        Err(e) => return Ok(error_result(&format!(
            "moot_dataset_stats: estate storage does not support datasets: {}",
            e
        ))),
    };

    let mut lines: Vec<String> = vec![
        "dataset_stats:".to_string(),
        format!("  id: {}", dataset_id),
        format!("  handle_id: {}", handle_drawer.id),
    ];

    let columns_to_stat: Vec<String>;
    if let Some(col) = requested_column {
        // Single-column mode: validate identifier before issuing the query.
        if let Err(e) = validate_dataset_column_identifier(col) {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("moot_dataset_stats: invalid column identifier \"{}\": {}", col, e),
            ));
        }
        columns_to_stat = vec![col.to_string()];
    } else {
        // All-columns mode: use schema summary from handle content.
        columns_to_stat = handle_content
            .as_ref()
            .map(|hc| hc.columns.iter().map(|c| c.name.clone()).collect())
            .unwrap_or_default();
        if columns_to_stat.is_empty() {
            lines.push("  (no column schema in handle)".to_string());
            return Ok(text_result(&lines.join("\n")));
        }
    }

    lines.push("stats:".to_string());
    for col in &columns_to_stat {
        match dataset_store.column_stats(dataset_id, col) {
            Ok(s) => {
                lines.push(format!("  {}:", col));
                lines.push(format!("    count: {}", s.count));
                lines.push(format!("    distinct_count: {}", s.distinct_count));
                lines.push(format!("    null_count: {}", s.null_count));
                lines.push(format!("    min: {}", typed_value_to_string(&s.min)));
                lines.push(format!("    max: {}", typed_value_to_string(&s.max)));
            }
            Err(e) => {
                lines.push(format!("  {}: error: {}", col, e));
            }
        }
    }
    Ok(text_result(&lines.join("\n")))
}

// ---------------------------------------------------------------------------
// CSV path security
// ---------------------------------------------------------------------------

/// Resolve, security-check, and size-check a caller-supplied csv_path.
///
/// Security rules (MX-TAB-7 §Security review gate):
///   1. Canonicalize: `std::fs::canonicalize` resolves all symlinks to get the
///      real path. The RESOLVED path is what we check and record — symlinks to
///      regular files are accepted; symlinks to directories or devices are rejected.
///   2. Regular file: must be a regular file (not a directory, device, pipe,
///      or broken symlink). Checked via `std::fs::metadata`.
///   3. Size cap: file size must be ≤ CSV_SIZE_CAP_BYTES (100 MiB). Checked
///      before reading to avoid loading an unexpectedly large file into memory.
///
/// Returns the resolved (canonical) absolute path string on success.
fn resolve_csv_path(raw: &str) -> Result<String, String> {
    // 1. Canonicalize to resolve all symlink chains.
    let canonical = std::fs::canonicalize(raw).map_err(|e| {
        format!(
            "moot_file_dataset: csv_path does not exist or cannot be resolved: {} ({})",
            raw, e
        )
    })?;
    let resolved = canonical.to_string_lossy().into_owned();

    // 1.5. Import-root confinement (MX-TAB-SEC-1 A1).
    //
    // After canonicalization (symlinks resolved, relative components collapsed),
    // the path MUST lie inside the allowed import root. This prevents a
    // prompt-injected client from reading arbitrary filesystem locations such as
    // /etc/passwd by supplying a relative path or a symlink that escapes the
    // intended directory.
    //
    // Root resolution (D11): the user's HOME directory is the default import root.
    // The comparison is component-safe: the root has "/" appended before the
    // starts_with check so that "/home/evil" cannot match a "/home" root.
    //
    // Future: make the root configurable via estate configuration if a per-estate
    // config surface is added; see MX-TAB-SEC-1 D11.
    {
        let home_raw = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
        let import_root = std::fs::canonicalize(&home_raw)
            .unwrap_or_else(|_| std::path::PathBuf::from(&home_raw));
        let canonical_root = import_root.to_string_lossy().into_owned();
        let root_with_sep = if canonical_root.ends_with('/') {
            canonical_root.clone()
        } else {
            format!("{}/", canonical_root)
        };
        if !resolved.starts_with(&root_with_sep) && resolved != canonical_root {
            return Err(format!(
                "moot_file_dataset: csv_path must be inside the allowed import \
                root ({}): {}",
                canonical_root, resolved
            ));
        }
    }

    // 2. Check that the resolved path is a regular file.
    let meta = std::fs::metadata(&canonical).map_err(|e| {
        format!(
            "moot_file_dataset: cannot read csv_path attributes: {} ({})",
            resolved, e
        )
    })?;
    if !meta.is_file() {
        return Err(format!(
            "moot_file_dataset: csv_path must be a regular file \
            (not a directory, device, or non-file symlink target): {}",
            resolved
        ));
    }

    // 3. Size cap: reject before reading to avoid loading a very large file.
    let file_size = meta.len() as i64;
    if file_size > CSV_SIZE_CAP_BYTES {
        let cap_mib = CSV_SIZE_CAP_BYTES / 1_048_576;
        let file_mib = file_size as f64 / 1_048_576.0;
        return Err(format!(
            "moot_file_dataset: csv_path exceeds size cap \
            ({:.1} MiB > {} MiB limit): {}",
            file_mib, cap_mib, resolved
        ));
    }

    Ok(resolved)
}

// ---------------------------------------------------------------------------
// Parse result
// ---------------------------------------------------------------------------

/// Intermediate result from CSV or inline-rows import.
struct ParseResult {
    schema: DatasetSchema,
    rows: Vec<BTreeMap<String, TypedValue>>,
}

// ---------------------------------------------------------------------------
// CSV parsing
// ---------------------------------------------------------------------------

/// Parse a CSV file into a DatasetSchema and typed rows.
///
/// Header row required (first line). Type inference per column: try Int64,
/// then f64, else TEXT. Empty cells → null. One transaction per call.
///
/// RFC-4180 CSV handling:
///   - Fields may be quoted (double-quote wrapper, double-double-quote escape).
///   - Bare (unquoted) fields are trimmed of leading/trailing whitespace.
///   - CRLF and LF line endings are both accepted.
///   - Empty string in an unquoted cell → TypedValue::Null.
///
/// When `column_hints` is non-empty and the hint carries a type, the declared
/// type overrides inference for that column.
fn parse_csv(path: &str, column_hints: &[ColumnSpec]) -> Result<ParseResult, String> {
    let data = std::fs::read(path).map_err(|e| {
        format!("moot_file_dataset: cannot read csv_path: {} ({})", path, e)
    })?;
    let content = String::from_utf8(data).map_err(|_| {
        "moot_file_dataset: csv_path is not valid UTF-8".to_string()
    })?;

    let csv_lines = split_csv_lines(&content);
    if csv_lines.is_empty() {
        return Err("moot_file_dataset: csv_path is empty (header row required)".to_string());
    }

    // Parse header row to get column names.
    let headers = parse_csv_record(&csv_lines[0]);
    if headers.is_empty() {
        return Err("moot_file_dataset: CSV header row is empty".to_string());
    }

    // Validate all header-derived column names.
    for h in &headers {
        validate_dataset_column_identifier(h).map_err(|_| {
            format!(
                "moot_file_dataset: CSV header \"{}\" is not a valid column identifier. \
                Column names must match [A-Za-z_][A-Za-z0-9_]*.",
                h
            )
        })?;
    }

    // Build hint lookup for type overrides (column-name → ColumnType).
    let hint_map: HashMap<&str, ColumnType> = column_hints
        .iter()
        .filter_map(|spec| spec.column_type.map(|t| (spec.name.as_str(), t)))
        .collect();

    // Accumulate raw cell values per column for type inference.
    let data_lines = &csv_lines[1..];
    let mut raw_rows_by_col: HashMap<&str, Vec<Option<String>>> = HashMap::new();
    for h in &headers {
        raw_rows_by_col.insert(h.as_str(), Vec::new());
    }

    for line in data_lines {
        let fields = parse_csv_record(line);
        for (i, h) in headers.iter().enumerate() {
            // Empty string → None (converts to TypedValue::Null during build phase).
            let val: Option<String> = if i < fields.len() && !fields[i].is_empty() {
                Some(fields[i].clone())
            } else {
                None
            };
            raw_rows_by_col.get_mut(h.as_str()).unwrap().push(val);
        }
    }

    // Infer column types from values, or use the caller-supplied hint.
    let mut column_decls: Vec<ColumnDeclaration> = Vec::new();
    let mut column_types: HashMap<String, ColumnType> = HashMap::new();
    for h in &headers {
        let col_type = if let Some(&ht) = hint_map.get(h.as_str()) {
            ht
        } else {
            let non_nil_values: Vec<&str> = raw_rows_by_col[h.as_str()]
                .iter()
                .filter_map(|v| v.as_deref())
                .collect();
            infer_column_type(&non_nil_values)
        };
        column_decls.push(ColumnDeclaration::new(h.clone(), col_type));
        column_types.insert(h.clone(), col_type);
    }

    let schema = DatasetSchema {
        columns: column_decls,
        primary_key_column: None,
    };

    // Build typed rows.
    let row_count = raw_rows_by_col.values().next().map(|v| v.len()).unwrap_or(0);
    let mut typed_rows: Vec<BTreeMap<String, TypedValue>> = Vec::with_capacity(row_count);
    for i in 0..row_count {
        let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
        for h in &headers {
            let raw = raw_rows_by_col[h.as_str()].get(i).and_then(|v| v.as_deref());
            let col_type = column_types.get(h).copied().unwrap_or(ColumnType::Text);
            row.insert(h.clone(), parse_typed_value(raw, col_type));
        }
        typed_rows.push(row);
    }

    Ok(ParseResult { schema, rows: typed_rows })
}

/// Split CSV content into non-empty logical lines (normalising CRLF and CR).
fn split_csv_lines(content: &str) -> Vec<String> {
    let normalized = content
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    normalized
        .split('\n')
        .filter(|line| !line.trim().is_empty())
        .map(|s| s.to_string())
        .collect()
}

/// Parse one CSV record (line) into an array of field strings.
///
/// Handles RFC-4180 quoting: a field wrapped in double-quotes may contain
/// commas, newlines, and escaped double-quotes (two consecutive double-quotes
/// represent one literal double-quote). Bare (unquoted) fields are trimmed.
fn parse_csv_record(line: &str) -> Vec<String> {
    let mut fields: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let chars: Vec<char> = line.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        let ch = chars[i];
        if in_quotes {
            if ch == '"' {
                // Double double-quote → one literal double-quote.
                if i + 1 < chars.len() && chars[i + 1] == '"' {
                    current.push('"');
                    i += 2;
                    continue;
                } else {
                    in_quotes = false;
                    i += 1;
                }
            } else {
                current.push(ch);
                i += 1;
            }
        } else {
            if ch == '"' {
                in_quotes = true;
                i += 1;
            } else if ch == ',' {
                fields.push(current.trim().to_string());
                current = String::new();
                i += 1;
            } else {
                current.push(ch);
                i += 1;
            }
        }
    }
    fields.push(current.trim().to_string());
    fields
}

// ---------------------------------------------------------------------------
// Inline row parsing
// ---------------------------------------------------------------------------

/// Parse inline rows from a JsonValue array into a DatasetSchema and typed rows.
///
/// Each array element must be a JSON object. Column schema is derived from the
/// provided column_specs (all names already validated by the caller).
fn parse_inline_rows(
    value: &JsonValue,
    column_specs: &[ColumnSpec],
) -> Result<ParseResult, String> {
    let arr = match value {
        JsonValue::Array(a) => a,
        _ => return Err("moot_file_dataset: rows must be a JSON array".to_string()),
    };

    // Build column declarations from provided specs (names already validated).
    let column_decls: Vec<ColumnDeclaration> = column_specs
        .iter()
        .map(|spec| ColumnDeclaration::new(spec.name.clone(), spec.column_type.unwrap_or(ColumnType::Text)))
        .collect();
    let schema = DatasetSchema {
        columns: column_decls,
        primary_key_column: None,
    };

    let mut typed_rows: Vec<BTreeMap<String, TypedValue>> = Vec::with_capacity(arr.len());
    for element in arr {
        let obj = match element {
            JsonValue::Object(o) => o,
            _ => return Err("moot_file_dataset: each row must be a JSON object".to_string()),
        };
        let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
        for spec in column_specs {
            let tv = obj
                .get(&spec.name)
                .map(|jv| json_value_to_typed(jv, spec.column_type))
                .unwrap_or(TypedValue::Null);
            row.insert(spec.name.clone(), tv);
        }
        // Keys not in the column spec are silently dropped (no unknown-column path).
        typed_rows.push(row);
    }

    Ok(ParseResult { schema, rows: typed_rows })
}

// ---------------------------------------------------------------------------
// Column spec parsing
// ---------------------------------------------------------------------------

/// A partially-parsed column specification from the `columns` argument.
struct ColumnSpec {
    name: String,
    column_type: Option<ColumnType>,
}

/// Parse the `columns` argument to a list of ColumnSpec.
fn parse_column_specs(value: Option<&JsonValue>) -> Result<Vec<ColumnSpec>, JSONRPCError> {
    let arr = match value {
        None => return Ok(vec![]),
        Some(JsonValue::Array(a)) => a,
        _ => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "moot_file_dataset: columns must be an array",
            ))
        }
    };

    let mut specs = Vec::with_capacity(arr.len());
    for element in arr {
        let obj = match element {
            JsonValue::Object(o) => o,
            _ => {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "moot_file_dataset: each column must be an object with 'name'",
                ))
            }
        };
        let name = obj
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "moot_file_dataset: each column must be an object with 'name'",
                )
            })?
            .to_string();

        let column_type: Option<ColumnType> = if let Some(type_str) = obj.get("type").and_then(|v| v.as_str()) {
            let ct = match type_str.to_lowercase().as_str() {
                "text" | "string" => ColumnType::Text,
                "int" | "integer" => ColumnType::Int,
                "float" | "real" | "double" => ColumnType::Float,
                "bool" | "boolean" => ColumnType::Bool,
                other => {
                    return Err(JSONRPCError::new(
                        JSONRPCErrorCode::INVALID_PARAMS,
                        format!(
                            "moot_file_dataset: unknown column type '{}'. Supported: text, int, float, bool",
                            other
                        ),
                    ))
                }
            };
            Some(ct)
        } else {
            None // Will be inferred from values.
        };

        specs.push(ColumnSpec { name, column_type });
    }
    Ok(specs)
}

// ---------------------------------------------------------------------------
// Type inference and conversion
// ---------------------------------------------------------------------------

/// Infer the column type from a sample of non-nil string values.
///
/// Strategy: if every sample parses as Int64 → Int;
/// if every sample parses as f64 → Float; else Text.
/// Empty samples default to Text.
fn infer_column_type(values: &[&str]) -> ColumnType {
    if values.is_empty() {
        return ColumnType::Text;
    }
    if values.iter().all(|s| s.parse::<i64>().is_ok()) {
        return ColumnType::Int;
    }
    if values.iter().all(|s| s.parse::<f64>().is_ok()) {
        return ColumnType::Float;
    }
    ColumnType::Text
}

/// Convert a raw string cell (or None for empty/missing) to a TypedValue.
fn parse_typed_value(raw: Option<&str>, col_type: ColumnType) -> TypedValue {
    let s = match raw {
        None => return TypedValue::Null,
        Some(s) => s,
    };
    match col_type {
        ColumnType::Int => {
            if let Ok(i) = s.parse::<i64>() {
                TypedValue::Int(i)
            } else if s.is_empty() {
                TypedValue::Null
            } else {
                TypedValue::Text(s.to_string())
            }
        }
        ColumnType::Float => {
            if let Ok(d) = s.parse::<f64>() {
                TypedValue::Float(d)
            } else if s.is_empty() {
                TypedValue::Null
            } else {
                TypedValue::Text(s.to_string())
            }
        }
        ColumnType::Bool => match s.to_lowercase().as_str() {
            "true" | "1" | "yes" => TypedValue::Bool(true),
            "false" | "0" | "no" => TypedValue::Bool(false),
            _ => TypedValue::Text(s.to_string()),
        },
        ColumnType::Text => TypedValue::Text(s.to_string()),
        // Other types stored as text in v1.
        _ => TypedValue::Text(s.to_string()),
    }
}

/// Convert a JsonValue to TypedValue, optionally using a column type hint.
///
/// Mirrors Swift DatasetTools.jsonValueToTyped(_:hint:).
/// Type inference on string JsonValues without a hint: try Int64, then f64, else Text.
pub(crate) fn json_value_to_typed(jv: &JsonValue, hint: Option<ColumnType>) -> TypedValue {
    match jv {
        JsonValue::Null => TypedValue::Null,
        JsonValue::Bool(b) => TypedValue::Bool(*b),
        JsonValue::Integer(i) => TypedValue::Int(*i),
        JsonValue::Double(d) => {
            // Promote to int if hint demands it and the value is losslessly representable.
            if let Some(ColumnType::Int) = hint {
                if let Some(i) = int64_exact(*d) {
                    return TypedValue::Int(i);
                }
            }
            TypedValue::Float(*d)
        }
        JsonValue::String(s) => {
            if let Some(hint_type) = hint {
                parse_typed_value(Some(s.as_str()), hint_type)
            } else {
                // Type inference: try Int64, then f64, else text.
                if let Ok(i) = s.parse::<i64>() {
                    TypedValue::Int(i)
                } else if let Ok(d) = s.parse::<f64>() {
                    TypedValue::Float(d)
                } else {
                    TypedValue::Text(s.clone())
                }
            }
        }
        JsonValue::Object(_) | JsonValue::Array(_) => {
            // Nested structures stored as text in v1 (no nested-document storage).
            TypedValue::Text(format!("{:?}", jv))
        }
    }
}

/// Lossless f64 → i64 conversion (mirrors Swift's `Int64(exactly: d)`).
fn int64_exact(d: f64) -> Option<i64> {
    if d.fract() == 0.0 && d >= i64::MIN as f64 && d <= i64::MAX as f64 {
        Some(d as i64)
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// TypedValue → string (f64 wire discipline)
// ---------------------------------------------------------------------------

/// Serialize a TypedValue to its human-readable text form for tool output.
///
/// Float discipline: f64 uses `format!("{}", d)` which is the Rust ryu
/// shortest-roundtrip decimal string — matches Swift's String(d) exactly.
/// Never f32: no narrowing cast at any point in this file.
///
/// Mirrors Swift DatasetTools.typedValueToString(_:).
pub(crate) fn typed_value_to_string(v: &TypedValue) -> String {
    match v {
        TypedValue::Null => "null".to_string(),
        TypedValue::Bool(b) => if *b { "true" } else { "false" }.to_string(),
        TypedValue::Int(i) => format!("{}", i),
        TypedValue::Bitmap(i) => format!("{}", i),
        // f64 shortest roundtrip via ryu: format!("{}", d) uses ryu in Rust 1.x.
        TypedValue::Float(d) => format!("{}", d),
        TypedValue::Text(s) => {
            let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
            format!("\"{}\"", escaped)
        }
        TypedValue::Uuid(u) => format!("\"{}\"", u),
        TypedValue::Timestamp(ms) => {
            // Epoch ms → ISO8601 string (matches Swift's ISO8601DateFormatter).
            format!("\"{}\"", epoch_ms_to_iso8601(*ms))
        }
        _ => format!("<{:?}>", v),
    }
}

/// Convert epoch milliseconds to an ISO8601 UTC string.
/// Matches Swift's ISO8601DateFormatter().string(from:) output format.
fn epoch_ms_to_iso8601(ms: i64) -> String {
    // A minimal implementation: delegate to the iso8601 string we can build
    // from the components. We use a fixed-format calculation.
    let secs = ms / 1000;
    let year = seconds_to_ymd(secs);
    year
}

/// Convert epoch seconds to "YYYY-MM-DDTHH:MM:SSZ" string.
fn seconds_to_ymd(total_secs: i64) -> String {
    // Algorithm: convert Unix timestamp to calendar date.
    let secs_in_day: i64 = 86400;
    let days = total_secs.div_euclid(secs_in_day);
    let time = total_secs.rem_euclid(secs_in_day);
    let h = time / 3600;
    let m = (time % 3600) / 60;
    let s = time % 60;

    // Julian Day Number algorithm (days since 1970-01-01 = JDN 2440588).
    let jdn = days + 2_440_588;
    // Algorithm from Richards (2013), "Calendrical calculations".
    let f = jdn + 1401 + (((4 * jdn + 274277) / 146097) * 3) / 4 - 38;
    let e = 4 * f + 3;
    let g = (e % 1461) / 4;
    let h2 = 5 * g + 2;
    let day = (h2 % 153) / 5 + 1;
    let month = (h2 / 153 + 2) % 12 + 1;
    let year = e / 1461 - 4716 + (14 - month) / 12;

    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", year, month, day, h, m, s)
}

// ---------------------------------------------------------------------------
// Predicate parsing
// ---------------------------------------------------------------------------

/// Parse a `where` argument to a StoragePredicate.
///
/// Supported format (JsonValue object or string-encoded JSON):
///   Single condition: {"col":"name","op":"eq|neq|lt|lte|gt|gte|is_null|is_not_null","val":value}
///   Compound: {"and":[...]} or {"or":[...]}
///   Absent/null: full table scan (None predicate).
///
/// Mirrors Swift DatasetTools.parseWherePredicate(_:tableName:).
pub(crate) fn parse_where_predicate(
    value: Option<&JsonValue>,
    table_name: &str,
) -> Result<Option<StoragePredicate>, JSONRPCError> {
    match value {
        None | Some(JsonValue::Null) => Ok(None),
        Some(JsonValue::Object(obj)) => {
            let pred = parse_predicate(obj, table_name)?;
            Ok(Some(pred))
        }
        Some(JsonValue::String(s)) => {
            // Caller may have sent a JSON-encoded predicate string.
            if let Ok(sv) = serde_json::from_str::<serde_json::Value>(s) {
                if let serde_json::Value::Object(m) = sv {
                    let obj: BTreeMap<String, JsonValue> = m
                        .into_iter()
                        .map(|(k, v)| (k, JsonValue::from(v)))
                        .collect();
                    let pred = parse_predicate(&obj, table_name)?;
                    return Ok(Some(pred));
                }
            }
            // Unparseable string → no predicate (full scan).
            Ok(None)
        }
        // null / bool / integer / double / array: no predicate.
        _ => Ok(None),
    }
}

fn parse_predicate(
    obj: &BTreeMap<String, JsonValue>,
    table_name: &str,
) -> Result<StoragePredicate, JSONRPCError> {
    // Compound: {"and":[...]}
    if let Some(JsonValue::Array(and_arr)) = obj.get("and") {
        let children: Result<Vec<StoragePredicate>, JSONRPCError> = and_arr
            .iter()
            .map(|element| {
                let child_obj = match element {
                    JsonValue::Object(o) => o,
                    _ => {
                        return Err(JSONRPCError::new(
                            JSONRPCErrorCode::INVALID_PARAMS,
                            "moot_dataset_query: 'and' elements must be JSON objects",
                        ))
                    }
                };
                parse_predicate(child_obj, table_name)
            })
            .collect();
        return Ok(StoragePredicate::And(children?));
    }

    // Compound: {"or":[...]}
    if let Some(JsonValue::Array(or_arr)) = obj.get("or") {
        let children: Result<Vec<StoragePredicate>, JSONRPCError> = or_arr
            .iter()
            .map(|element| {
                let child_obj = match element {
                    JsonValue::Object(o) => o,
                    _ => {
                        return Err(JSONRPCError::new(
                            JSONRPCErrorCode::INVALID_PARAMS,
                            "moot_dataset_query: 'or' elements must be JSON objects",
                        ))
                    }
                };
                parse_predicate(child_obj, table_name)
            })
            .collect();
        return Ok(StoragePredicate::Or(children?));
    }

    // Single condition: {"col":"...","op":"...","val":...}
    let col_str = obj
        .get("col")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "moot_dataset_query: where condition must have a 'col' string",
            )
        })?;
    let op_str = obj
        .get("op")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "moot_dataset_query: where condition must have an 'op' string",
            )
        })?;

    // A3: MCP-layer identifier validation (MX-TAB-SEC-1 A3).
    //
    // Validate the column name at parse time before it reaches the backend.
    // This is an independent first gate against prompt injection — a hostile
    // client supplying col: "name; DROP TABLE x" is rejected here with a
    // clean invalid-params error rather than reaching SQL generation.
    //
    // The backend guard at query execution is the second independent layer;
    // two checks exist by design (belt-and-suspenders; comment this intent
    // on the backend side too per the security review spec).
    if let Err(e) = validate_dataset_column_identifier(col_str) {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!(
                "moot_dataset_query: invalid column identifier in where condition \
                'col': \"{}\". Column names must match [A-Za-z_][A-Za-z0-9_]*. ({})",
                col_str, e
            ),
        ));
    }

    let column = Column::new(table_name, col_str);

    // Null checks (no value needed).
    if op_str == "is_null" {
        return Ok(StoragePredicate::IsNull(column));
    }
    if op_str == "is_not_null" {
        return Ok(StoragePredicate::IsNotNull(column));
    }

    // Comparison ops require a value.
    let val_jv = obj.get("val").ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("moot_dataset_query: op '{}' requires a 'val' field", op_str),
        )
    })?;
    let typed_val = json_value_to_typed(val_jv, None);

    match op_str {
        "eq" => Ok(StoragePredicate::Eq(column, typed_val)),
        "neq" => Ok(StoragePredicate::Neq(column, typed_val)),
        "lt" => Ok(StoragePredicate::Lt(column, typed_val)),
        "lte" => Ok(StoragePredicate::Lte(column, typed_val)),
        "gt" => Ok(StoragePredicate::Gt(column, typed_val)),
        "gte" => Ok(StoragePredicate::Gte(column, typed_val)),
        other => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!(
                "moot_dataset_query: unknown op '{}'. \
                Supported: eq, neq, lt, lte, gt, gte, is_null, is_not_null, and, or",
                other
            ),
        )),
    }
}

// ---------------------------------------------------------------------------
// OrderBy parsing
// ---------------------------------------------------------------------------

/// Parse an `order_by` argument to an OrderClause array.
///
/// Accepts: array of {"col":"name","dir":"asc|desc"} objects.
/// Absent or null → [] (no ordering).
///
/// Mirrors Swift DatasetTools.parseOrderBy(_:tableName:).
pub(crate) fn parse_order_by(
    value: Option<&JsonValue>,
    table_name: &str,
) -> Result<Vec<OrderClause>, JSONRPCError> {
    let arr = match value {
        None | Some(JsonValue::Null) => return Ok(vec![]),
        Some(JsonValue::Array(a)) if !a.is_empty() => a,
        _ => return Ok(vec![]),
    };

    let mut result = Vec::with_capacity(arr.len());
    for element in arr {
        let obj = match element {
            JsonValue::Object(o) => o,
            _ => {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "moot_dataset_query: each order_by element must have a 'col' string",
                ))
            }
        };
        let col_str = obj
            .get("col")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "moot_dataset_query: each order_by element must have a 'col' string",
                )
            })?;
        let dir_str = obj
            .get("dir")
            .and_then(|v| v.as_str())
            .unwrap_or("asc");
        let direction = match dir_str.to_lowercase().as_str() {
            "asc" | "ascending" => OrderDirection::Ascending,
            "desc" | "descending" => OrderDirection::Descending,
            other => {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!(
                        "moot_dataset_query: order_by 'dir' must be 'asc' or 'desc'; got '{}'",
                        other
                    ),
                ))
            }
        };
        // A3: MCP-layer identifier validation in order_by (MX-TAB-SEC-1 A3).
        //
        // Same two-layer intent as the where-predicate guard: reject hostile column
        // names at the MCP parse boundary before they reach the backend. The backend
        // guard is the second independent layer.
        if let Err(e) = validate_dataset_column_identifier(col_str) {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!(
                    "moot_dataset_query: invalid column identifier in order_by \
                    'col': \"{}\". Column names must match [A-Za-z_][A-Za-z0-9_]*. ({})",
                    col_str, e
                ),
            ));
        }

        result.push(OrderClause::new(Column::new(table_name, col_str), direction));
    }
    Ok(result)
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

/// Decode the `sensitivity` argument to a raw i64 for capture_dataset_handle.
///
/// Mirrors Swift DatasetTools.decodeSensitivity(_:).
/// AdjectiveSensitivity raw values: Normal=0, Elevated=16, Restricted=32, Secret=48.
fn decode_sensitivity_raw(args: &BTreeMap<String, JsonValue>) -> Result<i64, JSONRPCError> {
    match args.get("sensitivity") {
        None | Some(JsonValue::Null) => Ok(0), // Normal
        Some(JsonValue::String(s)) => match s.to_lowercase().as_str() {
            "normal" => Ok(0),
            "elevated" => Ok(16),
            "restricted" => Ok(32),
            "secret" => Ok(48),
            other => Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!(
                    "sensitivity must be normal, elevated, restricted, or secret; got '{}'",
                    other
                ),
            )),
        },
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "sensitivity must be a string (normal, elevated, restricted, secret)",
        )),
    }
}

// ---------------------------------------------------------------------------
// Column type label (for DatasetColumnSummary.data_type)
// ---------------------------------------------------------------------------

/// Map a ColumnType to the data_type label string stored in DatasetColumnSummary.
///
/// CRITICAL: these strings must be byte-identical to what Swift produces via
/// `$0.type.rawValue.uppercased()`. Swift's ColumnType enum uses the case name
/// as rawValue (no explicit association), and all case names are lowercase:
///   ColumnType.int.rawValue   = "int"   → uppercased → "INT"
///   ColumnType.float.rawValue = "float" → uppercased → "FLOAT"
///   ColumnType.text.rawValue  = "text"  → uppercased → "TEXT"
///   ColumnType.bool.rawValue  = "bool"  → uppercased → "BOOL"
///
/// The data_type string is embedded in the signature preimage (MX-TAB-5),
/// so divergence between Rust and Swift would produce mismatched signatures.
fn column_type_label(col_type: ColumnType) -> String {
    match col_type {
        ColumnType::Int => "INT".to_string(),
        ColumnType::Float => "FLOAT".to_string(),
        ColumnType::Text => "TEXT".to_string(),
        ColumnType::Bool => "BOOL".to_string(),
        ColumnType::Uuid => "UUID".to_string(),
        ColumnType::Bitmap => "BITMAP".to_string(),
        ColumnType::Timestamp => "TIMESTAMP".to_string(),
        ColumnType::Blob => "BLOB".to_string(),
        ColumnType::Json => "JSON".to_string(),
        ColumnType::Hlc => "HLC".to_string(),
        ColumnType::Fingerprint => "FINGERPRINT".to_string(),
    }
}

// ---------------------------------------------------------------------------
// Lens helpers (used by lens_tools.rs for dataset_id dispatch)
// ---------------------------------------------------------------------------

/// Resolve a dataset UUID from a string, check the handle is active, and return
/// (dataset_id, handle_drawer, DatasetHandleContent?, DatasetStore).
///
/// Soft refusals (withdrawn, not found) return `Ok(error_result(...))` via the
/// caller's return. Hard faults (invalid UUID, estate inaccessible, storage absent)
/// return `Err(JSONRPCError)` as transport-level faults.
///
/// Mirrors Swift LensTools.resolveDataset(idStr:kit:handle:toolName:).
pub(crate) fn resolve_lens_dataset(
    id_str: &str,
    tool_name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<LensDatasetResolution, LensDatasetResolutionError> {
    let dataset_id = Uuid::parse_str(id_str).map_err(|_| {
        LensDatasetResolutionError::Fault(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("{}: dataset_id is not a valid UUID: {}", tool_name, id_str),
        ))
    })?;

    let open = registry.resolve_direct(args).map_err(LensDatasetResolutionError::Fault)?;

    let coord = open.coord.lock().map_err(|_| {
        LensDatasetResolutionError::Fault(JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("{}: estate coordinator lock poisoned", tool_name),
        ))
    })?;
    let locus_estate = coord.estate_for(&open.handle).map_err(|e| {
        LensDatasetResolutionError::Fault(JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("{}: estate not accessible: {}", tool_name, describe_glk_error(&e)),
        ))
    })?;

    let handle_drawer = match locus_estate.resolve_active_dataset_handle(dataset_id) {
        Ok(d) => d,
        Err(LocusKitError::WithdrawnDatasetHandle { dataset_id: did }) => {
            let msg = format!(
                "{}: dataset is withdrawn (id: {}). \
                Restore it with moot_update_memory mutation=revive before using this lens.",
                tool_name, did
            );
            return Err(LensDatasetResolutionError::Refusal(error_result(&msg)));
        }
        Err(e) => {
            let msg = format!("{}: dataset handle not found: {}", tool_name, e);
            return Err(LensDatasetResolutionError::Refusal(error_result(&msg)));
        }
    };
    drop(coord);

    // Content is optional — callers that need column schema check for None.
    let content = DatasetHandleContent::decode(&handle_drawer.content).ok();

    let storage = match open.store.storage() {
        Some(s) => s,
        None => {
            return Err(LensDatasetResolutionError::Fault(JSONRPCError::new(
                JSONRPCErrorCode::INTERNAL_ERROR,
                format!("{}: estate storage does not support datasets", tool_name),
            )));
        }
    };
    let dataset_store = storage.dataset_store().map_err(|e| {
        LensDatasetResolutionError::Fault(JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("{}: estate storage does not support datasets: {}", tool_name, e),
        ))
    })?;

    Ok(LensDatasetResolution {
        dataset_id,
        handle_drawer,
        content,
        dataset_store,
    })
}

/// Successful resolution from `resolve_lens_dataset`.
#[allow(dead_code)] // handle_drawer and content are exposed for callers; not all lens paths use them
pub(crate) struct LensDatasetResolution {
    pub dataset_id: Uuid,
    pub handle_drawer: locus_kit::drawer::Drawer,
    pub content: Option<DatasetHandleContent>,
    pub dataset_store: Arc<dyn persistence_kit::dataset_store::DatasetStore>,
}

/// Error type for `resolve_lens_dataset` — mirrors Swift's `DatasetResolutionError`.
pub(crate) enum LensDatasetResolutionError {
    /// Soft refusal: return this JSON value as the tool result (isError:true).
    Refusal(serde_json::Value),
    /// Hard fault: rethrow as a JSONRPCError (transport-level error).
    Fault(JSONRPCError),
}

/// Row cap for all dataset-mode lens queries.
/// Matches CognitionKit::dataset_cohesion::SCAN_CAP (10 000 rows).
/// Bounds scan cost; callers may supply a smaller `limit`.
pub(crate) const DATASET_LENS_ROW_CAP: usize = cognition_kit::dataset_cohesion::SCAN_CAP;

// ---------------------------------------------------------------------------
// Lens conversion helpers — used by lens_tools.rs dataset_id dispatch paths
// ---------------------------------------------------------------------------

/// Convert a TypedValue to a `DatasetColumnValue` for cohesion scoring.
///
/// Mirrors Swift `LensTools.typedValueToDatasetColumnValue(_:)`:
///   Int/Bitmap/Float → Numeric(f64)
///   Bool/Text/Uuid/Timestamp → Categorical(String)
///   Null → Null
pub(crate) fn typed_value_to_dataset_column_value(
    tv: &TypedValue,
) -> cognition_kit::dataset_cohesion::DatasetColumnValue {
    use cognition_kit::dataset_cohesion::DatasetColumnValue;
    match tv {
        TypedValue::Int(i) => DatasetColumnValue::Numeric(*i as f64),
        TypedValue::Bitmap(i) => DatasetColumnValue::Numeric(*i as f64),
        TypedValue::Float(d) => DatasetColumnValue::Numeric(*d),
        TypedValue::Null => DatasetColumnValue::Null,
        TypedValue::Bool(b) => DatasetColumnValue::Categorical(
            if *b { "true" } else { "false" }.to_string()
        ),
        TypedValue::Text(s) => DatasetColumnValue::Categorical(s.clone()),
        TypedValue::Uuid(u) => DatasetColumnValue::Categorical(u.to_string()),
        TypedValue::Timestamp(ms) => DatasetColumnValue::Categorical(epoch_ms_to_iso8601(*ms)),
        // Blob/Json/Hlc/Fingerprint: no representable value for lens scoring.
        _ => DatasetColumnValue::Null,
    }
}

/// Convert a TypedValue to a bare label string for association mining.
///
/// Returns `None` for Null (row excluded from the label matrix entirely).
/// Returns `Some(string)` for all representable variants.
/// Mirrors Swift `LensTools.typedValueToLabelString(_:)`:
///   null → None
///   bool → "true"/"false" (no quoting)
///   int → "{i}" (decimal)
///   float → "{d}" (f64 shortest roundtrip via ryu)
///   text → "{s}" (bare — no escaping, no quotes)
///   uuid → "{uuid}"
///   timestamp → ISO8601 string
pub(crate) fn typed_value_to_label_string(tv: &TypedValue) -> Option<String> {
    match tv {
        TypedValue::Null => None,
        TypedValue::Bool(b) => Some(if *b { "true" } else { "false" }.to_string()),
        TypedValue::Int(i) => Some(format!("{}", i)),
        TypedValue::Bitmap(i) => Some(format!("{}", i)),
        TypedValue::Float(d) => Some(format!("{}", d)),
        TypedValue::Text(s) => Some(s.clone()),
        TypedValue::Uuid(u) => Some(u.to_string()),
        TypedValue::Timestamp(ms) => Some(epoch_ms_to_iso8601(*ms)),
        // Blob/Json/Hlc/Fingerprint: no label string available.
        _ => None,
    }
}
