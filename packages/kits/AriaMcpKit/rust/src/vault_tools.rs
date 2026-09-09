//! Vault tool surface — the `moot_vault_*` family backed by `vault-kit`.
//!
//! Mirrors Swift `VaultTools.swift`: export writes the vault + the SHA-256
//! sidecar manifest at `.moot/export-manifest.json`; status reads only the
//! manifest; reconcile re-hashes and diffs; import delegates to `VaultBridge`.
//! `moot_vault_job` polls a completed-job ledger (see below).
//!
//! ## SHA-256 sidecar manifest (Vault drift and candidate handling decision b)
//!
//! VaultKit's bridge writes no per-note content hash. The ARIA layer (this
//! module) owns the drift stamp. After a successful `VaultBridge::export`,
//! `moot_vault_export` SHA-256 hashes ONLY the paths the export wrote
//! (the written-paths certification receipt from `ExportReport::note_paths`)
//! and writes a manifest JSON to `.moot/export-manifest.json` (schema v2).
//! Hashing only the export's written paths certifies exactly the notes whose
//! disk content agreed with the estate at export time — stamping unwritten
//! notes would certify agreement nobody verified (VR-01 Finding A).
//!
//! `.moot/` is hidden (leading `.`), so `ObsidianAdapter::to_ir` (which
//! skips hidden files) never reads the manifest as a note on re-import.
//!
//! SHA-256 is chosen for file-identity detection (did these bytes change?),
//! matching Swift's CryptoKit choice. It is unrelated to the substrate's
//! FNV-1a SimHash primitives, which answer a semantic-similarity question.
//!
//! ## Reconcile two-step workflow (B2-3)
//!
//! `moot_vault_reconcile` is a two-step workflow:
//!   - Dry-run (default, `apply` absent or `false`): re-hashes the vault,
//!     diffs against the export manifest, and returns the candidate list.
//!     Writes nothing. Mirrors the original "return-only seam" from
//!     Vault drift and candidate handling decision c/d, now documented as the dry-run mode.
//!   - Apply mode (`apply=true`): actions the added/modified candidates by
//!     calling `VaultBridge::import_vault` synchronously. Idempotent per
//!     note's `stable_source_key` — a re-reconcile after a partial run is
//!     safe. Deleted files are always reported only; no drawer is expunged.
//!
//! ## moot_vault_job — synchronous-backend parity (Bob's ruling 2026-06-12)
//!
//! Swift's `moot_vault_export` and `moot_vault_import` are async: they return
//! a `job_id` immediately and complete the work in a background Task. The Rust
//! backend is synchronous by design — `run_export` and `run_import` block
//! until completion before returning. To achieve tool-surface parity (53/53
//! tool count), the Rust port implements honest synchronous semantics:
//!
//!   1. On completion, `run_export` / `run_import` assign a UUID job ID,
//!      record a completed `VaultJobRecord` in the in-process `VaultJobLedger`,
//!      and return both the job ID and the result summary in one response.
//!   2. `moot_vault_job(id)` looks up the completed record in the ledger.
//!      A known ID returns the full completed record (same field names as Swift).
//!      An unknown ID returns the Swift-identical not-found shape.
//!   3. The ledger is bounded to the last 100 jobs (insertion order) to prevent
//!      unbounded memory growth in long-running server processes.
//!
//! This design is truthful: the caller is never told a job is "running" when
//! it has already finished synchronously. The `moot_vault_job` tool is present,
//! schema-identical to Swift, and never returns `methodNotFound`.

use crate::dispatch::{describe_glk_error, error_result, text_result};
use crate::estate_registry::{EstateRegistry, OpenEstate};
use genius_locus_kit::dataset_signatures::{compute_dataset_signatures, DATASET_SIGNATURE_SAMPLE_SIZE};
use genius_locus_kit::EncodeSpeed;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode};
use locus_kit::dataset_handle::{DatasetColumnSummary, DatasetHandleContent};
use persistence_kit::dataset_store::{ColumnStats, DatasetSchema, validate_dataset_column_identifier};
use persistence_kit::schema::ColumnDeclaration;
use persistence_kit::types::{ColumnType, TypedValue};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use vault_kit::{DrawerMapping, ExportReport, ImportReport, ObsidianAdapter, VaultBridge, VaultExportScope};

// ---------------------------------------------------------------------------
// Manifest data structures
// ---------------------------------------------------------------------------

/// Manifest schema version stamped by this build. Version 2 means every entry
/// is a CERTIFICATION: the note's disk content was known to agree with the
/// estate's record when stamped (written by the export). A manifest without a
/// `version` key is legacy: it was built by hashing every `.md` on disk, so
/// its entries certify nothing — reconcile must not treat a hash match as
/// "unchanged" (VR-01 Finding A). Mirrors Swift `VaultTools.manifestSchemaVersion`.
pub const MANIFEST_SCHEMA_VERSION: u32 = 2;

/// One note's SHA-256 stamp at export time. Mirrors Swift `ManifestEntry`.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ManifestEntry {
    pub sha256: String,
}

/// The sidecar manifest `moot_vault_export` writes. Mirrors Swift `ExportManifest`.
///
/// - `version`:     schema version (`MANIFEST_SCHEMA_VERSION`). `None` on legacy
///   manifests (no `version` key in JSON) whose hashes certify nothing —
///   reconcile classifies every note under a legacy manifest as changed /
///   needs-review, failing toward surfacing rather than silence.
/// - `exported_at`: ISO8601 instant the export ran (display only, not used in diff).
///   Serializes as `exportedAt` (camelCase) to match Swift's manifest.json key.
/// - `note_count`:  number of notes at export time — NOT written to manifest.json
///   (`skip_serializing`) so diffs against Swift-written manifests stay clean.
///   Read from `files.len()` on the deserialized struct instead.
/// - `files`:       vault-relative path → SHA-256 stamp. Version 2: ONLY paths
///   the export wrote — never a whole-disk enumeration.
///
/// `files` is keyed by forward-slash vault-relative path matching the keys
/// `ObsidianAdapter::to_ir` produces, so re-hashing after a re-read aligns.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ExportManifest {
    /// Manifest schema version (see `MANIFEST_SCHEMA_VERSION`). `None` on
    /// legacy manifests, whose hashes are not certifications — reconcile
    /// classifies every note under a legacy manifest as changed /
    /// needs-review, failing toward surfacing rather than silence.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub version: Option<u32>,
    // Serializes as "exportedAt" (camelCase) to match Swift's manifest.json key.
    // The alias accepts "exported_at" (snake_case) so old Rust-written manifests
    // still deserialize correctly on vault_status / reconcile reads.
    #[serde(rename = "exportedAt", alias = "exported_at")]
    pub exported_at: String,
    // note_count is a convenience field computed at build time — not written to
    // manifest.json (skip_serializing) so the file matches Swift's key set.
    // After deserialization, use files.len() instead of this field (it will be 0).
    #[serde(skip_serializing, default)]
    pub note_count: usize,
    /// BTreeMap so JSON serialization is key-sorted and byte-stable.
    pub files: BTreeMap<String, ManifestEntry>,
}

/// Direct, typed status for a vault export manifest. This is shared by the
/// v2 mobility lower adapter without asking it to inspect a v1 text result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultStatusSnapshot {
    pub manifest_present: bool,
    pub path: String,
    pub last_export: Option<String>,
    pub note_count: Option<u64>,
}

/// One candidate surfaced by a vault reconciliation dry run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultReconcileCandidate {
    pub stable_source_key: String,
    pub vault_path: String,
    pub sha256: String,
}

/// Direct, typed reconciliation receipt. It deliberately retains only the
/// values that are authoritative for v2; legacy prose remains a v1 concern.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultReconcileSnapshot {
    pub added: Vec<String>,
    pub modified: Vec<String>,
    pub deleted: Vec<String>,
    pub missing: Vec<String>,
    pub import_set_count: u64,
    pub candidate_count: u64,
    pub missing_count: u64,
    pub applied: bool,
    pub candidates: Option<Vec<VaultReconcileCandidate>>,
}

// ---------------------------------------------------------------------------
// Vault job ledger — synchronous parity for moot_vault_job
// (Bob's ruling 2026-06-12: tool surface parity matters even when the backend
// is synchronous. Rust vault ops complete before returning, so the ledger
// records the completed result immediately. moot_vault_job(id) looks it up.)
// ---------------------------------------------------------------------------

/// Whether the recorded job was a vault import or a vault export.
/// Mirrors Swift `JobKind` from `VaultJobRegistry.swift`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VaultJobKind {
    Import,
    Export,
}

impl VaultJobKind {
    /// Raw string used in response text. Mirrors Swift `JobKind.rawValue`.
    fn as_str(&self) -> &'static str {
        match self {
            VaultJobKind::Import => "import",
            VaultJobKind::Export => "export",
        }
    }
}

/// Outcome counts from a completed vault import.
/// Field names mirror Swift `ImportResult` from `VaultJobRegistry.swift`.
/// The two skip-count fields were added by the vault idempotency + cluster-C
/// fixes and are surfaced in `moot_vault_job` results so an idempotent
/// re-import is observable. Mirrors Swift `ImportResult` exactly.
#[derive(Debug, Clone)]
pub struct ImportJobResult {
    pub drawers_written: i64,
    pub drawers_updated: i64,
    pub items_skipped: i64,
    pub tunnels_created: i64,
    pub fdc_classified: i64,
    pub fdc_unclassified: i64,
    /// Drawers whose content was byte-identical and were skipped (idempotent re-import).
    pub drawers_skipped_unchanged: i64,
    /// Drawers whose lineage was tombstoned and were therefore skipped.
    pub drawers_skipped_tombstoned: i64,
}

/// Outcome of a completed vault export.
/// Mirrors Swift `ExportResult` from `VaultJobRegistry.swift`.
#[derive(Debug, Clone)]
pub struct ExportJobResult {
    /// Note count at export time.
    pub note_count: usize,
    /// ISO8601 timestamp written to the export manifest.
    pub exported_at: String,
}

/// The payload of a completed vault job.
/// Mirrors Swift `JobResult` from `VaultJobRegistry.swift`.
#[derive(Debug, Clone)]
pub enum VaultJobResult {
    Imported(ImportJobResult),
    Exported(ExportJobResult),
}

/// One completed vault job record stored in the ledger.
/// Mirrors Swift `VaultJob` from `VaultJobRegistry.swift`.
///
/// The Rust backend completes synchronously, so there is no "running" state —
/// records are written to the ledger only on completion. The `elapsed_s` field
/// in `moot_vault_job` responses is always 0.0 (the job was already done when
/// the caller asked about it). This is honest and matches the synchronous-
/// backend contract documented in the module header.
#[derive(Debug, Clone)]
pub struct VaultJobRecord {
    pub job_id: String,
    pub kind: VaultJobKind,
    pub vault_path: String,
    pub result: VaultJobResult,
}

