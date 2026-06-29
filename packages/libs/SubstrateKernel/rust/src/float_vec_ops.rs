//! Scalar float-vector operations for the substrate kernel layer.
//!
//! These are the canonical IEEE-754 scalar implementations of L2 norm,
//! L2 normalisation, dot product, and cosine similarity. Every backend
//! that needs these operations MUST produce bit-identical output to this
//! scalar reference — no BLAS, no platform intrinsics; the scalar path
//! is the reference the conformance gate measures against.
//!
//! Placement rationale: "vector and similarity compute runs through the
//! substrate's kernel dispatch; the scalar kernel is the reference every
//! backend must match bit for bit." — GENIUSLOCUS_ARCHITECTURE_SPEC §4.
//! Float-vector ops belong in substrate-kernel alongside the PortableKernel
//! trait, HammingNN, and SimHash. Higher crates (corpus-kit-providers,
//! locuskit, geniuslocus-kit) consume these ops here — they MUST NOT
//! reimplement them inline.
//!
//! Swift port: packages/libs/SubstrateKernel/Sources/SubstrateKernel/FloatVecOps.swift
//!
//! ## Numeric contract (bit-identity specification)
//!
//! `l2_norm(v)`:
//!   normSq = 0.0f32; for x in v: normSq += x*x; return normSq.sqrt()
//!   — Single IEEE-754 add-then-accumulate loop; no fused operations.
//!
//! `l2_normalize(v)`:
//!   norm_sq = sum of x*x over v (same scalar loop as l2_norm but keeps
//!             the squared form to avoid two sqrt calls)
//!   if norm_sq <= 0: return v unchanged (zero-vector passthrough)
//!   inv_norm = 1.0 / norm_sq.sqrt()   — NOT recip() to match Swift exactly
//!   multiply each element by inv_norm in-place
//!
//!   The zero-vector contract: a zero input returns the zero vector
//!   unchanged. This is intentional — an all-zero context sum is an
//!   honest "no information" signal.
//!
//!   NOTE on .recip() vs 1.0/sqrt: The Swift implementation uses
//!   `1.0 / normSq.squareRoot()`. Rust's `.recip()` is defined as
//!   `1.0 / self`, so `norm_sq.sqrt().recip()` is algebraically identical
//!   to `1.0 / norm_sq.sqrt()`. However, IEEE-754 does not guarantee that
//!   `x.recip()` and `1.0 / x` produce the same bit pattern on all
//!   platforms. To guarantee bit-identity with Swift we use `1.0 / sqrt`
//!   explicitly here. The canonical test vectors verify this.
//!
//! `dot(a, b)`:
//!   sum = 0.0f32; for (x, y) in zip(a, b): sum += x*y; return sum
//!   Precondition: a.len() == b.len(). Caller is responsible.
//!
//! `cosine(a, b)`:
//!   Defined ONLY for L2-normalised inputs (norm ≈ 1.0). For unit
//!   vectors, cosine similarity equals the dot product.

// MARK: - Euclidean norm

/// Euclidean (L2) norm of a float slice.
///
/// Equivalent to `sqrt(sum(x*x for x in v))`.
///
/// Returns `0.0` for an empty input.
#[inline]
pub fn l2_norm(v: &[f32]) -> f32 {
    let mut norm_sq: f32 = 0.0;
    // Scalar loop: each element squared and accumulated.
    // Order of operations is fixed; matches Swift's `for x in v { normSq += x * x }`.
    for &x in v {
        norm_sq += x * x;
    }
    norm_sq.sqrt()
}

// MARK: - L2 normalisation

/// L2-normalise a float vector, returning a unit vector.
///
/// If the input has zero norm (all-zero vector), returns the
/// vector unchanged. This is the correct "no information" signal:
/// it projects to `Engram::ZERO` through `float_simhash::project`.
///
/// Bit-identity contract: the Swift port's `l2Normalize` in
/// `FloatVecOps.swift` MUST produce identical bit patterns for
/// identical IEEE-754 inputs. The operation sequence is:
///   1. Accumulate sum of squares (scalar loop).
///   2. Guard: if norm_sq <= 0, return v unchanged.
///   3. Compute `inv_norm = 1.0 / norm_sq.sqrt()`  (NOT .recip()).
///   4. Multiply each element by `inv_norm` in place.
///
/// - The `1.0 / sqrt` form is used (not `.recip()`) to guarantee
///   bit-identity with the Swift `1.0 / normSq.squareRoot()` path.
#[inline]
pub fn l2_normalize(mut v: Vec<f32>) -> Vec<f32> {
    let mut norm_sq: f32 = 0.0;
    // Step 1: sum of squares.
    for &x in &v {
        norm_sq += x * x;
    }
    // Step 2: zero-vector passthrough — honest no-context signal.
    if norm_sq <= 0.0 {
        return v;
    }
    // Step 3: reciprocal of the L2 norm.
    // Use `1.0 / sqrt` explicitly (not .recip()) to match the Swift
    // `1.0 / normSq.squareRoot()` bit pattern.
    let inv_norm: f32 = 1.0 / norm_sq.sqrt();
    // Step 4: scale each element in place.
    for x in &mut v {
        *x *= inv_norm;
    }
    v
}

