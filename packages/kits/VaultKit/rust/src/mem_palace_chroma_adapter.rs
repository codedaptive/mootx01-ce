//! MemPalaceChromaAdapter — the direct MemPalace → MOOTx01 importer
//! (read side of the MemPalace migration lane). Rust port of
//! `Sources/VaultKit/MemPalaceChromaAdapter.swift`; the two must map
//! byte-identically (shared fixtures under
//! `Tests/VaultKitTests/Fixtures/mempalace/` are asserted by both
//! suites).
//!
//! MemPalace persists THREE stores under one palace root (`~/.mempalace`):
//!
//!   1. `palace/chroma.sqlite3` — a standard ChromaDB SQLite file. Two
//!      collections: `mempalace_drawers` (drawer chunks, including
//!      `type=diary_entry` rows) and `mempalace_closets` (closet
//!      summaries). Per-row metadata lives in `embedding_metadata`
//!      (key / string_value / int_value / float_value / bool_value,
//!      joined to `embeddings` by rowid); the full text rides the
//!      metadata key `chroma:document`.
//!   2. `tunnels.json` — explicit cross-wing links, an atomic-replace
//!      JSON list (MemPalace `palace_graph.py`).
//!   3. `knowledge_graph.sqlite3` — KG facts: tables `entities` and
//!      `triples` (MemPalace `knowledge_graph.py`).
//!
//! All three are opened READ-ONLY (`SQLITE_OPEN_READ_ONLY`); the palace
//! is never written. The COMPLETE field → `NoteIR` mapping table lives in
//! the Swift adapter's header comment — it is the single normative copy;
//! this port implements it line for line. Summary of the invariants:
//!
//! - `stableSourceKey` = the raw store id (embedding id / tunnel id / KG
//!   row id), un-namespaced.
//! - Frontmatter keys VERBATIM from MemPalace metadata (no prefixes).
//! - Numeric metadata is stringified BY SQLITE (`CAST(... AS TEXT)` in
//!   the query) so both ports share one float-to-text implementation.
//! - `kind`: `"closet_summary"` / `"diary_entry"` / `"drawer"` /
//!   `"tunnel"` / `"kg_entity"` / `"kg_triple"`.
//! - Nothing dropped: every store field lands in a typed `NoteIR` home
//!   or rides frontmatter verbatim.
//!
//! ## Trust posture: the palace root is UNTRUSTED input
//!
//! A palace root is a directory handed to the importer from outside the
//! estate. "The user chose it" covers a palace they were given, not only
//! one they built — so its size and shape are an attacker-influenced
//! input, not a fact this code may assume. Every read below is bounded by
//! [`MemPalaceImportLimits`] and accounted against one
//! [`MemPalaceImportBudget`] for the whole import: a maximum
//! `tunnels.json` size checked BEFORE the file is opened, a maximum row
//! count, a maximum total of materialized bytes, and a SQLite progress
//! guard that abandons a query which burns virtual-machine steps without
//! returning rows.
//!
//! The palace is opened read-only and never written, so this adapter
//! cannot mutate it and does not write outside the estate. Availability
//! was the exposure these bounds close: before them the importer read an
//! oversized `tunnels.json`, every SQLite row, and every `NoteIR` into
//! memory with no ceiling of any kind.
//!
//! One residual is worth knowing rather than assuming away: the queries
//! below run against an attacker-authored schema, so a palace that
//! defines `embeddings` / `collections` / `entities` / `triples` as VIEWS
//! executes its own SQL inside this connection. Read-only blocks writes
//! and no filesystem-reach function is enabled, which leaves SQLite's own
//! parser surface plus availability — and the step budget bounds the
//! availability half. `PRAGMA trusted_schema=OFF` would close the rest;
//! it is deliberately NOT set here because it changes how SQLite treats a
//! foreign file and a real palace has never needed it. Do not upgrade
//! this comment to "no confidentiality or integrity risk" without it.
//!
//! Every limit fails with an error naming the limit AND the observed
//! value, because an import that dies on an unexplained cap is worse than
//! one that is slow. The limit VALUES are identical to the Swift port's;
//! divergent caps would mean an import that succeeds in one port and
//! fails in the other.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;

use crate::error::VaultKitError;
use crate::note_ir::{Block, FactIR, NoteIR, OccurredAt, SourceRef, WikiLink};
use crate::vault_adapter::VaultAdapter;

/// Maximum size of `tunnels.json`, checked BEFORE the file is read.
///
/// 64 MiB against a measured 3,149 bytes on the real palace — a 21,311x
/// factor that looks extreme only because MemPalace writes one record per
/// explicit cross-wing link, so the file is tiny in every real palace.
/// 64 MiB still admits roughly 130,000 tunnel records at ~500 bytes each.
/// The cap exists to reject a multi-gigabyte file before it is opened,
/// not to be tight.
pub const MAX_TUNNELS_JSON_BYTES: usize = 67_108_864;

/// Maximum SQLite rows read across the WHOLE import (both chroma
/// collections plus both knowledge-graph tables), not per query.
///
/// 20,000,000 against a measured 506,204 rows for the whole real palace —
/// a 39.5x factor. A palace would need roughly 2,000,000 embeddings to
/// reach it.
pub const MAX_IMPORT_ROWS: usize = 20_000_000;

