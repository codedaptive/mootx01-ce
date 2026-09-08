// HNSWIndex.swift
//
// Hierarchical Navigable Small World approximate nearest-neighbour index
// for the float lane (Lane D).
//
// Architecture (HNSW_DESIGN.md §2 + §4):
//   The graph is a layered navigable small-world structure. Every vector is a
//   node; each node keeps a short neighbour list per layer. The top layer is
//   sparse with long hops, the bottom layer (0) holds every node. A search
//   enters at the top, greedily hops toward the query, drops one layer, and
//   repeats until it reaches layer 0, where it collects efSearch candidates.
//   Cost grows logarithmically in corpus size; brute-force grows linearly.
//
// Design rulings:
//   - Float lane ONLY. Binary lane (A/B) is untouched; it is already exact.
//   - Cross-port determinism NOT required. Any valid HNSW graph answers
//     correctly; the Swift and Rust graphs legitimately differ (HNSW_DESIGN §7).
//   - Within-port reproducibility IS required. SplitMix64 seeded at index
//     creation so the same seed + insertion order yields the same graph.
//   - CROSS-RUN identity for BULK builds (SPEC 1.10.0): every bulk rebuild
//     (compact() here; VectorStore.rebuildHNSWIndex at the store) inserts rows
//     in content-stable order — (fnv1a64(payload bytes) ASC, itemID ASC) — so
//     identical content yields an identical graph across independent builds
//     even though item UUIDs differ per provisioning. Incremental single-row
//     inserts keep ARRIVAL order: only bulk rebuilds guarantee cross-run
//     identity; the next THETA rebuild converges an incrementally-grown graph.
//   - Crossover threshold: 5,000 vectors per modelID partition. Below this
//     count FloatBruteForceIndex is faster (see §Crossover below).
//   - Nearest only. Farthest queries still use FloatBruteForceIndex regardless
//     of corpus size — anti-similarity with HNSW requires a full-graph scan
//     and provides no speed benefit.
//
// Storage contract (HNSW_DESIGN §3):
//   The graph (neighbour lists) lives in the `hnsw_graph` SQLite table as
//   packed Int32 BLOBs. Vectors are owned by the HNSWIndex itself (flat float
//   byte array per node). At/above the threshold, VectorStore routes nearest-
//   float queries through HNSWIndex; below it, FloatBruteForceIndex is used.
//
// Cadence duties (HNSW_DESIGN §5):
//   ALPHA  (30 s)  — extreme vocabulary drift clears the index; rebuild is lazy.
//   THETA  (24 h)  — basis retrain → re-embed → graph rebuild, ONE operation.
//   BETA   (7 d)   — tombstone sweep + compact (wear, not staleness).
//   OMEGA  (14 d)  — unchanged (retires dreamed tunnels, not graph nodes).
//
// Sync policy (HNSW_DESIGN §6):
//   hnsw_graph table is NEVER included in ConvergenceKit sync exports.
//   The graph is a rebuildable derived accelerator; device-local only.
//
// Crossover threshold rationale (measured, then confirmed by calculation):
//   At M=16, efSearch=50, HNSW visits ≈ efSearch × log₂(n) nodes per search.
//   At n=5000: HNSW comparisons ≈ 50 × 12.2 ≈ 610 vs brute-force 5000.
//   Below 5000 the graph construction overhead + pointer-chasing overhead
//   outweighs the scan reduction. 5000 is a conservative crossover; tests
//   confirm ≥90% recall@10 at this threshold.
//
// Default parameters (HNSW_DESIGN §8, Malkov & Yashunin 2018):
//   M              = 16   (max connections per layer; 2×M at layer 0)
//   efConstruction = 100  (beam width during insert)
//   efSearch       = 50   (beam width during search)
//   seed           = 42   (SplitMix64 initial state; overridable in tests)

import Foundation
import MootProductIdentity
import OSLog

private let hnswLog = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "SynapseKit.HNSWIndex")

// MARK: - HNSW tuning constants (public — exposed so VectorStore can log them)

/// Max connections per node per layer (layers 1+). Layer 0 uses `hnswM0 = 2 × hnswM`.
/// M=16 is optimal for high-dimensional embedding spaces (Malkov & Yashunin 2018 §4.1).
public let hnswM: Int = 16

/// Max connections at layer 0. Always 2 × M (per-paper recommendation).
public let hnswM0: Int = hnswM * 2

/// Level multiplier for probabilistic level assignment: 1/ln(M).
/// Controls the expected number of layers; smaller mL = fewer, denser layers.
let hnswML: Double = 1.0 / log(Double(hnswM))

/// Beam width during index construction. Higher = better graph quality, slower build.
/// efConstruction=100 is the paper's default for M=16.
public let hnswEfConstruction: Int = 100

/// Beam width during search. Higher = better recall, slower query.
/// efSearch=50 achieves ≥90% recall@10 for M=16 at n≥5,000.
public let hnswEfSearch: Int = 50

/// Vector count per modelID partition above which HNSWIndex activates.
/// Below this threshold FloatBruteForceIndex is faster (see file header §Crossover).
public let hnswDefaultThreshold: UInt32 = 5_000

