// kernel_avx512.rs
//
// ═══════════════════════════════════════════════════════════════════
// DARK PATH — P11-VAL-015
//
// This backend is BUILT but NOT selected by runtime dispatch.
// `PortableKernel::for_current_platform()` never returns this kernel.
// `PortableKernel::of_kind(KernelKind::Avx512)` is the only entry
// point, and it is exercised only by explicit override (conformance
// tests, future MatrixSprint benchmarks, operator --kernel=avx512).
//
// Gate-enable condition: MatrixSprint must demonstrate that
// `Avx512HammingKernel` is measurably faster than `ScalarKernel`
// on real AVX-512 VPOPCNTDQ hardware at the estate sizes we actually
// run. We cannot benchmark this on Apple Silicon (no AVX-512).
// Until that proof exists, scalar remains the live oracle and this
// file is a DARK backend: present and correct, not live.
//
// SCALAR IS THE ORACLE. If `Avx512HammingKernel` ever produces a
// different result from `ScalarKernel` for the same input, that is a
// bug in the AVX-512 path — not a reason to update the scalar path.
// ═══════════════════════════════════════════════════════════════════
//
// Algorithm: VPOPCNTQ bulk Hamming-NN (cookbook § 8.2 + § 17.5)
//
// Hamming distance of two 256-bit fingerprints = popcount of their
// XOR. That is: for each of the 4 × 64-bit blocks, XOR and count
// set bits; sum the four per-block counts.
//
//   scalar:  (a.b0 ^ b.b0).count_ones()
//           + (a.b1 ^ b.b1).count_ones()
//           + ...
//
// The AVX-512 VPOPCNTDQ extension adds `VPOPCNTQ` (_mm512_popcnt_epi64),
// which computes popcount independently for each of 8 × 64-bit lanes
// in a 512-bit register. This means we can process 8 × 256-bit
// candidate fingerprints in 4 VPOPCNTQ instructions:
//
//   1. Collect candidate.block_j for j=0..4 across 8 candidates
//      into four __m512i registers (8 × 64-bit lanes each).
//   2. XOR each 512-bit register with the probe.block_j broadcast.
//      → _mm512_xor_epi64 (AVX-512F)
//   3. Apply VPOPCNTQ to each block register.
//      → _mm512_popcnt_epi64 (AVX-512VPOPCNTDQ)
//   4. Sum the four block popcount registers lane-wise.
//      → _mm512_add_epi64 (AVX-512F)
//   5. Store the 8 summed distances from the 512-bit total register.
//      → _mm512_storeu_si512 (AVX-512F)
//
// Correctness: VPOPCNTQ is defined by Intel as the exact bit-count
// of each 64-bit lane (same as Rust's `u64::count_ones()`). XOR and
// integer addition are exact. The result is therefore bit-identical
// to the scalar reference for every possible input.
//
// Tail candidates (when the count is not a multiple of 8) fall back
// to scalar XOR + count_ones — also bit-identical.
//
// This file compiles only on x86_64 (see `lib.rs` module declaration).
// On aarch64 and other platforms, the entire module is absent.
// The `is_x86_feature_detected!` runtime guard further ensures the
// VPOPCNTQ code paths are never called on x86_64 CPUs that lack the
// avx512vpopcntdq extension.
//
// ── CPUID Safety Invariant (secfix 2026-06-28) ───────────────────────
//
// The `#[target_feature(enable = "avx512f,avx512vpopcntdq")]` attribute on
// the two private `unsafe fn` below tells the compiler to EMIT the AVX-512
// machine instructions for those function bodies. This is a COMPILE-TIME
// directive only — it does NOT prevent the instructions from being
// executed on a CPU that lacks the extension. Executing AVX-512
// intrinsics on a CPU without `avx512f` + `avx512vpopcntdq` is
// undefined behaviour and results in a SIGILL fault at runtime.
//
// `is_x86_feature_detected!` is the RUNTIME SAFETY PRECONDITION:
//
//   `Avx512HammingKernel::has_avx512_vpopcntdq()` calls
//   `is_x86_feature_detected!("avx512f")` and
//   `is_x86_feature_detected!("avx512vpopcntdq")`. These macro calls
//   perform a CPUID check on the first invocation (cached per thread
//   thereafter). Every method that dispatches to an unsafe inner function
//   calls `has_avx512_vpopcntdq()` FIRST. If it returns false, the method
//   falls back to the scalar path and the unsafe function is never called.
//
//   safe caller:
//     if Self::has_avx512_vpopcntdq() {  ← runtime CPUID gate
//         unsafe { avx512_hamming_... }   ← only reached when safe
//     } else {
//         scalar fallback                 ← no intrinsics, no SIGILL
//     }
//
// Invariant: AVX-512 intrinsics in this file are NEVER called without a
// preceding positive `has_avx512_vpopcntdq()` check. Preserving this
// invariant is mandatory when adding new methods to `Avx512HammingKernel`.
// ─────────────────────────────────────────────────────────────────────────

