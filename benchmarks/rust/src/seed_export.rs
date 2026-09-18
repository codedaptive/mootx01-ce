//! seed_export — the shared schema-v1.1 seed-file emitter and the post-import
//! attribution pass (MXE-JI-2). Twin of `SeedExport.swift`.
//!
//! EMITTER. Every converted runner's batch seed path and every `--dump-seed`
//! goes through [`emit_seed_json`] — one seam, never parallel paths (ruling
//! 8D5B8053's enforcement note). Output is the seed-file schema v1.1 the
//! `moot_json_import` lane consumes, canonically defined in
//! `packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md`: dump output ==
//! importer input == the third-party interchange artifact.
//!
//! The writer is hand-rolled because the dump contract is BYTE determinism
//! across BOTH harness ports; the Swift twin implements the identical
//! algorithm and `benchmarks/conformance/seed_export_vectors.json` pins the
//! bytes. Format:
//!   - 2-space indentation, `"key": value`, LF line endings, no trailing
//!     newline
//!   - object keys in ASCII-sorted order (the "sorted keys" dump contract)
//!   - records/facts/tunnels arrays in CALLER order (file order is ingestion
//!     order — the importer never sorts, so the emitter must not either)
//!   - optional keys omitted when absent (schema v1.1 is rigid: omission
//!     means "apply the default"; null is a schema violation); `subject` is
//!     ALWAYS emitted — computed via `deterministic_subject`
//!   - empty facts/tunnels sections omitted entirely
//!   - string escaping: `\" \\ \n \r \t \b \f`, any other control char as
//!     `\u00xx` (lowercase hex) — everything else UTF-8 verbatim
//!
//! ATTRIBUTION PASS. The import receipt reports counts + seedSha256 only —
//! no record-id → drawer-UUID map — while several lanes attribute reply-
//! surface UUIDs (hunt reports, ranked dense rows) back to corpus records.
//! Live seeding got the map from each write's "filed memory <UUID>"; the
//! batch path rebuilds it READ-ONLY after the import + drain barrier: one
//! `moot_memory_list` per seeded (wing, room) yields dense rows, rows match
//! records by second-precision event time, and same-instant collisions are
//! settled by a `moot_memory_get` exact-content comparison. Drawer UUIDs
//! cannot be derived client-side: the FNV-1a-128 lineage id in the schema
//! doc is the drawer's LINEAGE, not its id — `captureBatch` mints the drawer
//! id fresh at insert and no MCP surface addresses by lineage.

use crate::json_value::JsonValue;
use crate::mcp_client::MCPError;

// ─────────────────────────────────────────────────────────────────────────────
// Seed-file element types
// ─────────────────────────────────────────────────────────────────────────────

/// One `records[]` element of seed-file schema v1/v1.2. Twin of `SeedFileRecord`.
///
/// Schema v1.2 adds `capture_date` (emitted before `content` in ASCII key
/// order: "capture_date" < "content"). When `None`, omitted — byte-identical
/// to v1.1 output (existing lanes are unaffected).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeedFileRecord {
    pub id: String,
    pub content: String,
    /// Schema v1.2: UTC ISO8601 with trailing Z. When set, the importer
    /// stamps the drawer's `filedAt` to this instant rather than the batch
    /// wall-clock. Emitted before `content` (ASCII order). None = omit.
    pub capture_date: Option<String>,
    /// UTC ISO8601 with trailing Z, second or millisecond precision.
    pub event_time: String,
    pub room: String,
    /// None = omit → the import's default wing ("Agentic Memory", matching
    /// where the live `moot_file_memory` path files when no wing is given).
    pub wing: Option<String>,
    /// None = omit → `prose`.
    pub kind: Option<String>,
    /// None = omit → `normal`.
    pub sensitivity: Option<String>,
    /// None = omit → `private`.
    pub exportability: Option<String>,
}

