// row_attribute_view.rs
//
// Shared row-replay shape for multi-antecedent mining (Apriori, FCA).
// Rust port of RowAttributeView.swift (Sources/SubstrateML/RowAttributeView.swift).
//
// `RowAttributeView` is a pure value type that exposes one row's
// categorical features as a sorted Vec<(field: u8, value: u8)> list —
// the same `Item`-compatible shape association_rule_mining uses, so
// engines built on that primitive can consume both the pairwise
// (MatrixO) and the row-replay (RowAttributeView) inputs without an
// intermediate translation layer.
//
// Input shape: `RowAuditEntry` is the SubstrateML-native audit-entry
// type. GeniusLocusKit converts its `UnifiedAuditEntry` stream into
// `RowAuditEntry` values before calling the factory. Keeping
// `RowAuditEntry` in SubstrateML avoids a layering inversion
// (SubstrateML is below GeniusLocusKit; it cannot import GLK types).
//
// Extraction rules (cookbook §5.3 / §6.3):
//
//   RowAuditValue::Bitmap(v) — each set bit at position p (0..63)
//     becomes one attribute: field = fieldPath vocab index,
//     value = p (bit position). Mirrors F-matrix bit-decomposition
//     from applyCapture.
//
//   RowAuditValue::Integer(n) — one attribute: field = fieldPath
//     vocab index, value = (n & 0xFF) as u8. Low byte only.
//
//   RowAuditValue::Null — dropped (no categorical content).
//
// The shared vocabulary is built once per `from(audit_entries)` call
// by collecting all distinct field_path strings, sorting
// alphabetically, and assigning indices 0..min(N-1, 63). The
// vocabulary is NOT embedded in the returned views; it is an
// implementation detail of the factory. Callers that need consistent
// cross-call vocabularies should merge their entry lists before
// calling.

use std::collections::HashMap;
use substrate_types::HLC;

// ---------------------------------------------------------------------------
// Input types
// ---------------------------------------------------------------------------

/// A typed value payload for a single audit-log field write.
/// Mirrors `RowAuditValue` in Swift. The three cases are:
/// - Bitmap: each set bit position becomes a separate attribute.
/// - Integer: low byte is used as the attribute value.
/// - Null: produces no attribute and the entry is dropped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowAuditValue {
    /// A 64-bit bitmap. Each set bit position p becomes an attribute
    /// (field, p) in `RowAttributeView`.
    Bitmap(u64),
    /// An integer value. Low byte flows through as the attribute value.
    Integer(i64),
    /// Absent / tombstone — produces no attribute.
    Null,
}

/// One field write from an audit log. Used as input to
/// `RowAttributeView::from(audit_entries)`.
///
/// GeniusLocusKit converts `UnifiedAuditEntry` values to `RowAuditEntry`
/// values before calling the factory, keeping the dependency graph clean:
/// SubstrateML never imports GeniusLocusKit types.
#[derive(Debug, Clone)]
pub struct RowAuditEntry {
    /// The row this write belongs to. u128 mirrors Swift UUID (128 bits).
    pub row_id: u128,

    /// Storage tier as a raw string (e.g. "locus", "rag").
    /// Matches `AuditTier.rawValue` from GeniusLocusKit so grouping
    /// semantics are preserved through the conversion.
    pub tier: String,

    /// Logical name of the field being written.
    pub field_path: String,

    /// Hybrid logical clock at write time. Used for latest-wins
    /// deduplication within a row's field history.
    pub hlc: HLC,

    /// The value written to this field.
    pub value: RowAuditValue,
}

impl RowAuditEntry {
    pub fn new(
        row_id: u128,
        tier: impl Into<String>,
        field_path: impl Into<String>,
        hlc: HLC,
        value: RowAuditValue,
    ) -> Self {
        Self {
            row_id,
            tier: tier.into(),
            field_path: field_path.into(),
            hlc,
            value,
        }
    }
}