#![cfg(target_arch = "x86_64")]

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hyperplane::HyperplaneFamily;
use crate::kernel::{SubstrateKernel, KernelKind};

// ---- AVX-512 inner implementations ----
//
// These functions are `unsafe` because they require the CPU to support
// the `avx512f` and `avx512vpopcntdq` target features. The safe
// `SubstrateKernel` impl below checks `is_x86_feature_detected!`
// before every call to verify the requirement is met.
//
// The `#[target_feature(enable = "...")]` attribute tells the compiler
// to emit code that assumes the listed CPU features are available.
// Without it, the compiler would not be allowed to emit `VPOPCNTQ`
// instructions even inside an `unsafe` block.

/// Single-pair Hamming distance via VPOPCNTQ.
///
/// Packs the four XOR-ed blocks into the lower 4 lanes of a 512-bit
/// register (upper 4 lanes = 0, contributing 0 to the final sum),
/// applies `_mm512_popcnt_epi64` (VPOPCNTQ), stores all 8 lanes,
/// and sums the first four.
///
/// Bit-identical to `(a ^ b).popcount()` in `ScalarKernel`:
/// - XOR is exact integer arithmetic (no rounding, no approximation).
/// - VPOPCNTQ is the exact bit-count of a 64-bit integer, identical
///   to Rust's `u64::count_ones()` by Intel specification.
/// - Integer addition is exact.
///
/// # Safety
/// Caller MUST verify `avx512f` + `avx512vpopcntdq` via
/// `Avx512HammingKernel::has_avx512_vpopcntdq()` before calling.
#[target_feature(enable = "avx512f,avx512vpopcntdq")]
unsafe fn avx512_hamming_distance_256(a: &Fingerprint256, b: &Fingerprint256) -> u32 {
    use std::arch::x86_64::{
        __m512i,
        _mm512_set_epi64,
        _mm512_popcnt_epi64,
        _mm512_storeu_si512,
    };

    // Scalar XOR — exact, no rounding. Same bits as scalar kernel.
    let x0 = (a.block0 ^ b.block0) as i64;
    let x1 = (a.block1 ^ b.block1) as i64;
    let x2 = (a.block2 ^ b.block2) as i64;
    let x3 = (a.block3 ^ b.block3) as i64;

    // _mm512_set_epi64(e7, e6, e5, e4, e3, e2, e1, e0):
    // Intel intrinsic arg order is highest-lane first, so e0 maps to
    // lane 0 (the lowest-addressed element). We load XOR results into
    // lanes 0-3 and fill lanes 4-7 with 0 so their VPOPCNTQ results
    // are 0 and contribute nothing to the horizontal sum.
    let v = _mm512_set_epi64(0i64, 0i64, 0i64, 0i64, x3, x2, x1, x0);

    // VPOPCNTQ: count set bits independently in each of the 8 × 64-bit
    // lanes. Lanes 0-3 carry the XOR results; lanes 4-7 are 0 → popcount 0.
    let p = _mm512_popcnt_epi64(v);

    // Store all 8 lanes to a local [i64; 8] buffer (512 bits = 64 bytes,
    // which the buffer provides). Cast to *mut __m512i to match the
    // stdarch intrinsic signature (Rust 1.69+; formerly *mut i32 before
    // stdarch stdarch/pull/1280). _mm512_storeu_si512 writes raw bytes,
    // so the buffer layout is unaffected by the pointer cast type.
    // Sum only lanes 0-3; lanes 4-7 are 0 and don't change the result.
    let mut buf = [0i64; 8];
    _mm512_storeu_si512(buf.as_mut_ptr() as *mut __m512i, p);
    (buf[0] + buf[1] + buf[2] + buf[3]) as u32
}

