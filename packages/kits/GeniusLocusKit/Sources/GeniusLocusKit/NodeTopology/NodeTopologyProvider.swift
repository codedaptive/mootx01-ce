import Foundation

/// The host-side adapter protocol that exposes a strict node tree to the
/// GeniusLocusKit structural reasoner.
///
/// The substrate stores nothing about the host tree. Ids and shape are
/// host-owned; the substrate reads them once per recall start (G1) and
/// discards the snapshot when the recall completes. The tree never enters
/// any LocusKit, VectorKit, or CorpusKit table.
///
/// Topology boundary invariant (G4): this protocol declares EXACTLY three
/// methods — `parentID`, `childIDs`, and `treeEdges`. No content accessor
/// is present or will ever be added here. Any node-content need routes
/// through CorpusKit; this seam never widens (SPEC invariant I-G4).
///
/// Async/sync asymmetry (G3, sanctioned): Swift is async to be actor-friendly;
/// the Rust mirror trait is synchronous (no async runtime in the Rust port).
/// Conformance compares EDGE OUTPUT, not call shape. This mirrors the
/// NeuronKit policy-store precedent where Swift and Rust surface identical
/// value-level results despite different async shapes.
public protocol NodeTopologyProvider: Sendable {

    /// Return the parent node id of `nodeID`, or `nil` if `nodeID` is a root
    /// (has no parent). The tree is strict — each node has at most one parent.
    ///
    /// Used only for non-recall topology queries (parenthood checks, single-hop
    /// navigation). NOT called inside any deterministic recall path (G1): the
    /// recall path reads the tree exclusively through the frozen `treeEdges`
    /// snapshot.
    func parentID(of nodeID: String) async -> String?

    /// Return the direct children of `nodeID`. Returns an empty array when
    /// `nodeID` is a leaf or is not present in the tree.
    ///
    /// Used only for non-recall topology queries. NOT called inside any
    /// deterministic recall path (G1).
    func childIDs(of nodeID: String) async -> [String]

    /// Return the INDUCED edge set for the given scope.
    ///
    /// An induced edge is a parent-child pair where BOTH endpoints are members
    /// of `scope`. When `scope` is `nil`, the full forest is returned — every
    /// parent-child pair in the tree.
    ///
    /// This is the ONLY method the RecallDirector calls during a
    /// `.nodeTreeNative` recall. It is called EXACTLY ONCE at recall start
    /// (G1) and the result is frozen into the StructureGraph for the duration
    /// of that recall. No subsequent call to `parentID` or `childIDs` occurs
    /// inside any deterministic computation.
    ///
    /// Contract (LOCKED): the scope parameter is the induced edge definition —
    /// a pair (parent, child) is included if and only if both parent and child
    /// are in `scope`. Implementations must honour this contract; the substrate
    /// relies on it for correctness of the containment edge set.
    func treeEdges(scope: [String]?) async -> [(parent: String, child: String)]
}
