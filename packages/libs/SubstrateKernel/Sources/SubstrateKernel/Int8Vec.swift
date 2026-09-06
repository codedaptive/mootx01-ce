// Int8Vec.swift
//
// Symmetric per-vector int8 quantisation for encoder span vectors — the
// policy ratified by the Encoder Rerank Program (ENCODER_RERANK_CONTRACT §4,
// SYNAPSEKIT_SPEC § I-4a). Placed beside FloatVecOps because it is scalar
// float arithmetic every port must reproduce exactly: the quantised bytes
// are persisted (SynapseKit `vectors` rows, kind = 2) and compared across
// ports, so `q` and `scale` are bit-for-bit conformance-gated on the shared
// fixture packages/kits/SynapseKit/Tests/Fixtures/encoder/int8_vectors.json.
//
// Rust port: packages/libs/SubstrateKernel/rust/src/int8_vec.rs
//
// ## Numeric contract (bit-identity specification)
//
// quantize(v):                     v is an L2-normalised float32 vector
//   max   = max_i |v_i|            (exact: comparisons only)
//   scale = max / 127              (one IEEE-754 float32 division;
//                                   scale = 1 when max == 0, q all zero)
//   q_i   = clamp(round(v_i / scale), -127, 127)
//           round = half away from zero (`Float.rounded()` default rule,
//           Rust `f32::round`); the division is one float32 division.
//   Why 127 and not 128: symmetric range ±127 keeps -128 out of the
//   codebook so negation is closed and no value saturates asymmetrically.
//
// dequantize(q, scale):  v̂_i = Float(q_i) × scale   (one float32 multiply)
//
// dotQuery(u, q, scale):           u is an L2-normalised float32 query
//   acc = 0; for i: acc += u_i × Float(q_i)          (float32, in order,
//                                                     no fused multiply-add)
//   return acc × scale
//   The single multiply by `scale` after the loop is the contract: it is
//   both cheaper than scaling every term and the operation order the
//   fixture's `dot_query` values were produced with. No renormalisation:
//   the quantisation error is accepted by design (§4).
//
// Preconditions (caller bugs, checked with `precondition` like FloatVecOps):
//   dotQuery: u.count == q.count.

/// Symmetric per-vector int8 quantisation (ENCODER_RERANK_CONTRACT §4).
///
/// Pure functions over `[Float]` / `[Int8]`; IEEE-754 scalar arithmetic in
/// the order documented in the file header. Both ports match `q` and
/// `scale` bit for bit on the shared fixture and `dotQuery` within 1e-5.
public enum Int8Vec {

    /// Largest magnitude in the codebook. Symmetric ±127 (never -128).
    @usableFromInline
    static let maxMagnitude: Float = 127

    // MARK: - Quantise

    /// Quantise `v` to int8 with a per-vector scale.
    ///
    /// - Returns: `(q, scale)` with `q.count == v.count`. A zero vector
    ///   returns all zeros with `scale == 1` so `dequantize` and `dotQuery`
    ///   stay well defined without a division by zero.
    @inlinable
    public static func quantize(_ v: [Float]) -> (q: [Int8], scale: Float) {
        var maxAbs: Float = 0
        for x in v where abs(x) > maxAbs { maxAbs = abs(x) }
        // scale = max / 127; 1 when the vector is all zeros (nothing to scale).
        let scale: Float = maxAbs > 0 ? maxAbs / maxMagnitude : 1
        var q = [Int8]()
        q.reserveCapacity(v.count)
        for x in v {
            // One float32 division, round half away from zero, clamp. The
            // clamp only matters for the float32 rounding tail of x/scale at
            // the maximum element (which can land a hair above 127).
            let r = (x / scale).rounded()
            let clamped = min(max(r, -maxMagnitude), maxMagnitude)
            q.append(Int8(clamped))
        }
        return (q, scale)
    }

    // MARK: - Dequantise

    /// Reconstruct the approximate float32 vector: `q_i × scale`.
    @inlinable
    public static func dequantize(_ q: [Int8], scale: Float) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(q.count)
        for qi in q { out.append(Float(qi) * scale) }
        return out
    }

    // MARK: - Similarity

    /// Similarity between a float32 query `u` (unit norm) and a stored
    /// quantised vector: `(Σ u_i × q_i) × scale`, the cosine up to the
    /// accepted quantisation error.
    ///
    /// - Precondition: `u.count == q.count`.
    @inlinable
    public static func dotQuery(_ u: [Float], q: [Int8], scale: Float) -> Float {
        precondition(u.count == q.count,
                     "Int8Vec.dotQuery: dimension mismatch (\(u.count) vs \(q.count))")
        var acc: Float = 0
        // Scalar loop in index order; no fused multiply-add, so the sum is
        // the same on every port that follows the header contract.
        for i in 0..<u.count { acc += u[i] * Float(q[i]) }
        return acc * scale
    }
}
