// kernel.rs
//
// Portable kernel layer per cookbook § 4.4. Mirror of
// glref-swift-PortableKernel.swift.
//
// Trait + scalar reference impl. NEON / AVX-512 / AVX2 specializations
// live in kernel-specific overlay files. All kernels MUST produce
// bit-identical output for the same inputs.

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hyperplane::HyperplaneFamily;
use substrate_types::count_vector::CountVector256;

pub trait SubstrateKernel: Send + Sync {
    /// Identify the concrete kernel kind. Useful for runtime
    /// introspection (stress-test reporting, dispatcher tests,
    /// logging). The default impl is overridden by every
    /// concrete kernel.
    fn kind(&self) -> KernelKind {
        KernelKind::Scalar
    }

    fn popcount64(&self, x: u64) -> u32;
    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32;
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256;
    fn hamming_top_k(&self, probe: &Fingerprint256,
                     candidates: &[Fingerprint256],
                     k: usize) -> Vec<(usize, u32)>;
    /// Single-block SimHash: 64 bits over an input vector with
    /// one hyperplane family. Callers compose four invocations
    /// (one per family) for a full Fingerprint256.
    fn simhash_block(&self, input: &[u64], family: &HyperplaneFamily) -> u64;

    // ----- Batched variants (Phase 1 trait extension per
    //       DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17).
    //
    // Default impls are loops over the pair-at-a-time ops above,
    // so trait extensions are non-breaking and every backend gets
    // correct (if slow) batched behavior for free. Performance
    // backends override these to amortize per-call overhead across
    // a SIMD or GPU dispatch unit.

    /// Hamming distance between `probe` and every candidate in
    /// `candidates`. Output is the same length as `candidates`,
    /// indexed identically.
    fn hamming_distance_batch(&self,
                              probe: &Fingerprint256,
                              candidates: &[Fingerprint256],
                              out: &mut [u32]) {
        debug_assert_eq!(candidates.len(), out.len(),
                         "hamming_distance_batch: candidates and out must be the same length");
        for (i, cand) in candidates.iter().enumerate() {
            out[i] = self.hamming_distance_256(probe, cand);
        }
    }

    /// SimHash block over each input vector in `inputs`, all
    /// against the same hyperplane family. Output is the same
    /// length as `inputs`, indexed identically.
    fn simhash_block_batch(&self,
                           inputs: &[&[u64]],
                           family: &HyperplaneFamily,
                           out: &mut [u64]) {
        debug_assert_eq!(inputs.len(), out.len(),
                         "simhash_block_batch: inputs and out must be the same length");
        for (i, input) in inputs.iter().enumerate() {
            out[i] = self.simhash_block(input, family);
        }
    }

    /// OR-reduce each batch of fingerprints independently. Output
    /// is the same length as `batches`, indexed identically.
    fn or_reduce_batch(&self,
                       batches: &[&[Fingerprint256]],
                       out: &mut [Fingerprint256]) {
        debug_assert_eq!(batches.len(), out.len(),
                         "or_reduce_batch: batches and out must be the same length");
        for (i, batch) in batches.iter().enumerate() {
            out[i] = self.or_reduce_256(batch);
        }
    }

    /// Count-fold a slice of fingerprints into a count-vector: for
    /// each of the 256 bit positions, the number of members with that
    /// bit set, plus the member count. The bundle-algebra fold
    /// (DECISION_BUNDLE_ALGEBRA_AND_ERASURE_2026-05-20). The OR-reduce
    /// above is its degenerate case, saturating each count at one. The
    /// default is the scalar reference; performance backends override
    /// with a vectorized vertical counter, gated against the reference
    /// by the conformance harness.
    fn count_fold_256(&self, fingerprints: &[Fingerprint256]) -> CountVector256 {
        CountVector256::fold(fingerprints)
    }

    /// Count-fold each batch independently. Output is the same length
    /// as `batches`, indexed identically.
    fn count_fold_batch(&self,
                        batches: &[&[Fingerprint256]],
                        out: &mut [CountVector256]) {
        debug_assert_eq!(batches.len(), out.len(),
                         "count_fold_batch: batches and out must be the same length");
        for (i, batch) in batches.iter().enumerate() {
            out[i] = self.count_fold_256(batch);
        }
    }
}

pub struct ScalarKernel;

impl ScalarKernel {
    pub fn new() -> Self { Self }
}

impl SubstrateKernel for ScalarKernel {
    fn kind(&self) -> KernelKind { KernelKind::Scalar }

    fn popcount64(&self, x: u64) -> u32 {
        x.count_ones()
    }

    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32 {
        // Phase 2 (decision 2026-05-28 §6.2): one-liner via the
        // Phase 1 combinators. Bit-identical to the prior unroll.
        a.zip4(b, |x, y| x ^ y).popcount()
    }

    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256 {
        // Phase 2 (decision 2026-05-28 §6.2): one-liner via the
        // Phase 1 combinator. Bit-identical to the prior loop.
        Fingerprint256::reduce4(fingerprints.iter().copied(), |x, y| x | y)
    }

