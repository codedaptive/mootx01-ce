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
// Directed-graph convention (design council decision, 2026-06-04):
//
//   The implementation computes AUTHORITY CENTRALITY via A^T @ x:
//
//       x_{k+1} = A^T @ x_k / ||A^T @ x_k||_2
//
//   where adjacency[i] lists edges OUT OF node i.  Expanding the
//   inner loop: `x_next[j] += w * x[i]` for edge i→j accumulates
//   at j the weighted influence of all nodes that POINT TO j.  A
//   node scores highly when it is pointed to by many high-scoring
//   nodes — the authority interpretation.
//
//   This is the correct semantic for cognitive-recall keystones:
//   a row is "central" when many other rows reference it (e.g.
//   via association edges), not when it references many others.
//   The design council confirmed this on 2026-06-04 and locked the
//   directed-graph conformance vector in MX-Tidy to prevent future
//   drift back to hub semantics.
//
//   For undirected graphs, A = A^T so the distinction is immaterial;
//   symmetrize the adjacency before calling if undirected centrality
//   is needed (see the star-graph test in EigenvalueCentralityTests).
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
import IntellectusLib

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
    ///
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals.centralityScore` with value 1.0 (completion
    /// indicator), tagged by estate, node count, and iteration count
    /// to convergence. Off-path is a single atomic-bool load.
    ///
    /// - Parameters:
    ///   - adjacency: Sparse adjacency list.
    ///   - maxIterations: Power iteration cap.
    ///   - tolerance: Convergence tolerance (L2 diff norm).
    ///   - estate: Estate identifier for VizGraph telemetry. Callers with no
    ///             estate context must pass "" explicitly (no default — compiler
    ///             enforces the decision at every call site).
    ///   - ts: Caller-supplied epoch seconds for telemetry. Never read a clock
    ///         inside SubstrateML; the caller provides `ts`. Pass 0.0 explicitly
    ///         when no meaningful timestamp is available.
    public static func compute(
        adjacency: Adjacency,
        maxIterations: Int = defaultMaxIterations,
        tolerance: Double = defaultTolerance,
        estate: String,
        ts: Double
    ) -> [Double] {
        let shift: Double = 1.0
        let n = adjacency.count
        if n == 0 { return [] }

        // Initial vector: uniform 1/sqrt(n) so ||x_0||_2 = 1.
        let initial = 1.0 / Double(n).squareRoot()
        var x = [Double](repeating: initial, count: n)
        var xNext = [Double](repeating: 0.0, count: n)

        // Track iteration count to include in the VizGraph emit below.
        // The iteration count tells the Topology view how expensive this
        // run was (sparse well-connected graphs converge in ~10 iterations;
        // poorly-connected ones hit the maxIterations cap).
        var iterationsRun = 0

        for _ in 0..<maxIterations {
            iterationsRun += 1
            // x_next = A^T @ x  (xNext[j] += w * x[i] for edge i→j — authority, not hub)
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
                // Zero-norm: uniform fallback. Emit completion then return.
                let result = [Double](repeating: initial, count: n)
                emitCentrality(n: n, iterations: iterationsRun, estate: estate, ts: ts)
                return result
            }
            for i in 0..<n { xNext[i] /= norm }

            // Convergence check.
            var diffSq = 0.0
            for i in 0..<n {
                let d = xNext[i] - x[i]
                diffSq += d * d
            }
            if diffSq.squareRoot() < tolerance {
                // Converged within tolerance. Emit completion then return.
                emitCentrality(n: n, iterations: iterationsRun, estate: estate, ts: ts)
                return xNext
            }
            swap(&x, &xNext)
        }
        // Iteration budget exhausted without convergence. Emit and return
        // best estimate.
        emitCentrality(n: n, iterations: iterationsRun, estate: estate, ts: ts)
        return x
    }

    /// Emit the VizGraph `centrality.score` signal.
    ///
    /// Extracted so that all three return paths in `compute()` share
    /// one emit site. Off-path cost (monitoring disabled): single
    /// Atomic<Bool> load + branch — no allocation, no lock.
    ///
    /// - Parameters:
    ///   - n: Node count (graph size).
    ///   - iterations: Number of power-iteration steps that ran.
    ///   - estate: Caller-supplied estate identifier tag.
    ///   - ts: Caller-supplied epoch seconds.
    private static func emitCentrality(n: Int, iterations: Int,
                                        estate: String, ts: Double) {
        // VizGraph emit: centrality.score — power iteration complete.
        // Value 1.0 is a completion indicator (the per-node scores are
        // stored in the row_keystone_score column per cookbook § 11.11;
        // they cannot be serialised to a single scalar metric).
        Intellectus.report(.metric(
            name: VizGraphSignals.centralityScore,
            value: 1.0,
            tags: [
                "estate": estate,
                "node_count": "\(n)",
                "iterations_to_convergence": "\(iterations)",
            ],
            ts: ts
        ))
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
