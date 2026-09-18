//! Symmetric per-vector int8 quantisation for encoder span vectors — the
//! policy ratified by the Encoder Rerank Program (ENCODER_RERANK_CONTRACT §4,
//! SYNAPSEKIT_SPEC § I-4a). Placed beside `float_vec_ops` because it is
//! scalar float arithmetic every port must reproduce exactly: the quantised
//! bytes are persisted (SynapseKit `vectors` rows, kind = 2) and compared
//! across ports, so `q` and `scale` are bit-for-bit conformance-gated on the
//! shared fixture
//! packages/kits/SynapseKit/Tests/Fixtures/encoder/int8_vectors.json.
//!
//! Swift port: packages/libs/SubstrateKernel/Sources/SubstrateKernel/Int8Vec.swift
//!
//! ## Numeric contract (bit-identity specification)
//!
//! `quantize(v)`:                  v is an L2-normalised f32 vector
//!   max   = max_i |v_i|           (exact: comparisons only)
//!   scale = max / 127             (one IEEE-754 f32 division;
//!                                  scale = 1 when max == 0, q all zero)
//!   q_i   = clamp(round(v_i / scale), -127, 127)
//!           round = half away from zero (`f32::round`, Swift
//!           `Float.rounded()`); the division is one f32 division.
//!   Why 127 and not 128: symmetric range ±127 keeps -128 out of the
//!   codebook so negation is closed and no value saturates asymmetrically.
//!
//! `dequantize(q, scale)`:  v̂_i = (q_i as f32) × scale   (one f32 multiply)
//!
//! `dot_query(u, q, scale)`:       u is an L2-normalised f32 query
//!   acc = 0; for i: acc += u_i × (q_i as f32)   (f32, in order, no FMA)
//!   return acc × scale
//!   The single multiply by `scale` after the loop is the contract: it is
//!   both cheaper than scaling every term and the operation order the
//!   fixture's `dot_query` values were produced with. No renormalisation:
//!   the quantisation error is accepted by design (§4).
//!
//! Preconditions (caller bugs, asserted like `float_vec_ops`):
//!   `dot_query`: `u.len() == q.len()`.

/// Largest magnitude in the codebook. Symmetric ±127 (never -128).
const MAX_MAGNITUDE: f32 = 127.0;

/// Quantise `v` to int8 with a per-vector scale.
///
/// Returns `(q, scale)` with `q.len() == v.len()`. A zero vector returns all
/// zeros with `scale == 1` so `dequantize` and `dot_query` stay well defined
/// without a division by zero. Mirrors Swift `Int8Vec.quantize`.
#[inline]
pub fn quantize(v: &[f32]) -> (Vec<i8>, f32) {
    let mut max_abs = 0.0f32;
    for &x in v {
        if x.abs() > max_abs {
            max_abs = x.abs();
        }
    }
    // scale = max / 127; 1 when the vector is all zeros (nothing to scale).
    let scale = if max_abs > 0.0 { max_abs / MAX_MAGNITUDE } else { 1.0 };
    let mut q = Vec::with_capacity(v.len());
    for &x in v {
        // One f32 division, round half away from zero, clamp. The clamp
        // only matters for the f32 rounding tail of x/scale at the maximum
        // element (which can land a hair above 127).
        let r = (x / scale).round();
        let clamped = r.max(-MAX_MAGNITUDE).min(MAX_MAGNITUDE);
        q.push(clamped as i8);
    }
    (q, scale)
}

/// Reconstruct the approximate f32 vector: `q_i × scale`. Mirrors Swift
/// `Int8Vec.dequantize`.
#[inline]
pub fn dequantize(q: &[i8], scale: f32) -> Vec<f32> {
    q.iter().map(|&qi| qi as f32 * scale).collect()
}

/// Similarity between an f32 query `u` (unit norm) and a stored quantised
/// vector: `(Σ u_i × q_i) × scale`, the cosine up to the accepted
/// quantisation error. Mirrors Swift `Int8Vec.dotQuery`.
///
/// Panics when `u.len() != q.len()` (a caller bug, like `float_vec_ops::dot`).
#[inline]
pub fn dot_query(u: &[f32], q: &[i8], scale: f32) -> f32 {
    assert_eq!(
        u.len(),
        q.len(),
        "int8_vec::dot_query: dimension mismatch ({} vs {})",
        u.len(),
        q.len()
    );
    let mut acc = 0.0f32;
    // Scalar loop in index order; no fused multiply-add, so the sum is the
    // same on every port that follows the module contract.
    for i in 0..u.len() {
        acc += u[i] * (q[i] as f32);
    }
    acc * scale
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_vector_quantises_to_zeros_with_unit_scale() {
        let (q, scale) = quantize(&[0.0; 8]);
        assert_eq!(q, vec![0i8; 8]);
        assert_eq!(scale, 1.0);
        assert_eq!(dot_query(&[0.25; 8], &q, scale), 0.0);
    }

    #[test]
    fn maximum_element_maps_to_plus_or_minus_127() {
        let (q, scale) = quantize(&[0.5, -1.0, 0.25, 0.0]);
        assert_eq!(scale, 1.0 / 127.0);
        assert_eq!(q, vec![64, -127, 32, 0]);
        // Failure mode pinned: half-to-even would give 63 for 0.5/(1/127) only
        // when the quotient is an exact tie; here the tie case is covered by
        // the shared fixture's edge vector, this pins the ±127 anchor.
        assert_eq!(dequantize(&q, scale)[1], -1.0);
    }

    #[test]
    fn exact_half_ties_round_away_from_zero() {
        // scale = 127·2^-8 / 127 = 2^-8 exactly, so every quotient below is
        // an exact f32 value: 127, 62.5, -62.5, 0.5, -0.5, 1.5, -2.5, 0.
        let step = 2f32.powi(-8);
        let v: Vec<f32> = [127.0, 62.5, -62.5, 0.5, -0.5, 1.5, -2.5, 0.0]
            .iter()
            .map(|m| m * step)
            .collect();
        let (q, scale) = quantize(&v);
        assert_eq!(scale, step);
        // Half-to-even would produce [127, 62, -62, 0, 0, 2, -2, 0].
        assert_eq!(q, vec![127, 63, -63, 1, -1, 2, -3, 0]);
    }

    #[test]
    fn dot_query_multiplies_by_scale_once_after_accumulating() {
        let u = [0.5f32, 0.5, 0.5, 0.5];
        let q = [10i8, -20, 30, -40];
        let scale = 0.01f32;
        // (5 - 10 + 15 - 20) × 0.01 = -0.1 in f32 arithmetic.
        let expected = ((0.5f32 * 10.0 + 0.5 * -20.0 + 0.5 * 30.0) + 0.5 * -40.0) * 0.01;
        assert_eq!(dot_query(&u, &q, scale), expected);
    }
}
