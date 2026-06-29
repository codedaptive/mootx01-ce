// kernel_simd.rs
//
// Portable-SIMD-backed kernel implementation per
// DECISION_OR_REDUCE_BACKENDS_2026-05-17.md (Axis 1, the "1" path)
// and DECISION_HAMMING_BACKENDS_2026-05-17.md (Phase 2.β-1).
//
// Uses Rust's nightly `std::simd::u64x4` for SIMD lanes. On
// aarch64 (Apple Silicon and other ARM64 targets), the compiler
// emits NEON instructions:
//
//   or_reduce_256:  u64x4 |=  →  `orr.16b`
//   hamming_distance_256:  u64x4 ^  →  `eor.16b`
//                          + lane-wise count_ones  →  `cnt.16b`
//
// This is the per-op-optimal path for the bandwidth-bound ops
// the substrate uses, per cookbook § 4.4 and § 17.5.
//
// SimdKernel is the Rust mirror of the Swift `SimdKernel` struct.
// Phase 2.α-1 added `or_reduce_*`. Phase 2.β-1 added
// `hamming_distance_256`, `hamming_distance_batch`, and
// `hamming_top_k`. Phase 2.γ-1 added `simhash_block_batch` via
// vertical SIMD over hyperplanes (see lines 297-315).
//
// This module is compiled only when the `simd-nightly` Cargo
// feature is enabled (and a nightly toolchain is in use).
// Stable builds skip it entirely; `KernelKind::Simd` exists but
// falls through to `ScalarKernel`.
//
// Conformance: every method must produce byte-identical output
// to `ScalarKernel` for the same inputs. The four-way conformance
// gate verifies this when invoked with `--kernel=simd`.

#![cfg(feature = "simd-nightly")]

use std::simd::u64x4;
use substrate_types::count_vector::CountVector256;

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hyperplane::HyperplaneFamily;
use crate::kernel::SubstrateKernel;

/// SIMD-backed kernel. Wins on aarch64 (NEON) and Apple Silicon.
/// Falls back to scalar for ops not yet SIMD-implemented.
pub struct SimdKernel;

impl SimdKernel {
    pub fn new() -> Self { Self }

    /// Internal helper: Hamming distance between two
    /// fingerprints via u64x4 XOR + lane-wise count_ones.
    /// On aarch64 the compiler emits `eor.16b` + `cnt.16b` +
    /// horizontal sum. Inlined into hot-path callers so the
    /// dispatch overhead doesn't appear in tight loops.
    #[inline(always)]
    fn hd256(a: &Fingerprint256, b: &Fingerprint256) -> u32 {
        let av = u64x4::from_array([a.block0, a.block1, a.block2, a.block3]);
        let bv = u64x4::from_array([b.block0, b.block1, b.block2, b.block3]);
        let x = (av ^ bv).to_array();
        x[0].count_ones() + x[1].count_ones()
            + x[2].count_ones() + x[3].count_ones()
    }
}

// ----- Packed family layout + SIMD inner loop (Phase 2.γ-1)

/// SoA layout of one HyperplaneFamily for SIMD evaluation. The
/// 64 hyperplane positive/negative masks are stored as 16 groups
/// of 4 lanes each. Per-(group, word) access is a single u64x4
/// load instead of four scattered array indirections.
struct PackedFamily {
    positive: Vec<u64x4>,   // 16 groups × word_count entries
    negative: Vec<u64x4>,
    word_count: usize,
}

impl PackedFamily {
    fn new(family: &HyperplaneFamily) -> Self {
        assert_eq!(family.planes.len(), 64,
                   "PackedFamily requires exactly 64 planes");
        let wc = family.planes[0].positive_mask.len();
        let mut pos = Vec::with_capacity(16 * wc);
        let mut neg = Vec::with_capacity(16 * wc);
        for g in 0..16 {
            let p0 = &family.planes[4 * g + 0];
            let p1 = &family.planes[4 * g + 1];
            let p2 = &family.planes[4 * g + 2];
            let p3 = &family.planes[4 * g + 3];
            for i in 0..wc {
                pos.push(u64x4::from_array([
                    p0.positive_mask[i],
                    p1.positive_mask[i],
                    p2.positive_mask[i],
                    p3.positive_mask[i],
                ]));
                neg.push(u64x4::from_array([
                    p0.negative_mask[i],
                    p1.negative_mask[i],
                    p2.negative_mask[i],
                    p3.negative_mask[i],
                ]));
            }
        }
        PackedFamily { positive: pos, negative: neg, word_count: wc }
    }
}

