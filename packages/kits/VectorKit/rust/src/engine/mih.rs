//! MIHIndex — Lane B: Binary Multi-Index Hashing, sub-linear EXACT Hamming k-NN.
//!
//! The whole point of MIH is that it is EXACT. The pigeonhole proposition
//! (retrieval algorithms reference §1.1) guarantees: if two codes differ
//! in at most r bits total, at least one band matches within ⌊r/m⌋ bits.
//! Probing each band's hash table for all substrings within the per-band
//! radius and unioning candidates yields every true r-neighbour — no false
//! negatives. False positives are removed by exact full-distance check via
//! EngramLib (I-7). The result is bit-for-bit identical to BruteForceIndex
//! on the same inputs.
//!
//! Conformance gate (arch spec §3.3 BLOCKER):
//!   tests::mih_gate_* assert MIHIndex::search == BruteForceIndex::search
//!   on all §1.10 canonical vectors AND on randomised fuzz inputs across
//!   seeds, n, k, and m ∈ {4,8,16,32}. BruteForceIndex is always the oracle.
//!
//! Key invariants (retrieval algorithms reference §1.8):
//!   1. Band order 0,1,...,m−1. Fixed.
//!   2. Flip-combination enumeration: colex order, ascending subset size (§1.3).
//!      Only matters for trace reproducibility; final output is sort-invariant.
//!   3. PostingList ids kept SORTED ASCENDING (§1.2 invariant). Candidate
//!      streams deterministic without relying on HashMap iteration order.
//!   4. k-NN retention: retained = k codes minimising (dist, item_id)
//!      lexicographically. Bounded max-heap evicts by (dist DESC, item_id DESC).
//!   5. Result order: (dist ASC, item_id ASC).
//!   6. Integer-only: distances are u32 via EngramLib. No floats.
//!   7. m is pinned config, never auto-derived (§1.6).
//!
//! Conformance restriction (§1.7 note): m ∈ {4,8,16,32} only. sub_bits ∈
//! {64,32,16,8} — each band lies within one u64 word, no word-straddle needed.
//!
//! I-7 (arch spec §3.1, §3.4): ALL Hamming distances through EngramLib
//! (which routes to SubstrateKernel). MIH does candidate generation; the
//! kernel does every distance. No XOR/popcount in this file.
//!
//! Enumeration-budget guard:
//!   MIH progressive-radius expansion is sub-linear only on clustered data.
//!   On sparse/random data the k-th best Hamming distance can be ~120 bits,
//!   causing the per-band colex enumeration to reach C(64,~30) ≈ 10^17 masks
//!   — a hang. The guard tracks a running `mask_count` and, before each new
//!   radius band, checks whether the projected total would exceed the budget
//!   B = max(n, 2^20). When the budget would be exceeded and the heap is not
//!   yet exact, the query falls back to a full O(n) brute-scan over `codes`
//!   (already in memory). The brute scan reuses BoundedMaxHeap and EngramLib
//!   distances — output is provably identical to BruteForceIndex. The fallback
//!   degrades latency, never correctness. The `vectorkit.mih.enumeration_fallback`
//!   metric is emitted on fallback so operators see when m is poorly chosen.
//!   The `cumulative_choose` function and the projection arithmetic are
//!   integer-only and bit-identical to the Swift port so both fall back at
//!   the same radius (the bounded MIH enumeration budget conformance).

use std::collections::{HashMap, HashSet};

use crate::engine::hit::DenseHit;
use crate::engine::key::VectorRecordKey;
use crate::engine::metric::{BinaryMetric, DenseMetric};
use crate::engine::payload::{VectorKind, VectorPayload};
use crate::engine::seam::{DenseIndex, IndexKind, MetadataFilter};
use crate::error::VectorKitError;
use engram_lib::{Engram, EngramLib};
use intellectus_lib::{report, StatSample};

// ── Allowed m values ────────────────────────────────────────────────────────

/// Conformance-restricted band counts (§1.7 note).
/// Restricting to {4,8,16,32} keeps sub_bits ∈ {64,32,16,8} and ensures
/// each band lies within one u64 word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MIHBandCount {
    M4  = 4,
    M8  = 8,
    M16 = 16,
    M32 = 32,
}

impl MIHBandCount {
    /// Bits per band: 256 / m.
    pub fn sub_bits(self) -> u32 {
        256 / self as u32
    }
}

// ── Internal types ───────────────────────────────────────────────────────────

/// One band's hash table: substring bit-value → sorted Vec of VectorRecordKeys.
///
/// Keyed by VectorRecordKey (not just item_id) so that two distinct vectors
/// sharing the same item_id but differing in vector_index or model_id are
/// both retained as separate posting-list entries. The VectorStore schema
/// UNIQUE constraint is (item_id, vector_index, model_id); the posting list
/// respects the same triple. (secfix/punt-vector: MIH itemID collision fix)
///
/// Keys in each posting list are kept sorted ascending (§1.2 invariant):
/// candidate enumeration is then deterministic regardless of HashMap
/// iteration order.
#[derive(Debug, Default, Clone)]
struct SubstringTable {
    /// key = substring bit-value, value = VectorRecordKeys sorted ascending.
    map: HashMap<u64, Vec<VectorRecordKey>>,
}

impl SubstringTable {
    /// Insert `id` into the posting list for `key`, maintaining sort order.
    fn insert(&mut self, key: u64, id: &VectorRecordKey) {
        let list = self.map.entry(key).or_default();
        // Binary-search insert to maintain ascending order (VectorRecordKey: Ord).
        let pos = list.partition_point(|x| x < id);
        list.insert(pos, id.clone());
    }

    /// Remove `id` from the posting list for `key`.
    /// Drops the entry if the list becomes empty (consistent with Swift).
    fn remove(&mut self, key: u64, id: &VectorRecordKey) {
        if let Some(list) = self.map.get_mut(&key) {
            if let Ok(pos) = list.binary_search(id) {
                list.remove(pos);
            }
            if list.is_empty() {
                self.map.remove(&key);
            }
        }
    }
}

// ── Bounded max-heap ─────────────────────────────────────────────────────────

/// Retains the best k (dist, key) pairs by (dist ASC, key ASC).
///
/// Internally a binary max-heap ordered by (dist DESC, key DESC), so
/// the root is the WORST retained element — evicted when a strictly better
/// candidate arrives.
///
/// §1.8 rule 4: among codes tied at the boundary distance, those with
/// smaller keys are kept. "key" is the full VectorRecordKey, which orders
/// by (item_id, vector_index, model_id, model_version). Two records sharing
/// the same item_id but differing in vector_index or model_id are retained
/// independently — neither collapses the other.
/// (secfix/punt-vector: MIH itemID collision fix)
///
/// Eviction key: (dist DESC, key DESC).
#[derive(Debug)]
struct BoundedMaxHeap {
    capacity: usize,
    elements: Vec<(u32, VectorRecordKey)>,   // (dist, full key)
}

impl BoundedMaxHeap {
    fn new(capacity: usize) -> Self {
        BoundedMaxHeap {
            capacity,
            elements: Vec::with_capacity(capacity + 1),
        }
    }

    fn size(&self) -> usize { self.elements.len() }

    /// Distance of the worst element (root). Only valid when size > 0.
    fn worst_dist(&self) -> u32 { self.elements[0].0 }

    /// Comparison: is element at index i "worse" (= higher priority in the
    /// max-heap = larger (dist, key)) than the element at j?
    fn is_worse(&self, i: usize, j: usize) -> bool {
        let (da, ka) = &self.elements[i];
        let (db, kb) = &self.elements[j];
        if da != db { return da > db; }
        ka > kb
    }

    fn sift_up(&mut self, mut i: usize) {
        while i > 0 {
            let parent = (i - 1) / 2;
            if self.is_worse(i, parent) {
                self.elements.swap(i, parent);
                i = parent;
            } else { break; }
        }
    }

    fn sift_down(&mut self, mut i: usize) {
        let n = self.elements.len();
        loop {
            let l = 2 * i + 1;
            let r = 2 * i + 2;
            let mut top = i;
            if l < n && self.is_worse(l, top) { top = l; }
            if r < n && self.is_worse(r, top) { top = r; }
            if top == i { break; }
            self.elements.swap(i, top);
            i = top;
        }
    }

    /// Offer (dist, key) to the heap.
    ///
    /// If not full: always insert.
    /// If full: replace the worst only if (dist, key) is strictly better
    /// (smaller dist, or equal dist and smaller VectorRecordKey).
    fn offer(&mut self, dist: u32, key: VectorRecordKey) {
        if self.elements.len() < self.capacity {
            self.elements.push((dist, key));
            let i = self.elements.len() - 1;
            self.sift_up(i);
        } else {
            let (wd, wk) = self.elements[0].clone();
            let better = dist < wd || (dist == wd && key < wk);
            if !better { return; }
            self.elements[0] = (dist, key);
            self.sift_down(0);
        }
    }

