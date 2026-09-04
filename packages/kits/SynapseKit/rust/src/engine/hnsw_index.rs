//! HNSWIndex — Lane D approximate nearest-neighbour index (Rust twin).
//!
//! Hierarchical Navigable Small World approximate nearest-neighbour index
//! for the float32 lane (Lane D).
//!
//! # Architecture (HNSW_DESIGN.md §2 + §4)
//!
//! The graph is a layered navigable small-world structure. Every vector is a
//! node; each node keeps a short neighbour list per layer. The top layer is
//! sparse with long hops, the bottom layer (0) holds every node. A search
//! enters at the top, greedily hops toward the query, drops one layer, and
//! repeats until it reaches layer 0, where it collects `efSearch` candidates.
//! Cost grows logarithmically in corpus size; brute-force grows linearly.
//!
//! # Design rulings
//!
//! - Float lane ONLY. Binary lane (A/B) is untouched; it is already exact.
//! - Cross-port determinism NOT required. Any valid HNSW graph answers
//!   correctly; the Swift and Rust graphs legitimately differ (HNSW_DESIGN §7).
//! - Within-port reproducibility IS required. SplitMix64 seeded at index
//!   creation so the same seed + insertion order yields the same graph.
//! - CROSS-RUN identity for BULK builds (SPEC 1.10.0): every bulk rebuild
//!   (`compact()` here; `VectorStore::rebuild_hnsw_index` at the store)
//!   inserts rows in content-stable order — (fnv1a64(payload bytes) ASC,
//!   item_id ASC) — so identical content yields an identical graph across
//!   independent builds even though item UUIDs differ per provisioning.
//!   Incremental single-row inserts keep ARRIVAL order: only bulk rebuilds
//!   guarantee cross-run identity; the next THETA rebuild converges an
//!   incrementally-grown graph.
//! - Crossover threshold: 5,000 vectors per modelID partition. Below this
//!   count `FloatBruteForceIndex` is faster (see §Crossover below).
//! - Nearest only. Farthest queries still use `FloatBruteForceIndex` regardless
//!   of corpus size — anti-similarity with HNSW requires a full-graph scan
//!   and provides no speed benefit.
//!
//! # Crossover threshold rationale (measured, then confirmed by calculation)
//!
//! At M=16, efSearch=50, HNSW visits ≈ efSearch × log₂(n) nodes per search.
//! At n=5000: HNSW comparisons ≈ 50 × 12.2 ≈ 610 vs brute-force 5000.
//! Below 5000 the graph construction overhead + pointer-chasing overhead
//! outweighs the scan reduction. 5000 is a conservative crossover; tests
//! confirm ≥90% recall@10 at this threshold.
//!
//! # Default parameters (HNSW_DESIGN §8, Malkov & Yashunin 2018)
//!
//! - M              = 16   (max connections per layer; 2×M at layer 0)
//! - efConstruction = 100  (beam width during insert)
//! - efSearch       = 50   (beam width during search)
//! - seed           = 42   (SplitMix64 initial state; overridable in tests)
//!
//! # Float determinism
//!
//! THIS LANE IS NOT FOUR-WAY BIT-IDENTICAL.
//! The Swift and Rust graphs legitimately differ (different pointer order,
//! different float rounding) — recall quality is the correctness criterion,
//! not bit-identity. A reviewer must not "fix" this to chase four-way identity.
//!
//! # Rule FT-1
//!
//! This file does NOT modify any Lane F shared type. If a new field is needed
//! on a shared type, stop and file an FT-1 update to Lane F.

use crate::error::SynapseKitError;
use crate::vector_store::VectorMatch;

// MARK: - Persistence row type

/// Row-oriented view of one node at one layer for `hnsw_graph` SQLite persistence.
///
/// Used by `HNSWIndex::graph_rows()` to serialise the in-memory graph and by
/// `HNSWIndex::load_from_graph_rows()` to deserialise rows back. One row covers
/// exactly one (node, layer) pair. The schema is PK=(model_id, node_idx, layer);
/// `model_id` is provided by the caller at the VectorStore layer (it is the
/// partition key, not stored per-row inside HNSWIndex).
///
/// `neighbours_blob`: packed little-endian i32 array — 4 bytes per neighbour,
/// length = `neighbours_blob.len() / 4`. Compact (tombstone-free) indices.
pub struct GraphRow {
    /// Compact ordinal index of this node within the persisted graph (0-based).
    /// Assigned at serialisation time; contiguous over live nodes only.
    pub node_idx: i32,
    /// item_id of the vector stored at this node; matches `vectors.item_id`.
    pub node_id: String,
    /// Which HNSW layer this row covers. Layer 0 is the base (densest) layer.
    pub layer: usize,
    /// Packed little-endian i32 neighbour node indices at this layer.
    pub neighbours_blob: Vec<u8>,
    /// Shadow-swap generation this graph row belongs to. Matches the
    /// `hnsw_graph.generation` column (v6). Rows whose generation ≠ the
    /// store's current serving generation are ignored at load time (§4).
    pub generation: i64,
}

impl GraphRow {
    /// Decode `neighbours_blob` to a `Vec<i32>` of compact node indices.
    ///
    /// The BLOB is UNTRUSTED persisted input (VH-01 Finding C): the decoded
    /// count is capped at `HNSW_M0` — the maximum fan-out any layer can
    /// legitimately persist (layer 0 caps at M0; layers ≥ 1 cap at M < M0) —
    /// so a crafted oversized BLOB cannot drive the allocation size. Trailing
    /// bytes beyond the last whole i32 are ignored (integer division).
    pub fn decode_neighbours(&self) -> Vec<i32> {
        let count = (self.neighbours_blob.len() / 4).min(HNSW_M0);
        (0..count)
            .map(|i| {
                let base = i * 4;
                i32::from_le_bytes([
                    self.neighbours_blob[base],
                    self.neighbours_blob[base + 1],
                    self.neighbours_blob[base + 2],
                    self.neighbours_blob[base + 3],
                ])
            })
            .collect()
    }
}

// MARK: - HNSW tuning constants

/// Max connections per node per layer (layers 1+). Layer 0 uses `HNSW_M0 = 2 × M`.
/// M=16 is optimal for high-dimensional embedding spaces (Malkov & Yashunin 2018 §4.1).
pub const HNSW_M: usize = 16;

/// Max connections at layer 0. Always 2 × M (per-paper recommendation).
pub const HNSW_M0: usize = HNSW_M * 2;

/// Level multiplier for probabilistic level assignment: 1/ln(M).
/// Controls the expected number of layers; smaller mL = fewer, denser layers.
/// Precomputed: 1/ln(16) = 1/(4×ln(2)) ≈ 0.36067376022224085.
/// Cannot be computed via `f64::ln()` in a const context (not a const fn in stable Rust).
const HNSW_ML: f64 = 0.36067376022224085_f64;

/// Beam width during index construction. Higher = better graph quality, slower build.
/// efConstruction=100 is the paper's default for M=16.
pub const HNSW_EF_CONSTRUCTION: usize = 100;

