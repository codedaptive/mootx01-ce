//! JsonImportBridge — the fourth import lane (seed-file JSON, schema v1).
//!
//! Rust port of `Sources/VaultKit/JsonImportBridge.swift`. The two
//! implementations must accept the byte-identical input set, reject with
//! byte-identical error messages, and land byte-identical estate
//! inventories for the same seed file — the determinism verification
//! script compares both.
//!
//! Sits beside the three shipping lanes (Obsidian/Markdown via VaultBridge,
//! MemPalace via PalaceBridge, GKF via the exchange adapter) and follows
//! their common bulk-import topology with three deliberate mutations:
//!
//!   1. TOTAL PRE-WRITE VALIDATION replaces count-and-skip guards. The seed
//!      file is machine-generated interchange: any schema violation means
//!      the producer is broken, so the import performs ZERO writes and
//!      returns one error naming the FIRST offending element. Never a
//!      partial estate.
//!   2. FILE ORDER IS INGESTION ORDER. `records` array order is semantic
//!      (supersession chains, timelines); the importer never sorts.
//!   3. THE IMPORTER ENDS AT ENCODE ENQUEUE. Drain barrier and dream are
//!      caller protocol steps (the seed-run protocol), not import steps.
//!
//! The canonical schema definition ships with this code at
//! `packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md`.

use std::collections::{BTreeSet, HashSet};

use uuid::Uuid;

use crate::drawer_mapping::{iso8601_to_ms, DrawerMapping};
use crate::error::VaultKitError;
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::handle::EstateHandle;
use locus_kit::{
    adjectives::{AdjectiveExportability, AdjectiveSensitivity},
    drawer_operational::{CaptureChannel, ContentKind},
    estate_types::LatticeAnchor,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
    provenance::{Channel, SourceType},
    tunnel_operational::TunnelKind,
};

// MARK: - Limits

/// Ceilings enforced on an untrusted seed file — the `MemPalaceImportLimits`
/// pattern applied to the JSON lane. ONE budget covers the whole import:
/// the byte ceiling is charged from the filesystem size BEFORE the file is
/// read into memory, and the row ceiling is the total across records,
/// facts, and tunnels (not a fresh allowance per section). Mirrors Swift
/// `JsonImportLimits`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JsonImportLimits {
    /// Maximum seed-file size in bytes. Checked against the on-disk size
    /// before the file is opened, so an oversized file is never read.
    /// Default 512 MiB: comfortably above the largest benchmark seed
    /// (~100 MB) while still refusing a runaway or hostile file.
    pub max_seed_file_bytes: usize,
    /// Maximum total element count (records + facts + tunnels). Default
    /// 2,000,000 — an order of magnitude above the largest benchmark seed,
    /// same "totals for the import" intent as `MemPalaceImportLimits`.
    pub max_rows: usize,
}

impl Default for JsonImportLimits {
    fn default() -> Self {
        Self {
            max_seed_file_bytes: 512 * 1024 * 1024,
            max_rows: 2_000_000,
        }
    }
}

// MARK: - Schema types (seed-file schema v1)

/// One validated record from the seed file's `records` array. Mirrors
/// Swift `JsonSeedRecord`; `event_time_ms` is epoch-MILLISECONDS (the
/// unit `CaptureFrame.event_time` consumes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonSeedRecord {
    /// File-unique stable id; the lineage anchor
    /// (`DrawerMapping::lineage_id` over this string).
    pub id: String,
    /// Non-empty drawer content (I-5).
    pub content: String,
    /// Event time in epoch milliseconds — schema v1 pins UTC ISO8601 with
    /// a trailing "Z" (offset forms are rejected for cross-port parity).
    pub event_time_ms: i64,
    /// Optional wing; `None` files under the import's default wing.
    pub wing: Option<String>,
    /// Non-empty room path.
    pub room: String,
    /// Content kind; schema default `Prose`.
    pub kind: ContentKind,
    /// Sensitivity adjective; schema default `Normal`.
    pub sensitivity: AdjectiveSensitivity,
    /// Exportability adjective; schema default `Private`.
    pub exportability: AdjectiveExportability,
}

/// One validated fact from the seed file's `facts` array. `record_id` is
/// guaranteed by the validator to resolve to a record id in the same file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonSeedFact {
    pub subject: String,
    pub predicate: String,
    pub object: String,
    pub record_id: String,
}

/// One validated tunnel from the seed file's `tunnels` array. `from`/`to`
/// are guaranteed by the validator to resolve to record ids in the same
/// file; `kind` is a member of the closed `TunnelKind` vocabulary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonSeedTunnel {
    pub from: String,
    pub to: String,
    pub kind: TunnelKind,
    /// Optional label; `None` gets the same "source -> target" fill-in the
    /// palace lane applies (I-5), resolved at import time when endpoint
    /// locations are known.
    pub label: Option<String>,
}

/// A fully validated seed file. Constructing one via `parse` IS phases 1–2
/// of the import: after it returns, every schema rule holds and the import
/// may proceed to estate work knowing the file cannot fail validation
/// mid-write. Mirrors Swift `JsonSeedFile`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonSeedFile {
    pub format_version: i64,
    /// Non-empty seed name (carried into the receipt for traceability).
    pub name: String,
    /// Records in FILE ORDER — the validator never reorders them.
    pub records: Vec<JsonSeedRecord>,
    pub facts: Vec<JsonSeedFact>,
    pub tunnels: Vec<JsonSeedTunnel>,
}

/// The only version this parser accepts.
pub const SUPPORTED_FORMAT_VERSION: i64 = 1;

// Closed key vocabularies (rigid schema: unknown keys are hard errors,
// because a misspelled optional key silently changing an estate is exactly
// the partial-damage class this lane exists to eliminate).
const TOP_LEVEL_KEYS: [&str; 5] = ["format_version", "name", "records", "facts", "tunnels"];
const RECORD_KEYS: [&str; 8] = [
    "id", "content", "event_time", "wing", "room", "kind", "sensitivity", "exportability",
];
const FACT_KEYS: [&str; 4] = ["subject", "predicate", "object", "record_id"];
const TUNNEL_KEYS: [&str; 4] = ["from", "to", "kind", "label"];

/// Tunnel kind vocabulary rendered into the unknown-kind error message.
const TUNNEL_KIND_VOCABULARY: &str = "supersedes, references, blocks, validates, contradicts, \
     derivesFrom, covers, elaborates, respondsTo, parent";

fn err(message: String) -> VaultKitError {
    VaultKitError::AdapterError(message)
}

impl JsonSeedFile {
    /// Parse and validate a whole seed file BEFORE any estate work.
    ///
    /// Any violation returns `VaultKitError::AdapterError` with ONE message
    /// naming the first offending element (record index + id where
    /// applicable). Messages are pinned byte-identical to the Swift twin.
    pub fn parse(data: &[u8], limits: &JsonImportLimits) -> Result<JsonSeedFile, VaultKitError> {
        // Byte ceiling on the in-memory document. `import_seed` additionally
        // charges the on-disk size before reading (palace pattern); this
        // check keeps the parser safe for callers that hand it raw bytes.
        if data.len() > limits.max_seed_file_bytes {
            return Err(err(format!(
                "seed file exceeds byte ceiling: {} bytes > limit {}",
                data.len(),
                limits.max_seed_file_bytes
            )));
        }

        // Phase 1 — parse. Library error detail is deliberately NOT
        // included: serde_json and Foundation phrase failures differently,
        // and the determinism script compares error output across ports.
        let parsed: serde_json::Value = match serde_json::from_slice(data) {
            Ok(v) => v,
            Err(_) => return Err(err("seed file is malformed JSON".to_string())),
        };
        let root = match parsed.as_object() {
            Some(o) => o,
            None => return Err(err("seed file top level must be a JSON object".to_string())),
        };

        // Rigid schema: unknown top-level keys are hard errors. serde_json's
        // default map is a BTreeMap (sorted keys), so the first unknown key
        // is alphabetically first — matching the Swift `sorted().first`.
        if let Some(unknown) = root.keys().find(|k| !TOP_LEVEL_KEYS.contains(&k.as_str())) {
            return Err(err(format!(
                "unknown top-level key \"{unknown}\" — schema v1 keys are format_version, name, records, facts, tunnels"
            )));
        }

        // format_version gate runs FIRST among field checks: a future-
        // version file must fail on the version, not on whatever field
        // changed.
        let version_value = root
            .get("format_version")
            .ok_or_else(|| err("format_version is missing (expected 1)".to_string()))?;
        let version = int_value(version_value)
            .ok_or_else(|| err("format_version must be an integer (expected 1)".to_string()))?;
        if version != SUPPORTED_FORMAT_VERSION {
            return Err(err(format!(
                "unsupported format_version: found {version}, expected 1"
            )));
        }

        let name = match root.get("name").and_then(|v| v.as_str()) {
            Some(n) if !n.is_empty() => n.to_string(),
            _ => return Err(err("name is missing or empty".to_string())),
        };

        let records_raw = match root.get("records").and_then(|v| v.as_array()) {
            Some(a) => a,
            None => return Err(err("records is missing (expected an array)".to_string())),
        };
        let facts_raw = optional_array(root, "facts")?;
        let tunnels_raw = optional_array(root, "tunnels")?;

        // Row ceiling — ONE total across all three sections.
        let total_rows = records_raw.len() + facts_raw.len() + tunnels_raw.len();
        if total_rows > limits.max_rows {
            return Err(err(format!(
                "seed file exceeds row ceiling: {} elements > limit {}",
                total_rows, limits.max_rows
            )));
        }

        // Phase 2 — total validation, in file order, first offender wins.
        let mut records: Vec<JsonSeedRecord> = Vec::with_capacity(records_raw.len());
        let mut seen_ids: BTreeSet<String> = BTreeSet::new();
        for (index, element) in records_raw.iter().enumerate() {
            records.push(parse_record(element, index, &mut seen_ids)?);
        }
        let record_ids = seen_ids;

        let mut facts: Vec<JsonSeedFact> = Vec::with_capacity(facts_raw.len());
        for (index, element) in facts_raw.iter().enumerate() {
            facts.push(parse_fact(element, index, &record_ids)?);
        }

        let mut tunnels: Vec<JsonSeedTunnel> = Vec::with_capacity(tunnels_raw.len());
        for (index, element) in tunnels_raw.iter().enumerate() {
            tunnels.push(parse_tunnel(element, index, &record_ids)?);
        }

        Ok(JsonSeedFile {
            format_version: version,
            name,
            records,
            facts,
            tunnels,
        })
    }
}

