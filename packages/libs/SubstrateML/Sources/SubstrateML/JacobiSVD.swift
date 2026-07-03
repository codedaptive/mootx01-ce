// JacobiSVD.swift
//
// Deterministic one-sided Jacobi SVD for real matrices (m × n, m ≥ n).
// Part 1 of the ADR-010 Decision B LSA signal.
//
// ## Algorithm
//
// One-sided cyclic Jacobi SVD: iteratively orthogonalises the columns
// of a working copy of A by applying planar Jacobi rotations to pairs
// of columns (p, q) in the fixed cyclic order (0,1),(0,2),…,(n-2,n-1).
// The right singular vectors V accumulate the same rotations; after
// `sweeps` rounds the columns of the working matrix are approximately
// orthogonal and carry the left singular vectors (un-normalised).
//
// Reference: Golub & Van Loan "Matrix Computations" 4th ed., §8.6.2.
//
// ## Determinism contract (cross-port bit-identity)
//
// Bit-identical output in Swift (this file) and Rust (substrate-ml
// crate, svd.rs) is guaranteed by:
//
//   1. Fixed sweep count (no convergence criterion that depends on
//      float comparisons reaching a threshold at different iterations).
//   2. Fixed cyclic column-pair order: (0,1),(0,2),…,(n-2,n-1),
//      (1,2),(1,3),…  — same in both ports.
//   3. Identical scalar Float32 arithmetic — no platform SIMD, no FMA,
//      no Accelerate, no LAPACK on either port.
//   4. Jacobi rotation derived from α, β, γ in an identical expression
//      tree on both ports (see `jacobiCS` helper below).
//   5. Sign convention: for each left singular vector U[:,j], find the
//      component with the largest absolute value and force it positive.
//      Both ports compute argmax(|u_i|) then apply the same sign flip
//      to both U[:,j] and V[:,j] (singular values are always ≥ 0).
//
// ## Reuse of substrate primitives
//
// Column dot products and norms are computed with the same flat-storage
// loop order as NMFAlternatingLeastSquares, so no new substrate
// primitive is needed. Left singular vectors are normalized by dividing
// each entry by σ (not via FloatVecOps.l2Normalize).
//
// ## LSA position
//
// SVD lives here in SubstrateML (general math primitive), not in
// CorpusKit. CorpusKit's LsaProvider calls `JacobiSVD.decompose` to
// factorise the term-document matrix and holds no SVD arithmetic.
//
// ## Limitations
//
// Requires m ≥ n (tall or square input). Operates in Float32 for
// bit-identity with the Rust port (which also uses f32). The fixed
// sweep count (default 30) is more than sufficient for the small
// term-document matrices an on-device estate produces; large matrices
// (vocabulary size > ~500) should not call this on every query.
//
// ## Conformance vectors
//
// See Tests/SubstrateMLTests/JacobiSVDTests.swift for the canonical
// test matrix (pinned 4×3 input) whose expected singular values and
// vectors both ports assert bit-for-bit.

import Foundation
import SubstrateKernel

// MARK: - Result type

/// Result of a JacobiSVD decomposition: A ≈ U · diag(singularValues) · Vᵀ.
///
/// All three components are row-major Float32 arrays:
///   U: m × rank (left singular vectors)
///   singularValues: rank (non-increasing, all ≥ 0)
///   Vt: rank × n (rows are right singular vectors)
///   rank: k (requested truncation; ≤ min(m, n))
public struct SVDResult: Sendable {
    /// Left singular vectors, row-major m × rank.
    public let U: [[Float]]
    /// Singular values in non-increasing order (all ≥ 0).
    public let singularValues: [Float]
    /// Right singular vectors (Vᵀ), row-major rank × n.
    /// Row i of Vt is the i-th right singular vector.
    public let Vt: [[Float]]
    /// Requested truncation rank k.
    public let rank: Int

    public init(U: [[Float]], singularValues: [Float], Vt: [[Float]], rank: Int) {
        self.U = U
        self.singularValues = singularValues
        self.Vt = Vt
        self.rank = rank
    }
}