/// Beam width during search. Higher = better recall, slower query.
/// efSearch=50 achieves ≥90% recall@10 for M=16 at n≥5,000.
pub const HNSW_EF_SEARCH: usize = 50;

/// Vector count per modelID partition above which HNSWIndex activates.
/// Below this threshold FloatBruteForceIndex is faster (see module docstring §Crossover).
pub const HNSW_DEFAULT_THRESHOLD: u32 = 5_000;

/// Upper bound accepted for a persisted `hnsw_graph.layer` value (VH-01
/// Finding C). Persisted graph rows are UNTRUSTED input; `layer` sizes the
/// per-node neighbour-layer allocation, so it must be capped consistently
/// with the index's own level generation: `assign_level` draws
/// `floor(-ln(u) × mL)` with mL = 1/ln(16) ≈ 0.3607, so
/// P(level ≥ 32) = exp(-32/mL) ≈ 3e-39 — an honest graph can never persist
/// a layer this high. Any row above the cap is structurally invalid.
pub const HNSW_MAX_PERSISTED_LAYER: usize = 32;

// MARK: - Node

/// One node in the HNSW graph.
///
/// Owns the float vector bytes so search can compute distances without
/// fetching from the table. `neighbours[l]` = list of node indices at layer l.
#[derive(Clone)]
struct Node {
    /// item_id from the originating VectorRecordKey.
    item_id: String,
    /// model_id from the originating VectorRecordKey.
    model_id: String,
    /// IEEE-754 LE float32 bytes (same format as VectorPayload.bytes).
    vector_bytes: Vec<u8>,
    /// FNV-1a 64 over `vector_bytes` — the content-derived tie key shared
    /// with every k-NN engine (SPEC 1.10.0). Computed once at node
    /// construction; used by the neighbour-truncation cuts in `insert`
    /// and by the content-stable bulk rebuild order in `compact`.
    /// Placeholder tombstones (empty bytes) carry the hash of the empty
    /// sequence — never compared, because tombstones are skipped.
    vec_hash: u64,
    /// `neighbours[l]` = array of node indices (i32) at layer l.
    /// Layer 0 (the densest) has up to M0 connections; layers ≥1 have up to M.
    neighbours: Vec<Vec<i32>>,
    /// True once tombstoned. Excluded from search; compacted out on next compact().
    tombstoned: bool,
}

// MARK: - HNSWIndex

/// Approximate nearest-neighbour index for the float32 dense lane (Lane D).
///
/// Implements HNSW (Malkov & Yashunin 2018) over resident float32 vectors.
/// Owns both the graph structure (neighbour lists) and the flat vector bytes
/// (for distance computation without a separate store lookup). At/above the
/// crossover threshold `VectorStore` routes nearest-float queries here; below
/// the threshold `FloatBruteForceIndex` is the active index.
///
/// This is an APPROXIMATE index. `FloatBruteForceIndex` is the conformance oracle.
/// Tests compare recall quality: HNSW must find ≥90% of the oracle's top-k results.
///
/// Thread-safety: this struct is NOT thread-safe by itself. VectorStore wraps it
/// inside the `Mutex<HotState>` lock — all access is serialised by the caller.
///
/// # No Default impl
///
/// Use `HNSWIndex::new(seed)` or `HNSWIndex::new_default()`. No `impl Default`
/// is provided; see BRR VEC-HNSW-01 schema constraints: "HNSWIndex in Rust
/// exposes only `new()` factory, not `impl Default`."
pub struct HNSWIndex {
    /// All nodes in insertion order. A node's array index is its graph node_id.
    nodes: Vec<Node>,

    /// item_id → node array index. O(1) lookup by item_id.
    node_index: std::collections::HashMap<String, i32>,

    /// Current graph entry point (top-layer seed for search). None when empty.
    entry_point: Option<i32>,

    /// Highest layer currently in use (0 = all nodes at layer 0 only).
    max_layer: usize,

    /// SplitMix64 state. Seeded at init; same seed + insertion order → same graph.
    rng_state: u64,

    /// Byte count per vector (float32 stride = dim × 4). None before first insert.
    vector_stride: Option<usize>,

    /// Shadow-swap generation identity. Fixed at build or load time.
    ///
    /// Set to the store's serving generation when the graph is built via
    /// `rebuild_hnsw_index` (D6 fix: stamped BEFORE persisting so a crash
    /// between stamp and persist leaves an absent graph, not a mismatched one).
    /// Set to `expected_generation` when loaded via `load_from_graph_rows`.
    ///
    /// `find_nearest_float` checks this value against the current serving
    /// generation before routing a query here. A mismatch means the graph is
    /// stale (crash between flip-commit and rebuild) and the query falls back
    /// to exact scan. DEFAULT 0 matches new graphs built before the shadow-swap
    /// feature shipped, which always served generation 0.
    generation: i64,
}

impl HNSWIndex {
    /// Construct an empty HNSW index with a given SplitMix64 seed.
    ///
    /// Use `new_default()` for the production seed (42). The seed parameter
    /// exists for tests that need to explore different graph shapes with the same
    /// data set.
    ///
    /// - Parameter seed: SplitMix64 initial state. Default production value is 42.
    pub fn new(seed: u64) -> Self {
        HNSWIndex {
            nodes: Vec::new(),
            node_index: std::collections::HashMap::new(),
            entry_point: None,
            max_layer: 0,
            rng_state: seed,
            vector_stride: None,
            // New graphs start at generation 0. VectorStore.rebuild_hnsw_index
            // calls set_generation(serving_gen) before persisting (D6).
            generation: 0,
        }
    }

    /// Construct an empty HNSW index with the production seed (42).
    ///
    /// The canonical entry point for all non-test callers.
    pub fn new_default() -> Self {
        Self::new(42)
    }

    /// The shadow-swap generation this index was built for or loaded from.
    ///
    /// `find_nearest_float` compares this against the store's current serving
    /// generation before routing a query here. A mismatch means the graph is
    /// stale (crash between flip-commit and rebuild) and the query falls back
    /// to exact scan (§4 HNSW generation identity ruling).
    pub fn generation(&self) -> i64 {
        self.generation
    }

    /// Stamp this graph with the given generation.
    ///
    /// Called by `VectorStore::rebuild_hnsw_index` AFTER building the graph
    /// and BEFORE persisting it (D6 fix). The stamp ensures that if the process
    /// crashes between persist and the serving-generation registry flip, the
    /// next open sees a generation-0 graph for a non-0 serving generation and
    /// correctly treats it as absent, falling back to exact scan.
    pub fn set_generation(&mut self, gen: i64) {
        self.generation = gen;
    }

    // MARK: - SplitMix64 RNG

    /// Advance state and return the next pseudorandom u64.
    ///
    /// SplitMix64 (Vigna 2015): one-state, zero-avalanche, good statistical
    /// properties. Identical algorithm to Swift GauntletRNG and the fleet's
    /// RandomIndexingProvider — chosen for consistency.
    fn next_random(&mut self) -> u64 {
        self.rng_state = self.rng_state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.rng_state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }

