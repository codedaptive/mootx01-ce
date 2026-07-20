//! ExchangeAdapter — the first programmatic-tool adapter. Rust twin of Swift `ExchangeAdapter.swift`
//! (VK-ADAPT-01 read side, VK-EXPORT-01 write side).
//!
//! Both directions of the MOOT exchange format v1 (our canonical
//! interchange JSON): `to_ir`/`decode` read it into the canonical
//! `NoteIR`, and `from_ir`/`encode` write `NoteIR` back out as an
//! exchange document. This adapter is the single owner of the export codec:
//! mass import is
//! exclusively adapter → `VaultBridge::import_vault`, and mass export is
//! `VaultBridge::export` → adapter, which applies the privacy-tier
//! rules and writes the audit receipt BEFORE the adapter sees the notes.
//!
//! Adapters are pure transforms (`tool format ⇄ NoteIR`): no process
//! spawning, no network I/O. `to_ir`/`from_ir` touch the filesystem only
//! to read/write the export file the caller points at; `decode` and
//! `encode` are the pure byte-level transforms the ARIA_MCP server uses
//! when the export rides the wire instead of disk.
//!
//! Export shape (minimal documented form, extended-field keys optional):
//!
//! ```json
//! {
//!   "name": String,
//!   "entries": [
//!     {
//!       "id": String,                 // → stable_source_key
//!       "content": String,            // → body (one markdown block)
//!       "tags": [String]?,            // → tags ([] when absent)
//!       "facts": [FactIR]?,           // → facts ([] when absent)
//!       "pathComponents": [String]?,  // → path_components ([] when absent)
//!       "scope": {String: String}?,   // → scope ({} when absent)
//!       "kind": String?               // → kind ("note" when absent)
//!     }
//!   ]
//! }
//! ```

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;

use crate::error::VaultKitError;
use crate::note_ir::{Block, FactIR, NoteIR};
use crate::vault_adapter::VaultAdapter;

/// A decoded external memory-tool export: corpus name + entries as
/// canonical notes. Mirrors Swift `ExchangeExport`.
///
/// The name is corpus-level metadata (it identifies the source palace,
/// not any one note), so it rides beside the notes; `corpus_projection`
/// consumes both halves to rebuild an `ExternalCorpus`.
#[derive(Debug, Clone, PartialEq)]
pub struct ExchangeExport {
    /// Human-readable corpus name, verbatim from the export's `name`.
    pub name: String,
    /// One `NoteIR` per export entry, sorted by `stable_source_key`
    /// (the `VaultAdapter` deterministic-order contract).
    pub notes: Vec<NoteIR>,
}

/// The export's top-level JSON object. Strict on `name` + `entries`.
#[derive(Deserialize)]
struct ExportPayload {
    name: String,
    entries: Vec<ExportEntry>,
}

/// One export entry. `id` and `content` are required; every other key is
/// optional and lands its `NoteIR` default when absent. `facts` decodes
/// directly as `Vec<FactIR>` — the IR fact shape IS the boundary
/// contract, so no separate wire struct is needed.
#[derive(Deserialize)]
struct ExportEntry {
    id: String,
    content: String,
    #[serde(default)]
    tags: Option<Vec<String>>,
    #[serde(default)]
    facts: Option<Vec<FactIR>>,
    #[serde(rename = "pathComponents", default)]
    path_components: Option<Vec<String>>,
    #[serde(default)]
    scope: Option<BTreeMap<String, String>>,
    #[serde(default)]
    kind: Option<String>,
}

/// Decodes the external memory-tool JSON export into `[NoteIR]`.
/// Mirrors Swift `ExchangeAdapter`.
#[derive(Debug, Default, Clone, Copy)]
pub struct ExchangeAdapter;

impl ExchangeAdapter {
    pub fn new() -> Self {
        Self
    }

    /// The pure transform: export bytes → decoded corpus.
    ///
    /// Field mapping per VK-ADAPT-01: `id` → `stable_source_key` (the
    /// idempotency key the bridge derives the lineage from), `content` →
    /// a single `"markdown"` body block, `tags` → `tags`, and the
    /// VK-IR-01 extended fields populated when present. `original_path`
    /// is the joined `path_components` back-compat view, matching the
    /// `NoteIR` doc contract.
    ///
    /// Errors with `VaultKitError::Serialization` on malformed JSON or a
    /// missing required field (`name`, `id`, `content`).
    pub fn decode(&self, data: &[u8]) -> Result<ExchangeExport, VaultKitError> {
        let payload: ExportPayload = serde_json::from_slice(data)
            .map_err(|e| VaultKitError::Serialization(e.to_string()))?;
        let mut notes: Vec<NoteIR> = payload
            .entries
            .into_iter()
            .map(|entry| -> Result<NoteIR, VaultKitError> {
                // Validate path components before projecting them into substrate
                // room paths or vault directory trees — traversal sequences (..)
                // and embedded separators must be rejected at decode time so no
                // downstream adapter can be tricked into escaping the vault root.
                let path_components = validated_path_components(
                    entry.path_components.unwrap_or_default(), &entry.id)?;
                let mut note = NoteIR::new(
                    entry.id,
                    vec![Block::markdown(entry.content)],
                    std::collections::HashMap::new(),
                    Vec::new(),
                    entry.tags.unwrap_or_default(),
                    path_components.join("/"),
                    None,
                    None,
                );
                // Full-fidelity fields (VK_IR_01): the constructor lands
                // the documented defaults; producers set them directly.
                note.facts = entry.facts.unwrap_or_default();
                note.path_components = path_components;
                note.scope = entry.scope.unwrap_or_default();
                if let Some(kind) = entry.kind {
                    note.kind = kind;
                }
                Ok(note)
            })
            .collect::<Result<Vec<_>, _>>()?;
        // Deterministic order, sorted by stable_source_key — the
        // VaultAdapter contract, so repeated decodes are stable.
        notes.sort_by(|a, b| a.stable_source_key.cmp(&b.stable_source_key));
        Ok(ExchangeExport { name: payload.name, notes })
    }