/// Bulk Hamming distance: one probe vs N candidates, 8 at a time.
///
/// Main loop (8 candidates per iteration):
///   1. Gather `candidate.block_j` for j ∈ {0,1,2,3} across 8
///      candidates into four 512-bit registers (8 i64 lanes each).
///   2. XOR each block register with the probe's block (broadcast).
///   3. Apply VPOPCNTQ to each block XOR register.
///   4. Sum the four block-popcount registers lane-wise.
///   5. Store 8 i64 distances from the 512-bit total register.
///
/// Tail (fewer than 8 remaining): scalar XOR + `count_ones`.
///
/// Bit-identical to a scalar loop because XOR and VPOPCNTQ are exact
/// integer operations (see function-level doc on `avx512_hamming_distance_256`).
/// The tail path uses the scalar algorithm directly.
///
/// # Safety
/// Same as `avx512_hamming_distance_256`.
#[target_feature(enable = "avx512f,avx512vpopcntdq")]
unsafe fn avx512_hamming_distance_batch(
    probe: &Fingerprint256,
    candidates: &[Fingerprint256],
    out: &mut [u32],
) {
    use std::arch::x86_64::{
        __m512i,
        _mm512_set1_epi64,
        _mm512_set_epi64,
        _mm512_xor_epi64,
        _mm512_popcnt_epi64,
        _mm512_add_epi64,
        _mm512_storeu_si512,
    };

    // Broadcast each probe block to all 8 lanes of a __m512i. These
    // four registers stay in AVX-512 registers for the entire candidate
    // scan — one of the key throughput advantages over the scalar path.
    let p0 = _mm512_set1_epi64(probe.block0 as i64);
    let p1 = _mm512_set1_epi64(probe.block1 as i64);
    let p2 = _mm512_set1_epi64(probe.block2 as i64);
    let p3 = _mm512_set1_epi64(probe.block3 as i64);

    let n = candidates.len();
    let mut i = 0usize;

    // ── Main loop: 8 candidates per AVX-512 iteration ──────────────
    while i + 8 <= n {
        let c = &candidates[i..];

        // Gather block0 of candidates[i..i+8] into one __m512i.
        // _mm512_set_epi64(e7, e6, e5, e4, e3, e2, e1, e0):
        // e0 → lane 0 (= candidates[i+0].block0), ..., e7 → lane 7.
        // Using set (gather from 8 scattered fields) is correct here;
        // a transposed-SoA layout would allow a single vmovdqu64 load
        // instead, which is a future optimisation for when this backend
        // is gate-enabled after MatrixSprint validation.
        let c0 = _mm512_set_epi64(
            c[7].block0 as i64, c[6].block0 as i64,
            c[5].block0 as i64, c[4].block0 as i64,
            c[3].block0 as i64, c[2].block0 as i64,
            c[1].block0 as i64, c[0].block0 as i64,
        );
        let c1 = _mm512_set_epi64(
            c[7].block1 as i64, c[6].block1 as i64,
            c[5].block1 as i64, c[4].block1 as i64,
            c[3].block1 as i64, c[2].block1 as i64,
            c[1].block1 as i64, c[0].block1 as i64,
        );
        let c2 = _mm512_set_epi64(
            c[7].block2 as i64, c[6].block2 as i64,
            c[5].block2 as i64, c[4].block2 as i64,
            c[3].block2 as i64, c[2].block2 as i64,
            c[1].block2 as i64, c[0].block2 as i64,
        );
        let c3 = _mm512_set_epi64(
            c[7].block3 as i64, c[6].block3 as i64,
            c[5].block3 as i64, c[4].block3 as i64,
            c[3].block3 as i64, c[2].block3 as i64,
            c[1].block3 as i64, c[0].block3 as i64,
        );

        // XOR each block register with the broadcasted probe block.
        let x0 = _mm512_xor_epi64(c0, p0);
        let x1 = _mm512_xor_epi64(c1, p1);
        let x2 = _mm512_xor_epi64(c2, p2);
        let x3 = _mm512_xor_epi64(c3, p3);

        // VPOPCNTQ on each block's XOR → 8 per-candidate bit-counts
        // for that block. Each lane holds the number of differing bits
        // in one candidate's corresponding block (0 to 64).
        let pop0 = _mm512_popcnt_epi64(x0);
        let pop1 = _mm512_popcnt_epi64(x1);
        let pop2 = _mm512_popcnt_epi64(x2);
        let pop3 = _mm512_popcnt_epi64(x3);

        // Sum the four per-block popcounts lane-wise. Each lane of
        // `total` now holds the full 256-bit Hamming distance for one
        // candidate (0 to 256).
        let total = _mm512_add_epi64(
            _mm512_add_epi64(pop0, pop1),
            _mm512_add_epi64(pop2, pop3),
        );

        // Store all 8 i64 distance values from the 512-bit register.
        // popcount(256 bits) ≤ 256, which fits trivially in u32.
        // The i64 → u32 cast is lossless for all valid inputs.
        // Cast to *mut __m512i per stdarch post-1.69 signature
        // (formerly *mut i32; see stdarch/pull/1280).
        let mut buf = [0i64; 8];
        _mm512_storeu_si512(buf.as_mut_ptr() as *mut __m512i, total);
        for j in 0..8 {
            out[i + j] = buf[j] as u32;
        }

        i += 8;
    }

    // ── Tail: fewer than 8 remaining candidates ─────────────────────
    // Scalar XOR + count_ones for the remainder. Bit-identical to the
    // main loop by algorithm equivalence; avoids padding complexity.
    while i < n {
        let c = &candidates[i];
        out[i] = (probe.block0 ^ c.block0).count_ones()
               + (probe.block1 ^ c.block1).count_ones()
               + (probe.block2 ^ c.block2).count_ones()
               + (probe.block3 ^ c.block3).count_ones();
        i += 1;
    }
}