/// Maximum bytes of SQLite column text materialized across the whole
/// import.
///
/// 1 GiB against a measured 40,700,592 bytes — a 26.4x factor. This is
/// the cap that actually bounds memory: the row count alone does not,
/// because one row may carry an arbitrarily large text or blob value.
pub const MAX_MATERIALIZED_BYTES: usize = 1_073_741_824;

/// Maximum SQLite virtual-machine steps before a query is abandoned.
///
/// 1,000,000,000 against a measured ~8,850,000 for the whole real palace
/// — a 113x factor, roughly 30-60 seconds of work at the measured
/// throughput. This catches what the row and byte caps cannot: a corrupt
/// or hostile database whose query plan degenerates (a missing index
/// turning the metadata join into a nested loop) and burns instructions
/// WITHOUT returning rows, so neither the row counter nor the byte
/// counter ever advances.
pub const MAX_SQLITE_VM_STEPS: usize = 1_000_000_000;

/// SQLite virtual-machine steps between progress-handler callbacks.
///
/// 1,000,000, which at the full step budget fires the handler about a
/// thousand times — frequent enough to abandon a pathological query
/// promptly, rare enough that the callback itself costs nothing
/// measurable.
pub const SQLITE_PROGRESS_GRAIN: usize = 1_000_000;

/// The ceilings one MemPalace import may not cross.
///
/// Every default is sized against a REAL palace (`~/.mempalace`, measured
/// 2026-08-03) rather than invented — see each constant above for the
/// observed figure and the headroom factor. Defaults that reject a real
/// palace would be a broken feature rather than a control, so the
/// headroom is deliberate. Mirrors Swift `MemPalaceImportLimits`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MemPalaceImportLimits {
    /// See [`MAX_TUNNELS_JSON_BYTES`].
    pub max_tunnels_json_bytes: usize,
    /// See [`MAX_IMPORT_ROWS`].
    pub max_import_rows: usize,
    /// See [`MAX_MATERIALIZED_BYTES`].
    pub max_materialized_bytes: usize,
    /// See [`MAX_SQLITE_VM_STEPS`].
    pub max_sqlite_vm_steps: usize,
    /// See [`SQLITE_PROGRESS_GRAIN`].
    pub sqlite_progress_grain: usize,
}

impl Default for MemPalaceImportLimits {
    fn default() -> Self {
        Self {
            max_tunnels_json_bytes: MAX_TUNNELS_JSON_BYTES,
            max_import_rows: MAX_IMPORT_ROWS,
            max_materialized_bytes: MAX_MATERIALIZED_BYTES,
            max_sqlite_vm_steps: MAX_SQLITE_VM_STEPS,
            sqlite_progress_grain: SQLITE_PROGRESS_GRAIN,
        }
    }
}

/// The running totals for one import, charged as rows and bytes arrive.
///
/// ONE budget is threaded through every read of a single palace — both
/// chroma collections, `tunnels.json`, and both knowledge-graph tables —
/// so `max_import_rows` and `max_materialized_bytes` are real totals for
/// the import rather than a per-query allowance that would silently
/// multiply by the number of stores. Mirrors Swift
/// `MemPalaceImportBudget`.
#[derive(Debug)]
pub struct MemPalaceImportBudget {
    /// The ceilings this budget enforces.
    limits: MemPalaceImportLimits,
    /// Rows charged so far, across every store.
    rows_read: usize,
    /// Column-text bytes charged so far, across every store.
    bytes_materialized: usize,
    /// Progress-handler callbacks observed so far. Shared with the
    /// handler closures installed on each connection, which rusqlite
    /// requires to be `Send + 'static` — hence the `Arc`, where the Swift
    /// port can pass its budget through SQLite's opaque context pointer.
    progress_ticks: Arc<AtomicUsize>,
}

impl Default for MemPalaceImportBudget {
    fn default() -> Self {
        Self::new(MemPalaceImportLimits::default())
    }
}

