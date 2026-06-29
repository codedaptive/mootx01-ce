# SubstrateKernel — Changelog

## 2026-06-28 — Security: CPUID guard verification and explicit test coverage

**Branch:** `secfix/punt-kernel`
**Finding:** Security audit against the dark AVX-512 VPOPCNTQ Hamming-NN backend
shipped 2026-06-27. The concern: `kernel_avx512.rs` compiles and links on x86_64
and is reachable via `PortableKernel::of_kind(KernelKind::Avx512)`. Any path
invoking the `unsafe` AVX-512 intrinsics without a runtime CPUID check is
undefined behaviour (SIGILL) on CPUs without `avx512f` + `avx512vpopcntdq`.

**Verification — guard was present from the initial commit:**

The `Avx512HammingKernel` struct carries a dedicated runtime feature-check method:

```rust
pub fn has_avx512_vpopcntdq() -> bool {
    is_x86_feature_detected!("avx512f")
        && is_x86_feature_detected!("avx512vpopcntdq")
}
```

Both entry points into the unsafe intrinsics check this guard before the `unsafe`
call and fall back to scalar when the feature is absent:

- `hamming_distance_256` — line 326 of `kernel_avx512.rs`
- `hamming_distance_batch` — line 352 of `kernel_avx512.rs`
- `hamming_top_k` — delegates to `hamming_distance_batch` (already guarded)
- All other trait methods (`popcount64`, `or_reduce_256`, `simhash_block`) do not
  call AVX-512 intrinsics.

**Hardening applied in this commit:**

1. **`kernel_avx512.rs`** — Added "CPUID Safety Invariant" section to the module
   header explaining: (a) `#[target_feature]` is a compile-time emission directive
   only — it does not guard runtime execution; (b) `is_x86_feature_detected!` is the
   runtime precondition; (c) the invariant that no unsafe AVX-512 call may occur
   without a preceding positive `has_avx512_vpopcntdq()` check.

2. **`kernel.rs`** — Replaced the brief comment above `KernelKind::Avx512` in
   `PortableKernel::of_kind` with an explicit CPUID safety contract note explaining
   what the guard guarantees and why omitting it would be UB / SIGILL.

3. **`tests/avx512_hamming_conformance.rs`** — Added cross-platform test
   `cpuid_guard_prevents_intrinsics_without_feature`:
   - Runs on aarch64 and x86_64.
   - On aarch64: proves `of_kind(Avx512)` returns scalar (module absent).
   - On x86_64 without AVX-512: proves `of_kind(Avx512)` returns scalar-identical
     results without SIGILL (the combined proof of correct fallback AND absence of
     intrinsic execution — a SIGILL would crash the test before the assertion).
   - On x86_64 WITH AVX-512: proves the fast path is also bit-identical to scalar.
   - Exercises 20 candidates (2 × 8-element main-loop groups + 4-element tail).
   - Seed: 0xCAFEBABEDEADBEEF (canonical conformance seed, cookbook § 18.1).

**Dark-path posture unchanged:**

`PortableKernel::for_current_platform()` never selects `Avx512HammingKernel`.
Scalar remains the live oracle. Gate-enable requires MatrixSprint perf proof on real
AVX-512 VPOPCNTDQ hardware (P11-VAL-015).
