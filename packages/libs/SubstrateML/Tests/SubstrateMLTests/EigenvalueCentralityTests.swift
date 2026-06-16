// EigenvalueCentralityTests.swift
//
// Eigenvalue centrality (power iteration) per cookbook § 7.2.
// swift-testing peer suite for Sources/SubstrateML/EigenvalueCentrality.swift,
// mirroring rust/src/eigenvalue_centrality.rs (5 #[test]) case-for-case,
// with the Rust iteration counts and tolerances.
//
// Isolation strategy:
//   EigenvalueCentrality.compute() calls Intellectus.report() on every non-empty
//   graph. Tests that pass non-empty adjacency lists wrap their body in
//   GlobalTestLock.shared.withLock { } to prevent concurrent VizGraphSignalTests
//   from capturing stray samples and failing exact count assertions.
//   emptyGraphYieldsEmptyVector (n==0 early return) is exempt.

import Foundation
import Testing
@testable import SubstrateML

@Suite("EigenvalueCentrality")
struct EigenvalueCentralityTests {

    @Test("an empty graph yields an empty vector")
    func emptyGraphYieldsEmptyVector() {
        let result = EigenvalueCentrality.compute(adjacency: [], maxIterations: 100, tolerance: 1.0e-6)
        #expect(result.isEmpty)
    }

    @Test("an edgeless graph yields uniform centrality")
    func isolatedGraphYieldsUniformCentrality() async {
        // compute() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let adj: EigenvalueCentrality.Adjacency = Array(repeating: [], count: 5)
            let result = EigenvalueCentrality.compute(adjacency: adj, maxIterations: 100, tolerance: 1.0e-6)
            let expected = 1.0 / 5.0.squareRoot()
            for v in result { #expect(abs(v - expected) < 1e-9) }
        }
    }

    @Test("a star graph centers on its hub")
    func starGraphCentersOnHub() async {
        // compute() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let n = 5
            var adj: EigenvalueCentrality.Adjacency = Array(repeating: [], count: n)
            for leaf in 1..<n {
                adj[0].append((neighbor: leaf, weight: 1.0))
                adj[leaf].append((neighbor: 0, weight: 1.0))
            }
            let result = EigenvalueCentrality.compute(adjacency: adj, maxIterations: 200, tolerance: 1.0e-9)
            let hub = abs(result[0])
            for leaf in 1..<n { #expect(hub > abs(result[leaf])) }
            // All leaves equally central by symmetry.
            for i in 2..<n { #expect(abs(abs(result[i]) - abs(result[1])) < 1e-6) }
        }
    }

    @Test("the centrality vector is normalized to unit length")
    func normalizedToUnitLength() async {
        // compute() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // Triangle, symmetric.
            var adj: EigenvalueCentrality.Adjacency = Array(repeating: [], count: 3)
            adj[0].append((1, 1.0)); adj[1].append((0, 1.0))
            adj[1].append((2, 1.0)); adj[2].append((1, 1.0))
            adj[0].append((2, 1.0)); adj[2].append((0, 1.0))
            let result = EigenvalueCentrality.compute(adjacency: adj, maxIterations: 200, tolerance: 1.0e-9)
            let sumSq = result.reduce(0.0) { $0 + $1 * $1 }
            #expect(abs(sumSq - 1.0) < 1e-6)
        }
    }

    @Test("scaling every edge weight preserves the eigenvector direction")
    func weightScalingPreservesDirection() async {
        // compute() calls Intellectus.report() (two calls here) — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var adj: EigenvalueCentrality.Adjacency = Array(repeating: [], count: 4)
            adj[0].append((1, 1.0)); adj[1].append((2, 1.0))
            adj[2].append((3, 1.0)); adj[3].append((0, 1.0))
            let resultUnit = EigenvalueCentrality.compute(adjacency: adj, maxIterations: 300, tolerance: 1.0e-9)

            let adjScaled = adj.map { edges in edges.map { (neighbor: $0.neighbor, weight: $0.weight * 7.5) } }
            let resultScaled = EigenvalueCentrality.compute(adjacency: adjScaled, maxIterations: 300, tolerance: 1.0e-9)

            for i in 0..<4 { #expect(abs(abs(resultUnit[i]) - abs(resultScaled[i])) < 1e-6) }
        }
    }
}