    fn hamming_top_k(&self, probe: &Fingerprint256,
                     candidates: &[Fingerprint256],
                     k: usize) -> Vec<(usize, u32)> {
        // Phase 3.2 (decision 2026-05-28 §6.3): heap-based top-K.
        // Maintains a max-heap of size k keyed on (distance, index)
        // with the SAME tie-break order as the prior full-sort
        // implementation (row-index ascending among equal distances).
        // O(N log k) instead of O(N log N).
        //
        // Conformance: hamming_nn vectors continue to PASS at CRC
        // 0xb1a25c93 because both algorithms produce the same
        // sorted-ascending top-K result.
        use std::collections::BinaryHeap;
        if k == 0 { return Vec::new(); }
        // BinaryHeap is a max-heap. Key is (distance, index) — the
        // candidate with the LARGEST tuple is on top, ready to be
        // evicted when a better candidate arrives.
        let mut heap: BinaryHeap<(u32, usize)> = BinaryHeap::with_capacity(k);
        for (idx, fp) in candidates.iter().enumerate() {
            let d = self.hamming_distance_256(probe, fp);
            if heap.len() < k {
                heap.push((d, idx));
            } else if let Some(&top) = heap.peek() {
                if (d, idx) < top {
                    heap.pop();
                    heap.push((d, idx));
                }
            }
        }
        // into_sorted_vec returns ascending by Ord — exactly the
        // result order we want (distance ascending, index ascending
        // on ties). Then re-pair as (idx, distance) for the public
        // return shape.
        heap.into_sorted_vec()
            .into_iter()
            .map(|(d, idx)| (idx, d))
            .collect()
    }

    fn simhash_block(&self, input: &[u64], family: &HyperplaneFamily) -> u64 {
        substrate_types::simhash::block(input, family)
    }
}

impl Default for ScalarKernel {
    fn default() -> Self { Self::new() }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KernelKind {
    Scalar,
    /// Portable SIMD backend via `std::simd::u64x4`. On aarch64
    /// this compiles to NEON `orr.16b` for OR-reduce. See
    /// DECISION_OR_REDUCE_BACKENDS_2026-05-17.md. Available only
    /// in builds with the `simd-nightly` Cargo feature; without
    /// it, `of_kind(Simd)` falls through to `ScalarKernel`.
    Simd,
    Neon,
    Avx512,
    Avx2,
}

impl KernelKind {
    /// Parse a CLI flag value into a `KernelKind`. Returns None
    /// for unrecognized names. The set of recognized names is
    /// fixed (scalar, simd, neon, avx512, avx2) so the harness
    /// CLI stays identical across stable and nightly builds.
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "scalar" => Some(KernelKind::Scalar),
            "simd"   => Some(KernelKind::Simd),
            "neon"   => Some(KernelKind::Neon),
            "avx512" => Some(KernelKind::Avx512),
            "avx2"   => Some(KernelKind::Avx2),
            _ => None,
        }
    }

    /// Stable string name suitable for embedding in stress-test
    /// JSON output and CLI flag echoes.
    pub fn as_str(self) -> &'static str {
        match self {
            KernelKind::Scalar => "scalar",
            KernelKind::Simd   => "simd",
            KernelKind::Neon   => "neon",
            KernelKind::Avx512 => "avx512",
            KernelKind::Avx2   => "avx2",
        }
    }
}

pub struct PortableKernel;

impl PortableKernel {
    /// Select the best kernel for the current platform.
    ///
    /// On aarch64 (Apple Silicon and ARM64 Linux) WITH the
    /// `simd-nightly` feature enabled, returns `SimdKernel`
    /// (portable SIMD via `std::simd::u64x4`, compiles to NEON
    /// `orr.16b` for or_reduce per
    /// DECISION_OR_REDUCE_BACKENDS_2026-05-17). Stable builds
    /// without the feature fall through to `ScalarKernel`.
    ///
    /// On other platforms, returns `ScalarKernel`. Future
    /// platform-specific overlays may override this for AVX-512
    /// / AVX2 on x86_64.
    pub fn for_current_platform() -> Box<dyn SubstrateKernel> {
        #[cfg(all(target_arch = "aarch64", feature = "simd-nightly"))]
        {
            // SimdKernel strictly dominates ScalarKernel on aarch64
            // for the SIMD-implemented ops; inherited scalar impls
            // are identical for the others. No threshold to learn.
            return Box::new(crate::kernel_simd::SimdKernel::new());
        }
        #[cfg(not(all(target_arch = "aarch64", feature = "simd-nightly")))]
        {
            Box::new(ScalarKernel::new())
        }
    }