/// Upper bound accepted for a persisted `hnsw_graph.layer` value (VH-01
/// Finding C). Persisted graph rows are UNTRUSTED input; `layer` sizes the
/// per-node neighbour-layer allocation, so it must be capped consistently
/// with the index's own level generation: `assignLevel` draws
/// `floor(-ln(u) × mL)` with mL = 1/ln(16) ≈ 0.3607, so
/// P(level ≥ 32) = exp(-32/mL) ≈ 3e-39 — an honest graph can never persist
/// a layer this high. Any row above the cap is structurally invalid.
public let hnswMaxPersistedLayer: Int = 32

// MARK: - HNSWIndex

/// Approximate nearest-neighbour index for the float32 dense lane (Lane D).
///
/// Implements HNSW (Malkov & Yashunin 2018) over resident float32 vectors. Owns
/// both the graph structure (neighbour lists, megabytes) and the flat vector bytes
/// (for distance computation without a separate vector store lookup). At/above the
/// crossover threshold VectorStore routes nearest-float queries here; below the
/// threshold FloatBruteForceIndex is the active index.
///
/// This is an APPROXIMATE index. FloatBruteForceIndex is the conformance oracle.
/// Tests compare recall quality: HNSW must find ≥90% of the oracle's top-k results.
///
/// Thread-safety: actor. Mutation (insert, tombstone, compact, clear) is actor-
/// isolated. Search is read-only over the current frozen state.
public actor HNSWIndex {

    // MARK: - Node storage

    /// One node in the HNSW graph.
    ///
    /// Owns the float vector bytes so search can compute distances without
    /// fetching from SQLite. `neighbours[l]` = list of node indices at layer l.
    struct Node: Sendable {
        /// item_id from the originating VectorRecordKey.
        let itemID: String
        /// model_id from the originating VectorRecordKey.
        let modelID: String
        /// IEEE-754 LE float32 bytes (same format as VectorPayload.bytes).
        let vectorBytes: [UInt8]
        /// FNV-1a 64 over `vectorBytes` — the content-derived tie key shared
        /// with every k-NN engine (SPEC 1.10.0). Computed once at node
        /// construction; used by the neighbour-truncation cuts in `insert`
        /// and by the content-stable bulk rebuild order in `compact`.
        /// Placeholder tombstones (empty bytes) carry the hash of the empty
        /// sequence — never compared, because tombstones are skipped.
        let vecHash: UInt64
        /// `neighbours[l]` = array of node indices (Int32) at layer l.
        /// Layer 0 (the densest) has up to M0 connections; layers ≥1 have up to M.
        var neighbours: [[Int32]]
        /// True once tombstoned. Excluded from search; compacted out on next compact().
        var tombstoned: Bool = false
    }

    /// All nodes in insertion order. A node's array index is its graph node_id (Int32).
    private var nodes: [Node] = []

    /// itemID → node array index. O(1) lookup by item_id.
    private var nodeIndex: [String: Int32] = [:]

    /// Current graph entry point (top-layer seed for search). Nil when empty.
    private var entryPoint: Int32? = nil

    /// Highest layer currently in use (0 = all nodes at layer 0 only).
    private var maxLayer: Int = 0

    // MARK: - Generation identity (shadow-swap)

    /// Shadow-swap generation this graph was built or loaded for. Fixed at
    /// build time (insert path: stays 0 until VectorStore.publishShadowGeneration
    /// calls setGeneration) or load time (loadFromGraphRows sets it from the
    /// expectedGeneration parameter). A generation mismatch at query time means
    /// this graph does not represent the current serving set — treat as absent
    /// and fall back to exact scan (§4 of the design contract).
    private var _generation: Int64 = 0

    /// Read-only generation identity exposed to VectorStore for the query-site
    /// mismatch check and the lastServedGraphGeneration probe.
    public var generation: Int64 { _generation }

    /// Stamp this graph instance with the given generation. Called by
    /// VectorStore after a full HNSW rebuild completes (insert path) or
    /// after publishShadowGeneration commits the serving-gen flip.
    public func setGeneration(_ gen: Int64) {
        _generation = gen
    }

    // MARK: - RNG (SplitMix64 — same algorithm as GauntletRNG)

    /// SplitMix64 state. Seeded at init; same seed + insertion order → same graph.
    private var rngState: UInt64

    // MARK: - Stride

    /// Byte count per vector (float32 stride = dim × 4). Set on first insert.
    /// Nil before any node is inserted.
    private var vectorStride: Int? = nil

    /// Float dimensionality. Derived from vectorStride.
    private var dim: Int { (vectorStride ?? 0) / 4 }

    // MARK: - Observability

    /// Total node count (including tombstoned).
    public var totalCount: Int { nodes.count }

    /// Live (non-tombstoned) node count.
    public var liveCount: Int { nodes.filter { !$0.tombstoned }.count }

    // MARK: - Init

    /// Construct an empty HNSW index.
    ///
    /// - Parameter seed: SplitMix64 initial state. Default 42. Override in
    ///   tests to explore different graph shapes with the same data set.
    public init(seed: UInt64 = 42) {
        self.rngState = seed
    }

    // MARK: - SplitMix64 RNG

    /// Advance state and return the next pseudorandom UInt64.
    ///
    /// SplitMix64 (Vigna 2015): one-state, zero-avalanche, good statistical
    /// properties. Identical algorithm to GauntletRNG and RandomIndexingProvider
    /// in the fleet — chosen for consistency.
    private func nextRandom() -> UInt64 {
        rngState &+= 0x9e3779b97f4a7c15
        var z: UInt64 = rngState
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// Draw a HNSW node level from the geometric distribution.
    ///
    /// Formula: `floor(-ln(u) × mL)` where u ~ Uniform(0,1), mL = 1/ln(M).
    /// Always ≥ 0 (every node appears at layer 0). Approximately 1/M of nodes
    /// appear at layer 1, 1/M² at layer 2, and so on.
    private func assignLevel() -> Int {
        // Map UInt64 to uniform (0,1) using top 53 bits (IEEE-754 double mantissa).
        let u = Double(nextRandom() >> 11) * (1.0 / Double(1 << 53))
        let level = Int(-log(max(u, 1e-15)) * hnswML)
        return max(0, level)
    }

    // MARK: - Distance computation

    /// Cosine distance between a [Float] probe and the bytes of node `idx`.
    ///
    /// cosine distance = 1 − cos(a,b). Range [0,2]; 0 = identical direction.
    /// Returns 1.0 for zero-norm vectors (safe maximum-distance fallback).
    private func cosineDistanceToNode(probe: [Float], nodeIdx: Int) -> Float {
        let bytes = nodes[nodeIdx].vectorBytes
        let d = dim
        guard d > 0, bytes.count == d * 4, probe.count == d else { return 1.0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<d {
            let a = probe[i]
            let b = floatFromBytes(bytes, at: i)
            dot   += a * b
            normA += a * a
            normB += b * b
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 0 else { return 1.0 }
        let sim = (dot / denom).clamped(to: -1.0...1.0)
        return 1.0 - sim
    }

    // MARK: - Truncation total order

    /// Total order used wherever a candidate list is CUT to a neighbour cap
    /// during graph construction: (dist ASC, vecHash ASC, itemID ASC).
    ///
    /// This is the universal tie-break key (SPEC 1.10.0): a raw index-order
    /// cut at the cap boundary would break ties by internal node index —
    /// i.e. by arrival order — making the wired topology depend on which of
    /// two equidistant nodes happened to be inserted first. The content hash
    /// makes the cut identical across independent builds of the same content;
    /// itemID remains the final backstop for byte-identical vectors, which
    /// are interchangeable for every ordering consumer.
    private func truncationOrdered(
        _ a: (dist: Float, idx: Int32), _ b: (dist: Float, idx: Int32)
    ) -> Bool {
        if a.dist != b.dist { return a.dist < b.dist }
        let na = nodes[Int(a.idx)], nb = nodes[Int(b.idx)]
        if na.vecHash != nb.vecHash { return na.vecHash < nb.vecHash }
        return na.itemID < nb.itemID
    }

    /// Decode one IEEE-754 LE float32 from byte array at index i.
    private func floatFromBytes(_ bytes: [UInt8], at i: Int) -> Float {
        let base = i * 4
        let bits = UInt32(bytes[base])
            | (UInt32(bytes[base + 1]) << 8)
            | (UInt32(bytes[base + 2]) << 16)
            | (UInt32(bytes[base + 3]) << 24)
        return Float(bitPattern: bits)
    }

    // MARK: - searchLayer (core graph traversal)

    /// Greedy best-first search within one HNSW layer.
    ///
    /// Implements the `SEARCH-LAYER(q, ep, ef, lc)` function from Malkov &
    /// Yashunin Algorithm 2. Returns up to `ef` nearest candidates to `probe`
    /// at layer `layer`, sorted by cosine distance ascending.
    ///
    /// For small ef (default 50–200) a sorted Array is faster than a heap
    /// because element counts are bounded and branch prediction dominates.
    private func searchLayer(
        probe: [Float],
        entryPts: [Int32],
        ef: Int,
        layer: Int
    ) -> [(dist: Float, idx: Int32)] {

        var visited = Set<Int32>(minimumCapacity: ef * 2)

        /// `candidates`: min-heap ordered by dist (nearest-first, popped from front).
        /// `results`: the ef-nearest found so far, dist ascending (farthest at .last).
        var candidates: [(dist: Float, idx: Int32)] = []
        var results:    [(dist: Float, idx: Int32)] = []

        // Sorted insert helper: insert `item` into a dist-ascending array.
        func insertSortedAsc(into arr: inout [(dist: Float, idx: Int32)],
                             item: (dist: Float, idx: Int32)) {
            // Binary search for insertion point.
            var lo = 0, hi = arr.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if arr[mid].dist <= item.dist { lo = mid + 1 } else { hi = mid }
            }
            arr.insert(item, at: lo)
        }

        // Seed with entry points.
        for ep in entryPts {
            let epInt = Int(ep)
            guard epInt < nodes.count, !nodes[epInt].tombstoned else { continue }
            visited.insert(ep)
            let d = cosineDistanceToNode(probe: probe, nodeIdx: epInt)
            insertSortedAsc(into: &candidates, item: (d, ep))
            insertSortedAsc(into: &results,    item: (d, ep))
        }

        while !candidates.isEmpty {
            // Pop nearest candidate.
            let c = candidates.removeFirst()
            // farthest in results set.
            let fDist = results.last?.dist ?? Float.infinity

            // Early exit: even the closest unexplored candidate is farther than the
            // farthest result we already have. Greedy exploration is complete.
            if c.dist > fDist { break }

            let cInt = Int(c.idx)
            guard cInt < nodes.count else { continue }
            let node = nodes[cInt]
            if layer < node.neighbours.count {
                for nIdx in node.neighbours[layer] {
                    guard !visited.contains(nIdx) else { continue }
                    let nInt = Int(nIdx)
                    guard nInt < nodes.count, !nodes[nInt].tombstoned else { continue }
                    visited.insert(nIdx)
                    let nd = cosineDistanceToNode(probe: probe, nodeIdx: nInt)
                    let fDist2 = results.last?.dist ?? Float.infinity
                    if nd < fDist2 || results.count < ef {
                        insertSortedAsc(into: &candidates, item: (nd, nIdx))
                        insertSortedAsc(into: &results,    item: (nd, nIdx))
                        if results.count > ef { results.removeLast() }
                    }
                }
            }
        }

        return results
    }

    // MARK: - Insert

    /// Insert a float32 vector into the HNSW graph (incremental, O(log n)).
    ///
    /// If `itemID` is already present, the existing node is tombstoned and a
    /// new node is inserted (upsert behaviour, matching VectorStore's UNIQUE
    /// constraint on (item_id, vector_index, model_id)).
    ///
    /// - Parameters:
    ///   - itemID: item_id from the VectorRecordKey.
    ///   - modelID: model_id from the VectorRecordKey.
    ///   - vector: float32 values. Must have the same dimensionality as all
    ///     previously inserted vectors. Mismatched dim logs a warning and no-ops.
    public func insert(itemID: String, modelID: String, vector: [Float]) {
        // Upsert: tombstone any existing node for this itemID. If that node
        // was the graph entry point, repair immediately — a tombstoned seed
        // is skipped by searchLayer and would produce zero neighbours for the
        // replacement, AND the dim-mismatch early-return path below also
        // leaves the tombstone without a repair (VH-01 Finding B mirror).
        if let existingIdx = nodeIndex[itemID] {
            nodes[Int(existingIdx)].tombstoned = true
            repairEntryPoint()
        }

        let byteCount = vector.count * 4
        if let vs = vectorStride, byteCount != vs {
            hnswLog.warning("HNSWIndex.insert: dimension mismatch; expected \(vs / 4) floats, got \(vector.count). Skipped.")
            return
        }
        if vectorStride == nil { vectorStride = byteCount }

        // Pack float32 to LE bytes (VectorPayload byte order).
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for (i, f) in vector.enumerated() {
            let bits = f.bitPattern
            bytes[i * 4]     = UInt8(bits        & 0xFF)
            bytes[i * 4 + 1] = UInt8((bits >> 8)  & 0xFF)
            bytes[i * 4 + 2] = UInt8((bits >> 16) & 0xFF)
            bytes[i * 4 + 3] = UInt8((bits >> 24) & 0xFF)
        }

        let level = assignLevel()
        let newIdx = Int32(nodes.count)

        // Allocate the node with `level + 1` empty neighbour layers.
        let emptyLayers = [[Int32]](repeating: [], count: level + 1)
        nodes.append(Node(
            itemID: itemID, modelID: modelID,
            vectorBytes: bytes, vecHash: fnv1a64(bytes), neighbours: emptyLayers
        ))
        nodeIndex[itemID] = newIdx

        guard let ep = entryPoint else {
            // First node: becomes entry point at the assigned level.
            entryPoint = newIdx
            maxLayer = level
            return
        }

        var curEP = ep
        let curMaxLayer = maxLayer

        // Search from the top down to `level+1` to find the best layer-`level` entry.
        if curMaxLayer > level {
            for lc in (level + 1 ... curMaxLayer).reversed() {
                let cands = searchLayer(probe: vector, entryPts: [curEP], ef: 1, layer: lc)
                if let nearest = cands.first { curEP = nearest.idx }
            }
        }

        // Wire connections at each layer from min(level, curMaxLayer) down to 0.
        let topWireLayer = min(level, curMaxLayer)
        if topWireLayer >= 0 {
            for lc in (0 ... topWireLayer).reversed() {
                var cands = searchLayer(
                    probe: vector, entryPts: [curEP], ef: hnswEfConstruction, layer: lc
                )
                // Truncation cut at mMax: (dist, vecHash, itemID) total order so
                // ties at the cap boundary do not fall to arrival order.
                cands.sort { truncationOrdered($0, $1) }
                let mMax = lc == 0 ? hnswM0 : hnswM
                let selected = cands.prefix(mMax)

                // Set new node's neighbours at this layer.
                nodes[Int(newIdx)].neighbours[lc] = selected.map { $0.idx }

                // Add back-connections from each selected neighbour to the new node.
                for nbr in selected {
                    let nInt = Int(nbr.idx)
                    guard nInt < nodes.count, !nodes[nInt].tombstoned else { continue }
                    guard lc < nodes[nInt].neighbours.count else { continue }
                    var nNeighbours = nodes[nInt].neighbours[lc]
                    if nNeighbours.count < mMax {
                        nNeighbours.append(newIdx)
                    } else {
                        // Back-edge shrink: evict the weakest neighbour to stay ≤ mMax.
                        // Compute neighbour-to-all-candidates distances from nInt's position.
                        let nProbe = nodeFloats(nInt)
                        var conns: [(dist: Float, idx: Int32)] = nNeighbours.compactMap { cidx in
                            let ci = Int(cidx)
                            guard ci < nodes.count, !nodes[ci].tombstoned else { return nil }
                            return (cosineDistanceToNode(probe: nProbe, nodeIdx: ci), cidx)
                        }
                        conns.append((cosineDistanceToNode(probe: nProbe, nodeIdx: Int(newIdx)), newIdx))
                        // Same truncation total order as the forward-edge cut above.
                        conns.sort { truncationOrdered($0, $1) }
                        nNeighbours = Array(conns.prefix(mMax).map { $0.idx })
                    }
                    nodes[nInt].neighbours[lc] = nNeighbours
                }

                // The nearest at this layer is the entry point for the next lower layer.
                if let nearest = selected.first { curEP = nearest.idx }
            }
        }

        // Promote entry point if the new node's level is higher.
        if level > curMaxLayer {
            entryPoint = newIdx
            maxLayer = level
        }
    }

    // MARK: - Search

    /// Find the k approximate nearest neighbours (cosine metric).
    ///
    /// Traverses the layered graph from the top layer to layer 0, collecting
    /// `efSearch` candidates at layer 0 via greedy best-first. Filters to
    /// `modelID` and returns the top k.
    ///
    /// Distance convention: `Int((cosineDistance × 10_000).rounded())` —
    /// matches VectorMatch.distance in the float lane (same as FloatBruteForceIndex
    /// path in VectorStore._findNearestFloatCached).
    ///
    /// - Parameters:
    ///   - probe: float32 query vector. Must match the index's dimensionality.
    ///   - modelID: model partition to search (only nodes with this modelID returned).
    ///   - k: number of nearest neighbours to return.
    /// - Returns: up to k VectorMatch values, sorted by distance ascending.
    /// - Throws: SynapseKitError.invalidPayload if probe dimension mismatches.
    public func search(probe: [Float], modelID: String, k: Int) throws -> [VectorMatch] {
        guard liveCount > 0, k > 0 else { return [] }
        guard let ep = entryPoint else { return [] }

        if let vs = vectorStride, probe.count * 4 != vs {
            throw SynapseKitError.invalidPayload(
                "HNSWIndex.search: probe has \(probe.count) floats; expected \(vs / 4)"
            )
        }

        var curEP = ep
        // Upper layers: single-candidate greedy descent to the layer-0 entry point.
        if maxLayer > 0 {
            for lc in (1 ... maxLayer).reversed() {
                let cands = searchLayer(probe: probe, entryPts: [curEP], ef: 1, layer: lc)
                if let nearest = cands.first { curEP = nearest.idx }
            }
        }

        // Layer 0: collect efSearch candidates.
        let cands = searchLayer(probe: probe, entryPts: [curEP], ef: hnswEfSearch, layer: 0)

        // Filter to modelID, take top k, convert distances.
        // D5: carry the graph's own generation in every returned VectorMatch so
        // callers (VectorStore._findNearestFloatCached) can verify generation parity.
        // The graph's generation is fixed at build/load time via setGeneration and
        // never changes while the graph is resident — reading it once here is correct.
        let graphGeneration = _generation
        return cands
            .filter { nodes[Int($0.idx)].modelID == modelID }
            .prefix(k)
            .map { c in
                let node = nodes[Int(c.idx)]
                let dist = Int((c.dist * 10_000).rounded())
                return VectorMatch(itemID: node.itemID, distance: dist, modelID: node.modelID, generation: graphGeneration)
            }
    }

    // MARK: - Maintenance duties

    /// Tombstone a node by item_id (pre-step for BETA compaction).
    ///
    /// Tombstoned nodes are excluded from search results and skipped during
    /// graph traversal. Dead edges pointing to a tombstone are not immediately
    /// removed; they are cleaned up during the next compact() call. This is
    /// the "wear" model from HNSW_DESIGN §5: tombstones accumulate until BETA.
    public func tombstone(itemID: String) {
        guard let idx = nodeIndex[itemID] else { return }
        nodes[Int(idx)].tombstoned = true
        // Entry-point invariant (VH-01 Finding B): tombstoning the entry node
        // must re-seed the entry point, or search goes dark for the whole
        // partition while live nodes remain.
        repairEntryPoint()
    }

    /// Re-seed `entryPoint` if it refers to a tombstoned node.
    ///
    /// Invariant established (VH-01 Finding B): whenever `liveCount > 0`,
    /// `entryPoint` refers to a live, non-tombstoned node. Called after any
    /// tombstoning mutation (insert upsert path, tombstone). Picks the live
    /// node with the most neighbour layers (highest top layer = `maxLayer`);
    /// ties resolve to the lowest array index for determinism. O(n) scan,
    /// but only runs when the entry node was actually tombstoned.
    private func repairEntryPoint() {
        // Bounds guard included (VH-01 F2): a stale entryPoint from a prior
        // load can be past the end of the rebuilt nodes array. Matches Rust
        // twin: hnsw_index.rs:638-640 (`i < self.nodes.len()` check).
        if let ep = entryPoint, Int(ep) < nodes.count, !nodes[Int(ep)].tombstoned {
            return // entry point is live — nothing to repair
        }
        var bestIdx: Int32? = nil
        var bestLayer = -1
        for (i, node) in nodes.enumerated() {
            guard !node.tombstoned else { continue }
            let topLayer = node.neighbours.count - 1
            if topLayer > bestLayer {
                bestLayer = topLayer
                bestIdx = Int32(i)
            }
        }
        if let b = bestIdx {
            entryPoint = b
            maxLayer = bestLayer
        } else {
            entryPoint = nil
            maxLayer = 0
        }
    }

    /// Rebuild the graph from live nodes, dropping all tombstones (BETA duty).
    ///
    /// O(n log n) where n is the live count. Dead nodes and their inbound edges
    /// are permanently removed. The graph is rebuilt in the CONTENT-STABLE bulk
    /// build order (SPEC 1.10.0): live rows sorted by (vecHash ASC, itemID ASC)
    /// before re-insertion, so a bulk rebuild from the same row set produces the
    /// identical graph regardless of the original arrival order.
    public func compact() {
        let live = nodes.filter { !$0.tombstoned }
        guard !live.isEmpty else { clear(); return }
        var snapshot = live.map {
            (itemID: $0.itemID, modelID: $0.modelID, bytes: $0.vectorBytes, vecHash: $0.vecHash)
        }
        // Content-stable bulk build order: (fnv1a64(payload bytes) ASC, itemID
        // ASC). Identical content yields an identical insertion sequence — and
        // therefore an identical graph — across independent rebuilds; itemID is
        // the backstop only for byte-identical (interchangeable) vectors.
        snapshot.sort { a, b in
            a.vecHash != b.vecHash ? a.vecHash < b.vecHash : a.itemID < b.itemID
        }
        clear()
        for node in snapshot {
            let floats = bytesToFloats(node.bytes)
            insert(itemID: node.itemID, modelID: node.modelID, vector: floats)
        }
        hnswLog.info("HNSWIndex.compact: rebuilt with \(self.nodes.count) live nodes")
    }

    /// Clear the entire graph (ALPHA extreme-drift duty; THETA pre-rebuild step).
    ///
    /// Drops all nodes, connections, and vector bytes. O(1) — just releases arrays.
    /// After clear(), the next insert or rebuild starts a fresh graph from an empty state.
    public func clear() {
        nodes.removeAll(keepingCapacity: false)
        nodeIndex.removeAll(keepingCapacity: false)
        entryPoint = nil
        maxLayer = 0
        vectorStride = nil
        hnswLog.info("HNSWIndex.clear: graph cleared")
    }

    // MARK: - Persistence API

    /// True when the graph contains at least one node (entry point is set).
    ///
    /// Used by VectorStore to decide whether `hnsw_graph` rows should be written
    /// or loaded. An empty graph has no rows to persist.
    public var hasGraph: Bool { entryPoint != nil }

    /// One serialisable row for the `hnsw_graph` SQLite table.
    ///
    /// One `GraphRow` per (node, layer) combination. `nodeIdx` is the dense
    /// array index; `nodeID` is the item_id. `neighboursBlob` is a packed
    /// little-endian Int32 array of neighbour node_idx values — matching the
    /// column definition in VectorStore.schemaDeclaration v6. `generation`
    /// ties each row to a specific shadow-swap generation so VectorStore can
    /// filter to the serving generation on load and reclaim retired rows.
    public struct GraphRow: Sendable {
        public let nodeIdx:        Int32
        public let nodeID:         String
        public let layer:          Int
        public let neighboursBlob: Data   // packed LE Int32 array
        /// Shadow-swap generation tag for this row. Matches the generation
        /// of the HNSWIndex instance that produced it.
        public let generation:     Int64

        /// Decode `neighboursBlob` back to an [Int32] array.
        ///
        /// The BLOB is UNTRUSTED persisted input (VH-01 Finding C): the
        /// decoded count is capped at `hnswM0` — the maximum fan-out any
        /// layer can legitimately persist — so a crafted oversized BLOB
        /// cannot drive the allocation size. The BLOB must be a whole number
        /// of Int32s; trailing bytes beyond the last whole 4-byte word are
        /// ignored (guarded by the `/4` integer division).
        public func decodeNeighbours() -> [Int32] {
            guard !neighboursBlob.isEmpty else { return [] }
            return neighboursBlob.withUnsafeBytes { ptr in
                let count = min(ptr.count / 4, hnswM0)
                var result = [Int32](repeating: 0, count: count)
                for i in 0..<count {
                    var v: Int32 = 0
                    withUnsafeMutableBytes(of: &v) { dst in
                        dst.copyMemory(from:
                            UnsafeRawBufferPointer(rebasing: ptr[(i*4)..<(i*4+4)]))
                    }
                    result[i] = v
                }
                return result
            }
        }
    }

    /// Serialise the current graph to rows for the `hnsw_graph` table.
    ///
    /// Returns one `GraphRow` per (node, layer) combination for every
    /// non-tombstoned node in the graph. Tombstoned nodes are excluded so
    /// the persisted graph contains only live topology; the next BETA
    /// compaction rebuilds a clean graph without tombstones.
    ///
    /// Neighbours are packed as little-endian Int32 BLOBs matching the
    /// `hnsw_graph.neighbours` column format. Call after `insert`, `compact`,
    /// or `rebuildHNSWIndex` to persist the current graph state. VectorStore
    /// owns the SQLite write; this method only produces the row payloads.
    public func graphRows() -> [GraphRow] {
        var rows: [GraphRow] = []
        for (nodeIdx, node) in nodes.enumerated() {
            // Skip tombstoned nodes — they are invisible to search and
            // should not appear in the persisted graph. The next BETA
            // compaction rebuilds a clean graph without tombstones.
            guard !node.tombstoned else { continue }
            for (layer, neighbours) in node.neighbours.enumerated() {
                var blob = Data(capacity: neighbours.count * 4)
                for n in neighbours {
                    // Pack as 4 LE bytes (little-endian Int32).
                    blob.append(UInt8( n        & 0xFF))
                    blob.append(UInt8((n >>  8) & 0xFF))
                    blob.append(UInt8((n >> 16) & 0xFF))
                    blob.append(UInt8((n >> 24) & 0xFF))
                }
                rows.append(GraphRow(
                    nodeIdx:        Int32(nodeIdx),
                    nodeID:         node.itemID,
                    layer:          layer,
                    neighboursBlob: blob,
                    generation:     _generation
                ))
            }
        }
        return rows
    }

    /// Restore the graph topology from persisted rows plus float vector bytes.
    ///
    /// Reconstructs `nodes`, `nodeIndex`, `entryPoint`, and `maxLayer` from
    /// `rows` (the `hnsw_graph` table dump) and `nodeBytes` (float32 payloads
    /// from the `vectors` table, keyed by nodeIdx). The RNG state is reset
    /// to the default seed (42); the loaded graph is already built — no
    /// level-assignment RNG is needed until the next incremental insert.
    ///
    /// Loading is O(n × L) where n = node count, L = average layer count —
    /// far cheaper than the O(n × L × efConstruction) insert-rebuild path.
    ///
    /// - Parameters:
    ///   - rows: All `GraphRow` values for one modelID partition, in any order.
    ///     Rows for the same nodeIdx must share the same nodeID.
    ///   - nodeBytes: Mapping from nodeIdx (Int32) to (itemID, vectorBytes).
    ///     Nodes missing from this map receive a placeholder tombstone that
    ///     preserves compact addressing — a bare skip would shift every later
    ///     node's index and mis-wire neighbour edges (VH-01 F1). The tombstone
    ///     is excluded from search; the THETA rebuild corrects topology on the
    ///     next cadence.
    ///   - modelID: The modelID partition this graph serves. Stored on each
    ///     reconstructed node so `search(probe:modelID:k:)` can filter by
    ///     partition membership — search performs `nodes[i].modelID == modelID`
    ///     and silently returns [] if the modelID is empty (the pre-load default).
    ///   - expectedGeneration: The serving_generation value VectorStore fetched
    ///     from the registry. Only rows whose `row.generation == expectedGeneration`
    ///     are accepted; any mismatch causes the load to be treated as absent —
    ///     this instance is left EMPTY (state is reset before the generation
    ///     filter runs, VH-01 F2) so the query path falls back to exact scan.
    ///     On a successful load, `self.generation` is set to this value.
    public func loadFromGraphRows(
        _ rows: [GraphRow],
        nodeBytes: [Int32: (itemID: String, bytes: [UInt8])],
        modelID: String,
        expectedGeneration: Int64
    ) {
        // Reset all state before loading (VH-01 F2): any early return — empty
        // rows, a retired generation, a Phase-0 reject, or an all-tombstone
        // result — yields a clean empty index rather than leaving a stale
        // entryPoint from a previous load. Matches the Rust twin, which calls
        // self.clear() before the empty-rows check.
        nodes.removeAll(keepingCapacity: false)
        nodeIndex.removeAll(keepingCapacity: false)
        entryPoint = nil
        maxLayer = 0
        vectorStride = nil

        // Reject rows that belong to a retired generation. The reset above has
        // already emptied this instance, so a mismatch leaves hasGraph false and
        // the query path falls back to exact scan rather than serving stale
        // topology (§4 of the design contract).
        let matchingRows = rows.filter { $0.generation == expectedGeneration }
        guard !matchingRows.isEmpty else { return }
        let rows = matchingRows

        // Phase 0: validate every row BEFORE any allocation is sized from row
        // data. Persisted graph rows are UNTRUSTED input (VH-01 Finding C):
        // `layer` drives `count: maxLayer + 1` allocations and `neighboursBlob`
        // drives the decoded array size, so both must be bounded before reaching
        // the allocation phases. One invalid row rejects the WHOLE persisted
        // graph — the index stays empty (hasGraph → false) and the caller
        // falls back to exact scan until the next THETA rebuild — rather than
        // reconstructing a partial topology from corrupt state.
        for row in rows {
            let blobLen = row.neighboursBlob.count
            guard row.nodeIdx >= 0,
                  row.layer <= hnswMaxPersistedLayer,
                  blobLen % 4 == 0,
                  blobLen <= hnswM0 * 4 else {
                return
            }
        }

        // Sort rows by nodeIdx then layer so we can rebuild in order.
        let sorted = rows.sorted {
            $0.nodeIdx != $1.nodeIdx ? $0.nodeIdx < $1.nodeIdx : $0.layer < $1.layer
        }

        // Build a compact index: old nodeIdx → new array position.
        // nodeIdx values may be non-contiguous if tombstones were excluded
        // during the persist pass; map them to a fresh compact index. The
        // graph topology depends on relative indices; absolute values are
        // internal to each instance.
        var oldToNew: [Int32: Int] = [:]
        var newToOld: [Int] = []  // new position → original nodeIdx
        for row in sorted {
            if oldToNew[row.nodeIdx] == nil {
                oldToNew[row.nodeIdx] = newToOld.count
                newToOld.append(Int(row.nodeIdx))
            }
        }

        let totalNodes = newToOld.count
        var maxLayerSeen = 0
        var layerNeighbours: [[Int: [Int32]]] = Array(repeating: [:], count: totalNodes)

        for row in sorted {
            guard let newIdx = oldToNew[row.nodeIdx] else { continue }
            if row.layer > maxLayerSeen { maxLayerSeen = row.layer }
            let rawNeighbours = row.decodeNeighbours()
            // Remap neighbour indices from the old dense space to the new space.
            let remapped = rawNeighbours.compactMap { oldN -> Int32? in
                guard let newN = oldToNew[oldN] else { return nil }
                return Int32(newN)
            }
            layerNeighbours[newIdx][row.layer] = remapped
        }

        // Reconstruct the node array in new-index order.
        // nodes and nodeIndex were cleared in the F2b reset block above.
        nodes.reserveCapacity(totalNodes)

        for newIdx in 0..<totalNodes {
            let originalIdx = Int32(newToOld[newIdx])
            let layerMap    = layerNeighbours[newIdx]
            let topLayer    = layerMap.keys.max() ?? 0
            var nodeNeighbours = [[Int32]](repeating: [], count: topLayer + 1)
            for (l, nbrs) in layerMap {
                nodeNeighbours[l] = nbrs
            }
            if let (itemID, bytes) = nodeBytes[originalIdx] {
                // Live node: vector bytes present.
                nodes.append(Node(
                    itemID:      itemID,
                    modelID:     modelID,  // partition-scoped; needed by search filter
                    vectorBytes: bytes,
                    vecHash:     fnv1a64(bytes),
                    neighbours:  nodeNeighbours
                ))
                nodeIndex[itemID] = Int32(nodes.count - 1)
            } else {
                // Deleted vector: placeholder tombstone preserves compact addressing
                // (VH-01 F1). A bare `continue` would shift every later node down,
                // mis-wiring neighbour edges: a neighbour list saying "node 3" would
                // address whatever landed at index 3 after the skip. Matches Rust
                // twin: hnsw_index.rs:863-871. NOT added to nodeIndex.
                nodes.append(Node(
                    itemID:      "",
                    modelID:     modelID,
                    vectorBytes: [],
                    vecHash:     fnv1a64([]),  // never compared — tombstones are skipped
                    neighbours:  nodeNeighbours,
                    tombstoned:  true
                ))
            }
        }

        // Elect entry point: the live node with the most layers (ties: lowest index).
        // Skip tombstones — nodes may include placeholder tombstones for deleted
        // vectors (VH-01 F1). Only set entryPoint if a live candidate exists.
        // Matches Rust: hnsw_index.rs:893-913.
        var bestIdx: Int32? = nil
        var bestTopLayer    = -1
        for (i, node) in nodes.enumerated() {
            guard !node.tombstoned else { continue }
            let nodeTop = node.neighbours.count - 1
            if nodeTop > bestTopLayer {
                bestTopLayer = nodeTop
                bestIdx      = Int32(i)
            }
        }
        if let b = bestIdx {
            entryPoint = b
            maxLayer   = bestTopLayer
        }
        // If bestIdx is nil (all tombstones, or empty), entryPoint stays nil —
        // cleared in the F2b reset block above. hasGraph → false; caller falls
        // back to exact scan until the next THETA rebuild.

        // Skip tombstone placeholders when deriving stride: a deleted node at
        // compact index 0 has vectorBytes == [] and would set stride to 0,
        // causing search() to throw invalidPayload. The Rust twin derives stride
        // from node_bytes (the nodeIdx→bytes map, which excludes deleted entries)
        // so it is immune; this makes Swift match that contract.
        vectorStride = nodes.first(where: { !$0.tombstoned })?.vectorBytes.count
        // RNG state reset: the loaded graph is already built, so no level-
        // assignment calls are needed until the next incremental insert.
        // The default seed (42) is used for any subsequent insertions.
        rngState = 42
        // Record the generation this graph was loaded for. The query site
        // in VectorStore checks graph.generation == serving_gen before use.
        _generation = expectedGeneration
    }

    // MARK: - Private helpers

    /// Decode stored bytes of node `idx` to [Float] for distance computation.
    private func nodeFloats(_ idx: Int) -> [Float] {
        bytesToFloats(nodes[idx].vectorBytes)
    }

    /// Decode a LE float32 byte array to [Float].
    private func bytesToFloats(_ bytes: [UInt8]) -> [Float] {
        let count = bytes.count / 4
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count { result[i] = floatFromBytes(bytes, at: i) }
        return result
    }
}

// MARK: - Float.clamped helper

private extension Float {
    /// Clamp to a closed range without importing additional modules.
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