impl MemPalaceImportBudget {
    /// Start a fresh budget at `limits`.
    pub fn new(limits: MemPalaceImportLimits) -> Self {
        Self {
            limits,
            rows_read: 0,
            bytes_materialized: 0,
            progress_ticks: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// The ceilings this budget enforces.
    pub fn limits(&self) -> MemPalaceImportLimits {
        self.limits
    }

    /// Install the progress guard on `conn`, so a query that burns steps
    /// without returning rows is abandoned rather than run to completion.
    pub fn install_progress_guard(&self, conn: &Connection) {
        let ticks = Arc::clone(&self.progress_ticks);
        let grain = self.limits.sqlite_progress_grain;
        let max_steps = self.limits.max_sqlite_vm_steps;
        conn.progress_handler(
            grain as std::os::raw::c_int,
            // Returning true aborts the running statement with
            // SQLITE_INTERRUPT.
            Some(move || (ticks.fetch_add(1, Ordering::Relaxed) + 1) * grain > max_steps),
        );
    }

    /// Whether the progress guard has already tripped, so a SQLite error
    /// can be reported as the step limit by name instead of as SQLite's
    /// generic "interrupted" diagnostic.
    pub fn vm_step_limit_exceeded(&self) -> bool {
        self.progress_ticks.load(Ordering::Relaxed) * self.limits.sqlite_progress_grain
            > self.limits.max_sqlite_vm_steps
    }

    /// Charge one row and its column bytes, or fail naming the limit that
    /// was crossed and the value observed when it was crossed.
    pub fn charge_row(&mut self, byte_count: usize) -> Result<(), VaultKitError> {
        self.rows_read += 1;
        if self.rows_read > self.limits.max_import_rows {
            return Err(VaultKitError::AdapterError(format!(
                "MemPalace import limit exceeded: read {} SQLite rows, over the \
                 max_import_rows limit of {}. The palace is larger than this importer \
                 will materialize; raise MemPalaceImportLimits::max_import_rows to \
                 import it.",
                self.rows_read, self.limits.max_import_rows
            )));
        }
        self.bytes_materialized += byte_count;
        if self.bytes_materialized > self.limits.max_materialized_bytes {
            return Err(VaultKitError::AdapterError(format!(
                "MemPalace import limit exceeded: materialized {} bytes of SQLite column \
                 text, over the max_materialized_bytes limit of {}. Raise \
                 MemPalaceImportLimits::max_materialized_bytes to import this palace.",
                self.bytes_materialized, self.limits.max_materialized_bytes
            )));
        }
        Ok(())
    }

    /// Charge a whole file read against `max_tunnels_json_bytes`. Called
    /// with the size from the filesystem BEFORE the file is opened, so an
    /// oversized file is never read into memory at all.
    pub fn charge_tunnels_file(
        &mut self,
        byte_count: usize,
        path: &Path,
    ) -> Result<(), VaultKitError> {
        if byte_count > self.limits.max_tunnels_json_bytes {
            return Err(VaultKitError::AdapterError(format!(
                "MemPalace import limit exceeded: tunnels.json at {} is {} bytes, over the \
                 max_tunnels_json_bytes limit of {}. The file was not read. Raise \
                 MemPalaceImportLimits::max_tunnels_json_bytes to import this palace.",
                path.display(),
                byte_count,
                self.limits.max_tunnels_json_bytes
            )));
        }
        self.bytes_materialized += byte_count;
        if self.bytes_materialized > self.limits.max_materialized_bytes {
            return Err(VaultKitError::AdapterError(format!(
                "MemPalace import limit exceeded: materialized {} bytes after reading \
                 tunnels.json at {}, over the max_materialized_bytes limit of {}.",
                self.bytes_materialized,
                path.display(),
                self.limits.max_materialized_bytes
            )));
        }
        Ok(())
    }

    /// The error for a query the progress guard interrupted, naming the
    /// step limit rather than surfacing SQLite's generic diagnostic.
    pub fn step_limit_error(&self) -> VaultKitError {
        VaultKitError::AdapterError(format!(
            "MemPalace import limit exceeded: a SQLite query ran past the \
             max_sqlite_vm_steps limit of {} virtual-machine steps and was interrupted. \
             The palace's database is degenerate or hostile — a query plan that burns \
             steps without returning rows. Raise \
             MemPalaceImportLimits::max_sqlite_vm_steps only if the palace is known good.",
            self.limits.max_sqlite_vm_steps
        ))
    }

    /// Map a rusqlite error, reporting the step limit by name when the
    /// progress guard is what stopped the query.
    pub fn map_sql_error(&self, context: &str, e: rusqlite::Error) -> VaultKitError {
        if self.vm_step_limit_exceeded() {
            return self.step_limit_error();
        }
        VaultKitError::AdapterError(format!("{context}: {e}"))
    }
}

/// Size of a file on disk, or 0 when the metadata cannot be read.
///
/// A file whose size is unreadable is charged as 0 rather than rejected:
/// the read that follows will fail on its own terms with a filesystem
/// error, and inventing a limit breach for a stat failure would report
/// the wrong cause.
pub(crate) fn file_byte_count(path: &Path) -> usize {
    std::fs::metadata(path).map(|m| m.len() as usize).unwrap_or(0)
}

/// `chroma.sqlite3` location under the palace root. Required.
pub(crate) const CHROMA_RELATIVE_PATH: &str = "palace/chroma.sqlite3";

/// `tunnels.json` location under the palace root. Optional — a palace
/// with no explicit tunnels has no file (MemPalace `_load_tunnels`
/// treats absence as the empty list; so does this adapter).
pub(crate) const TUNNELS_RELATIVE_PATH: &str = "tunnels.json";

/// `knowledge_graph.sqlite3` location under the palace root. Optional —
/// a palace whose KG was never populated has no file.
pub(crate) const KNOWLEDGE_GRAPH_RELATIVE_PATH: &str = "knowledge_graph.sqlite3";

/// Reads one whole MemPalace palace (all three stores) into `NoteIR`.
/// Import-only; see `from_ir`. Mirrors Swift `MemPalaceChromaAdapter`.
#[derive(Debug, Clone)]
pub struct MemPalaceChromaAdapter {
    /// Name of the ChromaDB collection holding drawer chunks.
    pub drawers_collection: String,

    /// Name of the ChromaDB collection holding closet summaries.
    pub closets_collection: String,

    /// The ceilings this adapter enforces on an untrusted palace root.
    /// Configurable so a caller with a known-good oversized palace can
    /// raise them deliberately, and so the limits are testable without
    /// building a twenty-million-row fixture.
    pub limits: MemPalaceImportLimits,
}

impl Default for MemPalaceChromaAdapter {
    fn default() -> Self {
        Self {
            drawers_collection: "mempalace_drawers".to_owned(),
            closets_collection: "mempalace_closets".to_owned(),
            limits: MemPalaceImportLimits::default(),
        }
    }
}

impl MemPalaceChromaAdapter {
    /// Construct with the standard MemPalace collection names.
    pub fn new() -> Self {
        Self::default()
    }
}

impl VaultAdapter for MemPalaceChromaAdapter {
    /// Read one whole palace into canonical notes.
    ///
    /// `vault_path` is the PALACE ROOT directory (e.g. `~/.mempalace`),
    /// containing `palace/chroma.sqlite3` (required), `tunnels.json`
    /// (optional), and `knowledge_graph.sqlite3` (optional). Returns one
    /// `NoteIR` per chroma row, tunnel, KG entity, and KG triple — sorted
    /// by `stable_source_key` bytes (`str` ordering IS byte order; the
    /// Swift port sorts UTF-8 bytes explicitly to match).
    fn to_ir(&self, vault_path: &Path) -> Result<Vec<NoteIR>, VaultKitError> {
        let chroma_path = vault_path.join(CHROMA_RELATIVE_PATH);
        if !chroma_path.exists() {
            return Err(VaultKitError::AdapterError(format!(
                "MemPalace chroma store not found at {}",
                chroma_path.display()
            )));
        }

        // ONE budget for the whole palace: the row and byte ceilings are
        // totals for this import, not a fresh allowance per store.
        let mut budget = MemPalaceImportBudget::new(self.limits);

        let mut notes = self.chroma_notes(&chroma_path, &mut budget)?;
        notes.extend(tunnel_notes(
            &vault_path.join(TUNNELS_RELATIVE_PATH),
            &mut budget,
        )?);
        notes.extend(knowledge_graph_notes(
            &vault_path.join(KNOWLEDGE_GRAPH_RELATIVE_PATH),
            &mut budget,
        )?);

        // Deterministic order by stable_source_key bytes — identical to
        // the Swift port's explicit UTF-8 byte sort.
        notes.sort_by(|a, b| a.stable_source_key.cmp(&b.stable_source_key));
        Ok(notes)
    }

    /// MemPalace is an external SOURCE store: this adapter is import-only.
    /// Writing notes back into a live ChromaDB file would bypass
    /// MemPalace's own write path (embeddings, dedup, sweeper) and corrupt
    /// the palace, so the write direction is rejected loudly rather than
    /// half-done.
    fn from_ir(&self, _notes: &[NoteIR], _vault_path: &Path) -> Result<(), VaultKitError> {
        Err(VaultKitError::AdapterError(
            "MemPalaceChromaAdapter is read-only: MemPalace is an external source; writes go through MemPalace itself"
                .to_owned(),
        ))
    }
}

impl MemPalaceChromaAdapter {
    // MARK: - Store 1: chroma.sqlite3

    /// Read both collections from the ChromaDB file into notes.
    fn chroma_notes(
        &self,
        db_path: &Path,
        budget: &mut MemPalaceImportBudget,
    ) -> Result<Vec<NoteIR>, VaultKitError> {
        let db = open_read_only(db_path, budget)?;
        let mut notes = Vec::new();
        for (collection, is_closet) in [
            (self.drawers_collection.as_str(), false),
            (self.closets_collection.as_str(), true),
        ] {
            // A palace may legitimately lack a collection (e.g. closets
            // never built); absence yields zero notes from it, not an error.
            let Some(segment_id) = metadata_segment_id(&db, collection, budget)? else {
                continue;
            };
            for (embedding_id, metadata) in metadata_rows(&db, &segment_id, budget)? {
                notes.push(chroma_note(&embedding_id, metadata, is_closet));
            }
        }
        Ok(notes)
    }
}

/// Open a foreign SQLite file strictly read-only, with `budget`'s
/// progress guard installed. `NO_MUTEX` matches rusqlite's default
/// single-threaded-connection model; no create, no write — the palace is
/// never mutated, structurally.
pub(crate) fn open_read_only(
    path: &Path,
    budget: &MemPalaceImportBudget,
) -> Result<Connection, VaultKitError> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| {
        VaultKitError::AdapterError(format!(
            "cannot open {} read-only: {e}",
            path.display()
        ))
    })?;
    budget.install_progress_guard(&conn);
    Ok(conn)
}