/// Typed terminal snapshot for a locally minted vault job.  The synchronous
/// Rust backend records jobs only after work completes, so this never claims a
/// running state that did not occur.
#[derive(Debug, Clone)]
pub struct VaultJobSnapshot {
    pub job_id: uuid::Uuid,
    pub kind: VaultJobKind,
    pub vault_path: String,
    pub result: VaultJobResult,
}

/// Immediate typed receipt returned by the shared export/import cores.  V1
/// renders it as text and the dormant v2 mobility layer can project it without
/// reading that text back.
#[derive(Debug, Clone)]
pub struct VaultJobLaunch {
    pub job_id: uuid::Uuid,
    pub kind: VaultJobKind,
    pub vault_path: String,
    pub scope: Option<String>,
    pub note_count: Option<usize>,
    pub datasets_processed: usize,
    pub warnings: Vec<String>,
    pub result: VaultJobResult,
}

/// Bounded in-process ledger of completed vault jobs.
///
/// Bounded to `MAX_JOBS` entries (insertion order, oldest evicted first) to
/// prevent unbounded memory growth in long-running servers. Wrapped in
/// `Mutex` so `Dispatcher` can hold it as a shared field accessible via `&self`.
pub struct VaultJobLedger {
    jobs: Mutex<VecDeque<VaultJobRecord>>,
}

/// Maximum completed jobs retained in the ledger before the oldest is evicted.
/// 100 entries: generous for typical usage, bounded for server longevity.
const MAX_JOBS: usize = 100;

impl VaultJobLedger {
    /// Create an empty ledger.
    pub fn new() -> Self {
        VaultJobLedger {
            jobs: Mutex::new(VecDeque::new()),
        }
    }

    /// Record a completed job. Evicts the oldest entry when the ledger is full.
    pub fn record(&self, record: VaultJobRecord) {
        let mut jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        if jobs.len() >= MAX_JOBS {
            jobs.pop_front();
        }
        jobs.push_back(record);
    }

    /// Look up a job by ID. Returns `None` when no such ID is registered.
    pub fn get(&self, job_id: &str) -> Option<VaultJobRecord> {
        let jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        jobs.iter().find(|r| r.job_id == job_id).cloned()
    }

    /// Read a completed job as direct typed data.  The v1 renderer and v2
    /// adapter share this exact lookup rather than parsing rendered job text.
    pub fn snapshot(&self, job_id: uuid::Uuid) -> Option<VaultJobSnapshot> {
        let record = self.get(&job_id.to_string())?;
        Some(VaultJobSnapshot {
            job_id,
            kind: record.kind,
            vault_path: record.vault_path,
            result: record.result,
        })
    }
}

impl Default for VaultJobLedger {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Manifest path constant (mirrors Swift `VaultTools.manifestRelativePath`)
// ---------------------------------------------------------------------------

/// Vault-relative path of the hidden sidecar manifest.
/// `.moot/` is a hidden directory, so `ObsidianAdapter` (`.skipsHiddenFiles`
/// equivalent) never reads the manifest as a note.
const MANIFEST_RELATIVE_PATH: &str = ".moot/export-manifest.json";

// ---------------------------------------------------------------------------
// Public dispatch entry point
// ---------------------------------------------------------------------------

/// Dispatch one of the five `moot_vault_*` tools. Called from
/// `dispatch::dispatch_tool` when `name.starts_with("moot_vault_")`.
///
/// Returns `Ok(serde_json::Value)` in all non-transport-fault cases — even
/// substrate refusals surface as `isError: true` results, matching the Swift
/// discipline. Throws `JSONRPCError` only for missing required arguments.
///
/// `ledger` is the session-scoped `VaultJobLedger` owned by `Dispatcher`.
/// `moot_vault_export` and `moot_vault_import` record completed jobs there;
/// `moot_vault_job` looks them up. The Rust backend is synchronous: jobs are
/// always "complete" when recorded (no "running" state in the ledger).
pub fn dispatch_vault(
    name: &str,
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    ledger: &VaultJobLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    // moot_vault_job only needs a job_id — vaultPath is not required.
    // Mirrors Swift VaultTools.dispatch which branches on name == "moot_vault_job"
    // before the vaultPath extraction block.
    if name == "moot_vault_job" {
        let job_id = args
            .get("job_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "Missing required string argument: job_id",
                )
            })?;
        return Ok(run_job(job_id, ledger));
    }

    // `vaultPath` is required for the remaining four vault tools.
    let vault_path_str = args
        .get("vaultPath")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "Missing required string argument: vaultPath",
            )
        })?;
    let vault_path = PathBuf::from(vault_path_str);

    match name {
        "moot_vault_export" => {
            // Parse the optional `scope` argument before delegating.
            let scope = parse_scope(args.get("scope"))?;
            run_export(args, registry, &vault_path, scope, ledger)
        }
        "moot_vault_import" => run_import(args, registry, &vault_path, ledger),
        "moot_vault_status" => run_status(&vault_path),
        "moot_vault_reconcile" => run_reconcile(args, registry, &vault_path),
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown vault tool: {name}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// `moot_vault_export` — project the estate to the vault, then stamp the
/// SHA-256 sidecar manifest. Mirrors Swift `VaultTools.runExport`.
///
/// Steps:
/// 1. Resolve the target estate.
/// 2. Build a `VaultBridge` with `ObsidianAdapter` and `DrawerMapping::default()`.
/// 3. Call `bridge.export(handle, vault_path, now, scope)` to write the `.md` files.
///    The returned `ExportReport` (note count + data-movement privacy tiers tier-exclusion counts)
///    is not consumed here — the tool's response shape is unchanged; the same
///    counts persist in the audit receipt the bridge writes to the estate diary.
/// 4. Hash every `.md` under the vault root (excluding hidden dirs) with SHA-256.
/// 5. Write the sidecar manifest at `.moot/export-manifest.json`.
/// 6. Assign a UUID job ID, record the completed job in `ledger`, and include
///    the `job_id` in the response so the caller can poll via `moot_vault_job`.
///
/// `scope` controls which drawers are included (default `VaultExportScope::Exportable`,
/// CAND-032 — a default disk export writes only exportable-marked rows; broader
/// scopes like `Believed`/`BelievedIncludingPrivate` are explicit opt-ins).
/// `now` is sampled at the handler boundary — this is a real wall-clock event
/// (the export instant), matching the same precedent in Swift's handler.
///
/// The Rust backend is synchronous: the job is complete before this function
/// returns. The `job_id` is included in the response alongside the result
/// summary so callers that assume async semantics (poll via `moot_vault_job`)
/// work correctly — `moot_vault_job(id)` will immediately return the completed
/// record. This is honest parity: the tool never says "running" for a finished job.
/// Run a synchronous vault export and record the completed job in the ledger.
///
/// # Concurrent-job cap — Rust vs Swift
///
/// The Swift async backend has a 4-job concurrent cap that is enforced by an
/// atomic actor method (`checkAndRegister`) to close a TOCTOU window. The Rust
/// backend has no equivalent TOCTOU risk: the `Dispatcher` is wrapped in
/// `Arc<Mutex<>>` (see `http_server.rs`), which serializes ALL dispatch calls
/// including concurrent HTTP connections. The entire call from cap-check to
/// ledger-record runs within that single critical section, so no two export calls
/// can interleave. A concurrent job cap on the Rust side would therefore be
/// enforced trivially — the Mutex already serializes access.
fn run_export(
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    vault_path: &Path,
    scope: VaultExportScope,
    ledger: &VaultJobLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    let launch = launch_export(args, registry, vault_path, scope, ledger)?;
    Ok(text_result(&render_export_launch(&launch)))
}

/// Shared direct export core.  This performs the v1 work, records the job,
/// and returns the typed receipt consumed by both renderers.
pub fn launch_export(
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    vault_path: &Path,
    scope: VaultExportScope,
    ledger: &VaultJobLedger,
) -> Result<VaultJobLaunch, JSONRPCError> {
    let open = registry.resolve_direct(args)?;
    // mut: VaultBridge::new requires &mut EstateCoordinator (dual-path intake fix
    // — import routes through capture_with_mode which needs mutable coord access).
    // Export only reads the coordinator, but the bridge holds &mut for uniformity.
    let mut coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "vault_export: estate coordinator lock poisoned",
        )
    })?;

    let bridge = VaultBridge::new(
        &mut coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::default(),
    );

    let now_ms = wall_now_ms();
    // VaultKitError implements Display with clean English messages — use it
    // so no internal Rust enum variant names leak to the agent boundary.
    // Capture the report to extract the certification receipt (note_paths) for
    // the manifest — stamping only written paths, not the whole vault (VR-01 Finding A).
    let export_report: ExportReport = bridge.export(&open.handle, vault_path, now_ms, scope, None).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("vault_export: bridge export failed: {e}"),
        )
    })?;

    // Build and write the SHA-256 sidecar manifest. Stamp ONLY the paths the
    // export wrote (its certification receipt) — never a whole-disk enumeration,
    // which would certify unexported notes and hide their edits from every future
    // reconcile (VR-01 Finding A).
    let manifest = build_manifest(vault_path, &export_report.note_paths, now_ms).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("vault_export: manifest build failed: {e}"),
        )
    })?;
    write_manifest(&manifest, vault_path).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("vault_export: manifest write failed: {e}"),
        )
    })?;

    // Post-step (MX-TAB-7b §6): write companion CSV files for dataset handle
    // notes. Non-fatal — CSV export failures are surfaced as response warnings
    // but do not fail the export. The .md handle notes are already correct;
    // CSVs can be regenerated by re-exporting.
    let (dataset_csv_count, csv_warnings) = export_dataset_csvs(vault_path, &open);

    // Assign a UUID job ID and record the completed job in the ledger.
    // The Rust backend completes synchronously, so the job is already done.
    // Including job_id in the response lets callers that poll with moot_vault_job
    // receive the completed record immediately on lookup.
    let job_id = uuid::Uuid::new_v4();
    let export_result = ExportJobResult {
        note_count: manifest.note_count,
        exported_at: manifest.exported_at.clone(),
    };
    ledger.record(VaultJobRecord {
        job_id: job_id.to_string(),
        kind: VaultJobKind::Export,
        vault_path: vault_path.to_string_lossy().into_owned(),
        result: VaultJobResult::Exported(export_result.clone()),
    });
    Ok(VaultJobLaunch {
        job_id,
        kind: VaultJobKind::Export,
        vault_path: vault_path.to_string_lossy().into_owned(),
        scope: Some(scope.as_str().to_owned()),
        note_count: None,
        datasets_processed: dataset_csv_count,
        warnings: csv_warnings,
        result: VaultJobResult::Exported(export_result),
    })
}

