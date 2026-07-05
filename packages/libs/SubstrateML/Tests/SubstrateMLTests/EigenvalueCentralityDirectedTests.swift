// EigenvalueCentralityDirectedTests.swift
//
// Directed-graph tests for EigenvalueCentrality, pinning the
// authority-centrality convention locked on 2026-06-04.
//
// Authority semantics: a node scores highly when many high-scoring
// nodes POINT TO it (A^T @ x), not when it points to many others
// (A @ x). On directed graphs these give different orderings; these
// tests confirm the implementation matches the authority convention.
//
// Conformance vector: eigenvalue_centrality_directed.json
//
// Isolation strategy:
//   EigenvalueCentrality.compute() calls Intellectus.report(). Every test
//   here wraps its body in GlobalTestLock.shared.withLock { } to prevent
//   concurrent VizGraphSignalTests from capturing stray samples.

import Testing
@testable import SubstrateML

@Suite("EigenvalueCentrality directed-graph authority semantics")
struct EigenvalueCentralityDirectedTests {

    // MARK: - Directed chain: authority flows opposite to edge direction

    /// In a directed chain 0 → 1 → 2 → 3, node 3 is pointed at by
    /// the whole chain's weight (authority builds at the tail), while
    /// node 0 is pointed at by nobody (authority is lowest at head).
    ///
    /// Hub semantics (A @ x) would reverse this: node 0 drives the
    /// whole chain and would score highest. Authority and hub orderings
    /// are mirror images on a directed chain.
    @Test("directed chain: authority accumulates at tail node")
    func directedChainAuthorityAtTail() async {
        // compute() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // 0 → 1 → 2 → 3 (unit weights)
            var adj = EigenvalueCentrality.Adjacency(repeating: [], count: 4)
            adj[0] = [(neighbor: 1, weight: 1.0)]
            adj[1] = [(neighbor: 2, weight: 1.0)]
            adj[2] = [(neighbor: 3, weight: 1.0)]
            // node 3 has no out-edges

            // estate/ts: explicit sentinels — tests have no estate context.
            let scores = EigenvalueCentrality.compute(adjacency: adj, maxIterations: 300, tolerance: 1e-9,
                                                      estate: "", ts: 0)
            #expect(scores.count == 4)

            // Authority: node 3 is pointed at by 2, which is pointed at
            // by 1, which is pointed at by 0 — highest authority at tail.
            // Node 0 has no incoming edges — lowest authority.
            #expect(scores[3] > scores[2])
            #expect(scores[2] > scores[1])
            #expect(scores[1] > scores[0])
        }
    }

    // MARK: - Asymmetric hub vs authority fixture

    /// A 4-node graph where the hub (high out-degree) and authority
    /// (high in-degree) nodes are distinct:
    ///
    ///   0 → 1, 0 → 2, 0 → 3   (node 0: hub — points to all others)
    ///   1 → 2, 3 → 2           (node 2: authority — pointed at by 1 and 3)
    ///
    /// Hub semantics (A @ x) ranks node 0 first (most out-edges).
    /// Authority semantics (A^T @ x) ranks node 2 first (most in-edges,
    /// from the highest-scoring sources after convergence).
    @Test("asymmetric graph: authority winner is high-in-degree node, not high-out-degree hub")
    func asymmetricHubVsAuthority() async {
        // compute() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var adj = EigenvalueCentrality.Adjacency(repeating: [], count: 4)
            // Node 0 is the hub (3 out-edges, 0 in-edges)
            adj[0] = [(neighbor: 1, weight: 1.0), (neighbor: 2, weight: 1.0), (neighbor: 3, weight: 1.0)]
            // Node 1 and 3 each point to node 2
            adj[1] = [(neighbor: 2, weight: 1.0)]
            adj[3] = [(neighbor: 2, weight: 1.0)]
            // Node 2 has no out-edges

            // estate/ts: explicit sentinels — tests have no estate context.
            let scores = EigenvalueCentrality.compute(adjacency: adj, maxIterations: 300, tolerance: 1e-9,
                                                      estate: "", ts: 0)
            #expect(scores.count == 4)

            // Node 2 receives edges from 0, 1, and 3 — highest in-degree.
            // Under authority semantics it must rank above node 0 (which
            // has zero in-edges and would win under hub semantics).
            #expect(scores[2] > scores[0],
                    "node 2 (max in-degree) must outrank node 0 (max out-degree) under authority semantics")
        }
    }

    // MARK: - Conformance vector anchor

    /// The directed conformance vector (eigenvalue_centrality_directed.json)
    /// records the asymmetric 4-node fixture's score ordering so the
    /// Swift and Rust ports agree. This test verifies the Swift port
    /// produces an ordering consistent with the vector.
    ///
    /// Vector pin: scores[2] > scores[0] (authority beats hub).
    /// Swift and Rust must agree on this ordering to within 1e-6.
    @Test("conformance vector ordering: authority node outranks hub node")
    func conformanceVectorOrdering() async {
        // compute() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var adj = EigenvalueCentrality.Adjacency(repeating: [], count: 4)
            adj[0] = [(neighbor: 1, weight: 1.0), (neighbor: 2, weight: 1.0), (neighbor: 3, weight: 1.0)]
            adj[1] = [(neighbor: 2, weight: 1.0)]
            adj[3] = [(neighbor: 2, weight: 1.0)]

            // estate/ts: explicit sentinels — tests have no estate context.
            let scores = EigenvalueCentrality.compute(adjacency: adj, maxIterations: 300, tolerance: 1e-9,
                                                      estate: "", ts: 0)

            // Authority ordering that both ports must agree on:
            //   scores[2] > scores[0]: the authority node beats the hub
            //   scores[2] > scores[1]: authority beats mid-chain
            //   scores[2] > scores[3]: authority beats the other in-edge source
            #expect(scores[2] > scores[0])
            #expect(scores[2] > scores[1])
            #expect(scores[2] > scores[3])
        }
    }
}