    /// Draw a HNSW node level from the geometric distribution.
    ///
    /// Formula: `floor(-ln(u) × mL)` where u ~ Uniform(0,1), mL = 1/ln(M).
    /// Always ≥ 0 (every node appears at layer 0). Approximately 1/M of nodes
    /// appear at layer 1, 1/M² at layer 2, and so on.
    fn assign_level(&mut self) -> usize {
        // Map u64 to uniform (0,1) using top 53 bits (IEEE-754 double mantissa).
        let r = self.next_random();
        let u = (r >> 11) as f64 * (1.0 / (1u64 << 53) as f64);
        let level = (-f64::ln(f64::max(u, 1e-15)) * HNSW_ML) as usize;
        level
    }

    // MARK: - Distance computation

    /// Float dimensionality derived from the stride.
    fn dim(&self) -> usize {
        self.vector_stride.unwrap_or(0) / 4
    }

    /// Cosine distance between a [f32] probe and the bytes of node `idx`.
    ///
    /// cosine distance = 1 − cos(a, b). Range [0, 2]; 0 = identical direction.
    /// Returns 1.0 for zero-norm vectors (safe maximum-distance fallback).
    fn cosine_distance_to_node(&self, probe: &[f32], node_idx: usize) -> f32 {
        let bytes = &self.nodes[node_idx].vector_bytes;
        let d = self.dim();
        if d == 0 || bytes.len() != d * 4 || probe.len() != d {
            return 1.0;
        }
        let mut dot = 0.0_f32;
        let mut norm_a = 0.0_f32;
        let mut norm_b = 0.0_f32;
        for i in 0..d {
            let a = probe[i];
            let b = decode_f32_le_at(bytes, i);
            dot += a * b;
            norm_a += a * a;
            norm_b += b * b;
        }
        let denom = norm_a.sqrt() * norm_b.sqrt();
        if denom == 0.0 {
            return 1.0;
        }
        let sim = (dot / denom).clamp(-1.0, 1.0);
        1.0 - sim
    }

    // MARK: - Truncation total order

    /// Total order used wherever a candidate list is CUT to a neighbour cap
    /// during graph construction: (dist ASC, vec_hash ASC, item_id ASC).
    ///
    /// This is the universal tie-break key (SPEC 1.10.0): a raw index-order
    /// cut at the cap boundary would break ties by internal node index —
    /// i.e. by arrival order — making the wired topology depend on which of
    /// two equidistant nodes happened to be inserted first. The content hash
    /// makes the cut identical across independent builds of the same content;
    /// item_id remains the final backstop for byte-identical vectors, which
    /// are interchangeable for every ordering consumer. An incomparable
    /// distance (NaN) falls straight to the tie key, matching the previous
    /// `unwrap_or(Equal)` behaviour.
    fn truncation_cmp(&self, a: &(f32, i32), b: &(f32, i32)) -> std::cmp::Ordering {
        match a.0.partial_cmp(&b.0) {
            Some(std::cmp::Ordering::Equal) | None => {
                let na = &self.nodes[a.1 as usize];
                let nb = &self.nodes[b.1 as usize];
                na.vec_hash
                    .cmp(&nb.vec_hash)
                    .then_with(|| na.item_id.cmp(&nb.item_id))
            }
            Some(ord) => ord,
        }
    }

    // MARK: - searchLayer (core graph traversal)

    /// Greedy best-first search within one HNSW layer.
    ///
    /// Implements the `SEARCH-LAYER(q, ep, ef, lc)` function from Malkov &
    /// Yashunin Algorithm 2. Returns up to `ef` nearest candidates to `probe`
    /// at layer `layer`, sorted by cosine distance ascending.
    ///
    /// For small ef (default 50–200) a sorted Vec is faster than a heap
    /// because element counts are bounded and branch prediction dominates.
    fn search_layer(
        &self,
        probe: &[f32],
        entry_pts: &[i32],
        ef: usize,
        layer: usize,
    ) -> Vec<(f32, i32)> {
        let mut visited: std::collections::HashSet<i32> =
            std::collections::HashSet::with_capacity(ef * 2);

        // `candidates`: sorted by dist ascending (nearest-first, pop from front).
        // `results`: the ef-nearest found so far, dist ascending (farthest at end).
        let mut candidates: Vec<(f32, i32)> = Vec::new();
        let mut results: Vec<(f32, i32)> = Vec::new();

        // Sorted insert into a dist-ascending Vec (binary search insertion point).
        fn insert_sorted_asc(arr: &mut Vec<(f32, i32)>, item: (f32, i32)) {
            let pos = arr.partition_point(|&(d, _)| d <= item.0);
            arr.insert(pos, item);
        }

        // Seed with entry points.
        for &ep in entry_pts {
            let ep_i = ep as usize;
            if ep_i >= self.nodes.len() || self.nodes[ep_i].tombstoned {
                continue;
            }
            visited.insert(ep);
            let d = self.cosine_distance_to_node(probe, ep_i);
            insert_sorted_asc(&mut candidates, (d, ep));
            insert_sorted_asc(&mut results, (d, ep));
        }

        while !candidates.is_empty() {
            // Pop nearest candidate.
            let c = candidates.remove(0);
            // Farthest in results set.
            let f_dist = results.last().map(|&(d, _)| d).unwrap_or(f32::INFINITY);

            // Early exit: even the closest unexplored candidate is farther than
            // the farthest result we already have. Greedy exploration is complete.
            if c.0 > f_dist {
                break;
            }

            let c_i = c.1 as usize;
            if c_i >= self.nodes.len() {
                continue;
            }
            let node = &self.nodes[c_i];
            if layer < node.neighbours.len() {
                for &n_idx in &node.neighbours[layer] {
                    if visited.contains(&n_idx) {
                        continue;
                    }
                    let n_i = n_idx as usize;
                    if n_i >= self.nodes.len() || self.nodes[n_i].tombstoned {
                        continue;
                    }
                    visited.insert(n_idx);
                    let nd = self.cosine_distance_to_node(probe, n_i);
                    let f_dist2 = results.last().map(|&(d, _)| d).unwrap_or(f32::INFINITY);
                    if nd < f_dist2 || results.len() < ef {
                        insert_sorted_asc(&mut candidates, (nd, n_idx));
                        insert_sorted_asc(&mut results, (nd, n_idx));
                        if results.len() > ef {
                            results.pop();
                        }
                    }
                }
            }
        }

        results
    }

    // MARK: - Insert

