// VizGraphSignalsTests.swift
//
// Tests for the VizGraph telemetry emit wired into SubstrateML's five
// graph-analytic algorithms. Mirrors the Rust test module in
// rust/tests/viz_graph_signals_tests.rs.
//
// Test structure per algorithm:
//   §1 Disabled gate: monitoring OFF → zero samples emitted; return
//      value is IDENTICAL to pre-signal implementation.
//   §2 Enabled gate: monitoring ON → exactly one sample with the
//      expected metric name, shape, and tags.
//   §3 Conformance: result value is unchanged by the emit.
//
// Isolation strategy:
//   All VizGraph test suites are wrapped in a `.serialized` parent suite
//   (VizGraphSignalTests). The `.serialized` trait instructs Swift Testing
//   to run all child tests sequentially, preventing concurrent access to
//   the Intellectus global singleton. This is the correct pattern for
//   any test suite that manipulates process-global state (Intellectus
//   enabled flag + installed sink). GlobalTestLock is retained as a
//   secondary guard for any tests that escape the `.serialized` parent.
//   See VectorKit's GlobalTestLock.swift for the canonical explanation.

import Foundation
import Testing
@testable import SubstrateML
import IntellectusLib

// MARK: - Helper: capturing sink

/// Records every received StatSample. Thread-safe via NSLock.
private final class CapturingSink: StatsSink, @unchecked Sendable {
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

// MARK: - VizGraph telemetry signal tests
//
// The `.serialized` trait on this parent suite ensures all five algorithm
// suites run sequentially. Swift Testing's parallel runner would otherwise
// interleave them, causing Intellectus singleton state from one test to
// bleed into another. GlobalTestLock provides an additional async barrier
// within each test body; both mechanisms are required.

@Suite("VizGraph signal tests", .serialized)
struct VizGraphSignalTests {

    // MARK: - §1 CommunityDetection

    @Suite("§1 VizGraph — CommunityDetection emit")
    struct CommunityDetectionEmitTests {

        /// A simple triangle graph (all three nodes connected) for deterministic
        /// community tests. Louvain phase 1 leaves all three in one community
        /// because merging any node into any other's community increases modularity.
        private static let triangleAdj: CommunityDetection.Adjacency = [
            [(neighbor: 1, weight: 1.0), (neighbor: 2, weight: 1.0)],
            [(neighbor: 0, weight: 1.0), (neighbor: 2, weight: 1.0)],
            [(neighbor: 0, weight: 1.0), (neighbor: 1, weight: 1.0)],
        ]

        @Test("no sample emitted when monitoring is disabled")
        func noSampleWhenDisabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)

                _ = CommunityDetection.detect(
                    adjacency: Self.triangleAdj, estate: "test-estate", ts: 1.0)

                #expect(sink.count == 0,
                    "CommunityDetection.detect must not emit when monitoring is disabled")

                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("one community.assignment sample emitted when monitoring is enabled")
        func oneSampleWhenEnabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                _ = CommunityDetection.detect(
                    adjacency: Self.triangleAdj, estate: "test-estate", ts: 1.0)

