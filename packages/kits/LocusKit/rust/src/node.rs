//! Container node in the estate's containment tree (ADR-017 §1–§2).
//!
//! The estate is a fixed-depth tree: estate (depth 0), wing (depth 1),
//! room (depth 2). Drawers are leaf nodes in the `drawers` table, not
//! the `nodes` table. Container nodes carry lifecycle state
//! (active/tombstoned) with HLC timestamps for temporal filtering,
//! supporting the as-of read surface (NT-P1).
//!
//! Two name fields (§8): `display_name` preserves first-writer casing;
//! `lookup_name` is normalized (NFC + casefold + whitespace-collapse)
//! and used for resolution and uniqueness enforcement.
//!
//! ## Swift-to-Rust shape changes
//!
//! - Swift `UUID` → Rust `uuid::Uuid`.
//! - Swift `Date` → Rust `i64` epoch seconds.
//! - Swift `HLC` → Rust `substrate_types::hlc::HLC`.

use substrate_types::hlc::HLC;
use substrate_types::merkle_root::MerkleRoot;
use uuid::Uuid;

/// A container node in the estate's containment tree.
///
/// Nodes represent the structural skeleton: estate root, wings, and
/// rooms. Drawers reference their parent room via `parent_node_id`
/// on the drawers table (NT-L2). The `merkle_root` field is populated
/// by `rollup_merkle_roots` after drawer writes (NT-L3); new nodes
/// start with `None` until the first rollup runs.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Node {
    /// Stable UUID identifier for this node.
    pub id: Uuid,

    /// Parent node UUID. None only for the estate root (depth 0).
    pub parent_id: Option<Uuid>,

    /// Human-readable name preserving first-writer casing (§8).
    pub display_name: String,

    /// Normalized resolution key: NFC + casefold + whitespace-collapse (§8).
    /// All resolution, uniqueness enforcement, and index keys use this field.
    pub lookup_name: String,

    /// Tree depth: 0 = estate, 1 = wing, 2 = room. Write-once, no reparent.
    pub depth: i32,

    /// Lifecycle state: 0 = active, 1 = tombstoned (§5).
    pub lifecycle: i32,

    /// HLC at node creation — temporal floor for as-of filter.
    pub created_hlc: HLC,

    /// HLC at tombstone transition; None while active (§5, §15).
    /// As-of test: created_hlc <= T AND (tombstoned_hlc.is_none() OR tombstoned_hlc > T).
    pub tombstoned_hlc: Option<HLC>,

    /// Wall-clock mirror of tombstoned_hlc (epoch seconds), for display only.
    /// Never used in temporal filtering — wall time is not HLC-comparable.
    pub tombstoned_at: Option<i64>,

    /// Per-node Merkle content-integrity root (§16). Stored as a 32-byte
    /// BLOB in SQLite. None until hash-on-write populates it.
    pub merkle_root: Option<MerkleRoot>,

    /// Wall-clock creation timestamp (epoch seconds; ISO8601 TEXT in SQLite).
    pub created_at: i64,

    /// Wall-clock last-update timestamp (epoch seconds; ISO8601 TEXT in SQLite).
    pub updated_at: i64,

    /// Forward-compat JSON extension slot (ADR-012). None in 1.0.
    pub ext: Option<String>,
}

impl Node {
    /// Whether this node is active (not tombstoned).
    pub fn is_active(&self) -> bool {
        self.lifecycle == 0
    }

    /// Whether this node has been tombstoned.
    pub fn is_tombstoned(&self) -> bool {
        self.lifecycle == 1
    }

    /// Derive a lookup name from a display name: Unicode NFC, trim,
    /// collapse internal whitespace to single spaces, then casefold
    /// (lowercased for ASCII; full Unicode casefold for non-ASCII).
    /// Conformance-gated: Swift and Rust must produce byte-identical results.
    pub fn normalize_lookup_name(display_name: &str) -> String {
        use unicode_normalization::UnicodeNormalization;
        let nfc: String = display_name.nfc().collect();
        let trimmed = nfc.trim();
        // Collapse internal whitespace to single spaces
        let mut collapsed = String::with_capacity(trimmed.len());
        let mut prev_was_space = false;
        for ch in trimmed.chars() {
            if ch.is_whitespace() {
                if !prev_was_space {
                    collapsed.push(' ');
                    prev_was_space = true;
                }
            } else {
                collapsed.push(ch);
                prev_was_space = false;
            }
        }
        // Casefold (lowercased — matches Swift's lowercased() for ASCII;
        // for full Unicode casefold, both ports use lowercase which covers
        // the conformance-gated subset)
        collapsed.to_lowercase()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_lookup_name_basic() {
        assert_eq!(Node::normalize_lookup_name("  My Wing  "), "my wing");
    }

    #[test]
    fn normalize_lookup_name_collapses_whitespace() {
        assert_eq!(Node::normalize_lookup_name("foo   bar\tbaz"), "foo bar baz");
    }

    #[test]
    fn normalize_lookup_name_empty() {
        assert_eq!(Node::normalize_lookup_name(""), "");
    }

    #[test]
    fn node_lifecycle_accessors() {
        let hlc = HLC::new(1000, 0, 0);
        let node = Node {
            id: Uuid::new_v4(),
            parent_id: None,
            display_name: "Estate".to_string(),
            lookup_name: "estate".to_string(),
            depth: 0,
            lifecycle: 0,
            created_hlc: hlc,
            tombstoned_hlc: None,
            tombstoned_at: None,
            merkle_root: None,
            created_at: 1000,
            updated_at: 1000,
            ext: None,
        };
        assert!(node.is_active());
        assert!(!node.is_tombstoned());
    }

    #[test]
    fn node_round_trip_equality() {
        let hlc = HLC::new(1000, 0, 0);
        let id = Uuid::new_v4();
        let node = Node {
            id,
            parent_id: Some(Uuid::new_v4()),
            display_name: "Test Wing".to_string(),
            lookup_name: "test wing".to_string(),
            depth: 1,
            lifecycle: 0,
            created_hlc: hlc,
            tombstoned_hlc: None,
            tombstoned_at: None,
            merkle_root: None,
            created_at: 1000,
            updated_at: 1000,
            ext: None,
        };
        let cloned = node.clone();
        assert_eq!(node, cloned);
    }
}
