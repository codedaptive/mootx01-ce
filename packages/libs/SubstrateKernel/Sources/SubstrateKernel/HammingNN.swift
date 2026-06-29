// HammingNN.swift
//
// Top-K Hamming nearest-neighbor search per cookbook § 8.2.
//
// Brute-force exact NN over fingerprints. For 1M-row estates at
// 32 bytes/fingerprint, the working set is 32 MB; at typical
// LPDDR5 bandwidth (~60 GB/s on Apple Silicon M-series) a full
// scan takes ~500 µs. K=10 top-K maintenance adds negligible
// overhead via a small bounded max-heap (cookbook § 17.1 budget).
//
// The structure here is deliberate:
//
//   1. A candidate iterator (filtered by predicate; usually a
//      bitmap-tier filter has already pruned).
//   2. For each candidate, compute Hamming distance via the
//      kernel layer (here scalar; production routes to SIMD).
//   3. Maintain a fixed-size max-heap of the K smallest distances.
//   4. Return them sorted ascending by (distance, rowID.uuidString).
//
// Tie-break convention: equal-distance hits are ordered by
// rowID.uuidString ascending. This gives deterministic, reproducible
// results across runs and Swift/Rust ports — a substrate-wide
// requirement for conformance vectors. Mirrors the index-ascending
// convention in SubstrateLib's kernel-path tie-break tests.
//
// This is the substrate's foundational retrieval primitive; every
// `recall_similar_*` CognitionKit primitive composes from it.

import Foundation
import SubstrateTypes

public struct HammingNNHit: Hashable, Sendable {
    public let rowID: UUID
    public let distance: Int

    public init(rowID: UUID, distance: Int) {
        self.rowID = rowID
        self.distance = distance
    }
}

/// Reference top-K Hamming-NN over a candidate row list.
///
/// `candidates` is an iterator over `(rowID, fingerprint)` pairs.
/// In production the iterator is backed by the bit-slice tensor
/// (cookbook § 4.1) scanned through the kernel layer; here a
/// simple array iterator suffices.
///
/// `blocks` defaults to all four; supply a subset for per-block
/// similarity (e.g. `[1]` for topic-only).
public enum HammingNN {

    public static func topK<S: Sequence>(
        anchor: Fingerprint256,
        candidates: S,
        k: Int,
        blocks: BlockMask = .all
    ) -> [HammingNNHit] where S.Element == (UUID, Fingerprint256) {
        precondition(k > 0, "k must be positive")

        // Bounded max-heap by distance: keep the smallest K
        // distances seen so far. The heap is small (K typically
        // 10–100), so a flat array with manual reheap is fine.
        var heap = [HammingNNHit]()
        heap.reserveCapacity(k)

        for (rowID, fingerprint) in candidates {
            let d = Hamming.distance(anchor, fingerprint, blocks: blocks)
            let newHit = HammingNNHit(rowID: rowID, distance: d)
            if heap.count < k {
                heap.append(newHit)
                heapifyUp(&heap)
            } else if heapLarger(heap[0], newHit) {
                // Root is strictly worse than the new hit; evict root.
                heap[0] = newHit
                heapifyDown(&heap)
            }
        }

        // Sort ascending by (distance, rowID.uuidString) for determinism.
        return heap.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.rowID.uuidString < $1.rowID.uuidString
        }
    }

    // MARK: - Heap ordering — max-heap where root is the worst retained hit

    // "Larger" in heap terms = worse = should be evicted soonest.
    // Primary: larger distance is worse. Secondary: larger uuidString
    // is worse, so ties evict the candidate with the higher row ID,
    // keeping the candidate with the lower row ID in the result.
    @inline(__always)
    private static func heapLarger(_ a: HammingNNHit, _ b: HammingNNHit) -> Bool {
        if a.distance != b.distance { return a.distance > b.distance }
        return a.rowID.uuidString > b.rowID.uuidString
    }

    // MARK: - Max-heap helpers (root has the worst/largest hit)

    private static func heapifyUp(_ heap: inout [HammingNNHit]) {
        var i = heap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if heapLarger(heap[i], heap[parent]) {
                heap.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private static func heapifyDown(_ heap: inout [HammingNNHit]) {
        var i = 0
        let n = heap.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var largest = i
            if left < n && heapLarger(heap[left], heap[largest]) {
                largest = left
            }
            if right < n && heapLarger(heap[right], heap[largest]) {
                largest = right
            }
            if largest == i { break }
            heap.swapAt(i, largest)
            i = largest
        }
    }
}

// MARK: - Batched / vectorized hot-path
//
// The reference implementation above is correct and clear. The
// production hot-path in NeuronKit is structured differently:
//
//   1. Bit-slice the candidate fingerprints by block (256 separate
//      arrays of length N).
//   2. For each block, XOR with the corresponding anchor block
//      replicated across N lanes.
//   3. Per-row popcount via VPOPCNTQ (AVX-512), AMX matrix-mode,
//      or vcnt (NEON).
//   4. Sum the four block popcounts per row.
//   5. Top-K via a SIMD-aware tournament reduction.
//
// All four backends must produce results bit-identical to the
// scalar reference here. The cookbook § 18.2 conformance suite
// validates this with CRC checks.

// MARK: - GPU implementation
//
// The Metal backend is implemented in `PortableKernel-Metal.swift`
// (embedded shader string, explicit `KernelKind.metal` selection).
// It is NOT automatically selected: `kernelForCurrentPlatform()`
// returns the SIMD kernel on arm64. Metal must be requested explicitly
// via `PortableKernel.kernel(of: .metal)`.