// ---------------------------------------------------------------------------
// RowAttributeView
// ---------------------------------------------------------------------------

/// One row's categorical features in the flat `(field, value)` shape
/// used by `apriori_mining` and `formal_concept_analysis`.
///
/// Produced by `RowAttributeView::from(audit_entries)` or by direct
/// construction for tests and for engines that derive views from
/// sources other than the audit log.
///
/// Attribute ordering is sorted ascending by `(field, value)` for
/// deterministic equality, hashing, and itemset operations across
/// languages — identical to the Swift port.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RowAttributeView {
    /// The row this view describes. u128 mirrors Swift UUID.
    pub row_id: u128,

    /// The storage tier this row came from (raw string value).
    pub tier: String,

    /// Sorted `(field, value)` attribute pairs for this row.
    ///
    /// `field` is a per-factory vocabulary index (0..63) over
    /// distinct field_path strings in the input batch.
    ///
    /// `value` is either a bitmap bit-position (0..63) for
    /// `Bitmap` fields or the low byte of an `Integer` value.
    pub attributes: Vec<(u8, u8)>,
}

impl RowAttributeView {
    /// Direct constructor — available for tests and for downstream
    /// engines that supply their own views. Sorts attributes ascending
    /// by (field, value) to match factory output ordering.
    pub fn new(row_id: u128, tier: impl Into<String>, attributes: Vec<(u8, u8)>) -> Self {
        let mut attrs = attributes;
        attrs.sort_unstable();
        Self {
            row_id,
            tier: tier.into(),
            attributes: attrs,
        }
    }

    /// Build a `RowAttributeView` array from a flat list of `RowAuditEntry` values.
    ///
    /// Algorithm (mirrors Swift `RowAttributeView.from(auditEntries:)`):
    ///
    /// 1. Build a shared vocabulary of all distinct `field_path` strings,
    ///    sorted alphabetically and capped at 64 (the 6-bit field-index
    ///    limit of `Item`).
    ///
    /// 2. Group entries by `(tier, row_id)`.
    ///
    /// 3. Within each group, take the LATEST entry per `field_path`
    ///    (HLC ordering ascending — last write wins, matching the
    ///    AuditLogFold projection rule).
    ///
    /// 4. Extract attributes from each surviving entry's `value`
    ///    using the rules in the file header. Rows that produce
    ///    zero attributes are dropped.
    ///
    /// The returned array is sorted by `(tier, row_id)` as a string pair
    /// for deterministic output — mirrors the Swift sort by
    /// `(tier, rowID.uuidString)`.
    pub fn from(audit_entries: &[RowAuditEntry]) -> Vec<RowAttributeView> {
        if audit_entries.is_empty() {
            return Vec::new();
        }

        // Step 1 — build shared field_path vocabulary (max 64 entries).
        let vocab = build_vocab(audit_entries);

        // Step 2 — group by (tier, row_id).
        let mut groups: HashMap<(String, u128), Vec<&RowAuditEntry>> = HashMap::new();
        for entry in audit_entries {
            groups
                .entry((entry.tier.clone(), entry.row_id))
                .or_default()
                .push(entry);
        }

        // Steps 3+4 — project each group to a RowAttributeView.
        let mut views: Vec<RowAttributeView> = Vec::with_capacity(groups.len());

        for ((tier, row_id), entries) in groups {
            let attrs = project_attributes(&entries, &vocab);
            if attrs.is_empty() {
                continue;
            }
            views.push(RowAttributeView {
                row_id,
                tier,
                attributes: attrs,
            });
        }

        // Deterministic output order: (tier, row_id formatted as hex string).
        // row_id is a u128 representing a UUID; format as "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        // (32 lowercase hex digits) to match Swift's UUID.uuidString sort collation.
        views.sort_by(|a, b| {
            let t = a.tier.cmp(&b.tier);
            if t != std::cmp::Ordering::Equal {
                return t;
            }
            // UUID string sort: format both as hyphenated UUID strings for
            // lexicographic ordering consistent with Swift UUIDString sort.
            uuid_string(a.row_id).cmp(&uuid_string(b.row_id))
        });

        views
    }
}