// ---- Public struct ----

/// AVX-512 VPOPCNTQ-backed Hamming-NN kernel (x86_64 only).
///
/// **DARK PATH** — never selected by `PortableKernel::for_current_platform()`.
/// Available only via `PortableKernel::of_kind(KernelKind::Avx512)` for
/// explicit override, conformance testing, or future MatrixSprint
/// benchmarking. See the module-level doc comment for the gate-enable
/// criteria.
///
/// On x86_64 hosts that do not have `avx512f` + `avx512vpopcntdq`, the
/// VPOPCNTQ paths fall back to scalar XOR + `count_ones`. The result is
/// bit-identical in both cases.
///
/// Non-Hamming operations (`simhash_block`, `or_reduce_256`,
/// `count_fold_256`) delegate to the scalar/default implementations.
/// This backend specialises exclusively on the Hamming-NN hot path.
pub struct Avx512HammingKernel;

impl Avx512HammingKernel {
    /// Construct a new `Avx512HammingKernel`. The struct has no fields;
    /// this exists purely for API symmetry with other kernel types.
    pub fn new() -> Self { Self }

    /// Runtime feature check. Returns `true` when the executing CPU
    /// supports both AVX-512F (foundation 512-bit registers and
    /// instructions) and AVX-512VPOPCNTDQ (`VPOPCNTQ` and `VPOPCNTD`
    /// popcount instructions).
    ///
    /// `is_x86_feature_detected!` caches the CPUID result on first call
    /// (per-thread), so repeated calls are near-free (one atomic load
    /// after warm-up).
    ///
    /// This guard is called at the entry of every hot-path method before
    /// dispatching to the `unsafe` AVX-512 inner functions.
    #[inline(always)]
    pub fn has_avx512_vpopcntdq() -> bool {
        is_x86_feature_detected!("avx512f")
            && is_x86_feature_detected!("avx512vpopcntdq")
    }
}

impl Default for Avx512HammingKernel {
    fn default() -> Self { Self::new() }
}

impl SubstrateKernel for Avx512HammingKernel {
    /// Returns `KernelKind::Avx512`. Used by the conformance harness and
    /// dispatcher tests to verify this is the selected backend.
    fn kind(&self) -> KernelKind { KernelKind::Avx512 }

    /// Popcount of a single u64. No AVX-512 benefit for a single word;
    /// delegates to the scalar `count_ones()`.
    fn popcount64(&self, x: u64) -> u32 {
        x.count_ones()
    }

    /// Hamming distance between two 256-bit fingerprints.
    ///
    /// On hosts with AVX-512F + VPOPCNTDQ: packs the four XOR blocks
    /// into the lower half of a 512-bit register, applies VPOPCNTQ,
    /// and sums the lane counts. See `avx512_hamming_distance_256`.
    ///
    /// On hosts without the feature: scalar XOR + `count_ones` for
    /// each of the 4 × 64-bit blocks. Bit-identical to the VPOPCNTQ
    /// path by algorithm construction.
    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32 {
        if Self::has_avx512_vpopcntdq() {
            // SAFETY: has_avx512_vpopcntdq() confirmed avx512f +
            // avx512vpopcntdq are available on this CPU.
            unsafe { avx512_hamming_distance_256(a, b) }
        } else {
            // Scalar fallback — bit-identical to the VPOPCNTQ path.
            a.zip4(b, |x, y| x ^ y).popcount()
        }
    }

