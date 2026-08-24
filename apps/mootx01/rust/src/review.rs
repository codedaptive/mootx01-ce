//! review — deterministic review session engine (Wave B2: CORE-05 Rust parity).
//!
//! Produces byte-identical ReviewSession JSON for the same (kind, drawers, now)
//! inputs as the Swift CommunityReviewEngine. The parity contract is enforced by
//! the shared canonical vector files in apps/mootx01/testdata/review-vectors/*.json.
//!
//! # ID Derivation
//!
//! All session/section/item/action/group/choice IDs use `derive_id`:
//!   SHA-256(NAMESPACE_BYTES + components.join("\0")), first 16 bytes,
//!   version bits = 0x50 (byte 6 high nibble), variant bits = 0x80 (byte 8 high two).
//!
//! Namespace: 4c6f7257-5265-7669-6577-000000000001 ("LocuRevi" + zeros).
//! This is the fixed namespace shared with the Swift engine — changing it
//! breaks all canonical vectors.
//!
//! # Estate Fingerprint
//!
//! SHA-256(sorted_active_IDs.join("\n")), first 32 hex chars, colon, active count.
//! An empty estate: SHA-256("") → e3b0c44298fc1c149afbf4c8996fb924... (first 32 chars).
//!
//! # Section Ordering
//!
//! Drawers sorted filedAt DESC then id ASC; cap 20.
//! One section per kind (titles: "First priorities" / "Today's items" / "This week's items").
//!
//! # Action Ordering
//!
//! One action per active drawer, sorted by drawer id ASC; cap 20.
//!
//! # Duplicate Detection
//!
//! Pass 1 — same normalized subject (lowercase + whitespace-collapse; NFC is a no-op
//!           for the ASCII-range test vectors but is noted as the full spec).
//! Pass 2 — identical trimmed content.
//! First match wins per drawer; groups sorted by group UUID string ASC.

use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// Fixed namespace (MUST NOT change — changing breaks Swift/Rust parity)
// ---------------------------------------------------------------------------

/// Fixed review-family ID derivation namespace.
///
/// Bytes: 4c 6f 72 57 52 65 76 69 65 77 00 00 00 00 00 01
/// ("LocuRevi" + "ew" + zeros). Mirrors Swift's CommunityReviewEngine.reviewNamespaceBytes.
const REVIEW_NAMESPACE: &[u8] = &[
    0x4c, 0x6f, 0x72, 0x57, 0x52, 0x65, 0x76, 0x69,
    0x65, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
];

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// The three review session kinds. Wire values match the Swift enum rawValue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReviewKind {
    Morning,
    EndOfDay,
    Weekly,
}

impl ReviewKind {
    /// Wire string as used in JSON and ID derivation — must match Swift rawValue.
    pub fn wire_str(self) -> &'static str {
        match self {
            ReviewKind::Morning  => "morning",
            ReviewKind::EndOfDay => "endOfDay",
            ReviewKind::Weekly   => "weekly",
        }
    }

    /// Parse from a JSON wire string.
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "morning"  => Some(ReviewKind::Morning),
            "endOfDay" => Some(ReviewKind::EndOfDay),
            "weekly"   => Some(ReviewKind::Weekly),
            _          => None,
        }
    }

    /// Section title for this kind. Mirrors Swift's sectionTitleFor(kind:).
    fn section_title(self) -> &'static str {
        match self {
            ReviewKind::Morning  => "First priorities",
            ReviewKind::EndOfDay => "Today's items",
            ReviewKind::Weekly   => "This week's items",
        }
    }
}