    /// Explicit selector for the conformance harness.
    pub fn of_kind(kind: KernelKind) -> Box<dyn SubstrateKernel> {
        match kind {
            KernelKind::Scalar => Box::new(ScalarKernel::new()),
            KernelKind::Simd => {
                #[cfg(feature = "simd-nightly")]
                {
                    Box::new(crate::kernel_simd::SimdKernel::new())
                }
                #[cfg(not(feature = "simd-nightly"))]
                {
                    Box::new(ScalarKernel::new())
                }
            }
            // Direct-intrinsic kernels are conditional-compile in
            // their own files; the reference build falls through
            // to scalar. `Simd` (above) is the portable SIMD path
            // via std::simd and is the recommended kernel on
            // aarch64 today.
            KernelKind::Neon | KernelKind::Avx512 | KernelKind::Avx2 => {
                Box::new(ScalarKernel::new())
            }
        }
    }

    /// Bit-identical output assertion for the conformance gate.
    pub fn assert_equal(lhs: &dyn SubstrateKernel,
                        rhs: &dyn SubstrateKernel,
                        probe: &Fingerprint256,
                        candidates: &[Fingerprint256],
                        k: usize) -> bool {
        let l = lhs.hamming_top_k(probe, candidates, k);
        let r = rhs.hamming_top_k(probe, candidates, k);
        l == r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ----- Dispatcher selection tests
    //
    // These tests assert that PortableKernel::for_current_platform()
    // and PortableKernel::of_kind() return the kernel they claim
    // to return. Without these tests, a misconfigured #[cfg] gate
    // could silently route everything to ScalarKernel while the
    // conformance gate still passes (because scalar and simd
    // produce identical output). The tests fail loudly if the
    // dispatcher routes wrong.

    #[test]
    fn of_kind_scalar_returns_scalar() {
        let k = PortableKernel::of_kind(KernelKind::Scalar);
        assert_eq!(k.kind(), KernelKind::Scalar,
                   "of_kind(Scalar) must return a ScalarKernel");
    }

    #[test]
    fn of_kind_simd_returns_simd_when_feature_enabled() {
        let k = PortableKernel::of_kind(KernelKind::Simd);
        #[cfg(feature = "simd-nightly")]
        assert_eq!(k.kind(), KernelKind::Simd,
                   "with simd-nightly enabled, of_kind(Simd) must return a SimdKernel");
        #[cfg(not(feature = "simd-nightly"))]
        assert_eq!(k.kind(), KernelKind::Scalar,
                   "without simd-nightly, of_kind(Simd) must fall through to ScalarKernel");
    }

    #[test]
    fn for_current_platform_picks_simd_on_aarch64_with_feature() {
        let k = PortableKernel::for_current_platform();
        #[cfg(all(target_arch = "aarch64", feature = "simd-nightly"))]
        assert_eq!(k.kind(), KernelKind::Simd,
                   "on aarch64 + simd-nightly, for_current_platform must return SimdKernel; \
                    got {:?}", k.kind());
        #[cfg(not(all(target_arch = "aarch64", feature = "simd-nightly")))]
        assert_eq!(k.kind(), KernelKind::Scalar,
                   "off aarch64 OR without simd-nightly, for_current_platform must return \
                    ScalarKernel; got {:?}", k.kind());
    }

    // ----- Behavioral conformance: dispatcher's choice produces
    //       byte-identical output to the scalar reference. If the
    //       dispatcher silently routed wrong (e.g., a SimdKernel
    //       with a buggy override), this test catches it
    //       independent of the type assertion above.

    #[test]
    fn dispatcher_or_reduce_matches_scalar() {
        let scalar = ScalarKernel::new();
        let dispatched = PortableKernel::for_current_platform();
        let fingerprints: Vec<Fingerprint256> = (0..32u64)
            .map(|i| Fingerprint256::new(i, i.wrapping_mul(0x9E3779B97F4A7C15),
                                         i.wrapping_mul(0xBF58476D1CE4E5B9),
                                         i.wrapping_mul(0x94D049BB133111EB)))
            .collect();
        let s = scalar.or_reduce_256(&fingerprints);
        let d = dispatched.or_reduce_256(&fingerprints);
        assert_eq!(s, d,
                   "dispatcher's or_reduce_256 must produce scalar-identical output; \
                    scalar={:?} dispatched={:?} kind={:?}", s, d, dispatched.kind());
    }

    #[test]
    fn count_fold_conformance_across_kernels() {
        // Every kernel kind must produce a CountVector256 identical to
        // the scalar reference. Kinds without an override inherit the
        // reference and pass trivially; the gate becomes load-bearing
        // the moment a vectorized override lands.
        let scalar = ScalarKernel::new();
        let fingerprints: Vec<Fingerprint256> = (0..257u64)
            .map(|i| Fingerprint256::new(i.wrapping_mul(0x9E3779B97F4A7C15),
                                         i.wrapping_mul(0xBF58476D1CE4E5B9),
                                         i.wrapping_mul(0x94D049BB133111EB),
                                         i.wrapping_mul(0x2545F4914F6CDD1D)))
            .collect();
        let reference = scalar.count_fold_256(&fingerprints);
        for kind in [KernelKind::Scalar, KernelKind::Simd, KernelKind::Neon,
                     KernelKind::Avx512, KernelKind::Avx2] {
            let k = PortableKernel::of_kind(kind);
            assert_eq!(k.count_fold_256(&fingerprints), reference,
                       "kernel {:?} diverged from scalar reference", kind);
        }
    }

    #[test]
    fn dispatcher_hamming_distance_matches_scalar() {
        let scalar = ScalarKernel::new();
        let dispatched = PortableKernel::for_current_platform();
        let a = Fingerprint256::new(0xCAFEBABE, 0xDEADBEEF, 0x0123456789ABCDEF, 0xFEDCBA9876543210);
        let b = Fingerprint256::new(0x12345678, 0x9ABCDEF0, 0x0F0F0F0F0F0F0F0F, 0xF0F0F0F0F0F0F0F0);
        assert_eq!(scalar.hamming_distance_256(&a, &b),
                   dispatched.hamming_distance_256(&a, &b));
    }
    // Phase 3.2 spec-pinned tie-check tests
    // (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.3.2)

    #[test]
    fn hamming_top_k_ties_break_by_index_ascending() {
        let kernel = ScalarKernel::new();
        let probe = Fingerprint256::ZERO;
        let candidates = vec![
            Fingerprint256::new(0b0001, 0, 0, 0),       // idx 0, d=1
            Fingerprint256::new(0b0011, 0, 0, 0),       // idx 1, d=2 (tie)
            Fingerprint256::new(0b0111, 0, 0, 0),       // idx 2, d=3
            Fingerprint256::new(0, 0b0001, 0, 0),       // idx 3, d=1 (tie)
            Fingerprint256::new(0, 0b0011, 0, 0),       // idx 4, d=2 (tie)
            Fingerprint256::new(0b1111, 0, 0, 0),       // idx 5, d=4
            Fingerprint256::new(0, 0, 0b0001, 0),       // idx 6, d=1 (tie)
            Fingerprint256::new(0, 0, 0b0011, 0),       // idx 7, d=2 (tie)
        ];

        let top = kernel.hamming_top_k(&probe, &candidates, 5);
        assert_eq!(top.len(), 5);
        assert_eq!(top[0], (0, 1));
        assert_eq!(top[1], (3, 1));
        assert_eq!(top[2], (6, 1));
        assert_eq!(top[3], (1, 2));
        assert_eq!(top[4], (4, 2));
    }

    #[test]
    fn hamming_top_k_equals_full_sort_prefix() {
        // Deterministic xorshift PRNG (no deps).
        let mut state: u64 = 0xCAFE_BABE_DEAD_BEEF;
        let mut next = || -> u64 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };

        let kernel = ScalarKernel::new();
        let candidates: Vec<Fingerprint256> = (0..200).map(|_| {
            Fingerprint256::new(next(), next(), next(), next())
        }).collect();
        let probe = Fingerprint256::new(0x123, 0x456, 0x789, 0xABC);

        let via_heap = kernel.hamming_top_k(&probe, &candidates, 13);

        let mut scored: Vec<(usize, u32)> = candidates.iter().enumerate()
            .map(|(idx, fp)| (idx, kernel.hamming_distance_256(&probe, fp)))
            .collect();
        scored.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));
        let via_full_sort: Vec<(usize, u32)> = scored.into_iter().take(13).collect();

        assert_eq!(via_heap, via_full_sort, "heap diverged from full-sort prefix");
    }

    #[test]
    fn hamming_top_k_k_zero_returns_empty() {
        let kernel = ScalarKernel::new();
        let probe = Fingerprint256::ZERO;
        let candidates = vec![Fingerprint256::new(1, 2, 3, 4)];
        let top = kernel.hamming_top_k(&probe, &candidates, 0);
        assert!(top.is_empty());
    }

    #[test]
    fn hamming_top_k_k_larger_than_candidates_returns_all() {
        let kernel = ScalarKernel::new();
        let probe = Fingerprint256::ZERO;
        let candidates = vec![
            Fingerprint256::new(1, 0, 0, 0),
            Fingerprint256::new(0, 0, 0, 1),
        ];
        let top = kernel.hamming_top_k(&probe, &candidates, 10);
        assert_eq!(top.len(), 2);
    }

}