/// Compute one 64-bit SimHash block via vertical SIMD over the
/// packed family. Inner loop processes 4 hyperplanes per SIMD
/// iteration; outer loop covers 16 groups for 64 total. Final
/// per-lane comparison + bit-set assembles the result.
#[inline(always)]
fn simhash_block_simd(input: &[u64], packed: &PackedFamily) -> u64 {
    debug_assert_eq!(input.len(), packed.word_count,
                     "input must match family word count");
    let mut result: u64 = 0;
    for g in 0..16 {
        let mut pos4 = [0u32; 4];
        let mut neg4 = [0u32; 4];
        for i in 0..packed.word_count {
            let v_i = u64x4::splat(input[i]);
            let idx = g * packed.word_count + i;
            let pos_and = (v_i & packed.positive[idx]).to_array();
            let neg_and = (v_i & packed.negative[idx]).to_array();
            pos4[0] = pos4[0].wrapping_add(pos_and[0].count_ones());
            pos4[1] = pos4[1].wrapping_add(pos_and[1].count_ones());
            pos4[2] = pos4[2].wrapping_add(pos_and[2].count_ones());
            pos4[3] = pos4[3].wrapping_add(pos_and[3].count_ones());
            neg4[0] = neg4[0].wrapping_add(neg_and[0].count_ones());
            neg4[1] = neg4[1].wrapping_add(neg_and[1].count_ones());
            neg4[2] = neg4[2].wrapping_add(neg_and[2].count_ones());
            neg4[3] = neg4[3].wrapping_add(neg_and[3].count_ones());
        }
        // Lane-wise sign comparison + bit-set. Matches scalar
        // Hyperplane::sign contract: strict greater-than (ties
        // resolve to false).
        let base = 4 * g;
        if pos4[0] > neg4[0] { result |= 1u64 << (base + 0); }
        if pos4[1] > neg4[1] { result |= 1u64 << (base + 1); }
        if pos4[2] > neg4[2] { result |= 1u64 << (base + 2); }
        if pos4[3] > neg4[3] { result |= 1u64 << (base + 3); }
    }
    result
}

impl Default for SimdKernel {
    fn default() -> Self { Self::new() }
}

impl SubstrateKernel for SimdKernel {
    fn kind(&self) -> crate::kernel::KernelKind { crate::kernel::KernelKind::Simd }

    // ----- popcount64 (inherited semantics)

    fn popcount64(&self, x: u64) -> u32 {
        x.count_ones()
    }

    // ----- Hamming distance via u64x4 XOR + lane-wise popcount (Phase 2.β-1)

    /// Hamming distance between two 256-bit fingerprints via
    /// `u64x4` XOR (`eor.16b`) and lane-wise `count_ones`
    /// (`cnt.16b` + horizontal sum) on aarch64.
    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32 {
        Self::hd256(a, b)
    }

    /// Batched Hamming distance: one probe against N candidates.
    /// Overrides the trait default loop so the probe vector stays
    /// in NEON registers across the inner loop without
    /// `&self.hamming_distance_256` dispatch overhead.
    fn hamming_distance_batch(&self,
                              probe: &Fingerprint256,
                              candidates: &[Fingerprint256],
                              out: &mut [u32]) {
        debug_assert_eq!(candidates.len(), out.len(),
                         "hamming_distance_batch: candidates and out must be the same length");
        let pv = u64x4::from_array([probe.block0, probe.block1,
                                    probe.block2, probe.block3]);
        for (i, cand) in candidates.iter().enumerate() {
            let cv = u64x4::from_array([cand.block0, cand.block1,
                                        cand.block2, cand.block3]);
            let x = (pv ^ cv).to_array();
            out[i] = x[0].count_ones() + x[1].count_ones()
                   + x[2].count_ones() + x[3].count_ones();
        }
    }