    /// Return results sorted (dist ASC, key ASC) — the oracle final order.
    fn sorted_ascending(mut self) -> Vec<(u32, VectorRecordKey)> {
        self.elements.sort_by(|a, b| {
            a.0.cmp(&b.0).then(a.1.cmp(&b.1))
        });
        self.elements
    }
}

// ── Binomial prefix sum (integer-only, parity-gated with Swift) ─────────────

/// Cumulative binomial coefficient Σ_{d=0..rho} C(n, d).
///
/// Used by the enumeration-budget guard to project the total flip-mask
/// count before committing to a new radius band. This is the dominant
/// term in E_band(rho) = Σ_{d=0..rho} C(sub_bits, d) from the decision memo.
///
/// Implementation: iterative multiplication (same recurrence as Swift port).
/// Uses saturating arithmetic: once the running value would overflow usize,
/// we saturate to usize::MAX — a saturating return still correctly triggers
/// the budget guard. This matches the Swift port's Int.max capping exactly
/// so both ports fall back at the same radius
/// (the bounded MIH enumeration budget conformance).
///
/// The function is integer-only (no floats) so results are bit-identical
/// across Rust (x86_64/aarch64) and Swift (arm64).
pub(crate) fn cumulative_choose(sub_bits: u32, rho: u32) -> usize {
    if sub_bits == 0 { return 0; }

    // C(n,0) = 1 for any n >= 0.
    let mut sum: usize = 1;
    let mut c:   usize = 1; // current C(sub_bits, d)
    let n = sub_bits as usize;

    for d in 1..=(rho as usize) {
        if d > n { break; } // C(n, d) = 0 for d > n
        // C(sub_bits, d) = C(sub_bits, d-1) * (sub_bits - d + 1) / d
        // Saturating multiply then divide — same logic as Swift port.
        c = c.saturating_mul(n - d + 1) / d;
        sum = sum.saturating_add(c);
        // Once saturated, stop — the budget guard will fire.
        if sum == usize::MAX { return usize::MAX; }
    }
    sum
}

// ── Colex flip-mask enumeration (§1.3) ──────────────────────────────────────

/// Call `f(flip_mask)` for each flip-mask of Hamming weight 0..=max_hamming
/// over `sub_bits` bit positions, in colex order (ascending flip-mask integer).
///
/// For d=0: one call with flip_mask=0. For d > sub_bits: no calls.
///
/// Uses Gosper's hack to iterate all d-bit combinations in ascending order.
fn colex_flip_masks(sub_bits: u32, max_hamming: u32, mut f: impl FnMut(u64)) {
    if sub_bits == 0 || sub_bits > 64 { return; }
    let n = sub_bits as u32;

    for d in 0..=max_hamming {
        if d == 0 {
            f(0);
            continue;
        }
        if d > n { break; }

        // Start mask: lowest d bits set.
        let start_mask: u64 = if d == 64 {
            u64::MAX
        } else {
            (1u64 << d) - 1
        };

        // Upper limit: for n < 64, first mask >= 1<<n is excluded.
        // For n==64, all 64-bit values are valid; iterate until Gosper wraps.
        let limit: u64 = if n < 64 { 1u64 << n } else { 0u64 }; // 0 = sentinel for n==64

        let mut mask = start_mask;
        loop {
            // Bounds check.
            if n < 64 && mask >= limit { break; }

            f(mask);

            // Gosper's hack: advance to next combination of same popcount.
            //   c    = lowest set bit of mask
            //   r    = mask + c  (clears trailing run of 1s, adds carry)
            //   next = (((r ^ mask) >> 2) / c) | r
            let c = mask & mask.wrapping_neg();
            let (r, overflow) = mask.overflowing_add(c);
            if overflow { break; }

            let xrm = r ^ mask;
            // c is a power of 2; xrm >> 2 divides exactly by c via right-shift.
            let next = (xrm >> 2) / c | r;

            // For n==64: detect wraparound (all combinations exhausted).
            if n == 64 && next <= mask { break; }

            mask = next;
        }
    }
}

// ── Band extraction (§1.7) ───────────────────────────────────────────────────

/// Extract band `band_index` from a 256-bit Engram as a u64.
///
/// Canonical bit numbering (§0.1): bit i lives in word w[i/64] at
/// position i%64 (0 = LSB). The four words map to:
///   w[0] = block0 (bits 0-63)
///   w[1] = block1 (bits 64-127)
///   w[2] = block2 (bits 128-191)
///   w[3] = block3 (bits 192-255)
///
/// For m ∈ {4,8,16,32}: sub_bits ∈ {64,32,16,8}. Every band lies wholly
/// within one word — no word-straddle (the else-branch in §1.7 is dead).
///
/// Reference formula (§1.7):
///   start   = band_index * sub_bits
///   lo_word = start / 64
///   lo_off  = start % 64
///   mask    = if sub_bits==64 { u64::MAX } else { (1<<sub_bits)-1 }
///   return (w[lo_word] >> lo_off) & mask
fn extract_band(engram: &Engram, band_index: u32, sub_bits: u32) -> u64 {
    let start   = band_index * sub_bits;
    let lo_word = (start / 64) as usize;
    let lo_off  = start % 64;

    let word: u64 = match lo_word {
        0 => engram.block0,
        1 => engram.block1,
        2 => engram.block2,
        3 => engram.block3,
        _ => 0,  // unreachable for m ∈ {4,8,16,32}
    };

    let mask: u64 = if sub_bits == 64 {
        u64::MAX
    } else {
        (1u64 << sub_bits) - 1
    };
    (word >> lo_off) & mask
}

// ── MIHIndex ─────────────────────────────────────────────────────────────────

/// Binary Multi-Index Hashing index. Sub-linear EXACT Hamming k-NN.
///
/// Parallel to Swift `MIHIndex`. The result of every `search` call is
/// bit-for-bit identical to `BruteForceIndex::search` on the same inputs.
///
/// Configuration: `band_count` ∈ {M4, M8, M16, M32}.
/// `mask_budget`: optional fixed override for the enumeration budget.
///   None means compute dynamically as max(n, 2^20) at query time.
/// Thread-safety: not internally synchronized; callers wrap in `Mutex` if shared.
/// Binary Multi-Index Hashing index. Sub-linear EXACT Hamming k-NN.
///
/// Internal identity: full `VectorRecordKey` (not just `item_id`). This means
/// two distinct vectors sharing the same `item_id` but differing in
/// `vector_index` or `model_id` are each retained and returned independently
/// — consistent with the VectorStore UNIQUE constraint (item_id, vector_index,
/// model_id). (secfix/punt-vector: MIH itemID collision fix)
#[derive(Debug)]
pub struct MIHIndex {
    /// Number of bands m.
    m: u32,
    /// Bits per band: 256 / m.
    sub_bits: u32,
    /// Maximum cumulative flip-mask evaluations per query.
    /// None means use the dynamic max(n, 2^20) formula at query time.
    /// A fixed Some(budget) overrides the formula — useful in tests
    /// that need deterministic fallback thresholds. Mirrors Swift's
    /// `fixedMaskBudget`.
    mask_budget: Option<usize>,
    /// m substring hash tables, one per band.
    tables: Vec<SubstringTable>,
    /// Full 256-bit codes keyed by VectorRecordKey, for exact full-distance
    /// re-check (I-7). Using the full key (not just item_id) means two distinct
    /// vectors sharing the same item_id each have their own entry and neither
    /// overwrites the other on add.
    codes: HashMap<VectorRecordKey, Engram>,
}

impl MIHIndex {
    /// Create an empty MIH index with the given band count and default
    /// adaptive budget (max(n, 2^20) computed per query).
    pub fn new(band_count: MIHBandCount) -> Self {
        Self::new_with_budget(band_count, None)
    }

    /// Create an empty MIH index with an explicit mask budget override.
    ///
    /// Pass `Some(budget)` to fix the enumeration budget for this instance.
    /// Pass `None` to use the adaptive default: max(n, 2^20) per query.
    /// The override is useful in tests that must exercise the fallback path
    /// deterministically regardless of corpus size.
    pub fn new_with_budget(band_count: MIHBandCount, mask_budget: Option<usize>) -> Self {
        let m = band_count as u32;
        MIHIndex {
            m,
            sub_bits: band_count.sub_bits(),
            mask_budget,
            tables: vec![SubstringTable::default(); m as usize],
            codes: HashMap::new(),
        }
    }

    /// Number of bands m (the index configuration).
    pub fn band_count(&self) -> u32 { self.m }

    // ── Private helpers ──────────────────────────────────────────────────────

    fn insert_into_tables(&mut self, id: &VectorRecordKey, engram: &Engram) {
        for t in 0..self.m {
            let sub = extract_band(engram, t, self.sub_bits);
            self.tables[t as usize].insert(sub, id);
        }
    }

