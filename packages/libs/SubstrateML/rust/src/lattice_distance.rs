// lattice_distance.rs
//
// Lattice distance per cookbook § 8.3. Mirror of
// glref-swift-LatticeDistance.swift.

use std::collections::HashSet;

/// Lattice anchor with UDC string and optional Wikidata Q-ID.
/// (Distinct from the packed 16-byte form used in verbs.rs;
/// the distance reference works on the rich string form so it
/// can be tested directly with human-readable UDC codes.)
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LatticeAnchorStr {
    pub udc: String,
    pub qid: u64, // 0 = null
}

impl LatticeAnchorStr {
    pub fn new(udc: impl Into<String>, qid: u64) -> Self {
        Self { udc: udc.into(), qid }
    }
}

// ============================================================
// UDC tree distance
// ============================================================

pub struct UDCTreeDistance;

impl UDCTreeDistance {
    /// Longest common prefix length, in characters.
    #[inline]
    pub fn longest_common_prefix_length(a: &str, b: &str) -> usize {
        let a_chars: Vec<char> = a.chars().collect();
        let b_chars: Vec<char> = b.chars().collect();
        let n = a_chars.len().min(b_chars.len());
        let mut i = 0;
        while i < n && a_chars[i] == b_chars[i] {
            i += 1;
        }
        i
    }

    /// UDC tree distance per glref oracle (cookbook § 8.3).
    ///
    /// Formula: raw = (len_a - lcp) + (len_b - lcp), divisor = max(len_a, len_b).
    /// Guard: both-empty strings are equal (caught by the identity check);
    /// when max_len = 0, return 0.0.
    pub fn distance(a: &str, b: &str) -> f64 {
        if a == b {
            return 0.0;
        }
        let len_a = a.chars().count();
        let len_b = b.chars().count();
        let max_len = len_a.max(len_b);
        // Guard: both-empty are equal and caught above; a non-empty vs
        // empty pair yields max_len > 0. Explicit guard to match glref.
        if max_len == 0 {
            return 0.0;
        }
        let lcp = Self::longest_common_prefix_length(a, b);
        let raw = ((len_a - lcp) + (len_b - lcp)) as f64;
        raw / max_len as f64
    }
}

// ============================================================
// Wikidata graph distance
// ============================================================

/// Adjacency over subclass_of / instance_of / part_of.
pub trait WikidataAdjacencyProvider {
    fn neighbors(&self, qid: u64) -> HashSet<u64>;
}

pub struct WikidataGraphDistance;

impl WikidataGraphDistance {
    pub const MAX_DEPTH: usize = 4;
    pub const NORMALIZATION_SCALE: f64 = 3.0;

    /// BFS over `provider` up to `max_depth`. Returns shortest
    /// path length or None.
    pub fn shortest_path_length(
        a: u64,
        b: u64,
        provider: &dyn WikidataAdjacencyProvider,
        max_depth: usize,
    ) -> Option<usize> {
        if a == b {
            return Some(0);
        }
        let mut visited: HashSet<u64> = HashSet::new();
        visited.insert(a);
        let mut frontier: HashSet<u64> = HashSet::new();
        frontier.insert(a);
        for depth in 1..=max_depth {
            let mut next: HashSet<u64> = HashSet::new();
            for &node in &frontier {
                for neighbor in provider.neighbors(node) {
                    if neighbor == b {
                        return Some(depth);
                    }
                    if !visited.contains(&neighbor) {
                        visited.insert(neighbor);
                        next.insert(neighbor);
                    }
                }
            }
            if next.is_empty() {
                return None;
            }
            frontier = next;
        }
        None
    }

    pub fn distance(
        a: u64,
        b: u64,
        provider: &dyn WikidataAdjacencyProvider,
        max_depth: usize,
    ) -> f64 {
        if a == 0 || b == 0 {
            return 1.0;
        }
        if a == b {
            return 0.0;
        }
        match Self::shortest_path_length(a, b, provider, max_depth) {
            Some(path_length) => 1.0 - (-(path_length as f64) / Self::NORMALIZATION_SCALE).exp(),
            None => 1.0,
        }
    }
}

// ============================================================
// Combined lattice distance
// ============================================================

pub struct LatticeDistance;

impl LatticeDistance {
    pub const DEFAULT_ALPHA_UDC: f64 = 0.5;
    pub const DEFAULT_ALPHA_QID: f64 = 0.5;

    pub fn distance(
        a: &LatticeAnchorStr,
        b: &LatticeAnchorStr,
        provider: &dyn WikidataAdjacencyProvider,
        alpha_udc: f64,
        alpha_qid: f64,
    ) -> f64 {
        let udc_d = UDCTreeDistance::distance(&a.udc, &b.udc);
        let qid_d = WikidataGraphDistance::distance(
            a.qid, b.qid, provider, WikidataGraphDistance::MAX_DEPTH);
        alpha_udc * udc_d + alpha_qid * qid_d
    }
}