// MARK: - JacobiSVD

/// Deterministic one-sided Jacobi SVD for real matrices.
///
/// Computes the truncated SVD of A (m × n, m ≥ n) returning the top-k
/// singular triplets. Output is bit-identical to the Rust port
/// `substrate_ml::svd::JacobiSvd` given the same input and `sweeps`.
///
/// ## Usage example
///
/// ```swift
/// let A: [[Float]] = [[1, 2], [3, 4], [5, 6]]
/// let result = JacobiSVD.decompose(A: A, rank: 2)
/// // result.singularValues: [σ₀, σ₁] in non-increasing order
/// // result.U[i][j]: i-th row, j-th column of U (left singular vectors)
/// // result.Vt[j]: j-th row of Vᵀ (j-th right singular vector)
/// ```
public enum JacobiSVD {

    // MARK: - Public entry point

    /// Decompose A into U, Σ, Vᵀ via one-sided cyclic Jacobi SVD.
    ///
    /// - Parameters:
    ///   - A: Input matrix, m × n (row-major nested array), m ≥ n.
    ///   - rank: Number of singular triplets to return. Clamped to min(m, n).
    ///   - sweeps: Number of full cyclic sweeps over all column pairs.
    ///     Default 30 — sufficient for convergence on the small term-
    ///     document matrices an on-device estate produces.
    ///     MUST be identical between Swift and Rust calls when bit-identity
    ///     is required. The default of 30 is pinned in both ports.
    /// - Returns: SVDResult with the top-k singular triplets, singular values
    ///   in non-increasing order.
    ///
    /// - Precondition: A is non-empty, rectangular (all rows same length),
    ///   m ≥ n, rank ≥ 1.
    public static func decompose(
        A: [[Float]],
        rank: Int,
        sweeps: Int = 30
    ) -> SVDResult {
        let m = A.count
        precondition(m > 0, "JacobiSVD: A must have at least one row")
        let n = A[0].count
        precondition(n > 0, "JacobiSVD: A must have at least one column")
        precondition(m >= n, "JacobiSVD: requires m >= n (tall or square input); got m=\(m) n=\(n)")
        for i in 0..<m {
            precondition(A[i].count == n,
                "JacobiSVD: A is not rectangular: row 0 has \(n) cols but row \(i) has \(A[i].count)")
        }
        let k = max(1, min(rank, min(m, n)))
        precondition(sweeps >= 0, "JacobiSVD: sweeps must be >= 0")

        // Copy A into column-major flat storage for efficient column access.
        // col j occupies indices [j*m ..< j*m + m].
        // Using column-major because the algorithm repeatedly sweeps over
        // pairs of columns; column-major avoids strided access.
        var W = [Float](repeating: 0, count: m * n)  // column-major m×n
        for i in 0..<m {
            for j in 0..<n {
                W[j * m + i] = A[i][j]
            }
        }

        // V accumulates right-side rotations (n×n, column-major).
        // Initialised to identity.
        var V = [Float](repeating: 0, count: n * n)  // column-major n×n
        for j in 0..<n { V[j * n + j] = 1 }

        // Tolerance for declaring a pair already orthogonal.
        // Using Float32 machine epsilon × matrix scale.
        // Any pair whose off-diagonal cosine is below this threshold
        // contributes nothing — skip the rotation to avoid unnecessary
        // float ops that might diverge on edge cases.
        let eps: Float = 1e-9

        // One-sided TOURNAMENT Jacobi: fixed `sweeps` passes; each sweep walks
        // the round-robin tournament schedule (circle method) instead of the
        // old lexicographic (p, q) nest. Within a round every pair is COLUMN-
        // DISJOINT, so the round's rotations commute exactly — each reads and
        // writes only its own two columns of W and V — and can execute on any
        // number of threads with BIT-IDENTICAL output (thread-count-independent
        // determinism; serial == parallel). Rounds are barriers
        // (`concurrentPerform` returns only when every iteration finishes), so
        // round r+1 sees every rotation of round r. The schedule is a pure
        // integer function of n, twin-implemented in Rust
        // (`JacobiSvd::tournament_rounds`) and pinned by the shared schedule
        // hash — both ports rotate the same pairs in the same round order, so
        // cross-port bit-identity holds exactly as it did for the
        // lexicographic order.
        //
        // WHY: the lexicographic nest is inherently serial (consecutive pairs
        // share a column), so a 512-column reindex factorization pinned one
        // core for minutes while the retrain's other phases fanned out. The
        // tournament order runs up to n/2 rotations concurrently.
        //
        // PERF + SAFETY of the pointer access: unchanged from the previous
        // implementation — unsafe buffer pointers over W and V so the inner
        // loops vectorize; every index is statically derived from the buffer
        // dimensions (pBase/qBase ∈ {0,m,…,(n-1)m}, i ∈ 0..<m). The ALIASING
        // safety of the parallel fan-out is the schedule's column-
        // disjointness, unit-asserted in JacobiSVDTests.
        let rounds = tournamentRounds(n)
        let workers = ProcessInfo.processInfo.activeProcessorCount
        W.withUnsafeMutableBufferPointer { wBuf in
            V.withUnsafeMutableBufferPointer { vBuf in
                let mats = MatPtr(w: wBuf.baseAddress!, v: vBuf.baseAddress!)
                for _ in 0..<sweeps {
                    for round in rounds {
                        if workers <= 1 || round.count < 2 {
                            for pair in round {
                                rotatePair(mats, m: m, n: n, p: pair.p, q: pair.q, eps: eps)
                            }
                        } else {
                            // Chunk the round's disjoint pairs across the cores;
                            // concurrentPerform is a synchronous barrier.
                            let chunkCount = min(workers, round.count)
                            let per = (round.count + chunkCount - 1) / chunkCount
                            DispatchQueue.concurrentPerform(iterations: chunkCount) { ci in
                                let lo = ci * per
                                let hi = min(lo + per, round.count)
                                for idx in lo..<hi {
                                    let pair = round[idx]
                                    rotatePair(mats, m: m, n: n, p: pair.p, q: pair.q, eps: eps)
                                }
                            }
                        }
                    }
                }
            }
        }

        // After sweeps, the columns of W are approximately orthogonal.
        // Compute singular values σ_j = ||W[:,j]||.
        var sigmaAll = [Float](repeating: 0, count: n)
        for j in 0..<n {
            var norm2: Float = 0
            let jBase = j * m
            for i in 0..<m {
                let v = W[jBase + i]
                norm2 = norm2 + v * v
            }
            sigmaAll[j] = norm2.squareRoot()
        }

        // Sort singular values in non-increasing order; carry column
        // indices so we can extract U and V in sorted order.
        // Insertion sort (n is small — vocabulary rank ≤ 512).
        var order = Array(0..<n)
        for i in 1..<n {
            let key = sigmaAll[order[i]]
            let keyIdx = order[i]
            var j = i - 1
            while j >= 0 && sigmaAll[order[j]] < key {
                order[j + 1] = order[j]
                j -= 1
            }
            order[j + 1] = keyIdx
        }

        // Build U (m × k) and Vt (k × n) for the top k components.
        // Apply sign convention: for each left singular vector u (length m),
        // find the index with the largest |u_i| and force it positive.
        // Apply the same sign flip to the corresponding row of Vt so that
        // A ≈ U diag(Σ) Vt is preserved.
        var U = [[Float]](repeating: [Float](repeating: 0, count: k), count: m)
        var sigmaK = [Float](repeating: 0, count: k)
        var Vt = [[Float]](repeating: [Float](repeating: 0, count: n), count: k)

        for rankIdx in 0..<k {
            let colIdx = order[rankIdx]
            sigmaK[rankIdx] = sigmaAll[colIdx]

            // Left singular vector U[:,rankIdx] = W[:,colIdx] / σ.
            // Use FloatVecOps.l2Normalize via the kernel to get the
            // conformance-gated implementation.
            var colW = [Float](repeating: 0, count: m)
            let colBase = colIdx * m
            for i in 0..<m { colW[i] = W[colBase + i] }
            let sigma = sigmaAll[colIdx]
            let uCol: [Float]
            if sigma < eps {
                // Zero singular value: u is the zero vector.
                // (The basis choice is arbitrary; use the column as-is.)
                uCol = colW
            } else {
                // Divide by sigma (equivalent to l2Normalize on an
                // orthogonal column after Jacobi — sigma is its norm).
                var tmp = [Float](repeating: 0, count: m)
                for i in 0..<m { tmp[i] = colW[i] / sigma }
                uCol = tmp
            }

            // Sign convention: find argmax |u_i| and force it positive.
            // Both ports use the same argmax loop (ties broken by lowest
            // index — first maximum found wins because > not >=).
            var maxAbsVal: Float = 0
            var maxAbsIdx: Int = 0
            for i in 0..<m {
                let absVal = uCol[i] < 0 ? -uCol[i] : uCol[i]
                if absVal > maxAbsVal {
                    maxAbsVal = absVal
                    maxAbsIdx = i
                }
            }
            // Sign of the largest-magnitude component.
            let signFlip: Float = (uCol[maxAbsIdx] < 0) ? -1 : 1

            // Write U rows.
            for i in 0..<m {
                U[i][rankIdx] = uCol[i] * signFlip
            }

            // Right singular vector from V: V[:,colIdx] is the colIdx-th
            // column of V (n-length). Vt[rankIdx] = (V[:,colIdx])ᵀ · signFlip.
            let vColBase = colIdx * n
            for j in 0..<n {
                Vt[rankIdx][j] = V[vColBase + j] * signFlip
            }
        }

        return SVDResult(U: U, singularValues: sigmaK, Vt: Vt, rank: k)
    }