impl SeedFileRecord {
    /// A record with every optional field omitted (the common lane shape).
    /// Produces schema v1.1-compatible output (no `capture_date` → batch
    /// wall-clock for filedAt). Existing callers are unaffected.
    pub fn new(id: &str, content: &str, event_time: &str, room: &str) -> Self {
        Self {
            id: id.to_string(),
            content: content.to_string(),
            capture_date: None,
            event_time: event_time.to_string(),
            room: room.to_string(),
            wing: None,
            kind: None,
            sensitivity: None,
            exportability: None,
        }
    }
}

/// One `facts[]` element. `record_id` must name a record in the same file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeedFileFact {
    pub subject: String,
    pub predicate: String,
    pub object: String,
    pub record_id: String,
}

/// One `tunnels[]` element. None label omits the key (the importer generates
/// the default label).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeedFileTunnel {
    pub from: String,
    pub to: String,
    pub kind: String,
    pub label: Option<String>,
}

/// How a converted lane loads its seed: `Batch` (default) emits schema v1 +
/// one `moot_json_import`; `Live` is the retained slow lane (per-record
/// `moot_file_memory`) kept for periodic equivalence re-proving.
///
/// ANY PAYLOAD ABOVE ROUGHLY 25 RECORDS BELONGS ON `Batch`, with the import
/// called in background encode speed (`"mode": "background"`). One import
/// carries up to `ImportPolicy::BULK_WINDOW` — 125,000 rows — in a single
/// transaction, and it returns once the rows are written and the encode work
/// is enqueued; the corpus drain worker then fans that encode across the
/// machine. The live lane writes one record per call and waits for each, so it
/// costs N round trips where batch costs one. It exists to prove the two paths
/// agree, not to load anything sizeable.
///
/// The same rule governs how a batch is shaped: one import for the payload and
/// one drain at the end. Splitting a payload into chunks with a drain barrier
/// between them serializes exactly what the product parallelizes, and
/// republishes the resident vector index once per barrier. The timing lane's
/// landscape build did that and took six hours for 100,000 rows; as one
/// background import it takes minutes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeedPathMode {
    Live,
    Batch,
}

impl SeedPathMode {
    /// Parses a `--seed-path` CLI value; None input = default (`Batch`).
    /// Fail-closed on unknown values. Twin of `SeedPathMode.parse`.
    pub fn parse(raw: Option<&str>) -> Result<Self, String> {
        match raw {
            None => Ok(SeedPathMode::Batch),
            Some("live") => Ok(SeedPathMode::Live),
            Some("batch") => Ok(SeedPathMode::Batch),
            Some(other) => Err(format!(
                "--seed-path must be \"live\" or \"batch\"; got '{other}'"
            )),
        }
    }

