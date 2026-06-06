// node_topology.rs — Rust mirror of GeniusLocusKit NodeTopologyProvider.
//
// G3 — sanctioned async/sync asymmetry: The Swift protocol is async
// (actor-friendly, using `async func`). The Rust trait is synchronous
// because the Rust port uses no async runtime. Conformance is proved
// by comparing EDGE OUTPUT against a canonical fixed-edge test-double
// provider — the call shape difference does not affect the result.
// This mirrors the NeuronKit policy-store precedent.
//
// G4 — topology boundary invariant: this trait declares EXACTLY three
// methods (parent_id / child_ids / tree_edges) and NO content accessor.
// Any node-content need routes through CorpusKit. This seam will never
// be widened (SPEC invariant I-G4).

/// Host-side adapter giving GLK access to a strict parent-child node tree.
///
/// The substrate stores nothing about the host tree. Ids and shape are
/// host-owned; the substrate reads them once per recall start (G1) and
/// discards the snapshot when the recall completes.
///
/// Implementations must be `Send + Sync` so the coordinator can hold a
/// boxed reference across threaded call boundaries.
pub trait NodeTopologyProvider: Send + Sync {
    /// Return the parent node id of `node_id`, or `None` if `node_id` is
    /// a root (has no parent). The tree is strict — each node has at most
    /// one parent.
    ///
    /// Used only for non-recall topology queries. NOT called inside any
    /// deterministic recall path (G1).
    fn parent_id(&self, node_id: &str) -> Option<String>;

    /// Return the direct children of `node_id`. Returns an empty Vec when
    /// `node_id` is a leaf or is not present in the tree.
    ///
    /// Used only for non-recall topology queries. NOT called inside any
    /// deterministic recall path (G1).
    fn child_ids(&self, node_id: &str) -> Vec<String>;

    /// Return the INDUCED edge set for the given scope.
    ///
    /// An induced edge is a parent-child pair where BOTH endpoints are
    /// members of `scope`. When `scope` is `None`, the full forest is
    /// returned — every parent-child pair in the tree.
    ///
    /// This is the ONLY method the coordinator calls during a
    /// `NodeTreeNative` recall. It is called EXACTLY ONCE at recall start
    /// (G1) and the result is frozen into the StructureGraph for the duration
    /// of that recall. No subsequent call to `parent_id` or `child_ids`
    /// occurs inside any deterministic computation.
    ///
    /// Contract (LOCKED): a pair (parent, child) is included if and only if
    /// both parent and child are in `scope`. Implementations must honour this
    /// invariant.
    fn tree_edges(&self, scope: Option<&[String]>) -> Vec<(String, String)>;
}

/// In-memory test-double implementation of `NodeTopologyProvider`.
///
/// Holds an explicit parent-map (`node → parent`). Suitable for canonical
/// conformance tests (G2): fixed deterministic edges allow byte-identical
/// output comparison across Swift and Rust.
pub struct MemoryTopologyProvider {
    /// Map from each node id to its parent id. Nodes with no entry are roots.
    parent_map: std::collections::HashMap<String, String>,
}

impl MemoryTopologyProvider {
    /// Construct a provider from a list of (child, parent) pairs.
    ///
    /// Each pair `(child, parent)` asserts that `parent` is the direct
    /// parent of `child`. Roots are absent from the list (no parent entry).
    pub fn new(edges: impl IntoIterator<Item = (String, String)>) -> Self {
        let parent_map: std::collections::HashMap<String, String> =
            edges.into_iter().map(|(child, parent)| (child, parent)).collect();
        Self { parent_map }
    }
}

impl NodeTopologyProvider for MemoryTopologyProvider {
    fn parent_id(&self, node_id: &str) -> Option<String> {
        self.parent_map.get(node_id).cloned()
    }

    fn child_ids(&self, node_id: &str) -> Vec<String> {
        self.parent_map
            .iter()
            .filter_map(|(child, parent)| {
                if parent == node_id {
                    Some(child.clone())
                } else {
                    None
                }
            })
            .collect()
    }

    fn tree_edges(&self, scope: Option<&[String]>) -> Vec<(String, String)> {
        match scope {
            None => {
                // Full forest: every parent-child pair in the tree.
                self.parent_map
                    .iter()
                    .map(|(child, parent)| (parent.clone(), child.clone()))
                    .collect()
            }
            Some(scope_ids) => {
                // Induced edge set: both endpoints must be in scope.
                let scope_set: std::collections::HashSet<&str> =
                    scope_ids.iter().map(|s| s.as_str()).collect();
                self.parent_map
                    .iter()
                    .filter_map(|(child, parent)| {
                        if scope_set.contains(child.as_str())
                            && scope_set.contains(parent.as_str())
                        {
                            Some((parent.clone(), child.clone()))
                        } else {
                            None
                        }
                    })
                    .collect()
            }
        }
    }
}