/// Map a rusqlite error into the adapter error case with context.
fn sql_err(context: &str, e: rusqlite::Error) -> VaultKitError {
    VaultKitError::AdapterError(format!("{context}: {e}"))
}

/// Byte length of an optional decoded column value — the honest memory
/// cost of the string this import is holding. Summed per row and charged
/// to the budget. Taken from values already decoded at the call site
/// rather than re-reading the row, so accounting costs nothing.
fn text_bytes(value: Option<&String>) -> usize {
    value.map_or(0, |s| s.len())
}

/// The METADATA segment id for a collection name, or `None` when the
/// collection does not exist in this file. ChromaDB stores per-row
/// metadata under the collection's metadata segment, so this id is the
/// join key for everything we read.
pub(crate) fn metadata_segment_id(
    db: &Connection,
    collection: &str,
    budget: &mut MemPalaceImportBudget,
) -> Result<Option<String>, VaultKitError> {
    let mut stmt = db
        .prepare(
            "SELECT s.id FROM segments s \
             JOIN collections c ON s.collection = c.id \
             WHERE c.name = ?1 AND s.scope = 'METADATA' \
             LIMIT 1",
        )
        .map_err(|e| budget.map_sql_error("prepare segment lookup", e))?;
    let mut rows = stmt
        .query([collection])
        .map_err(|e| budget.map_sql_error("query segment lookup", e))?;
    match rows
        .next()
        .map_err(|e| budget.map_sql_error("read segment lookup", e))?
    {
        Some(row) => {
            let id: String = row
                .get(0)
                .map_err(|e| budget.map_sql_error("decode segment id", e))?;
            budget.charge_row(id.len())?;
            Ok(Some(id))
        }
        None => Ok(None),
    }
}

