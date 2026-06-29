// avx512_hamming_conformance.rs
//
// Conformance tests for the DARK AVX-512 VPOPCNTQ Hamming-NN backend.
// See `kernel_avx512.rs` for the full algorithm description and the
// MatrixSprint gate-enable criteria (P11-VAL-015).
//
// Test structure
// ──────────────
// § Dispatcher tests (all platforms):
//   Verify that `PortableKernel::of_kind(KernelKind::Avx512)` returns
//   the correct kind, and that `for_current_platform()` never
//   auto-selects Avx512 (the path is DARK by design).
//
// § AVX-512 fast-path conformance (x86_64 only):
//   Call the AVX-512 backend explicitly via `of_kind(KernelKind::Avx512)`
//   and verify bit-identical output vs `ScalarKernel` on the canonical
//   seed 0xCAFEBABEDEADBEEF and a 256-candidate sweep.
//
//   On x86_64 hosts WITHOUT avx512f + avx512vpopcntdq: the test
//   returns early (passes vacuously) with a printed explanation.
//   These hosts exercise the scalar fallback path inside
//   `Avx512HammingKernel`, which is identical to `ScalarKernel`.
//
//   On aarch64 (this Mac): the `#[cfg(target_arch = "x86_64")]`
//   gate means the AVX-512 intrinsic tests do not compile at all.
//   Only the dispatcher tests (which run on all platforms) are present.
//
// Swift counterpart: NONE. This backend is Rust/x86_64 only.
// Swift targets Apple Silicon (Metal + NEON); no Swift AVX-512 path
// exists or is planned (platform waiver — see `KernelKind` doc comment
// in `kernel.rs`).

use substrate_kernel::{KernelKind, PortableKernel};
use substrate_types::fingerprint256::Fingerprint256;

// ── § Dispatcher tests — run on all platforms ───────────────────────

/// `PortableKernel::for_current_platform()` must never auto-select
/// `KernelKind::Avx512`. The AVX-512 path is DARK: present and correct
/// but not live until MatrixSprint validates it on real hardware.
#[test]
fn for_current_platform_never_selects_avx512() {
    let k = PortableKernel::for_current_platform();
    assert_ne!(k.kind(), KernelKind::Avx512,
        "for_current_platform() must not auto-select Avx512 — the path \
         is DARK pending MatrixSprint perf validation (P11-VAL-015). \
         Scalar remains the live oracle. Got: {:?}", k.kind());
}

/// `PortableKernel::of_kind(KernelKind::Avx512)` is the explicit
/// override entry point. On x86_64 it returns `Avx512HammingKernel`
/// (kind = Avx512). On non-x86_64 it falls through to scalar (no
/// AVX-512 on those platforms — not a bug, by design).
#[test]
fn of_kind_avx512_reports_correct_kind_for_platform() {
    let k = PortableKernel::of_kind(KernelKind::Avx512);
    #[cfg(target_arch = "x86_64")]
    assert_eq!(k.kind(), KernelKind::Avx512,
        "on x86_64, of_kind(Avx512) must return Avx512HammingKernel \
         (kind = Avx512), not fall through to scalar; got {:?}", k.kind());
    #[cfg(not(target_arch = "x86_64"))]
    assert_eq!(k.kind(), KernelKind::Scalar,
        "on non-x86_64, of_kind(Avx512) must fall through to ScalarKernel \
         (no AVX-512 on this platform); got {:?}", k.kind());
}

