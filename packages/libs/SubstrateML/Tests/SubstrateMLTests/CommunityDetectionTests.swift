// CommunityDetectionTests.swift
//
// Louvain community detection per cookbook § 7.3.
// swift-testing peer suite for Sources/SubstrateML/CommunityDetection.swift,
// mirroring rust/src/community_detection.rs case-for-case.
//
// Suite layout:
//   - phase-1 (`detect`) regression tests — unchanged behavior, untouched.
//   - shared conformance vectors V1–V5 for `detectFull` (full Louvain:
//     phase 1 + phase 2 aggregation + resolution parameter). The same
//     fixtures with the same expected canonical labels exist in the Rust
//     module tests; both legs must agree exactly.
//   - telemetry boundary tests: `detectFull` emits exactly ONE
//     community.assignment signal regardless of how many aggregation
//     levels run internally.
//
// Isolation strategy:
//   `detect` and `detectFull` both call Intellectus.report() when monitoring
//   is enabled. The VizGraphSignalTests suite installs a CapturingSink and
//   calls setEnabled(true), then asserts an exact sample count. If any
//   CommunityDetection test runs concurrently and calls detect/detectFull,
//   it emits a stray sample into VizGraph's sink, breaking the count == 1
//   assertion. Every test here that calls an emitting algorithm wraps its
//   body in `GlobalTestLock.shared.withLock { }` to prevent that race.
//   Tests that only call `canonicalize` or operate on empty/zero-weight
//   graphs (which return before the emit site) are exempt.

import Foundation
import Testing
@testable import SubstrateML
import IntellectusLib

/// Records every received StatSample. Thread-safe via NSLock.
/// File-local twin of the sink in VizGraphSignalsTests.swift (that one is
/// fileprivate and cannot be shared across test files).
private final class CommunitySink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock()
        _samples.append(sample)
        lock.unlock()
    }

    var samples: [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.count
    }
}

// Serialized because three telemetry tests install a CommunitySink into the
// Intellectus global singleton and check the sample count. Non-telemetry tests
// that call `detectFull` emit into whichever sink is installed at the time —
// if they run in parallel with a telemetry test their emission inflates the
// sink count and breaks the `count == 1` assertion. Serializing the suite
// prevents any two CommunityDetection tests from overlapping. Cross-suite
// parallelism with VizGraphSignalTests is mediated by GlobalTestLock: the
// telemetry tests acquire it before touching Intellectus.
@Suite("CommunityDetection", .serialized)
struct CommunityDetectionTests {

    /// Build a symmetric adjacency from (a, b, w) edges — mirrors
    /// the Rust `symmetric_edges` helper.
    private func symmetricEdges(_ n: Int, _ edges: [(Int, Int, Double)]) -> CommunityDetection.Adjacency {
        var adj: CommunityDetection.Adjacency = Array(repeating: [], count: n)
        for (a, b, w) in edges {
            adj[a].append((neighbor: b, weight: w))
            adj[b].append((neighbor: a, weight: w))
        }
        return adj
    }

    @Test("an empty graph yields an empty labeling")
    func emptyGraph() {
        // estate/ts: explicit sentinels — tests have no estate context.
        #expect(CommunityDetection.detect(adjacency: [], maxPasses: 10, estate: "", ts: 0).isEmpty)
    }

    @Test("a disconnected graph gives one community per node")
    func disconnectedGraphOneCommunityPerNode() {
        let adj: CommunityDetection.Adjacency = Array(repeating: [], count: 4)
        // estate/ts: explicit sentinels — tests have no estate context.
        #expect(CommunityDetection.detect(adjacency: adj, maxPasses: 10, estate: "", ts: 0) == [0, 1, 2, 3])
    }

    @Test("two cliques with a weak bridge split into two communities")
    func twoCliquesSplitIntoTwoCommunities() async {
        // detect() calls Intellectus.report() — hold GlobalTestLock so a concurrent
        // VizGraphSignalTests sink does not capture a stray sample.
        await GlobalTestLock.shared.withLock {
            let edges: [(Int, Int, Double)] = [
                (0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0),
                (3, 4, 1.0), (3, 5, 1.0), (4, 5, 1.0),
                (0, 3, 0.01),
            ]
            // estate/ts: explicit sentinels — tests have no estate context.
            let result = CommunityDetection.detect(adjacency: symmetricEdges(6, edges), maxPasses: 20,
                                                   estate: "", ts: 0)
            #expect(result[0] == result[1])
            #expect(result[1] == result[2])
            #expect(result[3] == result[4])
            #expect(result[4] == result[5])
            #expect(result[0] != result[3])
        }
    }