    /// The pure transform: decoded corpus → canonical export bytes. The
    /// inverse of `decode`: `decode(encode(x)) == x` for every
    /// `ExchangeExport` whose notes carry only format-representable
    /// fields, and `encode(decode(bytes))` is the canonical form of any
    /// valid export — idempotent, so re-encoding is byte-stable. Mirrors
    /// Swift `ExchangeAdapter.encode(_:)`.
    ///
    /// Canonical form (cross-language byte-equality contract, same
    /// conventions as `CorpusDocument::canonical_json`): entries sorted
    /// ascending by `id` regardless of input order; object keys sorted
    /// ascending via an explicit `sort_keys` pass (independent of whether
    /// serde_json's map is BTree- or IndexMap-backed); compact output; forward
    /// slashes unescaped; extended entry keys omitted at their documented
    /// defaults (`tags`/`facts`/`pathComponents` empty, `scope` empty,
    /// `kind == "note"`); `FactIR` optional keys omitted when `None`.
    /// The shared fixture
    /// `Tests/VaultKitTests/Fixtures/exchange_export_canonical.json` is
    /// the canonical encode of the golden fixture, asserted byte-for-byte
    /// by BOTH test suites.
    ///
    /// Fields the export format CANNOT carry — enumerated per the
    /// VK-EXPORT-01 never-silently-dropped rule. The format's entry shape
    /// is `{ id, content, tags?, facts?, pathComponents?, scope?, kind? }`,
    /// so these `NoteIR` fields do not survive `encode`:
    ///
    /// - `frontmatter` — no frontmatter map in the export shape
    /// - `links` — the tool has no wikilink concept; link relations
    ///   travel as `facts` when the producer models them
    /// - `origin_date` — no per-entry timestamp key
    /// - `source` — no attachment/source-ref key
    /// - `moot_id` — no lineage key; a re-import resolves identity from
    ///   `id` → `stable_source_key` (FNV fallback), not `moot_id`
    /// - `body` block structure — `content` is the flattened body
    ///   (blocks joined by newline); multiple blocks collapse to one
    ///   `"markdown"` block on re-read, and non-`"markdown"` block kinds
    ///   are not preserved
    /// - `original_path` is NOT lost but is derived: it re-materializes
    ///   as `path_components.join("/")` on decode, so a note whose
    ///   `original_path` disagrees with its `path_components` reads back
    ///   with the components-derived view
    pub fn encode(&self, export: &ExchangeExport) -> Result<String, VaultKitError> {
        use serde_json::{Map, Value};
        use crate::corpus_document::sort_keys;

        let mut sorted: Vec<&NoteIR> = export.notes.iter().collect();
        sorted.sort_by(|a, b| a.stable_source_key.cmp(&b.stable_source_key));

        let mut entries: Vec<Value> = Vec::with_capacity(sorted.len());
        for note in sorted {
            // Build the per-entry object. Insertion order does not matter
            // because sort_keys (applied below) sorts all object keys
            // recursively before serialisation — this is required because
            // Cargo feature unification may activate serde_json's
            // `preserve_order` feature (GeniusLocusKit requests it), which
            // makes Map IndexMap-backed instead of BTreeMap-backed, so a
            // plain Map::new() no longer guarantees sorted key output.
            let mut obj = Map::new();
            obj.insert("id".to_string(), Value::String(note.stable_source_key.clone()));
            obj.insert("content".to_string(), Value::String(note.flattened_body()));
            if !note.tags.is_empty() {
                obj.insert(
                    "tags".to_string(),
                    serde_json::to_value(&note.tags)
                        .map_err(|e| VaultKitError::Serialization(e.to_string()))?,
                );
            }
            if !note.facts.is_empty() {
                obj.insert(
                    "facts".to_string(),
                    serde_json::to_value(&note.facts)
                        .map_err(|e| VaultKitError::Serialization(e.to_string()))?,
                );
            }
            if !note.path_components.is_empty() {
                obj.insert(
                    "pathComponents".to_string(),
                    serde_json::to_value(&note.path_components)
                        .map_err(|e| VaultKitError::Serialization(e.to_string()))?,
                );
            }
            if !note.scope.is_empty() {
                obj.insert(
                    "scope".to_string(),
                    serde_json::to_value(&note.scope)
                        .map_err(|e| VaultKitError::Serialization(e.to_string()))?,
                );
            }
            if note.kind != "note" {
                obj.insert("kind".to_string(), Value::String(note.kind.clone()));
            }
            entries.push(Value::Object(obj));
        }

        let mut top = Map::new();
        top.insert("name".to_string(), Value::String(export.name.clone()));
        top.insert("entries".to_string(), Value::Array(entries));
        // sort_keys reconstructs every object from a sorted Vec, making
        // key order ascending-lexicographic regardless of whether serde_json's
        // Map is BTree- or IndexMap-backed — matching Swift's `.sortedKeys`.
        serde_json::to_string(&sort_keys(Value::Object(top)))
            .map_err(|e| VaultKitError::Serialization(e.to_string()))
    }
}