/// `of_kind(Avx512)` must produce output bit-identical to `ScalarKernel`
/// regardless of whether VPOPCNTDQ is available on the current CPU.
/// On non-x86_64: always uses scalar path (same result by definition).
/// On x86_64 without VPOPCNTDQ: `Avx512HammingKernel` uses its
/// scalar fallback (also bit-identical).
/// On x86_64 with VPOPCNTDQ: exercises the VPOPCNTQ path — checked
/// by the `avx512_vpopcntdq_conformance_on_canonical_vectors` test below.
#[test]
fn of_kind_avx512_produces_scalar_identical_output() {
    let scalar   = PortableKernel::of_kind(KernelKind::Scalar);
    let avx_kind = PortableKernel::of_kind(KernelKind::Avx512);

    let probe = Fingerprint256::new(0xCAFEBABEDEADBEEF, 0x0123456789ABCDEF,
                                    0xFEDCBA9876543210, 0x1122334455667788);
    let candidates: Vec<Fingerprint256> = (0u64..16).map(|i| {
        Fingerprint256::new(
            i.wrapping_mul(0xCAFEBABEDEADBEEF),
            i.wrapping_mul(0x0123456789ABCDEF),
            i.wrapping_mul(0xFEDCBA9876543210),
            i.wrapping_mul(0x1122334455667788),
        )
    }).collect();

    let k = 5;
    let scalar_result = scalar.hamming_top_k(&probe, &candidates, k);
    let avx_result    = avx_kind.hamming_top_k(&probe, &candidates, k);

    assert_eq!(scalar_result, avx_result,
        "of_kind(Avx512).hamming_top_k diverged from ScalarKernel \
         on canonical vectors; scalar={:?} avx={:?}", scalar_result, avx_result);
}