// ============================================================
// Tests
// ============================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// Synthetic adjacency provider for tests.
    struct MockGraph {
        adj: HashMap<u64, HashSet<u64>>,
    }

    impl MockGraph {
        fn new() -> Self {
            Self { adj: HashMap::new() }
        }
        fn edge(&mut self, a: u64, b: u64) -> &mut Self {
            self.adj.entry(a).or_insert_with(HashSet::new).insert(b);
            self.adj.entry(b).or_insert_with(HashSet::new).insert(a);
            self
        }
    }

    impl WikidataAdjacencyProvider for MockGraph {
        fn neighbors(&self, qid: u64) -> HashSet<u64> {
            self.adj.get(&qid).cloned().unwrap_or_default()
        }
    }

    #[test]
    fn udc_identical_zero() {
        assert_eq!(UDCTreeDistance::distance("004.42", "004.42"), 0.0);
    }

    #[test]
    fn udc_shared_prefix() {
        // "004.42" vs "004.5": lcp = "004.", len 4. len(a)=6, len(b)=5.
        // raw = (6-4) + (5-4) = 3. divisor = max(6,5) = 6. d = 3/6 = 0.5.
        let d = UDCTreeDistance::distance("004.42", "004.5");
        assert!((d - 3.0 / 6.0).abs() < 1e-9);
    }

    #[test]
    fn udc_no_common_prefix() {
        // "004" vs "37": lcp = "", raw = 3 + 2 = 5, divisor = max(3,2) = 3.
        // d = 5/3 ≈ 1.667. The glref oracle uses max(len_a, len_b) as divisor
        // which can exceed 1.0 when strings have no common prefix and differ
        // in length. This matches the canonical lattice.json vectors.
        let d = UDCTreeDistance::distance("004", "37");
        assert!((d - 5.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn udc_bounded_unit() {
        // Pairs where d ∈ [0.0, 1.0] (shared prefix keeps raw ≤ max_len).
        // Note: pairs with no common prefix and len_a ≠ len_b can exceed 1.0
        // per the glref formula — those are excluded from this bounded check.
        let pairs: &[(&str, &str)] = &[
            ("004.42", "004.5"),  // d = 0.5
            ("", "004"),          // max=3, raw=3, d=1.0
            ("004.42", ""),       // max=6, raw=6, d=1.0
            ("004", "004.42"),    // lcp="004", raw=0+3=3, max=6, d=0.5
            ("004.42", "004.42"), // identical → 0.0
        ];
        for &(a, b) in pairs {
            let d = UDCTreeDistance::distance(a, b);
            assert!(
                d >= 0.0 && d <= 1.0,
                "d={} for ({}, {}) is out of [0,1]",
                d, a, b
            );
        }
    }

    #[test]
    fn udc_empty_strings() {
        assert_eq!(UDCTreeDistance::distance("", ""), 0.0);
    }

    #[test]
    fn wikidata_identical_zero() {
        let g = MockGraph::new();
        assert_eq!(
            WikidataGraphDistance::distance(11_111, 11_111, &g, 4),
            0.0
        );
    }

    #[test]
    fn wikidata_null_qid_max_distance() {
        let g = MockGraph::new();
        assert_eq!(WikidataGraphDistance::distance(0, 11_111, &g, 4), 1.0);
        assert_eq!(WikidataGraphDistance::distance(11_111, 0, &g, 4), 1.0);
    }

    #[test]
    fn wikidata_distance_1_hop() {
        let mut g = MockGraph::new();
        g.edge(11_111, 22_222);
        // path length = 1; d = 1 - exp(-1/3) ≈ 0.2835.
        let d = WikidataGraphDistance::distance(11_111, 22_222, &g, 4);
        let expected = 1.0 - (-1.0 / 3.0_f64).exp();
        assert!((d - expected).abs() < 1e-9);
    }

    #[test]
    fn wikidata_distance_3_hop() {
        let mut g = MockGraph::new();
        g.edge(1, 2).edge(2, 3).edge(3, 4);
        // shortest path 1→4 is length 3; d = 1 - exp(-1) ≈ 0.6321.
        let d = WikidataGraphDistance::distance(1, 4, &g, 4);
        let expected = 1.0 - (-1.0_f64).exp();
        assert!((d - expected).abs() < 1e-9);
    }

    #[test]
    fn wikidata_distance_beyond_depth_returns_max() {
        let mut g = MockGraph::new();
        g.edge(1, 2).edge(2, 3).edge(3, 4).edge(4, 5).edge(5, 6);
        // Path 1→6 has length 5; max_depth = 4 ⇒ unreachable ⇒ 1.0.
        assert_eq!(WikidataGraphDistance::distance(1, 6, &g, 4), 1.0);
    }

    #[test]
    fn lattice_combined_reflexive() {
        let g = MockGraph::new();
        let a = LatticeAnchorStr::new("004.42", 11_111);
        let d = LatticeDistance::distance(&a, &a, &g, 0.5, 0.5);
        assert!(d.abs() < 1e-9);
    }

    #[test]
    fn lattice_combined_weighted() {
        let mut g = MockGraph::new();
        g.edge(11_111, 22_222);
        let a = LatticeAnchorStr::new("004.42", 11_111);
        let b = LatticeAnchorStr::new("004.5", 22_222);
        let d_udc = UDCTreeDistance::distance("004.42", "004.5");
        let d_qid = WikidataGraphDistance::distance(11_111, 22_222, &g, 4);
        let expected = 0.5 * d_udc + 0.5 * d_qid;
        let d = LatticeDistance::distance(&a, &b, &g, 0.5, 0.5);
        assert!((d - expected).abs() < 1e-9);
    }
}