                #expect(sink.count == 1,
                    "CommunityDetection.detect must emit exactly one sample when monitoring is enabled")

                if case let .metric(name, value, tags, ts) = sink.samples.first {
                    #expect(name == VizGraphSignals.communityAssignment)
                    #expect(value >= 1.0, "community count must be at least 1")
                    #expect(tags["estate"] == "test-estate")
                    #expect(tags["node_count"] == "3")
                    #expect(tags["community_count"] != nil)
                    #expect(ts == 1.0)
                } else {
                    Issue.record("expected .metric sample; got \(String(describing: sink.samples.first))")
                }

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("detect result is identical regardless of monitoring state")
        func conformanceResultUnchangedByMonitoring() async {
            await GlobalTestLock.shared.withLock {
                // Compute result with monitoring off.
                Intellectus.setEnabled(false)
                let resultOff = CommunityDetection.detect(
                    adjacency: Self.triangleAdj, estate: "test", ts: 0)

                // Compute result with monitoring on.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let resultOn = CommunityDetection.detect(
                    adjacency: Self.triangleAdj, estate: "test", ts: 0)

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)

                // Both results must be bit-identical (monitoring is a pure
                // side-effect and must never alter the algorithm output).
                #expect(resultOff == resultOn,
                    "CommunityDetection result must be identical with monitoring on or off")
            }
        }

        @Test("empty graph emits no sample and returns empty")
        func emptyGraphNoSample() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                let result = CommunityDetection.detect(adjacency: [], estate: "e", ts: 0)

                // Empty input: the algorithm returns early before the emit.
                #expect(result.isEmpty)
                #expect(sink.count == 0,
                    "empty-graph early return must not emit a sample")

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }
    }

    // MARK: - §2 EigenvalueCentrality

    @Suite("§2 VizGraph — EigenvalueCentrality emit")
    struct EigenvalueCentralityEmitTests {

        /// Star graph: node 0 is the hub, nodes 1-3 point to 0.
        private static let starAdj: EigenvalueCentrality.Adjacency = [
            [(neighbor: 1, weight: 1.0), (neighbor: 2, weight: 1.0), (neighbor: 3, weight: 1.0)],
            [(neighbor: 0, weight: 1.0)],
            [(neighbor: 0, weight: 1.0)],
            [(neighbor: 0, weight: 1.0)],
        ]

        @Test("no sample emitted when monitoring is disabled")
        func noSampleWhenDisabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)

                _ = EigenvalueCentrality.compute(adjacency: Self.starAdj, estate: "e", ts: 2.0)

                #expect(sink.count == 0,
                    "EigenvalueCentrality.compute must not emit when monitoring is disabled")

                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("one centrality.score sample emitted when monitoring is enabled")
        func oneSampleWhenEnabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                _ = EigenvalueCentrality.compute(adjacency: Self.starAdj, estate: "my-estate", ts: 2.0)

                #expect(sink.count == 1,
                    "EigenvalueCentrality.compute must emit exactly one sample when enabled")

                if case let .metric(name, value, tags, ts) = sink.samples.first {
                    #expect(name == VizGraphSignals.centralityScore)
                    #expect(value == 1.0, "completion indicator must be 1.0")
                    #expect(tags["estate"] == "my-estate")
                    #expect(tags["node_count"] == "4")
                    #expect(tags["iterations_to_convergence"] != nil)
                    #expect(ts == 2.0)
                } else {
                    Issue.record("expected .metric sample")
                }

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("compute result is identical regardless of monitoring state")
        func conformanceResultUnchangedByMonitoring() async {
            await GlobalTestLock.shared.withLock {
                Intellectus.setEnabled(false)
                let resultOff = EigenvalueCentrality.compute(
                    adjacency: Self.starAdj, estate: "", ts: 0)

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let resultOn = EigenvalueCentrality.compute(
                    adjacency: Self.starAdj, estate: "", ts: 0)

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)

                guard resultOff.count == resultOn.count else {
                    Issue.record("result lengths differ: \(resultOff.count) vs \(resultOn.count)")
                    return
                }
                for (a, b) in zip(resultOff, resultOn) {
                    #expect(a == b, "centrality scores must be bit-identical")
                }
            }
        }
    }

    // MARK: - §3 NMF

    @Suite("§3 VizGraph — NMF emit")
    struct NMFEmitTests {

        // Small 3×4 non-negative matrix for deterministic tests.
        private static let V: [[Float32]] = [
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [9, 10, 11, 12],
        ]

        @Test("no sample emitted when monitoring is disabled")
        func noSampleWhenDisabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)

                _ = NMFAlternatingLeastSquares.factorize(
                    V: Self.V, rank: 2, estate: "e", ts: 3.0)

                #expect(sink.count == 0,
                    "NMFAlternatingLeastSquares.factorize must not emit when monitoring is disabled")

                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("one nmf.factor sample emitted when monitoring is enabled")
        func oneSampleWhenEnabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                _ = NMFAlternatingLeastSquares.factorize(
                    V: Self.V, rank: 2, estate: "nmf-estate", ts: 3.0)

                #expect(sink.count == 1,
                    "NMFAlternatingLeastSquares.factorize must emit exactly one sample when enabled")

                if case let .metric(name, value, tags, ts) = sink.samples.first {
                    #expect(name == VizGraphSignals.nmfFactor)
                    #expect(value >= 0, "reconstruction error must be non-negative")
                    #expect(tags["estate"] == "nmf-estate")
                    #expect(tags["rows"] == "3")
                    #expect(tags["cols"] == "4")
                    #expect(tags["rank"] == "2")
                    #expect(ts == 3.0)
                } else {
                    Issue.record("expected .metric sample")
                }

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("factorize result is identical regardless of monitoring state")
        func conformanceResultUnchangedByMonitoring() async {
            await GlobalTestLock.shared.withLock {
                let seed: UInt64 = 0xDEADBEEFCAFEBABE

                Intellectus.setEnabled(false)
                let resultOff = NMFAlternatingLeastSquares.factorize(
                    V: Self.V, rank: 2, seed: seed, estate: "", ts: 0)

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let resultOn = NMFAlternatingLeastSquares.factorize(
                    V: Self.V, rank: 2, seed: seed, estate: "", ts: 0)

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)

                // finalError must be bit-identical (same seed, same algorithm).
                #expect(resultOff.finalError == resultOn.finalError,
                    "NMF finalError must be bit-identical regardless of monitoring state")
                #expect(resultOff.iterations == resultOn.iterations,
                    "NMF iterations must be identical regardless of monitoring state")
            }
        }
    }

    // MARK: - §4 AnomalyDetection

    @Suite("§4 VizGraph — AnomalyDetection emit")
    struct AnomalyDetectionEmitTests {

        private static let window: [Float32] = [1.0, 2.0, 3.0, 4.0, 5.0]
        private static let current: Float32 = 10.0  // clearly anomalous

        @Test("no sample emitted from rollingZScore when monitoring is disabled")
        func rollingZScoreNoSampleWhenDisabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)

                _ = AnomalyDetection.rollingZScore(
                    window: Self.window, current: Self.current, estate: "e", ts: 4.0)

                #expect(sink.count == 0,
                    "rollingZScore must not emit when monitoring is disabled")

                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("one anomaly.flag sample emitted from rollingZScore when monitoring is enabled")
        func rollingZScoreOneSampleWhenEnabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                let score = AnomalyDetection.rollingZScore(
                    window: Self.window, current: Self.current, estate: "anomaly-estate", ts: 4.0)

                #expect(sink.count == 1,
                    "rollingZScore must emit exactly one sample when enabled")

                if case let .metric(name, value, tags, ts) = sink.samples.first {
                    #expect(name == VizGraphSignals.anomalyFlag)
                    #expect(value == Double(abs(score)), "emitted value must equal abs(z-score)")
                    #expect(tags["estate"] == "anomaly-estate")
                    #expect(tags["method"] == "z_score")
                    #expect(tags["window_size"] == "5")
                    #expect(ts == 4.0)
                } else {
                    Issue.record("expected .metric sample")
                }

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("no sample emitted from rollingModifiedZScore when monitoring is disabled")
        func rollingModifiedZScoreNoSampleWhenDisabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)

                _ = AnomalyDetection.rollingModifiedZScore(
                    window: Self.window, current: Self.current, estate: "e", ts: 5.0)

                #expect(sink.count == 0,
                    "rollingModifiedZScore must not emit when monitoring is disabled")

                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("one anomaly.flag sample emitted from rollingModifiedZScore when monitoring is enabled")
        func rollingModifiedZScoreOneSampleWhenEnabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                let score = AnomalyDetection.rollingModifiedZScore(
                    window: Self.window, current: Self.current, estate: "mod-estate", ts: 5.0)

                #expect(sink.count == 1,
                    "rollingModifiedZScore must emit exactly one sample when enabled")

                if case let .metric(name, value, tags, ts) = sink.samples.first {
                    #expect(name == VizGraphSignals.anomalyFlag)
                    #expect(value == Double(abs(score)), "emitted value must equal abs(modified z-score)")
                    #expect(tags["estate"] == "mod-estate")
                    #expect(tags["method"] == "modified_z_score")
                    #expect(tags["window_size"] == "5")
                    #expect(ts == 5.0)
                } else {
                    Issue.record("expected .metric sample")
                }

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("rollingZScore result is identical regardless of monitoring state")
        func rollingZScoreConformance() async {
            await GlobalTestLock.shared.withLock {
                Intellectus.setEnabled(false)
                let scoreOff = AnomalyDetection.rollingZScore(
                    window: Self.window, current: Self.current, estate: "", ts: 0)

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let scoreOn = AnomalyDetection.rollingZScore(
                    window: Self.window, current: Self.current, estate: "", ts: 0)

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)

                #expect(scoreOff == scoreOn,
                    "rollingZScore result must be bit-identical regardless of monitoring state")
            }
        }

        @Test("rollingModifiedZScore result is identical regardless of monitoring state")
        func rollingModifiedZScoreConformance() async {
            await GlobalTestLock.shared.withLock {
                Intellectus.setEnabled(false)
                let scoreOff = AnomalyDetection.rollingModifiedZScore(
                    window: Self.window, current: Self.current, estate: "", ts: 0)

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let scoreOn = AnomalyDetection.rollingModifiedZScore(
                    window: Self.window, current: Self.current, estate: "", ts: 0)

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)

                #expect(scoreOff == scoreOn,
                    "rollingModifiedZScore result must be bit-identical regardless of monitoring state")
            }
        }
    }

    // MARK: - §5 MatrixDecay

    @Suite("§5 VizGraph — MatrixDecay emit")
    struct MatrixDecayEmitTests {

        @Test("no sample emitted when monitoring is disabled")
        func noSampleWhenDisabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)

                var matrix = DecayingMatrix(rows: 3, cols: 3, halfLifeSeconds: 86400)
                matrix[0, 0] = 1.0
                MatrixDecay.apply(to: &matrix, nowSeconds: 86400, estate: "e", ts: 6.0)

                #expect(sink.count == 0,
                    "MatrixDecay.apply must not emit when monitoring is disabled")

                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("one edge.decayed_weight sample emitted when monitoring is enabled")
        func oneSampleWhenEnabled() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                var matrix = DecayingMatrix(rows: 3, cols: 4, halfLifeSeconds: 86400,
                                             lastDecayTimeSeconds: 0)
                matrix[0, 0] = 1.0
                MatrixDecay.apply(to: &matrix, nowSeconds: 86400, estate: "decay-estate", ts: 6.0)

                #expect(sink.count == 1,
                    "MatrixDecay.apply must emit exactly one sample when enabled")

                if case let .metric(name, value, tags, ts) = sink.samples.first {
                    #expect(name == VizGraphSignals.edgeDecayedWeight)
                    // Decay factor for half-life = 86400s at dt = 86400s is 0.5.
                    #expect(abs(value - 0.5) < 1e-9, "decay factor for exactly one half-life must be 0.5")
                    #expect(tags["estate"] == "decay-estate")
                    #expect(tags["matrix_rows"] == "3")
                    #expect(tags["matrix_cols"] == "4")
                    #expect(tags["elapsed_seconds"] == "86400")
                    #expect(ts == 6.0)
                } else {
                    Issue.record("expected .metric sample")
                }

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("no-op decay (dt == 0) emits factor 1.0")
        func noOpDecayEmitsFactorOne() async {
            await GlobalTestLock.shared.withLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)

                var matrix = DecayingMatrix(rows: 2, cols: 2, halfLifeSeconds: 86400,
                                             lastDecayTimeSeconds: 100)
                // nowSeconds == lastDecayTimeSeconds → no-op path.
                MatrixDecay.apply(to: &matrix, nowSeconds: 100, estate: "no-op-estate", ts: 7.0)

                #expect(sink.count == 1,
                    "no-op decay must still emit one sample so the Topology view knows a check ran")

                if case let .metric(name, value, tags, _) = sink.samples.first {
                    #expect(name == VizGraphSignals.edgeDecayedWeight)
                    #expect(value == 1.0, "no-op decay must emit factor 1.0")
                    #expect(tags["elapsed_seconds"] == "0")
                } else {
                    Issue.record("expected .metric sample for no-op decay")
                }

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
        }

        @Test("matrix values are identical regardless of monitoring state")
        func conformanceMatrixValuesUnchangedByMonitoring() async {
            await GlobalTestLock.shared.withLock {
                // Run with monitoring off.
                Intellectus.setEnabled(false)
                var matOff = DecayingMatrix(rows: 3, cols: 3, halfLifeSeconds: 86400)
                matOff[1, 1] = 4.0
                MatrixDecay.apply(to: &matOff, nowSeconds: 86400, estate: "", ts: 0)

                // Run with monitoring on.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                var matOn = DecayingMatrix(rows: 3, cols: 3, halfLifeSeconds: 86400)
                matOn[1, 1] = 4.0
                MatrixDecay.apply(to: &matOn, nowSeconds: 86400, estate: "", ts: 0)

                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)

                #expect(matOff.values == matOn.values,
                    "DecayingMatrix values must be bit-identical regardless of monitoring state")
            }
        }
    }
}