fn render_export_launch(launch: &VaultJobLaunch) -> String {
    let mut response_lines = format!(
        "job_id: {}\nvault: {}\nscope: {}\n",
        launch.job_id,
        launch.vault_path,
        launch.scope.as_deref().unwrap_or("exportable"),
    );
    if launch.datasets_processed > 0 {
        response_lines.push_str(&format!("datasetsExported: {}\n", launch.datasets_processed));
    }
    for warning in &launch.warnings { response_lines.push_str(&format!("warning: {warning}\n")); }
    response_lines.push_str("poll: moot_vault_job to check status");
    response_lines
}

/// Parse the optional `scope` argument from the MCP tool input.
///
/// - Absent or `null` → `VaultExportScope::default()` = `Exportable` (CAND-032 —
///   a default disk export writes only exportable-marked rows).
/// - Known string → the matching scope.
/// - Unknown string → `JSONRPCError::invalidParams` with the list of valid values.
///
/// Mirrors Swift `VaultTools.parseScope(_:)`.
fn parse_scope(
    value: Option<&crate::jsonrpc::JsonValue>,
) -> Result<VaultExportScope, JSONRPCError> {
    match value {
        None => Ok(VaultExportScope::default()),
        Some(v) => {
            let s = v.as_str().unwrap_or("");
            if s.is_empty() {
                return Ok(VaultExportScope::default());
            }
            VaultExportScope::from_str(s).ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!(
                        "Unknown export scope: \"{s}\". Valid values: {}",
                        VaultExportScope::all_strs().join(", ")
                    ),
                )
            })
        }
    }
}

/// `moot_vault_import` — import a Markdown vault into the estate via the
/// capture seam. Idempotent per note's `stable_source_key`.
/// Mirrors Swift `VaultTools.runImport`.
///
/// The Rust backend is synchronous: the import completes before this function
/// returns. A UUID job ID is assigned, the completed job is recorded in `ledger`,
/// and the response uses the Swift-identical async job shape:
///   job_id / vault / note_count / poll
/// Callers that poll with `moot_vault_job` receive the completed record
/// immediately — the tool never reports "running" for a job that is already done.
///
/// `note_count` is computed as a synchronous pre-scan before running the bridge.
/// The count reflects the vault's pre-import state and appears in the immediate
/// response, mirroring Swift's `hashAllNotes` count in the job_id response.
///
/// Ordering note: in Swift (secfix/c-vault-cap), `checkAndRegister` now runs
/// BEFORE `hashAllNotes` so the cap bounds the expensive preflight. In Rust,
/// `hash_all_notes` still runs before the bridge because the `Dispatcher`
/// `Arc<Mutex<>>` already serializes all dispatch calls — at most one import
/// runs at any time, so no concurrent preflight fan-out is possible and no
/// TOCTOU risk exists. Both ports report `note_count` in the immediate response
/// before bridge completion.
///
/// Run a synchronous vault import and record the completed job in the ledger.
///
/// See `run_export` for a note on the concurrent-job cap and why no TOCTOU
/// fix is required on the Rust side (the `Dispatcher` Mutex serializes calls).
fn run_import(
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    vault_path: &Path,
    ledger: &VaultJobLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    if matches!(args.get("mode").and_then(|value| value.as_str()), Some(mode) if !matches!(mode.to_lowercase().as_str(), "foreground" | "background")) {
        return Ok(error_result(
            "mode must be \"foreground\" or \"background\"; omit it to use the default (foreground)",
        ));
    }
    let launch = launch_import(args, registry, vault_path, ledger)?;
    Ok(text_result(&render_import_launch(&launch)))
}

/// Shared direct import core.  It retains the synchronous Rust completion
/// semantics and returns the terminal receipt without text reconstruction.
pub fn launch_import(
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    vault_path: &Path,
    ledger: &VaultJobLedger,
) -> Result<VaultJobLaunch, JSONRPCError> {
    // Step 1: enumerate all .md notes for the note_count response field and
    // for building the non-dataset path set used by the filtered bridge import.
    //
    // `hash_all_notes` is a pure filesystem enumeration — no estate I/O.
    // On error (e.g. vault path does not exist), default to an empty map;
    // the bridge import will surface the real error below.
    //
    // Slot-safety (secfix/c-vault-jobslot): the Rust backend has no "running"
    // slot concept — `ledger.record()` is only called AFTER the bridge completes
    // successfully. A `hash_all_notes` failure is swallowed with `unwrap_or`
    // and the bridge call below handles the real error. The `Dispatcher`
    // `Arc<Mutex<>>` serialises all calls; no TOCTOU risk.
    let all_md_notes = hash_all_notes(vault_path).unwrap_or_default();
    let note_count = all_md_notes.len();

    // Step 2: scan the vault for dataset handle notes (contentKind: 7).
    //
    // Dataset notes are excluded from the bridge import because DrawerMapping
    // does not re-honour `contentKind` on import — importing them via the
    // standard bridge path would create drawers with contentKind=0 (wrong).
    // Instead, they are imported directly via `capture_dataset_handle` after
    // the bridge finishes (MX-TAB-7b §6).
    //
    // Scan failure is non-fatal: fall back to a full (unfiltered) bridge import.
    let dataset_notes = scan_dataset_notes(vault_path).unwrap_or_default();
    let dataset_note_paths: HashSet<String> =
        dataset_notes.iter().map(|(p, _, _)| p.clone()).collect();

    // Non-dataset paths: the set of .md paths the bridge import will process.
    // When there are no dataset notes, all paths go through the full bridge.
    let non_dataset_paths: HashSet<String> = if dataset_notes.is_empty() {
        HashSet::new() // unused — full import used below
    } else {
        all_md_notes
            .keys()
            .filter(|p| !dataset_note_paths.contains(*p))
            .cloned()
            .collect()
    };

    let open = registry.resolve_direct(args)?;

    // Step 3: mode argument (encode SPEED; WRITE strategy is auto size-gated).
    let mode = match args.get("mode").and_then(|v| v.as_str()).map(|s| s.to_lowercase()) {
        None => EncodeSpeed::Foreground,
        Some(ref s) if s == "foreground" => EncodeSpeed::Foreground,
        Some(ref s) if s == "background" => EncodeSpeed::Background,
        Some(_) => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "mode must be \"foreground\" or \"background\"; omit it to use the default (foreground)",
            ));
        }
    };

    // Step 4: acquire DatasetStore (from open.store, no coord lock required).
    // Obtained before locking coord to avoid holding the lock while doing
    // filesystem I/O. Arc-backed — no lifetime dependency on coord.
    let storage_opt = open.store.storage();
    let dataset_store_opt = storage_opt
        .as_ref()
        .and_then(|s| s.dataset_store().ok());

    // Step 5: bridge import for non-dataset notes.
    // mut: VaultBridge::new requires &mut EstateCoordinator (import routes
    // through capture_with_mode — dual-path intake fix, G7).
    let mut coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "vault_import: estate coordinator lock poisoned",
        )
    })?;

    let mut bridge = VaultBridge::new(
        &mut coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::default(),
    );

    let now_ms = wall_now_ms();

    let report: ImportReport = if dataset_notes.is_empty() {
        // No dataset notes — use the full unfiltered import (unchanged path).
        bridge
            .import_vault(vault_path, &open.handle, now_ms, None, mode)
            .map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("vault_import: bridge import failed: {e}"),
                )
            })?
    } else {
        // Exclude dataset note paths from the bridge import so the bridge
        // does not create wrong-contentKind drawers for them.
        bridge
            .import_vault_filtered(
                vault_path,
                &non_dataset_paths,
                &open.handle,
                now_ms,
                None,
                mode,
            )
            .map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("vault_import: bridge filtered import failed: {e}"),
                )
            })?
    };

    // Release the &mut coord borrow (bridge drops here).
    drop(bridge);

    // Step 6: import dataset notes via the direct estate path.
    //
    // `locus_estate` borrows from `coord` (the MutexGuard). Both must be in
    // scope for the duration of the dataset import loop. `coord` is dropped
    // at the end of this function, after the loop completes.
    let mut dataset_imported = 0usize;
    let mut dataset_warnings: Vec<String> = Vec::new();

    if !dataset_notes.is_empty() {
        match dataset_store_opt {
            None => {
                dataset_warnings.push(
                    "vault_import: estate has no DatasetStore — dataset notes skipped".to_string(),
                );
            }
            Some(ref ds) => {
                match coord.estate_for(&open.handle) {
                    Err(e) => {
                        dataset_warnings.push(format!(
                            "vault_import: estate not accessible for dataset import ({}); dataset notes skipped",
                            describe_glk_error(&e)
                        ));
                    }
                    Ok(locus_estate) => {
                        dataset_imported = import_dataset_notes(
                            vault_path,
                            &dataset_notes,
                            ds.as_ref(),
                            locus_estate,
                            &open.handle,
                            now_ms,
                            &mut dataset_warnings,
                        );
                    }
                }
            }
        }
    }

    // Step 7: record the completed job in the ledger.
    let job_id = uuid::Uuid::new_v4();
    let import_result = ImportJobResult {
        drawers_written: report.drawers_written as i64,
        drawers_updated: report.drawers_updated as i64,
        items_skipped: report.items_skipped as i64,
        tunnels_created: report.tunnels_created as i64,
        fdc_classified: report.fdc_classified as i64,
        fdc_unclassified: report.fdc_unclassified as i64,
        drawers_skipped_unchanged: report.drawers_skipped_unchanged as i64,
        drawers_skipped_tombstoned: report.drawers_skipped_tombstoned as i64,
    };
    ledger.record(VaultJobRecord {
        job_id: job_id.to_string(),
        kind: VaultJobKind::Import,
        vault_path: vault_path.to_string_lossy().into_owned(),
        result: VaultJobResult::Imported(import_result.clone()),
    });
    Ok(VaultJobLaunch {
        job_id,
        kind: VaultJobKind::Import,
        vault_path: vault_path.to_string_lossy().into_owned(),
        scope: None,
        note_count: Some(note_count),
        datasets_processed: dataset_imported,
        warnings: dataset_warnings,
        result: VaultJobResult::Imported(import_result),
    })
}

fn render_import_launch(launch: &VaultJobLaunch) -> String {
    let VaultJobResult::Imported(report) = &launch.result else {
        unreachable!("import launch must hold an import receipt");
    };
    let mut response = format!(
        "job_id: {}\nvault: {}\nnote_count: {}\nstatus: COMPLETE\n\
         drawersWritten: {}\ndrawersUpdated: {}\nitemsSkipped: {}\n\
         tunnelsCreated: {}\nfdcClassified: {}\nfdcUnclassified: {}",
        launch.job_id, launch.vault_path, launch.note_count.unwrap_or(0),
        report.drawers_written, report.drawers_updated, report.items_skipped,
        report.tunnels_created, report.fdc_classified, report.fdc_unclassified,
    );
    if launch.datasets_processed > 0 { response.push_str(&format!("\ndatasetsImported: {}", launch.datasets_processed)); }
    for warning in &launch.warnings { response.push_str(&format!("\nwarning: {warning}")); }
    response
}