// MARK: - Element parsers

fn parse_record(
    element: &serde_json::Value,
    index: usize,
    seen_ids: &mut BTreeSet<String>,
) -> Result<JsonSeedRecord, VaultKitError> {
    let object = element
        .as_object()
        .ok_or_else(|| err(format!("record[{index}]: must be a JSON object")))?;
    // id first so every later error can name it.
    let id = match object.get("id").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return Err(err(format!("record[{index}]: id is missing or empty"))),
    };
    let at = format!("record[{index}] (id \"{id}\")");

    if let Some(unknown) = object.keys().find(|k| !RECORD_KEYS.contains(&k.as_str())) {
        return Err(err(format!(
            "{at}: unknown key \"{unknown}\" — schema v1 record keys are id, content, event_time, wing, room, kind, sensitivity, exportability"
        )));
    }
    if seen_ids.contains(&id) {
        return Err(err(format!(
            "{at}: duplicate id — ids must be unique within the seed file"
        )));
    }
    seen_ids.insert(id.clone());

    let content = match object.get("content").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => {
            return Err(err(format!(
                "{at}: content is missing or empty (I-5: content must be non-empty)"
            )))
        }
    };
    let event_time_raw = object
        .get("event_time")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            err(format!(
                "{at}: event_time is missing (expected UTC ISO8601, e.g. 2026-01-03T09:00:00Z)"
            ))
        })?;
    let event_time_ms = parse_utc_iso8601_ms(event_time_raw).ok_or_else(|| {
        err(format!(
            "{at}: event_time is not UTC ISO8601 (\"{event_time_raw}\" — expected the form 2026-01-03T09:00:00Z; offset forms are not accepted)"
        ))
    })?;
    let room = match object.get("room").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return Err(err(format!("{at}: room is missing or empty"))),
    };

    let wing: Option<String> = if object.contains_key("wing") {
        match object.get("wing").and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => Some(s.to_string()),
            _ => {
                return Err(err(format!(
                    "{at}: wing is empty (omit it to use the default wing)"
                )))
            }
        }
    } else {
        None
    };

    let kind: ContentKind = if object.contains_key("kind") {
        let label = object.get("kind").and_then(|v| v.as_str());
        match label.and_then(kind_from_label) {
            Some(k) => k,
            None => {
                return Err(err(format!(
                    "{at}: unknown kind \"{}\" (valid: prose, code, transcript, list, structuredJSON, imageCaption)",
                    string_or_type(object.get("kind"))
                )))
            }
        }
    } else {
        ContentKind::Prose
    };

    let sensitivity: AdjectiveSensitivity = if object.contains_key("sensitivity") {
        let label = object.get("sensitivity").and_then(|v| v.as_str());
        match label.and_then(sensitivity_from_label_strict) {
            Some(s) => s,
            None => {
                return Err(err(format!(
                    "{at}: unknown sensitivity \"{}\" (valid: normal, elevated, restricted, secret)",
                    string_or_type(object.get("sensitivity"))
                )))
            }
        }
    } else {
        AdjectiveSensitivity::Normal
    };

    let exportability: AdjectiveExportability = if object.contains_key("exportability") {
        let label = object.get("exportability").and_then(|v| v.as_str());
        match label.and_then(exportability_from_label_strict) {
            Some(e) => e,
            None => {
                return Err(err(format!(
                    "{at}: unknown exportability \"{}\" (valid: private, public)",
                    string_or_type(object.get("exportability"))
                )))
            }
        }
    } else {
        AdjectiveExportability::Private
    };

    Ok(JsonSeedRecord {
        id,
        content,
        event_time_ms,
        wing,
        room,
        kind,
        sensitivity,
        exportability,
    })
}

fn parse_fact(
    element: &serde_json::Value,
    index: usize,
    record_ids: &BTreeSet<String>,
) -> Result<JsonSeedFact, VaultKitError> {
    let object = element
        .as_object()
        .ok_or_else(|| err(format!("fact[{index}]: must be a JSON object")))?;
    let at = format!("fact[{index}]");
    if let Some(unknown) = object.keys().find(|k| !FACT_KEYS.contains(&k.as_str())) {
        return Err(err(format!(
            "{at}: unknown key \"{unknown}\" — schema v1 fact keys are subject, predicate, object, record_id"
        )));
    }
    // Required-and-non-empty, in a fixed field order so the first offender
    // is deterministic.
    let mut fields: Vec<String> = Vec::with_capacity(4);
    for key in ["subject", "predicate", "object", "record_id"] {
        match object.get(key).and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => fields.push(s.to_string()),
            _ => return Err(err(format!("{at}: {key} is missing or empty"))),
        }
    }
    let record_id = fields[3].clone();
    if !record_ids.contains(&record_id) {
        return Err(err(format!(
            "{at}: record_id \"{record_id}\" does not resolve to a record id in this file"
        )));
    }
    Ok(JsonSeedFact {
        subject: fields[0].clone(),
        predicate: fields[1].clone(),
        object: fields[2].clone(),
        record_id,
    })
}

fn parse_tunnel(
    element: &serde_json::Value,
    index: usize,
    record_ids: &BTreeSet<String>,
) -> Result<JsonSeedTunnel, VaultKitError> {
    let object = element
        .as_object()
        .ok_or_else(|| err(format!("tunnel[{index}]: must be a JSON object")))?;
    let at = format!("tunnel[{index}]");
    if let Some(unknown) = object.keys().find(|k| !TUNNEL_KEYS.contains(&k.as_str())) {
        return Err(err(format!(
            "{at}: unknown key \"{unknown}\" — schema v1 tunnel keys are from, to, kind, label"
        )));
    }
    let from = match object.get("from").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return Err(err(format!("{at}: from is missing or empty"))),
    };
    if !record_ids.contains(&from) {
        return Err(err(format!(
            "{at}: from \"{from}\" does not resolve to a record id in this file"
        )));
    }
    let to = match object.get("to").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return Err(err(format!("{at}: to is missing or empty"))),
    };
    if !record_ids.contains(&to) {
        return Err(err(format!(
            "{at}: to \"{to}\" does not resolve to a record id in this file"
        )));
    }
    let kind = match object
        .get("kind")
        .and_then(|v| v.as_str())
        .and_then(tunnel_kind_from_label)
    {
        Some(k) => k,
        None => {
            return Err(err(format!(
                "{at}: unknown kind \"{}\" (valid: {TUNNEL_KIND_VOCABULARY})",
                string_or_type(object.get("kind"))
            )))
        }
    };
    let label: Option<String> = if object.contains_key("label") {
        match object.get("label").and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => Some(s.to_string()),
            _ => {
                return Err(err(format!(
                    "{at}: label is empty (omit it to use the generated default)"
                )))
            }
        }
    } else {
        None
    };
    Ok(JsonSeedTunnel {
        from,
        to,
        kind,
        label,
    })
}

// MARK: - Small helpers