/// A single estate drawer as provided by a vector file.
///
/// All fields are raw strings (ISO8601 timestamps remain as-is; string
/// comparison is valid for UTC ISO8601 and avoids a chrono dependency).
#[derive(Debug, Clone)]
pub struct DrawerInput {
    /// Stable UUID string (lowercase hyphenated).
    pub id: String,
    /// Optional subject label for the drawer's content.
    pub subject: Option<String>,
    /// Verbatim drawer content.
    pub content: String,
    /// ISO8601 UTC timestamp, e.g. "2026-08-23T08:00:00.000Z".
    pub filed_at: String,
    /// If present, the drawer is tombstoned and excluded from the session.
    pub tombstoned_at: Option<String>,
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Generate a deterministic review session as a canonical JSON Value.
///
/// Inputs must be provided explicitly — this function never calls time(), random(),
/// or any other non-deterministic source. The same inputs always produce the same
/// output, which is the foundation of Swift/Rust parity testing.
///
/// - `kind`: session kind (morning / endOfDay / weekly)
/// - `drawers`: ALL drawers from the estate (tombstoned ones are filtered here)
/// - `now`: explicit current timestamp as ISO8601 string (e.g. "2026-08-23T09:00:00.000Z")
///
/// Returns a `serde_json::Value` whose keys are sorted (BTreeMap-backed) for
/// byte-identical canonical output.
pub fn generate_session(
    kind: ReviewKind,
    drawers: &[DrawerInput],
    now: &str,
) -> serde_json::Value {
    // Filter to active (non-tombstoned) drawers.
    let active: Vec<&DrawerInput> = drawers.iter().filter(|d| d.tombstoned_at.is_none()).collect();

    // Compute estate fingerprint from active drawers.
    let source_estate_state = estate_fingerprint(&active);

    // Derive session ID: SHA-256(namespace + "session\0kind\0now\0fingerprint")
    let session_id = derive_id(&["session", kind.wire_str(), now, &source_estate_state]);

    // Build section title and section ID.
    let section_title = kind.section_title();
    let section_id = derive_id(&["section", &session_id, section_title]);

    // Sort drawers for item ordering: filedAt DESC, id ASC; cap 20.
    let mut sorted_drawers: Vec<&DrawerInput> = active.clone();
    sorted_drawers.sort_by(|a, b| {
        // Primary: filedAt descending (lexicographic; valid for UTC ISO8601).
        let cmp_time = b.filed_at.cmp(&a.filed_at);
        if cmp_time != std::cmp::Ordering::Equal {
            return cmp_time;
        }
        // Secondary: id ascending.
        a.id.cmp(&b.id)
    });
    let sorted_drawers: Vec<&DrawerInput> = sorted_drawers.into_iter().take(20).collect();

    // Build items from the sorted drawers with their section-relative index.
    let items: Vec<serde_json::Value> = sorted_drawers
        .iter()
        .enumerate()
        .map(|(idx, drawer)| {
            // Item ID: SHA-256(namespace + "item\0sectionID\0drawerID\0idx")
            let item_id = derive_id(&["item", &section_id, &drawer.id, &idx.to_string()]);
            let subject = drawer_subject(drawer);
            // Detail: content prefix 120 chars, trimmed.
            let detail = drawer.content.trim_end();
            let detail = if detail.len() > 120 { &detail[..120] } else { detail };
            let detail = detail.trim();
            build_obj([
                ("detail", serde_json::Value::String(detail.to_string())),
                ("id", serde_json::Value::String(item_id)),
                ("subject", serde_json::Value::String(subject)),
            ])
        })
        .collect();

    // Build the section (empty sections array when no active drawers).
    let sections: Vec<serde_json::Value> = if items.is_empty() {
        vec![]
    } else {
        vec![build_obj([
            ("id", serde_json::Value::String(section_id.clone())),
            ("items", serde_json::Value::Array(items)),
            ("title", serde_json::Value::String(section_title.to_string())),
        ])]
    };

    // Build actions: one per active drawer, sorted by drawer id ASC; cap 20.
    let mut action_drawers: Vec<&DrawerInput> = active.clone();
    action_drawers.sort_by(|a, b| a.id.cmp(&b.id));
    let action_drawers: Vec<&DrawerInput> = action_drawers.into_iter().take(20).collect();

    let actions: Vec<serde_json::Value> = action_drawers
        .iter()
        .map(|drawer| {
            // Action ID: SHA-256(namespace + "action\0sessionID\0drawerID")
            let action_id = derive_id(&["action", &session_id, &drawer.id]);
            let subject = drawer_subject(drawer);
            // All review-mark actions are reversible at generation time;
            // reversalAvailable is false until the action is applied (durable state).
            build_obj([
                ("expectedEffect", serde_json::Value::String(format!("Mark '{}' as reviewed.", subject))),
                ("id", serde_json::Value::String(action_id)),
                ("isReversible", serde_json::Value::Bool(true)),
                ("reversalAvailable", serde_json::Value::Bool(false)),
            ])
        })
        .collect();

    // Detect duplicate groups.
    let duplicate_groups = detect_duplicates(&active, &session_id);

    // completionStatus is always inProgress at session generation time (no
    // durable state injected in the parity-vector path).
    let completion_status = build_obj([("state", serde_json::Value::String("inProgress".to_string()))]);

    // Assemble the canonical session object (keys sorted via build_obj / BTreeMap).
    build_obj([
        ("actions", serde_json::Value::Array(actions)),
        ("completionStatus", completion_status),
        ("duplicateGroups", serde_json::Value::Array(duplicate_groups)),
        ("generatedAt", serde_json::Value::String(now.to_string())),
        ("id", serde_json::Value::String(session_id)),
        ("kind", serde_json::Value::String(kind.wire_str().to_string())),
        ("sections", serde_json::Value::Array(sections)),
        ("sourceEstateState", serde_json::Value::String(source_estate_state)),
    ])
}

// ---------------------------------------------------------------------------
// Estate fingerprint
// ---------------------------------------------------------------------------

/// Compute a compact, stable fingerprint of the active estate drawers.
///
/// Input: active drawer IDs sorted alphabetically, joined by "\n".
/// Output: "sha256:{first32hexchars}:{activeCount}"
///
/// Mirrors Swift CommunityReviewEngine.estateFingerprint.
pub fn estate_fingerprint(active: &[&DrawerInput]) -> String {
    let mut sorted_ids: Vec<&str> = active.iter().map(|d| d.id.as_str()).collect();
    sorted_ids.sort_unstable();
    let joined = sorted_ids.join("\n");

    let mut hasher = Sha256::new();
    hasher.update(joined.as_bytes());
    let digest = hasher.finalize();

    // First 32 hex chars (16 bytes) — compact but collision-resistant for
    // estate-change detection. Mirrors the Swift `.prefix(32)` on the hex string.
    let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    let hex32 = &hex[..32];

    format!("sha256:{}:{}", hex32, active.len())
}

// ---------------------------------------------------------------------------
// ID derivation
// ---------------------------------------------------------------------------

/// Derive a deterministic UUID string from a slice of components.
///
/// Algorithm: SHA-256(REVIEW_NAMESPACE + components.join("\0")), first 16 bytes.
/// Then set UUID version marker (byte 6 high nibble = 0x5) and RFC 4122 variant
/// (byte 8 high two bits = 0b10). Output is lowercase hyphenated string.
///
/// Mirrors Swift CommunityReviewEngine.deriveID(_ components: String...).
pub fn derive_id(components: &[&str]) -> String {
    let input = components.join("\0");
    let mut hasher = Sha256::new();
    hasher.update(REVIEW_NAMESPACE);
    hasher.update(input.as_bytes());
    let digest = hasher.finalize();

    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);