    /// Insert a float32 vector into the HNSW graph (incremental, O(log n)).
    ///
    /// If `item_id` is already present, the existing node is tombstoned and a
    /// new node is inserted (upsert behaviour, matching VectorStore's UNIQUE
    /// constraint on (item_id, vector_index, model_id)).
    ///
    /// A mismatched dimension (different from previously inserted vectors) logs
    /// nothing and no-ops silently — the caller is responsible for supplying
    /// dimensionally consistent vectors within one HNSWIndex.
    ///
    /// - Parameters:
    ///   - item_id: item_id from the VectorRecordKey.
    ///   - model_id: model_id from the VectorRecordKey.
    ///   - vector: float32 values. Must have the same dimensionality as all
    ///     previously inserted vectors.
    pub fn insert(&mut self, item_id: String, model_id: String, vector: Vec<f32>) {
        // Upsert: tombstone any existing node for this item_id. If that node
        // was the graph entry point, repair the entry point IMMEDIATELY —
        // before the descent below seeds from it (a tombstoned seed is
        // skipped by search_layer, which would wire the replacement with no
        // neighbours) and before either early return (VH-01 Finding B: an
        // unrepaired entry point suppresses all recall for the partition
        // while live_count > 0, until the next rebuild/compaction).
        if let Some(&existing_idx) = self.node_index.get(&item_id) {
            self.nodes[existing_idx as usize].tombstoned = true;
            self.repair_entry_point();
        }

        let byte_count = vector.len() * 4;

        // Dimension guard: mismatched dim is a no-op (same as Swift's warning+return).
        if let Some(vs) = self.vector_stride {
            if byte_count != vs {
                return;
            }
        }
        if self.vector_stride.is_none() {
            self.vector_stride = Some(byte_count);
        }

        // Pack float32 to LE bytes (VectorPayload byte order).
        let mut bytes = vec![0u8; byte_count];
        for (i, &f) in vector.iter().enumerate() {
            let bits = f.to_bits();
            bytes[i * 4]     = (bits        & 0xFF) as u8;
            bytes[i * 4 + 1] = ((bits >> 8)  & 0xFF) as u8;
            bytes[i * 4 + 2] = ((bits >> 16) & 0xFF) as u8;
            bytes[i * 4 + 3] = ((bits >> 24) & 0xFF) as u8;
        }

        let level = self.assign_level();
        let new_idx = self.nodes.len() as i32;

        // Allocate the node with `level + 1` empty neighbour layers.
        let empty_layers: Vec<Vec<i32>> = vec![Vec::new(); level + 1];
        let vec_hash = super::fnv1a64(&bytes);
        self.nodes.push(Node {
            item_id: item_id.clone(),
            model_id,
            vector_bytes: bytes,
            vec_hash,
            neighbours: empty_layers,
            tombstoned: false,
        });
        self.node_index.insert(item_id, new_idx);

        let ep = match self.entry_point {
            None => {
                // First node: becomes entry point at the assigned level.
                self.entry_point = Some(new_idx);
                self.max_layer = level;
                return;
            }
            Some(ep) => ep,
        };

        let mut cur_ep = ep;
        let cur_max_layer = self.max_layer;

        // Search from the top down to `level+1` to find the best layer-`level` entry.
        if cur_max_layer > level {
            for lc in ((level + 1)..=cur_max_layer).rev() {
                let cands = self.search_layer(&vector, &[cur_ep], 1, lc);
                if let Some(&(_, nearest)) = cands.first() {
                    cur_ep = nearest;
                }
            }
        }

        // Wire connections at each layer from min(level, cur_max_layer) down to 0.
        let top_wire_layer = level.min(cur_max_layer);
        for lc in (0..=top_wire_layer).rev() {
            let mut cands = self.search_layer(&vector, &[cur_ep], HNSW_EF_CONSTRUCTION, lc);
            // Truncation cut at m_max: (dist, vec_hash, item_id) total order so
            // ties at the cap boundary do not fall to arrival order.
            cands.sort_by(|a, b| self.truncation_cmp(a, b));
            let m_max = if lc == 0 { HNSW_M0 } else { HNSW_M };
            let selected: Vec<(f32, i32)> = cands.into_iter().take(m_max).collect();

            // Set new node's neighbours at this layer.
            self.nodes[new_idx as usize].neighbours[lc] =
                selected.iter().map(|&(_, idx)| idx).collect();

            // Add back-connections from each selected neighbour to the new node.
            for &(_, nbr_idx) in &selected {
                let n_i = nbr_idx as usize;
                if n_i >= self.nodes.len() || self.nodes[n_i].tombstoned {
                    continue;
                }
                if lc >= self.nodes[n_i].neighbours.len() {
                    continue;
                }
                let current_count = self.nodes[n_i].neighbours[lc].len();
                if current_count < m_max {
                    self.nodes[n_i].neighbours[lc].push(new_idx);
                } else {
                    // Back-edge shrink: evict the weakest neighbour to stay ≤ m_max.
                    // Compute distances from nbr_idx's position to all its current
                    // neighbours + the new node, keep the m_max nearest.
                    let n_probe = self.node_to_floats(n_i);
                    let mut conns: Vec<(f32, i32)> = self.nodes[n_i].neighbours[lc]
                        .iter()
                        .filter_map(|&cidx| {
                            let ci = cidx as usize;
                            if ci >= self.nodes.len() || self.nodes[ci].tombstoned {
                                return None;
                            }
                            Some((self.cosine_distance_to_node(&n_probe, ci), cidx))
                        })
                        .collect();
                    conns.push((
                        self.cosine_distance_to_node(&n_probe, new_idx as usize),
                        new_idx,
                    ));
                    // Same truncation total order as the forward-edge cut above.
                    conns.sort_by(|a, b| self.truncation_cmp(a, b));
                    self.nodes[n_i].neighbours[lc] =
                        conns.into_iter().take(m_max).map(|(_, idx)| idx).collect();
                }
            }

            // The nearest at this layer is the entry point for the next lower layer.
            if let Some(&(_, nearest)) = selected.first() {
                cur_ep = nearest;
            }
        }

        // Promote entry point if the new node's level is higher.
        if level > cur_max_layer {
            self.entry_point = Some(new_idx);
            self.max_layer = level;
        }
    }

    // MARK: - Search