    // MARK: - Jacobi rotation helper


    // MARK: - Tournament schedule (the parallel-Jacobi contract)

    /// Round-robin tournament schedule for `n` columns (the classic circle
    /// method). Returns `t-1` rounds (t = n rounded up to even); each round is
    /// a set of COLUMN-DISJOINT (p, q) pairs with p < q, and across a full
    /// cycle every unordered pair appears EXACTLY once. Pure integer function
    /// of `n` — no floats, nothing that can drift — twin-implemented in Rust
    /// (`JacobiSvd::tournament_rounds`) and pinned by the shared schedule
    /// hash, so both ports walk the identical rotation order by construction.
    /// Pairs within a round are sorted (deterministic serial-order definition;
    /// execution order within a round is irrelevant — the pairs are disjoint).
    public static func tournamentRounds(_ n: Int) -> [[(p: Int, q: Int)]] {
        guard n >= 2 else { return [] }
        // Odd n: add a phantom "bye" column at index t-1; pairs touching it
        // are skipped, leaving that column idle for the round.
        let t = n % 2 == 0 ? n : n + 1
        let roundCount = t - 1
        let half = t / 2
        var out: [[(p: Int, q: Int)]] = []
        out.reserveCapacity(roundCount)
        for r in 0..<roundCount {
            var pairs: [(p: Int, q: Int)] = []
            pairs.reserveCapacity(half)
            for k in 0..<half {
                let a: Int
                let b: Int
                if k == 0 {
                    // The fixed pivot (t-1) plays the rotating index.
                    a = t - 1
                    b = r % (t - 1)
                } else {
                    a = (r + k) % (t - 1)
                    b = ((r + t - 1) - k) % (t - 1)
                }
                if a >= n || b >= n { continue }  // bye pair (odd n)
                pairs.append(a < b ? (a, b) : (b, a))
            }
            pairs.sort { $0.p != $1.p ? $0.p < $1.p : $0.q < $1.q }
            out.append(pairs)
        }
        return out
    }