    /// CLI / cache-key / provenance string form. Matches the Swift enum's
    /// rawValue and the `--seed-path` flag values.
    pub fn as_str(self) -> &'static str {
        match self {
            SeedPathMode::Live => "live",
            SeedPathMode::Batch => "batch",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Emitter
// ─────────────────────────────────────────────────────────────────────────────

/// Serializes one seed file (schema v1.1 / v1.2) deterministically. See the
/// module header for the byte-level format contract; the Swift twin is
/// `emitSeedJSON` and the shared conformance vectors pin both to the same
/// bytes.
///
/// Schema v1.1: `subject` always emitted (computed via
/// `subject_generator::deterministic_subject`). Schema v1.2: optional
/// `capture_date` emitted before `content` (ASCII: "capture_date" <
/// "content"); `format_version` stays 1. When every record's `capture_date`
/// is `None`, output is byte-identical to v1.1 — existing callers unaffected.
pub fn emit_seed_json(
    name: &str,
    records: &[SeedFileRecord],
    facts: &[SeedFileFact],
    tunnels: &[SeedFileTunnel],
) -> Vec<u8> {
    let mut out = String::with_capacity(records.len() * 200 + 256);

    // Key emission order is the ASCII sort of the keys actually present.
    // Top level: facts < format_version < name < records < tunnels.
    out.push_str("{\n");
    if !facts.is_empty() {
        out.push_str("  \"facts\": [\n");
        for (i, f) in facts.iter().enumerate() {
            out.push_str("    {\n");
            out.push_str(&format!("      \"object\": {},\n", json_string(&f.object)));
            out.push_str(&format!("      \"predicate\": {},\n", json_string(&f.predicate)));
            out.push_str(&format!("      \"record_id\": {},\n", json_string(&f.record_id)));
            out.push_str(&format!("      \"subject\": {}\n", json_string(&f.subject)));
            out.push_str(if i == facts.len() - 1 { "    }\n" } else { "    },\n" });
        }
        out.push_str("  ],\n");
    }
    out.push_str("  \"format_version\": 1,\n");
    out.push_str(&format!("  \"name\": {},\n", json_string(name)));
    if records.is_empty() {
        out.push_str("  \"records\": []");
    } else {
        out.push_str("  \"records\": [\n");
        for (i, r) in records.iter().enumerate() {
            out.push_str("    {\n");
            let mut lines: Vec<String> = Vec::new();
            // Schema v1.2: capture_date emitted before content (ASCII order).
            if let Some(v) = &r.capture_date {
                lines.push(format!("      \"capture_date\": {}", json_string(v)));
            }
            lines.push(format!("      \"content\": {}", json_string(&r.content)));
            lines.push(format!("      \"event_time\": {}", json_string(&r.event_time)));
            if let Some(v) = &r.exportability {
                lines.push(format!("      \"exportability\": {}", json_string(v)));
            }
            lines.push(format!("      \"id\": {}", json_string(&r.id)));
            if let Some(v) = &r.kind {
                lines.push(format!("      \"kind\": {}", json_string(v)));
            }
            lines.push(format!("      \"room\": {}", json_string(&r.room)));
            if let Some(v) = &r.sensitivity {
                lines.push(format!("      \"sensitivity\": {}", json_string(v)));
            }
            // Schema v1.1: subject always emitted (never optional). Computed
            // from content via deterministic_subject — identical to the live
            // arm's moot_file_memory `subject:` argument. Trimmed defensively
            // because prefix(120) can produce a trailing space when the cut
            // lands on whitespace; moot_json_import rejects subjects with
            // leading or trailing whitespace. Key order:
            // sensitivity < subject < wing (ASCII).
            lines.push(format!(
                "      \"subject\": {}",
                json_string(
                    &crate::subject_generator::deterministic_subject(&r.content)
                        .replace('\n', " ")
                        .replace('\r', " ")
                        .trim()
                        .to_string()
                )
            ));
            if let Some(v) = &r.wing {
                lines.push(format!("      \"wing\": {}", json_string(v)));
            }
            out.push_str(&lines.join(",\n"));
            out.push('\n');
            out.push_str(if i == records.len() - 1 { "    }\n" } else { "    },\n" });
        }
        out.push_str("  ]");
    }
    if !tunnels.is_empty() {
        out.push_str(",\n  \"tunnels\": [\n");
        for (i, t) in tunnels.iter().enumerate() {
            out.push_str("    {\n");
            let mut lines: Vec<String> = Vec::new();
            lines.push(format!("      \"from\": {}", json_string(&t.from)));
            lines.push(format!("      \"kind\": {}", json_string(&t.kind)));
            if let Some(v) = &t.label {
                lines.push(format!("      \"label\": {}", json_string(v)));
            }
            lines.push(format!("      \"to\": {}", json_string(&t.to)));
            out.push_str(&lines.join(",\n"));
            out.push('\n');
            out.push_str(if i == tunnels.len() - 1 { "    }\n" } else { "    },\n" });
        }
        out.push_str("  ]\n}");
    } else {
        out.push_str("\n}");
    }
    out.into_bytes()
}

/// JSON string literal with the cross-port escaping contract (module header).
pub fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Writes emitted seed bytes beside the scratch estate and returns the path
/// handed to `moot_json_import`.
///
/// Permissions are set to owner-only (0o600 on POSIX) at creation time so the
/// seed data is never world-readable during the import window.
pub fn write_seed_file(
    data: &[u8],
    scratch_dir: &std::path::Path,
    name: &str,
) -> Result<std::path::PathBuf, MCPError> {
    use std::io::Write;

    let path = scratch_dir.join(format!("{name}.seed.json"));
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    opts.open(&path)
        .and_then(|mut f| f.write_all(data))
        .map_err(|e| MCPError {
            description: format!("seed export: could not write {}: {e}", path.display()),
        })?;
    Ok(path)
}

// ─────────────────────────────────────────────────────────────────────────────
// Import id map extractor
// ─────────────────────────────────────────────────────────────────────────────

/// Reads the `{"id_map":{…}}` block that `moot_json_import` returns when called
/// with `return_id_map: true`, verifies it names a drawer for every seeded
/// record, and returns a `record_id → drawer_id` map.
///
/// This replaces post-hoc needle attribution. Attribution had to re-discover
/// each drawer by searching for its own content, which cannot be made exact: a
/// room of near-identical records can bury the row at any search limit, and a
/// room above the 200-row listing cap cannot be enumerated at all. The importer
/// already knows the answer — it mints the ids — so it is the only source that
/// can be both exact and total.
///
/// # Errors
///
/// Returns `MCPError` when:
/// - no text block parses as an id_map JSON object
/// - an id_map entry is not a string value
/// - the map size differs from `expecting` (partial manifest → refuse to score)
///
/// Twin of Swift `seedIDMap(fromImportBlocks:expecting:label:)` in `SeedExport.swift`.
pub fn seed_id_map(
    blocks: &[String],
    expecting: usize,
    label: &str,
) -> Result<std::collections::HashMap<String, String>, MCPError> {
    for block in blocks {
        let trimmed = block.trim();
        if !trimmed.starts_with('{') {
            continue;
        }
        let parsed = match JsonValue::from_slice(trimmed.as_bytes()) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let id_map_inner = match parsed.get("id_map") {
            Some(v) => v.clone(),
            None => continue,
        };
        let raw = match id_map_inner {
            JsonValue::Object(m) => m,
            _ => continue,
        };
        let mut map: std::collections::HashMap<String, String> =
            std::collections::HashMap::with_capacity(raw.len());
        for (record_id, value) in &raw {
            match value {
                JsonValue::String(s) => {
                    map.insert(record_id.clone(), s.clone());
                }
                _ => {
                    return Err(MCPError {
                        description: format!(
                            "{label}: import id map entry \"{record_id}\" is not a string"
                        ),
                    });
                }
            }
        }
        if map.len() != expecting {
            return Err(MCPError {
                description: format!(
                    "{label}: import id map names {} drawer(s) for \
                     {expecting} seeded record(s) — refusing to score with an \
                     incomplete manifest",
                    map.len()
                ),
            });
        }
        return Ok(map);
    }
    Err(MCPError {
        description: format!(
            "{label}: moot_json_import returned no id_map block — the run asked \
             for return_id_map; a server that does not send it cannot be scored"
        ),
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic event-time generator
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a deterministic ISO 8601 UTC timestamp at second precision for a
/// given `offset_seconds` from the fixed base `2026-01-01T00:00:00Z`.
///
/// Used by batch seeding lanes (LME, LMEB) to stamp records with unique,
/// reproducible event times when the source corpus carries no real timestamps.
/// Each record receives +1 s relative to the previous, so the room list
/// returned by `moot_memory_list` is ingest-ordered and needle attribution
/// resolves unambiguously.
///
/// Twin of `syntheticEventTime(offsetSeconds:)` in `SeedExport.swift`.
pub fn synthetic_event_time(offset_seconds: usize) -> String {
    let mut rem = offset_seconds;
    let s = rem % 60;
    rem /= 60;
    let m = rem % 60;
    rem /= 60;
    let h = rem % 24;
    rem /= 24;
    // rem is now whole days elapsed from 2026-01-01.
    let mut year: u32 = 2026;
    let mut month: u32 = 1;
    let mut day: u32 = 1 + rem as u32;

    let is_leap = |y: u32| -> bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) };
    let days_in_month = |mn: u32, yr: u32| -> u32 {
        match mn {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 => if is_leap(yr) { 29 } else { 28 },
            _ => unreachable!("month out of range"),
        }
    };
    loop {
        let dim = days_in_month(month, year);
        if day <= dim {
            break;
        }
        day -= dim;
        month += 1;
        if month > 12 {
            month = 1;
            year += 1;
        }
    }
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

// ─────────────────────────────────────────────────────────────────────────────
// moot_memory_get content extraction
// ─────────────────────────────────────────────────────────────────────────────

/// Lines returned by `moot_memory_get` that are server chrome and must not
/// defeat verbatim content comparisons.
const MEMORY_GET_TRAILING_ADVISORY_PREFIXES: [&str; 2] =
    ["sensitivity_advisory:", "hint:"];

/// Extracts the verbatim content block from a `moot_memory_get` reply:
/// every line after the first `content:` line up to (excluding) any
/// trailing advisory lines, joined with LF. Consumed by `lme_spec_runner`
/// when hydrating answer memories; the Swift harness has no counterpart.
pub fn memory_get_content(text_blocks: &[String]) -> Option<String> {
    let text = text_blocks.join("\n");
    let mut lines: Vec<&str> = text.split('\n').collect();
    let idx = lines
        .iter()
        .position(|l| *l == "content:" || l.starts_with("content:"))?;
    // The Moot Modes coaching block (appended every Nth call per
    // ModesManifest.coaching_calls) is MULTI-LINE and only its FIRST line
    // carries the `hint:` prefix — the prefix-run stripper below cannot
    // remove its unprefixed continuation lines. The block header is
    // distinctive ("hint: [Moot coaching"); everything from the LAST such
    // header to the end is chrome. Truncate it before the prefix-run pass
    // so a coaching block landing on a get reply is never mistaken for
    // drawer content.
    if let Some(coaching_idx) = lines
        .iter()
        .rposition(|l| l.starts_with("hint: [Moot coaching"))
    {
        if coaching_idx > idx {
            lines.truncate(coaching_idx);
        }
    }
    // Drop trailing advisory chrome. Only a TRAILING run is stripped —
    // an advisory-looking line in the middle of real content survives.
    while let Some(last) = lines.last() {
        if MEMORY_GET_TRAILING_ADVISORY_PREFIXES
            .iter()
            .any(|p| last.starts_with(p))
        {
            lines.pop();
        } else {
            break;
        }
    }
    let first = lines[idx];
    if first == "content:" {
        return Some(lines[idx + 1..].join("\n"));
    }
    let inline = first["content:".len()..].trim().to_string();
    let rest = &lines[idx + 1..];
    if rest.is_empty() {
        Some(inline)
    } else {
        let mut parts = vec![inline];
        parts.extend(rest.iter().map(|s| s.to_string()));
        Some(parts.join("\n"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn emission_is_byte_deterministic() {
        let records = vec![SeedFileRecord::new(
            "r1", "Only one sentence.", "2026-01-01T00:00:00Z", "bench/room",
        )];
        let a = emit_seed_json("det", &records, &[], &[]);
        let b = emit_seed_json("det", &records, &[], &[]);
        assert_eq!(a, b);
    }

    #[test]
    fn keys_sorted_and_optionals_omitted() {
        let records = vec![SeedFileRecord::new(
            "r1", "c", "2026-01-01T00:00:00Z", "room",
        )];
        let text = String::from_utf8(emit_seed_json("keys", &records, &[], &[])).unwrap();
        let fv = text.find("\"format_version\"").unwrap();
        let nm = text.find("\"name\"").unwrap();
        let rc = text.find("\"records\"").unwrap();
        assert!(fv < nm && nm < rc);
        assert!(!text.contains("\"facts\""));
        assert!(!text.contains("\"tunnels\""));
        assert!(!text.contains("\"wing\""));
        assert!(!text.contains("\"kind\""));
    }

    #[test]
    fn escaping_matches_contract() {
        let records = vec![SeedFileRecord::new(
            "esc",
            "quote:\" backslash:\\ newline:\n tab:\t cr:\r unit:\u{1f}",
            "2026-01-01T00:00:00Z",
            "esc",
        )];
        let text = String::from_utf8(emit_seed_json("esc", &records, &[], &[])).unwrap();
        assert!(text.contains(r#"quote:\" backslash:\\ newline:\n tab:\t cr:\r unit:\u001f"#));
        // Round-trips through a strict JSON parser back to the exact content.
        let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(
            parsed["records"][0]["content"].as_str().unwrap(),
            "quote:\" backslash:\\ newline:\n tab:\t cr:\r unit:\u{1f}"
        );
    }

    #[test]
    fn facts_and_tunnels_emit_when_present() {
        let records = vec![
            SeedFileRecord::new("r1", "a", "2026-01-01T00:00:00Z", "room"),
            SeedFileRecord::new("r2", "b", "2026-01-02T00:00:00Z", "room"),
        ];
        let facts = vec![SeedFileFact {
            subject: "s".into(), predicate: "p".into(), object: "o".into(),
            record_id: "r1".into(),
        }];
        let tunnels = vec![SeedFileTunnel {
            from: "r1".into(), to: "r2".into(), kind: "supersedes".into(), label: None,
        }];
        let text =
            String::from_utf8(emit_seed_json("rel", &records, &facts, &tunnels)).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(parsed["facts"][0]["record_id"], "r1");
        assert_eq!(parsed["tunnels"][0]["kind"], "supersedes");
        assert!(parsed["tunnels"][0].get("label").is_none());
    }

    #[derive(Deserialize)]
    struct VectorRecord {
        id: String,
        content: String,
        event_time: String,
        room: String,
        wing: Option<String>,
        kind: Option<String>,
        sensitivity: Option<String>,
        exportability: Option<String>,
    }

    #[derive(Deserialize)]
    struct VectorCase {
        id: String,
        name: String,
        records: Vec<VectorRecord>,
        expected_json: String,
    }

    #[derive(Deserialize)]
    struct VectorFile {
        cases: Vec<VectorCase>,
    }

    /// `benchmarks/conformance/` from the crate root (benchmarks/rust/).
    fn conformance_path(filename: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("benchmark dir")
            .join("conformance")
            .join(filename)
    }

    #[test]
    fn conformance_vectors_match_byte_for_byte() {
        let path = conformance_path("seed_export_vectors.json");
        let data = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        let file: VectorFile = serde_json::from_str(&data)
            .unwrap_or_else(|e| panic!("cannot parse seed_export_vectors.json: {e}"));
        assert!(!file.cases.is_empty());
        for case in &file.cases {
            let records: Vec<SeedFileRecord> = case
                .records
                .iter()
                .map(|r| SeedFileRecord {
                    id: r.id.clone(),
                    content: r.content.clone(),
                    // Schema v1.2: capture_date is not part of the conformance
                    // vector suite (vectors pin schema v1.1 behaviour). Default
                    // to None so existing cases remain unaffected.
                    capture_date: None,
                    event_time: r.event_time.clone(),
                    room: r.room.clone(),
                    wing: r.wing.clone(),
                    kind: r.kind.clone(),
                    sensitivity: r.sensitivity.clone(),
                    exportability: r.exportability.clone(),
                })
                .collect();
            let got = String::from_utf8(emit_seed_json(&case.name, &records, &[], &[]))
                .unwrap();
            assert_eq!(got, case.expected_json, "vector case '{}' drifted", case.id);
        }
    }

    #[test]
    fn seed_path_mode_parses_fail_closed() {
        assert_eq!(SeedPathMode::parse(None).unwrap(), SeedPathMode::Batch);
        assert_eq!(SeedPathMode::parse(Some("live")).unwrap(), SeedPathMode::Live);
        assert_eq!(SeedPathMode::parse(Some("batch")).unwrap(), SeedPathMode::Batch);
        assert!(SeedPathMode::parse(Some("bulk")).is_err());
    }

    #[test]
    fn trailing_advisory_chrome_is_stripped() {
        // Observed live: a sensitivity-tier gate appends its advisory AFTER
        // the content block; it is server chrome, not drawer content.
        let reply = "memory 11111111-1111-1111-1111-111111111111\n\
                     room: supersession/city  wing: Agentic Memory\n\
                     content:\n\
                     Sarah Chen C1 lives in Nairobi.\n\
                     sensitivity_advisory: a sensitivity tier gate is in effect."
            .to_string();
        assert_eq!(
            memory_get_content(&[reply]).unwrap(),
            "Sarah Chen C1 lives in Nairobi."
        );
    }

    #[test]
    fn mid_content_advisory_survives() {
        let reply = "content:\n\
                     first line\n\
                     hint: this is real content, not chrome\n\
                     last line"
            .to_string();
        assert_eq!(
            memory_get_content(&[reply]).unwrap(),
            "first line\nhint: this is real content, not chrome\nlast line"
        );
    }

    #[test]
    fn memory_get_content_reads_verbatim_block() {
        let reply = "memory 11111111-1111-1111-1111-111111111111\n\
                     room: supersession/color  wing: Agentic Memory\n\
                     filed_at: 2026-08-09T00:00:00Z\n\
                     content:\n\
                     Line one.\n\
                     Line two."
            .to_string();
        assert_eq!(
            memory_get_content(&[reply]).unwrap(),
            "Line one.\nLine two."
        );
    }

    /// The multi-line Moot coaching block (only its FIRST line hint:-prefixed)
    /// must be truncated, or the hydrated content carries server chrome —
    /// exactly as observed live in the verify-artifacts replay (2026-08-23).
    #[test]
    fn memory_get_content_truncates_coaching_block() {
        let reply = [
            "content:",
            "Tomas Haddad C8 works at Halcyon Labs.",
            "sensitivity_advisory: a sensitivity tier gate is in effect on this estate.",
            "hint: [Moot coaching · call 25]",
            "Good session — 25 calls across 2 tools. I bet moot_estate_status teaches you a tool you haven't tried yet.",
            "Modes available: Recall (100%), Filing (unused), Lenses (unused).",
        ]
        .join("\n");
        assert_eq!(
            memory_get_content(&[reply]).unwrap(),
            "Tomas Haddad C8 works at Halcyon Labs."
        );
    }

    // ── BM-01 regressions ────────────────────────────────────────────────────

    /// Finding 2: seed files must not be world-readable while a run is in
    /// progress. write_seed_file must always set 0o600 at creation time.
    ///
    /// Unix-only: on non-Unix targets the permission bits are not meaningful,
    /// so the assertion is gated on `#[cfg(unix)]`.
    #[test]
    fn write_seed_file_creates_with_owner_only_permissions() {
        let dir = std::env::temp_dir()
            .join(format!("bm01-perm-{}-owner", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let records = vec![SeedFileRecord::new(
            "r1", "content", "2026-01-01T00:00:00Z", "room",
        )];
        let data = emit_seed_json("perm-test", &records, &[], &[]);
        let path = write_seed_file(&data, &dir, "perm-test-seed").unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(
                mode & 0o777, 0o600,
                "seed file must be owner-only (0o600); got 0o{:o}",
                mode & 0o777
            );
        }

        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Finding 1: membench item IDs like "FirstAgent/simple/roles/0" must be
    /// sanitized to "FirstAgent_simple_roles_0" before being passed to
    /// write_seed_file. This test confirms the sanitized name produces a file
    /// that lands directly in scratch_dir with no path-separator in its name.
    #[test]
    fn write_seed_file_sanitized_name_stays_flat_in_scratch_dir() {
        let dir = std::env::temp_dir()
            .join(format!("bm01-slash-{}-flat", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let records = vec![SeedFileRecord::new("r1", "c", "2026-01-01T00:00:00Z", "room")];
        let data = emit_seed_json("flat", &records, &[], &[]);

        // The sanitized form of "FirstAgent/simple/roles/0":
        let safe_name = "membench-FirstAgent_simple_roles_0";
        let path = write_seed_file(&data, &dir, safe_name).unwrap();

        // File must land directly in dir (one path component below).
        assert_eq!(
            path.parent().unwrap().canonicalize().unwrap(),
            dir.canonicalize().unwrap(),
            "write_seed_file must produce a flat file directly in scratch_dir"
        );
        // No slash must appear in the filename itself.
        assert!(
            !path.file_name().unwrap().to_str().unwrap().contains('/'),
            "sanitized filename must not contain path separators"
        );
        assert!(
            path.file_name().unwrap().to_str().unwrap()
                .contains("FirstAgent_simple_roles_0"),
            "underscores must replace slashes in the filename component"
        );

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