    /// Find the k approximate nearest neighbours (cosine metric).
    ///
    /// Traverses the layered graph from the top layer to layer 0, collecting
    /// `efSearch` candidates at layer 0 via greedy best-first. Filters to
    /// `model_id` and returns the top k.
    ///
    /// Distance convention: `((cosine_distance × 10_000).round()) as i32` —
    /// matches VectorMatch.distance in the float lane (same as the
    /// FloatBruteForceIndex path in VectorStore.find_nearest_float).
    ///
    /// Returns `SynapseKitError::InvalidPayload` if the probe dimension mismatches
    /// the index's established stride.
    pub fn search(
        &self,
        probe: &[f32],
        model_id: &str,
        k: usize,
    ) -> Result<Vec<VectorMatch>, SynapseKitError> {
        let live_count = self.nodes.iter().filter(|n| !n.tombstoned).count();
        if live_count == 0 || k == 0 {
            return Ok(Vec::new());
        }
        let ep = match self.entry_point {
            None => return Ok(Vec::new()),
            Some(ep) => ep,
        };

        if let Some(vs) = self.vector_stride {
            if probe.len() * 4 != vs {
                return Err(SynapseKitError::InvalidPayload(format!(
                    "HNSWIndex.search: probe has {} floats; expected {}",
                    probe.len(),
                    vs / 4
                )));
            }
        }

        let mut cur_ep = ep;

        // Upper layers: single-candidate greedy descent to the layer-0 entry point.
        if self.max_layer > 0 {
            for lc in (1..=self.max_layer).rev() {
                let cands = self.search_layer(probe, &[cur_ep], 1, lc);
                if let Some(&(_, nearest)) = cands.first() {
                    cur_ep = nearest;
                }
            }
        }

        // Layer 0: collect efSearch candidates.
        let cands = self.search_layer(probe, &[cur_ep], HNSW_EF_SEARCH, 0);

        // Filter to model_id, take top k, convert distances.
        let results: Vec<VectorMatch> = cands
            .into_iter()
            .filter(|&(_, idx)| {
                let i = idx as usize;
                i < self.nodes.len() && self.nodes[i].model_id == model_id
            })
            .take(k)
            .map(|(dist, idx)| {
                let node = &self.nodes[idx as usize];
                VectorMatch {
                    item_id: node.item_id.clone(),
                    distance: (dist * 10_000.0).round() as i32,
                    model_id: node.model_id.clone(),
                    // Rows served by this HNSW instance belong to its generation.
                    // The caller filters graph instances by generation before use
                    // (§4 generation-identity check), so self.generation equals the
                    // serving generation at the time this search fires.
                    generation: self.generation,
                score: None,
                }
            })
            .collect();

        Ok(results)
    }

    // MARK: - Maintenance duties

    /// Tombstone a node by item_id (pre-step for BETA compaction).
    ///
    /// Tombstoned nodes are excluded from search results and skipped during
    /// graph traversal. Dead edges pointing to a tombstone are not immediately
    /// removed; they are cleaned up during the next `compact()` call. This is
    /// the "wear" model from HNSW_DESIGN §5: tombstones accumulate until BETA.
    pub fn tombstone(&mut self, item_id: &str) {
        if let Some(&idx) = self.node_index.get(item_id) {
            self.nodes[idx as usize].tombstoned = true;
            // Entry-point invariant (VH-01 Finding B): tombstoning the entry
            // node must re-seed the entry point, or search goes dark for the
            // whole partition while live nodes remain.
            self.repair_entry_point();
        }
    }

    /// Re-seed `entry_point` if it refers to a tombstoned (or out-of-range)
    /// node.
    ///
    /// Invariant established (VH-01 Finding B): whenever `live_count > 0`,
    /// `entry_point` refers to a live, non-tombstoned node. Called after any
    /// tombstoning mutation (`insert` upsert path, `tombstone`). Picks the
    /// live node with the most layers (its top layer becomes `max_layer`,
    /// keeping the search descent consistent); ties resolve to the
    /// lowest-index node for determinism. O(n) scan — only runs when the
    /// entry node was actually tombstoned, which is rare relative to inserts.
    /// With no live nodes left, the graph resets to the empty-entry state.
    fn repair_entry_point(&mut self) {
        if let Some(ep) = self.entry_point {
            let i = ep as usize;
            if i < self.nodes.len() && !self.nodes[i].tombstoned {
                return; // entry point is live — nothing to repair
            }
        } else {
            return; // empty graph — nothing to repair
        }
        let mut best: Option<(usize, usize)> = None; // (top_layer, node idx)
        for (i, n) in self.nodes.iter().enumerate() {
            if n.tombstoned {
                continue;
            }
            let top = n.neighbours.len().saturating_sub(1);
            if best.map_or(true, |(bt, _)| top > bt) {
                best = Some((top, i));
            }
        }
        match best {
            Some((top, i)) => {
                self.entry_point = Some(i as i32);
                self.max_layer = top;
            }
            None => {
                self.entry_point = None;
                self.max_layer = 0;
            }
        }
    }