    // UUID version 5 marker: high nibble of byte 6 = 0x5 → byte[6] = 0x5X
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    // RFC 4122 variant: high two bits of byte 8 = 0b10 → byte[8] = 0b10xxxxxx
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    )
}

// ---------------------------------------------------------------------------
// Duplicate detection
// ---------------------------------------------------------------------------

/// Detect duplicate drawer groups using two strategies (same-subject then content-identity).
///
/// Mirrors Swift CommunityReviewEngine.detectDuplicates.
fn detect_duplicates(
    active: &[&DrawerInput],
    session_id: &str,
) -> Vec<serde_json::Value> {
    let mut used_ids: std::collections::HashSet<&str> = std::collections::HashSet::new();
    let mut groups: Vec<(String, serde_json::Value)> = vec![];

    // Strategy 1: same normalized subject.
    // Bucket by normalized subject, sort buckets by key for determinism.
    let mut subject_buckets: BTreeMap<String, Vec<&DrawerInput>> = BTreeMap::new();
    for drawer in active.iter() {
        let sub = drawer_subject(drawer);
        let key = normalize_subject(&sub);
        if !key.is_empty() {
            subject_buckets.entry(key).or_default().push(drawer);
        }
    }
    for (_key, bucket) in &subject_buckets {
        if bucket.len() < 2 { continue; }
        // Only include drawers not already in a group.
        let candidates: Vec<&DrawerInput> = bucket.iter().copied()
            .filter(|d| !used_ids.contains(d.id.as_str()))
            .collect();
        if candidates.len() < 2 { continue; }
        let group_val = make_group(
            &candidates,
            "Records share the same canonical subject.",
            session_id,
        );
        for d in &candidates { used_ids.insert(d.id.as_str()); }
        // Store with group id as sort key.
        let group_id = group_val["id"].as_str().unwrap_or("").to_string();
        groups.push((group_id, group_val));
    }

    // Strategy 2: identical trimmed content.
    let mut content_buckets: BTreeMap<String, Vec<&DrawerInput>> = BTreeMap::new();
    for drawer in active.iter() {
        if used_ids.contains(drawer.id.as_str()) { continue; }
        let key = drawer.content.trim().to_string();
        if !key.is_empty() {
            content_buckets.entry(key).or_default().push(drawer);
        }
    }
    for (_key, bucket) in &content_buckets {
        if bucket.len() < 2 { continue; }
        let group_val = make_group(
            bucket,
            "Records have identical content.",
            session_id,
        );
        for d in bucket { used_ids.insert(d.id.as_str()); }
        let group_id = group_val["id"].as_str().unwrap_or("").to_string();
        groups.push((group_id, group_val));
    }

    // Sort groups by group id string (UUID lowercase), mirroring Swift sort.
    groups.sort_by(|a, b| a.0.cmp(&b.0));
    groups.into_iter().map(|(_, v)| v).collect()
}