    /// Raw pointers to the working matrices, passable into the per-round
    /// parallel closure. SAFETY INVARIANT: a round's pairs are column-disjoint
    /// (`tournamentRounds` construction, unit-asserted), and each
    /// `concurrentPerform` iteration owns a disjoint chunk of pairs — no two
    /// threads ever touch the same Float.
    private struct MatPtr: @unchecked Sendable {
        let w: UnsafeMutablePointer<Float>
        let v: UnsafeMutablePointer<Float>
    }

    /// One Jacobi rotation on columns (p, q) of W (m rows) and V (n rows) —
    /// byte-for-byte the arithmetic of the pre-tournament serial body (same
    /// accumulation order, same expression trees, same skip threshold).
    private static func rotatePair(_ mats: MatPtr, m: Int, n: Int, p: Int, q: Int, eps: Float) {
        let w = mats.w
        let v = mats.v
        // Compute inner products for columns p and q.
        // alpha = <W[:,p], W[:,p]>, beta = <W[:,q], W[:,q]>,
        // gamma = <W[:,p], W[:,q]>. Same loop nest order as NMF's matMulFlat
        // so cross-port accumulation order matches.
        var alpha: Float = 0
        var beta:  Float = 0
        var gamma: Float = 0
        let pBase = p * m
        let qBase = q * m
        for i in 0..<m {
            let wp = w[pBase + i]
            let wq = w[qBase + i]
            alpha = alpha + wp * wp
            beta  = beta  + wq * wq
            gamma = gamma + wp * wq
        }

        // Check orthogonality: skip if the pair is already orthogonal enough.
        let gammaAbs = gamma < 0 ? -gamma : gamma
        let threshold: Float = eps * (alpha < 0 ? -alpha : alpha).squareRoot() *
                                     (beta  < 0 ? -beta  : beta ).squareRoot()
        if gammaAbs <= threshold { return }

        let (c, s) = jacobiCS(alpha: alpha, beta: beta, gamma: gamma)

        // Apply the rotation to columns p and q of W.
        for i in 0..<m {
            let wp = w[pBase + i]
            let wq = w[qBase + i]
            w[pBase + i] = c * wp - s * wq
            w[qBase + i] = s * wp + c * wq
        }

        // Apply the same rotation to V.
        let vpBase = p * n
        let vqBase = q * n
        for j in 0..<n {
            let vp = v[vpBase + j]
            let vq = v[vqBase + j]
            v[vpBase + j] = c * vp - s * vq
            v[vqBase + j] = s * vp + c * vq
        }
    }

