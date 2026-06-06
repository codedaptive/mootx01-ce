// src/harness/kernel_registry.rs
//
// Enumeration of every kernel actually available on this build.
// The `--all` mode of stress-test iterates this list. New
// candidate kernels register themselves here so they pick up
// the full benchmark sweep automatically.
//
// A kernel is "available" if it was compiled in. SimdKernel is
// behind the `simd-nightly` Cargo feature, so it only appears
// when that feature is enabled. Apple-specific kernels (BNNS,
// Metal) are Swift-only and never appear on the Rust side
// (Rust exists for non-Apple ports per project policy).

use substrate_kernel::kernel::KernelKind;

/// Ordered list of kernel kinds available on this build. The
/// order is stable across runs so JSON output is reproducible.
pub fn available() -> Vec<KernelKind> {
    let mut out = vec![KernelKind::Scalar];

    // SimdKernel is gated on the simd-nightly feature in
    // geniuslocus-reference. The harness re-exports the
    // feature via its own simd-nightly feature flag (see
    // test-harness/rust/Cargo.toml).
    #[cfg(feature = "simd-nightly")]
    {
        out.push(KernelKind::Simd);
    }

    out
}

/// Filename-safe name for a kernel, suitable for embedding in
/// JSON output and benchmark file paths.
pub fn name(kind: KernelKind) -> &'static str {
    kind.as_str()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalar_always_available() {
        let kernels = available();
        assert!(kernels.contains(&KernelKind::Scalar),
                "ScalarKernel is the reference and must always be in the registry");
    }

    #[cfg(feature = "simd-nightly")]
    #[test]
    fn simd_available_with_feature() {
        let kernels = available();
        assert!(kernels.contains(&KernelKind::Simd),
                "with simd-nightly enabled, SimdKernel must be in the registry");
    }

    #[cfg(not(feature = "simd-nightly"))]
    #[test]
    fn simd_absent_without_feature() {
        let kernels = available();
        assert!(!kernels.contains(&KernelKind::Simd),
                "without simd-nightly, SimdKernel must NOT be in the registry");
    }
}
