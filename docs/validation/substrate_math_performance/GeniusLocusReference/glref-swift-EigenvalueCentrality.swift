// EigenvalueCentrality.swift
//
// Eigenvalue centrality on the estate graph, per cookbook § 7.2.
//
// The estate graph is constructed on demand from the substrate's
// matrices and tables (cookbook § 7.1); this reference takes the
// adjacency as input rather than reconstructing it. The caller
// supplies a sparse adjacency list `(row_index, neighbors, weights)`
// over a fixed row enumeration.
//
// The centrality vector is the dominant eigenvector of the sparse
// adjacency matrix A, computed by power iteration:
//
//     x_{k+1} = A @ x_k / ||A @ x_k||_2
//
// converging to the principal eigenvector. The substrate uses the
// L2-normalized result so the scores are dimensionless and
// comparable across estate snapshots.
//
// Convergence: typical sparse graphs converge in 20-50 iterations
// to a relative error of 1e-6. The reference uses 100 iterations
// as a safety bound; cookbook § 7.2 budgets 1 second of compute
// per million-row estate.
//
// Used by:
//   - CognitionKit § 11.11 (recall_keystone) via cached
//     `row_keystone_score` (Float32) column on every row.
//   - The dreaming daemon's Rule 10 (daily refresh of keystone
//     scores).
//
// Cookbook references:
//   § 7.1   Estate graph definition
//   § 7.2   Eigenvalue centrality
//   § 11.11 recall_keystone primitive
//   § 15.1  Dreaming daemon Rule 10

import Foundation

public enum EigenvalueCentrality {

    /// Sparse adjacency representation: for row index i, list of
    /// (neighbor_index, edge_weight) pairs. The graph is treated
    /// as directed; callers wanting undirected centrality should
    /// symmetrize the adjacency before calling.
    public typealias Adjacency = [[(neighbor: Int, weight: Double)]]

    public static let defaultMaxIterations: Int = 100
    public static let defaultTolerance: Double = 1.0e-6

    /// Power iteration on the supplied sparse adjacency.
    /// Returns the L2-normalized principal eigenvector as a
    /// Double array indexed by row.
    ///
    /// Implementation detail: a small Perron shift
    /// (`xNext += SHIFT * x`) is applied each iteration. This
    /// shifts every eigenvalue by `SHIFT` without changing the
    /// eigenvectors, breaking the +/- lambda oscillation that
    /// bipartite graphs (e.g. a star) exhibit under raw power
    /// iteration. Mirrors the Rust port's shift constant.
    public static func compute(
        adjacency: Adjacency,
        maxIterations: Int = defaultMaxIterations,
        tolerance: Double = defaultTolerance
    ) -> [Double] {
        let shift: Double = 1.0
        let n = adjacency.count
        if n == 0 { return [] }

        // Initial vector: uniform 1/sqrt(n) so ||x_0||_2 = 1.
        let initial = 1.0 / Double(n).squareRoot()
        var x = [Double](repeating: initial, count: n)
        var xNext = [Double](repeating: 0.0, count: n)

        for _ in 0..<maxIterations {
            // x_next = A @ x
            for i in 0..<n {
                xNext[i] = 0.0
            }
            for i in 0..<n {
                for (j, w) in adjacency[i] {
                    xNext[j] += w * x[i]
                }
            }
            // Perron shift: y = A*x + shift*x. Same eigenvectors,
            // eigenvalues shifted by `shift`, breaks +/- oscillation.
            for i in 0..<n {
                xNext[i] += shift * x[i]
            }
            // Normalize.
            var sumSq = 0.0
            for v in xNext { sumSq += v * v }
            let norm = sumSq.squareRoot()
            if norm < 1.0e-30 {
                return [Double](repeating: initial, count: n)
            }
            for i in 0..<n { xNext[i] /= norm }

            // Convergence check.
            var diffSq = 0.0
            for i in 0..<n {
                let d = xNext[i] - x[i]
                diffSq += d * d
            }
            if diffSq.squareRoot() < tolerance {
                return xNext
            }
            swap(&x, &xNext)
        }
        return x
    }
}

// MARK: - Properties
//
//   normalized:  ||compute(adj)||_2 = 1 modulo the convergence
//                tolerance.
//   invariant-under-self-loops: a self-loop at row i adds w to
//                A[i][i], which power-iterates as a scaling on x[i].
//   isolated-graph: a graph with no edges yields uniform 1/sqrt(n)
//                centrality (every row equally non-central).
//   monotone-in-weight: replacing every edge weight with c * w
//                scales the eigenvalue by c but leaves the
//                normalized eigenvector unchanged.
//
// MARK: - Cookbook references
//   § 7.1, § 7.2, § 11.11, § 15.1