/// All metadata rows of one segment, grouped per embedding:
/// `(embedding_id, {key: text_value})` in embedding-rowid order.
///
/// The value is COALESCEd across the four typed columns with the numeric
/// ones CAST to text by SQLite itself — the cross-port determinism anchor
/// (see the module header).
pub(crate) fn metadata_rows(
    db: &Connection,
    segment_id: &str,
    budget: &mut MemPalaceImportBudget,
) -> Result<Vec<(String, HashMap<String, String>)>, VaultKitError> {
    let mut stmt = db
        .prepare(
            "SELECT e.embedding_id, m.key, \
                    COALESCE(m.string_value, \
                             CAST(m.int_value AS TEXT), \
                             CAST(m.float_value AS TEXT), \
                             CAST(m.bool_value AS TEXT)) \
             FROM embeddings e \
             JOIN embedding_metadata m ON m.id = e.id \
             WHERE e.segment_id = ?1 \
             ORDER BY e.id, m.key",
        )
        .map_err(|e| budget.map_sql_error("prepare metadata scan", e))?;
    let mut rows = stmt
        .query([segment_id])
        .map_err(|e| budget.map_sql_error("query metadata scan", e))?;

    let mut out: Vec<(String, HashMap<String, String>)> = Vec::new();
    let mut current_id: Option<String> = None;
    let mut current_meta: HashMap<String, String> = HashMap::new();
    while let Some(row) = rows
        .next()
        .map_err(|e| budget.map_sql_error("read metadata row", e))?
    {
        let id: String = row
            .get(0)
            .map_err(|e| budget.map_sql_error("decode embedding id", e))?;
        let key: String = row
            .get(1)
            .map_err(|e| budget.map_sql_error("decode metadata key", e))?;
        let value: Option<String> = row
            .get(2)
            .map_err(|e| budget.map_sql_error("decode metadata value", e))?;
        budget.charge_row(id.len() + key.len() + text_bytes(value.as_ref()))?;
        if current_id.as_deref() != Some(id.as_str()) {
            if let Some(finished) = current_id.take() {
                out.push((finished, std::mem::take(&mut current_meta)));
            }
            current_id = Some(id);
        }
        // A row whose four value columns are all NULL has no value to
        // carry; the key is skipped (ChromaDB never writes such rows).
        if let Some(value) = value {
            current_meta.insert(key, value);
        }
    }
    if let Some(finished) = current_id {
        out.push((finished, current_meta));
    }
    Ok(out)
}

/// Pure mapping of one chroma row → `NoteIR`. Mirrors Swift
/// `MemPalaceChromaAdapter.chromaNote(id:metadata:isCloset:)` — see the
/// Swift header for the complete field table.
fn chroma_note(id: &str, metadata: HashMap<String, String>, is_closet: bool) -> NoteIR {
    // Placement: wing / hall / room in palace order; only present,
    // non-empty components ride.
    let path_components: Vec<String> = ["wing", "hall", "room"]
        .iter()
        .filter_map(|key| metadata.get(*key))
        .filter(|v| !v.is_empty())
        .cloned()
        .collect();

    // kind: collection membership first, then the diary discriminator,
    // then the plain-drawer default.
    let kind = if is_closet {
        "closet_summary"
    } else if metadata.get("type").map(String::as_str) == Some("diary_entry") {
        "diary_entry"
    } else {
        "drawer"
    };

    // Origin date: `filed_at` (full timestamp, every row) wins; the diary
    // `date` key (date-only) is the fallback. The verbatim strings stay in
    // frontmatter either way.
    let origin_date = metadata
        .get("filed_at")
        .and_then(|s| canonical_iso8601_from_mem_palace(s))
        .or_else(|| {
            metadata
                .get("date")
                .and_then(|s| canonical_iso8601_from_mem_palace(s))
        })
        .map(OccurredAt::new);

    // entities: semicolon-separated entity names → one mention fact per
    // entity, anchored to this row's stable key.
    let facts: Vec<FactIR> = metadata
        .get("entities")
        .map(String::as_str)
        .unwrap_or("")
        .split(';')
        .filter(|s| !s.is_empty())
        .map(|entity| FactIR::new(entity, "mentioned_in", id))
        .collect();

    // source_file → SourceRef (no content hash recorded by MemPalace).
    let source = metadata
        .get("source_file")
        .map(|p| SourceRef::new(p.clone(), "", None, None));

    // Frontmatter: every metadata key VERBATIM, except the document text,
    // whose home is the body.
    let mut frontmatter = metadata;
    let document = frontmatter.remove("chroma:document").unwrap_or_default();

    let original_path = path_components.join("/");
    NoteIR {
        stable_source_key: id.to_owned(),
        body: vec![Block::markdown(document)],
        frontmatter,
        links: Vec::new(),
        tags: Vec::new(),
        original_path,
        origin_date,
        source,
        moot_id: None,
        facts,
        path_components,
        scope: BTreeMap::new(),
        kind: kind.to_owned(),
    }
}