    /// Rebuild the graph from live nodes, dropping all tombstones (BETA duty).
    ///
    /// O(n log n) where n is the live count. Dead nodes and their inbound edges
    /// are permanently removed. The graph is rebuilt in the CONTENT-STABLE bulk
    /// build order (SPEC 1.10.0): live rows sorted by (vec_hash ASC, item_id ASC)
    /// before re-insertion, so a bulk rebuild from the same row set produces the
    /// identical graph regardless of the original arrival order.
    pub fn compact(&mut self) {
        // Snapshot live nodes before clearing.
        let mut live: Vec<(u64, String, String, Vec<f32>)> = self
            .nodes
            .iter()
            .filter(|n| !n.tombstoned)
            .map(|n| {
                (
                    n.vec_hash,
                    n.item_id.clone(),
                    n.model_id.clone(),
                    bytes_to_floats(&n.vector_bytes),
                )
            })
            .collect();

        if live.is_empty() {
            self.clear();
            return;
        }

        // Content-stable bulk build order: (fnv1a64(payload bytes) ASC, item_id
        // ASC). Identical content yields an identical insertion sequence — and
        // therefore an identical graph — across independent rebuilds; item_id is
        // the backstop only for byte-identical (interchangeable) vectors.
        live.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));

        self.clear();
        for (_, item_id, model_id, floats) in live {
            self.insert(item_id, model_id, floats);
        }
    }

    /// Clear the entire graph (ALPHA extreme-drift duty; THETA pre-rebuild step).
    ///
    /// Drops all nodes, connections, and vector bytes. O(1) — just releases the
    /// allocated Vecs. After `clear()`, the next `insert` or rebuild starts a
    /// fresh graph from an empty state. Generation is reset to 0; the caller
    /// (rebuild_hnsw_index via set_generation) stamps it before persisting.
    pub fn clear(&mut self) {
        self.nodes.clear();
        self.node_index.clear();
        self.entry_point = None;
        self.max_layer = 0;
        self.vector_stride = None;
        self.generation = 0;
    }

    // MARK: - Persistence (hnsw_graph table)

    /// True when the graph has at least one live node (entry_point is set).
    ///
    /// Used by `VectorStore.load_hnsw_graph_if_present` to detect an empty
    /// reconstruction (all nodes had deleted vectors).
    pub fn has_graph(&self) -> bool {
        self.entry_point.is_some()
    }

    /// Serialise the current HNSW graph to row form for SQLite persistence.
    ///
    /// Tombstoned nodes are excluded (compact layout). Neighbour indices are
    /// remapped from the internal (possibly fragmented) address space to
    /// compact sequential indices so the persisted rows form a self-consistent
    /// graph. One `GraphRow` is emitted per (live node, layer) pair.
    ///
    /// Returns an empty Vec when the graph is empty.
    pub fn graph_rows(&self) -> Vec<GraphRow> {
        // Build a compact index over live nodes only.
        let live: Vec<usize> = self.nodes.iter()
            .enumerate()
            .filter(|(_, n)| !n.tombstoned)
            .map(|(i, _)| i)
            .collect();

        if live.is_empty() {
            return Vec::new();
        }

        // old internal index → compact index mapping.
        let mut old_to_new: std::collections::HashMap<i32, i32> =
            std::collections::HashMap::with_capacity(live.len());
        for (new_idx, &old_idx) in live.iter().enumerate() {
            old_to_new.insert(old_idx as i32, new_idx as i32);
        }

        let mut rows = Vec::new();
        for (new_idx, &old_idx) in live.iter().enumerate() {
            let node = &self.nodes[old_idx];
            for (layer, neighbours) in node.neighbours.iter().enumerate() {
                // Remap neighbour indices: skip tombstoned neighbours (absent from map).
                let remapped: Vec<i32> = neighbours.iter()
                    .filter_map(|&n| old_to_new.get(&n).copied())
                    .collect();

                // Pack as little-endian i32 BLOB.
                let mut blob = Vec::with_capacity(remapped.len() * 4);
                for n in &remapped {
                    blob.extend_from_slice(&n.to_le_bytes());
                }

                rows.push(GraphRow {
                    node_idx: new_idx as i32,
                    node_id: node.item_id.clone(),
                    layer,
                    neighbours_blob: blob,
                    // Emit the graph's generation so VectorStore can filter rows
                    // by serving generation at load time (§4 generation identity).
                    generation: self.generation,
                });
            }
        }
        rows
    }

    /// Reconstruct the HNSW graph from persisted rows.
    ///
    /// `node_bytes` maps compact `node_idx → (item_id, float bytes)`. Nodes
    /// whose compact index is absent from `node_bytes` (their vector was
    /// deleted from the `vectors` table since the last persist) are silently
    /// skipped. `model_id` is set on every reconstructed node so `search`'s
    /// model-id filter returns results correctly.
    ///
    /// Only rows whose `generation == expected_generation` are used (§4 HNSW
    /// generation identity ruling). Rows for a different generation are silently
    /// skipped — they belong to a retired or shadow generation. If no rows
    /// match `expected_generation`, the graph remains empty (has_graph() → false).
    /// On a successful load, `self.generation` is set to `expected_generation`.
    ///
    /// Clears any existing graph before loading.
    pub fn load_from_graph_rows(
        &mut self,
        rows: &[GraphRow],
        node_bytes: &std::collections::HashMap<i32, (String, Vec<u8>)>,
        model_id: &str,
        expected_generation: i64,
    ) {
        self.clear();
        if rows.is_empty() {
            return;
        }
        // Filter to rows whose generation matches the expected (serving) generation.
        // Rows for retired or shadow generations are silently skipped — they belong
        // to a different swap window and must not pollute the reconstructed graph.
        let filtered_rows: Vec<GraphRow> = rows
            .iter()
            .filter(|r| r.generation == expected_generation)
            .map(|r| GraphRow {
                node_idx: r.node_idx,
                node_id: r.node_id.clone(),
                layer: r.layer,
                neighbours_blob: r.neighbours_blob.clone(),
                generation: r.generation,
            })
            .collect();
        if filtered_rows.is_empty() {
            return;
        }
        // Shadow-swap generation identity: stamp this graph with the expected
        // generation so the store can verify it before routing queries here.
        // Performed here (at load time) rather than at the call site to keep
        // the stamp colocated with the filtering logic (§4 ruling).
        // Note: rows is now filtered_rows; rebind to keep phase names intact.
        let rows = filtered_rows.as_slice();

        // Phase 0: validate every row BEFORE any allocation is sized from row
        // data. Persisted graph rows are UNTRUSTED input (VH-01 Finding C):
        // `layer` drives the per-node layer-vector allocation and `node_idx`
        // is a compact array index, so a crafted row must never reach the
        // allocation phases. One invalid row rejects the WHOLE persisted
        // graph — the index stays empty (`has_graph()` → false) and the
        // caller falls back to exact scan until the next THETA rebuild —
        // rather than reconstructing a partial topology from corrupt state.
        // `query_hnsw_graph_rows` applies the same bounds at the store layer;
        // this check also covers direct engine callers.
        for row in rows {
            let blob_len = row.neighbours_blob.len();
            if row.node_idx < 0
                || row.layer > HNSW_MAX_PERSISTED_LAYER
                || blob_len % 4 != 0
                || blob_len > HNSW_M0 * 4
            {
                return;
            }
        }

        // Phase 1: discover distinct compact node indices and per-node layer counts.
        // node_idx → number of layers to allocate for that node.
        let mut node_layer_counts: std::collections::BTreeMap<i32, usize> =
            std::collections::BTreeMap::new();
        for row in rows {
            let entry = node_layer_counts.entry(row.node_idx).or_insert(0);
            if row.layer + 1 > *entry {
                *entry = row.layer + 1;
            }
        }

        if node_layer_counts.is_empty() {
            return;
        }

        // Phase 2: infer vector stride from first available node bytes.
        let stride = match node_bytes.values().next() {
            Some((_, b)) => b.len(),
            None => return,  // no bytes at all — nothing to load
        };
        self.vector_stride = Some(stride);

        // Phase 3: allocate nodes in compact node_idx order. Nodes missing from
        // node_bytes are inserted as placeholder tombstones so neighbour index
        // references remain valid during reconstruction.
        let sorted_idxs: Vec<i32> = node_layer_counts.keys().copied().collect();

        // compact_idx → position in self.nodes (equal when nodes are contiguous).
        let mut compact_to_pos: std::collections::HashMap<i32, usize> =
            std::collections::HashMap::with_capacity(sorted_idxs.len());

        for &cidx in &sorted_idxs {
            let pos = self.nodes.len();
            compact_to_pos.insert(cidx, pos);

            let layer_count = *node_layer_counts.get(&cidx).unwrap_or(&1);
            let empty_layers: Vec<Vec<i32>> = vec![Vec::new(); layer_count];

            if let Some((item_id, bytes)) = node_bytes.get(&cidx) {
                self.nodes.push(Node {
                    item_id: item_id.clone(),
                    model_id: model_id.to_string(),
                    vec_hash: super::fnv1a64(bytes),
                    vector_bytes: bytes.clone(),
                    neighbours: empty_layers,
                    tombstoned: false,
                });
                self.node_index.insert(item_id.clone(), pos as i32);
            } else {
                // Deleted vector: placeholder tombstone preserves compact addressing.
                self.nodes.push(Node {
                    item_id: String::new(),
                    model_id: model_id.to_string(),
                    // Hash of the empty sequence — never compared (tombstones skipped).
                    vec_hash: super::fnv1a64(&[]),
                    vector_bytes: Vec::new(),
                    neighbours: empty_layers,
                    tombstoned: true,
                });
            }
        }

        // Phase 4: fill neighbour lists from the persisted rows.
        // Neighbour indices in the rows are compact indices; remap via compact_to_pos.
        for row in rows {
            let pos = match compact_to_pos.get(&row.node_idx) {
                Some(&p) => p,
                None => continue,
            };
            if self.nodes[pos].tombstoned {
                continue;
            }
            if row.layer < self.nodes[pos].neighbours.len() {
                self.nodes[pos].neighbours[row.layer] = row.decode_neighbours()
                    .into_iter()
                    .filter_map(|cidx| compact_to_pos.get(&cidx).copied().map(|p| p as i32))
                    .collect();
            }
        }

        // Phase 5: elect entry point — the live node with the most layers
        // (ties: lowest position in nodes, i.e. lowest compact index).
        let mut best_pos: Option<usize> = None;
        let mut best_layers = 0usize;
        for &pos in compact_to_pos.values() {
            let node = &self.nodes[pos];
            if node.tombstoned {
                continue;
            }
            let layers = node.neighbours.len();
            if layers > best_layers {
                best_layers = layers;
                best_pos = Some(pos);
            } else if layers == best_layers && best_pos.map_or(true, |bp| pos < bp) {
                best_pos = Some(pos);
            }
        }

        if let Some(pos) = best_pos {
            self.entry_point = Some(pos as i32);
            self.max_layer = best_layers.saturating_sub(1);
        }

        // Stamp the generation AFTER the graph is successfully loaded (§4).
        // If has_graph() is false (all nodes were deleted), the generation stays
        // at 0 — the store treats an absent graph as absent regardless.
        if self.has_graph() {
            self.generation = expected_generation;
        }
    }

    // MARK: - Observability

    /// Total node count (including tombstoned).
    pub fn total_count(&self) -> usize {
        self.nodes.len()
    }

    /// Live (non-tombstoned) node count.
    pub fn live_count(&self) -> usize {
        self.nodes.iter().filter(|n| !n.tombstoned).count()
    }

    // MARK: - Private helpers

    /// Decode stored bytes of node `idx` to Vec<f32> for distance computation.
    fn node_to_floats(&self, idx: usize) -> Vec<f32> {
        bytes_to_floats(&self.nodes[idx].vector_bytes)
    }
}