    @Test("canonical labels start at zero and stay in range")
    func canonicalLabelsStartAtZero() async {
        // detect() calls Intellectus.report() — hold GlobalTestLock so a concurrent
        // VizGraphSignalTests sink does not capture a stray sample.
        await GlobalTestLock.shared.withLock {
            let edges: [(Int, Int, Double)] = [(0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0)]
            // estate/ts: explicit sentinels — tests have no estate context.
            let result = CommunityDetection.detect(adjacency: symmetricEdges(3, edges), maxPasses: 20,
                                                   estate: "", ts: 0)
            #expect(result[0] == 0)
            let maxLabel = result.max() ?? 0
            #expect(maxLabel < result.count)
        }
    }

    @Test("canonicalize renumbers in order of first appearance")
    func canonicalizeRenumbersInOrder() {
        let labels = [17, 3, 17, 99, 3, 17]
        // 17 -> 0, 3 -> 1, 99 -> 2.
        #expect(CommunityDetection.canonicalize(labels) == [0, 1, 0, 2, 1, 0])
    }

    // MARK: - Shared conformance vectors V1–V5 (detectFull)
    //
    // Identical fixtures and expected canonical labels live in the Rust
    // module tests (rust/src/community_detection.rs). Expected labels were
    // hand-derived from the gain formula
    //     ΔQ(γ) = (k_{i,B} − k_{i,A})/m − γ·k_i·(σ_B − σ_A^excl + k_i)/(2m²)
    // at γ=0.05; the canonical assignments are the unique partition that
    // maximises generalized modularity for each fixture at that resolution.

    /// V1 fixture — the live-estate pathology this mission exists for:
    /// 4 tunnel-bonded pairs (w = 1.0), node 0 lattice-star-bonded to one
    /// member of each other pair (w = 0.2).
    private var v1StarOfPairs: CommunityDetection.Adjacency {
        symmetricEdges(8, [
            (0, 1, 1.0), (2, 3, 1.0), (4, 5, 1.0), (6, 7, 1.0),
            (0, 2, 0.2), (0, 4, 0.2), (0, 6, 0.2),
        ])
    }