/// `facts` / `tunnels` are optional sections; when present they must be
/// arrays (a non-array value is a schema violation, not an empty default).
fn optional_array<'a>(
    root: &'a serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Result<&'a [serde_json::Value], VaultKitError> {
    match root.get(key) {
        None => Ok(&[]),
        Some(value) => value
            .as_array()
            .map(|a| a.as_slice())
            .ok_or_else(|| err(format!("{key} must be an array when present"))),
    }
}

/// Strict integer extraction that mirrors the Swift NSNumber behavior:
/// exact-integer doubles (1.0) are accepted, fractional values (1.5) and
/// non-numbers are not. JSON booleans are a distinct type in serde_json,
/// so no boolean guard is needed here (the Swift twin checks explicitly).
fn int_value(value: &serde_json::Value) -> Option<i64> {
    if let Some(i) = value.as_i64() {
        return Some(i);
    }
    if let Some(f) = value.as_f64() {
        if f.fract() == 0.0 && f >= i64::MIN as f64 && f <= i64::MAX as f64 {
            return Some(f as i64);
        }
    }
    None
}

/// Render an unknown-value diagnostic: the string itself when the value is
/// a string (the common case — a bad label), else its JSON type name.
/// Mirrors Swift `stringOrType`.
fn string_or_type(value: Option<&serde_json::Value>) -> String {
    match value {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(_)) => "<number>".to_string(),
        Some(serde_json::Value::Array(_)) => "<array>".to_string(),
        Some(serde_json::Value::Object(_)) => "<object>".to_string(),
        Some(serde_json::Value::Bool(_)) => "<unknown>".to_string(),
        Some(serde_json::Value::Null) | None => "<null>".to_string(),
    }
}

/// Record kinds admitted at this boundary — the same six content kinds the
/// `moot_file_memory` surface accepts. The internal kinds
/// (`FingerprintOnly`, `Dataset`) are deliberately NOT importable: they
/// are system-managed representations, not seedable content.
fn kind_from_label(label: &str) -> Option<ContentKind> {
    match label {
        "prose" => Some(ContentKind::Prose),
        "code" => Some(ContentKind::Code),
        "transcript" => Some(ContentKind::Transcript),
        "list" => Some(ContentKind::List),
        "structuredJSON" => Some(ContentKind::StructuredJson),
        "imageCaption" => Some(ContentKind::ImageCaption),
        _ => None,
    }
}

/// Strict sensitivity labels — unlike the palace lane's lenient
/// `sensitivity_from_label` (which defaults unknown labels to Normal),
/// the rigid schema REJECTS unknown labels. Mirrors Swift
/// `DrawerMapping.sensitivity(fromLabel:)` returning nil.
fn sensitivity_from_label_strict(label: &str) -> Option<AdjectiveSensitivity> {
    match label {
        "normal" => Some(AdjectiveSensitivity::Normal),
        "elevated" => Some(AdjectiveSensitivity::Elevated),
        "restricted" => Some(AdjectiveSensitivity::Restricted),
        "secret" => Some(AdjectiveSensitivity::Secret),
        _ => None,
    }
}

/// Strict exportability labels; unknown labels are rejected. Mirrors Swift
/// `DrawerMapping.exportability(fromLabel:)` returning nil.
fn exportability_from_label_strict(label: &str) -> Option<AdjectiveExportability> {
    match label {
        "private" => Some(AdjectiveExportability::Private),
        "public" => Some(AdjectiveExportability::Public),
        _ => None,
    }
}

/// Tunnel kind labels — the full closed `TunnelKind` vocabulary, spelled
/// as the Swift case names (the canonical spelling in schema v1).
fn tunnel_kind_from_label(label: &str) -> Option<TunnelKind> {
    match label {
        "supersedes" => Some(TunnelKind::Supersedes),
        "references" => Some(TunnelKind::References),
        "blocks" => Some(TunnelKind::Blocks),
        "validates" => Some(TunnelKind::Validates),
        "contradicts" => Some(TunnelKind::Contradicts),
        "derivesFrom" => Some(TunnelKind::DerivesFrom),
        "covers" => Some(TunnelKind::Covers),
        "elaborates" => Some(TunnelKind::Elaborates),
        "respondsTo" => Some(TunnelKind::RespondsTo),
        "parent" => Some(TunnelKind::Parent),
        _ => None,
    }
}

/// Schema v1 event_time parser: UTC ISO8601 with a REQUIRED trailing "Z".
/// Exactly two shapes are accepted — `YYYY-MM-DDTHH:MM:SSZ` and
/// `YYYY-MM-DDTHH:MM:SS.fffZ` (milliseconds, exactly 3 fraction digits).
/// Component ranges and the calendar (month lengths, leap years) are
/// validated EXPLICITLY — `iso8601_to_ms` alone would silently accept
/// out-of-range components and ignore offset suffixes. Mirrors Swift
/// `parseUTCISO8601` byte-for-byte on the accepted input set.
fn parse_utc_iso8601_ms(s: &str) -> Option<i64> {
    let bytes = s.as_bytes();
    if !s.ends_with('Z') {
        return None;
    }
    match bytes.len() {
        20 => {}
        24 => {
            if bytes[19] != b'.' {
                return None;
            }
            if !bytes[20..23].iter().all(u8::is_ascii_digit) {
                return None;
            }
        }
        _ => return None,
    }
    if bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return None;
    }
    const DIGIT_INDEXES: [usize; 14] = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18];
    if !DIGIT_INDEXES.iter().all(|&i| bytes[i].is_ascii_digit()) {
        return None;
    }
    let field = |range: std::ops::Range<usize>| -> i64 { s[range].parse().unwrap() };
    let year = field(0..4);
    let month = field(5..7);
    let day = field(8..10);
    let hour = field(11..13);
    let minute = field(14..16);
    let second = field(17..19);
    if !(1..=12).contains(&month) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let days_in_month = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if !(1..=days_in_month[(month - 1) as usize]).contains(&day) {
        return None;
    }
    // Shape and calendar are valid; `iso8601_to_ms` computes the instant
    // (it reads the same fixed positions and the optional 3-digit fraction).
    iso8601_to_ms(s)
}

// MARK: - Bridge (phases 3–8)

// Default field values that mirror VaultBridge / PalaceBridge defaults.
const ADDED_BY: &str = "jsonimportbridge-import";
const EMBEDDING_MODEL_ID: &str = "vaultkit-noembed-v1";
/// UDC sentinel for unclassified content — exactly the anchor
/// `PalaceBridge::build_chroma_frame` stamps; the GLK capture seam
/// classifies on ingestion when the sentinel is present.
const FALLBACK_UDC: &str = "000";

/// The JSON import lane's estate-facing half. Phases 1–2 (parse + total
/// validation) live on `JsonSeedFile::parse`; this type owns the snapshot,
/// the strict-append assertion, the pure frame build, and (Parts 3–4) the
/// windowed write, relationship pass, encode enqueue, and receipt.
/// Mirrors Swift `JsonImportBridge`; holds a mutable reference to an
/// `EstateCoordinator` (the same pattern as `VaultBridge`/`PalaceBridge`).
pub struct JsonImportBridge<'a> {
    coordinator: &'a mut EstateCoordinator,
    /// The ceilings this bridge enforces on an untrusted seed file.
    limits: JsonImportLimits,
}

impl<'a> JsonImportBridge<'a> {
    /// Create a bridge at the shipping import limits.
    pub fn new(coordinator: &'a mut EstateCoordinator) -> Self {
        Self {
            coordinator,
            limits: JsonImportLimits::default(),
        }
    }

    /// Create a bridge with explicit limits, for a caller with a
    /// known-good oversized seed.
    pub fn with_limits(coordinator: &'a mut EstateCoordinator, limits: JsonImportLimits) -> Self {
        Self { coordinator, limits }
    }

    // MARK: Phase 3 — occupied-lineage snapshot