// MARK: - Store 2: tunnels.json

/// One tunnel endpoint as MemPalace `palace_graph.py` writes it.
#[derive(Debug, Deserialize)]
struct TunnelEndpoint {
    wing: String,
    room: String,
}

/// One tunnel record as MemPalace `palace_graph.py` writes it.
#[derive(Debug, Deserialize)]
struct TunnelRecord {
    id: String,
    source: TunnelEndpoint,
    target: TunnelEndpoint,
    label: Option<String>,
    created_at: Option<String>,
}

/// Read `tunnels.json` into one note per tunnel. A missing file is the
/// empty list (MemPalace semantics); a present-but-malformed file errors
/// — silently dropping links would violate full fidelity.
///
/// The size is taken from the filesystem and charged to the budget BEFORE
/// the file is opened, so an oversized `tunnels.json` is rejected without
/// ever being read into memory.
fn tunnel_notes(
    json_path: &Path,
    budget: &mut MemPalaceImportBudget,
) -> Result<Vec<NoteIR>, VaultKitError> {
    if !json_path.exists() {
        return Ok(Vec::new());
    }
    budget.charge_tunnels_file(file_byte_count(json_path), json_path)?;
    let data = std::fs::read(json_path)?;
    let records: Vec<TunnelRecord> = serde_json::from_slice(&data).map_err(|e| {
        VaultKitError::AdapterError(format!(
            "tunnels.json is malformed at {}: {e}",
            json_path.display()
        ))
    })?;
    Ok(records.iter().map(tunnel_note).collect())
}

/// Pure mapping of one tunnel record → `NoteIR`. Mirrors Swift
/// `MemPalaceChromaAdapter.tunnelNote(from:)`.
fn tunnel_note(record: &TunnelRecord) -> NoteIR {
    let target_ref = format!("{}/{}", record.target.wing, record.target.room);
    let source_ref = format!("{}/{}", record.source.wing, record.source.room);
    let label = record.label.clone().unwrap_or_default();
    // I-5: body must be non-empty; an unlabeled tunnel renders its
    // endpoints. The same fallback rides the wikilink's `raw` so the
    // substrate tunnel label is never empty either.
    let text = if label.is_empty() {
        format!("{source_ref} -> {target_ref}")
    } else {
        label
    };

    let mut frontmatter = HashMap::from([
        ("source_wing".to_owned(), record.source.wing.clone()),
        ("source_room".to_owned(), record.source.room.clone()),
        ("target_wing".to_owned(), record.target.wing.clone()),
        ("target_room".to_owned(), record.target.room.clone()),
    ]);
    if let Some(created_at) = &record.created_at {
        frontmatter.insert("created_at".to_owned(), created_at.clone());
    }

    NoteIR {
        stable_source_key: record.id.clone(),
        body: vec![Block::markdown(text.clone())],
        frontmatter,
        links: vec![WikiLink::new(target_ref, None, text)],
        tags: Vec::new(),
        original_path: source_ref,
        origin_date: record
            .created_at
            .as_deref()
            .and_then(canonical_iso8601_from_mem_palace)
            .map(OccurredAt::new),
        source: None,
        moot_id: None,
        facts: Vec::new(),
        path_components: vec![record.source.wing.clone(), record.source.room.clone()],
        scope: BTreeMap::new(),
        kind: "tunnel".to_owned(),
    }
}

// MARK: - Store 3: knowledge_graph.sqlite3