/// `moot_vault_status` — report whether the vault carries a manifest and,
/// if so, its header. Pure filesystem read; mutates nothing.
/// Mirrors Swift `VaultTools.runStatus`.
pub fn vault_status_snapshot(vault_path: &Path) -> Result<VaultStatusSnapshot, String> {
    let manifest = read_manifest(vault_path)?;
    Ok(match manifest {
        None => VaultStatusSnapshot {
            manifest_present: false,
            path: vault_path.display().to_string(),
            last_export: None,
            note_count: None,
        },
        Some(manifest) => VaultStatusSnapshot {
            manifest_present: true,
            path: vault_path.display().to_string(),
            last_export: Some(manifest.exported_at),
            note_count: Some(u64::try_from(manifest.files.len()).map_err(|_| "vault_status: note count overflow".to_owned())?),
        },
    })
}

fn run_status(vault_path: &Path) -> Result<serde_json::Value, JSONRPCError> {
    match vault_status_snapshot(vault_path) {
        Err(e) => Ok(error_result(&format!(
            "vault_status: error reading manifest: {e}"
        ))),
        Ok(snapshot) if !snapshot.manifest_present => Ok(text_result(&format!(
            "vault_status: no export manifest at {MANIFEST_RELATIVE_PATH}\npath: {}\n(run moot_vault_export to stamp one)",
            snapshot.path,
        ))),
        Ok(snapshot) => Ok(text_result(&format!(
            "vault_status: manifest present\npath: {}\nnoteCount: {}\nlastExport: {}",
            snapshot.path,
            snapshot.note_count.expect("present manifest has count"),
            snapshot.last_export.expect("present manifest has export time"),
        ))),
    }
}

/// `moot_vault_reconcile` — re-hash the vault's notes, report drift
/// (added / modified / deleted) vs the export manifest, and surface the
/// full import set (candidates ∪ missing) in both modes.
///
/// Dry-run mode (`apply` absent or `false`): computes the selection via
/// `VaultBridge::reconcile_selection` (one estate snapshot, no disk reads),
/// reports the candidates and missing notes, writes nothing. Mirrors Swift
/// `VaultTools.runReconcile`.
///
/// Apply mode (`apply=true`): actions the selection via
/// `VaultBridge::import_vault_reconciling`, which returns the exact imported
/// set alongside the `ImportReport`. The surfaced set and the imported set
/// are computed by the same `missing_paths` body, so the review gate holds:
/// apply can never import a note the dry-run would not list (VR-01 Finding B).
/// After the import, the manifest is re-stamped with the imported paths' hashes
/// from the `current` scan so those entries become v2 certifications.
/// Idempotent per note's `stable_source_key`. Deleted files are always reported
/// only; no drawer is expunged. Mirrors Swift `VaultTools.runReconcile(apply:true)`.
fn run_reconcile(
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    vault_path: &Path,
) -> Result<serde_json::Value, JSONRPCError> {
    // `apply` is optional; absent or non-true means dry-run.
    let apply = args
        .get("apply")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Resolve estateID unconditionally — dry-run and apply both validate the
    // estate parameter so a malformed estateID errors before any manifest I/O.
    // Matches Swift, which calls resolveHandle(_:) at dispatch time before
    // entering runReconcile. Previously this was inside the `if apply {}`
    // block, so a bad estateID in dry-run was silently ignored and the default
    // estate used — diverging from Swift's behaviour (Defect B2-3 fix 1).
    let open = registry.resolve_direct(args)?;

    let manifest = match read_manifest(vault_path) {
        Err(e) => {
            return Ok(error_result(&format!(
                "vault_reconcile: error reading manifest: {e}"
            )))
        }
        Ok(None) => {
            return Ok(error_result(&format!(
                "vault_reconcile: no export manifest at {MANIFEST_RELATIVE_PATH}. Run moot_vault_export first."
            )))
        }
        Ok(Some(m)) => m,
    };

    let current = match hash_all_notes(vault_path) {
        Err(e) => {
            return Ok(error_result(&format!(
                "vault_reconcile: hashing failed: {e}"
            )))
        }
        Ok(c) => c,
    };

    // A manifest entry is only trustworthy as a certification of vault↔estate
    // agreement on schema v2+ (stamped from the export's written-paths receipt).
    // A legacy manifest (no version key) was built by hashing every `.md` on
    // disk — after such a "manifest reset" its prior hashes are unavailable and
    // a hash match proves nothing about the estate's record (VR-01 Finding A).
    let manifest_certifies = manifest.version.unwrap_or(0) >= MANIFEST_SCHEMA_VERSION;

    // Diff: added = in current but not in manifest; modified = SHA differs;
    // deleted = in manifest but not in current.
    let mut added: Vec<String> = Vec::new();
    let mut modified: Vec<String> = Vec::new();
    for (path, entry) in &current {
        match manifest.files.get(path) {
            Some(stamped) if stamped.sha256 != entry.sha256 => modified.push(path.clone()),
            None => added.push(path.clone()),
            _ => {}
        }
    }
    let mut deleted: Vec<String> = manifest
        .files
        .keys()
        .filter(|k| !current.contains_key(*k))
        .cloned()
        .collect();
    added.sort();
    modified.sort();
    deleted.sort();

    // Candidate paths: the notes classified changed / needs-review.
    // Certified (v2) manifest: the added and modified notes — what the manifest
    // diff can establish. Legacy manifest: EVERY note currently on disk. A note
    // whose content differs from the estate's record must be reported as changed,
    // and with prior hashes unavailable the safe classification is "changed /
    // needs review", never "unchanged" — fail toward surfacing, not toward
    // silence. The import's content-idempotent check absorbs the over-selection
    // without a write, and the apply-mode re-stamp converges the manifest to v2
    // so the full surface happens once, not forever.
    let candidate_paths: std::collections::HashSet<String> = if manifest_certifies {
        added.iter().chain(modified.iter()).cloned().collect()
    } else {
        current.keys().cloned().collect()
    };

    let mut lines = vec![format!(
        "vault_reconcile: {} added, {} modified, {} deleted",
        added.len(),
        modified.len(),
        deleted.len(),
    )];
    if !manifest_certifies {
        lines.push(format!(
            "manifest: legacy (pre-certification) — prior hashes unavailable; all {} note(s) classified changed / needs review",
            current.len()
        ));
    }
    lines.push("added:".to_owned());
    for p in &added {
        lines.push(format!("  + {p}"));
    }
    lines.push("modified:".to_owned());
    for p in &modified {
        lines.push(format!("  ~ {p}"));
    }
    lines.push("deleted (reported, not actioned):".to_owned());
    for p in &deleted {
        lines.push(format!("  - {p}"));
    }

    // Both modes need the estate coordinator: apply calls
    // import_vault_reconciling, dry-run calls reconcile_selection. The bridge
    // is constructed once outside the if/else so the review gate holds: both
    // modes compute the selected set via the same missing_paths body, meaning
    // apply can never import a note the dry-run would not list (VR-01 Finding B).
    //
    // The drift report above (added/modified/deleted counts) describes what
    // changed since the last export — it is independent of the selected set
    // computed below, which may be a strict superset.
    //
    // mut: VaultBridge::new requires &mut EstateCoordinator (import routes
    // through capture_with_mode — dual-path intake fix, G7). The lock is
    // also held in dry-run so reconcile_selection can snapshot the estate.
    let mut coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "vault_reconcile: estate coordinator lock poisoned",
        )
    })?;
    let mut bridge = VaultBridge::new(
        &mut coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::default(),
    );
    let now_ms = wall_now_ms();
    // VaultKitError has Display — use it so no internal type names leak.
    let all_paths: HashSet<String> = current.keys().cloned().collect();

    // Compute the selected set and (in apply mode) the ImportReport. The
    // selected set is candidates ∪ missing. Missing notes are paths present in
    // all_paths but absent from the estate under both identities (lineage and
    // export path). This closes the blind spot that export-then-reconcile
    // had: diffing against a manifest the export just wrote yields zero
    // candidates, so only the missing set detects un-imported notes.
    let (selected, report_opt): (HashSet<String>, Option<ImportReport>) = if apply {
        let (report, sel) = bridge
            .import_vault_reconciling(
                vault_path,
                &all_paths,
                &candidate_paths,
                &open.handle,
                now_ms,
                None,
                EncodeSpeed::Foreground,
            )
            .map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("vault_reconcile: apply import failed: {e}"),
                )
            })?;
        (sel, Some(report))
    } else {
        let sel = bridge
            .reconcile_selection(&all_paths, &candidate_paths, &open.handle, now_ms)
            .map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("vault_reconcile: reconcile_selection failed: {e}"),
                )
            })?;
        (sel, None)
    };

    // Surface the missing set and full import set in both modes. The MCP client
    // sees the same listing in dry-run and apply — the review gate's visibility
    // guarantee (VR-01 Finding B). missing = selected \ candidate_paths.
    let mut missing_sorted: Vec<String> = selected.difference(&candidate_paths).cloned().collect();
    missing_sorted.sort();
    let missing_count = missing_sorted.len();
    lines.push("missing (estate lacks — apply imports these):".to_owned());
    for path in &missing_sorted {
        lines.push(format!("  * {path}"));
    }
    lines.push(format!(
        "import set: {} note(s) — {} candidate(s) + {} missing",
        selected.len(),
        candidate_paths.len(),
        missing_count
    ));

    if let Some(report) = report_opt {
        lines.push("apply: true — imported exactly the surfaced import set".to_owned());
        lines.push(format!("  drawersWritten: {}", report.drawers_written));
        lines.push(format!("  drawersUpdated: {}", report.drawers_updated));
        lines.push(format!("  itemsSkipped: {}", report.items_skipped));
        lines.push(format!("  tunnelsCreated: {}", report.tunnels_created));
        lines.push(format!("  fdcClassified: {}", report.fdc_classified));
        lines.push(format!("  fdcUnclassified: {}", report.fdc_unclassified));
        lines.push(format!("  drawersSkippedUnchanged: {}", report.drawers_skipped_unchanged));
        lines.push(format!("  drawersSkippedTombstoned: {}", report.drawers_skipped_tombstoned));
        // Re-stamp: overwrite manifest entries for imported paths with the
        // hashes captured in `current` above. After the import the estate
        // agrees with the disk content hashed at reconcile-start, so each
        // imported path's stamp becomes a true v2 certification. Without this,
        // a surfaced note (foreign, scope-excluded, or legacy-manifest) would
        // re-surface on every reconcile forever. If a file changed mid-apply,
        // the stale stamp fails toward surfacing on the next reconcile —
        // correct behaviour. Entries for paths gone from disk are retained so
        // deletions keep reporting. A legacy manifest converges to v2 here
        // after its first apply (every current note was selected). This is the
        // tool layer's manifest write; the dry-run branch writes nothing.
        let mut restamped_files = manifest.files.clone();
        for path in &selected {
            if let Some(entry) = current.get(path) {
                restamped_files.insert(path.clone(), entry.clone());
            }
        }
        let restamped = ExportManifest {
            version: Some(MANIFEST_SCHEMA_VERSION),
            exported_at: manifest.exported_at.clone(),
            note_count: restamped_files.len(),
            files: restamped_files,
        };
        write_manifest(&restamped, vault_path).map_err(|e| {
            JSONRPCError::new(
                JSONRPCErrorCode::INTERNAL_ERROR,
                format!("vault_reconcile: manifest re-stamp failed: {e}"),
            )
        })?;
        lines.push(format!(
            "manifest: re-stamped {} imported path(s) (schema v{})",
            selected.len(),
            MANIFEST_SCHEMA_VERSION
        ));
    } else {
        // Dry-run mode: list the changed/needs-review candidates with their
        // stable keys and hashes, write nothing.
        let mut sorted_candidates: Vec<&String> = candidate_paths.iter().collect();
        sorted_candidates.sort();
        lines.push("candidates (dry-run — pass apply=true to action):".to_owned());
        for path in sorted_candidates {
            // Drop the `.md` extension to form the stableSourceKey.
            let key = if path.ends_with(".md") {
                &path[..path.len() - 3]
            } else {
                path.as_str()
            };
            let hash = current.get(path).map(|e| e.sha256.as_str()).unwrap_or("");
            lines.push(format!(
                "  candidate stableSourceKey={key} vaultPath={path} sha256={hash}"
            ));
        }
        lines.push("no Proposal written — dry-run".to_owned());
    }

    Ok(text_result(&lines.join("\n")))
}