    /// Compute (c, s) for the Jacobi rotation that annihilates the
    /// off-diagonal entry of the 2×2 symmetric matrix
    ///   [[α, γ], [γ, β]].
    ///
    /// Formula (Golub & Van Loan §8.6.2, cross-port pinned):
    ///   ζ = (β − α) / (2 · γ)
    ///   t = sign(ζ) / (|ζ| + sqrt(1 + ζ²))    (t satisfies t² + 2ζt − 1 = 0)
    ///   c = 1 / sqrt(1 + t²)
    ///   s = c · t
    ///
    /// Both ports must compute this in EXACTLY this expression order
    /// so the Float32 rounding is bit-identical. Parenthesisation is
    /// explicit below; do NOT refactor.
    @inline(__always)
    static func jacobiCS(alpha: Float, beta: Float, gamma: Float) -> (c: Float, s: Float) {
        // zeta = (beta - alpha) / (2 * gamma)
        // Written as two separate ops (subtraction, then division) to
        // match Rust's identical expression: (beta - alpha) / (2.0 * gamma).
        let zeta: Float = (beta - alpha) / (2 * gamma)
        // t = sign(zeta) / (|zeta| + sqrt(1 + zeta^2))
        // sign(zeta): +1 if zeta >= 0, -1 otherwise (matching Rust's if >=0).
        let zetaAbs: Float = zeta < 0 ? -zeta : zeta
        let tDen: Float = zetaAbs + (1 + zeta * zeta).squareRoot()
        let t: Float = (zeta >= 0 ? 1 : -1) / tDen
        // c = 1 / sqrt(1 + t^2)
        let c: Float = 1 / (1 + t * t).squareRoot()
        let s: Float = c * t
        return (c, s)
    }
}