/// Read the KG file into one note per entity and one per triple. A
/// missing file is an empty KG (a palace whose KG was never built).
///
/// The file's size on disk is NOT charged: only the column text this
/// adapter actually materializes is, row by row. A large SQLite file whose
/// rows are never read costs no memory.
fn knowledge_graph_notes(
    db_path: &Path,
    budget: &mut MemPalaceImportBudget,
) -> Result<Vec<NoteIR>, VaultKitError> {
    if !db_path.exists() {
        return Ok(Vec::new());
    }
    let db = open_read_only(db_path, budget)?;
    let mut notes = Vec::new();

    {
        let mut stmt = db
            .prepare("SELECT id, name, type, properties, created_at FROM entities ORDER BY id")
            .map_err(|e| budget.map_sql_error("prepare entities scan", e))?;
        let mut rows = stmt
            .query([])
            .map_err(|e| budget.map_sql_error("query entities", e))?;
        while let Some(row) = rows
            .next()
            .map_err(|e| budget.map_sql_error("read entity row", e))?
        {
            let id: String = row
                .get(0)
                .map_err(|e| budget.map_sql_error("decode entity id", e))?;
            let name: Option<String> = row
                .get(1)
                .map_err(|e| budget.map_sql_error("decode entity name", e))?;
            let type_: Option<String> = row
                .get(2)
                .map_err(|e| budget.map_sql_error("decode entity type", e))?;
            let properties: Option<String> = row
                .get(3)
                .map_err(|e| budget.map_sql_error("decode entity properties", e))?;
            let created_at: Option<String> = row
                .get(4)
                .map_err(|e| budget.map_sql_error("decode entity created_at", e))?;
            budget.charge_row(
                id.len()
                    + text_bytes(name.as_ref())
                    + text_bytes(type_.as_ref())
                    + text_bytes(properties.as_ref())
                    + text_bytes(created_at.as_ref()),
            )?;
            notes.push(kg_entity_note(
                &id,
                &name.unwrap_or_default(),
                type_.as_deref(),
                properties.as_deref(),
                created_at.as_deref(),
            ));
        }
    }

    {
        let mut stmt = db
            .prepare(
                "SELECT id, subject, predicate, object, valid_from, valid_to, \
                        CAST(confidence AS TEXT), source_closet, source_file, \
                        source_drawer_id, adapter_name, extracted_at \
                 FROM triples ORDER BY id",
            )
            .map_err(|e| budget.map_sql_error("prepare triples scan", e))?;
        let mut rows = stmt
            .query([])
            .map_err(|e| budget.map_sql_error("query triples", e))?;
        while let Some(row) = rows
            .next()
            .map_err(|e| budget.map_sql_error("read triple row", e))?
        {
            // The closure borrows `row` only; the budget is charged after
            // every column is decoded so it cannot be borrowed here too.
            let get = |i: usize| -> Result<Option<String>, VaultKitError> {
                row.get(i)
                    .map_err(|e| sql_err("decode triple column", e))
            };
            let id: String = row.get(0).map_err(|e| sql_err("decode triple id", e))?;
            let decoded = KgTripleRow {
                id,
                subject: get(1)?.unwrap_or_default(),
                predicate: get(2)?.unwrap_or_default(),
                object: get(3)?.unwrap_or_default(),
                valid_from: get(4)?,
                valid_to: get(5)?,
                confidence_text: get(6)?,
                source_closet: get(7)?,
                source_file: get(8)?,
                source_drawer_id: get(9)?,
                adapter_name: get(10)?,
                extracted_at: get(11)?,
            };
            budget.charge_row(decoded.text_bytes())?;
            notes.push(kg_triple_note(decoded));
        }
    }
    Ok(notes)
}

/// Pure mapping of one KG `entities` row → `NoteIR`. Mirrors Swift
/// `MemPalaceChromaAdapter.kgEntityNote`.
fn kg_entity_note(
    id: &str,
    name: &str,
    type_: Option<&str>,
    properties: Option<&str>,
    created_at: Option<&str>,
) -> NoteIR {
    let mut frontmatter = HashMap::from([("name".to_owned(), name.to_owned())]);
    if let Some(type_) = type_ {
        frontmatter.insert("type".to_owned(), type_.to_owned());
    }
    if let Some(properties) = properties {
        frontmatter.insert("properties".to_owned(), properties.to_owned());
    }
    if let Some(created_at) = created_at {
        frontmatter.insert("created_at".to_owned(), created_at.to_owned());
    }

    NoteIR {
        stable_source_key: id.to_owned(),
        // I-5: `name` is NOT NULL in the schema but "" is storable; the
        // id (a primary key, always non-empty) is the fallback.
        body: vec![Block::markdown(if name.is_empty() { id } else { name })],
        frontmatter,
        links: Vec::new(),
        tags: Vec::new(),
        original_path: "knowledge_graph/entities".to_owned(),
        origin_date: created_at
            .and_then(canonical_iso8601_from_mem_palace)
            .map(OccurredAt::new),
        source: None,
        moot_id: None,
        facts: Vec::new(),
        path_components: vec!["knowledge_graph".to_owned(), "entities".to_owned()],
        scope: BTreeMap::new(),
        kind: "kg_entity".to_owned(),
    }
}

/// One decoded KG `triples` row (named fields so the mapping call site
/// stays readable — the table has twelve columns).
struct KgTripleRow {
    id: String,
    subject: String,
    predicate: String,
    object: String,
    valid_from: Option<String>,
    valid_to: Option<String>,
    /// SQLite's text rendering of the REAL `confidence` column (CAST in
    /// SQL — the shared float-to-text implementation); parsed back to f64
    /// for `FactIR.confidence`, whose wire type is numeric.
    confidence_text: Option<String>,
    source_closet: Option<String>,
    source_file: Option<String>,
    source_drawer_id: Option<String>,
    adapter_name: Option<String>,
    extracted_at: Option<String>,
}

impl KgTripleRow {
    /// Total decoded text this row holds — its memory cost, charged to the
    /// import budget.
    fn text_bytes(&self) -> usize {
        self.id.len()
            + self.subject.len()
            + self.predicate.len()
            + self.object.len()
            + text_bytes(self.valid_from.as_ref())
            + text_bytes(self.valid_to.as_ref())
            + text_bytes(self.confidence_text.as_ref())
            + text_bytes(self.source_closet.as_ref())
            + text_bytes(self.source_file.as_ref())
            + text_bytes(self.source_drawer_id.as_ref())
            + text_bytes(self.adapter_name.as_ref())
            + text_bytes(self.extracted_at.as_ref())
    }
}