/// Reconcile a vault through the direct VaultKit path and return the typed
/// receipt used by the v2 mobility surface. This never enters a v1 dispatcher
/// or reconstructs fields from v1 text.
pub fn vault_reconcile_snapshot(
    open: &OpenEstate,
    vault_path: &Path,
    apply: bool,
) -> Result<VaultReconcileSnapshot, String> {
    let manifest = read_manifest(vault_path)
        .map_err(|error| format!("vault_reconcile: error reading manifest: {error}"))?
        .ok_or_else(|| format!(
            "vault_reconcile: no export manifest at {MANIFEST_RELATIVE_PATH}. Run moot_vault_export first."
        ))?;
    let current = hash_all_notes(vault_path)
        .map_err(|error| format!("vault_reconcile: hashing failed: {error}"))?;
    let manifest_certifies = manifest.version.unwrap_or(0) >= MANIFEST_SCHEMA_VERSION;

    let mut added = Vec::new();
    let mut modified = Vec::new();
    for (path, entry) in &current {
        match manifest.files.get(path) {
            Some(stamped) if stamped.sha256 != entry.sha256 => modified.push(path.clone()),
            None => added.push(path.clone()),
            _ => {}
        }
    }
    let mut deleted: Vec<String> = manifest.files.keys()
        .filter(|path| !current.contains_key(*path))
        .cloned()
        .collect();
    added.sort();
    modified.sort();
    deleted.sort();

    let candidate_paths: HashSet<String> = if manifest_certifies {
        added.iter().chain(modified.iter()).cloned().collect()
    } else {
        current.keys().cloned().collect()
    };
    let all_paths: HashSet<String> = current.keys().cloned().collect();
    let mut coord = open.coord.lock()
        .map_err(|_| "vault_reconcile: estate coordinator lock poisoned".to_owned())?;
    let mut bridge = VaultBridge::new(
        &mut coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::default(),
    );
    let now_ms = wall_now_ms();
    let (selected, report): (HashSet<String>, Option<ImportReport>) = if apply {
        bridge.import_vault_reconciling(
            vault_path,
            &all_paths,
            &candidate_paths,
            &open.handle,
            now_ms,
            None,
            EncodeSpeed::Foreground,
        ).map(|(report, selected)| (selected, Some(report))).map_err(|error| {
            format!("vault_reconcile: apply import failed: {error}")
        })?
    } else {
        bridge.reconcile_selection(&all_paths, &candidate_paths, &open.handle, now_ms)
            .map(|selected| (selected, None))
            .map_err(|error| format!("vault_reconcile: reconcile_selection failed: {error}"))?
    };

    let mut missing: Vec<String> = selected.difference(&candidate_paths).cloned().collect();
    missing.sort();
    let import_set_count = u64::try_from(selected.len())
        .map_err(|_| "vault_reconcile: import set count overflow".to_owned())?;
    let candidate_count = u64::try_from(candidate_paths.len())
        .map_err(|_| "vault_reconcile: candidate count overflow".to_owned())?;
    let missing_count = u64::try_from(missing.len())
        .map_err(|_| "vault_reconcile: missing count overflow".to_owned())?;

    if report.is_some() {
        let mut restamped_files = manifest.files.clone();
        for path in &selected {
            if let Some(entry) = current.get(path) {
                restamped_files.insert(path.clone(), entry.clone());
            }
        }
        let restamped = ExportManifest {
            version: Some(MANIFEST_SCHEMA_VERSION),
            exported_at: manifest.exported_at,
            note_count: restamped_files.len(),
            files: restamped_files,
        };
        write_manifest(&restamped, vault_path)
            .map_err(|error| format!("vault_reconcile: manifest re-stamp failed: {error}"))?;
    }

    let candidates = if apply {
        None
    } else {
        let mut paths: Vec<String> = candidate_paths.into_iter().collect();
        paths.sort();
        Some(paths.into_iter().map(|vault_path| {
            let stable_source_key = vault_path.strip_suffix(".md")
                .unwrap_or(vault_path.as_str())
                .to_owned();
            let sha256 = current.get(&vault_path)
                .map(|entry| entry.sha256.clone())
                .unwrap_or_default();
            VaultReconcileCandidate { stable_source_key, vault_path, sha256 }
        }).collect())
    };

    Ok(VaultReconcileSnapshot {
        added,
        modified,
        deleted,
        missing,
        import_set_count,
        candidate_count,
        missing_count,
        applied: report.is_some(),
        candidates,
    })
}

// ---------------------------------------------------------------------------
// moot_vault_job handler
// ---------------------------------------------------------------------------

/// `moot_vault_job` — return the status and result of a vault job by ID.
///
/// The Rust backend is synchronous: jobs are always in the "complete" state
/// when recorded in the ledger. This handler returns a "complete" record for
/// any known job ID, and the Swift-identical "unknown job_id" not-found shape
/// for any unknown ID — matching Swift `VaultTools.runJob` field names exactly.
///
/// Response shapes (must match Swift `VaultTools.runJob` output text):
///
/// - Known import job (completed):
///   ```text
///   job_id: <uuid>
///   kind: import
///   vault: <path>
///   status: complete
///   elapsed_s: 0.0
///   drawersWritten: N
///   drawersUpdated: N
///   itemsSkipped: N
///   tunnelsCreated: N
///   fdcClassified: N
///   fdcUnclassified: N
///   ```
/// - Known export job (completed):
///   ```text
///   job_id: <uuid>
///   kind: export
///   vault: <path>
///   status: complete
///   elapsed_s: 0.0
///   noteCount: N
///   exportedAt: <ISO8601>
///   ```
/// - Unknown ID (mirrors Swift `ToolDispatcher.errorResult("unknown job_id: \(jobID)")`):
///   `isError: true`, text = `"unknown job_id: <id>"`
fn run_job(job_id: &str, ledger: &VaultJobLedger) -> serde_json::Value {
    let Ok(job_id) = uuid::Uuid::parse_str(job_id) else {
        return error_result(&format!("unknown job_id: {job_id}"));
    };
    let Some(snapshot) = ledger.snapshot(job_id) else {
        // Swift: `return ToolDispatcher.errorResult("unknown job_id: \(jobID)")`
        // Rust mirrors this exact phrase so clients get the same not-found shape.
        return error_result(&format!("unknown job_id: {job_id}"));
    };

    text_result(&render_job_snapshot(&snapshot))
}

/// V1 presentation over the same terminal receipt used by the dormant v2
/// mobility adapter.  The Rust backend is synchronous, so elapsed_s is 0.0.
pub fn render_job_snapshot(snapshot: &VaultJobSnapshot) -> String {
    // Swift computes `Date().timeIntervalSince(job.startedAt)` for a real
    // async job; here the job was done before the caller could poll, so 0.0
    // is the truthful value (not a stub — it reflects the real elapsed time
    // of a synchronous operation measured at millisecond resolution).
    let elapsed_s = "0.0";

    match &snapshot.result {
        VaultJobResult::Imported(r) => format!(
            "job_id: {}\nkind: {}\nvault: {}\nstatus: complete\nelapsed_s: {}\ndrawersWritten: {}\ndrawersUpdated: {}\nitemsSkipped: {}\ntunnelsCreated: {}\nfdcClassified: {}\nfdcUnclassified: {}\ndrawersSkippedUnchanged: {}\ndrawersSkippedTombstoned: {}",
            snapshot.job_id,
            snapshot.kind.as_str(),
            snapshot.vault_path,
            elapsed_s,
            r.drawers_written,
            r.drawers_updated,
            r.items_skipped,
            r.tunnels_created,
            r.fdc_classified,
            r.fdc_unclassified,
            r.drawers_skipped_unchanged,
            r.drawers_skipped_tombstoned,
        ),
        VaultJobResult::Exported(r) => format!(
            "job_id: {}\nkind: {}\nvault: {}\nstatus: complete\nelapsed_s: {}\nnoteCount: {}\nexportedAt: {}",
            snapshot.job_id,
            snapshot.kind.as_str(),
            snapshot.vault_path,
            elapsed_s,
            r.note_count,
            r.exported_at,
        ),
    }
}

// ---------------------------------------------------------------------------
// Manifest I/O + hashing
// ---------------------------------------------------------------------------

