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
//! Pass 1 — same normalized subject (NFC + lowercase + whitespace-collapse; uses
//!           unicode-normalization crate for full NFC spec compliance — F9 fix).
//! Pass 2 — identical trimmed content.
//! First match wins per drawer; groups sorted by group UUID string ASC.

use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
// unicode-normalization: NFC normalization for normalize_subject, matching Swift's
// precomposedStringWithCanonicalMapping. Added for F9 parity (2026-08-24).
use unicode_normalization::UnicodeNormalization;

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
    /// Origin label written at capture time.
    ///
    /// System-origin drawers (prefixed "system:") are implementation artifacts —
    /// e.g. the "personal/capture" sentinel seeded by CommunityCaptureCoordinator
    /// when the estate has no rooms. They must be excluded from review sessions,
    /// actions, and duplicate detection, mirroring the Swift engine's filter (F11).
    pub added_by: Option<String>,
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
    // Filter to active drawers: non-tombstoned AND not system-origin.
    //
    // System-origin drawers (added_by prefixed "system:") are implementation
    // artifacts — e.g. the "personal/capture" sentinel — that must not appear
    // in review sessions, actions, or duplicate groups. Mirrors the Swift engine
    // filter in CommunityReviewEngine.generateSession() (F11 fix).
    let active: Vec<&DrawerInput> = drawers
        .iter()
        .filter(|d| {
            d.tombstoned_at.is_none()
                && !d
                    .added_by
                    .as_deref()
                    .unwrap_or("")
                    .starts_with("system:")
        })
        .collect();

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
            // Detail: content prefix 120 CHARS (not bytes), trimmed.
            //
            // Swift: String(drawer.content.prefix(120)).trimmingCharacters(in: .whitespaces)
            // Swift's .prefix(120) counts Unicode scalar values (chars), not bytes.
            // For non-ASCII content (e.g. 65 CJK chars × 3 bytes = 195 bytes), the old
            // byte-indexed &detail[..120] would take only 40 chars and panic on non-boundary
            // offsets. chars().take(120) is the correct, panic-free equivalent.
            // Trim uses is_swift_whitespace (excludes \n) to match Swift .whitespaces exactly.
            let detail_chars: String = drawer.content.chars().take(120).collect();
            let detail = trim_swift_whitespaces(&detail_chars);
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
/// Mirrors Swift CommunityReviewEngine.drawerSubject exactly:
///   1. prefix(60) by CHARACTER (Swift String.prefix counts grapheme clusters; here we
///      use chars().take(60) which counts Unicode scalar values — equivalent for all
///      content that produces identical output to Swift's grapheme-cluster count,
///      which is true for any content where scalars == grapheme clusters, i.e. all
///      non-ZWJ-sequence / non-emoji-modifier content).
///   2. THEN trimmingCharacters(in: .whitespaces) — trims space (U+0020) and tab
///      (U+0009) only, matching Swift's CharacterSet.whitespaces (NOT newlines).
///
/// F9 fix: the previous implementation used trim_end() BEFORE slicing (wrong order)
/// and used byte indexing &preview[..60] (panics on non-ASCII multibyte boundaries).
/// Swift order: take 60 chars FIRST, then trim whitespace.
fn drawer_subject(drawer: &DrawerInput) -> String {
    if let Some(ref sub) = drawer.subject {
        if !sub.is_empty() {
            return sub.clone();
        }
    }
    // Fallback: take first 60 Unicode scalar values (chars), matching Swift's
    // String.prefix(60) on grapheme-cluster boundaries for non-combining content.
    // Then trim Swift .whitespaces (space + tab only, NOT newlines or \r).
    let preview: String = drawer.content.chars().take(60).collect();
    let preview = trim_swift_whitespaces(&preview);
    if preview.is_empty() {
        drawer.id.clone()
    } else {
        preview.to_string()
    }
}