    /// Top-K Hamming-NN with sorted-ladder maintenance per cookbook
    /// section 11.2. Rust mirror of the
    /// Swift `SimdKernel.hammingTopK` at
    /// `glref-swift-PortableKernel-SIMD.swift` lines 113-211
    /// (Phase 2.delta-1).
    ///
    /// Replaces the prior score-then-sort strategy: maintains a
    /// K-element sorted (distance, index) ladder during the scan,
    /// avoiding the O(N log N) sort and the N-element scored
    /// allocation. Asymptotic cost: O(N) distance work plus
    /// O(N · K) ladder maintenance worst case; in practice the
    /// `d >= worst` early-exit keeps most candidates from
    /// touching the ladder once it fills, so expected updates
    /// land near K · ln(N / K).
    ///
    /// Tie-break contract (matches scalar reference): for equal
    /// distances, the candidate with smaller index wins. Since
    /// we scan in ascending index order, any earlier candidate
    /// with the same distance is already in the ladder, so the
    /// strict `d >= worst` early-exit preserves the tie-break.
    /// The byte-equality conformance gate verifies this against
    /// `ScalarKernel`.
    ///
    /// Cookbook section 17.1 hot-path budget: K=10 over 1M rows
    /// under 100 microseconds. The bandwidth floor at section
    /// 17.5 is roughly 533 microseconds on apple-m5-max; the
    /// Swift counterpart sits 13% above floor at 604 microseconds
    /// per DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md row 5.
    /// This Rust port targets parity within measurement noise on
    /// the same hardware.
    fn hamming_top_k(&self, probe: &Fingerprint256,
                     candidates: &[Fingerprint256],
                     k: usize) -> Vec<(usize, u32)> {
        if k == 0 || candidates.is_empty() { return Vec::new(); }
        let n = candidates.len();
        let effective_k = k.min(n);

        let pv = u64x4::from_array([probe.block0, probe.block1,
                                    probe.block2, probe.block3]);

        // Maintained ladder: parallel arrays of distance + index,
        // sorted ascending by distance. Initialize with sentinels
        // (u32::MAX distance) so the first K candidates always
        // insert. Parallel arrays beat tuple arrays for cache
        // behavior under tight inner loops.
        let mut top_dist: Vec<u32> = vec![u32::MAX; effective_k];
        let mut top_idx: Vec<usize> = vec![usize::MAX; effective_k];

        // Local cached worst-in-ladder for fast early exit. Read
        // path is hot; written only when the ladder updates.
        let mut worst: u32 = u32::MAX;

        for idx in 0..n {
            let cand = &candidates[idx];
            let cv = u64x4::from_array([cand.block0, cand.block1,
                                        cand.block2, cand.block3]);
            let x = (pv ^ cv).to_array();
            let d = x[0].count_ones() + x[1].count_ones()
                  + x[2].count_ones() + x[3].count_ones();

            // Early exit. Equal distance with an already-present
            // lower-index candidate also bypasses the ladder
            // update, since we scan in ascending index order and
            // the tie-break favors the earlier candidate.
            if d >= worst { continue; }

            // Find insertion position: rightmost pos in [0, K)
            // such that all top_dist[i < pos] are <= d. Linear
            // scan beats binary search for K <= ~32 because the
            // branch predictor handles short loops well.
            let mut pos = effective_k - 1;
            while pos > 0 && top_dist[pos - 1] > d {
                pos -= 1;
            }

            // Shift entries [pos, K-2] one position right to
            // make room. The last entry (was at K-1) is
            // displaced and forgotten.
            let mut i = effective_k - 1;
            while i > pos {
                top_dist[i] = top_dist[i - 1];
                top_idx[i]  = top_idx[i - 1];
                i -= 1;
            }
            top_dist[pos] = d;
            top_idx[pos]  = idx;

            // Update cached worst.
            worst = top_dist[effective_k - 1];
        }

        // Output: drop unfilled sentinel entries. Defensive;
        // with the current logic this cannot happen because
        // effective_k <= n and the first K candidates always
        // insert.
        let mut out: Vec<(usize, u32)> = Vec::with_capacity(effective_k);
        for i in 0..effective_k {
            if top_dist[i] == u32::MAX { break; }
            out.push((top_idx[i], top_dist[i]));
        }
        out
    }

    // ----- simhash_block (inherited semantics; Phase 2.γ scope)

    fn simhash_block(&self, input: &[u64], family: &HyperplaneFamily) -> u64 {
        substrate_types::simhash::block(input, family)
    }

    // ----- simhash_block_batch via vertical SIMD over hyperplanes (Phase 2.γ-1)

    /// Batched SimHash block: one family applied to N input
    /// vectors. The family is manifest-immutable; we build a
    /// packed view of its 64 planes ONCE per batch and reuse it
    /// across every input. Per-input, the inner loop is vertical
    /// SIMD: 16 groups of 4 hyperplanes each, with u64x4 AND +
    /// lane-wise count_ones + u32x4 accumulator.
    fn simhash_block_batch(&self,
                           inputs: &[&[u64]],
                           family: &HyperplaneFamily,
                           out: &mut [u64]) {
        debug_assert_eq!(inputs.len(), out.len(),
                         "simhash_block_batch: inputs and out must be the same length");
        let packed = PackedFamily::new(family);
        for (i, input) in inputs.iter().enumerate() {
            out[i] = simhash_block_simd(input, &packed);
        }
    }

    // ----- OR-reduce via u64x4 |= (Phase 2.α-1)