/// SHA-256 exactly the paths the export wrote and assemble the export manifest.
///
/// `written_paths` is the certification receipt from `VaultBridge::export` —
/// only the vault-relative paths the export actually wrote. Hashing is
/// restricted to that set: stamping a note the export did not write (foreign,
/// scope-excluded, or user-edited and not re-exported) would certify
/// vault↔estate agreement nobody verified, and a note so mis-certified matches
/// the manifest on the next reconcile and is never surfaced again (VR-01
/// Finding A). Un-stamped notes fall into reconcile's "added" bucket —
/// changed/needs-review, fail toward surfacing. Mirrors Swift
/// `VaultTools.buildManifest(vaultURL:writtenPaths:now:)`.
///
/// `now_ms` is milliseconds-since-epoch, supplied by the caller. The
/// `exported_at` ISO8601 timestamp is derived from it. Using milliseconds
/// matches `VaultBridge::export`'s `now` contract so the two calls stay
/// consistent in the same handler invocation.
pub fn build_manifest(
    vault_path: &Path,
    written_paths: &[String],
    now_ms: i64,
) -> Result<ExportManifest, std::io::Error> {
    let mut files: BTreeMap<String, ManifestEntry> = BTreeMap::new();
    for rel in written_paths {
        // Containment guard (Perkins VR-01 finding 2): from_ir errors on
        // traversal before this runs, but that is containment by call
        // ordering, not by construction. Enforce it here too so a future
        // caller with un-vetted paths cannot turn the stamp read into an
        // arbitrary-file hash oracle. Same lexical rules as the from_ir
        // write guard: no "..", no absolute prefix, no backslash, no empty
        // components. Mirrors Swift `VaultTools.buildManifest`.
        let escapes = rel.starts_with('/')
            || rel.contains('\\')
            || rel.split('/').any(|c| c.is_empty() || c == ".." || c == ".");
        if escapes {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "manifest stamp path escapes the vault root; stamp refused",
            ));
        }
        let path = vault_path.join(rel);
        // Regular-file gate (Perkins VR-01 finding 1): `std::fs::read`
        // follows symlinks, so a note swapped for a symlink between
        // from_ir's write and this hash (TOCTOU) would stamp the hash of
        // any file this process can read. `symlink_metadata` does NOT
        // follow links, so it detects both live and broken symlinks. A
        // non-regular entry is skipped, not stamped — no certification, so
        // the path surfaces as changed / needs review on the next
        // reconcile. Fail toward surfacing. Mirrors Swift.
        match std::fs::symlink_metadata(&path) {
            Ok(meta) if meta.is_file() => {}
            _ => continue,
        }
        // The export just wrote this path through the adapter's containment
        // guards; the direct read hashes the actual disk bytes so the stamp
        // certifies exactly what landed.
        let content = std::fs::read(&path)?;
        let sha256 = sha256_hex(&content);
        files.insert(rel.clone(), ManifestEntry { sha256 });
    }
    let note_count = files.len();
    // Derive the ISO8601 timestamp from now_ms (milliseconds since epoch).
    // Round to seconds for the display-only field — matches Swift's
    // `ISO8601DateFormatter().string(from: now)` which is second-resolution.
    let secs = (now_ms / 1000) as u64;
    let exported_at = format_iso8601(secs);
    Ok(ExportManifest { version: Some(MANIFEST_SCHEMA_VERSION), exported_at, note_count, files })
}

/// Write the manifest to `.moot/export-manifest.json` inside the vault.
///
/// Applies a symlink-containment guard before writing — the same pattern the
/// Swift `ObsidianAdapter.ensureWritableFileTarget` uses for note writes. If a
/// pre-existing symlink exists at the manifest path, the write is refused
/// unconditionally: a symlink could redirect the manifest write outside the vault
/// root and is never a legitimate state for this layer-owned sidecar file.
/// `symlink_metadata` is used (not `metadata`) so the check targets the link
/// itself rather than its destination.
///
/// The `.moot/` directory is created if absent. Sorted keys keep the
/// on-disk JSON byte-stable across exports.
pub fn write_manifest(
    manifest: &ExportManifest,
    vault_path: &Path,
) -> Result<(), std::io::Error> {
    let moot_dir = vault_path.join(".moot");
    std::fs::create_dir_all(&moot_dir)?;

    // Parent-dir containment guard (Finding 13): verify that the `.moot` directory
    // itself resolves inside the vault root after create_dir_all. An attacker can
    // pre-plant a symlink at the `.moot` path pointing to a foreign directory;
    // create_dir_all silently follows it and creates the target there, so all
    // subsequent writes land outside the vault. The leaf-symlink check below does
    // not catch this because the manifest file does not yet exist at the now-foreign
    // path.
    //
    // `canonicalize` follows symlinks and returns the real absolute path. If the
    // resolved `.moot` path does not start with the resolved vault root, reject
    // the write unconditionally. This is the inline analog of Swift
    // `ObsidianAdapter.ensureContainedInVault`.
    let vault_canonical = vault_path.canonicalize()?;
    let moot_canonical  = moot_dir.canonicalize()?;
    let vault_str = vault_canonical.to_string_lossy();
    let moot_str  = moot_canonical.to_string_lossy();
    if moot_str != vault_str.as_ref()
        && !moot_str.starts_with(&format!("{}/", vault_str))
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            ".moot parent directory resolves outside the vault root after symlink expansion; write refused",
        ));
    }

    let manifest_path = vault_path.join(MANIFEST_RELATIVE_PATH);

    // Leaf symlink-containment guard: refuse a pre-existing symlink at the manifest
    // path. symlink_metadata succeeds even for broken symlinks (unlike metadata),
    // so this correctly detects the attack vector regardless of symlink target.
    if manifest_path.exists() || manifest_path.symlink_metadata().is_ok() {
        if let Ok(meta) = manifest_path.symlink_metadata() {
            if meta.file_type().is_symlink() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "manifest path targets a pre-existing symlink; write refused",
                ));
            }
        }
    }

    let json =
        serde_json::to_string_pretty(manifest).map_err(std::io::Error::other)?;
    std::fs::write(manifest_path, json.as_bytes())
}

/// Read and decode the manifest, or `None` when none has been stamped.
pub fn read_manifest(vault_path: &Path) -> Result<Option<ExportManifest>, String> {
    let manifest_path = vault_path.join(MANIFEST_RELATIVE_PATH);
    if !manifest_path.exists() {
        return Ok(None);
    }
    let data = std::fs::read(&manifest_path).map_err(|e| e.to_string())?;
    let m = serde_json::from_slice::<ExportManifest>(&data)
        .map_err(|e| e.to_string())?;
    Ok(Some(m))
}

/// Enumerate every `.md` note file under `vault_path` (skipping hidden files
/// and directories), hash each with SHA-256, and return a BTreeMap keyed by
/// forward-slash vault-relative path.
///
/// Mirrors `VaultTools.hashAllNotes(vaultURL:)` and `ObsidianAdapter::to_ir`
/// exactly:
/// - Skips hidden files/dirs so `.moot/export-manifest.json` is never stamped
///   into its own manifest.
/// - Skips OKF navigation files (`index.md`, `log.md`) that `from_ir` emits
///   for progressive-disclosure nav but that `to_ir` never imports as notes.
///   Without this skip the manifest count is inflated by one per folder.
pub fn hash_all_notes(
    vault_path: &Path,
) -> Result<BTreeMap<String, ManifestEntry>, std::io::Error> {
    let mut out: BTreeMap<String, ManifestEntry> = BTreeMap::new();
    collect_and_hash(vault_path, vault_path, &mut out)?;
    Ok(out)
}

fn collect_and_hash(
    dir: &Path,
    vault_root: &Path,
    out: &mut BTreeMap<String, ManifestEntry>,
) -> Result<(), std::io::Error> {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        // Skip hidden files and directories — matches Swift's `.skipsHiddenFiles`.
        if name_str.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            collect_and_hash(&path, vault_root, out)?;
        } else if file_type.is_file() && name_str.ends_with(".md") {
            // Skip OKF navigation files — mirrors ObsidianAdapter::to_ir which
            // skips stems "index" and "log" on read. Without this skip the
            // manifest count is inflated by one per folder (one index.md is
            // emitted per folder by from_ir), breaking noteCount assertions and
            // drift detection. Mirrors Swift VaultTools.hashAllNotes fix.
            let stem = name_str.trim_end_matches(".md");
            if stem == "index" || stem == "log" {
                continue;
            }
            // Vault-relative path with forward slashes.
            let rel = path
                .strip_prefix(vault_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            let data = std::fs::read(&path)?;
            let hash = sha256_hex(&data);
            out.insert(rel, ManifestEntry { sha256: hash });
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Dataset round-trip helpers (MX-TAB-7b §6)
// ---------------------------------------------------------------------------

/// Maximum rows exported per dataset CSV companion file.
/// 1 million rows covers practical real-world datasets in v1. Larger datasets
/// produce truncated CSVs; the handle note still exports correctly.
const DATASET_EXPORT_ROW_CAP: usize = 1_000_000;

/// CSV file size cap for dataset import from vault (mirrors `moot_file_dataset`).
/// 100 MiB = 104,857,600 bytes.
const VAULT_CSV_SIZE_CAP_BYTES: u64 = 100 * 1_048_576;

/// Parse flat YAML frontmatter from a Markdown note content string.
///
/// Expects the standard ObsidianAdapter format:
/// ```text
/// ---
/// key: value
/// anotherKey: "quoted value"
/// ---
/// body here…
/// ```
/// Handles only the flat key-value subset that `DrawerMapping` writes.
/// Quoted string values have surrounding `"` stripped. Returns an empty map
/// when no valid `---…---` block is found.
fn parse_vault_frontmatter(content: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    // Strip UTF-8 BOM if present.
    let content = content.trim_start_matches('\u{FEFF}');
    let mut lines = content.lines();
    // First non-empty line must be the opening "---".
    let first = lines.by_ref().find(|l| !l.trim().is_empty());
    if first.map(|l| l.trim()) != Some("---") {
        return out;
    }
    for line in lines {
        let trimmed = line.trim();
        if trimmed == "---" {
            break; // Closing delimiter — frontmatter is complete.
        }
        if let Some(colon_pos) = trimmed.find(':') {
            let key = trimmed[..colon_pos].trim().to_string();
            let value_raw = trimmed[colon_pos + 1..].trim();
            // Strip surrounding double-quotes (Obsidian YAML string syntax).
            let value = if value_raw.starts_with('"')
                && value_raw.ends_with('"')
                && value_raw.len() >= 2
            {
                value_raw[1..value_raw.len() - 1].to_string()
            } else {
                value_raw.to_string()
            };
            if !key.is_empty() {
                out.insert(key, value);
            }
        }
    }
    out
}

/// Extract the note body from a Markdown note — the text after the closing
/// `---` frontmatter delimiter. Returns an empty string when the frontmatter
/// block is unclosed or the file has no frontmatter.
fn extract_md_body(content: &str) -> String {
    let content = content.trim_start_matches('\u{FEFF}');
    let mut lines = content.lines().peekable();
    // Find the opening "---".
    if lines.by_ref().find(|l| l.trim() == "---").is_none() {
        // No frontmatter — entire content is the body.
        return content.to_string();
    }
    // Find the closing "---".
    let mut after_close = false;
    let mut rest_lines: Vec<&str> = Vec::new();
    for line in lines {
        if !after_close {
            if line.trim() == "---" {
                after_close = true;
            }
        } else {
            rest_lines.push(line);
        }
    }
    if after_close {
        rest_lines.join("\n")
    } else {
        String::new() // Unclosed frontmatter.
    }
}

/// Scan a vault directory for dataset handle notes (`contentKind: 7` in frontmatter).
///
/// Returns `Vec<(vault_relative_path, frontmatter, note_body)>`. Skips hidden
/// directories and files (same rule as `collect_and_hash`). Skips OKF nav files.
/// Errors from individual files are logged and skipped; only directory read
/// errors propagate.
fn scan_dataset_notes(
    vault_path: &Path,
) -> Result<Vec<(String, HashMap<String, String>, String)>, String> {
    let mut out = Vec::new();
    scan_dataset_notes_dir(vault_path, vault_path, &mut out)?;
    Ok(out)
}

fn scan_dataset_notes_dir(
    dir: &Path,
    vault_root: &Path,
    out: &mut Vec<(String, HashMap<String, String>, String)>,
) -> Result<(), String> {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("scan_dataset_notes: read_dir error: {}", e)),
    };
    for entry in entries {
        let entry = entry.map_err(|e| format!("scan_dataset_notes: entry error: {}", e))?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        // Skip hidden files and directories — matches `collect_and_hash`.
        if name_str.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|e| format!("scan_dataset_notes: file_type error: {}", e))?;
        if file_type.is_dir() {
            scan_dataset_notes_dir(&path, vault_root, out)?;
        } else if file_type.is_file() && name_str.ends_with(".md") {
            // Skip OKF navigation files — mirrors `collect_and_hash`.
            let stem = name_str.trim_end_matches(".md");
            if stem == "index" || stem == "log" {
                continue;
            }
            // Read content; skip if unreadable (broken notes are not fatal).
            let content = match std::fs::read_to_string(&path) {
                Ok(c) => c,
                Err(_) => continue,
            };
            let frontmatter = parse_vault_frontmatter(&content);
            // ContentKind::Dataset raw value = 7.
            if frontmatter.get("contentKind").map(|s| s.as_str()) == Some("7") {
                let body = extract_md_body(&content);
                let rel = path
                    .strip_prefix(vault_root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .replace('\\', "/");
                out.push((rel, frontmatter, body));
            }
        }
    }
    Ok(())
}