/// Whether a char is in Swift's CharacterSet.whitespaces (used by normalize_subject).
///
/// Swift's .whitespaces includes: SPACE (U+0020), TAB (U+0009), and other Unicode
/// category Zs characters (NO-BREAK SPACE U+00A0, EN QUAD U+2000–EM SPACE U+2003, etc.).
/// It does NOT include newlines (\n, \r, \r\n), which are in .newlines and
/// .whitespacesAndNewlines but NOT in .whitespaces.
///
/// F9 fix: the previous `split_whitespace()` was Rust's Unicode whitespace split,
/// which INCLUDES newlines — diverging from Swift on newline-bearing subjects.
/// This function matches Swift's .whitespaces set for the split/filter step.
fn is_swift_whitespace(c: char) -> bool {
    matches!(c,
        // ASCII space and tab — the primary Swift .whitespaces members.
        '\u{0009}' | '\u{0020}' |
        // Unicode Zs category (space separators) — all in Swift's .whitespaces.
        '\u{00A0}' | // NO-BREAK SPACE
        '\u{1680}' | // OGHAM SPACE MARK
        '\u{2000}' | // EN QUAD
        '\u{2001}' | // EM QUAD
        '\u{2002}' | // EN SPACE
        '\u{2003}' | // EM SPACE
        '\u{2004}' | // THREE-PER-EM SPACE
        '\u{2005}' | // FOUR-PER-EM SPACE
        '\u{2006}' | // SIX-PER-EM SPACE
        '\u{2007}' | // FIGURE SPACE
        '\u{2008}' | // PUNCTUATION SPACE
        '\u{2009}' | // THIN SPACE
        '\u{200A}' | // HAIR SPACE
        '\u{202F}' | // NARROW NO-BREAK SPACE
        '\u{205F}' | // MEDIUM MATHEMATICAL SPACE
        '\u{3000}'   // IDEOGRAPHIC SPACE
    )
}

/// Trim Swift .whitespaces (space and tab only, NOT newlines) from both ends.
///
/// Mirrors Swift's trimmingCharacters(in: .whitespaces).
fn trim_swift_whitespaces(s: &str) -> &str {
    s.trim_matches(is_swift_whitespace)
}