    /// Snapshot every lineage the estate already carries — active,
    /// withdrawn (usedToBelieve), and erased (tombstoned). ONE snapshot
    /// before any write; no per-row probes. The recall frames are the
    /// same shapes `PalaceBridge::existing_drawer_state` /
    /// `existing_tombstoned_lineage_ids` use, at `Structured` hydration
    /// because only lineage ids are needed (the JSON lane has no
    /// content-idempotent guard to feed — overlap of any kind is an
    /// error). Mirrors Swift `occupiedLineageIDs`.
    pub fn occupied_lineage_ids(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<HashSet<Uuid>, VaultKitError> {
        let active_frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Structured,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let active = self
            .coordinator
            .recall(handle, active_frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let withdrawn_frame = RecallFrame {
            filter_chain: vec![Filter::UsedToBelieve],
            hydration_level: HydrationLevel::Structured,
            limit: Some(10_000_000),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let withdrawn = self
            .coordinator
            .recall(handle, withdrawn_frame, now)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let erased = self
            .coordinator
            .tombstoned_lineage_ids(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        let mut occupied: HashSet<Uuid> = active.into_iter().map(|d| d.lineage_id).collect();
        occupied.extend(withdrawn.into_iter().map(|d| d.lineage_id));
        occupied.extend(erased);
        Ok(occupied)
    }
}

// MARK: Phase 3 — strict-append assertion (pure)

/// Strict-append assertion: any overlap between the file's record lineages
/// and the estate is a hard error naming the FIRST colliding record in
/// file order. Silent dedup is banned as a determinism hazard — a seed
/// file either builds exactly what it says or builds nothing. (A
/// withdrawn/erased overlap would otherwise resurrect or shadow a
/// tombstoned lineage, so those count as collisions too.) Mirrors Swift
/// `JsonImportBridge.assertStrictAppend`; the error message is pinned
/// byte-identical.
pub fn assert_strict_append(
    file: &JsonSeedFile,
    occupied: &HashSet<Uuid>,
) -> Result<(), VaultKitError> {
    for (index, record) in file.records.iter().enumerate() {
        let lineage = DrawerMapping::lineage_id(&record.id);
        if occupied.contains(&lineage) {
            return Err(err(format!(
                "record[{index}] (id \"{}\"): lineage collision — this id's lineage already exists in the estate (strict append: the JSON lane never dedups)",
                record.id
            )));
        }
    }
    Ok(())
}

// MARK: Phase 4 — pure frame build (file order)

/// Build one `CaptureFrame` per record, in FILE ORDER, with explicit
/// lineage (from the record id) and explicit `event_time` (validated at
/// parse). Pure: no estate access, no clock — same input, same frames,
/// every time, both ports. Mirrors Swift `JsonImportBridge.buildFrames`.
///
/// `default_wing` fills records that omit `wing`; `None` leaves the frame
/// wing `None` so the estate default wing applies at capture.
pub fn build_frames(file: &JsonSeedFile, default_wing: Option<&str>) -> Vec<CaptureFrame> {
    file.records
        .iter()
        .map(|record| {
            let mut frame = CaptureFrame::new(
                record.content.as_str(),
                CaptureChannel::ImportedFile,
                record.room.as_str(),
                // Sentinel UDC anchor exactly as build_chroma_frame does.
                LatticeAnchor::udc(FALLBACK_UDC),
                ADDED_BY,
                EMBEDDING_MODEL_ID,
            );
            frame.sensitivity = record.sensitivity;
            frame.exportability = record.exportability;
            frame.kind = record.kind;
            // Provenance: imported from a file (same stamps as
            // DrawerMapping's vault import path).
            frame.provenance_channel = Channel::FileImport;
            frame.source_type = SourceType::Imported;
            frame.lineage_id = Some(DrawerMapping::lineage_id(&record.id));
            frame.event_time = Some(record.event_time_ms);
            frame.wing = record
                .wing
                .clone()
                .or_else(|| default_wing.map(str::to_string));
            frame
        })
        .collect()
}

// MARK: - Report

/// Counts returned by a seed-file import run. Unlike `ImportReport` there
/// are no skip counters: the JSON lane has no skips — a file either lands
/// whole or errors with zero writes. Mirrors Swift `JsonImportReport`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct JsonImportReport {
    /// The seed file's `name`, carried into the receipt for traceability.
    pub seed_name: String,
    /// Drawers captured (exactly `records.len()` on success — strict
    /// append means every record is a fresh lineage).
    pub drawers_written: usize,
    /// KG facts filed from the `facts` section.
    pub facts_written: usize,
    /// Tunnels created from the `tunnels` section.
    pub tunnels_created: usize,
    /// Drawers enqueued for semantic encoding by the phase-7 deferred
    /// sweep, mirroring `ImportReport.enqueued_for_encode`.
    pub enqueued_for_encode: usize,
    /// Lowercase-hex SHA-256 of the seed file's exact input bytes, carried
    /// into the audit receipt so any estate is traceable to the seed file
    /// that built it.
    pub seed_sha256: String,
}

// MARK: - Import pipeline (phases 1–6)

impl JsonImportBridge<'_> {
    /// Import a seed file (schema v1) into the estate.
    ///
    /// Phases: (1) parse under the byte ceiling, (2) total validation —
    /// any violation is ZERO writes and one error naming the first
    /// offending element, (3) one occupied-lineage snapshot + strict-
    /// append assertion, (4) pure frame build in file order, (5) windowed
    /// bulk write via `capture_batch` in `import_policy::BULK_WINDOW`
    /// transaction windows, (6) intra-file relationship pass (facts,
    /// tunnels). Mirrors Swift `importSeed`.
    ///
    /// Determinism: `now` is caller-supplied (epoch ms) and stamps only
    /// fact filing times and (Part 4) the receipt; drawer event times come
    /// from the records.
    pub fn import_seed(
        &mut self,
        seed_path: &std::path::Path,
        handle: &EstateHandle,
        default_wing: Option<&str>,
        now: i64,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
        mode: genius_locus_kit::EncodeSpeed,
    ) -> Result<JsonImportReport, VaultKitError> {
        self.import_seed_windowed(
            seed_path,
            handle,
            default_wing,
            now,
            progress,
            mode,
            crate::import_policy::BULK_WINDOW,
        )
    }

    /// Internal seam with an explicit `window_size` so the windowed-write
    /// bookkeeping is testable without a 125k-record fixture. Production
    /// entry (above) always passes `import_policy::BULK_WINDOW`.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn import_seed_windowed(
        &mut self,
        seed_path: &std::path::Path,
        handle: &EstateHandle,
        default_wing: Option<&str>,
        now: i64,
        progress: Option<&crate::vault_adapter::VaultProgress<'_>>,
        mode: genius_locus_kit::EncodeSpeed,
        window_size: usize,
    ) -> Result<JsonImportReport, VaultKitError> {
        // Phase 1 — byte ceiling charged from the on-disk size BEFORE the
        // file is read (palace pattern), then parse + total validation
        // (phase 2). Zero estate interaction until both pass.
        let metadata = std::fs::metadata(seed_path)
            .map_err(|_| err(format!("seed file not found at {}", seed_path.display())))?;
        let on_disk_bytes = metadata.len() as usize;
        if on_disk_bytes > self.limits.max_seed_file_bytes {
            return Err(err(format!(
                "seed file exceeds byte ceiling: {} bytes > limit {} at {}",
                on_disk_bytes,
                self.limits.max_seed_file_bytes,
                seed_path.display()
            )));
        }
        let data = std::fs::read(seed_path).map_err(|e| {
            err(format!(
                "seed file could not be read at {}: {e}",
                seed_path.display()
            ))
        })?;
        let file = JsonSeedFile::parse(&data, &self.limits)?;

        // Phase 3 — ONE snapshot, then the strict-append assertion. Any
        // overlap is a hard error before any write.
        let occupied = self.occupied_lineage_ids(handle, now)?;
        assert_strict_append(&file, &occupied)?;

        // Declare the encode SPEED before any encode work is enqueued —
        // SPEED only, the write strategy is fixed.
        self.coordinator.set_encode_speed(handle, mode);

        let mut report = JsonImportReport {
            seed_name: file.name.clone(),
            ..Default::default()
        };

        // Phase 4 — pure frame build in file order.
        let frames = build_frames(&file, default_wing);

        // Phase 5 — windowed bulk write: one transaction per window,
        // report bookkeeping advancing per COMMITTED window (a mid-import
        // failure reports only rows that actually landed). No stream
        // branch. The record-id → drawer map is built from the returned
        // drawers, which `capture_batch` yields in input order.
        let mut drawers_by_record_id: std::collections::HashMap<String, locus_kit::drawer::Drawer> =
            std::collections::HashMap::with_capacity(file.records.len());
        let mut processed: usize = 0;
        let total = file.records.len();
        let mut start = 0;
        while start < frames.len() {
            let end = (start + window_size).min(frames.len());
            let written = self
                .coordinator
                .capture_batch(handle, frames[start..end].to_vec(), now)
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            for (record, drawer) in file.records[start..end].iter().zip(written) {
                drawers_by_record_id.insert(record.id.clone(), drawer);
                report.drawers_written += 1;
                processed += 1;
                if processed % 10 == 0 {
                    if let Some(p) = &progress {
                        p(processed, total);
                    }
                }
            }
            start = end;
        }

        // Phase 6 — relationship pass. Facts and tunnels resolve their
        // endpoints through the id → drawer map (the validator guaranteed
        // every reference resolves, so a miss here is impossible by
        // construction). Facts anchor to the record's drawer and inherit
        // its bitmaps through the standard KG fact seam.
        for fact in &file.facts {
            let anchor = &drawers_by_record_id[&fact.record_id];
            let origin = locus_kit::kg_fact::KGFactOrigin {
                added_by: ADDED_BY.to_string(),
                foreign_source_key: String::new(),
                foreign_record_id: String::new(),
            };
            self.coordinator
                .add_kg_fact_with_origin(
                    handle,
                    &fact.subject,
                    &fact.predicate,
                    &fact.object,
                    &anchor.id,
                    &origin,
                    now,
                )
                .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
            report.facts_written += 1;
        }

        if !file.tunnels.is_empty() {
            // Endpoint wing/room names resolved once for all imported
            // drawers (batch-returned drawers carry node ids, not names).
            let all_drawers: Vec<locus_kit::drawer::Drawer> =
                drawers_by_record_id.values().cloned().collect();
            let node_names = crate::drawer_mapping::resolve_drawer_node_names(
                self.coordinator,
                handle,
                &all_drawers,
            );
            for tunnel in &file.tunnels {
                let source = &drawers_by_record_id[&tunnel.from];
                let target = &drawers_by_record_id[&tunnel.to];
                let empty = (String::new(), String::new());
                let (source_wing, source_room) =
                    node_names.get(&source.parent_node_id).unwrap_or(&empty);
                let (target_wing, target_room) =
                    node_names.get(&target.parent_node_id).unwrap_or(&empty);
                // Unlabeled tunnels get the same "source -> target"
                // fill-in the palace lane applies (I-5: non-empty body).
                let label = tunnel.label.clone().unwrap_or_else(|| {
                    format!("{source_wing}/{source_room} -> {target_wing}/{target_room}")
                });
                let mut frame = locus_kit::frames::TunnelCaptureFrame::new(
                    source_wing.as_str(),
                    source_room.as_str(),
                    target_wing.as_str(),
                    target_room.as_str(),
                    label,
                    ADDED_BY,
                );
                frame.source_drawer_id = Some(source.id.clone());
                frame.target_drawer_id = Some(target.id.clone());
                frame.kind = tunnel.kind;
                frame.origin_class = locus_kit::tunnel_operational::TunnelOriginClass::Imported;
                let estate = self
                    .coordinator
                    .estate_for(handle)
                    .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
                estate
                    .capture_tunnel(frame, now)
                    .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
                report.tunnels_created += 1;
            }
        }

        // Phase 7 — ONE deferred encode-enqueue sweep (delta-aware), the
        // exact `import_notes` seam (collect + enqueue + rollup). The
        // importer adds no drain barrier of its own and never dreams —
        // those are caller protocol steps in the seed-run protocol.
        if let Some((corpus, jobs)) = self
            .coordinator
            .collect_reindex_jobs(handle)
            .map_err(|e| VaultKitError::VerbError(format!("collect_reindex_jobs failed: {e:?}")))?
        {
            report.enqueued_for_encode = jobs.len();
            if jobs.is_empty() {
                // Nothing was missing: no new chunks enter the corpus, so
                // the Merkle tree and every embedding are exactly as
                // current as before this import — skip the tail entirely.
                eprintln!("[json-import] nothing to index — reindex tail skipped");
            } else {
                eprintln!(
                    "[json-import] {} drawers enqueued on the encode stream (embedded via the live basis at drain)",
                    jobs.len()
                );
                corpus.enqueue_change_batch(&jobs).map_err(|e| {
                    VaultKitError::VerbError(format!("enqueue_change_batch failed: {e:?}"))
                })?;
                self.coordinator.rollup_after_reindex(handle, now).map_err(|e| {
                    VaultKitError::VerbError(format!("rollup_after_reindex failed: {e:?}"))
                })?;
            }
        }

        // Phase 8 — audit receipt in the established receipt shape plus
        // `seedSha256` over the exact input bytes, so any estate is
        // traceable to the seed file that built it. Key order is pinned
        // byte-identical to the Swift twin's receipt.
        report.seed_sha256 = sha256_hex(&data);
        let source = seed_path.display().to_string();
        let entry = format!(
            "{{\"operation\":\"json-import\",\"source\":{},\"seedName\":{},\
             \"drawersWritten\":{},\"factsWritten\":{},\"tunnelsCreated\":{},\
             \"seedSha256\":\"{}\",\"occurredAt\":\"{}\"}}",
            json_string(&source),
            json_string(&report.seed_name),
            report.drawers_written,
            report.facts_written,
            report.tunnels_created,
            report.seed_sha256,
            crate::drawer_mapping::ms_to_iso8601(now),
        );
        self.write_receipt(&entry, handle, now)?;

        eprintln!(
            "json-import: {} drawers, {} facts, {} tunnels, {} enqueued for encode from seed {}",
            report.drawers_written,
            report.facts_written,
            report.tunnels_created,
            report.enqueued_for_encode,
            file.name
        );
        // Final 100% tick so the caller sees completion at the true total.
        if processed > 0 {
            if let Some(p) = &progress {
                p(processed, total);
            }
        }
        Ok(report)
    }

    /// File one receipt into the estate diary — same channel, wing/room,
    /// and bitmap as the vault/palace receipts (spec § 5.6: Migration
    /// event, Info severity, MigrationTool actor). `filed_at` carries the
    /// caller-supplied `now` so the receipt is deterministic and queryable
    /// by time. Mirrors `PalaceBridge::write_receipt`.
    fn write_receipt(
        &self,
        entry_text: &str,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(), VaultKitError> {
        use locus_kit::diary_operational::{DiaryActorClass, DiaryEventClass, DiarySeverity};
        let bitmap = DiaryEventClass::Migration.raw_value()
            | (DiarySeverity::Info.raw_value() << 4)
            | (DiaryActorClass::MigrationTool.raw_value() << 7);
        let mut entry = locus_kit::diary_entry::DiaryEntry::new(
            Uuid::new_v4().to_string(),
            crate::vault_bridge::VaultBridge::RECEIPT_AGENT_NAME.to_string(),
            entry_text.to_string(),
            "vault-receipt".to_string(),
            "wing_vaultkit".to_string(),
            "receipts".to_string(),
            now,
            "no-embedding".to_string(),
        );
        entry.operational_bitmap = bitmap;
        let estate = self
            .coordinator
            .estate_for(handle)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))?;
        estate
            .add_diary_entry(&entry)
            .map_err(|e| VaultKitError::VerbError(format!("{e:?}")))
    }
}

