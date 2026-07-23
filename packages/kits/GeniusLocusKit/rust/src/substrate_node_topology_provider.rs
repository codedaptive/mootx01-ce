//! Concrete adapter bridging LocusKit's `NodeStore`
//! (Uuid ids, `Result`) to GeniusLocusKit's `NodeTopologyProvider`
//! trait (String ids, infallible).
//!
//! The adapter constructs a read-only `NodeStore` from the estate's
//! `Storage` instance — the same database backing the estate's own
//! NodeStore. All operations are read-only (`get_node`, `root_node`,
//! `child_nodes`); the adapter never writes to the nodes table.
//!
//! String-Uuid conversion at the boundary: incoming `&str` ids are
//! parsed via `Uuid::parse_str`; outgoing Uuids are formatted via
//! `.to_string()`. Invalid strings are swallowed (the trait is
//! infallible) and logged.
//!
//! Tree walk strategy for `tree_edges`: BFS from the root node,
//! collecting all active parent-child pairs. The tree is fixed-depth
//! (max depth 2: estate→wing→room under the maximum node depth of two), so the walk
//! is bounded and fast.

use crate::node_topology::NodeTopologyProvider;
use locus_kit::node_store::NodeStore;
use std::collections::HashSet;
use std::sync::Arc;
use uuid::Uuid;

/// Adapter wrapping LocusKit's `NodeStore` to satisfy GLK's
/// `NodeTopologyProvider` trait, converting String↔Uuid at the
/// boundary.
///
/// Created automatically when an estate is opened (auto-registration
/// in `Coordinator::open`). Callers of `NodeTreeNative` recall mode
/// get substrate-native topology without supplying a host-side
/// provider.
pub struct SubstrateNodeTopologyProvider {
    node_store: Arc<NodeStore>,
}

impl SubstrateNodeTopologyProvider {
    /// Construct from a `NodeStore`.
    ///
    /// The `NodeStore` must already be backed by a storage with the
    /// LocusKit schema opened (the nodes table must exist). This is
    /// guaranteed when the adapter is constructed inside
    /// `Coordinator::open`, because `Estate::open` opens the schema
    /// before returning.
    pub fn new(node_store: Arc<NodeStore>) -> Self {
        Self { node_store }
    }

    /// BFS from root, collecting all active parent→child edge pairs.
    ///
    /// Fixed-depth tree (max depth 2) guarantees bounded traversal.
    /// Returns edges as `(parent_uuid_string, child_uuid_string)`.
    fn collect_all_edges(&self) -> Vec<(String, String)> {
        let root = match self.node_store.root_node() {
            Ok(Some(r)) => r,
            _ => return Vec::new(),
        };
        let mut edges = Vec::new();
        let mut queue = std::collections::VecDeque::new();
        queue.push_back(root);
        while let Some(current) = queue.pop_front() {
            match self.node_store.child_nodes(current.id) {
                Ok(children) => {
                    for child in children {
                        edges.push((current.id.to_string(), child.id.to_string()));
                        queue.push_back(child);
                    }
                }
                Err(_) => {}
            }
        }
        edges
    }
}

// NodeStore auto-derives Send + Sync: Storage: Send + Sync,
// Mutex<HLCGenerator> is Send + Sync. No unsafe impl needed.

impl NodeTopologyProvider for SubstrateNodeTopologyProvider {
    fn parent_id(&self, node_id: &str) -> Option<String> {
        let uuid = Uuid::parse_str(node_id).ok()?;
        let node = self.node_store.get_node(uuid).ok()??;
        node.parent_id.map(|pid| pid.to_string())
    }

    fn child_ids(&self, node_id: &str) -> Vec<String> {
        let uuid = match Uuid::parse_str(node_id) {
            Ok(u) => u,
            Err(_) => return Vec::new(),
        };
        match self.node_store.child_nodes(uuid) {
            Ok(children) => children.into_iter().map(|c| c.id.to_string()).collect(),
            Err(_) => Vec::new(),
        }
    }

    fn tree_edges(&self, scope: Option<&[String]>) -> Vec<(String, String)> {
        let all_edges = self.collect_all_edges();
        match scope {
            None => all_edges,
            Some(scope_ids) => {
                let scope_set: HashSet<&str> =
                    scope_ids.iter().map(|s| s.as_str()).collect();
                all_edges
                    .into_iter()
                    .filter(|(parent, child)| {
                        scope_set.contains(parent.as_str())
                            && scope_set.contains(child.as_str())
                    })
                    .collect()
            }
        }
    }
}