    /// OR-reduce a cohort of fingerprints via `u64x4`.
    ///
    /// On aarch64 this compiles to a tight loop of NEON
    /// `ldp` + `orr.16b` instructions. The accumulator stays in
    /// NEON registers across iterations.
    ///
    /// For an empty cohort, returns `Fingerprint256::ZERO`
    /// (the OR identity), matching `ScalarKernel` semantics.
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256 {
        let mut acc = u64x4::splat(0);
        for fp in fingerprints {
            acc |= u64x4::from_array([fp.block0, fp.block1, fp.block2, fp.block3]);
        }
        let arr = acc.to_array();
        Fingerprint256 {
            block0: arr[0],
            block1: arr[1],
            block2: arr[2],
            block3: arr[3],
        }
    }

    // ----- Count-fold via a bit-sliced carry-save vertical counter
    //
    // Mirror of SimdKernel.countFold256 in the Swift port.
    // `planes[b]` is a 256-bit value holding bit b of every column's
    // running count, in u64x4 lanes. Each fingerprint is a
    // 0-or-1-per-column vector folded in by a ripple-carry add: sum
    // bit is `plane ^ carry`, carry out is `plane & carry`. The carry
    // dies after about two planes on average, so the per-fingerprint
    // cost is a couple of eor/and pairs rather than a set-bit walk.
    // Byte-identical to the scalar reference, gated by the kernel
    // conformance test under the simd-nightly feature.
    fn count_fold_256(&self, fingerprints: &[Fingerprint256]) -> CountVector256 {
        if fingerprints.is_empty() {
            return CountVector256::zero();
        }
        let zero = u64x4::splat(0);
        let mut planes: Vec<u64x4> = Vec::new();
        for fp in fingerprints {
            let mut carry = u64x4::from_array([fp.block0, fp.block1, fp.block2, fp.block3]);
            let mut b = 0usize;
            while carry != zero {
                if b == planes.len() {
                    planes.push(carry);
                    break;
                }
                let plane = planes[b];
                planes[b] = plane ^ carry;   // sum bit at this weight
                carry = plane & carry;       // carry to the next weight
                b += 1;
            }
        }
        let mut counts = [0u32; 256];
        for (b, plane) in planes.iter().enumerate() {
            let weight = 1u32 << b;
            let arr = plane.to_array();
            for lane in 0..4 {
                let mut word = arr[lane];
                let base = lane * 64;
                while word != 0 {
                    let bit = word.trailing_zeros() as usize;
                    counts[base + bit] = counts[base + bit].wrapping_add(weight);
                    word &= word - 1;
                }
            }
        }
        CountVector256::from_parts(counts, fingerprints.len() as u32)
    }

    /// Batched OR-reduce. Each cohort produces one reduced
    /// fingerprint. Order-preserving: `out[i]` is the reduction
    /// of `batches[i]`.
    ///
    /// Overrides the trait's default loop so the SIMD accumulator
    /// stays in NEON registers across each inner cohort without
    /// the function-call overhead of repeated `or_reduce_256`
    /// dispatches. For short cohorts this is mostly a wash; for
    /// cohort sizes above ~8 it's a measurable win because the
    /// inner loop is not interrupted by trait-method dispatch.
    fn or_reduce_batch(&self,
                       batches: &[&[Fingerprint256]],
                       out: &mut [Fingerprint256]) {
        debug_assert_eq!(batches.len(), out.len(),
                         "or_reduce_batch: batches and out must be the same length");
        for (i, batch) in batches.iter().enumerate() {
            let mut acc = u64x4::splat(0);
            for fp in batch.iter() {
                acc |= u64x4::from_array([fp.block0, fp.block1, fp.block2, fp.block3]);
            }
            let arr = acc.to_array();
            out[i] = Fingerprint256 {
                block0: arr[0],
                block1: arr[1],
                block2: arr[2],
                block3: arr[3],
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::{ScalarKernel, SubstrateKernel};

    fn fingerprints(seed: u64, count: usize) -> Vec<Fingerprint256> {
        let mut state = seed.wrapping_add(0x9E3779B97F4A7C15);
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        (0..count)
            .map(|_| Fingerprint256::new(next(), next(), next(), next()))
            .collect()
    }

    #[test]
    fn simd_count_fold_matches_scalar_across_sizes() {
        // The SIMD vertical counter must equal the scalar reference at
        // every size, including the sizes that cross a plane boundary.
        let scalar = ScalarKernel::new();
        let simd = SimdKernel::new();
        for n in [1usize, 2, 3, 4, 7, 8, 15, 16, 31, 255, 256, 257, 1000, 4096] {
            let fps = fingerprints((n as u64).wrapping_mul(0x100000001B3), n);
            let reference = scalar.count_fold_256(&fps);
            let got = simd.count_fold_256(&fps);
            assert_eq!(got, reference, "SIMD diverged from scalar at n={}", n);
            assert_eq!(got.n(), n as u32);
        }
    }

    #[test]
    fn simd_count_fold_empty() {
        assert_eq!(SimdKernel::new().count_fold_256(&[]), CountVector256::zero());
    }
}
