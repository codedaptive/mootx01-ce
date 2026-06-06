//! Vault tool surface — the `moot_vault_*` family backed by `vault-kit`.
//!
//! Mirrors Swift `VaultTools.swift`: export writes the vault + the SHA-256
//! sidecar manifest at `.moot/export-manifest.json`; status reads only the
//! manifest; reconcile re-hashes and diffs; import delegates to `VaultBridge`.
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
//! ## Return-only candidate seam (ADR-VAULTKIT-002 decision c/d)
//!
//! `moot_vault_reconcile` returns the candidate list in its tool result and
//! writes no Proposal noun. Enqueue is deferred; no QueueKit instance is
//! mounted in the dispatch context.

use crate::dispatch::{error_result, text_result};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use vault_kit::{DrawerMapping, ImportReport, ObsidianAdapter, VaultBridge};

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
/// - `note_count`:  number of notes at export time (same as `files.len()`).
/// - `files`:       vault-relative path → SHA-256 stamp.
///
/// `files` is keyed by forward-slash vault-relative path matching the keys
/// `ObsidianAdapter::to_ir` produces, so re-hashing after a re-read aligns.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ExportManifest {
    pub exported_at: String,
    pub note_count: usize,
    /// BTreeMap so JSON serialization is key-sorted and byte-stable.
    pub files: BTreeMap<String, ManifestEntry>,
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

/// Dispatch one of the four `moot_vault_*` tools. Called from
/// `dispatch::dispatch_tool` when `name.starts_with("moot_vault_")`.
///
/// Returns `Ok(serde_json::Value)` in all non-transport-fault cases — even
/// substrate refusals surface as `isError: true` results, matching the Swift
/// discipline. Throws `JSONRPCError` only for missing required arguments.
pub fn dispatch_vault(
    name: &str,
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    // `vaultPath` is required for all four vault tools.
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
        "moot_vault_export" => run_export(args, registry, &vault_path),
        "moot_vault_import" => run_import(args, registry, &vault_path),
        "moot_vault_status" => run_status(&vault_path),
        "moot_vault_reconcile" => run_reconcile(&vault_path),
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
/// 3. Call `bridge.export(handle, vault_path, now)` to write the `.md` files.
/// 4. Hash every `.md` under the vault root (excluding hidden dirs) with SHA-256.
/// 5. Write the sidecar manifest at `.moot/export-manifest.json`.
///
/// `now` is sampled at the handler boundary — this is a real wall-clock event
/// (the export instant), matching the same precedent in Swift's handler.
fn run_export(
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    vault_path: &Path,
) -> Result<serde_json::Value, JSONRPCError> {
    let open = registry.resolve(args, "estateID")?;
    let coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "vault_export: estate coordinator lock poisoned",
        )
    })?;

    let bridge = VaultBridge::new(
        &coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::default(),
    );

    let now_ms = wall_now_ms();
    bridge.export(&open.handle, vault_path, now_ms).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            format!("vault_export: bridge export failed: {e:?}"),
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

    Ok(text_result(&format!(
        "vault_export: {} note(s) → {}\nmanifest: {} (sha256 ×{})\nexportedAt: {}",
        manifest.note_count,
        vault_path.display(),
        MANIFEST_RELATIVE_PATH,
        manifest.files.len(),
        manifest.exported_at,
    )))
}

/// `moot_vault_import` — import a Markdown vault into the estate via the
/// capture seam. Idempotent per note's `stable_source_key`.
/// Mirrors Swift `VaultTools.runImport`.
fn run_import(
    args: &BTreeMap<String, crate::jsonrpc::JsonValue>,
    registry: &EstateRegistry,
    vault_path: &Path,
) -> Result<serde_json::Value, JSONRPCError> {
    let open = registry.resolve(args, "estateID")?;
    let coord = open.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "vault_import: estate coordinator lock poisoned",
        )
    })?;

    let bridge = VaultBridge::new(
        &coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::default(),
    );

    let now_ms = wall_now_ms();
    let report: ImportReport = bridge
        .import_vault(vault_path, &open.handle, now_ms)
        .map_err(|e| {
            JSONRPCError::new(
                JSONRPCErrorCode::INTERNAL_ERROR,
                format!("vault_import: bridge import failed: {e:?}"),
            )
        })?;

    Ok(text_result(&format!(
        "vault_import: {} written, {} updated, {} skipped\ntunnels: {}\nfdc: {} classified, {} unclassified",
        report.drawers_written,
        report.drawers_updated,
        report.items_skipped,
        report.tunnels_created,
        report.fdc_classified,
        report.fdc_unclassified,
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
            m.note_count,
            m.exported_at,
        ))),
    }
}

/// `moot_vault_reconcile` — re-hash the vault's notes and report drift
/// (added / modified / deleted) vs the export manifest. Returns candidates
/// for the downstream loop; writes no Proposal and expunges no drawer.
/// Mirrors Swift `VaultTools.runReconcile`.
///
/// ADR-VAULTKIT-002 decision c/d: candidate seam is return-only.
fn run_reconcile(vault_path: &Path) -> Result<serde_json::Value, JSONRPCError> {
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

    // Candidate-enqueue seam (return-only, ADR-VAULTKIT-002 decision c/d).
    // Each added/modified file becomes a candidate carrying enough for the
    // downstream loop: the stableSourceKey (vault-relative path without the
    // `.md` extension — same key DrawerMapping derives on export), the vault
    // path, and the new content hash.
    let mut candidate_paths: Vec<String> = added.iter().chain(modified.iter()).cloned().collect();
    candidate_paths.sort();

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
    lines.push("candidates (returned, not enqueued — no Proposal written):".to_owned());
    for path in &candidate_paths {
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

    Ok(text_result(&lines.join("\n")))
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
/// The `.moot/` directory is created if absent. Sorted keys keep the
/// on-disk JSON byte-stable across exports.
pub fn write_manifest(
    manifest: &ExportManifest,
    vault_path: &Path,
) -> Result<(), std::io::Error> {
    let moot_dir = vault_path.join(".moot");
    std::fs::create_dir_all(&moot_dir)?;
    let manifest_path = vault_path.join(MANIFEST_RELATIVE_PATH);
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

/// Enumerate every `.md` file under `vault_path` (skipping hidden files and
/// directories), hash each with SHA-256, and return a BTreeMap keyed by
/// forward-slash vault-relative path.
///
/// Mirrors `VaultTools.hashAllNotes(vaultURL:)` and the `.skipsHiddenFiles`
/// constraint of `ObsidianAdapter::to_ir`. Hidden files start with `.`, so the
/// `.moot/export-manifest.json` sidecar is never included in its own stamp.
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