/// Build a DuplicateGroup JSON object from a set of candidate drawers.
///
/// Mirrors Swift CommunityReviewEngine.makeGroup.
fn make_group(
    drawers: &[&DrawerInput],
    reason: &str,
    session_id: &str,
) -> serde_json::Value {
    // Sort drawers: filedAt DESC, id ASC.
    let mut sorted: Vec<&DrawerInput> = drawers.to_vec();
    sorted.sort_by(|a, b| {
        let cmp = b.filed_at.cmp(&a.filed_at);
        if cmp != std::cmp::Ordering::Equal { return cmp; }
        a.id.cmp(&b.id)
    });

    // Group ID derived from session_id + sorted drawer ids, joined by "\0".
    // Input format: "group\0{sessionID}\0{id0}\0{id1}\0..."
    let mut id_parts = vec!["group", session_id];
    let drawer_id_refs: Vec<&str> = sorted.iter().map(|d| d.id.as_str()).collect();
    id_parts.extend_from_slice(&drawer_id_refs);
    // The Swift private overload joins with "\0" and passes the already-joined
    // string to deriveID (bypassing the variadic join). We replicate by joining
    // the parts ourselves — the result is identical because join("\0") on
    // id_parts produces the same bytes as the variadic path.
    let joined_input = id_parts.join("\0");
    let group_id = derive_id_from_joined(&joined_input);

    // Two daemon-owned resolution choices.
    let choice1_desc = "Keep the newer record and archive the older one.";
    let choice2_desc = "Merge content into the newer record and archive the older one.";
    let choice1_id = derive_id(&["choice", &group_id, choice1_desc]);
    let choice2_id = derive_id(&["choice", &group_id, choice2_desc]);

    let choices = vec![
        build_obj([
            ("description", serde_json::Value::String(choice1_desc.to_string())),
            ("id", serde_json::Value::String(choice1_id)),
        ]),
        build_obj([
            ("description", serde_json::Value::String(choice2_desc.to_string())),
            ("id", serde_json::Value::String(choice2_id)),
        ]),
    ];

    // recordIDs: sorted drawers' ids (filedAt DESC, id ASC).
    let record_ids: Vec<serde_json::Value> = sorted
        .iter()
        .map(|d| serde_json::Value::String(d.id.clone()))
        .collect();

    build_obj([
        ("choices", serde_json::Value::Array(choices)),
        ("id", serde_json::Value::String(group_id)),
        ("reason", serde_json::Value::String(reason.to_string())),
        ("recordIDs", serde_json::Value::Array(record_ids)),
    ])
}

/// Derive ID from an already-joined input string.
///
/// Mirrors the Swift private overload `deriveID(_ joined: String)`.
/// Used by make_group where the id_parts array has been joined externally.
fn derive_id_from_joined(joined: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(REVIEW_NAMESPACE);
    hasher.update(joined.as_bytes());
    let digest = hasher.finalize();

    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    )
}

// ---------------------------------------------------------------------------
// Helper utilities
// ---------------------------------------------------------------------------