    @Test("V1 star-of-pairs: phase 1 locks 4 pairs (the documented limitation)")
    func v1Phase1LocksPairs() async {
        // detect() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // estate/ts: explicit sentinels — tests have no estate context.
            let result = CommunityDetection.detect(adjacency: v1StarOfPairs, maxPasses: 20,
                                                   estate: "", ts: 0)
            #expect(result == [0, 0, 1, 1, 2, 2, 3, 3])
        }
    }

    @Test("V1 star-of-pairs: detectFull at resolution 1.0 confirms 4 pairs (the modularity optimum — no over-merge)")
    func v1DetectFullResolutionOneKeepsPairs() async {
        // detectFull() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // Q(4 pairs) = 0.618 is the global optimum at γ = 1.0; the condensed
            // first-merge gain is −0.206. Full Louvain must NOT differ from
            // phase 1 here — the cure for the pathology is resolution, not
            // aggregation alone.
            // estate/ts: explicit sentinels — tests have no estate context.
            let result = CommunityDetection.detectFull(
                adjacency: v1StarOfPairs, maxLevels: 10, maxPasses: 20, resolution: 1.0,
                estate: "", ts: 0)
            #expect(result == [0, 0, 1, 1, 2, 2, 3, 3])
        }
    }

    @Test("V1 star-of-pairs: detectFull at resolution 0.05 collapses to ONE community (the live-estate cure)")
    func v1DetectFullLowResolutionCollapses() async {
        // detectFull() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // γ = 0.05 is below the scale-invariant absorption bound
            // γ < w_lattice / k_pair = 0.2 / 2.2 ≈ 0.0909, so every pair
            // supernode merges into the star at level 1. Intermediate gain ties
            // among the symmetric pair supernodes are harmless: the terminal
            // state is the single community regardless of tie order.
            // estate/ts: explicit sentinels — tests have no estate context.
            let result = CommunityDetection.detectFull(
                adjacency: v1StarOfPairs, maxLevels: 10, maxPasses: 20, resolution: 0.05,
                estate: "", ts: 0)
            #expect(result == [0, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    /// V2 fixture — two 4-cliques joined by one weak bridge (0–4, w = 0.01).
    private var v2TwoCliquesBridge: CommunityDetection.Adjacency {
        symmetricEdges(8, [
            (0, 1, 1.0), (0, 2, 1.0), (0, 3, 1.0),
            (1, 2, 1.0), (1, 3, 1.0), (2, 3, 1.0),
            (4, 5, 1.0), (4, 6, 1.0), (4, 7, 1.0),
            (5, 6, 1.0), (5, 7, 1.0), (6, 7, 1.0),
            (0, 4, 0.01),
        ])
    }

    @Test("V2 two 4-cliques + bridge: both entries return 2 communities at resolution 1.0")
    func v2NoOverMergeAtResolutionOne() async {
        // detect() and detectFull() both call Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let expected = [0, 0, 0, 0, 1, 1, 1, 1]
            // estate/ts: explicit sentinels — tests have no estate context.
            #expect(CommunityDetection.detect(adjacency: v2TwoCliquesBridge, maxPasses: 20,
                                              estate: "", ts: 0) == expected)
            #expect(CommunityDetection.detectFull(
                adjacency: v2TwoCliquesBridge, maxLevels: 10, maxPasses: 20, resolution: 1.0,
                estate: "", ts: 0) == expected)
        }
    }

    @Test("V2 two 4-cliques + bridge: resolution 0.05 still does NOT merge continents")
    func v2NoOverMergeAtLowResolution() async {
        // detectFull() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // Continent-merge threshold is γ < 2m·w_bridge/(k·(σ+k)) ≈ 0.00083
            // for these cliques — orders of magnitude below 0.05. The low γ that
            // absorbs pair supernodes must not glue real continents together.
            // estate/ts: explicit sentinels — tests have no estate context.
            #expect(CommunityDetection.detectFull(
                adjacency: v2TwoCliquesBridge, maxLevels: 10, maxPasses: 20, resolution: 0.05,
                estate: "", ts: 0)
                == [0, 0, 0, 0, 1, 1, 1, 1])
        }
    }

    /// V3 fixture — two triangles + weak bridge: already optimal after
    /// phase 1, so the aggregation loop terminates on K == n at level 1.
    private var v3AlreadyOptimal: CommunityDetection.Adjacency {
        symmetricEdges(6, [
            (0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0),
            (3, 4, 1.0), (3, 5, 1.0), (4, 5, 1.0),
            (0, 3, 0.01),
        ])
    }

    @Test("V3 already-optimal partition: detectFull == detect (level-2 no-op)")
    func v3DetectFullMatchesDetectWhenOptimal() async {
        // detect() and detectFull() both call Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // estate/ts: explicit sentinels — tests have no estate context.
            let phase1 = CommunityDetection.detect(adjacency: v3AlreadyOptimal, maxPasses: 20,
                                                   estate: "", ts: 0)
            let full = CommunityDetection.detectFull(
                adjacency: v3AlreadyOptimal, maxLevels: 10, maxPasses: 20, resolution: 1.0,
                estate: "", ts: 0)
            #expect(phase1 == [0, 0, 0, 1, 1, 1])
            #expect(full == phase1)
        }
    }

    /// V4 fixture — triangle with an explicit self-loop on node 0
    /// (w = 0.5). The self-loop counts toward node 0's degree (k₀ = 2.5)
    /// but never toward k_{i,C}; the expected labels pin that math.
    private var v4SelfLoopTriangle: CommunityDetection.Adjacency {
        var adj = symmetricEdges(3, [(0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0)])
        adj[0].append((neighbor: 0, weight: 0.5))
        return adj
    }

    @Test("V4 self-loop graph: both entries total; degree math pinned by expected labels")
    func v4SelfLoopDegreeMath() async {
        // detect() and detectFull() both call Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // At γ = 1.0 every move gain is negative (k₀ = 2.5 inflates the
            // penalty), so all three nodes stay singletons; detectFull's level-0
            // K == n and the loop terminates without condensing.
            // estate/ts: explicit sentinels — tests have no estate context.
            #expect(CommunityDetection.detect(adjacency: v4SelfLoopTriangle, maxPasses: 20,
                                              estate: "", ts: 0) == [0, 1, 2])
            #expect(CommunityDetection.detectFull(
                adjacency: v4SelfLoopTriangle, maxLevels: 10, maxPasses: 20, resolution: 1.0,
                estate: "", ts: 0) == [0, 1, 2])
            // At γ = 0.05 the penalty shrinks and the triangle collapses; the
            // condensation path then carries the self-loop weight through.
            #expect(CommunityDetection.detectFull(
                adjacency: v4SelfLoopTriangle, maxLevels: 10, maxPasses: 20, resolution: 0.05,
                estate: "", ts: 0) == [0, 0, 0])
        }
    }

    @Test("V5 empty and singleton graphs are total")
    func v5EmptyAndSingleton() async {
        // The singleton-with-self-loop case has non-zero edge weight and reaches
        // the emit site in detectFull. Hold GlobalTestLock for the whole func so
        // all three sub-cases are covered (empty and zero-weight cases skip the
        // emit site but share the lock acquisition, which is cheap).
        await GlobalTestLock.shared.withLock {
            // estate/ts: explicit sentinels — tests have no estate context.
            #expect(CommunityDetection.detectFull(
                adjacency: [], maxLevels: 10, maxPasses: 10, resolution: 1.0,
                estate: "", ts: 0).isEmpty)
            // Singleton, no edges (zero total weight).
            #expect(CommunityDetection.detectFull(
                adjacency: [[]], maxLevels: 10, maxPasses: 10, resolution: 1.0,
                estate: "", ts: 0) == [0])
            // Singleton with a self-loop (non-zero weight, no candidate moves).
            #expect(CommunityDetection.detectFull(
                adjacency: [[(neighbor: 0, weight: 1.0)]], maxLevels: 10, maxPasses: 10, resolution: 1.0,
                estate: "", ts: 0) == [0])
        }
    }

    // MARK: - detectFull telemetry boundary

    @Test("detectFull emits exactly ONE community.assignment sample even across multiple levels")
    func detectFullEmitsOnce() async {
        await GlobalTestLock.shared.withLock {
            let sink = CommunitySink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            // γ = 0.05 on V1 runs level 0 plus at least one aggregation
            // level; the inner per-level cores must stay silent.
            let result = CommunityDetection.detectFull(
                adjacency: v1StarOfPairs, maxLevels: 10, maxPasses: 20,
                resolution: 0.05, estate: "full-estate", ts: 9.0)

            #expect(sink.count == 1,
                "detectFull must emit exactly one sample at the outer boundary")
            if case let .metric(name, value, tags, ts) = sink.samples.first {
                #expect(name == VizGraphSignals.communityAssignment)
                #expect(value == Double(Set(result).count))
                #expect(tags["estate"] == "full-estate")
                #expect(tags["node_count"] == "8")
                #expect(tags["community_count"] == "1")
                #expect(ts == 9.0)
            } else {
                Issue.record("expected .metric sample; got \(String(describing: sink.samples.first))")
            }

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("detectFull emits nothing when monitoring is disabled")
    func detectFullNoEmitWhenDisabled() async {
        await GlobalTestLock.shared.withLock {
            let sink = CommunitySink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            _ = CommunityDetection.detectFull(
                adjacency: v1StarOfPairs, maxLevels: 10, maxPasses: 20,
                resolution: 0.05, estate: "e", ts: 1.0)

            #expect(sink.count == 0,
                "detectFull must not emit when monitoring is disabled")

            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("detectFull result is identical regardless of monitoring state")
    func detectFullConformanceUnchangedByMonitoring() async {
        await GlobalTestLock.shared.withLock {
            Intellectus.setEnabled(false)
            let resultOff = CommunityDetection.detectFull(
                adjacency: v1StarOfPairs, maxLevels: 10, maxPasses: 20,
                resolution: 0.05, estate: "", ts: 0)

            let sink = CommunitySink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let resultOn = CommunityDetection.detectFull(
                adjacency: v1StarOfPairs, maxLevels: 10, maxPasses: 20,
                resolution: 0.05, estate: "", ts: 0)

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)

            #expect(resultOff == resultOn,
                "detectFull result must be bit-identical regardless of monitoring state")
        }
    }
}