/// Minimal JSON string encoder for receipt fields that carry arbitrary
/// filesystem paths and seed names (quotes/backslashes escaped per
/// RFC 8259). Same encoding as the VaultBridge/PalaceBridge receipts.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// MARK: - SHA-256 (dependency-free)

/// Lowercase-hex SHA-256 of the seed file's exact input bytes.
///
/// Hand-rolled (FIPS 180-4) rather than pulling the `sha2` crate:
/// external dependencies in kits require explicit per-crate approval, and
/// vault-kit's dependency set does not include a hash crate. ~60 lines of
/// constant-table compression is cheaper than a dependency review, and the
/// NIST test vectors below pin correctness. The Swift twin uses CryptoKit
/// (a system framework); both ports produce the identical digest string.
fn sha256_hex(data: &[u8]) -> String {
    // FIPS 180-4 §4.2.2 round constants (first 32 bits of the fractional
    // parts of the cube roots of the first 64 primes).
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    // §5.3.3 initial hash value (first 32 bits of the fractional parts of
    // the square roots of the first 8 primes).
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    // §5.1.1 padding: append 0x80, zero-fill to 56 mod 64, then the
    // original bit length as a big-endian u64.
    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    // §6.2.2 compression, one 512-bit block at a time.
    for block in message.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut hex = String::with_capacity(64);
    for word in h {
        hex.push_str(&format!("{word:08x}"));
    }
    hex
}