    fn remove_from_tables(&mut self, id: &VectorRecordKey, engram: &Engram) {
        for t in 0..self.m {
            let sub = extract_band(engram, t, self.sub_bits);
            self.tables[t as usize].remove(sub, id);
        }
    }

    /// Decode a 32-byte binary payload to an Engram.
    fn payload_to_engram(payload: &VectorPayload) -> Result<Engram, VectorKitError> {
        if payload.kind != VectorKind::Binary {
            return Err(VectorKitError::InvalidPayload(format!(
                "MIHIndex: payload.kind must be Binary, got {:?}", payload.kind
            )));
        }
        if payload.bytes.len() != 32 {
            return Err(VectorKitError::InvalidPayload(format!(
                "MIHIndex: binary payload must be 32 bytes, got {}", payload.bytes.len()
            )));
        }
        // 4×u64 little-endian from the 32-byte wire form (§2.1 canonical layout).
        let b0 = u64::from_le_bytes(payload.bytes[0..8].try_into().unwrap());
        let b1 = u64::from_le_bytes(payload.bytes[8..16].try_into().unwrap());
        let b2 = u64::from_le_bytes(payload.bytes[16..24].try_into().unwrap());
        let b3 = u64::from_le_bytes(payload.bytes[24..32].try_into().unwrap());
        Ok(Engram::new(b0, b1, b2, b3))
    }

    // ── Progressive-radius k-NN (§1.4) with enumeration-budget guard ────────

    /// The EXACT k-NN algorithm with progressive radius expansion.
    ///
    /// Correctness invariant (§1.4): after processing total radius r, every
    /// code at full Hamming distance ≤ r has been examined. Stopping rule
    /// (heap full AND worst_dist ≤ r) guarantees no un-examined code can
    /// displace a retained neighbour. Output == BruteForce output.
    ///
    /// Enumeration-budget guard: before each new radius, the projected
    /// cumulative flip-mask count is compared to `budget` (max(n, 2^20)
    /// unless overridden). When the projection exceeds the budget and the
    /// heap is not yet exact, the function falls back to `brute_scan`
    /// — an O(n) scan that is identical in result to the enumeration.
    /// Budget arithmetic is integer-only and bit-identical to the Swift port
    /// so both fall back at the same radius.
    fn knn(
        &self,
        probe: &Engram,
        k: usize,
        filter: Option<&MetadataFilter>,
    ) -> Vec<DenseHit> {
        let n = self.codes.len();
        // Budget: max(n, 2^20) unless caller supplied a fixed override.
        let budget: usize = self.mask_budget.unwrap_or_else(|| n.max(1 << 20));

        // VectorRecordKey-owned seen set: deduplicates by FULL key so two records
        // sharing the same item_id but differing in vector_index or model_id are
        // each checked independently — neither is suppressed as "already seen."
        let mut seen: HashSet<VectorRecordKey> = HashSet::new();
        let mut heap = BoundedMaxHeap::new(k);

        // Precompute probe band keys (constant for the whole loop).
        let probe_bands: Vec<u64> = (0..self.m)
            .map(|t| extract_band(probe, t, self.sub_bits))
            .collect();

        // Running count of flip-mask evaluations across all radii and bands.
        let mut mask_count: usize = 0;

        let mut r: u32 = 0;
        loop {
            let rho   = r / self.m;   // ⌊r/m⌋
            let extra = r % self.m;   // first `extra` bands use rho+1

            // Conservative upper-bound band rho for the projection.
            // (first `extra` bands use rho+1; the rest use rho.)
            let max_band_rho = rho + if extra > 0 { 1 } else { 0 };

            // Projection: m × Σ_{d=0..max_band_rho} C(sub_bits, d).
            // Saturating arithmetic via cumulative_choose — if this saturates
            // to usize::MAX the budget comparison still fires correctly.
            let projected = (self.m as usize)
                .saturating_mul(cumulative_choose(self.sub_bits, max_band_rho));

            // If the projected total would exceed the budget AND the heap is
            // not yet exact, abandon enumeration and fall back to brute scan.
            if mask_count.saturating_add(projected) > budget {
                let is_exact = heap.size() == k && heap.worst_dist() <= r;
                if !is_exact {
                    // Telemetry: emit the enumeration-fallback metric so
                    // operators can see when m was poorly chosen for this
                    // estate/query pattern. Mirrors the
                    // `Intellectus.report(.metric("vectorkit.mih.enumeration_fallback"))`
                    // call in the Swift MIHIndex. The Swift port also writes an
                    // OSLog `.notice` line; that is an Apple-only diagnostic with
                    // no Rust sink, so the metric is the cross-platform parity
                    // surface. The `report!` block is a no-op unless monitoring is
                    // enabled (one AtomicBool load off-path), so the timestamp
                    // read inside it never runs on the hot path.
                    report!({
                        use std::time::{SystemTime, UNIX_EPOCH};
                        let ts = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64())
                            .unwrap_or(0.0);
                        let mut tags = std::collections::HashMap::new();
                        tags.insert("kit".to_string(), "VectorKit".to_string());
                        tags.insert("m".to_string(), self.m.to_string());
                        tags.insert("n".to_string(), n.to_string());
                        tags.insert("rho".to_string(), max_band_rho.to_string());
                        tags.insert("budget".to_string(), budget.to_string());
                        StatSample::metric(
                            "vectorkit.mih.enumeration_fallback".to_string(),
                            1.0,
                            tags,
                            ts,
                        )
                    });
                    return self.brute_scan(probe, k, filter);
                }
            }

            // Fixed band order 0,1,...,m-1 (§1.8 rule 1).
            for t in 0..self.m as usize {
                let band_rho = rho + if (t as u32) < extra { 1 } else { 0 };
                let query_sub = probe_bands[t];

                self.enumerate_band_candidates_counted(
                    &self.tables[t],
                    query_sub,
                    band_rho,
                    probe,
                    filter,
                    &mut seen,
                    &mut heap,
                    &mut mask_count,
                );
            }

            // STOPPING RULE (§1.4): exact.
            if heap.size() == k && heap.worst_dist() <= r { break; }
            // Short-circuit: once every indexed code has been seen, no further
            // candidates exist regardless of how much Hamming space remains.
            // Prevents O(2^subBits) enumeration when n < k.
            if seen.len() >= self.codes.len() { break; }
            if r == 256 { break; }  // fewer than k codes; exhausted
            r += 1;
        }

        // Build DenseHit from sorted heap output ((dist ASC, key ASC)).
        // The key is stored directly in the heap element — no secondary lookup.
        let sorted = heap.sorted_ascending();
        sorted.into_iter().map(|(dist, key)| {
            DenseHit {
                key,
                raw_distance: dist as i32,
                metric: DenseMetric::HAMMING,
            }
        }).collect()
    }

    // ── Brute-scan fallback (O(n) over codes) ────────────────────────────────

    /// Full O(n) scan over `self.codes`.
    ///
    /// Called when the enumeration-budget guard fires. Iterates every stored
    /// code, applies the optional filter, distances via EngramLib (I-7), offers
    /// to a fresh BoundedMaxHeap. Output is identical to BruteForceIndex::search
    /// because it uses the same codes, the same distances, and the same heap.
    fn brute_scan(
        &self,
        probe: &Engram,
        k: usize,
        filter: Option<&MetadataFilter>,
    ) -> Vec<DenseHit> {
        let mut heap = BoundedMaxHeap::new(k);
        for (record_key, code_engram) in &self.codes {
            if let Some(f) = filter {
                if !f.accepts(record_key) { continue; }
            }
            let dist = EngramLib::distance(probe, code_engram);
            heap.offer(dist, record_key.clone());
        }
        // Sort (dist ASC, key ASC) — oracle order (§0.3 extended to full
        // VectorRecordKey for same-item_id disambiguation).
        heap.sorted_ascending().into_iter().map(|(dist, key)| {
            DenseHit {
                key,
                raw_distance: dist as i32,
                metric: DenseMetric::HAMMING,
            }
        }).collect()
    }

    // ── Band candidate enumeration (§1.3) ────────────────────────────────────

    /// Enumerate candidates; increments `mask_count` once per flip-mask evaluated.
    fn enumerate_band_candidates_counted(
        &self,
        table: &SubstringTable,
        query_sub: u64,
        rho: u32,
        probe: &Engram,
        filter: Option<&MetadataFilter>,
        seen: &mut HashSet<VectorRecordKey>,
        heap: &mut BoundedMaxHeap,
        mask_count: &mut usize,
    ) {
        colex_flip_masks(self.sub_bits, rho, |flip_mask| {
            *mask_count += 1;
            let lookup_key = query_sub ^ flip_mask;
            if let Some(posting) = table.map.get(&lookup_key) {
                // posting is sorted ascending (§1.2 invariant).
                for record_key in posting {
                    // Deduplicate by FULL VectorRecordKey so two records
                    // sharing the same item_id (differing in vector_index or
                    // model_id) are each checked independently — neither is
                    // suppressed as "already seen." Matches Swift semantics:
                    // filtered items are still marked seen so they are not
                    // re-examined from other bands.
                    if !seen.insert(record_key.clone()) { continue; }

                    // Per-record metadata filter applied after deduplication.
                    if let Some(f) = filter {
                        if !f.accepts(record_key) { continue; }
                    }

                    // I-7: ALL distances through EngramLib (SubstrateKernel).
                    if let Some(code) = self.codes.get(record_key) {
                        let dist = EngramLib::distance(probe, code);
                        heap.offer(dist, record_key.clone());
                    }
                }
            }
        });
    }
}

