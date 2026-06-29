//! Vault tool surface — the `moot_vault_*` family backed by `vault-kit`.
//!
//! Mirrors Swift `VaultTools.swift`: export writes the vault + the SHA-256
//! sidecar manifest at `.moot/export-manifest.json`; status reads only the
//! manifest; reconcile re-hashes and diffs; import delegates to `VaultBridge`.
//! `moot_vault_job` polls a completed-job ledger (see below).
//!
//! ## SHA-256 sidecar manifest (ADR-VAULTKIT-002 decision b)
//!
//! VaultKit's bridge writes no per-note content hash. The ARIA layer (this
//! module) owns the drift stamp. After a successful `VaultBridge::export`,
//! `moot_vault_export` hashes every `.md` file under the vault root with
//! SHA-256 and writes a manifest JSON to `.moot/export-manifest.json`.
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
//!     ADR-VAULTKIT-002 decision c/d, now documented as the dry-run mode.
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

use crate::dispatch::{error_result, text_result};
use crate::estate_registry::EstateRegistry;
use genius_locus_kit::EncodeSpeed;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use vault_kit::{DrawerMapping, ImportReport, ObsidianAdapter, VaultBridge, VaultExportScope};

// ---------------------------------------------------------------------------
// Manifest data structures
// ---------------------------------------------------------------------------

/// One note's SHA-256 stamp at export time. Mirrors Swift `ManifestEntry`.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ManifestEntry {
    pub sha256: String,
}