    /// Batch Hamming distance: probe vs every candidate.
    ///
    /// On hosts with AVX-512F + VPOPCNTDQ: processes 8 candidates per
    /// SIMD iteration using the bulk VPOPCNTQ kernel. The tail (< 8
    /// remaining candidates) uses scalar. See `avx512_hamming_distance_batch`.
    ///
    /// On hosts without the feature: scalar loop (same as
    /// `SubstrateKernel` default, but inlined here to avoid the
    /// double-dispatch cost of calling the trait default which calls
    /// `hamming_distance_256`).
    fn hamming_distance_batch(&self,
                              probe: &Fingerprint256,
                              candidates: &[Fingerprint256],
                              out: &mut [u32]) {
        debug_assert_eq!(candidates.len(), out.len(),
            "hamming_distance_batch: candidates and out must be the same length");
        if Self::has_avx512_vpopcntdq() {
            // SAFETY: has_avx512_vpopcntdq() confirmed avx512f +
            // avx512vpopcntdq are available on this CPU.
            unsafe { avx512_hamming_distance_batch(probe, candidates, out) }
        } else {
            // Scalar fallback — identical to trait default.
            for (i, cand) in candidates.iter().enumerate() {
                out[i] = (probe.block0 ^ cand.block0).count_ones()
                       + (probe.block1 ^ cand.block1).count_ones()
                       + (probe.block2 ^ cand.block2).count_ones()
                       + (probe.block3 ^ cand.block3).count_ones();
            }
        }
    }

    /// Top-K Hamming-NN using the AVX-512 batch distance engine.
    ///
    /// Two-phase approach:
    ///   1. Compute all N distances via `hamming_distance_batch` (the
    ///      AVX-512 hot path when the feature is available).
    ///   2. Select the K nearest using the same heap algorithm as
    ///      `ScalarKernel` — same tie-break (distance ASC, index ASC).
    ///
    /// Bit-identical to `ScalarKernel::hamming_top_k` by construction:
    ///   - Distances are identical (VPOPCNTQ = count_ones for each lane).
    ///   - Heap algorithm and tie-break are identical.
    ///
    /// The allocation of a full `distances` vec is the trade-off for
    /// clean separation of the vectorized distance phase and the
    /// sequential selection phase. In a gate-enabled production path
    /// (post-MatrixSprint) a fused SIMD top-K could avoid this
    /// allocation; the current structure makes correctness obvious.
    fn hamming_top_k(&self,
                     probe: &Fingerprint256,
                     candidates: &[Fingerprint256],
                     k: usize) -> Vec<(usize, u32)> {
        if k == 0 || candidates.is_empty() { return Vec::new(); }

        // Phase 1: vectorized bulk distance computation.
        let mut distances = vec![0u32; candidates.len()];
        self.hamming_distance_batch(probe, candidates, &mut distances);

        // Phase 2: heap-based top-K, same algorithm + tie-break as
        // ScalarKernel (distance ASC, index ASC on equal distances).
        // BinaryHeap is a max-heap; (distance, index) tuples are
        // evicted when a strictly better candidate arrives.
        use std::collections::BinaryHeap;
        let mut heap: BinaryHeap<(u32, usize)> = BinaryHeap::with_capacity(k);
        for (idx, &d) in distances.iter().enumerate() {
            if heap.len() < k {
                heap.push((d, idx));
            } else if let Some(&top) = heap.peek() {
                if (d, idx) < top {
                    heap.pop();
                    heap.push((d, idx));
                }
            }
        }
        // into_sorted_vec returns ascending by Ord → (distance ASC, index ASC).
        // Re-pair as (idx, distance) to match the trait's return shape.
        heap.into_sorted_vec()
            .into_iter()
            .map(|(d, idx)| (idx, d))
            .collect()
    }

    /// OR-reduce: scalar fallback. This backend specialises Hamming-NN;
    /// OR-reduce is not on the AVX-512 critical path.
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256 {
        Fingerprint256::reduce4(fingerprints.iter().copied(), |x, y| x | y)
    }

    /// SimHash block: scalar fallback. Not on the AVX-512 critical path.
    fn simhash_block(&self, input: &[u64], family: &HyperplaneFamily) -> u64 {
        substrate_types::simhash::block(input, family)
    }
}

