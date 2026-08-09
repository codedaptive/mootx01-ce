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

use std::collections::BTreeSet;

use crate::drawer_mapping::iso8601_to_ms;
use crate::error::VaultKitError;
use locus_kit::{
    adjectives::{AdjectiveExportability, AdjectiveSensitivity},
    drawer_operational::ContentKind,
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
}