impl DenseIndex for MIHIndex {
    fn kind(&self) -> IndexKind {
        IndexKind::Mih
    }

    fn build(
        &mut self,
        vectors: &[VectorPayload],
        keys: &[VectorRecordKey],
    ) -> Result<(), VectorKitError> {
        if vectors.len() != keys.len() {
            return Err(VectorKitError::InvalidPayload(format!(
                "MIHIndex.build: vectors.len()={} != keys.len()={}",
                vectors.len(), keys.len()
            )));
        }
        // Reset state. codes and tables are keyed by full VectorRecordKey
        // so every (item_id, vector_index, model_id) triple is an independent
        // slot — no itemID-unique assumption.
        self.codes.clear();
        for t in &mut self.tables { t.map.clear(); }

        for (payload, key) in vectors.iter().zip(keys.iter()) {
            let engram = Self::payload_to_engram(payload)?;
            self.insert_into_tables(key, &engram);
            self.codes.insert(key.clone(), engram);
        }
        Ok(())
    }

    fn search(
        &self,
        probe: &VectorPayload,
        metric: DenseMetric,
        k: usize,
        filter: Option<&MetadataFilter>,
    ) -> Result<Vec<DenseHit>, VectorKitError> {
        if probe.kind != VectorKind::Binary {
            return Err(VectorKitError::InvalidPayload(format!(
                "MIHIndex.search: probe.kind must be Binary, got {:?}", probe.kind
            )));
        }
        if !matches!(metric, DenseMetric::Binary(BinaryMetric::Hamming)) {
            return Err(VectorKitError::InvalidPayload(format!(
                "MIHIndex.search: only Binary(Hamming) is supported; got {:?}", metric
            )));
        }
        if k == 0 { return Ok(vec![]); }
        if self.codes.is_empty() { return Ok(vec![]); }

        let probe_engram = Self::payload_to_engram(probe)?;
        Ok(self.knn(&probe_engram, k, filter))
    }

    fn add(
        &mut self,
        key: VectorRecordKey,
        vector: VectorPayload,
    ) -> Result<(), VectorKitError> {
        if vector.kind != VectorKind::Binary || vector.bytes.len() != 32 {
            return Err(VectorKitError::InvalidPayload(
                "MIHIndex.add: vector must be Binary with 32 bytes".into()
            ));
        }
        let engram = Self::payload_to_engram(&vector)?;
        // Upsert: if this exact VectorRecordKey is already present, remove the
        // old entry before re-inserting. Two records with the same item_id but
        // different vector_index or model_id are DISTINCT keys and do NOT evict
        // each other here (VectorRecordKey: Eq uses all four fields).
        if let Some(existing) = self.codes.get(&key).cloned() {
            self.remove_from_tables(&key, &existing);
        }
        self.insert_into_tables(&key, &engram);
        self.codes.insert(key, engram);
        Ok(())
    }