// ---------------------------------------------------------------------------
// Implementation helpers
// ---------------------------------------------------------------------------

/// Format a u128 as a hyphenated UUID string ("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
/// for sort ordering that matches Swift's UUID.uuidString ordering.
fn uuid_string(v: u128) -> String {
    let b = v.to_be_bytes();
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3],
        b[4], b[5],
        b[6], b[7],
        b[8], b[9],
        b[10], b[11], b[12], b[13], b[14], b[15]
    )
}

/// Build a sorted, capped vocabulary from all field_path strings.
/// Maximum 64 entries (6-bit field-index limit).
fn build_vocab(entries: &[RowAuditEntry]) -> Vec<String> {
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for e in entries {
        seen.insert(e.field_path.clone());
    }
    // BTreeSet is already sorted; take up to 64.
    seen.into_iter().take(64).collect()
}

/// Select the latest-HLC entry per field_path within one row group,
/// then extract attributes.
fn project_attributes(entries: &[&RowAuditEntry], vocab: &[String]) -> Vec<(u8, u8)> {
    // Latest-HLC dedup per field_path within this row.
    let mut latest: HashMap<&str, &RowAuditEntry> = HashMap::new();
    for entry in entries {
        let path = entry.field_path.as_str();
        match latest.get(path) {
            Some(existing) if existing.hlc >= entry.hlc => {
                // existing is at least as recent; keep it
            }
            _ => {
                latest.insert(path, entry);
            }
        }
    }

    let mut attrs: Vec<(u8, u8)> = Vec::new();

    for (field_path, entry) in &latest {
        // Find the vocabulary index for this field_path.
        let Some(idx) = vocab.iter().position(|s| s == field_path) else {
            continue;
        };
        let field = idx as u8;
        match entry.value {
            RowAuditValue::Bitmap(v) => {
                // Each set bit at position p → attribute (field, p).
                let mut remaining = v;
                while remaining != 0 {
                    let p = remaining.trailing_zeros() as u8;
                    attrs.push((field, p));
                    remaining &= remaining - 1;
                }
            }
            RowAuditValue::Integer(n) => {
                // Low byte flows through as the attribute value.
                attrs.push((field, (n & 0xFF) as u8));
            }
            RowAuditValue::Null => {
                // No attribute produced.
            }
        }
    }

    // Sort ascending by (field, value) for deterministic output.
    attrs.sort_unstable();
    attrs
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn hlc(physical_ms: i64) -> HLC {
        HLC::new(physical_ms, 0, 0)
    }

    fn entry(
        row_id: u128,
        tier: &str,
        field_path: &str,
        physical: i64,
        value: RowAuditValue,
    ) -> RowAuditEntry {
        RowAuditEntry::new(row_id, tier, field_path, hlc(physical), value)
    }

    // MARK: - Empty input

    #[test]
    fn empty_input_produces_empty_views() {
        let views = RowAttributeView::from(&[]);
        assert!(views.is_empty());
    }

    // MARK: - Single bitmap entry

    #[test]
    fn single_bitmap_entry_produces_one_view() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0001u128;
        let e = entry(id, "locus", "alpha", 1000, RowAuditValue::Bitmap(0b0101)); // bits 0, 2
        let views = RowAttributeView::from(&[e]);

        assert_eq!(views.len(), 1);
        let v = &views[0];
        assert_eq!(v.row_id, id);
        assert_eq!(v.tier, "locus");
        // Bit 0 and bit 2 → values 0 and 2 on field 0 ("alpha" is only field_path)
        assert_eq!(v.attributes, vec![(0, 0), (0, 2)]);
    }

    // MARK: - Single integer entry

    #[test]
    fn single_integer_entry_produces_one_view() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0002u128;
        let e = entry(id, "locus", "beta", 1000, RowAuditValue::Integer(42));
        let views = RowAttributeView::from(&[e]);

        assert_eq!(views.len(), 1);
        let v = &views[0];
        assert_eq!(v.row_id, id);
        // field 0 ("beta"), value 42
        assert_eq!(v.attributes, vec![(0, 42)]);
    }

    // MARK: - Null entry dropped

    #[test]
    fn null_entry_produces_no_view() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0003u128;
        let e = entry(id, "locus", "gamma", 1000, RowAuditValue::Null);
        let views = RowAttributeView::from(&[e]);
        assert!(views.is_empty());
    }

    // MARK: - Bitmap bit extraction

    #[test]
    fn bitmap_bit_extraction_matches_expected_items() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0004u128;
        // 0b10010001 → bits 0, 4, 7
        let e = entry(id, "locus", "flags", 1000, RowAuditValue::Bitmap(0b10010001));
        let views = RowAttributeView::from(&[e]);

        assert_eq!(views.len(), 1);
        // field 0 ("flags"), values 0, 4, 7
        assert_eq!(views[0].attributes, vec![(0, 0), (0, 4), (0, 7)]);
    }

    #[test]
    fn zero_bitmap_produces_no_view() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0005u128;
        let e = entry(id, "locus", "empty", 1000, RowAuditValue::Bitmap(0));
        let views = RowAttributeView::from(&[e]);
        assert!(views.is_empty());
    }

    // MARK: - Integer low-byte flows through

    #[test]
    fn integer_low_byte_flows_through() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0006u128;
        // 0x1FF → low byte = 0xFF
        let e = entry(id, "locus", "status", 1000, RowAuditValue::Integer(0x1FF));
        let views = RowAttributeView::from(&[e]);

        assert_eq!(views.len(), 1);
        assert_eq!(views[0].attributes, vec![(0, 0xFF)]);
    }

    // MARK: - Bundling by (tier, row_id)

    #[test]
    fn different_row_ids_produce_separate_views() {
        let id1 = 0x0000_0000_0000_0000_0000_0000_0000_0007u128;
        let id2 = 0x0000_0000_0000_0000_0000_0000_0000_0008u128;
        let entries = vec![
            entry(id1, "locus", "x", 1000, RowAuditValue::Integer(1)),
            entry(id2, "locus", "x", 1000, RowAuditValue::Integer(2)),
        ];
        let views = RowAttributeView::from(&entries);
        assert_eq!(views.len(), 2);
        let ids: std::collections::HashSet<u128> = views.iter().map(|v| v.row_id).collect();
        assert!(ids.contains(&id1));
        assert!(ids.contains(&id2));
    }

    #[test]
    fn different_tiers_produce_separate_views() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_0009u128;
        let entries = vec![
            entry(id, "locus", "x", 1000, RowAuditValue::Integer(1)),
            entry(id, "rag",   "x", 1000, RowAuditValue::Integer(2)),
        ];
        let views = RowAttributeView::from(&entries);
        assert_eq!(views.len(), 2);
        let tiers: std::collections::HashSet<&str> = views.iter().map(|v| v.tier.as_str()).collect();
        assert!(tiers.contains("locus"));
        assert!(tiers.contains("rag"));
    }

    #[test]
    fn same_row_merged_into_one_view() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_000Au128;
        // Two fields for the same row
        let entries = vec![
            entry(id, "locus", "a", 1000, RowAuditValue::Integer(1)),
            entry(id, "locus", "b", 1000, RowAuditValue::Integer(2)),
        ];
        let views = RowAttributeView::from(&entries);
        assert_eq!(views.len(), 1);
        // vocabulary: ["a", "b"] → field 0, 1
        assert_eq!(views[0].attributes, vec![(0, 1), (1, 2)]);
    }

    // MARK: - Latest-HLC deduplication

    #[test]
    fn latest_hlc_entry_wins_per_field_path() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_000Bu128;
        let entries = vec![
            RowAuditEntry::new(id, "locus", "x", HLC::new(100, 0, 0), RowAuditValue::Integer(10)),
            RowAuditEntry::new(id, "locus", "x", HLC::new(200, 0, 0), RowAuditValue::Integer(20)), // newer wins
            RowAuditEntry::new(id, "locus", "x", HLC::new(150, 0, 0), RowAuditValue::Integer(15)),
        ];
        let views = RowAttributeView::from(&entries);
        assert_eq!(views.len(), 1);
        // hlc(200) wins → value 20
        assert_eq!(views[0].attributes, vec![(0, 20)]);
    }

    // MARK: - Vocabulary ordering

    #[test]
    fn field_path_vocabulary_is_alphabetical() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_000Cu128;
        let entries = vec![
            entry(id, "locus", "zzz", 1000, RowAuditValue::Integer(3)),
            entry(id, "locus", "aaa", 1000, RowAuditValue::Integer(1)),
            entry(id, "locus", "mmm", 1000, RowAuditValue::Integer(2)),
        ];
        let views = RowAttributeView::from(&entries);
        assert_eq!(views.len(), 1);
        // vocab: ["aaa"=0, "mmm"=1, "zzz"=2] → attrs (0,1), (1,2), (2,3)
        assert_eq!(views[0].attributes, vec![(0, 1), (1, 2), (2, 3)]);
    }

    // MARK: - Output ordering

    #[test]
    fn output_sorted_by_tier_then_row_id() {
        // Use UUID-shaped u128 values with known string ordering.
        // UUID string format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        // These IDs are big-endian encoded so the sort on UUID string
        // matches numeric order.
        let id_a: u128 = 0x00000000_0000_0000_0000_000000000001;
        let id_b: u128 = 0x00000000_0000_0000_0000_000000000002;
        let entries = vec![
            entry(id_b, "locus", "x", 1000, RowAuditValue::Integer(2)),
            entry(id_a, "rag",   "x", 1000, RowAuditValue::Integer(4)),
            entry(id_a, "locus", "x", 1000, RowAuditValue::Integer(1)),
        ];
        let views = RowAttributeView::from(&entries);
        assert_eq!(views.len(), 3);
        // Sort: tier "locus" < "rag"; within "locus", id_a < id_b
        assert_eq!(views[0].row_id, id_a);
        assert_eq!(views[0].tier, "locus");
        assert_eq!(views[1].row_id, id_b);
        assert_eq!(views[1].tier, "locus");
        assert_eq!(views[2].row_id, id_a);
        assert_eq!(views[2].tier, "rag");
    }

    // MARK: - Mixed field types

    #[test]
    fn mixed_bitmap_and_integer_fields_produce_combined_attributes() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_000Du128;
        let entries = vec![
            entry(id, "locus", "flags",  1000, RowAuditValue::Bitmap(0b0011)), // bits 0, 1
            entry(id, "locus", "status", 1000, RowAuditValue::Integer(7)),
        ];
        let views = RowAttributeView::from(&entries);
        assert_eq!(views.len(), 1);
        // vocab: ["flags"=0, "status"=1]
        // flags → (0,0), (0,1); status → (1,7)
        assert_eq!(views[0].attributes, vec![(0, 0), (0, 1), (1, 7)]);
    }

    // MARK: - RowAttributeView::new sorts attributes

    #[test]
    fn new_constructor_sorts_attributes() {
        let id = 0x0000_0000_0000_0000_0000_0000_0000_000Eu128;
        let view = RowAttributeView::new(id, "locus", vec![(2, 5), (0, 3), (1, 1), (0, 1)]);
        // Expected sort: (0,1), (0,3), (1,1), (2,5)
        assert_eq!(view.attributes, vec![(0, 1), (0, 3), (1, 1), (2, 5)]);
    }
}