// MARK: - Dot product

/// Dot product of two equal-length float slices.
///
/// Panics in both debug and release builds if the slices have
/// different lengths (`assert_eq!` is not debug-only). Callers must
/// ensure equal lengths.
///
/// Returns `sum(a[i] * b[i])` over all indices.
#[inline]
pub fn dot(a: &[f32], b: &[f32]) -> f32 {
    // PAR-R2: release-build safety — mismatched dimensions must panic
    // even in optimized builds (silent truncation via zip is worse).
    assert_eq!(a.len(), b.len(),
               "FloatVecOps::dot: dimension mismatch {} ≠ {}", a.len(), b.len());
    let mut sum: f32 = 0.0;
    // Scalar loop: element-wise product accumulated in order.
    for (&x, &y) in a.iter().zip(b.iter()) {
        sum += x * y;
    }
    sum
}

// MARK: - Cosine similarity (unit-vector inputs)

/// Cosine similarity between two L2-normalised float slices.
///
/// For unit vectors, cosine similarity equals the dot product.
/// Callers MUST normalise both inputs with `l2_normalize` before
/// calling this function.
///
/// Panics in debug builds when either input has a norm that deviates
/// from 1.0 by more than 1e-5, catching callers that forgot to
/// normalise. The check is compiled away in release builds.
///
/// Precondition: `a.len() == b.len()`.
///
/// Returns cosine similarity in `[-1.0, 1.0]`.
#[inline]
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    // PAR-R2: release-build safety — mismatched dimensions must panic.
    assert_eq!(a.len(), b.len(),
               "FloatVecOps::cosine: dimension mismatch {} ≠ {}", a.len(), b.len());
    // Debug-only norm check: catch un-normalised inputs early.
    debug_assert!({
        let norm_a: f32 = a.iter().map(|&x| x * x).sum::<f32>().sqrt();
        let norm_b: f32 = b.iter().map(|&x| x * x).sum::<f32>().sqrt();
        (a.is_empty() || (norm_a - 1.0).abs() < 1e-5) &&
        (b.is_empty() || (norm_b - 1.0).abs() < 1e-5)
    }, "FloatVecOps::cosine: inputs must be L2-normalised (call l2_normalize first)");
    // For unit vectors cosine sim = dot product. Reuse dot's loop.
    let mut sum: f32 = 0.0;
    for (&x, &y) in a.iter().zip(b.iter()) {
        sum += x * y;
    }
    sum
}

// MARK: - Unit tests

#[cfg(test)]
mod tests {
    use super::*;

    // Helper: check if two f32 values are within tolerance.
    fn approx_eq(a: f32, b: f32, tol: f32) -> bool {
        (a - b).abs() < tol
    }

    // ----- l2_norm -----

    #[test]
    fn l2_norm_of_zero_vector_is_zero() {
        let v = vec![0.0f32; 8];
        assert_eq!(l2_norm(&v), 0.0);
    }

    #[test]
    fn l2_norm_of_empty_is_zero() {
        assert_eq!(l2_norm(&[]), 0.0);
    }

    #[test]
    fn l2_norm_of_unit_basis_vector_is_one() {
        // [1, 0, 0, 0] → norm = 1.0
        let v = vec![1.0f32, 0.0, 0.0, 0.0];
        assert!(approx_eq(l2_norm(&v), 1.0, 1e-7));
    }

    #[test]
    fn l2_norm_known_value() {
        // [3, 4] → norm = 5
        let v = vec![3.0f32, 4.0f32];
        assert!(approx_eq(l2_norm(&v), 5.0, 1e-6));
    }

    // ----- l2_normalize -----

    #[test]
    fn l2_normalize_zero_vector_returns_unchanged() {
        // Zero-vector passthrough: the contract guarantees no panic and
        // a zero-vector output (which projects to Engram::ZERO through
        // float_simhash — the honest no-information signal).
        let v = vec![0.0f32; 4];
        let out = l2_normalize(v.clone());
        assert_eq!(out, v, "zero vector must be returned unchanged");
    }

    #[test]
    fn l2_normalize_produces_unit_vector() {
        let v = vec![3.0f32, 4.0f32, 0.0f32];
        let normed = l2_normalize(v);
        let norm_sq: f32 = normed.iter().map(|&x| x * x).sum();
        assert!(approx_eq(norm_sq.sqrt(), 1.0, 1e-6),
                "normalised vector must have unit norm; got norm={}", norm_sq.sqrt());
    }