/// Convert a `DatasetColumnSummary` `data_type` label string back to a
/// `ColumnType` for `DatasetSchema` column declarations.
///
/// Parses the labels stored by `DatasetTools` at handle creation time
/// ("INT", "FLOAT", "TEXT", "BOOL", etc.). Case-insensitive; unknown labels
/// default to `ColumnType::Text`.
fn column_type_from_label(label: &str) -> ColumnType {
    match label.to_uppercase().as_str() {
        "INT" | "INTEGER" => ColumnType::Int,
        "FLOAT" | "REAL" | "DOUBLE" => ColumnType::Float,
        "BOOL" | "BOOLEAN" => ColumnType::Bool,
        "UUID" => ColumnType::Uuid,
        "BITMAP" => ColumnType::Bitmap,
        "TIMESTAMP" => ColumnType::Timestamp,
        _ => ColumnType::Text,
    }
}

/// Convert a frontmatter `sensitivity` label string to the raw i64 used by
/// `capture_dataset_handle`.
///
/// DrawerMapping omits the `sensitivity` key for Normal — absence maps to 0.
/// Raw values: Normal=0, Elevated=16, Restricted=32, Secret=48.
fn vault_sensitivity_to_raw(label: Option<&str>) -> i64 {
    match label {
        Some("elevated") => 16,
        Some("restricted") => 32,
        Some("secret") => 48,
        _ => 0, // Normal (also: absent key)
    }
}

/// RFC-4180 CSV line splitter. Normalises CRLF and bare CR line endings
/// and drops blank lines (same normalisation as `split_csv_lines` in
/// `dataset_tools.rs`).
fn split_vault_csv_lines(content: &str) -> Vec<String> {
    let normalised = content.replace("\r\n", "\n").replace('\r', "\n");
    normalised
        .split('\n')
        .filter(|l| !l.trim().is_empty())
        .map(|s| s.to_string())
        .collect()
}