// MARK: - Tests (mirrors JsonImportBridgeTests.swift Part 1 suite 1:1)

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_seed_path() -> std::path::PathBuf {
        let manifest = env!("CARGO_MANIFEST_DIR");
        std::path::PathBuf::from(manifest)
            .join("../Tests/VaultKitTests/Fixtures/seedfile/valid_seed.json")
    }

    fn parse_str(json: &str) -> Result<JsonSeedFile, VaultKitError> {
        JsonSeedFile::parse(json.as_bytes(), &JsonImportLimits::default())
    }

    /// Expect an AdapterError whose message contains every fragment.
    fn expect_parse_error(json: &str, limits: &JsonImportLimits, fragments: &[&str]) {
        match JsonSeedFile::parse(json.as_bytes(), limits) {
            Ok(_) => panic!("expected AdapterError containing {fragments:?}; parse succeeded"),
            Err(VaultKitError::AdapterError(message)) => {
                for fragment in fragments {
                    assert!(
                        message.contains(fragment),
                        "error message must contain \"{fragment}\"; got: {message}"
                    );
                }
            }
            Err(other) => panic!("expected AdapterError; got {other:?}"),
        }
    }

    fn expect_error(json: &str, fragments: &[&str]) {
        expect_parse_error(json, &JsonImportLimits::default(), fragments);
    }

    /// A minimal valid seed body the failure tests mutate one element at a
    /// time. Mirrors the Swift `seed(records:facts:tunnels:)` helper.
    fn seed(records: &str, facts: &str, tunnels: &str) -> String {
        format!(
            "{{\"format_version\": 1, \"name\": \"t\", \"records\": {records}, \
             \"facts\": {facts}, \"tunnels\": {tunnels}}}"
        )
    }

    const ONE_RECORD: &str = r#"[{"id": "r1", "content": "c1", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]"#;

    #[test]
    fn valid_fixture_parses_with_defaults_and_file_order() {
        let data = std::fs::read(fixture_seed_path()).expect("fixture readable");
        let file = JsonSeedFile::parse(&data, &JsonImportLimits::default()).expect("valid");

        assert_eq!(file.format_version, 1);
        assert_eq!(file.name, "fixture-valid-seed");
        assert_eq!(file.records.len(), 3);
        assert_eq!(file.facts.len(), 2);
        assert_eq!(file.tunnels.len(), 2);

        // records array order IS ingestion order — never sorted.
        let ids: Vec<&str> = file.records.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["r0001", "r0002", "r0003"]);

        // Optional fields get schema-v1 defaults.
        let r2 = &file.records[1];
        assert_eq!(r2.wing, None);
        assert_eq!(r2.kind, ContentKind::Prose);
        assert_eq!(r2.sensitivity, AdjectiveSensitivity::Normal);
        assert_eq!(r2.exportability, AdjectiveExportability::Private);

        // Explicit fields survive verbatim.
        let r3 = &file.records[2];
        assert_eq!(r3.wing.as_deref(), Some("Benchmark"));
        assert_eq!(r3.kind, ContentKind::Transcript);
        assert_eq!(r3.sensitivity, AdjectiveSensitivity::Elevated);
        assert_eq!(r3.exportability, AdjectiveExportability::Public);

        // Tunnel kinds decode from the closed vocabulary.
        assert_eq!(file.tunnels[0].kind, TunnelKind::Supersedes);
        assert_eq!(file.tunnels[1].kind, TunnelKind::References);
        assert_eq!(file.tunnels[1].label, None);
    }

    #[test]
    fn fractional_second_utc_event_time_parses_to_exact_instant() {
        let file = parse_str(&seed(
            r#"[{"id": "r1", "content": "c", "event_time": "2026-01-05T08:15:00.250Z", "room": "rm"}]"#,
            "[]",
            "[]",
        ))
        .expect("valid");
        let base = parse_utc_iso8601_ms("2026-01-05T08:15:00Z").unwrap();
        assert_eq!(file.records[0].event_time_ms, base + 250);
    }

    #[test]
    fn malformed_json_is_one_hard_error() {
        expect_error("{not json", &["malformed JSON"]);
    }

    #[test]
    fn top_level_array_rejected() {
        expect_error("[1, 2]", &["top level", "object"]);
    }

    #[test]
    fn wrong_format_version_names_the_version_found() {
        expect_error(
            r#"{"format_version": 2, "name": "t", "records": []}"#,
            &["format_version", "2", "expected 1"],
        );
    }

    #[test]
    fn missing_format_version_is_hard_error() {
        expect_error(r#"{"name": "t", "records": []}"#, &["format_version", "missing"]);
    }

    #[test]
    fn missing_or_empty_name_is_hard_error() {
        expect_error(r#"{"format_version": 1, "records": []}"#, &["name", "missing or empty"]);
        expect_error(
            r#"{"format_version": 1, "name": "", "records": []}"#,
            &["name", "missing or empty"],
        );
    }

    #[test]
    fn missing_records_is_hard_error() {
        expect_error(r#"{"format_version": 1, "name": "t"}"#, &["records", "missing"]);
    }

    #[test]
    fn unknown_top_level_key_rejected() {
        expect_error(
            r#"{"format_version": 1, "name": "t", "records": [], "extra": 1}"#,
            &["unknown top-level key", "extra"],
        );
    }

    #[test]
    fn record_missing_id_names_the_index() {
        expect_error(
            &seed(
                r#"[{"content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "id", "missing or empty"],
        );
    }

    #[test]
    fn duplicate_record_id_names_the_id() {
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "a", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                    {"id": "r2", "content": "b", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                    {"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &["record[2]", "\"r1\"", "duplicate id"],
        );
    }

    #[test]
    fn empty_content_names_the_record() {
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "\"r1\"", "content", "empty"],
        );
    }

    #[test]
    fn missing_event_time_names_the_record() {
        expect_error(
            &seed(r#"[{"id": "r1", "content": "c", "room": "rm"}]"#, "[]", "[]"),
            &["record[0]", "\"r1\"", "event_time", "missing"],
        );
    }

    #[test]
    fn bad_event_time_names_the_value() {
        // Garbage.
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "yesterday", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "event_time", "yesterday"],
        );
        // Offset form is rejected — schema v1 pins UTC "Z" (cross-port parity).
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00+02:00", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "event_time", "+02:00"],
        );
        // Fraction width other than 3 digits is rejected (pinned shape).
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00.25Z", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "event_time", "0.25Z"],
        );
        // Calendar-invalid date is rejected.
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-02-30T00:00:00Z", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "event_time", "2026-02-30"],
        );
    }

    #[test]
    fn missing_room_names_the_record() {
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "\"r1\"", "room", "missing or empty"],
        );
    }

    #[test]
    fn empty_wing_is_hard_error() {
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "wing": ""}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "wing", "empty"],
        );
    }

    #[test]
    fn bad_enum_labels_are_hard_errors() {
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "kind": "poem"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "kind", "poem"],
        );
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "sensitivity": "hush"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "sensitivity", "hush"],
        );
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "exportability": "shared"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "exportability", "shared"],
        );
    }

    #[test]
    fn unknown_record_key_rejected() {
        expect_error(
            &seed(
                r#"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "mood": "hopeful"}]"#,
                "[]",
                "[]",
            ),
            &["record[0]", "unknown key", "mood"],
        );
    }

    #[test]
    fn empty_fact_field_is_hard_error() {
        expect_error(
            &seed(
                ONE_RECORD,
                r#"[{"subject": "", "predicate": "p", "object": "o", "record_id": "r1"}]"#,
                "[]",
            ),
            &["fact[0]", "subject", "empty"],
        );
    }

    #[test]
    fn dangling_fact_record_id_names_the_id() {
        expect_error(
            &seed(
                ONE_RECORD,
                r#"[{"subject": "s", "predicate": "p", "object": "o", "record_id": "r9999"}]"#,
                "[]",
            ),
            &["fact[0]", "record_id", "\"r9999\"", "does not resolve"],
        );
    }

    #[test]
    fn dangling_tunnel_endpoints_name_the_id() {
        expect_error(
            &seed(
                ONE_RECORD,
                "[]",
                r#"[{"from": "r9", "to": "r1", "kind": "references"}]"#,
            ),
            &["tunnel[0]", "from", "\"r9\"", "does not resolve"],
        );
        expect_error(
            &seed(
                ONE_RECORD,
                "[]",
                r#"[{"from": "r1", "to": "r8", "kind": "references"}]"#,
            ),
            &["tunnel[0]", "to", "\"r8\"", "does not resolve"],
        );
    }

    #[test]
    fn bad_tunnel_kind_lists_the_vocabulary() {
        expect_error(
            &seed(
                ONE_RECORD,
                "[]",
                r#"[{"from": "r1", "to": "r1", "kind": "links"}]"#,
            ),
            &["tunnel[0]", "kind", "links", "references"],
        );
    }

    #[test]
    fn row_ceiling_is_hard_error() {
        let limits = JsonImportLimits {
            max_rows: 2,
            ..Default::default()
        };
        expect_parse_error(
            &seed(
                r#"[{"id": "r1", "content": "a", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                    {"id": "r2", "content": "b", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                    {"id": "r3", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]"#,
                "[]",
                "[]",
            ),
            &limits,
            &["row ceiling", "3", "2"],
        );
    }

    #[test]
    fn byte_ceiling_is_hard_error_before_decode() {
        let limits = JsonImportLimits {
            max_seed_file_bytes: 16,
            ..Default::default()
        };
        expect_parse_error(&seed(ONE_RECORD, "[]", "[]"), &limits, &["byte ceiling", "16"]);
    }

    // MARK: Part 2 — strict append + frame build (mirrors Swift
    // "JsonImportBridge strict append + frame build" suite 1:1)

    use locus_kit::{
        drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
        estate_types::OwnerCredentials,
    };
    use std::sync::Arc;

    /// Fixed operation instant (ms) used across the estate-backed tests.
    const NOW: i64 = 1_000_000_000_000i64;

    fn open_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coordinator = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
        let handle = coordinator
            .open(store, OwnerCredentials::new("jsonimportbridge-rust-tests"), 0, 100)
            .expect("open estate");
        (coordinator, handle)
    }

    fn fixture_file() -> JsonSeedFile {
        let data = std::fs::read(fixture_seed_path()).expect("fixture readable");
        JsonSeedFile::parse(&data, &JsonImportLimits::default()).expect("valid")
    }

    #[test]
    fn strict_append_passes_on_fresh_set() {
        let file = fixture_file();
        assert_strict_append(&file, &HashSet::new()).expect("no collision");
    }

    #[test]
    fn strict_append_names_first_colliding_record() {
        let file = fixture_file();
        // Occupy r0002 and r0003 — the FIRST in file order (r0002) is named.
        let occupied: HashSet<Uuid> = [
            DrawerMapping::lineage_id("r0002"),
            DrawerMapping::lineage_id("r0003"),
        ]
        .into_iter()
        .collect();
        match assert_strict_append(&file, &occupied) {
            Ok(()) => panic!("expected lineage-collision error"),
            Err(VaultKitError::AdapterError(message)) => {
                assert!(message.contains("record[1]"), "got: {message}");
                assert!(message.contains("\"r0002\""), "got: {message}");
                assert!(message.contains("lineage collision"), "got: {message}");
            }
            Err(other) => panic!("expected AdapterError; got {other:?}"),
        }
    }

    #[test]
    fn occupied_covers_active_and_withdrawn() {
        let (mut coordinator, handle) = open_estate();

        // Active drawer at r0001's lineage.
        let mut active_frame = CaptureFrame::new(
            "occupies r0001",
            CaptureChannel::ImportedFile,
            "rm",
            LatticeAnchor::udc("000"),
            "test",
            "no-embedding",
        );
        active_frame.lineage_id = Some(DrawerMapping::lineage_id("r0001"));
        let active = coordinator
            .capture(&handle, active_frame, NOW)
            .expect("capture active");

        // Withdrawn drawer at r0002's lineage.
        let mut withdrawn_frame = CaptureFrame::new(
            "occupies r0002",
            CaptureChannel::ImportedFile,
            "rm",
            LatticeAnchor::udc("000"),
            "test",
            "no-embedding",
        );
        withdrawn_frame.lineage_id = Some(DrawerMapping::lineage_id("r0002"));
        let withdrawn = coordinator
            .capture(&handle, withdrawn_frame, NOW)
            .expect("capture to withdraw");
        coordinator
            .withdraw(&handle, &withdrawn.id, Some("test-withdrawal"), NOW)
            .expect("withdraw");

        let bridge = JsonImportBridge::new(&mut coordinator);
        let occupied = bridge
            .occupied_lineage_ids(&handle, NOW)
            .expect("snapshot");
        assert!(occupied.contains(&active.lineage_id));
        assert!(occupied.contains(&withdrawn.lineage_id));

        // And the fixture file collides on record[0] (id r0001).
        let file = fixture_file();
        match assert_strict_append(&file, &occupied) {
            Ok(()) => panic!("expected lineage-collision error against the estate snapshot"),
            Err(VaultKitError::AdapterError(message)) => {
                assert!(message.contains("record[0]"), "got: {message}");
                assert!(message.contains("\"r0001\""), "got: {message}");
            }
            Err(other) => panic!("expected AdapterError; got {other:?}"),
        }
    }

    #[test]
    fn frame_build_deterministic_file_ordered_explicit_lineage() {
        let file = fixture_file();
        let first = build_frames(&file, None);
        let second = build_frames(&file, None);

        assert_eq!(first.len(), 3);
        // Field-by-field determinism.
        for (a, b) in first.iter().zip(second.iter()) {
            assert_eq!(a.content, b.content);
            assert_eq!(a.lineage_id, b.lineage_id);
            assert_eq!(a.event_time, b.event_time);
            assert_eq!(a.wing, b.wing);
            assert_eq!(a.room, b.room);
            assert_eq!(a.kind, b.kind);
            assert_eq!(a.sensitivity, b.sensitivity);
            assert_eq!(a.exportability, b.exportability);
        }
        // File order, not sorted: r0001, r0002, r0003.
        let expected: Vec<Uuid> = ["r0001", "r0002", "r0003"]
            .iter()
            .map(|id| DrawerMapping::lineage_id(id))
            .collect();
        let got: Vec<Uuid> = first.iter().map(|f| f.lineage_id.unwrap()).collect();
        assert_eq!(got, expected);
        // Explicit event times ride through (no `now` in frames).
        assert_eq!(
            first[0].event_time,
            Some(parse_utc_iso8601_ms("2026-01-03T09:00:00Z").unwrap())
        );
        // Sentinel UDC anchor exactly as build_chroma_frame: "000".
        assert!(first.iter().all(|f| f.lattice_anchor.udc_code == "000"));
        // Import provenance stamped.
        assert!(first.iter().all(|f| f.channel == CaptureChannel::ImportedFile));
        assert!(first.iter().all(|f| f.provenance_channel == Channel::FileImport));
        assert!(first.iter().all(|f| f.source_type == SourceType::Imported));
    }

    // MARK: Part 3 — import pipeline (mirrors Swift "JsonImportBridge
    // import pipeline (write + relationships)" suite 1:1)

    /// Write a seed JSON string to a temp file and return its path.
    fn temp_seed_file(json: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("jsonimport-rust-test-{}.json", Uuid::new_v4()));
        std::fs::write(&path, json).expect("temp seed writable");
        path
    }

    /// Stored (real) tunnels only: `recall_tunnels` unions synthetic
    /// "containment" tunnels from the node-topology provider into its
    /// result; those are structural echoes of the node tree, not rows the
    /// importer wrote, so inventory assertions must exclude them.
    fn stored_tunnels(
        coordinator: &EstateCoordinator,
        handle: &EstateHandle,
        wing: &str,
    ) -> Vec<locus_kit::tunnel::Tunnel> {
        coordinator
            .recall_tunnels(handle, wing)
            .expect("tunnels")
            .into_iter()
            .filter(|t| t.added_by != "nodeTopologyProvider")
            .collect()
    }

    #[test]
    fn fixture_round_trip_lands_exact_counts() {
        let (mut coordinator, handle) = open_estate();
        let report = {
            let mut bridge = JsonImportBridge::new(&mut coordinator);
            bridge
                .import_seed(
                    &fixture_seed_path(),
                    &handle,
                    None,
                    NOW,
                    None,
                    genius_locus_kit::EncodeSpeed::Foreground,
                )
                .expect("import succeeds")
        };

        assert_eq!(report.seed_name, "fixture-valid-seed");
        assert_eq!(report.drawers_written, 3);
        assert_eq!(report.facts_written, 2);
        assert_eq!(report.tunnels_created, 2);

        // Drawers landed with explicit event times (not `now`).
        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Full,
            limit: Some(100),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = coordinator.recall(&handle, frame, NOW).expect("recall");
        assert_eq!(drawers.len(), 3);
        let r1 = drawers
            .iter()
            .find(|d| d.lineage_id == DrawerMapping::lineage_id("r0001"))
            .expect("r0001 present");
        assert_eq!(
            r1.event_time,
            parse_utc_iso8601_ms("2026-01-03T09:00:00Z").unwrap()
        );

        // Facts landed anchored to their records' drawers.
        let facts = coordinator.recall_kg_facts(&handle).expect("facts");
        assert_eq!(facts.len(), 2);
        let thursday = facts
            .iter()
            .find(|f| f.object == "Thursday")
            .expect("Thursday fact");
        assert_eq!(thursday.source_drawer_id, r1.id);
        assert_eq!(thursday.subject, "planning meeting");

        // Tunnels landed with the explicit label; the unlabeled one's
        // source (r0002) lands in the estate DEFAULT wing, so only the
        // Benchmark-sourced supersedes tunnel is asserted by wing here.
        let benchmark_tunnels = stored_tunnels(&coordinator, &handle, "Benchmark");
        assert!(benchmark_tunnels
            .iter()
            .any(|t| t.kind == TunnelKind::Supersedes && t.label == "reschedule chain"));
    }

    #[test]
    fn two_window_seed_commits_both_windows() {
        let (mut coordinator, handle) = open_estate();

        // 5 records at an internal window size of 2 → 3 windows (2+2+1).
        let records: Vec<String> = (1..=5)
            .map(|i| {
                format!(
                    "{{\"id\": \"w{i}\", \"content\": \"window record {i}\", \
                     \"event_time\": \"2026-01-01T00:00:0{i}Z\", \"room\": \"rm\"}}"
                )
            })
            .collect();
        let json = format!(
            "{{\"format_version\": 1, \"name\": \"two-window\", \"records\": [{}]}}",
            records.join(",")
        );
        let path = temp_seed_file(&json);

        let report = {
            let mut bridge = JsonImportBridge::new(&mut coordinator);
            bridge
                .import_seed_windowed(
                    &path,
                    &handle,
                    None,
                    NOW,
                    None,
                    genius_locus_kit::EncodeSpeed::Foreground,
                    2,
                )
                .expect("import succeeds")
        };
        std::fs::remove_file(&path).ok();

        assert_eq!(report.drawers_written, 5);
        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Structured,
            limit: Some(100),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = coordinator.recall(&handle, frame, NOW).expect("recall");
        assert_eq!(drawers.len(), 5);
    }

    #[test]
    fn zero_writes_on_collision() {
        let (mut coordinator, handle) = open_estate();

        // Occupy r0002's lineage before the import.
        let mut occupying = CaptureFrame::new(
            "occupies r0002",
            CaptureChannel::ImportedFile,
            "rm",
            LatticeAnchor::udc("000"),
            "test",
            "no-embedding",
        );
        occupying.lineage_id = Some(DrawerMapping::lineage_id("r0002"));
        coordinator
            .capture(&handle, occupying, NOW)
            .expect("capture");

        let result = {
            let mut bridge = JsonImportBridge::new(&mut coordinator);
            bridge.import_seed(
                &fixture_seed_path(),
                &handle,
                None,
                NOW,
                None,
                genius_locus_kit::EncodeSpeed::Foreground,
            )
        };
        match result {
            Ok(_) => panic!("expected lineage-collision error"),
            Err(VaultKitError::AdapterError(message)) => {
                assert!(message.contains("\"r0002\""), "got: {message}");
            }
            Err(other) => panic!("expected AdapterError; got {other:?}"),
        }

        // ZERO writes: only the pre-existing drawer, no facts, no stored
        // tunnels (synthetic containment tunnels excluded — see
        // stored_tunnels).
        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Structured,
            limit: Some(100),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = coordinator.recall(&handle, frame, NOW).expect("recall");
        assert_eq!(drawers.len(), 1);
        let facts = coordinator.recall_kg_facts(&handle).expect("facts");
        assert!(facts.is_empty());
        let tunnels = stored_tunnels(&coordinator, &handle, "Benchmark");
        assert!(tunnels.is_empty());
    }

    #[test]
    fn zero_writes_on_invalid_file() {
        let (mut coordinator, handle) = open_estate();

        // Valid JSON, invalid schema (dangling tunnel endpoint) — the
        // validator must reject BEFORE any estate work.
        let path = temp_seed_file(
            "{\"format_version\": 1, \"name\": \"bad\", \"records\": [\
              {\"id\": \"r1\", \"content\": \"c\", \"event_time\": \"2026-01-01T00:00:00Z\", \"room\": \"rm\"}],\
             \"tunnels\": [{\"from\": \"r1\", \"to\": \"r999\", \"kind\": \"references\"}]}",
        );

        let result = {
            let mut bridge = JsonImportBridge::new(&mut coordinator);
            bridge.import_seed(
                &path,
                &handle,
                None,
                NOW,
                None,
                genius_locus_kit::EncodeSpeed::Foreground,
            )
        };
        std::fs::remove_file(&path).ok();
        match result {
            Ok(_) => panic!("expected validation error"),
            Err(VaultKitError::AdapterError(message)) => {
                assert!(message.contains("\"r999\""), "got: {message}");
            }
            Err(other) => panic!("expected AdapterError; got {other:?}"),
        }

        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Structured,
            limit: Some(100),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = coordinator.recall(&handle, frame, NOW).expect("recall");
        assert!(drawers.is_empty());
    }

    // MARK: Part 4 — enqueue + receipt (mirrors Swift "JsonImportBridge
    // enqueue + receipt" suite; the provisioned-corpus enqueue test lives
    // on the Swift side, where GLK provision() wires a deterministic-model
    // Corpus — the Rust in-memory coordinator registers no corpus, so
    // collect_reindex_jobs returns None and enqueued stays 0 here).

    #[test]
    fn sha256_matches_nist_vectors() {
        // FIPS 180-4 / NIST CAVS vectors pin the dependency-free
        // implementation to the standard.
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn receipt_carries_digest_and_counts() {
        let (mut coordinator, handle) = open_estate();
        let report = {
            let mut bridge = JsonImportBridge::new(&mut coordinator);
            bridge
                .import_seed(
                    &fixture_seed_path(),
                    &handle,
                    None,
                    NOW,
                    None,
                    genius_locus_kit::EncodeSpeed::Foreground,
                )
                .expect("import succeeds")
        };

        // Digest is the SHA-256 of the exact input bytes.
        let data = std::fs::read(fixture_seed_path()).expect("fixture readable");
        let expected = sha256_hex(&data);
        assert_eq!(report.seed_sha256, expected);

        // One receipt in the diary, in the established receipt shape plus
        // seedSha256.
        let receipts: Vec<_> = coordinator
            .recall_diary_entries(&handle)
            .expect("diary")
            .into_iter()
            .filter(|e| e.agent_name == crate::vault_bridge::VaultBridge::RECEIPT_AGENT_NAME)
            .collect();
        assert_eq!(receipts.len(), 1);
        let receipt = &receipts[0];
        assert_eq!(receipt.topic, "vault-receipt");
        assert_eq!(receipt.filed_at, NOW);
        assert!(receipt.entry.contains("\"operation\":\"json-import\""));
        assert!(receipt.entry.contains("\"seedName\":\"fixture-valid-seed\""));
        assert!(receipt.entry.contains("\"drawersWritten\":3"));
        assert!(receipt.entry.contains("\"factsWritten\":2"));
        assert!(receipt.entry.contains("\"tunnelsCreated\":2"));
        assert!(receipt
            .entry
            .contains(&format!("\"seedSha256\":\"{expected}\"")));
    }

    #[test]
    fn no_receipt_on_failure() {
        let (mut coordinator, handle) = open_estate();

        // Occupy r0001's lineage so the strict-append assertion fires.
        let mut occupying = CaptureFrame::new(
            "occupies r0001",
            CaptureChannel::ImportedFile,
            "rm",
            LatticeAnchor::udc("000"),
            "test",
            "no-embedding",
        );
        occupying.lineage_id = Some(DrawerMapping::lineage_id("r0001"));
        coordinator
            .capture(&handle, occupying, NOW)
            .expect("capture");

        {
            let mut bridge = JsonImportBridge::new(&mut coordinator);
            let _ = bridge.import_seed(
                &fixture_seed_path(),
                &handle,
                None,
                NOW,
                None,
                genius_locus_kit::EncodeSpeed::Foreground,
            );
        }

        let receipts: Vec<_> = coordinator
            .recall_diary_entries(&handle)
            .expect("diary")
            .into_iter()
            .filter(|e| e.agent_name == crate::vault_bridge::VaultBridge::RECEIPT_AGENT_NAME)
            .collect();
        assert!(receipts.is_empty());
    }

    #[test]
    fn default_wing_routes_records_omitting_wing() {
        let (mut coordinator, handle) = open_estate();
        {
            let mut bridge = JsonImportBridge::new(&mut coordinator);
            bridge
                .import_seed(
                    &fixture_seed_path(),
                    &handle,
                    Some("SeedWing"),
                    NOW,
                    None,
                    genius_locus_kit::EncodeSpeed::Foreground,
                )
                .expect("import succeeds");
        }

        let frame = RecallFrame {
            filter_chain: vec![Filter::Unconfirmed],
            hydration_level: HydrationLevel::Structured,
            limit: Some(100),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: None,
        };
        let drawers = coordinator.recall(&handle, frame, NOW).expect("recall");
        let r2 = drawers
            .iter()
            .find(|d| d.lineage_id == DrawerMapping::lineage_id("r0002"))
            .expect("r0002 present");
        let names = crate::drawer_mapping::resolve_drawer_node_names(
            &coordinator,
            &handle,
            std::slice::from_ref(r2),
        );
        assert_eq!(
            names.get(&r2.parent_node_id).map(|(w, _)| w.as_str()),
            Some("SeedWing")
        );
    }

    #[test]
    fn default_wing_fills_only_records_omitting_wing() {
        let file = fixture_file();
        let frames = build_frames(&file, Some("SeedWing"));
        // r0001 and r0003 carry explicit "Benchmark"; r0002 omits wing.
        assert_eq!(frames[0].wing.as_deref(), Some("Benchmark"));
        assert_eq!(frames[1].wing.as_deref(), Some("SeedWing"));
        assert_eq!(frames[2].wing.as_deref(), Some("Benchmark"));

        // With no default wing, the omitted record's frame carries None
        // (the estate default wing applies at capture).
        let bare = build_frames(&file, None);
        assert_eq!(bare[1].wing, None);
    }
}