    #[test]
    fn l2_normalize_already_unit_vector_unchanged() {
        // A vector that is already unit should stay unit after normalisation.
        let v = vec![1.0f32, 0.0, 0.0];
        let out = l2_normalize(v.clone());
        // The exact bits must match the expected 1.0 / 1.0 path.
        let norm: f32 = out.iter().map(|&x| x * x).sum::<f32>().sqrt();
        assert!(approx_eq(norm, 1.0, 1e-6));
    }

    #[test]
    fn l2_normalize_bit_pattern_matches_operation_order() {
        // Canonical test: verify the exact bit pattern for a known input.
        // Input: [1.0, 0.0, 0.0] — norm_sq = 1.0, inv_norm = 1.0/1.0 = 1.0.
        let v = vec![1.0f32, 0.0, 0.0];
        let out = l2_normalize(v);
        // inv_norm = 1.0 / sqrt(1.0) = 1.0; each element unchanged.
        assert_eq!(out[0].to_bits(), 1.0f32.to_bits());
        assert_eq!(out[1].to_bits(), 0.0f32.to_bits());
        assert_eq!(out[2].to_bits(), 0.0f32.to_bits());
    }

    #[test]
    fn l2_normalize_three_four_five_canonical() {
        // [3, 4] normalises to [0.6, 0.8] (exact in IEEE-754 via 1.0/5.0).
        let v = vec![3.0f32, 4.0f32];
        let out = l2_normalize(v);
        // norm_sq = 9 + 16 = 25; sqrt(25) = 5.0; inv_norm = 1.0/5.0 = 0.2
        // out[0] = 3.0 * 0.2 = 0.6, out[1] = 4.0 * 0.2 = 0.8
        assert!(approx_eq(out[0], 0.6, 1e-7), "expected 0.6 got {}", out[0]);
        assert!(approx_eq(out[1], 0.8, 1e-7), "expected 0.8 got {}", out[1]);
    }

    // ----- dot -----

    #[test]
    fn dot_of_unit_basis_vectors_is_zero() {
        let a = vec![1.0f32, 0.0, 0.0];
        let b = vec![0.0f32, 1.0, 0.0];
        assert_eq!(dot(&a, &b), 0.0);
    }

    #[test]
    fn dot_of_identical_unit_vector_is_one() {
        let a = vec![1.0f32, 0.0, 0.0];
        assert!(approx_eq(dot(&a, &a), 1.0, 1e-7));
    }

    #[test]
    fn dot_known_value() {
        let a = vec![1.0f32, 2.0, 3.0];
        let b = vec![4.0f32, 5.0, 6.0];
        // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
        assert!(approx_eq(dot(&a, &b), 32.0, 1e-6));
    }

    // ----- cosine -----

    #[test]
    fn cosine_of_identical_unit_vectors_is_one() {
        let v = vec![1.0f32, 0.0, 0.0];
        assert!(approx_eq(cosine(&v, &v), 1.0, 1e-7));
    }

    #[test]
    fn cosine_of_orthogonal_unit_vectors_is_zero() {
        let a = vec![1.0f32, 0.0];
        let b = vec![0.0f32, 1.0];
        assert_eq!(cosine(&a, &b), 0.0);
    }

    #[test]
    fn cosine_of_opposite_unit_vectors_is_neg_one() {
        let a = vec![1.0f32, 0.0];
        let b = vec![-1.0f32, 0.0];
        assert!(approx_eq(cosine(&a, &b), -1.0, 1e-7));
    }

    #[test]
    fn cosine_on_normalised_inputs_equals_dot() {
        // Verify that cosine and dot agree for normalised inputs.
        let raw_a = vec![3.0f32, 4.0, 0.0];
        let raw_b = vec![0.0f32, 4.0, 3.0];
        let a = l2_normalize(raw_a);
        let b = l2_normalize(raw_b);
        let c = cosine(&a, &b);
        let d = dot(&a, &b);
        assert!(approx_eq(c, d, 1e-7),
                "cosine and dot must agree for normalised inputs: cosine={c} dot={d}");
    }

    // PAR-R2: dimension mismatch must panic in release builds too.

    #[test]
    #[should_panic(expected = "dimension mismatch")]
    fn dot_panics_on_dimension_mismatch() {
        let a = vec![1.0f32, 2.0];
        let b = vec![1.0f32, 2.0, 3.0];
        dot(&a, &b);
    }

    #[test]
    #[should_panic(expected = "dimension mismatch")]
    fn cosine_panics_on_dimension_mismatch() {
        let a = l2_normalize(vec![1.0f32, 0.0]);
        let b = l2_normalize(vec![1.0f32, 0.0, 0.0]);
        cosine(&a, &b);
    }
}