/// RFC-4180 CSV record parser. Returns field values with surrounding quotes
/// stripped and embedded `""` unescaped to `"`. Bare (unquoted) fields are
/// trimmed. Mirrors `parse_csv_record` in `dataset_tools.rs`.
fn parse_vault_csv_record(line: &str) -> Vec<String> {
    let mut fields: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let chars: Vec<char> = line.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if in_quotes {
            if ch == '"' {
                if i + 1 < chars.len() && chars[i + 1] == '"' {
                    current.push('"');
                    i += 2;
                } else {
                    in_quotes = false;
                    i += 1;
                }
            } else {
                current.push(ch);
                i += 1;
            }
        } else if ch == '"' {
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
    fields.push(current.trim().to_string());
    fields
}

/// Convert a raw CSV cell string to a `TypedValue` given the known column type.
///
/// Empty string → `TypedValue::Null`. Mirrors `parse_typed_value` in
/// `dataset_tools.rs` (type-hint path).
fn parse_vault_csv_cell(cell: &str, col_type: ColumnType) -> TypedValue {
    if cell.is_empty() {
        return TypedValue::Null;
    }
    match col_type {
        ColumnType::Int => cell
            .parse::<i64>()
            .map(TypedValue::Int)
            .unwrap_or_else(|_| TypedValue::Text(cell.to_string())),
        ColumnType::Float => cell
            .parse::<f64>()
            .map(TypedValue::Float)
            .unwrap_or_else(|_| TypedValue::Text(cell.to_string())),
        ColumnType::Bool => match cell.to_lowercase().as_str() {
            "true" | "1" | "yes" => TypedValue::Bool(true),
            "false" | "0" | "no" => TypedValue::Bool(false),
            _ => TypedValue::Text(cell.to_string()),
        },
        _ => TypedValue::Text(cell.to_string()),
    }
}

/// Escape a CSV field value for RFC-4180 output.
///
/// Wraps the field in double-quotes if it contains commas, double-quotes, or
/// line terminators. Embedded double-quotes are doubled.
fn escape_vault_csv_field(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

/// Serialise a `TypedValue` to its CSV text form.
///
/// Null → empty string. Float uses `format!("{}", d)` (ryu shortest-roundtrip,
/// matching Swift's `String(d)`). Mirrors `typed_value_to_string` in
/// `dataset_tools.rs` but without the surrounding quotes on Text (CSV wrapping
/// is handled separately by `escape_vault_csv_field`).
fn typed_value_to_csv_text(v: &TypedValue) -> String {
    match v {
        TypedValue::Null => String::new(),
        TypedValue::Bool(b) => if *b { "true" } else { "false" }.to_string(),
        TypedValue::Int(i) => format!("{}", i),
        TypedValue::Bitmap(i) => format!("{}", i),
        TypedValue::Float(d) => format!("{}", d), // ryu shortest-roundtrip
        TypedValue::Text(s) => s.clone(),
        TypedValue::Uuid(u) => u.to_string(),
        TypedValue::Timestamp(ms) => format!("{}", ms),
        _ => format!("{:?}", v),
    }
}

/// Write CSV companion files alongside dataset handle notes in the vault.
///
/// Called as a post-step in `run_export` after `bridge.export()` and
/// `write_manifest()` complete. For each `.md` note with `contentKind: 7`
/// in its frontmatter, reads the `DatasetHandleContent` from the note body,
/// queries the `DatasetStore` for all rows (capped at `DATASET_EXPORT_ROW_CAP`),
/// and writes `<wing>/<room>/<slug>.csv` beside the handle note.
///
/// ## Sensitivity gate (MX-TAB-SEC-1 A4)
///
/// Handles with `sensitivity: restricted` or `sensitivity: secret` in their
/// frontmatter have their note exported (by `bridge.export`) but NO companion
/// CSV written. This prevents bulk CSV data from leaving the estate unprotected
/// alongside a sensitive handle note. A notice is emitted to stderr and a
/// warning entry is appended for each skipped handle.
///
/// Non-fatal: individual failures are collected as warnings and included in
/// the response; they do not fail the overall export.
///
/// Returns `(csv_count, warnings)`.
fn export_dataset_csvs(vault_path: &Path, open: &OpenEstate) -> (usize, Vec<String>) {
    let mut count = 0usize;
    let mut warnings: Vec<String> = Vec::new();

    // DatasetStore is optional — the estate may not have one.
    let storage = match open.store.storage() {
        Some(s) => s,
        None => {
            warnings.push(
                "vault_export: estate has no DatasetStore — dataset CSVs skipped".to_string(),
            );
            return (0, warnings);
        }
    };
    let dataset_store = match storage.dataset_store() {
        Ok(ds) => ds,
        Err(e) => {
            warnings.push(format!(
                "vault_export: DatasetStore unavailable ({e}) — dataset CSVs skipped"
            ));
            return (0, warnings);
        }
    };

    // Scan the vault for dataset handle notes.
    let dataset_notes = match scan_dataset_notes(vault_path) {
        Ok(v) => v,
        Err(e) => {
            warnings.push(format!(
                "vault_export: dataset note scan failed ({e}) — dataset CSVs skipped"
            ));
            return (0, warnings);
        }
    };

    for (rel_path, frontmatter, body) in &dataset_notes {
        // A4: Sensitivity gate — skip CSV for restricted/secret dataset handles
        // (MX-TAB-SEC-1 A4).
        //
        // The .md handle note is already in the vault (written by bridge.export,
        // which applies the bulk-channel tier rules). This gate prevents companion
        // CSV data from riding alongside a sensitive handle note.
        //
        // Behaviour:
        //   - normal / elevated:   note exported AND csv exported (no change)
        //   - restricted / secret: note exported, CSV is SKIPPED with a notice
        //
        // "restricted" and "secret" map to sensitivity tiers excluded from bulk data
        // export. Their CSV content must not leave the estate unprotected.
        let sensitivity_raw = vault_sensitivity_to_raw(
            frontmatter.get("sensitivity").map(|s| s.as_str()),
        );
        if sensitivity_raw >= 32 {
            // 32 = restricted; 48 = secret
            let sens_label = frontmatter
                .get("sensitivity")
                .map(|s| s.as_str())
                .unwrap_or("restricted");
            eprintln!(
                "vault_export: sensitive dataset handle at {} \
                (sensitivity: {}) — note exported, CSV skipped per MX-TAB-SEC-1 A4",
                rel_path, sens_label
            );
            warnings.push(format!(
                "vault_export: {rel_path}: sensitivity={sens_label} — \
                CSV skipped (handle note exported; dataset CSV withheld)"
            ));
            continue;
        }

        // Decode the DatasetHandleContent JSON from the note body.
        let handle_content = match DatasetHandleContent::decode(body.trim()) {
            Ok(c) => c,
            Err(e) => {
                warnings.push(format!(
                    "vault_export: {rel_path} — invalid DatasetHandleContent ({e}); skipped"
                ));
                continue;
            }
        };

        let dataset_id = handle_content.dataset_id;

        // Query rows (capped at DATASET_EXPORT_ROW_CAP).
        let rows = match dataset_store.query_rows(
            dataset_id,
            None,
            &[],
            Some(DATASET_EXPORT_ROW_CAP),
            None,
            None,
        ) {
            Ok(r) => r,
            Err(e) => {
                warnings.push(format!(
                    "vault_export: {rel_path} — query_rows failed ({e}); skipped"
                ));
                continue;
            }
        };

        // Build CSV: header row, then one data row per StorageRow.
        let col_names: Vec<&str> = handle_content.columns.iter().map(|c| c.name.as_str()).collect();
        let mut csv = String::new();

        // Header.
        let header_fields: Vec<String> =
            col_names.iter().map(|n| escape_vault_csv_field(n)).collect();
        csv.push_str(&header_fields.join(","));
        csv.push('\n');

        // Data rows.
        for row in &rows {
            let data_fields: Vec<String> = col_names
                .iter()
                .map(|col_name| {
                    let v = row.values.get(*col_name).unwrap_or(&TypedValue::Null);
                    escape_vault_csv_field(&typed_value_to_csv_text(v))
                })
                .collect();
            csv.push_str(&data_fields.join(","));
            csv.push('\n');
        }

        // Derive companion CSV path: replace trailing `.md` with `.csv`.
        let csv_rel = if rel_path.ends_with(".md") {
            format!("{}.csv", &rel_path[..rel_path.len() - 3])
        } else {
            format!("{}.csv", rel_path)
        };
        let csv_abs = vault_path.join(&csv_rel);

        if let Err(e) = std::fs::write(&csv_abs, csv.as_bytes()) {
            warnings.push(format!("vault_export: failed to write {csv_rel} ({e})"));
            continue;
        }
        count += 1;
    }

    (count, warnings)
}

/// Import dataset handle notes from the vault via the direct estate path.
///
/// For each `(rel_path, frontmatter, body)` dataset note triple:
///   1. Decode `DatasetHandleContent` from the note body JSON.
///   2. Locate the companion `.csv` file at the same path with `.csv` extension.
///   3. Parse the CSV using column types from the handle content.
///   4. Call `DatasetStore::create_dataset` + `append_rows` (idempotent on create).
///   5. Call `Estate::capture_dataset_handle` (authorised creation path).
///   6. Compute signatures non-fatally (reports "pending" on failure).
///
/// This is the same code path as `moot_file_dataset` for the CSV→handle flow.
/// `locus_estate` borrows from the caller's `coord` (MutexGuard) and must not
/// outlive it — both must be in scope for the duration of this call.
#[allow(clippy::too_many_arguments)]
fn import_dataset_notes(
    vault_path: &Path,
    dataset_notes: &[(String, HashMap<String, String>, String)],
    dataset_store: &dyn persistence_kit::dataset_store::DatasetStore,
    locus_estate: &locus_kit::estate::Estate,
    handle: &genius_locus_kit::handle::EstateHandle,
    now_ms: i64,
    warnings: &mut Vec<String>,
) -> usize {
    let _ = handle; // EstateHandle is not used after locus_estate is obtained.
    let mut imported = 0usize;

    for (rel_path, frontmatter, body) in dataset_notes {
        // --- Decode DatasetHandleContent ---
        let handle_content = match DatasetHandleContent::decode(body.trim()) {
            Ok(c) => c,
            Err(e) => {
                warnings.push(format!(
                    "vault_import: {rel_path} — invalid DatasetHandleContent ({e}); skipped"
                ));
                continue;
            }
        };

        let dataset_id = handle_content.dataset_id;

        // --- Build column schema from DatasetHandleContent ---
        // DatasetHandleContent.columns already carries the correct data_type labels
        // ("INT", "FLOAT", "TEXT", "BOOL") from original handle creation.
        let col_types: Vec<(String, ColumnType)> = handle_content
            .columns
            .iter()
            .map(|c| (c.name.clone(), column_type_from_label(&c.data_type)))
            .collect();

        // Validate column identifiers BEFORE any DDL (mirrors moot_file_dataset).
        let mut valid = true;
        for (col_name, _) in &col_types {
            if let Err(e) = validate_dataset_column_identifier(col_name) {
                warnings.push(format!(
                    "vault_import: {rel_path} — invalid column identifier '{col_name}' ({e}); skipped"
                ));
                valid = false;
                break;
            }
        }
        if !valid {
            continue;
        }

        let schema = DatasetSchema {
            columns: col_types
                .iter()
                .map(|(name, ct)| ColumnDeclaration::new(name.clone(), *ct))
                .collect(),
            primary_key_column: None,
        };

        // --- Locate and read companion CSV ---
        let csv_rel = if rel_path.ends_with(".md") {
            format!("{}.csv", &rel_path[..rel_path.len() - 3])
        } else {
            format!("{}.csv", rel_path)
        };
        let csv_abs = vault_path.join(&csv_rel);

        // Size-cap check before reading.
        let csv_size = match std::fs::metadata(&csv_abs).map(|m| m.len()) {
            Ok(sz) => sz,
            Err(_) => {
                // No companion CSV — no data to import; skip silently.
                // (The .md note was exported without a backing table, or the
                // CSV was manually deleted. The handle import without data is
                // not useful in v1.)
                warnings.push(format!(
                    "vault_import: {rel_path} — no companion CSV at {csv_rel}; skipped"
                ));
                continue;
            }
        };
        if csv_size > VAULT_CSV_SIZE_CAP_BYTES {
            warnings.push(format!(
                "vault_import: {csv_rel} exceeds {} MiB size cap; skipped",
                VAULT_CSV_SIZE_CAP_BYTES / 1_048_576
            ));
            continue;
        }

        let csv_content = match std::fs::read_to_string(&csv_abs) {
            Ok(c) => c,
            Err(e) => {
                warnings.push(format!(
                    "vault_import: failed to read {csv_rel} ({e}); skipped"
                ));
                continue;
            }
        };

        // --- Parse CSV ---
        let lines = split_vault_csv_lines(&csv_content);
        if lines.is_empty() {
            warnings.push(format!(
                "vault_import: {csv_rel} is empty; skipped"
            ));
            continue;
        }

        // Header: map column name → field index.
        let header_fields = parse_vault_csv_record(&lines[0]);
        let col_index: HashMap<String, usize> = header_fields
            .iter()
            .enumerate()
            .map(|(i, name)| (name.clone(), i))
            .collect();

        // Data rows.
        let mut typed_rows: Vec<BTreeMap<String, TypedValue>> =
            Vec::with_capacity(lines.len().saturating_sub(1));
        for line in lines.iter().skip(1) {
            let fields = parse_vault_csv_record(line);
            let mut row = BTreeMap::new();
            for (col_name, col_type) in &col_types {
                let cell = col_index
                    .get(col_name)
                    .and_then(|&i| fields.get(i))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                row.insert(col_name.clone(), parse_vault_csv_cell(cell, *col_type));
            }
            typed_rows.push(row);
        }

        // --- Create dataset table (idempotent: CREATE TABLE IF NOT EXISTS) ---
        if let Err(e) = dataset_store.create_dataset(dataset_id, &schema, &[]) {
            warnings.push(format!(
                "vault_import: {rel_path} — create_dataset failed ({e}); skipped"
            ));
            continue;
        }

        // --- Append rows (atomic intent: drop table on failure) ---
        if !typed_rows.is_empty() {
            if let Err(e) = dataset_store.append_rows(dataset_id, &typed_rows) {
                let _ = dataset_store.drop_dataset(dataset_id);
                warnings.push(format!(
                    "vault_import: {rel_path} — append_rows failed ({e}); table dropped"
                ));
                continue;
            }
        }

        // --- Capture dataset handle drawer ---
        // capture_dataset_handle is the ONLY authorised creation path for
        // ContentKind::Dataset drawers.
        let sensitivity_raw = vault_sensitivity_to_raw(
            frontmatter.get("sensitivity").map(|s| s.as_str()),
        );
        let wing_opt = frontmatter.get("wing").map(|s| s.as_str());
        let room = frontmatter
            .get("room")
            .map(|s| s.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("Datasets");
        let udc = frontmatter
            .get("udc")
            .map(|s| s.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("000");

        // column_summaries cloned from DatasetHandleContent — preserves the
        // original data_type labels for signature parity.
        let column_summaries: Vec<DatasetColumnSummary> = handle_content.columns.clone();

        let drawer = match locus_estate.capture_dataset_handle(
            dataset_id,
            column_summaries.clone(),
            typed_rows.len() as i64,
            &handle_content.source_description,
            wing_opt,
            room,
            "aria-mcp-vault-import",
            sensitivity_raw,
            udc,
            now_ms,
        ) {
            Ok(d) => d,
            Err(e) => {
                let _ = dataset_store.drop_dataset(dataset_id);
                warnings.push(format!(
                    "vault_import: {rel_path} — capture_dataset_handle failed ({e}); table dropped"
                ));
                continue;
            }
        };

        // --- Signatures (MX-TAB-5): non-fatal ---
        // Sample rows, gather column stats, patch the handle drawer.
        // Failure is non-fatal: the dataset and handle are already committed.
        let _: Result<_, String> = (|| {
            let sampled = dataset_store
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
            compute_dataset_signatures(locus_estate, &drawer.id, &column_summaries, &stats, &sampled)
                .map_err(|e| e.to_string())
        })();

        imported += 1;
    }

    imported
}

/// Lowercase hex SHA-256 digest. Mirrors Swift `VaultTools.sha256Hex(_:)`.
fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let result = hasher.finalize();
    result.iter().map(|b| format!("{b:02x}")).collect()
}

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------

/// Milliseconds since Unix epoch. The Rust `VaultBridge` takes `now` as
/// milliseconds (i64), so this is the correct unit for the bridge calls.
fn wall_now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// Format an epoch-second timestamp as an ISO8601 UTC string at second
/// resolution, e.g. `"2024-03-04T05:06:07Z"`. Used for the `exported_at`
/// manifest field (display only, not diffed). Matches Swift's
/// `ISO8601DateFormatter().string(from: now)` second-resolution output.
fn format_iso8601(epoch_secs: u64) -> String {
    // Manual ISO8601 UTC formatter. Avoids a third-party time crate; only
    // needs to produce the canonical second-resolution format that matches
    // Swift's output and is human-readable in the manifest.
    let secs = epoch_secs;
    // Days since Unix epoch → gregorian components. Algorithm: Euclidean
    // affine transform (Hatcher, "Introduction to the Calendar", 2000).
    let days = secs / 86400;
    let time = secs % 86400;
    let h = time / 3600;
    let m = (time % 3600) / 60;
    let s = time % 60;

    // Civil date from days since epoch (proleptic Gregorian, UTC).
    let (year, month, day) = days_to_ymd(days);
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Convert days-since-Unix-epoch (1970-01-01 = 0) to (year, month, day).
/// Uses Euclidean affine transform to convert to proleptic Gregorian.
/// Reference: https://www.reddit.com/r/learnprogramming/comments/... (Hatcher,
/// "Algorithms for Finding Calendar Dates" — well-known algorithm).
fn days_to_ymd(z: u64) -> (u64, u64, u64) {
    let z = z + 719468; // shift epoch to March 1, year 0
    let era = z / 146097;
    let doe = z % 146097; // day of era [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}
