// node_topology_parity.rs
//
// Acceptance gate tests for NodeTopologyProvider (Rust port).
//
// Swift reference: Sources/GeniusLocusKit/NodeTopology/NodeTopologyProvider.swift
//                  Tests/GeniusLocusKitTests/NodeTopologyProviderTests.swift
//
// These tests are the Rust half of the §6 acceptance gates. They verify:
//
//   NT-1  MemoryTopologyProvider: parent_id returns the correct parent.
//   NT-2  MemoryTopologyProvider: child_ids returns the correct children.
//   NT-3  MemoryTopologyProvider: tree_edges(None) returns the full forest.
//   NT-4  MemoryTopologyProvider: tree_edges(scope) returns the induced edge set
//         — only edges where BOTH endpoints are in scope (G4 locked contract).
//   NT-5  Roots have no parent (parent_id returns None for root nodes).
//   NT-6  Leaves have no children (child_ids returns [] for leaf nodes).
//   NT-7  tree_edges(Some(&[])) — empty scope → empty edge set.
//
// Conformance with Swift is proved by feeding identical edge input to
// MemoryTopologyProvider (Rust) and InstrumentedTopologyProvider (Swift)
// and asserting the same edge count and membership. The canonical test tree is:
//
//   root → A, root → B, A → C, B → D
//
// This matches the `smallTree()` helper in NodeTopologyProviderTests.swift.

use genius_locus_kit::node_topology::MemoryTopologyProvider;
use genius_locus_kit::NodeTopologyProvider;

/// Build the canonical 4-edge test tree: root→A, root→B, A→C, B→D.
///
/// This matches `smallTree()` in NodeTopologyProviderTests.swift so edge
/// output can be compared across the Swift and Rust implementations.
fn small_tree() -> MemoryTopologyProvider {
    // Constructor takes (child, parent) pairs per the MemoryTopologyProvider API.
    MemoryTopologyProvider::new([
        ("A".to_string(), "root".to_string()),
        ("B".to_string(), "root".to_string()),
        ("C".to_string(), "A".to_string()),
        ("D".to_string(), "B".to_string()),
    ])
}

// NT-1: parent_id returns the correct parent for interior nodes.
#[test]
fn nt1_parent_id_returns_correct_parent() {
    let p = small_tree();
    assert_eq!(p.parent_id("A"), Some("root".to_string()), "A's parent should be root");
    assert_eq!(p.parent_id("B"), Some("root".to_string()), "B's parent should be root");
    assert_eq!(p.parent_id("C"), Some("A".to_string()),    "C's parent should be A");
    assert_eq!(p.parent_id("D"), Some("B".to_string()),    "D's parent should be B");
}

// NT-2: child_ids returns the correct children for interior nodes.
#[test]
fn nt2_child_ids_returns_correct_children() {
    let p = small_tree();
    let mut root_children = p.child_ids("root");
    root_children.sort();
    assert_eq!(root_children, vec!["A", "B"], "root should have children A and B");

    let a_children = p.child_ids("A");
    assert_eq!(a_children, vec!["C"], "A should have child C");

    let b_children = p.child_ids("B");
    assert_eq!(b_children, vec!["D"], "B should have child D");
}

// NT-3: tree_edges(None) returns the full forest — all 4 edges.
#[test]
fn nt3_tree_edges_none_returns_full_forest() {
    let p = small_tree();
    let edges = p.tree_edges(None);
    assert_eq!(edges.len(), 4, "full forest should have 4 edges, got {}", edges.len());

    // Verify each expected edge is present.
    let edge_set: std::collections::HashSet<(String, String)> =
        edges.into_iter().collect();
    assert!(edge_set.contains(&("root".to_string(), "A".to_string())), "root→A should be present");
    assert!(edge_set.contains(&("root".to_string(), "B".to_string())), "root→B should be present");
    assert!(edge_set.contains(&("A".to_string(),    "C".to_string())), "A→C should be present");
    assert!(edge_set.contains(&("B".to_string(),    "D".to_string())), "B→D should be present");
}

// NT-4: tree_edges with a scope returns the induced edge set.
//
// Scope {root, A, C} includes root→A and A→C but excludes root→B (B∉scope)
// and B→D (B,D∉scope). This mirrors the Swift
// nodeTreeNative_treeEdgesScope_inducedSubset test.
#[test]
fn nt4_tree_edges_scope_returns_induced_edge_set() {
    let p = small_tree();
    let scope = vec!["root".to_string(), "A".to_string(), "C".to_string()];
    let edges = p.tree_edges(Some(&scope));

    assert_eq!(edges.len(), 2, "induced scope {{root, A, C}} should have 2 edges, got {}", edges.len());

    let edge_set: std::collections::HashSet<(String, String)> =
        edges.into_iter().collect();
    assert!(edge_set.contains(&("root".to_string(), "A".to_string())),
        "root→A should be in induced scope {{root, A, C}}");
    assert!(edge_set.contains(&("A".to_string(),    "C".to_string())),
        "A→C should be in induced scope {{root, A, C}}");
    assert!(!edge_set.contains(&("root".to_string(), "B".to_string())),
        "root→B should NOT be in induced scope (B∉scope)");
    assert!(!edge_set.contains(&("B".to_string(),    "D".to_string())),
        "B→D should NOT be in induced scope (B,D∉scope)");
}

// NT-5: root nodes have no parent (parent_id returns None).
#[test]
fn nt5_roots_have_no_parent() {
    let p = small_tree();
    assert_eq!(p.parent_id("root"), None, "root should have no parent");
    // An unknown node also has no parent.
    assert_eq!(p.parent_id("nonexistent"), None, "unknown node should have no parent");
}

// NT-6: leaf nodes have no children (child_ids returns empty Vec).
#[test]
fn nt6_leaves_have_no_children() {
    let p = small_tree();
    assert!(p.child_ids("C").is_empty(), "C is a leaf — should have no children");
    assert!(p.child_ids("D").is_empty(), "D is a leaf — should have no children");
    assert!(p.child_ids("nonexistent").is_empty(), "unknown node should have no children");
}

// NT-7: tree_edges(Some(&[])) — empty scope returns empty edge set.
//
// No edge can have both endpoints in an empty scope.
#[test]
fn nt7_tree_edges_empty_scope_returns_empty() {
    let p = small_tree();
    let edges = p.tree_edges(Some(&[]));
    assert!(edges.is_empty(),
        "empty scope should produce empty induced edge set, got {} edges", edges.len());
}