/// Pure mapping of one KG `triples` row → `NoteIR`. Mirrors Swift
/// `MemPalaceChromaAdapter.kgTripleNote`.
fn kg_triple_note(row: KgTripleRow) -> NoteIR {
    let mut frontmatter = HashMap::new();
    if let Some(v) = &row.source_closet {
        frontmatter.insert("source_closet".to_owned(), v.clone());
    }
    if let Some(v) = &row.source_file {
        frontmatter.insert("source_file".to_owned(), v.clone());
    }
    if let Some(v) = &row.source_drawer_id {
        frontmatter.insert("source_drawer_id".to_owned(), v.clone());
    }
    if let Some(v) = &row.adapter_name {
        frontmatter.insert("adapter_name".to_owned(), v.clone());
    }
    if let Some(v) = &row.extracted_at {
        frontmatter.insert("extracted_at".to_owned(), v.clone());
    }

    // valid_from/valid_to ride VERBATIM (MemPalace stores date-only
    // strings like "2026-04-27"); re-formatting a partial date would
    // invent precision the source never asserted.
    let fact = FactIR {
        subject: row.subject.clone(),
        predicate: row.predicate.clone(),
        object: row.object.clone(),
        valid_from: row.valid_from,
        valid_to: row.valid_to,
        confidence: row.confidence_text.as_deref().and_then(|s| s.parse().ok()),
    };

    NoteIR {
        stable_source_key: row.id,
        // The triple rendered as prose — the drawer content a recall can
        // match on. The structured truth is `facts[0]`.
        body: vec![Block::markdown(format!(
            "{} {} {}",
            row.subject, row.predicate, row.object
        ))],
        frontmatter,
        links: Vec::new(),
        tags: Vec::new(),
        original_path: "knowledge_graph/triples".to_owned(),
        origin_date: row
            .extracted_at
            .as_deref()
            .and_then(canonical_iso8601_from_mem_palace)
            .map(OccurredAt::new),
        source: row
            .source_file
            .map(|p| SourceRef::new(p, "", None, None)),
        moot_id: None,
        facts: vec![fact],
        path_components: vec!["knowledge_graph".to_owned(), "triples".to_owned()],
        scope: BTreeMap::new(),
        kind: "kg_triple".to_owned(),
    }
}

// MARK: - Timestamp normalization

/// Normalize a MemPalace timestamp to LocusKit's canonical ISO8601 form
/// (`YYYY-MM-DDTHH:MM:SS.fffZ`), or `None` when the string is not a
/// recognizable UTC instant (the verbatim value stays in frontmatter
/// regardless, so `None` loses nothing).
///
/// MemPalace writes four shapes, all UTC:
///   - `"2026-05-08T04:27:12.542283"` — naive microseconds (`filed_at`)
///   - `"2026-05-29T08:38:47.205501+00:00"` — explicit UTC offset
///     (tunnel `created_at`)
///   - `"2026-04-28 02:48:07"` — SQLite `CURRENT_TIMESTAMP` (KG rows)
///   - `"2026-05-08"` — date-only (diary `date`)
///
/// This is a PURE STRING transform (truncate/pad the fraction to
/// milliseconds, naive == UTC, `T00:00:00.000Z` for date-only) — no date
/// library — so the Swift and Rust ports are trivially byte-identical. A
/// non-UTC offset returns `None` rather than doing timezone arithmetic
/// two runtimes might disagree on. Mirrors Swift
/// `MemPalaceChromaAdapter.canonicalISO8601(fromMemPalace:)`.
pub fn canonical_iso8601_from_mem_palace(raw: &str) -> Option<String> {
    let mut chars: Vec<u8> = raw.as_bytes().to_vec();

    fn is_digit(c: u8) -> bool {
        c.is_ascii_digit()
    }

    // Date-only: "YYYY-MM-DD".
    if chars.len() == 10 {
        if chars[4] != b'-' || chars[7] != b'-' {
            return None;
        }
        if ![0usize, 1, 2, 3, 5, 6, 8, 9].iter().all(|&i| is_digit(chars[i])) {
            return None;
        }
        return Some(format!("{}T00:00:00.000Z", raw));
    }

    if chars.len() < 19 {
        return None;
    }

    // SQLite CURRENT_TIMESTAMP separator: " " → "T".
    if chars[10] == b' ' {
        chars[10] = b'T';
    }

    // Strip a UTC suffix; reject any other offset (no tz arithmetic).
    if chars.last() == Some(&b'Z') {
        chars.pop();
    } else if chars.len() >= 25 && &chars[chars.len() - 6..] == b"+00:00" {
        chars.truncate(chars.len() - 6);
    } else if chars.len() > 19 && chars[19..].iter().any(|&c| c == b'+' || c == b'-') {
        return None;
    }

    // Validate the 19-char date-time prefix.
    if chars.len() < 19
        || chars[4] != b'-'
        || chars[7] != b'-'
        || chars[10] != b'T'
        || chars[13] != b':'
        || chars[16] != b':'
        || ![0usize, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
            .iter()
            .all(|&i| is_digit(chars[i]))
    {
        return None;
    }

    // Fraction: absent → ".000"; present → digits truncated/padded to
    // milliseconds (canonical `.withFractionalSeconds` is 3 digits).
    let mut fraction = "000".to_owned();
    if chars.len() > 19 {
        if chars[19] != b'.' {
            return None;
        }
        let digits = &chars[20..];
        if digits.is_empty() || !digits.iter().all(|&c| is_digit(c)) {
            return None;
        }
        let mut padded: Vec<u8> = digits.to_vec();
        padded.extend_from_slice(b"000");
        fraction = String::from_utf8_lossy(&padded[..3]).into_owned();
    }
    // The prefix is validated ASCII; from_utf8 cannot fail here.
    let prefix = std::str::from_utf8(&chars[..19]).ok()?;
    Some(format!("{prefix}.{fraction}Z"))
}