/// Normalize a subject string for duplicate-detection comparison.
///
/// Applies: NFC + lowercase + whitespace-collapse matching Swift .whitespaces.
///
/// F9 fixes (divergences from Swift corrected):
///   1. NFC normalization — Swift uses precomposedStringWithCanonicalMapping (NFC).
///      A decomposed subject ("e" + U+0301) must normalize to the same key as the
///      precomposed form ("é"). The `unicode-normalization` crate provides `.nfc()`.
///   2. Whitespace set — `split_whitespace()` splits on newlines (Rust Unicode
///      whitespace), but Swift's .whitespaces does NOT include newlines.
///      Changed to split on is_swift_whitespace (Zs + tab + space, no newlines).
///
/// Mirrors Swift CommunityReviewEngine.normalizeSubject.
fn normalize_subject(subject: &str) -> String {
    // Step 1: NFC normalize — matches Swift precomposedStringWithCanonicalMapping.
    let nfc: String = subject.nfc().collect();
    // Step 2: lowercase + split on Swift .whitespaces (NOT newlines) + filter empty + rejoin.
    nfc.to_lowercase()
        .split(is_swift_whitespace)
        .filter(|s| !s.is_empty())
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
            // addedBy is optional in the vector format — legacy vectors that predate the
            // system-origin filter do not include this field; they implicitly have no
            // system-origin drawers, so None is the correct default (F11 fix).
            added_by: d.get("addedBy").and_then(|v| v.as_str()).map(String::from),
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
            added_by: None,
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
            added_by: None,
        };
        let dead = DrawerInput {
            id: "d2000000-0000-0000-0000-000000000001".to_string(),
            subject: Some("Dead".to_string()),
            content: "Tombstoned drawer.".to_string(),
            filed_at: "2026-08-23T08:00:00.000Z".to_string(),
            tombstoned_at: Some("2026-08-23T09:00:00.000Z".to_string()),
            added_by: None,
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
            added_by: None,
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
            added_by: None,
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

    // -----------------------------------------------------------------------
    // F9 parity tests — non-ASCII canonical vectors
    // -----------------------------------------------------------------------

    /// F9-P1: Decomposed Unicode subject parity.
    ///
    /// Two drawers with NFD ("écafe") and NFC ("écafe") subject forms.
    /// After NFC normalization, both produce the same duplicate-detection key
    /// and must be grouped as duplicates — byte-identical to Swift output.
    ///
    /// Tests fix: NFC normalization via unicode-normalization crate in normalize_subject.
    #[test]
    fn f9_p1_decomposed_unicode_subject_parity() {
        assert_vector_parity("non-ascii-decomposed-unicode-subject.json");
    }

    /// F9-P2: CJK content 60-character boundary parity.
    ///
    /// One drawer with 65 CJK characters (U+7684 × 65), no subject.
    /// drawer_subject falls back to content prefix(60 chars). The previous
    /// &preview[..60] byte-indexed slice would panic on non-ASCII UTF-8
    /// boundaries (U+7684 is 3 bytes; byte 60 falls inside a character).
    /// chars().take(60) must be used instead — byte-identical to Swift output.
    ///
    /// Tests fix: chars().take(60) instead of &preview[..60] in drawer_subject.
    #[test]
    fn f9_p2_cjk_content_60_boundary_parity() {
        assert_vector_parity("non-ascii-cjk-content-60-boundary.json");
    }

    /// F9-P3: Newline-bearing subject parity.
    ///
    /// Two drawers with subject "hello\nworld" (literal embedded newline).
    /// Swift's .whitespaces does NOT include newlines, so the subject stays as
    /// one token after normalization → both drawers share the key "hello\nworld"
    /// and form a duplicate group.
    ///
    /// The previous split_whitespace() (Rust Unicode whitespace, includes \n)
    /// would produce key "hello world" (space-joined) instead of "hello\nworld",
    /// diverging from Swift and NOT grouping these drawers as duplicates.
    ///
    /// Tests fix: split(is_swift_whitespace) instead of split_whitespace() in normalize_subject.
    #[test]
    fn f9_p3_newline_bearing_subject_parity() {
        assert_vector_parity("non-ascii-newline-subject.json");
    }

    // -----------------------------------------------------------------------
    // F9 unit tests — sub-primitive correctness
    // -----------------------------------------------------------------------

    /// F9-U1: normalize_subject applies NFC before comparison.
    ///
    /// NFD "écafe" and NFC "\u{e9}cafe" must produce the same normalized key.
    /// Without NFC, these would be different strings — breaking duplicate detection
    /// for drawers with decomposed Unicode subjects.
    #[test]
    fn f9_u1_normalize_subject_nfc() {
        // NFD: "e" + combining acute (U+0301) + "cafe"
        let nfd = "e\u{0301}cafe";
        // NFC: precomposed é (U+00E9) + "cafe"
        let nfc = "\u{00e9}cafe";
        // After NFC normalization, both should produce the same lowercase key.
        let key_nfd = normalize_subject(nfd);
        let key_nfc = normalize_subject(nfc);
        assert_eq!(
            key_nfd, key_nfc,
            "NFD and NFC forms of the same subject must normalize to the same key; \
             got '{}' vs '{}'", key_nfd, key_nfc
        );
        assert_eq!(key_nfd, "\u{00e9}cafe", "normalized key should be NFC lowercase");
    }

    /// F9-U2: normalize_subject does NOT split on newlines.
    ///
    /// Swift's .whitespaces (which normalize_subject mirrors) splits on space and tab
    /// but NOT on newlines. "hello\nworld" is one token, not two. A Rust implementation
    /// using split_whitespace() would split on \n and produce "hello world" instead.
    #[test]
    fn f9_u2_normalize_subject_no_newline_split() {
        // Subject with embedded newline — Swift .whitespaces does NOT split on \n.
        let key = normalize_subject("hello\nworld");
        // Must stay as one token containing the newline, not be split into two tokens.
        assert_eq!(
            key, "hello\nworld",
            "normalize_subject must NOT split on newlines (Swift .whitespaces excludes \\n); \
             got '{:?}'", key
        );
    }

    /// F9-U3: drawer_subject takes 60 chars (not 60 bytes) from content.
    ///
    /// For content consisting of 65 CJK characters (3 bytes each), a byte-indexed
    /// &content[..60] would only capture 20 characters — and would panic because
    /// byte 60 falls in the middle of the third character. chars().take(60)
    /// correctly takes the first 60 Unicode scalar values.
    #[test]
    fn f9_u3_drawer_subject_cjk_60_chars_not_bytes() {
        // 65 CJK characters (U+7684 "的"), each 3 bytes in UTF-8.
        let cjk_content: String = std::iter::repeat('\u{7684}').take(65).collect();
        assert_eq!(cjk_content.len(), 195, "sanity: 65 × 3 bytes = 195");

        let drawer = DrawerInput {
            id: "test-id".to_string(),
            subject: None,
            content: cjk_content,
            filed_at: String::new(),
            tombstoned_at: None,
            added_by: None,
        };

        // drawer_subject should return the first 60 CHARACTERS, not 60 bytes.
        let subject = drawer_subject(&drawer);
        let expected: String = std::iter::repeat('\u{7684}').take(60).collect();
        assert_eq!(
            subject, expected,
            "drawer_subject must take first 60 chars (not 60 bytes) from CJK content"
        );
        // The subject must be exactly 60 CJK chars (180 bytes), not 20 CJK chars (60 bytes).
        assert_eq!(subject.chars().count(), 60, "expected 60 chars");
        assert_eq!(subject.len(), 180, "expected 180 bytes (60 × 3)");
    }

    /// F9-U5: detail uses prefix(120 chars), not prefix(120 bytes).
    ///
    /// Swift: String(drawer.content.prefix(120)).trimmingCharacters(in: .whitespaces)
    /// For 125 CJK characters (3 bytes each = 375 bytes), the old byte-indexed
    /// &detail[..120] would take only 40 chars. chars().take(120) correctly takes 120.
    ///
    /// Tests the F9 fix applied to the detail field (same root cause as drawer_subject).
    #[test]
    fn f9_u5_detail_cjk_120_chars_not_bytes() {
        // 125 CJK characters, each 3 bytes in UTF-8.
        let cjk_content: String = std::iter::repeat('\u{7684}').take(125).collect();
        assert_eq!(cjk_content.len(), 375, "sanity: 125 × 3 bytes = 375");

        let drawer = DrawerInput {
            id: "detail-test-id".to_string(),
            subject: Some("explicit subject".to_string()), // non-empty so subject != detail
            content: cjk_content,
            filed_at: String::new(),
            tombstoned_at: None,
            added_by: None,
        };

        // Generate a session with this one drawer. The detail field in the
        // generated session item must be prefix(120 chars), not prefix(120 bytes).
        let now = "2026-08-24T09:00:00.000Z";
        let session = generate_session(ReviewKind::Morning, &[drawer], now);
        let sections = session["sections"].as_array().unwrap();
        assert!(!sections.is_empty(), "session must have a section");
        let items = sections[0]["items"].as_array().unwrap();
        assert!(!items.is_empty(), "section must have an item");
        let detail = items[0]["detail"].as_str().unwrap();
        let expected: String = std::iter::repeat('\u{7684}').take(120).collect();
        assert_eq!(
            detail, expected,
            "detail must be first 120 CHARS (not 40 chars from 120 bytes) for CJK content"
        );
        assert_eq!(detail.chars().count(), 120, "expected 120 chars in detail");
    }

    /// F9-U4: drawer_subject trims AFTER taking prefix (Swift order).
    ///
    /// Swift: String(content.prefix(60)).trimmingCharacters(in: .whitespaces)
    /// The trim happens AFTER the prefix, not before. If a 60-char prefix ends
    /// with trailing spaces, those are trimmed. If we trim FIRST then slice (old
    /// buggy Rust order), we'd get a different (longer) result for content that
    /// starts with spaces.
    #[test]
    fn f9_u4_drawer_subject_trim_after_prefix() {
        // Content: 4 leading spaces + 60 chars of 'x' = 64 chars total.
        // Swift prefix(60) = "    " + "x"×56. After trim = "x"×56.
        // Old Rust (trim first, then slice): trim → "x"×60, slice to 60 → "x"×60. WRONG.
        let content = format!("    {}", "x".repeat(60)); // 64 chars total
        let drawer = DrawerInput {
            id: "test-id".to_string(),
            subject: None,
            content,
            filed_at: String::new(),
            tombstoned_at: None,
            added_by: None,
        };

        // Swift order: prefix(60) → "    " + "x"×56 → trim → "x"×56
        let subject = drawer_subject(&drawer);
        assert_eq!(
            subject, "x".repeat(56),
            "drawer_subject must apply trim AFTER prefix, not before; \
             leading spaces in the prefix must be trimmed from the result"
        );
    }
}