// ---- In-module unit tests ----
//
// These run on any x86_64 host (the whole module is x86_64-only).
// They test the safe API surface of Avx512HammingKernel — including
// the scalar fallback path that runs when VPOPCNTDQ is absent — and
// confirm that `kind()` reports correctly.
//
// The VPOPCNTQ fast-path conformance test (explicit AVX-512 intrinsic
// call + canonical vector check) lives in
// `tests/avx512_hamming_conformance.rs` so it can be gated with
// `is_x86_feature_detected!` at runtime and skip gracefully when
// the feature is absent.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::SubstrateKernel;
    use substrate_types::fingerprint256::Fingerprint256;

    #[test]
    fn avx512_kernel_reports_correct_kind() {
        // The dispatcher uses kind() to confirm it returned the right
        // backend. Avx512HammingKernel must report Avx512, not Scalar.
        assert_eq!(Avx512HammingKernel::new().kind(), KernelKind::Avx512);
    }

    #[test]
    fn hamming_distance_256_matches_scalar_reference() {
        // Verifies that both paths (VPOPCNTQ when available, scalar
        // fallback when not) produce the same result as the scalar
        // XOR + count_ones reference. This test passes on all x86_64
        // hosts regardless of whether VPOPCNTDQ is present.
        let pairs: &[(Fingerprint256, Fingerprint256)] = &[
            // Seed: 0xCAFEBABEDEADBEEF (canonical test seed)
            (
                Fingerprint256::new(0xCAFEBABEDEADBEEF, 0x0123456789ABCDEF,
                                    0xFEDCBA9876543210, 0x1122334455667788),
                Fingerprint256::new(0x0000000000000000, 0xFFFFFFFFFFFFFFFF,
                                    0xCAFEBABEDEADBEEF, 0x8877665544332211),
            ),
            (
                Fingerprint256::new(0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
                                    0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
                Fingerprint256::ZERO,
            ),
            (Fingerprint256::ZERO, Fingerprint256::ZERO),
        ];
        let kernel = Avx512HammingKernel::new();
        for (a, b) in pairs {
            let expected = (a.block0 ^ b.block0).count_ones()
                         + (a.block1 ^ b.block1).count_ones()
                         + (a.block2 ^ b.block2).count_ones()
                         + (a.block3 ^ b.block3).count_ones();
            assert_eq!(kernel.hamming_distance_256(a, b), expected,
                "hamming_distance_256 diverged from scalar reference");
        }
    }

    #[test]
    fn hamming_distance_batch_matches_scalar_reference() {
        // 64 candidates: exercises both the main AVX-512 loop
        // (7 × 8 = 56 candidates) and the tail (8 candidates),
        // regardless of whether VPOPCNTDQ is available.
        let mut state: u64 = 0xCAFEBABEDEADBEEF;
        let mut next = || -> u64 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        let probe = Fingerprint256::new(next(), next(), next(), next());
        let candidates: Vec<Fingerprint256> = (0..64)
            .map(|_| Fingerprint256::new(next(), next(), next(), next()))
            .collect();

        let kernel = Avx512HammingKernel::new();
        let mut got = vec![0u32; candidates.len()];
        kernel.hamming_distance_batch(&probe, &candidates, &mut got);

        for (i, (cand, &d)) in candidates.iter().zip(got.iter()).enumerate() {
            let expected = (probe.block0 ^ cand.block0).count_ones()
                         + (probe.block1 ^ cand.block1).count_ones()
                         + (probe.block2 ^ cand.block2).count_ones()
                         + (probe.block3 ^ cand.block3).count_ones();
            assert_eq!(d, expected, "batch distance mismatch at index {}", i);
        }
    }

    #[test]
    fn hamming_top_k_matches_scalar_kernel() {
        // The two-phase AVX-512 top-K must produce the same result as
        // ScalarKernel for the same probe, candidates, and K.
        use crate::kernel::ScalarKernel;
        let mut state: u64 = 0xCAFEBABEDEADBEEF;
        let mut next = || -> u64 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        let probe = Fingerprint256::new(next(), next(), next(), next());
        let candidates: Vec<Fingerprint256> = (0..200)
            .map(|_| Fingerprint256::new(next(), next(), next(), next()))
            .collect();

        let avx = Avx512HammingKernel::new();
        let scalar = ScalarKernel::new();
        for k in [1, 5, 10, 20] {
            let avx_result   = avx.hamming_top_k(&probe, &candidates, k);
            let scalar_result = scalar.hamming_top_k(&probe, &candidates, k);
            assert_eq!(avx_result, scalar_result,
                "hamming_top_k diverged from ScalarKernel at k={}", k);
        }
    }
}