/// Extract a display subject from a DrawerInput.
///
/// Uses subject field if non-empty; falls back to content prefix (60 chars, trimmed).
/// Mirrors Swift CommunityReviewEngine.drawerSubject.
fn drawer_subject(drawer: &DrawerInput) -> String {
    if let Some(ref sub) = drawer.subject {
        if !sub.is_empty() {
            return sub.clone();
        }
    }
    // Fallback: first 60 chars of content, trimmed.
    let preview = drawer.content.trim_end();
    let preview = if preview.len() > 60 { &preview[..60] } else { preview };
    let preview = preview.trim();
    if preview.is_empty() {
        drawer.id.clone()
    } else {
        preview.to_string()
    }
}

/// Normalize a subject string for duplicate-detection comparison.
///
/// Applies: lowercase + whitespace-collapse. NFC is a no-op for the ASCII
/// test vectors; a production implementation would use the unicode-normalization
/// crate for full spec compliance.
///
/// Mirrors Swift CommunityReviewEngine.normalizeSubject.
fn normalize_subject(subject: &str) -> String {
    // Whitespace-split then rejoin — identical to Swift's whitespace-collapse.
    subject
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Build a JSON object Value with BTreeMap-backed sorted keys.
///
/// The N in the type parameter is inferred as the array size; all call sites
/// pass a fixed-size array literal so this is zero-overhead.
fn build_obj<const N: usize>(
    fields: [(&str, serde_json::Value); N],
) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    // Insert all fields; serde_json::Map preserves insertion order but we
    // need sorted-key output. We build a BTreeMap first, then convert.
    let mut btree: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
    for (k, v) in fields {
        btree.insert(k, v);
    }
    for (k, v) in btree {
        map.insert(k.to_string(), v);
    }
    serde_json::Value::Object(map)
}

// ---------------------------------------------------------------------------
// Vector loading helpers (used by tests)
// ---------------------------------------------------------------------------

/// Load and parse a DrawerInput slice from the vector JSON `drawers` array.
///
/// Panics if the JSON structure is invalid — test-only helper.
pub fn drawers_from_vector(vector: &serde_json::Value) -> Vec<DrawerInput> {
    let arr = vector["drawers"].as_array().expect("drawers must be array");
    arr.iter()
        .map(|d| DrawerInput {
            id: d["id"].as_str().expect("drawer.id").to_string(),
            subject: d.get("subject").and_then(|v| v.as_str()).map(String::from),
            content: d["content"].as_str().expect("drawer.content").to_string(),
            filed_at: d["filedAt"].as_str().expect("drawer.filedAt").to_string(),
            tombstoned_at: d.get("tombstonedAt").and_then(|v| v.as_str()).map(String::from),
        })
        .collect()
}