impl VaultAdapter for ExchangeAdapter {
    /// Read an export file into canonical notes.
    ///
    /// For this adapter the "vault" is a single JSON export file, so
    /// `vault_path` is the file's path, not a directory. The corpus
    /// `name` is dropped by this protocol-shaped entry point (the trait
    /// returns notes only); callers that need the name use `decode` and
    /// read `ExchangeExport::name`.
    fn to_ir(&self, vault_path: &Path) -> Result<Vec<NoteIR>, VaultKitError> {
        let data = std::fs::read(vault_path)?;
        Ok(self.decode(&data)?.notes)
    }

    /// Write canonical notes out as the external tool's export document —
    /// the programmatic exit promise (data-movement privacy tiers, gold item 7).
    /// Mirrors Swift `ExchangeAdapter.fromIR(_:to:)`.
    ///
    /// As with `to_ir`, the "vault" is a single JSON export file, so
    /// `vault_path` is the destination file's path. Intermediate
    /// directories are created as needed; the adapter writes only that
    /// one file. The trait carries no corpus name, so the document's
    /// `name` is derived from the destination filename without its
    /// extension (e.g. `…/my-estate.json` → `"my-estate"`); callers that
    /// need an explicit name use `encode` with a `ExchangeExport`.
    ///
    /// Output is deterministic (see `encode`), and this is a pure
    /// transform of exactly the notes handed in: tier filtering and audit
    /// receipts happen upstream in `VaultBridge::export` (VK-TIER-01) —
    /// the adapter never re-implements tier logic.
    fn from_ir(&self, notes: &[NoteIR], vault_path: &Path) -> Result<(), VaultKitError> {
        let name = vault_path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let export = ExchangeExport { name, notes: notes.to_vec() };
        let json = self.encode(&export)?;
        if let Some(parent) = vault_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // CAND-014: symlink containment guard. Reject the write if `vault_path`
        // is a pre-existing symbolic link. A symlink at the output path could be
        // used to redirect the export write to an attacker-controlled location
        // outside the vault root — the atomic rename would silently redirect the
        // document. `symlink_metadata` is used instead of `metadata` because the
        // latter follows symlinks and would report the target's metadata, not the
        // link itself. Mirrors Swift ExchangeAdapter.fromIR(_:to:).
        if let Ok(meta) = std::fs::symlink_metadata(vault_path) {
            if meta.file_type().is_symlink() {
                return Err(VaultKitError::AdapterError(format!(
                    "exchange-adapter export target is a pre-existing symlink: {}",
                    vault_path.display()
                )));
            }
        }

        // Atomic write (Perkins advisory, VK-EXPORT-01): stage to a temp
        // file in the same directory, then rename — atomic on POSIX when
        // both paths share a filesystem — so a concurrent reader or a
        // crash mid-write can never observe a partial document. Matches
        // the Swift port's `Data.write(to:options:.atomic)`.
        let staged = vault_path.with_extension("json.tmp");
        std::fs::write(&staged, json)?;
        std::fs::rename(&staged, vault_path)?;
        Ok(())
    }
}

/// Validate the `path_components` array from a decoded export entry.
///
/// Path components are semantic labels, not filesystem paths. Embedded
/// separators, traversal sequences (`..`), absolute-path markers, and empty
/// strings are invalid because they may be reinterpreted as filesystem escape
/// paths when a downstream adapter (e.g. `ObsidianAdapter::from_ir`) projects
/// them into a vault directory tree.
///
/// Mirrors Swift `ExchangeAdapter.validatedPathComponents(_:entryID:)`.
fn validated_path_components(
    components: Vec<String>,
    entry_id: &str,
) -> Result<Vec<String>, VaultKitError> {
    for component in &components {
        if component.is_empty()
            || component == "."
            || component == ".."
            || component.contains('/')
            || component.contains('\\')
            || component.starts_with('~')
        {
            return Err(VaultKitError::AdapterError(format!(
                "unsafe pathComponents entry {:?} in export entry {entry_id}",
                component
            )));
        }
    }
    Ok(components)
}
