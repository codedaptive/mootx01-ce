// hamming_nn.rs
//
// Top-K Hamming nearest-neighbor search per cookbook § 8.2.
//
// Brute-force exact NN over fingerprints. For 1M-row estates at
// 32 bytes/fingerprint, the working set is 32 MB; at typical
// LPDDR5 bandwidth a full scan takes ~500 µs. K=10 top-K
// maintenance adds negligible overhead via a small max-heap
// (cookbook § 17.1 budget).
//
// The structure here is deliberate:
//
//   1. A candidate iterator (filtered by predicate; usually a
//      bitmap-tier filter has already pruned).
//   2. For each candidate, compute Hamming distance via the
//      kernel layer (here scalar; production routes to SIMD).
//   3. Maintain a fixed-size max-heap of the K smallest distances.
//   4. Return them sorted ascending by (distance, row_id).
//
// Tie-break convention: equal-distance hits are ordered by row_id
// ascending. This gives deterministic, reproducible results across
// runs — a substrate-wide conformance requirement. The Ord impl on
// HammingNNHit encodes this tie-break so both the heap eviction and
// the final sort respect it automatically. Mirrors the Swift port's
// uuidString-ascending convention (u128 and UUID string order agree
// on the conformance vector IDs used in testing).

use std::collections::BinaryHeap;
// (Removed unused `use std::cmp::Reverse;` — the heap implements
// PartialOrd/Ord directly on HammingNNHit.)

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hamming;

/// One hit from a top-K Hamming-NN scan.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HammingNNHit {
    pub row_id: u128,         // 128-bit UUID
    pub distance: u32,
}

// We want the heap to keep the K SMALLEST distances. Standard
// BinaryHeap is a max-heap, so we wrap with Reverse: the heap's
// "max" is the largest distance kept, ready to be evicted.
// Direct PartialOrd on HammingNNHit so the heap orders correctly.
impl Ord for HammingNNHit {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.distance.cmp(&other.distance)
            .then(self.row_id.cmp(&other.row_id))
    }
}
impl PartialOrd for HammingNNHit {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// Reference top-K Hamming-NN over a candidate iterator.
///
/// `candidates` yields `(row_id, fingerprint)` pairs. In production
/// the iterator is backed by the bit-slice tensor (cookbook § 4.1)
/// scanned through the kernel layer; here a simple iterator
/// suffices.
///
/// `blocks` is the bitmask from `hamming::*BLOCK*` constants;
/// default `hamming::ALL_BLOCKS` for full 256-bit distance.
pub fn top_k<I>(
    anchor: &Fingerprint256,
    candidates: I,
    k: usize,
    blocks: u8,
) -> Vec<HammingNNHit>
where
    I: IntoIterator<Item = (u128, Fingerprint256)>,
{
    assert!(k > 0, "k must be positive");

    // Bounded max-heap by distance: pop the largest when full and
    // a smaller distance arrives. BinaryHeap<HammingNNHit> is a
    // max-heap by `distance` per the Ord impl above.
    let mut heap: BinaryHeap<HammingNNHit> = BinaryHeap::with_capacity(k);

    for (row_id, fingerprint) in candidates {
        let d = hamming::distance(anchor, &fingerprint, blocks);
        let new_hit = HammingNNHit { row_id, distance: d };
        if heap.len() < k {
            heap.push(new_hit);
        } else if let Some(&worst) = heap.peek() {
            // Evict the worst retained hit when the new one is strictly
            // better by the same (distance, row_id) ordering used for
            // the final sort. `new_hit < worst` via Ord means lower
            // distance, or same distance with lower row_id.
            if new_hit < worst {
                heap.pop();
                heap.push(new_hit);
            }
        }
    }

    let mut result: Vec<HammingNNHit> = heap.into_sorted_vec();
    // into_sorted_vec returns ascending by Ord: (distance ASC, row_id ASC).
    result.truncate(k);
    result
}

// Batched / vectorized hot-path
//
// The reference implementation above is correct and clear. The
// production hot-path in NeuronKit (Rust port) is structured
// differently:
//
//   1. Bit-slice the candidate fingerprints by block (256 separate
//      arrays of length N).
//   2. For each block, XOR with the corresponding anchor block
//      replicated across N lanes.
//   3. Per-row popcount via VPOPCNTQ (AVX-512) or vcnt (NEON).
//   4. Sum the four block popcounts per row.
//   5. Top-K via a SIMD-aware tournament reduction.
//
// All backends must produce results bit-identical to the scalar
// reference here. The cookbook § 18.2 conformance suite validates
// this with CRC checks.

// GPU implementation
//
// A Metal kernel for Hamming-NN lives in
// glref-metal-hamming_nn.metal. On non-Apple platforms a CUDA or
// SPIR-V/Vulkan equivalent is implementable but is out of scope
// for the v0.36 reference; the AVX-512 backend handles bulk
// workloads on x86_64.

#[cfg(test)]
mod tests {
    use super::*;
    use substrate_types::hamming::ALL_BLOCKS;

    #[test]
    fn top_one_finds_self() {
        let anchor = Fingerprint256::new(0xCAFE, 0xBABE, 0xDEAD, 0xBEEF);
        let id_self: u128 = 1;
        let id_other: u128 = 2;
        let candidates = vec![
            (id_self, anchor),
            (id_other, Fingerprint256::new(0, 0, 0, 0)),
        ];
        let hits = top_k(&anchor, candidates, 1, ALL_BLOCKS);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].row_id, id_self);
        assert_eq!(hits[0].distance, 0);
    }

    #[test]
    fn top_k_returns_sorted_ascending() {
        let anchor = Fingerprint256::ZERO;
        let candidates: Vec<(u128, Fingerprint256)> = vec![
            (1, Fingerprint256::new(0xFF, 0, 0, 0)),                  // dist 8
            (2, Fingerprint256::new(0x1, 0, 0, 0)),                   // dist 1
            (3, Fingerprint256::new(0x7, 0, 0, 0)),                   // dist 3
            (4, Fingerprint256::new(0xFFFF, 0, 0, 0)),                // dist 16
        ];
        let hits = top_k(&anchor, candidates, 3, ALL_BLOCKS);
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0].distance, 1);
        assert_eq!(hits[1].distance, 3);
        assert_eq!(hits[2].distance, 8);
    }
}