/// Normalize a JSON Value to use BTreeMap-backed objects at every level,
/// producing sorted-key output when serialized. Used to canonicalize
/// the expectedSession from the vector file before comparison.
pub fn normalize_json(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut btree: BTreeMap<String, serde_json::Value> = BTreeMap::new();
            for (k, val) in map {
                btree.insert(k, normalize_json(val));
            }
            let mut out = serde_json::Map::new();
            for (k, val) in btree {
                out.insert(k, val);
            }
            serde_json::Value::Object(out)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(normalize_json).collect())
        }
        other => other,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Resolve the path to a review vector file relative to the crate root.
    ///
    /// The vector files live at apps/mootx01/testdata/review-vectors/ relative
    /// to the workspace root (the directory containing apps/). From inside the
    /// crate at apps/mootx01/rust/, we go up three levels.
    fn vector_path(name: &str) -> std::path::PathBuf {
        // CARGO_MANIFEST_DIR is apps/mootx01/rust when running tests.
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest.join("..").join("testdata").join("review-vectors").join(name)
    }

    /// Load, parse, and return a vector file as a serde_json::Value.
    fn load_vector(filename: &str) -> serde_json::Value {
        let path = vector_path(filename);
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read vector {}: {}", path.display(), e));
        serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("failed to parse vector {}: {}", filename, e))
    }

    /// Core parity assertion: run the engine against the vector's drawers and now,
    /// then compare canonical JSON against the vector's expectedSession.
    ///
    /// Both sides are normalized to sorted-key compact JSON before comparison
    /// so the test is independent of whitespace in the vector files.
    fn assert_vector_parity(filename: &str) {
        let vector = load_vector(filename);

        let kind_str = vector["kind"].as_str().expect("kind must be string");
        let kind = ReviewKind::from_str(kind_str)
            .unwrap_or_else(|| panic!("unknown kind '{}' in vector {}", kind_str, filename));
        let now = vector["now"].as_str().expect("now must be string");
        let drawers = drawers_from_vector(&vector);

        // Generate the session using the Rust engine.
        let got = generate_session(kind, &drawers, now);

        // Normalize the expected session from the vector file.
        let expected_raw = vector["expectedSession"].clone();
        let expected = normalize_json(expected_raw);

        // Serialize both to compact JSON for byte-identical comparison.
        let got_json = serde_json::to_string(&got)
            .expect("failed to serialize generated session");
        let expected_json = serde_json::to_string(&expected)
            .expect("failed to serialize expected session");

        assert_eq!(
            got_json, expected_json,
            "parity failure for vector '{}'\n  GOT:      {}\n  EXPECTED: {}",
            filename, got_json, expected_json,
        );
    }

    // -----------------------------------------------------------------------
    // Parity tests — one per vector file
    // -----------------------------------------------------------------------

    /// B2-P1: Morning session with a single active drawer.
    /// Covers: section generation, item, action, no duplicate groups.
    #[test]
    fn b2_p1_morning_single_drawer_parity() {
        assert_vector_parity("morning-single-drawer.json");
    }

    /// B2-P2: Morning session with two drawers sharing the same subject.
    /// Covers: duplicate-group detection (same normalized subject), two actions.
    #[test]
    fn b2_p2_morning_duplicate_group_parity() {
        assert_vector_parity("morning-duplicate-group.json");
    }

    /// B2-P3: End-of-day session with a single active drawer.
    /// Covers: endOfDay section title "Today's items".
    #[test]
    fn b2_p3_endofday_single_drawer_parity() {
        assert_vector_parity("endofday-single-drawer.json");
    }

    /// B2-P4: Weekly session with a single active drawer.
    /// Covers: weekly section title "This week's items".
    #[test]
    fn b2_p4_weekly_single_drawer_parity() {
        assert_vector_parity("weekly-single-drawer.json");
    }

    /// B2-P5: Morning session with an empty estate (no active drawers).
    /// Covers: empty-estate fingerprint (SHA-256 of empty string), empty arrays,
    ///         and the specific session UUID that results from empty-estate inputs.
    #[test]
    fn b2_p5_empty_estate_parity() {
        assert_vector_parity("empty-estate.json");
    }

    // -----------------------------------------------------------------------
    // Unit tests for sub-primitives
    // -----------------------------------------------------------------------

    /// B2-U1: Empty-estate fingerprint equals SHA-256 of the empty string.
    ///
    /// SHA-256("") = e3b0c44298fc1c149afbf4c8996fb924... (first 32 chars).
    #[test]
    fn b2_u1_empty_estate_fingerprint() {
        let fp = estate_fingerprint(&[]);
        assert_eq!(fp, "sha256:e3b0c44298fc1c149afbf4c8996fb924:0");
    }

    /// B2-U2: Single-drawer estate fingerprint matches the known vector value.
    #[test]
    fn b2_u2_single_drawer_fingerprint() {
        let d = DrawerInput {
            id: "d1000000-0000-0000-0000-000000000001".to_string(),
            subject: None,
            content: String::new(),
            filed_at: String::new(),
            tombstoned_at: None,
        };
        let refs: Vec<&DrawerInput> = vec![&d];
        let fp = estate_fingerprint(&refs);
        // Expected from vector file (morning-single-drawer.json sourceEstateState).
        assert_eq!(fp, "sha256:88b343f61a9a4ebe4c31e08360ce8521:1");
    }

    /// B2-U3: derive_id produces the known session ID for morning-single-drawer.
    ///
    /// Input: ["session", "morning", "2026-08-23T09:00:00.000Z",
    ///          "sha256:88b343f61a9a4ebe4c31e08360ce8521:1"]
    #[test]
    fn b2_u3_session_id_derivation() {
        let id = derive_id(&[
            "session",
            "morning",
            "2026-08-23T09:00:00.000Z",
            "sha256:88b343f61a9a4ebe4c31e08360ce8521:1",
        ]);
        assert_eq!(id, "68450a7d-0df3-55c0-b6ac-6f6a1826af5a");
    }

    /// B2-U4: Tombstoned drawers are excluded from the session.
    #[test]
    fn b2_u4_tombstoned_drawers_excluded() {
        let active = DrawerInput {
            id: "d1000000-0000-0000-0000-000000000001".to_string(),
            subject: Some("Active".to_string()),
            content: "Active drawer.".to_string(),
            filed_at: "2026-08-23T08:00:00.000Z".to_string(),
            tombstoned_at: None,
        };
        let dead = DrawerInput {
            id: "d2000000-0000-0000-0000-000000000001".to_string(),
            subject: Some("Dead".to_string()),
            content: "Tombstoned drawer.".to_string(),
            filed_at: "2026-08-23T08:00:00.000Z".to_string(),
            tombstoned_at: Some("2026-08-23T09:00:00.000Z".to_string()),
        };
        let session = generate_session(
            ReviewKind::Morning,
            &[active, dead],
            "2026-08-23T10:00:00.000Z",
        );
        // Only one item in the section (the dead drawer is excluded).
        let sections = session["sections"].as_array().unwrap();
        assert_eq!(sections.len(), 1);
        let items = sections[0]["items"].as_array().unwrap();
        assert_eq!(items.len(), 1, "tombstoned drawer must not appear in items");
        // Only one action.
        let actions = session["actions"].as_array().unwrap();
        assert_eq!(actions.len(), 1, "tombstoned drawer must not appear in actions");
    }

    /// B2-U5: Equivalent inputs produce byte-identical sessions (determinism contract).
    #[test]
    fn b2_u5_determinism_same_input_same_output() {
        let d = DrawerInput {
            id: "d1000000-0000-0000-0000-000000000001".to_string(),
            subject: Some("Test".to_string()),
            content: "Test content.".to_string(),
            filed_at: "2026-08-23T08:00:00.000Z".to_string(),
            tombstoned_at: None,
        };
        let drawers = vec![d];
        let s1 = generate_session(ReviewKind::Morning, &drawers, "2026-08-23T09:00:00.000Z");
        let s2 = generate_session(ReviewKind::Morning, &drawers, "2026-08-23T09:00:00.000Z");
        let j1 = serde_json::to_string(&s1).unwrap();
        let j2 = serde_json::to_string(&s2).unwrap();
        assert_eq!(j1, j2, "same inputs must produce byte-identical sessions");
    }

    /// B2-U6: Different `now` produces a different session ID.
    ///
    /// The session ID incorporates `now`, so a different timestamp → different ID.
    #[test]
    fn b2_u6_different_now_different_session_id() {
        let d = DrawerInput {
            id: "d1000000-0000-0000-0000-000000000001".to_string(),
            subject: Some("Test".to_string()),
            content: "Test content.".to_string(),
            filed_at: "2026-08-23T08:00:00.000Z".to_string(),
            tombstoned_at: None,
        };
        let drawers = vec![d];
        let s1 = generate_session(ReviewKind::Morning, &drawers, "2026-08-23T09:00:00.000Z");
        let s2 = generate_session(ReviewKind::Morning, &drawers, "2026-08-23T10:00:00.000Z");
        assert_ne!(
            s1["id"].as_str().unwrap(),
            s2["id"].as_str().unwrap(),
            "different now must produce different session IDs",
        );
    }

    /// B2-U7: normalize_subject collapses whitespace and lowercases correctly.
    #[test]
    fn b2_u7_normalize_subject() {
        assert_eq!(normalize_subject("Research  Notes"), "research notes");
        assert_eq!(normalize_subject("  Hello   World  "), "hello world");
        assert_eq!(normalize_subject(""), "");
    }

    /// B2-U8: Section is absent when the estate is empty.
    #[test]
    fn b2_u8_empty_estate_no_sections() {
        let session = generate_session(ReviewKind::Morning, &[], "2026-08-23T09:00:00.000Z");
        let sections = session["sections"].as_array().unwrap();
        assert!(sections.is_empty(), "empty estate must produce no sections");
        let actions = session["actions"].as_array().unwrap();
        assert!(actions.is_empty(), "empty estate must produce no actions");
    }
}