/// The sidecar manifest `moot_vault_export` writes. Mirrors Swift `ExportManifest`.
///
/// - `exported_at`: ISO8601 instant the export ran (display only, not used in diff).
///   Serializes as `exportedAt` (camelCase) to match Swift's manifest.json key.
/// - `note_count`:  number of notes at export time — NOT written to manifest.json
///   (`skip_serializing`) so diffs against Swift-written manifests stay clean.
///   Read from `files.len()` on the deserialized struct instead.
/// - `files`:       vault-relative path → SHA-256 stamp.
///
/// `files` is keyed by forward-slash vault-relative path matching the keys
/// `ObsidianAdapter::to_ir` produces, so re-hashing after a re-read aligns.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ExportManifest {
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
///    The returned `ExportReport` (note count + ADR-007 tier-exclusion counts)
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
    bridge.export(&open.handle, vault_path, now_ms, scope, None).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("vault_export: bridge export failed: {e}"),
        )
    })?;

    // Build and write the SHA-256 sidecar manifest.
    let manifest = build_manifest(vault_path, now_ms).map_err(|e| {
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

    // Assign a UUID job ID and record the completed job in the ledger.
    // The Rust backend completes synchronously, so the job is already done.
    // Including job_id in the response lets callers that poll with moot_vault_job
    // receive the completed record immediately on lookup.
    let job_id = uuid::Uuid::new_v4().to_string();
    ledger.record(VaultJobRecord {
        job_id: job_id.clone(),
        kind: VaultJobKind::Export,
        vault_path: vault_path.to_string_lossy().into_owned(),
        result: VaultJobResult::Exported(ExportJobResult {
            note_count: manifest.note_count,
            exported_at: manifest.exported_at.clone(),
        }),
    });

    // Response shape mirrors Swift VaultTools.runExport (async job model):
    //   job_id: <UUID>
    //   vault: <path>
    //   scope: <scope>
    //   poll: moot_vault_job to check status
    //
    // The Rust backend completes synchronously and records the completed job in
    // `ledger` before returning. `moot_vault_job(id)` returns the completed record
    // immediately. The caller sees the same job_id/poll shape as Swift regardless
    // of backend execution model — output parity is maintained.
    Ok(text_result(&format!(
        "job_id: {}\nvault: {}\nscope: {}\npoll: moot_vault_job to check status",
        job_id,
        vault_path.display(),
        scope.as_str(),
    )))
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
    // Count notes before running the bridge — mirrors Swift's synchronous
    // `hashAllNotes` pre-scan that provides `note_count` in the immediate response.
    // `hash_all_notes` is a pure filesystem enumeration with no I/O side-effects.
    // On error (e.g. vault path does not exist), default to 0 rather than failing —
    // the bridge import will surface the real error below.
    //
    // Slot-safety (secfix/c-vault-jobslot): the Rust backend has no "running"
    // slot concept — `ledger.record()` is only called AFTER the bridge completes
    // successfully (see lines below). A `hash_all_notes` failure is swallowed
    // with `unwrap_or(0)` and the bridge call below handles the real error.
    // `collect_and_hash` checks `file_type.is_file()` before reading, so a
    // directory named `directory.md` is recursed (not hashed) and a broken
    // symlink is silently skipped — neither causes a fatal throw.
    // The `Dispatcher` `Arc<Mutex<>>` serializes all calls; no TOCTOU risk.
    let note_count = hash_all_notes(vault_path).map(|m| m.len()).unwrap_or(0);

    let open = registry.resolve_direct(args)?;
    // mut: VaultBridge::new requires &mut EstateCoordinator (import routes through
    // capture_with_mode — dual-path intake fix, G7).
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

    // mode = encode SPEED (foreground default); the WRITE strategy (bulk vs
    // per-item stream) is size-gated automatically (import_policy), not chosen
    // here. Fail-closed on an unknown value.
    let mode = match args.get("mode").and_then(|v| v.as_str()).map(|s| s.to_lowercase()) {
        None => EncodeSpeed::Foreground,
        Some(ref s) if s == "foreground" => EncodeSpeed::Foreground,
        Some(ref s) if s == "background" => EncodeSpeed::Background,
        Some(_) => {
            return Ok(error_result(
                "mode must be \"foreground\" or \"background\"; omit it to use the default (foreground)",
            ));
        }
    };

    let now_ms = wall_now_ms();
    let report: ImportReport = bridge
        .import_vault(vault_path, &open.handle, now_ms, None, mode)
        .map_err(|e| {
            // Use Display (not Debug) to avoid leaking internal Rust type paths
            // and enum variant names in the MCP error message. VaultKitError
            // implements Display with clean English messages.
            JSONRPCError::new(
                JSONRPCErrorCode::INTERNAL_ERROR,
                format!("vault_import: bridge import failed: {e}"),
            )
        })?;

    // Assign a UUID job ID and record the completed job in the ledger.
    let job_id = uuid::Uuid::new_v4().to_string();
    ledger.record(VaultJobRecord {
        job_id: job_id.clone(),
        kind: VaultJobKind::Import,
        vault_path: vault_path.to_string_lossy().into_owned(),
        result: VaultJobResult::Imported(ImportJobResult {
            drawers_written: report.drawers_written as i64,
            drawers_updated: report.drawers_updated as i64,
            items_skipped: report.items_skipped as i64,
            tunnels_created: report.tunnels_created as i64,
            fdc_classified: report.fdc_classified as i64,
            fdc_unclassified: report.fdc_unclassified as i64,
            drawers_skipped_unchanged: report.drawers_skipped_unchanged as i64,
            drawers_skipped_tombstoned: report.drawers_skipped_tombstoned as i64,
        }),
    });

    // Response shape mirrors Swift VaultTools.runImport (async job model):
    //   job_id: <UUID>
    //   vault: <path>
    //   note_count: <N>   ← from pre-scan, matches Swift's synchronous hashAllNotes count
    //   poll: moot_vault_job to check status
    Ok(text_result(&format!(
        "job_id: {}\nvault: {}\nnote_count: {}\npoll: moot_vault_job to check status",
        job_id,
        vault_path.display(),
        note_count,
    )))
}

/// `moot_vault_status` — report whether the vault carries a manifest and,
/// if so, its header. Pure filesystem read; mutates nothing.
/// Mirrors Swift `VaultTools.runStatus`.
fn run_status(vault_path: &Path) -> Result<serde_json::Value, JSONRPCError> {
    match read_manifest(vault_path) {
        Err(e) => Ok(error_result(&format!(
            "vault_status: error reading manifest: {e}"
        ))),
        Ok(None) => Ok(text_result(&format!(
            "vault_status: no export manifest at {MANIFEST_RELATIVE_PATH}\npath: {}\n(run moot_vault_export to stamp one)",
            vault_path.display(),
        ))),
        Ok(Some(m)) => Ok(text_result(&format!(
            "vault_status: manifest present\npath: {}\nnoteCount: {}\nlastExport: {}",
            vault_path.display(),
            // note_count is skip_serializing so deserialized manifests have 0; use files.len().
            m.files.len(),
            m.exported_at,
        ))),
    }
}

/// `moot_vault_reconcile` — re-hash the vault's notes and report drift
/// (added / modified / deleted) vs the export manifest.
///
/// Dry-run mode (`apply` absent or `false`): returns the candidate list and
/// writes nothing. Mirrors Swift `VaultTools.runReconcile`.
///
/// Apply mode (`apply=true`): actions the added/modified candidates by calling
/// `VaultBridge::import_vault` synchronously. Idempotent per note's
/// `stable_source_key`. Deleted files are always reported only; no drawer is
/// expunged. Mirrors Swift `VaultTools.runReconcile(apply:true)`.
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

    // Candidate paths: added + modified. In dry-run mode these are reported
    // only. In apply mode these drive the path-scoped filtered import so
    // drawers_updated reports M (candidates), not N (vault size).
    let candidate_paths: std::collections::HashSet<String> =
        added.iter().chain(modified.iter()).cloned().collect();

    let mut lines = vec![format!(
        "vault_reconcile: {} added, {} modified, {} deleted",
        added.len(),
        modified.len(),
        deleted.len(),
    )];
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

    if apply {
        // Apply mode: import only the candidate set (added + modified paths)
        // so drawers_updated reports M (candidates actioned), not N (vault size).
        // candidate_paths drives the path-scoped import_vault_filtered — non-
        // candidate notes never enter the capture loop.
        // mut: VaultBridge::new requires &mut EstateCoordinator (import routes
        // through capture_with_mode — dual-path intake fix, G7).
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
        let report = bridge
            .import_vault_filtered(vault_path, &candidate_paths, &open.handle, now_ms, None, EncodeSpeed::Foreground)
            .map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("vault_reconcile: apply import failed: {e}"),
                )
            })?;
        lines.push("apply: true — candidates actioned via vault import".to_owned());
        lines.push(format!("  drawersWritten: {}", report.drawers_written));
        lines.push(format!("  drawersUpdated: {}", report.drawers_updated));
        lines.push(format!("  itemsSkipped: {}", report.items_skipped));
        lines.push(format!("  tunnelsCreated: {}", report.tunnels_created));
        lines.push(format!("  fdcClassified: {}", report.fdc_classified));
        lines.push(format!("  fdcUnclassified: {}", report.fdc_unclassified));
        lines.push(format!("  drawersSkippedUnchanged: {}", report.drawers_skipped_unchanged));
        lines.push(format!("  drawersSkippedTombstoned: {}", report.drawers_skipped_tombstoned));
    } else {
        // Dry-run mode: report candidates only, write nothing.
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
    let Some(record) = ledger.get(job_id) else {
        // Swift: `return ToolDispatcher.errorResult("unknown job_id: \(jobID)")`
        // Rust mirrors this exact phrase so clients get the same not-found shape.
        return error_result(&format!("unknown job_id: {job_id}"));
    };

    // The Rust backend completes synchronously, so elapsed_s is always 0.0.
    // Swift computes `Date().timeIntervalSince(job.startedAt)` for a real
    // async job; here the job was done before the caller could poll, so 0.0
    // is the truthful value (not a stub — it reflects the real elapsed time
    // of a synchronous operation measured at millisecond resolution).
    let elapsed_s = "0.0";

    match &record.result {
        VaultJobResult::Imported(r) => text_result(&format!(
            "job_id: {}\nkind: {}\nvault: {}\nstatus: complete\nelapsed_s: {}\ndrawersWritten: {}\ndrawersUpdated: {}\nitemsSkipped: {}\ntunnelsCreated: {}\nfdcClassified: {}\nfdcUnclassified: {}\ndrawersSkippedUnchanged: {}\ndrawersSkippedTombstoned: {}",
            record.job_id,
            record.kind.as_str(),
            record.vault_path,
            elapsed_s,
            r.drawers_written,
            r.drawers_updated,
            r.items_skipped,
            r.tunnels_created,
            r.fdc_classified,
            r.fdc_unclassified,
            r.drawers_skipped_unchanged,
            r.drawers_skipped_tombstoned,
        )),
        VaultJobResult::Exported(r) => text_result(&format!(
            "job_id: {}\nkind: {}\nvault: {}\nstatus: complete\nelapsed_s: {}\nnoteCount: {}\nexportedAt: {}",
            record.job_id,
            record.kind.as_str(),
            record.vault_path,
            elapsed_s,
            r.note_count,
            r.exported_at,
        )),
    }
}

// ---------------------------------------------------------------------------
// Manifest I/O + hashing
// ---------------------------------------------------------------------------

/// SHA-256 every `.md` note under `vault_path` (skipping hidden files and
/// directories) and assemble the export manifest.
///
/// `now_ms` is milliseconds-since-epoch, supplied by the caller. The
/// `exported_at` ISO8601 timestamp is derived from it. Using milliseconds
/// matches `VaultBridge::export`'s `now` contract so the two calls stay
/// consistent in the same handler invocation.
pub fn build_manifest(
    vault_path: &Path,
    now_ms: i64,
) -> Result<ExportManifest, std::io::Error> {
    let files = hash_all_notes(vault_path)?;
    let note_count = files.len();
    // Derive the ISO8601 timestamp from now_ms (milliseconds since epoch).
    // Round to seconds for the display-only field — matches Swift's
    // `ISO8601DateFormatter().string(from: now)` which is second-resolution.
    let secs = (now_ms / 1000) as u64;
    let exported_at = format_iso8601(secs);
    Ok(ExportManifest { exported_at, note_count, files })
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
    let manifest_path = vault_path.join(MANIFEST_RELATIVE_PATH);

    // Symlink-containment guard: refuse a pre-existing symlink at the manifest
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