// MARK: - Float helpers (private, file-local)

/// Decode one IEEE-754 LE float32 from a byte slice at float index `i`.
fn decode_f32_le_at(bytes: &[u8], i: usize) -> f32 {
    let base = i * 4;
    let bits = (bytes[base] as u32)
        | ((bytes[base + 1] as u32) << 8)
        | ((bytes[base + 2] as u32) << 16)
        | ((bytes[base + 3] as u32) << 24);
    f32::from_bits(bits)
}

/// Decode a LE float32 byte slice to Vec<f32>.
fn bytes_to_floats(bytes: &[u8]) -> Vec<f32> {
    let count = bytes.len() / 4;
    (0..count).map(|i| decode_f32_le_at(bytes, i)).collect()
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn make_index() -> HNSWIndex {
        HNSWIndex::new_default()
    }

    fn v3(x: f32, y: f32, z: f32) -> Vec<f32> {
        vec![x, y, z]
    }

    // MARK: - Basic insert + search

    #[test]
    fn empty_index_returns_empty() {
        let idx = make_index();
        let result = idx.search(&[1.0, 0.0, 0.0], "m", 5).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn single_insert_then_search() {
        let mut idx = make_index();
        idx.insert("a".into(), "m".into(), v3(1.0, 0.0, 0.0));
        let results = idx.search(&[1.0, 0.0, 0.0], "m", 1).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].item_id, "a");
    }

    #[test]
    fn identical_vector_distance_near_zero() {
        let mut idx = make_index();
        let v = v3(0.6, 0.8, 0.0);
        idx.insert("a".into(), "m".into(), v.clone());
        let results = idx.search(&v, "m", 1).unwrap();
        assert_eq!(results.len(), 1);
        let dist_f = results[0].distance as f32 / 10_000.0;
        assert!(dist_f.abs() < 1e-2, "expected ~0 cosine distance, got {}", dist_f);
    }

    #[test]
    fn model_id_filter() {
        let mut idx = make_index();
        idx.insert("a".into(), "model-a".into(), v3(1.0, 0.0, 0.0));
        idx.insert("b".into(), "model-b".into(), v3(1.0, 0.0, 0.0));
        let results = idx.search(&[1.0, 0.0, 0.0], "model-a", 5).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].item_id, "a");
    }

    #[test]
    fn upsert_replaces_old_node() {
        let mut idx = make_index();
        idx.insert("a".into(), "m".into(), v3(1.0, 0.0, 0.0));
        idx.insert("a".into(), "m".into(), v3(0.0, 1.0, 0.0));
        // After upsert, there is one live node (the new one).
        assert_eq!(idx.live_count(), 1);
    }

    // MARK: - Tombstone + compact

    #[test]
    fn tombstone_excludes_from_search() {
        let mut idx = make_index();
        idx.insert("a".into(), "m".into(), v3(1.0, 0.0, 0.0));
        idx.insert("b".into(), "m".into(), v3(0.0, 1.0, 0.0));
        idx.tombstone("a");
        let results = idx.search(&[1.0, 0.0, 0.0], "m", 5).unwrap();
        assert!(results.iter().all(|r| r.item_id != "a"),
            "tombstoned node 'a' must not appear in search results");
    }

    #[test]
    fn compact_removes_tombstones() {
        let mut idx = make_index();
        idx.insert("a".into(), "m".into(), v3(1.0, 0.0, 0.0));
        idx.insert("b".into(), "m".into(), v3(0.0, 1.0, 0.0));
        idx.tombstone("a");
        idx.compact();
        assert_eq!(idx.live_count(), 1);
        // 'b' is still searchable after compact.
        let results = idx.search(&[0.0, 1.0, 0.0], "m", 1).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].item_id, "b");
    }

    // MARK: - Clear

    #[test]
    fn clear_empties_index() {
        let mut idx = make_index();
        idx.insert("a".into(), "m".into(), v3(1.0, 0.0, 0.0));
        idx.clear();
        assert_eq!(idx.total_count(), 0);
        let results = idx.search(&[1.0, 0.0, 0.0], "m", 5).unwrap();
        assert!(results.is_empty());
    }

    // MARK: - Dim mismatch

    #[test]
    fn insert_dim_mismatch_is_noop() {
        let mut idx = make_index();
        idx.insert("a".into(), "m".into(), v3(1.0, 0.0, 0.0)); // stride=12
        idx.insert("b".into(), "m".into(), vec![1.0, 0.0]);     // stride=8 → mismatch
        // 'b' must not appear; only 'a' is in the index.
        assert_eq!(idx.live_count(), 1);
    }

    #[test]
    fn search_dim_mismatch_returns_error() {
        let mut idx = make_index();
        idx.insert("a".into(), "m".into(), v3(1.0, 0.0, 0.0)); // dim=3
        let err = idx.search(&[1.0, 0.0], "m", 1);             // dim=2 → mismatch
        assert!(err.is_err());
    }

    // MARK: - Recall quality

    #[test]
    fn recall_quality_at_threshold() {
        // Build a 200-vector corpus (enough to exercise multi-layer topology)
        // and verify HNSW finds ≥90% of the BF oracle's top-10.
        use crate::engine::float_brute_force::FloatBruteForceIndex;
        use crate::engine::metric::DenseMetric;
        use crate::engine::payload::VectorPayload;
        use crate::engine::key::VectorRecordKey;
        use crate::engine::seam::DenseIndex;

        let dim: usize = 64;
        let n: usize = 200;
        let k: usize = 10;

        // Deterministic corpus: use SplitMix64 directly for reproducibility.
        let mut rng: u64 = 0xDEADBEEF;
        let mut next = |rng: &mut u64| -> u64 {
            *rng = rng.wrapping_add(0x9e3779b97f4a7c15);
            let mut z = *rng;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
            z ^ (z >> 31)
        };

        // Generate vectors as unit-normalized float32.
        let mut raw_vecs: Vec<Vec<f32>> = Vec::with_capacity(n);
        for _ in 0..n {
            let v: Vec<f32> = (0..dim)
                .map(|_| {
                    // Uniform [-1, 1] from top 24 bits.
                    let r = next(&mut rng);
                    (r >> 40) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0
                })
                .collect();
            // Normalize.
            let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            let v_norm: Vec<f32> = if norm > 0.0 {
                v.iter().map(|x| x / norm).collect()
            } else {
                v
            };
            raw_vecs.push(v_norm);
        }

        // Build HNSW.
        let mut hnsw = HNSWIndex::new(12345);
        let mut payloads_for_bf: Vec<VectorPayload> = Vec::with_capacity(n);
        let mut keys_for_bf: Vec<VectorRecordKey> = Vec::with_capacity(n);
        for (i, v) in raw_vecs.iter().enumerate() {
            let item_id = format!("item-{}", i);
            hnsw.insert(item_id.clone(), "m".into(), v.clone());
            payloads_for_bf.push(VectorPayload::from_f32(v));
            keys_for_bf.push(VectorRecordKey::new(&item_id, 0, "m", "1"));
        }

        // Build BF oracle.
        let mut bf = FloatBruteForceIndex::new();
        bf.build(&payloads_for_bf, &keys_for_bf).unwrap();

        // Query with a deterministic probe.
        let probe_vec: Vec<f32> = raw_vecs[0].clone();
        let probe_payload = VectorPayload::from_f32(&probe_vec);

        let hnsw_results = hnsw.search(&probe_vec, "m", k).unwrap();
        let bf_results = bf.search(&probe_payload, DenseMetric::COSINE, k, None).unwrap();

        let hnsw_ids: std::collections::HashSet<&str> =
            hnsw_results.iter().map(|r| r.item_id.as_str()).collect();
        let bf_ids: std::collections::HashSet<&str> =
            bf_results.iter().map(|h| h.key.item_id.as_str()).collect();

        let overlap: usize = hnsw_ids.intersection(&bf_ids).count();
        let recall = overlap as f64 / k as f64;
        assert!(
            recall >= 0.90,
            "HNSW recall@{} = {:.2} (< 0.90); overlap={}/{}; hnsw={:?}; bf={:?}",
            k,
            recall,
            overlap,
            k,
            hnsw_results.iter().map(|r| &r.item_id).collect::<Vec<_>>(),
            bf_results.iter().map(|h| &h.key.item_id).collect::<Vec<_>>(),
        );
    }

    // MARK: - Content-stable bulk build order (HNSW-DETERMINISM)

    /// Bulk path: same rows, two different arrival orders → identical graph.
    ///
    /// `compact()` (and `VectorStore::rebuild_hnsw_index`, which applies the
    /// same ordering before insertion) sorts rows by
    /// (fnv1a64(payload bytes) ASC, item_id ASC) before inserting, so a bulk
    /// rebuild from the same row set is order-independent. Twin of Swift
    /// `bulkRebuildIsContentStableAcrossArrivalOrders`.
    #[test]
    fn bulk_rebuild_is_content_stable_across_arrival_orders() {
        // SplitMix64 (same algorithm as the index RNG) for deterministic vectors.
        let mut rng: u64 = 7;
        let mut next = |state: &mut u64| -> u64 {
            *state = state.wrapping_add(0x9e3779b97f4a7c15);
            let mut z = *state;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
            z ^ (z >> 31)
        };
        let dim = 8;
        let n = 60;
        let corpus: Vec<(String, Vec<f32>)> = (0..n)
            .map(|i| {
                let mut v: Vec<f32> = (0..dim)
                    .map(|_| (next(&mut rng) >> 40) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0)
                    .collect();
                let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
                if norm > 0.0 {
                    for x in v.iter_mut() {
                        *x /= norm;
                    }
                }
                (format!("item-{:03}", i), v)
            })
            .collect();

        // Arrival order 1: natural. Arrival order 2: reversed. Both consume the
        // same number of RNG draws before compact(), so the level-assignment
        // sequence at rebuild time is identical — any graph difference can only
        // come from insertion ORDER.
        let mut idx1 = make_index();
        for (id, v) in &corpus {
            idx1.insert(id.clone(), "model-x".into(), v.clone());
        }
        idx1.compact();

        let mut idx2 = make_index();
        for (id, v) in corpus.iter().rev() {
            idx2.insert(id.clone(), "model-x".into(), v.clone());
        }
        idx2.compact();

        // Graph identity: row-for-row identical (node_id, layer, neighbour blob).
        let rows1 = idx1.graph_rows();
        let rows2 = idx2.graph_rows();
        assert_eq!(rows1.len(), rows2.len(), "graph row counts differ");
        for (r1, r2) in rows1.iter().zip(rows2.iter()) {
            assert_eq!(r1.node_id, r2.node_id, "node order differs");
            assert_eq!(r1.layer, r2.layer, "layer structure differs");
            assert_eq!(
                r1.neighbours_blob, r2.neighbours_blob,
                "neighbour list differs for node {} layer {}",
                r1.node_id, r1.layer
            );
        }

        // Probe identity: identical (item_id, distance) sequence from both graphs.
        let mut prng: u64 = 99;
        let mut probe: Vec<f32> = (0..dim)
            .map(|_| (next(&mut prng) >> 40) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0)
            .collect();
        let p_norm: f32 = probe.iter().map(|x| x * x).sum::<f32>().sqrt();
        if p_norm > 0.0 {
            for x in probe.iter_mut() {
                *x /= p_norm;
            }
        }
        let h1 = idx1.search(&probe, "model-x", 10).unwrap();
        let h2 = idx2.search(&probe, "model-x", 10).unwrap();
        let seq1: Vec<(String, i32)> = h1.iter().map(|m| (m.item_id.clone(), m.distance)).collect();
        let seq2: Vec<(String, i32)> = h2.iter().map(|m| (m.item_id.clone(), m.distance)).collect();
        assert_eq!(seq1, seq2, "probe result sequences differ");
    }
}