/// CPUID guard proof — `of_kind(Avx512)` falls back to scalar on hosts
/// without AVX-512 and NEVER executes AVX-512 intrinsics.
///
/// This test runs on ALL platforms (aarch64 and x86_64). It constitutes
/// the runtime proof of the CPUID safety invariant documented in
/// `kernel_avx512.rs`:
///
/// - On aarch64: `kernel_avx512` is not compiled at all. `of_kind(Avx512)`
///   returns `ScalarKernel` directly (the `#[cfg(not(target_arch = "x86_64"))]`
///   arm). No AVX-512 code path exists on this platform.
///
/// - On x86_64 without avx512f + avx512vpopcntdq: `of_kind(Avx512)`
///   returns `Avx512HammingKernel`. Each method calls
///   `has_avx512_vpopcntdq()` and takes the scalar branch — AVX-512
///   intrinsics are never reached. If they were reached, the process
///   would SIGILL and this test would crash, not return an incorrect
///   value. Completing without a crash AND returning scalar-identical
///   output is the combined proof of both properties.
///
/// - On x86_64 WITH avx512vpopcntdq: the AVX-512 path DOES execute.
///   This case is also handled here — the output must still be
///   bit-identical to scalar (VPOPCNTQ is exact integer arithmetic).
///
/// Uses 20 candidates (2 full AVX-512 main-loop iterations of 8 + tail
/// of 4) to exercise both the vectorised path and the scalar tail.
/// The canonical seed 0xCAFEBABEDEADBEEF is used (per cookbook § 18.1).
#[test]
fn cpuid_guard_prevents_intrinsics_without_feature() {
    let scalar     = PortableKernel::of_kind(KernelKind::Scalar);
    let avx_kernel = PortableKernel::of_kind(KernelKind::Avx512);

    // 20 candidates: 2 main-loop groups (8 each) + 4-element tail,
    // exercising every branch in avx512_hamming_distance_batch.
    let mut state: u64 = 0xCAFEBABEDEADBEEF;
    let mut next = || -> u64 {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    let probe = Fingerprint256::new(next(), next(), next(), next());
    let candidates: Vec<Fingerprint256> = (0..20)
        .map(|_| Fingerprint256::new(next(), next(), next(), next()))
        .collect();

    // hamming_distance_batch: every distance must be scalar-identical.
    // If the CPUID guard were absent, the AVX-512 intrinsics would
    // run on unsupported hardware and SIGILL before this assertion.
    let mut scalar_out = vec![0u32; candidates.len()];
    let mut avx_out    = vec![0u32; candidates.len()];
    scalar.hamming_distance_batch(&probe, &candidates, &mut scalar_out);
    avx_kernel.hamming_distance_batch(&probe, &candidates, &mut avx_out);
    assert_eq!(scalar_out, avx_out,
        "of_kind(Avx512).hamming_distance_batch must return scalar-identical \
         results on this host — CPUID guard is active, no SIGILL occurred");

    // hamming_top_k: full ranked result must be scalar-identical.
    let k = 5;
    let scalar_topk = scalar.hamming_top_k(&probe, &candidates, k);
    let avx_topk    = avx_kernel.hamming_top_k(&probe, &candidates, k);
    assert_eq!(scalar_topk, avx_topk,
        "of_kind(Avx512).hamming_top_k must return scalar-identical results — \
         CPUID guard active, intrinsics only run when avx512vpopcntdq confirmed");
}

// ── § AVX-512 fast-path conformance — x86_64 only ───────────────────
//
// These tests call the AVX-512 VPOPCNTQ intrinsic path explicitly.
// They do not exist on aarch64 (the whole cfg block is absent).
// On x86_64 without VPOPCNTDQ, the tests return early (pass vacuously).

#[cfg(target_arch = "x86_64")]
mod avx512_x86_only {
    use super::*;
    use substrate_kernel::kernel_avx512::Avx512HammingKernel;
    use substrate_kernel::{KernelKind, PortableKernel};
    use substrate_kernel::kernel::ScalarKernel;
    use substrate_kernel::kernel::SubstrateKernel;

    /// Canonical-vector conformance for the AVX-512 VPOPCNTQ fast path.
    ///
    /// Uses the canonical seed 0xCAFEBABEDEADBEEF (the shared substrate
    /// seed for all conformance suites, per cookbook § 18.1) to generate
    /// 256 deterministic candidate fingerprints. Verifies that
    /// `Avx512HammingKernel::hamming_distance_batch` produces exactly the
    /// same distances as `ScalarKernel::hamming_distance_256` for every
    /// candidate, with no tolerance — the result must be bit-identical.
    ///
    /// 256 candidates: exercises 31 full AVX-512 main-loop iterations
    /// (31 × 8 = 248 candidates) plus an 8-element tail, hitting both
    /// the vectorized VPOPCNTQ path and the scalar tail fallback.
    ///
    /// On this host (aarch64): this test does not compile.
    /// On x86_64 without avx512f + avx512vpopcntdq: returns early,
    /// passes vacuously, prints a skip explanation.
    /// On x86_64 with avx512vpopcntdq: executes the full conformance check.
    #[test]
    fn avx512_vpopcntdq_conformance_on_canonical_vectors() {
        if !Avx512HammingKernel::has_avx512_vpopcntdq() {
            // The AVX-512 VPOPCNTDQ fast path is guarded by a runtime
            // feature check. On hosts without the extension (including
            // any x86_64 that lacks avx512vpopcntdq), the fast path is
            // never called. This is correct behaviour, not a skip of
            // the conformance requirement: the conformance requirement
            // is that the fast path is bit-identical WHEN it runs.
            // Gate-enable for general use is pending MatrixSprint perf
            // validation on real AVX-512 hardware (P11-VAL-015).
            println!("SKIP: avx512f + avx512vpopcntdq not detected on this host — \
                      VPOPCNTQ conformance gated on MatrixSprint hardware. \
                      Avx512HammingKernel falls back to scalar on this CPU.");
            return;
        }

        // Deterministic xorshift PRNG seeded with 0xCAFEBABEDEADBEEF.
        // No external deps; matches the seed used in kernel.rs conformance tests.
        let mut state: u64 = 0xCAFEBABEDEADBEEF;
        let mut next = || -> u64 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };

        let probe = Fingerprint256::new(next(), next(), next(), next());
        let candidates: Vec<Fingerprint256> = (0..256)
            .map(|_| Fingerprint256::new(next(), next(), next(), next()))
            .collect();

        let scalar  = ScalarKernel::new();
        let avx512  = Avx512HammingKernel::new();

        // Compute scalar reference distances.
        let scalar_distances: Vec<u32> = candidates.iter()
            .map(|c| scalar.hamming_distance_256(&probe, c))
            .collect();

        // Compute AVX-512 batch distances.
        let mut avx512_distances = vec![0u32; candidates.len()];
        avx512.hamming_distance_batch(&probe, &candidates, &mut avx512_distances);

        // Bit-identical check: every distance must match exactly.
        for (i, (&scalar_d, &avx_d)) in scalar_distances.iter()
            .zip(avx512_distances.iter())
            .enumerate()
        {
            assert_eq!(scalar_d, avx_d,
                "AVX-512 VPOPCNTQ diverged from scalar reference at \
                 candidate index {} (scalar={} avx512={})", i, scalar_d, avx_d);
        }

        // Verify top-K is also bit-identical (both phases).
        for k in [1usize, 5, 10, 50] {
            let scalar_topk  = scalar.hamming_top_k(&probe, &candidates, k);
            let avx512_topk  = avx512.hamming_top_k(&probe, &candidates, k);
            assert_eq!(scalar_topk, avx512_topk,
                "AVX-512 hamming_top_k diverged from scalar at k={}: \
                 scalar={:?} avx512={:?}", k, scalar_topk, avx512_topk);
        }
    }

    /// Verify that `of_kind(Avx512)` returns `KernelKind::Avx512`
    /// (not Scalar) on x86_64. This is the dispatcher-selection proof:
    /// the Avx512HammingKernel struct exists, is returned by the
    /// dispatcher, and reports its kind correctly.
    ///
    /// This does NOT mean the VPOPCNTQ fast path is active at runtime
    /// (that requires avx512vpopcntdq to be present). The kernel is
    /// present and the kind is wired; the live selection path
    /// (`for_current_platform`) still returns Scalar.
    #[test]
    fn of_kind_avx512_returns_avx512_kind_on_x86_64() {
        let k = PortableKernel::of_kind(KernelKind::Avx512);
        assert_eq!(k.kind(), KernelKind::Avx512,
            "on x86_64, of_kind(Avx512) must return Avx512HammingKernel \
             (kind=Avx512), proving the dark backend is wired; got {:?}", k.kind());
    }

    /// Single-pair conformance via the explicit `Avx512HammingKernel` struct.
    /// On hosts without VPOPCNTDQ: exercises the scalar fallback path
    /// inside the kernel (still bit-identical). Passes on all x86_64 hosts.
    #[test]
    fn avx512_single_pair_matches_scalar() {
        let scalar = ScalarKernel::new();
        let avx    = Avx512HammingKernel::new();
        let pairs = [
            // Canonical seed-derived pair
            (
                Fingerprint256::new(0xCAFEBABEDEADBEEF, 0x0123456789ABCDEF,
                                    0xFEDCBA9876543210, 0x1122334455667788),
                Fingerprint256::new(0x8877665544332211, 0xFEDCBA9876543210,
                                    0x0123456789ABCDEF, 0xCAFEBABEDEADBEEF),
            ),
            // All-ones vs all-zeros: distance must be 256
            (
                Fingerprint256::new(u64::MAX, u64::MAX, u64::MAX, u64::MAX),
                Fingerprint256::ZERO,
            ),
            // Identity: distance must be 0
            (Fingerprint256::ZERO, Fingerprint256::ZERO),
        ];
        for (a, b) in &pairs {
            assert_eq!(avx.hamming_distance_256(a, b),
                       scalar.hamming_distance_256(a, b),
                "Avx512HammingKernel::hamming_distance_256 diverged from \
                 scalar for pair ({:?}, {:?})", a, b);
        }
    }
}
