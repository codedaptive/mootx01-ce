// FloatVecOps.swift
//
// Scalar float-vector operations for the substrate kernel layer.
//
// These are the canonical IEEE-754 scalar implementations of L2 norm,
// L2 normalisation, dot product, and cosine similarity. Every backend
// that needs these operations MUST produce bit-identical output to this
// scalar reference — no Accelerate.framework, no BLAS, no platform
// intrinsics; the scalar path is the reference the conformance gate
// measures against.
//
// Placement rationale: "vector and similarity compute runs through the
// substrate's kernel dispatch; the scalar kernel is the reference every
// backend must match bit for bit." — GENIUSLOCUS_ARCHITECTURE_SPEC §4.
// Float-vector ops belong in SubstrateKernel alongside PortableKernel,
// HammingNN, and SimHash. Higher kits (CorpusKit, LocusKit, GeniusLocusKit)
// consume these ops through this module — they MUST NOT reimplement them
// inline.
//
// Rust port: packages/libs/SubstrateKernel/rust/src/float_vec_ops.rs
//
// The four-way conformance gate (Swift scalar, Swift Metal, Rust scalar,
// Rust BLAS/NEON) verifies bit-identical output against the canonical
// test vectors in docs/engineering/substrate_reference/test-harness/.
//
// ## Numeric contract (bit-identity specification)
//
// l2Norm(v):
//   sum = 0.0f; for x in v: sum = sum + x*x; return sqrt(sum)
//   — Single IEEE-754 add-then-accumulate loop; no fused operations.
//
// l2Normalize(v):
//   normSq = sum of x*x over v (same scalar loop as l2Norm but keeps
//            the squared form to avoid two sqrt calls)
//   if normSq <= 0: return v unchanged (zero-vector passthrough)
//   invNorm = 1.0 / sqrt(normSq)
//   return each element multiplied by invNorm
//
//   The zero-vector contract: a zero input returns the zero vector
//   unchanged, NOT a NaN or panic. This is intentional — an all-zero
//   context sum is an honest "no information" signal that projects to
//   Engram.zero through FloatSimHash.
//
// dot(a, b):
//   sum = 0.0f; for (x, y) in zip(a, b): sum = sum + x*y; return sum
//   Precondition: a.count == b.count. Caller is responsible.
//
// cosine(a, b):
//   Defined ONLY for L2-normalised inputs (norm ≈ 1.0). For unit
//   vectors, cosine similarity equals the dot product, so this is
//   identical to dot(a, b). Callers MUST normalise both vectors first.
//   The "unit vectors" precondition is not asserted in release builds;
//   Debug builds fire a precondition failure for inputs whose norm
//   deviates from 1.0 by more than 1e-5.

/// Scalar float-vector operations.
///
/// All methods are pure functions over `[Float]`. No state, no
/// allocation (except the output array in `l2Normalize`). All
/// operations are IEEE-754 scalar arithmetic — the reference every
/// backend must match bit for bit.
public enum FloatVecOps {

    // MARK: - Euclidean norm

    /// Euclidean (L2) norm of a float vector.
    ///
    /// Equivalent to `sqrt(sum(x*x for x in v))`.
    ///
    /// - Returns: `0.0` for an empty input.
    @inlinable
    public static func l2Norm(_ v: [Float]) -> Float {
        var normSq: Float = 0.0
        // Scalar loop: each element squared and accumulated.
        // Order of operations is fixed; no auto-vectorisation
        // reordering that could break bit-identity.
        for x in v { normSq += x * x }
        return normSq.squareRoot()
    }

    // MARK: - L2 normalisation

    /// L2-normalise a float vector, returning a unit vector.
    ///
    /// If the input has zero norm (all-zero vector), returns the
    /// zero vector unchanged. This is the correct "no information"
    /// signal: it projects to `Engram.zero` through `FloatSimHash`.
    ///
    /// Bit-identity contract: the Rust port's `l2_normalize` in
    /// `float_vec_ops.rs` MUST produce identical bit patterns for
    /// identical IEEE-754 inputs. The operation sequence is:
    ///   1. Accumulate sum of squares (scalar loop).
    ///   2. Guard on normSq <= 0 (zero-vector passthrough).
    ///   3. Compute `invNorm = 1.0 / sqrt(normSq)`.
    ///   4. Multiply each element by `invNorm`.
    ///
    /// - Returns: Unit vector, or the zero vector if `v` is all-zero.
    @inlinable
    public static func l2Normalize(_ v: [Float]) -> [Float] {
        var normSq: Float = 0.0
        // Step 1: sum of squares.
        for x in v { normSq += x * x }
        // Step 2: zero-vector passthrough — honest no-context signal.
        guard normSq > 0 else { return v }
        // Step 3: reciprocal of the L2 norm.
        let invNorm: Float = 1.0 / normSq.squareRoot()
        // Step 4: scale each element.
        return v.map { $0 * invNorm }
    }

    // MARK: - Dot product

    /// Dot product of two equal-length float vectors.
    ///
    /// Precondition: `a.count == b.count`. The precondition is
    /// enforced in Debug builds; Release builds will produce
    /// a truncated result if the lengths differ (the shorter
    /// vector's length is used via `zip`).
    ///
    /// - Returns: `sum(a[i] * b[i])` over all indices.
    @inlinable
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count,
                     "FloatVecOps.dot: dimension mismatch \(a.count) ≠ \(b.count)")
        var sum: Float = 0.0
        // Scalar loop: element-wise product accumulated in order.
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    // MARK: - Cosine similarity (unit-vector inputs)

    /// Cosine similarity between two L2-normalised float vectors.
    ///
    /// For unit vectors, cosine similarity equals the dot product.
    /// Callers MUST normalise both inputs with `l2Normalize` before
    /// calling this function.
    ///
    /// In Debug builds, a precondition fires when either input has a
    /// norm that deviates from 1.0 by more than 1e-5, catching callers
    /// that forgot to normalise. In Release builds the check is
    /// compiled away.
    ///
    /// Precondition: `a.count == b.count`.
    ///
    /// - Returns: Cosine similarity in `[-1.0, 1.0]`.
    @inlinable
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count,
                     "FloatVecOps.cosine: dimension mismatch \(a.count) ≠ \(b.count)")
        // Debug-only norm check: catch un-normalised inputs early.
        assert({
            let normA = a.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            let normB = b.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            return (a.isEmpty || abs(normA - 1.0) < 1e-5) &&
                   (b.isEmpty || abs(normB - 1.0) < 1e-5)
        }(), "FloatVecOps.cosine: inputs must be L2-normalised (call l2Normalize first)")
        // For unit vectors cosine sim = dot product. Reuse dot's loop.
        var sum: Float = 0.0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}