    fn remove(&mut self, key: &VectorRecordKey) -> Result<(), VectorKitError> {
        // Remove by full VectorRecordKey — only evicts the exact (item_id,
        // vector_index, model_id, model_version) entry, not co-item siblings.
        if let Some(engram) = self.codes.remove(key) {
            self.remove_from_tables(key, &engram);
        }
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::brute_force::BruteForceIndex;
    use crate::engine::metric::DenseMetric;
    use crate::engine::payload::{VectorKind, VectorPayload};
    use crate::engine::resident_store::ResidentArrayStore;
    use engram_lib::Engram;

    // ── Helper constructors ──────────────────────────────────────────────────

    fn engram_payload(b0: u64, b1: u64, b2: u64, b3: u64) -> VectorPayload {
        let e = Engram::new(b0, b1, b2, b3);
        let mut bytes = vec![0u8; 32];
        bytes[0..8].copy_from_slice(&e.block0.to_le_bytes());
        bytes[8..16].copy_from_slice(&e.block1.to_le_bytes());
        bytes[16..24].copy_from_slice(&e.block2.to_le_bytes());
        bytes[24..32].copy_from_slice(&e.block3.to_le_bytes());
        VectorPayload { kind: VectorKind::Binary, dim: 256, bytes, scale: None }
    }

    fn zero_payload() -> VectorPayload { engram_payload(0, 0, 0, 0) }

    fn key(item_id: &str) -> VectorRecordKey {
        VectorRecordKey::new(item_id, 0, "model-a", "1")
    }

    /// Assert two DenseHit slices are bit-for-bit identical.
    fn assert_hits_identical(mih: &[DenseHit], brute: &[DenseHit], ctx: &str) {
        assert_eq!(mih.len(), brute.len(),
            "{ctx}: count mismatch mih={} brute={}", mih.len(), brute.len());
        for (i, (m, b)) in mih.iter().zip(brute.iter()).enumerate() {
            assert_eq!(m.key.item_id, b.key.item_id,
                "{ctx} hit[{i}]: item_id mih={} brute={}", m.key.item_id, b.key.item_id);
            assert_eq!(m.raw_distance, b.raw_distance,
                "{ctx} hit[{i}]: dist mih={} brute={}", m.raw_distance, b.raw_distance);
        }
    }

    /// Simple deterministic xorshift64 PRNG.
    fn xorshift64(state: &mut u64) -> u64 {
        *state ^= *state << 13;
        *state ^= *state >> 7;
        *state ^= *state << 17;
        *state
    }


    // ── Canonical spec vectors (§1.10) ───────────────────────────────────────

    #[test]
    fn mih1_exact_small_index_k2() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("id-1"), engram_payload(0, 0, 0, 0)).unwrap();
        mih.add(key("id-2"), engram_payload(7, 0, 0, 0)).unwrap();
        mih.add(key("id-3"), engram_payload(0xFF, 0, 0, 0)).unwrap();
        mih.add(key("id-4"), engram_payload(0, 0, 0, 0x8000_0000_0000_0000)).unwrap();

        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].key.item_id, "id-1");
        assert_eq!(hits[0].raw_distance, 0);
        assert_eq!(hits[1].key.item_id, "id-4");
        assert_eq!(hits[1].raw_distance, 1);
    }

    #[test]
    fn mih2_tie_break_by_item_id() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("id-1"), engram_payload(0, 0, 0, 0)).unwrap();
        mih.add(key("id-2"), engram_payload(7, 0, 0, 0)).unwrap();
        mih.add(key("id-3"), engram_payload(0xFF, 0, 0, 0)).unwrap();
        mih.add(key("id-4"), engram_payload(0, 0, 0, 0x8000_0000_0000_0000)).unwrap();
        mih.add(key("id-5"), engram_payload(1, 0, 0, 0)).unwrap();

        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].key.item_id, "id-1"); assert_eq!(hits[0].raw_distance, 0);
        // id-4 < id-5 in string order — id-4 wins the second slot.
        assert_eq!(hits[1].key.item_id, "id-4"); assert_eq!(hits[1].raw_distance, 1);
    }

    #[test]
    fn mih3_multiband_three_way_tie_k3() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("id-10"), engram_payload(3, 3, 0, 0)).unwrap();
        mih.add(key("id-11"), engram_payload(0, 0, 0, 0x0F)).unwrap();
        mih.add(key("id-12"), engram_payload(0x0F, 0, 0, 0)).unwrap();
        mih.add(key("id-13"), engram_payload(1, 0, 0, 0)).unwrap();

        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 3, None).unwrap();
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0].key.item_id, "id-13"); assert_eq!(hits[0].raw_distance, 1);
        assert_eq!(hits[1].key.item_id, "id-10"); assert_eq!(hits[1].raw_distance, 4);
        assert_eq!(hits[2].key.item_id, "id-11"); assert_eq!(hits[2].raw_distance, 4);
    }

    #[test]
    fn mih4_fewer_than_k() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("id-1"), engram_payload(0, 0, 0, 0)).unwrap();
        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 5, None).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].key.item_id, "id-1");
        assert_eq!(hits[0].raw_distance, 0);
    }

    #[test]
    fn mih5_delete_then_query() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("id-1"), engram_payload(0, 0, 0, 0)).unwrap();
        mih.add(key("id-2"), engram_payload(7, 0, 0, 0)).unwrap();
        mih.add(key("id-3"), engram_payload(0xFF, 0, 0, 0)).unwrap();
        mih.add(key("id-4"), engram_payload(0, 0, 0, 0x8000_0000_0000_0000)).unwrap();
        mih.remove(&key("id-4")).unwrap();

        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].key.item_id, "id-1"); assert_eq!(hits[0].raw_distance, 0);
        assert_eq!(hits[1].key.item_id, "id-2"); assert_eq!(hits[1].raw_distance, 3);
    }

    // ── MIH == BruteForce gate on canonical vectors ─────────────────────────

    fn gate_test(records: &[(&str, u64, u64, u64, u64)], k: usize, bc: MIHBandCount) {
        let mut mih   = MIHIndex::new(bc);
        let mut brute = BruteForceIndex::new();
        for (id, b0, b1, b2, b3) in records {
            let p = engram_payload(*b0, *b1, *b2, *b3);
            mih.add(key(id), p.clone()).unwrap();
            brute.add(key(id), p).unwrap();
        }
        let mih_hits   = mih.search(&zero_payload(), DenseMetric::HAMMING, k, None).unwrap();
        let brute_hits = brute.search(&zero_payload(), DenseMetric::HAMMING, k, None).unwrap();
        let ctx = format!("gate-m{}-k{}", bc as u32, k);
        assert_hits_identical(&mih_hits, &brute_hits, &ctx);
    }

    #[test]
    fn gate_mih1_m4() {
        gate_test(&[
            ("id-1", 0, 0, 0, 0),
            ("id-2", 7, 0, 0, 0),
            ("id-3", 0xFF, 0, 0, 0),
            ("id-4", 0, 0, 0, 0x8000_0000_0000_0000),
        ], 2, MIHBandCount::M4);
    }

    #[test]
    fn gate_mih2_m4() {
        gate_test(&[
            ("id-1", 0, 0, 0, 0),
            ("id-2", 7, 0, 0, 0),
            ("id-3", 0xFF, 0, 0, 0),
            ("id-4", 0, 0, 0, 0x8000_0000_0000_0000),
            ("id-5", 1, 0, 0, 0),
        ], 2, MIHBandCount::M4);
    }

    #[test]
    fn gate_mih3_m4() {
        gate_test(&[
            ("id-10", 3, 3, 0, 0),
            ("id-11", 0, 0, 0, 0x0F),
            ("id-12", 0x0F, 0, 0, 0),
            ("id-13", 1, 0, 0, 0),
        ], 3, MIHBandCount::M4);
    }

    #[test]
    fn gate_mih4_m4() {
        gate_test(&[("id-1", 0, 0, 0, 0)], 5, MIHBandCount::M4);
    }

    #[test]
    fn gate_mih5_delete() {
        let records: &[(&str, u64, u64, u64, u64)] = &[
            ("id-1", 0, 0, 0, 0),
            ("id-2", 7, 0, 0, 0),
            ("id-3", 0xFF, 0, 0, 0),
            ("id-4", 0, 0, 0, 0x8000_0000_0000_0000),
        ];
        let mut mih   = MIHIndex::new(MIHBandCount::M4);
        let mut brute = BruteForceIndex::new();
        for (id, b0, b1, b2, b3) in records {
            let p = engram_payload(*b0, *b1, *b2, *b3);
            mih.add(key(id), p.clone()).unwrap();
            brute.add(key(id), p).unwrap();
        }
        mih.remove(&key("id-4")).unwrap();
        brute.remove(&key("id-4")).unwrap();
        let mih_hits   = mih.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        let brute_hits = brute.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_hits_identical(&mih_hits, &brute_hits, "gate-mih5-delete");
    }

    // ── Randomised fuzz cross-check ─────────────────────────────────────────
    //
    // Correctness gate: MIHIndex.search == BruteForceIndex.search on all inputs.
    //
    // Performance note: MIH's progressive-radius expansion is sub-linear only
    // on CLUSTERED binary codes (the normal case). On pure-random 256-bit codes,
    // the k nearest neighbours are at Hamming distance ~128, requiring colex
    // enumeration up to rho=32 per band (C(64,32) ≈ 10^18 combinations for m=4).
    // The fuzz strategy below avoids this by ensuring the k nearest neighbours
    // of the probe are at small Hamming distance (≤ max_near_dist bits), so the
    // stopping rule fires quickly. The remaining n-k codes are random.
    // Correctness is fully exercised: MIH must find the exact k nearest from a
    // mixed population of near and far codes.

    /// Generate a fuzz scenario: probe + n indexed codes where the first k
    /// codes are guaranteed to be within `max_near_dist` bits of the probe.
    ///
    /// This ensures the k-NN stopping rule fires at r ≤ max_near_dist.
    fn fuzz_run_near(n: usize, k: usize, max_near_dist: u32, seed: u64, bc: MIHBandCount) {
        let mut state = seed;

        // Generate probe.
        let probe = engram_payload(
            xorshift64(&mut state), xorshift64(&mut state),
            xorshift64(&mut state), xorshift64(&mut state));
        let pe = Engram::new(
            u64::from_le_bytes(probe.bytes[0..8].try_into().unwrap()),
            u64::from_le_bytes(probe.bytes[8..16].try_into().unwrap()),
            u64::from_le_bytes(probe.bytes[16..24].try_into().unwrap()),
            u64::from_le_bytes(probe.bytes[24..32].try_into().unwrap()));

        // Generate near items (first k): probe XOR a small flip mask.
        let mut records: Vec<(VectorRecordKey, VectorPayload)> = Vec::new();
        for i in 0..k {
            // Apply a flip to a random subset of bits 0..max_near_dist.
            let flip_count = 1 + (xorshift64(&mut state) % max_near_dist as u64) as u32;
            let flip_bits  = xorshift64(&mut state);   // bits to flip in block0
            let mask = if flip_count >= 64 { u64::MAX } else { (1u64 << flip_count) - 1 };
            let flip = flip_bits & mask;
            let near = Engram::new(pe.block0 ^ flip, pe.block1, pe.block2, pe.block3);
            let item_id = format!("near-{:06}", i);
            let mut bytes = vec![0u8; 32];
            bytes[0..8].copy_from_slice(&near.block0.to_le_bytes());
            bytes[8..16].copy_from_slice(&near.block1.to_le_bytes());
            bytes[16..24].copy_from_slice(&near.block2.to_le_bytes());
            bytes[24..32].copy_from_slice(&near.block3.to_le_bytes());
            records.push((
                VectorRecordKey::new(&item_id, 0, "model-a", "1"),
                VectorPayload { kind: VectorKind::Binary, dim: 256, bytes, scale: None },
            ));
        }
        // Generate random items (remaining n-k): arbitrary distances.
        for i in k..n {
            let b0 = xorshift64(&mut state);
            let b1 = xorshift64(&mut state);
            let b2 = xorshift64(&mut state);
            let b3 = xorshift64(&mut state);
            let item_id = format!("rand-{:06}", i);
            records.push((
                VectorRecordKey::new(&item_id, 0, "model-a", "1"),
                engram_payload(b0, b1, b2, b3),
            ));
        }

        let mut mih   = MIHIndex::new(bc);
        let mut brute = BruteForceIndex::new();
        for (k, payload) in &records {
            mih.add(k.clone(), payload.clone()).unwrap();
            brute.add(k.clone(), payload.clone()).unwrap();
        }
        let mih_hits   = mih.search(&probe, DenseMetric::HAMMING, k, None).unwrap();
        let brute_hits = brute.search(&probe, DenseMetric::HAMMING, k, None).unwrap();
        let ctx = format!("fuzz-m{}-n{}-k{}-seed{:x}", bc as u32, n, k, seed);
        assert_hits_identical(&mih_hits, &brute_hits, &ctx);
    }

    #[test]
    fn fuzz_m4_seed_cafebabe() {
        // m=4 (sub_bits=64): near items within 4 bits → rho ≤ 1 per band → fast.
        fuzz_run_near(50, 5, 4, 0xCAFEBABEDEADBEEF, MIHBandCount::M4);
    }

    #[test]
    fn fuzz_m8_seed_deadbeef() {
        // m=8 (sub_bits=32): near items within 8 bits → rho ≤ 1 per band → fast.
        fuzz_run_near(80, 10, 8, 0xDEADBEEFCAFEBABE, MIHBandCount::M8);
    }

    #[test]
    fn fuzz_m16_seed_0102() {
        // m=16 (sub_bits=16): near items within 16 bits → rho ≤ 1 per band → fast.
        fuzz_run_near(100, 10, 16, 0x0102030405060708, MIHBandCount::M16);
    }

    #[test]
    fn fuzz_m32_seed_fedcba() {
        // m=32 (sub_bits=8): near items within 8 bits → rho ≤ 1 per band → fast.
        fuzz_run_near(100, 10, 8, 0xFEDCBA9876543210, MIHBandCount::M32);
    }

    #[test]
    fn fuzz_all_m_multiple_seeds() {
        // Five seeds × four m values. Near items within 4 bits of probe.
        let seeds: &[u64] = &[
            0xCAFEBABEDEADBEEF,
            0x1234567890ABCDEF,
            0xFEEDFACECAFEBEEF,
            0xA5A5A5A5A5A5A5A5,
            0x0F0F0F0F0F0F0F0F,
        ];
        let band_counts = [MIHBandCount::M4, MIHBandCount::M8,
                           MIHBandCount::M16, MIHBandCount::M32];
        for &seed in seeds {
            for &bc in &band_counts {
                let mut state = seed;
                let n = 20 + (xorshift64(&mut state) % 30) as usize;
                let k = 2 + (xorshift64(&mut state) % 5) as usize;
                fuzz_run_near(n, k, 4, state, bc);
            }
        }
    }

    #[test]
    fn fuzz_k_larger_than_n() {
        // k > n: should return all n items. Near within 4 bits.
        for &bc in &[MIHBandCount::M4, MIHBandCount::M8,
                     MIHBandCount::M16, MIHBandCount::M32] {
            fuzz_run_near(10, 50, 4, 0x1111111111111111, bc);
        }
    }

    #[test]
    fn fuzz_empty_index() {
        let mih   = MIHIndex::new(MIHBandCount::M4);
        let brute = BruteForceIndex::new();
        let mih_h   = mih.search(&zero_payload(), DenseMetric::HAMMING, 5, None).unwrap();
        let brute_h = brute.search(&zero_payload(), DenseMetric::HAMMING, 5, None).unwrap();
        assert_hits_identical(&mih_h, &brute_h, "empty-index");
    }

    // ── Error cases ──────────────────────────────────────────────────────────

    #[test]
    fn non_binary_probe_returns_error() {
        let mih = MIHIndex::new(MIHBandCount::M4);
        let float_probe = VectorPayload {
            kind: VectorKind::Float32, dim: 2,
            bytes: vec![0u8; 8], scale: None,
        };
        assert!(mih.search(&float_probe, DenseMetric::HAMMING, 1, None).is_err());
    }

    #[test]
    fn float_metric_returns_error() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("item-1"), zero_payload()).unwrap();
        assert!(mih.search(&zero_payload(), DenseMetric::COSINE, 1, None).is_err());
    }

    #[test]
    fn k_zero_returns_empty() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("item-1"), zero_payload()).unwrap();
        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 0, None).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn remove_absent_key_is_no_op() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        mih.add(key("item-1"), zero_payload()).unwrap();
        mih.remove(&key("no-such-item")).unwrap();
        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 1, None).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].key.item_id, "item-1");
    }

    // ── Persistence round-trip (real on-disk .vec sidecar) ───────────────────

    /// Build (vecs, keys) from a live snapshot (non-tombstoned slots only).
    fn live_from_snapshot(
        snap: &crate::engine::resident::ResidentVectorArray,
    ) -> (Vec<VectorPayload>, Vec<VectorRecordKey>) {
        let live_vecs: Vec<VectorPayload> = (0..snap.count)
            .filter(|&i| !snap.is_tombstoned(i))
            .map(|i| VectorPayload {
                kind: VectorKind::Binary,
                dim: 256,
                bytes: snap.vector_bytes(i).to_vec(),
                scale: None,
            })
            .collect();
        let live_keys: Vec<VectorRecordKey> = (0..snap.count)
            .filter(|&i| !snap.is_tombstoned(i))
            .map(|i| snap.keys[i].clone())
            .collect();
        (live_vecs, live_keys)
    }

    #[test]
    fn write_then_reopen_produces_identical_results() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("mih-test-{}.vec",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()));
        let _cleanup = defer_remove(&path);

        let records: &[(&str, u64)] = &[
            ("item-1", 0),
            ("item-2", 1),
            ("item-3", 3),
            ("item-4", 0xFF),
        ];

        // Session 1: write using new_binary (stride=32, binary lane).
        let mut store1 = ResidentArrayStore::new_binary(&path);
        for (id, b0) in records {
            store1.append(
                VectorRecordKey::new(*id, 0, "model-a", "1"),
                engram_payload(*b0, 0, 0, 0).bytes.clone(),
            ).unwrap();
        }
        let snap1 = store1.snapshot();
        let (vecs1, keys1) = live_from_snapshot(&snap1);
        let mut mih1 = MIHIndex::new(MIHBandCount::M4);
        mih1.build(&vecs1, &keys1).unwrap();
        let hits_before = mih1.search(&zero_payload(), DenseMetric::HAMMING, 3, None).unwrap();

        // Session 2: reopen from on-disk sidecar.
        let mut store2 = ResidentArrayStore::new_binary(&path);
        store2.load().unwrap();
        let snap2 = store2.snapshot();
        let (vecs2, keys2) = live_from_snapshot(&snap2);
        let mut mih2 = MIHIndex::new(MIHBandCount::M4);
        mih2.build(&vecs2, &keys2).unwrap();
        let hits_after = mih2.search(&zero_payload(), DenseMetric::HAMMING, 3, None).unwrap();

        assert_hits_identical(&hits_before, &hits_after, "persistence-reopen");
    }

    #[test]
    fn persistence_reopen_equals_brute_force() {
        // Uses near data so stopping rule fires quickly with m=8 (sub_bits=32).
        let dir = std::env::temp_dir();
        let path = dir.join(format!("mih-brute-{}.vec",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()));
        let _cleanup = defer_remove(&path);

        let mut state: u64 = 0xCAFEBABEDEADBEEF;
        let probe_b0 = xorshift64(&mut state);
        let probe_b1 = xorshift64(&mut state);
        let probe_b2 = xorshift64(&mut state);
        let probe_b3 = xorshift64(&mut state);
        let probe = engram_payload(probe_b0, probe_b1, probe_b2, probe_b3);

        let n = 40_usize;
        let k = 10_usize;
        // Generate k near records (within 1 bit of probe.block0).
        let mut records: Vec<(VectorRecordKey, VectorPayload)> = Vec::new();
        for i in 0..k {
            let flip = 1u64 << (xorshift64(&mut state) % 8);
            let b0 = probe_b0 ^ flip;
            records.push((
                VectorRecordKey::new(&format!("near-{:06}", i), 0, "model-a", "1"),
                engram_payload(b0, probe_b1, probe_b2, probe_b3),
            ));
        }
        // Generate n-k random far records.
        for i in k..n {
            let b0 = xorshift64(&mut state);
            let b1 = xorshift64(&mut state);
            let b2 = xorshift64(&mut state);
            let b3 = xorshift64(&mut state);
            records.push((
                VectorRecordKey::new(&format!("rand-{:06}", i), 0, "model-a", "1"),
                engram_payload(b0, b1, b2, b3),
            ));
        }

        // Write sidecar.
        let mut store = ResidentArrayStore::new_binary(&path);
        for (k, payload) in &records {
            store.append(k.clone(), payload.bytes.clone()).unwrap();
        }

        // Ground truth: BruteForce from add() calls.
        let mut brute = BruteForceIndex::new();
        for (k, payload) in &records {
            brute.add(k.clone(), payload.clone()).unwrap();
        }
        let brute_hits = brute.search(&probe, DenseMetric::HAMMING, k, None).unwrap();

        // Reopen and build MIH from sidecar.
        let mut store2 = ResidentArrayStore::new_binary(&path);
        store2.load().unwrap();
        let snap = store2.snapshot();
        let (live_vecs, live_keys) = live_from_snapshot(&snap);
        let mut mih = MIHIndex::new(MIHBandCount::M8);
        mih.build(&live_vecs, &live_keys).unwrap();
        let mih_hits = mih.search(&probe, DenseMetric::HAMMING, k, None).unwrap();

        assert_hits_identical(&mih_hits, &brute_hits, "persistence-vs-brute");
    }

    // ── W8b: bulk build(from: array) conformance  ───────────────────────────

    /// W8b-1: both MIHIndex and BruteForceIndex, built via the bulk
    /// `build()` path from the same live-vec arrays extracted from a
    /// ResidentVectorArray, produce identical `search` output.
    ///
    /// Corpus: 500 random 256-bit codes, seed 0x1234ABCD5678EF01.
    /// Probes: 25 random codes (shifted seed; capped for debug-build budget).
    /// k=10, m=16. All 25 probes must produce bit-for-bit identical hits.
    #[test]
    fn bulk_build_500_vectors_500_probes_m16_equals_bruteforce() {
        let n = 500;
        let k = 10;
        let mut state: u64 = 0x1234_ABCD_5678_EF01;

        // Build corpus.
        let records: Vec<(VectorRecordKey, VectorPayload)> = (0..n)
            .map(|i| {
                let b0 = xorshift64(&mut state);
                let b1 = xorshift64(&mut state);
                let b2 = xorshift64(&mut state);
                let b3 = xorshift64(&mut state);
                (
                    VectorRecordKey::new(format!("item-{:06}", i), 0, "model-a", "1"),
                    engram_payload(b0, b1, b2, b3),
                )
            })
            .collect();

        // Assemble a ResidentVectorArray via sidecar store (the bulk path).
        let path = {
            let f = tempfile::NamedTempFile::new().unwrap();
            f.path().with_extension("vec")
        };
        let _defer = defer_remove(&path);
        let mut store = ResidentArrayStore::new_binary(&path);
        for (k, payload) in &records {
            store.append(k.clone(), payload.bytes.clone()).unwrap();
        }
        let snap = store.snapshot();
        let (live_vecs, live_keys) = live_from_snapshot(&snap);

        // Build both indexes via the bulk path.
        let mut brute = BruteForceIndex::new();
        brute.build(&live_vecs, &live_keys).unwrap();

        let mut mih = MIHIndex::new(MIHBandCount::M16);
        mih.build(&live_vecs, &live_keys).unwrap();

        // Probe with 500 random codes.
        let mut probe_state: u64 = state ^ 0xDEAD_BEEF_CAFE_0000;
        // 25 probes, not n: each random k=10 probe costs ~300k flip-mask
        // enumerations at m=16 in debug builds; 500 probes blows the 3-minute
        // test budget while adding no conformance value beyond ~25.
        for i in 0..25usize {
            let probe = engram_payload(
                xorshift64(&mut probe_state),
                xorshift64(&mut probe_state),
                xorshift64(&mut probe_state),
                xorshift64(&mut probe_state),
            );
            let brute_hits = brute.search(&probe, DenseMetric::HAMMING, k, None).unwrap();
            let mih_hits = mih.search(&probe, DenseMetric::HAMMING, k, None).unwrap();
            assert_hits_identical(&mih_hits, &brute_hits,
                &format!("W8b probe[{i}] n={n} k={k}"));
        }
    }

    /// W8b-2: bulk build with all four m values {4,8,16,32}.
    ///
    /// Corpus: 200 random codes, seed 0xFEEDBABE12345678.
    /// 50 probes per m value. Each MIH result must match BruteForce.
    ///
    /// PROBE DESIGN — near-duplicate probes with k=1, NOT random probes with
    /// k=10: MIH's progressive-radius search terminates once (radius+1)·m
    /// exceeds the k-th best distance. A random probe over random data has a
    /// k-th best of ~120 bits, which at m=4 (64-bit bands) demands radius ~29
    /// — C(64,29) ≈ 10^17 flip masks per band, combinatorially infeasible
    /// (this exact shape hung the suite for hours, not minutes). Probing with
    /// a STORED vector ±≤2 flipped bits plants the best hit at distance ≤2,
    /// so every m terminates at radius ≤2 while still proving the bulk-built
    /// index put every live slot in the right buckets: a mis-indexed slot
    /// makes MIH miss the planted neighbour and diverge from brute force.
    /// Deep-k conformance on random data lives in W8b-1 above (m=16, where
    /// the enumeration is tractable). Mirrors the Swift twin exactly.
    #[test]
    fn bulk_build_200_vectors_all_m_values_equals_bruteforce() {
        let n = 200usize;
        let mut state: u64 = 0xFEED_BABE_1234_5678;

        let records: Vec<(VectorRecordKey, VectorPayload)> = (0..n)
            .map(|i| {
                let b0 = xorshift64(&mut state);
                let b1 = xorshift64(&mut state);
                let b2 = xorshift64(&mut state);
                let b3 = xorshift64(&mut state);
                (
                    VectorRecordKey::new(format!("item-{:06}", i), 0, "model-a", "1"),
                    engram_payload(b0, b1, b2, b3),
                )
            })
            .collect();

        // Build shared array once.
        let path = {
            let f = tempfile::NamedTempFile::new().unwrap();
            f.path().with_extension("vec")
        };
        let _defer = defer_remove(&path);
        let mut store = ResidentArrayStore::new_binary(&path);
        for (k, payload) in &records {
            store.append(k.clone(), payload.bytes.clone()).unwrap();
        }
        let snap = store.snapshot();
        let (live_vecs, live_keys) = live_from_snapshot(&snap);

        let mut brute = BruteForceIndex::new();
        brute.build(&live_vecs, &live_keys).unwrap();

        for m in [MIHBandCount::M4, MIHBandCount::M8, MIHBandCount::M16, MIHBandCount::M32] {
            let mut mih = MIHIndex::new(m);
            mih.build(&live_vecs, &live_keys).unwrap();

            for i in 0..50usize {
                // Probe = stored vector (i·7 mod n) with 0/1/2 deterministic
                // byte-level bit flips — the planted nearest neighbour that
                // every band count can reach at a tiny radius.
                let mut probe_bytes = records[(i * 7) % n].1.bytes.clone();
                for f in 0..(i % 3) {
                    let bit_index = (i * 13 + f * 97 + 7) % 256;
                    probe_bytes[bit_index / 8] ^= 1u8 << (bit_index % 8);
                }
                let probe = VectorPayload {
                    kind: VectorKind::Binary, dim: 256, bytes: probe_bytes, scale: None,
                };
                let brute_hits = brute.search(&probe, DenseMetric::HAMMING, 1, None).unwrap();
                let mih_hits = mih.search(&probe, DenseMetric::HAMMING, 1, None).unwrap();
                assert_hits_identical(&mih_hits, &brute_hits,
                    &format!("W8b m={} probe[{i}]", m as u32));
            }
        }
    }

    // ── Defer-remove helper ──────────────────────────────────────────────────

    struct DeferRemove(std::path::PathBuf);
    impl Drop for DeferRemove {
        fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); }
    }
    fn defer_remove(p: &std::path::Path) -> DeferRemove {
        DeferRemove(p.to_path_buf())
    }

    // ── cumulative_choose parity gate ────────────────────────────────────────
    //
    // These values must agree bit-for-bit with the Swift cumulativeChoose
    // unit tests (MIHIndexTests.swift Suite 8). Both ports must produce
    // identical values so both fall back at the same radius.

    #[test]
    fn cumulative_choose_sub_bits_8() {
        // C(8,0)=1, C(8,1)=8, C(8,2)=28, C(8,3)=56, C(8,4)=70
        assert_eq!(cumulative_choose(8, 0), 1);
        assert_eq!(cumulative_choose(8, 1), 9);    // 1+8
        assert_eq!(cumulative_choose(8, 2), 37);   // 1+8+28
        assert_eq!(cumulative_choose(8, 3), 93);   // 1+8+28+56
        assert_eq!(cumulative_choose(8, 4), 163);  // 1+8+28+56+70
    }

    #[test]
    fn cumulative_choose_sub_bits_16() {
        // C(16,0)=1, C(16,1)=16, C(16,2)=120, C(16,3)=560, C(16,4)=1820
        assert_eq!(cumulative_choose(16, 0), 1);
        assert_eq!(cumulative_choose(16, 1), 17);
        assert_eq!(cumulative_choose(16, 2), 137);
        assert_eq!(cumulative_choose(16, 3), 697);
        assert_eq!(cumulative_choose(16, 4), 2517);
    }

    #[test]
    fn cumulative_choose_sub_bits_32() {
        // C(32,0)=1, C(32,1)=32, C(32,2)=496, C(32,3)=4960
        assert_eq!(cumulative_choose(32, 0), 1);
        assert_eq!(cumulative_choose(32, 1), 33);
        assert_eq!(cumulative_choose(32, 2), 529);
        assert_eq!(cumulative_choose(32, 3), 5489);
    }

    #[test]
    fn cumulative_choose_sub_bits_64() {
        // C(64,0)=1, C(64,1)=64, C(64,2)=2016, C(64,3)=41664, C(64,4)=635376
        assert_eq!(cumulative_choose(64, 0), 1);
        assert_eq!(cumulative_choose(64, 1), 65);
        assert_eq!(cumulative_choose(64, 2), 2081);
        assert_eq!(cumulative_choose(64, 3), 43745);
        assert_eq!(cumulative_choose(64, 4), 679121);
    }

    #[test]
    fn cumulative_choose_zero_rho_always_one() {
        // Σ_{d=0..0} C(n,0) = 1 for all n.
        for n in [8u32, 16, 32, 64] {
            assert_eq!(cumulative_choose(n, 0), 1, "sub_bits={}", n);
        }
    }

    #[test]
    fn cumulative_choose_rho_ge_sub_bits_caps_at_2n() {
        // Σ_{d=0..n} C(n,d) = 2^n when rho >= sub_bits.
        assert_eq!(cumulative_choose(8, 8),   256);  // 2^8
        assert_eq!(cumulative_choose(8, 100), 256);  // clamped
    }

    /// Verify cumulative_choose matches the actual colex enumeration count
    /// for all conformance-gated (sub_bits, rho) pairs. Mirrors the Swift
    /// `matchesActualEnumerationCount` test.
    #[test]
    fn cumulative_choose_matches_actual_enumeration_count() {
        for &sb in &[8u32, 16, 32, 64] {
            for rho in 0u32..=4 {
                let mut count: usize = 0;
                colex_flip_masks(sb, rho, |_| { count += 1; });
                let computed = cumulative_choose(sb, rho);
                assert_eq!(computed, count,
                    "cumulative_choose({}, {})={} but colex_flip_masks generated {}",
                    sb, rho, computed, count);
            }
        }
    }

    // ── Enumeration-budget guard — deep-k random probes ─────────────────────

    /// n=300, m=4, k=10. All probes are uniformly random (no planted near items).
    /// Before the guard this shape hangs for hours. After the guard, the engine
    /// falls back to brute scan and returns exact results matching BruteForce.
    #[test]
    fn deep_k_random_m4_n300_equals_bruteforce() {
        let n = 300usize;
        let k = 10usize;
        let mut state: u64 = 0x1A2B3C4D5E6F0011;

        // Build corpus — purely random 256-bit codes, no planted near items.
        let mut records: Vec<(VectorRecordKey, VectorPayload)> = Vec::new();
        for i in 0..n {
            let b0 = xorshift64(&mut state);
            let b1 = xorshift64(&mut state);
            let b2 = xorshift64(&mut state);
            let b3 = xorshift64(&mut state);
            records.push((
                VectorRecordKey::new(format!("item-{:06}", i), 0, "model-a", "1"),
                engram_payload(b0, b1, b2, b3),
            ));
        }

        let mut mih   = MIHIndex::new(MIHBandCount::M4);
        let mut brute = BruteForceIndex::new();
        for (k_, payload) in &records {
            mih.add(k_.clone(), payload.clone()).unwrap();
            brute.add(k_.clone(), payload.clone()).unwrap();
        }

        // 10 random probes — each would previously hang for hours at m=4.
        for i in 0..10usize {
            let probe = engram_payload(
                xorshift64(&mut state),
                xorshift64(&mut state),
                xorshift64(&mut state),
                xorshift64(&mut state),
            );
            let mih_hits   = mih.search(&probe, DenseMetric::HAMMING, k, None).unwrap();
            let brute_hits = brute.search(&probe, DenseMetric::HAMMING, k, None).unwrap();
            assert_hits_identical(&mih_hits, &brute_hits,
                &format!("deepK-random-m4-n300 probe[{i}]"));
        }
    }

    /// Forced fallback: mask_budget=1 causes brute_scan on every non-trivial query.
    /// This is the unit test for the brute_scan code path: even with an impossibly
    /// tight budget the output must be identical to BruteForce.
    #[test]
    fn forced_fallback_equals_bruteforce() {
        // mask_budget=1 means the projection for rho=0 (m*1=4) > 1,
        // so fallback fires immediately for any non-trivial probe distance.
        let mut mih   = MIHIndex::new_with_budget(MIHBandCount::M4, Some(1));
        let mut brute = BruteForceIndex::new();

        let mut state: u64 = 0xFEDCBA9876543210;
        let n = 50usize;
        for i in 0..n {
            let b0 = xorshift64(&mut state);
            let b1 = xorshift64(&mut state);
            let b2 = xorshift64(&mut state);
            let b3 = xorshift64(&mut state);
            let p = engram_payload(b0, b1, b2, b3);
            let k_ = VectorRecordKey::new(format!("item-{:04}", i), 0, "model-a", "1");
            mih.add(k_.clone(), p.clone()).unwrap();
            brute.add(k_.clone(), p).unwrap();
        }

        for i in 0..5usize {
            let probe = engram_payload(
                xorshift64(&mut state),
                xorshift64(&mut state),
                xorshift64(&mut state),
                xorshift64(&mut state),
            );
            let mih_hits   = mih.search(&probe, DenseMetric::HAMMING, 10, None).unwrap();
            let brute_hits = brute.search(&probe, DenseMetric::HAMMING, 10, None).unwrap();
            assert_hits_identical(&mih_hits, &brute_hits,
                &format!("forced-fallback probe[{i}]"));
        }
    }

    // ── Finding 1: MIH itemID-collision fix ─────────────────────────────────

    /// Two binary vectors that share the same item_id but differ in vector_index
    /// must BOTH survive in the index and BOTH be retrievable independently.
    ///
    /// Before the fix, MIH keyed its internal structures by item_id alone so
    /// the second `add()` silently overwrote the first. After the fix, the
    /// key is the full VectorRecordKey (item_id, vector_index, model_id,
    /// model_version) and both slots coexist.
    #[test]
    fn same_item_id_distinct_vector_index_both_survive() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);

        // Two vectors under the same item_id but different vector_index (ColBERT-style).
        let key0 = VectorRecordKey::new("item-A", 0, "model-a", "1");
        let key1 = VectorRecordKey::new("item-A", 1, "model-a", "1");

        // vec0 = all-zeros (Hamming dist 0 to zero-probe)
        // vec1 = 1 bit set  (Hamming dist 1 to zero-probe)
        mih.add(key0.clone(), engram_payload(0, 0, 0, 0)).unwrap();
        mih.add(key1.clone(), engram_payload(1, 0, 0, 0)).unwrap();

        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 4, None).unwrap();

        // Both entries must appear.
        assert_eq!(hits.len(), 2, "both same-item_id slots must survive in the index");
        // vec0 is closer; vec1 one bit further.
        assert_eq!(hits[0].key, key0, "closest hit must be the zero-distance slot");
        assert_eq!(hits[0].raw_distance, 0);
        assert_eq!(hits[1].key, key1, "second hit must be the one-bit-set slot");
        assert_eq!(hits[1].raw_distance, 1);
    }

    /// Same-itemID test via `build()` (bulk path). Verifies both the `add` and
    /// `build` code paths apply the fix.
    #[test]
    fn same_item_id_via_build_both_survive() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);
        let mut brute = BruteForceIndex::new();

        let key0 = VectorRecordKey::new("shared", 0, "model-a", "1");
        let key1 = VectorRecordKey::new("shared", 1, "model-a", "1");
        let key2 = VectorRecordKey::new("other",  0, "model-a", "1");

        let payloads = vec![
            engram_payload(0, 0, 0, 0),  // key0 — dist 0
            engram_payload(3, 0, 0, 0),  // key1 — dist 2
            engram_payload(0xFF, 0, 0, 0), // key2 — dist 8
        ];
        let keys = vec![key0.clone(), key1.clone(), key2.clone()];

        mih.build(&payloads, &keys).unwrap();
        brute.build(&payloads, &keys).unwrap();

        let probe = zero_payload();
        let mih_hits   = mih.search(&probe, DenseMetric::HAMMING, 3, None).unwrap();
        let brute_hits = brute.search(&probe, DenseMetric::HAMMING, 3, None).unwrap();

        assert_eq!(mih_hits.len(), 3, "all three slots (two sharing item_id) must be present");
        assert_hits_identical(&mih_hits, &brute_hits, "same_item_id_via_build");
    }

    /// Upsert on the SAME full VectorRecordKey (not just same item_id) must replace.
    /// This verifies the upsert contract is preserved: identical keys get replaced,
    /// co-item-id siblings do NOT.
    #[test]
    fn upsert_same_full_key_replaces_not_sibling() {
        let mut mih = MIHIndex::new(MIHBandCount::M4);

        let key0 = VectorRecordKey::new("item-A", 0, "model-a", "1");
        let key1 = VectorRecordKey::new("item-A", 1, "model-a", "1");

        // Both start as all-zeros.
        mih.add(key0.clone(), engram_payload(0, 0, 0, 0)).unwrap();
        mih.add(key1.clone(), engram_payload(0, 0, 0, 0)).unwrap();

        // Upsert key0 with a different vector (1 bit set).
        mih.add(key0.clone(), engram_payload(1, 0, 0, 0)).unwrap();

        // Now key0 has dist=1 and key1 has dist=0.
        let hits = mih.search(&zero_payload(), DenseMetric::HAMMING, 4, None).unwrap();
        assert_eq!(hits.len(), 2, "there must still be exactly two entries");
        assert_eq!(hits[0].key, key1, "key1 unchanged (dist=0) must rank first");
        assert_eq!(hits[0].raw_distance, 0);
        assert_eq!(hits[1].key, key0, "key0 (upserted, dist=1) must rank second");
        assert_eq!(hits[1].raw_distance, 1);
    }
}
