// CognitionKitTelemetryTests.swift
//
// Tests for CognitionKit self-report telemetry added in cp-cognitionkit-report.
// Mirrors the Rust test module in rust/tests/cognitionkit_telemetry_tests.rs.
//
// §1 Disabled gate: with monitoring OFF, no metric is emitted and
//    recipe results are unchanged.
// §2 GroundedSynthesis emissions: recipe-start and recipe-complete pair
//    per run invocation; step_count tag equals recalled drawer count.
// §3 MigrationBenchmark emissions: start + complete pair per run
//    invocation; step_count tag equals plan count.
// §4 Conformance: recipe outputs are identical with monitoring ON and OFF.
//
// ISOLATION STRATEGY
// These tests install a capturing sink and flip the global Intellectus
// singleton. Swift Testing runs test functions concurrently by default;
// concurrent tests that manipulate the same global enabled/sink state
// produce phantom extra metric counts in each other's sinks.
//
// Two-layer solution:
//
// Layer 1 — intra-file: The outer CognitionKitTelemetrySuite carries
// `.serialized`, so no two tests in this file run at the same time.
//
// Layer 2 — cross-file: EVERY test function in this suite acquires the
// process-wide cognitionTestMutex (actor-based cooperative mutex defined
// in CognitionTestLock.swift) for its full duration. Tests in other suites
// (GroundedSynthesisTests, MigrationBenchmarkTests, etc.) that call
// recipe-run functions also acquire the same mutex, so they cannot run
// while a telemetry test holds the singleton in a non-default state.
// This directly mirrors the NeuronKit IntellectusTestLock solution and
// the Rust GLOBAL_LOCK pattern.
//
// All test functions are declared `async` to use withCognitionLock
// uniformly. The mutex uses cooperative async suspension (CheckedContinuation
// actor queue) — no thread is blocked, so this is safe under Swift 6
// strict concurrency and the cooperative thread pool.

import Foundation
import Testing
import IntellectusLib
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

// MARK: - Capturing sink

/// Records every received StatSample. Thread-safe via NSLock.
/// Mirrors NeuronKitTelemetryTests.CapturingSink.
private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock(); defer { lock.unlock() }
        _samples.append(sample)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.count
    }

    /// All metric samples with the given name.
    func metrics(named name: String) -> [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(n, _, _, _) = $0 { return n == name }
            return false
        }
    }
}

// MARK: - Shared cleanup helper

/// Restore global Intellectus state to (disabled, NoOpSink).
/// Called from every test via defer so a throwing test still cleans up.
private func resetIntellectus() {
    Intellectus.setEnabled(false)
    Intellectus.install(sink: NoOpSink.shared)
}

// MARK: - Estate construction helper

/// Open a fresh in-memory estate. Mirrors the pattern in GroundedSynthesisTests
/// and MigrationBenchmarkTests — `GeniusLocusKit() + InMemoryStorage`.
private func makeEstate(
    capturing contents: [String] = []
) async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
    let handle = try await kit.open(
        storage: storage,
        owner: OwnerCredentials(ownerIdentifier: "telemetry-test"))
    for text in contents {
        let frame = CaptureFrame(
            content: text,
            channel: .typed,
            room: "test",
            latticeAnchor: .udc("540"),
            addedBy: "telemetry-tester",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }
    return (kit, handle)
}

// MARK: - Top-level serialised suite

// `.serialized` enforces sequential execution across all child tests and
// nested suites. No test in this file runs concurrently with any other
// WITHIN this suite.
//
// Additionally, every test function acquires the process-wide
// cognitionTestMutex (defined in CognitionTestLock.swift). This
// prevents races with tests in OTHER suites (GroundedSynthesisTests,
// MigrationBenchmarkTests, etc.) that call recipe-run functions and
// run concurrently in the default parallel runner.
// `.serialized` alone is not sufficient across suite boundaries.
@Suite("CognitionKit Telemetry (cp-cognitionkit-report)", .serialized)
struct CognitionKitTelemetrySuite {

    // MARK: - §1 Disabled gate

    @Suite("§1 CognitionKitTelemetry — disabled gate")
    struct DisabledGateTests {

        /// When monitoring is OFF, GroundedSynthesis emits no metrics.
        @Test("GroundedSynthesis emits no metrics when monitoring is disabled")
        func groundedSynthesisEmitsNothingWhenDisabled() async throws {
            try await withCognitionLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let (kit, handle) = try await makeEstate(capturing: ["hello world"])
                let recipe = GroundedSynthesis()
                _ = try await recipe.run(
                    input: .init(frame: LocusKit.RecallFrame(filterChain: [.unconfirmed])),
                    estate: handle,
                    kit: kit
                )

                #expect(sink.count == 0,
                    "GroundedSynthesis must not emit when monitoring is disabled; got \(sink.count)")
            }
        }
    }

    // MARK: - §2 GroundedSynthesis emissions

    @Suite("§2 CognitionKitTelemetry — GroundedSynthesis recipe emissions")
    struct GroundedSynthesisEmissionTests {

        /// One run call emits exactly two cognitionkit.recipe.run metrics:
        /// one with status "start" and one with status "complete".
        @Test("GroundedSynthesis emits start and complete when monitoring is enabled")
        func runEmitsStartAndComplete() async throws {
            try await withCognitionLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let (kit, handle) = try await makeEstate(capturing: ["hello world"])
                let recipe = GroundedSynthesis()
                _ = try await recipe.run(
                    input: .init(frame: LocusKit.RecallFrame(filterChain: [.unconfirmed])),
                    estate: handle,
                    kit: kit
                )

                let recipeMetrics = sink.metrics(named: CognitionKitMetrics.recipeRun)
                #expect(recipeMetrics.count == 2,
                    "run must emit exactly 2 cognitionkit.recipe.run metrics; got \(recipeMetrics.count)")

                var startTags: [String: String]? = nil
                var completeTags: [String: String]? = nil
                for sample in recipeMetrics {
                    if case let .metric(_, _, tags, _) = sample {
                        if tags["status"] == "start" { startTags = tags }
                        if tags["status"] == "complete" { completeTags = tags }
                    }
                }
                #expect(startTags != nil, "must have a 'start' metric")
                #expect(completeTags != nil, "must have a 'complete' metric")
                #expect(startTags?["recipe"] == "grounded_synthesis",
                    "start metric must tag recipe 'grounded_synthesis'")
                #expect(completeTags?["recipe"] == "grounded_synthesis",
                    "complete metric must tag recipe 'grounded_synthesis'")
            }
        }

        /// Two run calls emit four cognitionkit.recipe.run metrics total.
        @Test("two GroundedSynthesis runs emit four recipe.run metrics")
        func twoRunsEmitFourMetrics() async throws {
            try await withCognitionLock {
                // Build the estate BEFORE enabling monitoring so the VectorKit
                // emit sites inside GeniusLocusKit.capture do not leak into the
                // capturing sink. CognitionKit.recipe.run is the ONLY metric
                // category we assert on, and recipes run AFTER setEnabled(true).
                let (kit, handle) = try await makeEstate(capturing: ["hello world"])
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let recipe = GroundedSynthesis()
                let frame = LocusKit.RecallFrame(filterChain: [.unconfirmed])
                _ = try await recipe.run(input: .init(frame: frame), estate: handle, kit: kit)
                _ = try await recipe.run(input: .init(frame: frame), estate: handle, kit: kit)

                // Filter to only CognitionKit recipe.run metrics so VectorKit
                // rerank emissions (from hybridRecall inside GroundedSynthesis)
                // are counted separately. Both runs emit start+complete = 4 total.
                let recipeMetrics = sink.metrics(named: CognitionKitMetrics.recipeRun)
                #expect(recipeMetrics.count == 4,
                    "two runs must emit 4 cognitionkit.recipe.run metrics; got \(recipeMetrics.count)")
            }
        }

        /// The step_count tag on complete equals the number of recalled drawers.
        @Test("step_count tag equals recalled drawer count")
        func stepCountTagMatchesDrawerCount() async throws {
            try await withCognitionLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let (kit, handle) = try await makeEstate(
                    capturing: ["hello", "world", "test"])
                let recipe = GroundedSynthesis()
                let output = try await recipe.run(
                    input: .init(frame: LocusKit.RecallFrame(filterChain: [.unconfirmed])),
                    estate: handle,
                    kit: kit
                )

                let complete = sink.metrics(named: CognitionKitMetrics.recipeRun).first {
                    if case let .metric(_, _, tags, _) = $0 { return tags["status"] == "complete" }
                    return false
                }
                guard let complete else {
                    Issue.record("no complete metric emitted"); return
                }
                if case let .metric(_, _, tags, _) = complete {
                    #expect(tags["step_count"] == "\(output.drawerCount)",
                        "step_count must equal drawer count; got \(tags["step_count"] ?? "nil")")
                }
            }
        }
    }

    // MARK: - §3 MigrationBenchmark emissions

    @Suite("§3 CognitionKitTelemetry — MigrationBenchmark recipe emissions")
    struct MigrationBenchmarkEmissionTests {

        /// One run call emits exactly two cognitionkit.recipe.run metrics:
        /// one with status "start" and one with status "complete".
        @Test("MigrationBenchmark emits start and complete when monitoring is enabled")
        func runEmitsStartAndComplete() async throws {
            try await withCognitionLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let (kit, handle) = try await makeEstate()
                let recipe = MigrationBenchmark()
                let origin = ExternalCorpus(name: "src", entries: [
                    ExternalEntry(id: "e1", content: "first entry", tags: []),
                    ExternalEntry(id: "e2", content: "second entry", tags: []),
                ])
                let plans: [MigrationPlan] = [
                    MigrationPlan(name: "plan-alpha", room: "r",
                        latticeCode: "600", embeddingModelID: "v1"),
                ]
                _ = try await recipe.run(
                    input: .init(origin: origin, plans: plans),
                    estate: handle,
                    kit: kit
                )

                let recipeMetrics = sink.metrics(named: CognitionKitMetrics.recipeRun)
                #expect(recipeMetrics.count == 2,
                    "MigrationBenchmark run must emit exactly 2 metrics; got \(recipeMetrics.count)")

                var startTags: [String: String]? = nil
                var completeTags: [String: String]? = nil
                for sample in recipeMetrics {
                    if case let .metric(_, _, tags, _) = sample {
                        if tags["status"] == "start" { startTags = tags }
                        if tags["status"] == "complete" { completeTags = tags }
                    }
                }
                #expect(startTags != nil, "must have a 'start' metric")
                #expect(completeTags != nil, "must have a 'complete' metric")
                #expect(startTags?["recipe"] == "migration_benchmark",
                    "start metric must tag recipe 'migration_benchmark'")
                #expect(completeTags?["recipe"] == "migration_benchmark",
                    "complete metric must tag recipe 'migration_benchmark'")
            }
        }

        /// The step_count tag on complete equals the plan count.
        @Test("step_count tag equals plan count")
        func stepCountTagMatchesPlanCount() async throws {
            try await withCognitionLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let (kit, handle) = try await makeEstate()
                let recipe = MigrationBenchmark()
                let origin = ExternalCorpus(name: "src", entries: [
                    ExternalEntry(id: "e1", content: "alpha", tags: []),
                ])
                let plans: [MigrationPlan] = [
                    MigrationPlan(name: "plan-a", room: "r", latticeCode: "600", embeddingModelID: "v1"),
                    MigrationPlan(name: "plan-b", room: "r", latticeCode: "600", embeddingModelID: "v1"),
                ]
                _ = try await recipe.run(
                    input: .init(origin: origin, plans: plans),
                    estate: handle,
                    kit: kit
                )

                let complete = sink.metrics(named: CognitionKitMetrics.recipeRun).first {
                    if case let .metric(_, _, tags, _) = $0 { return tags["status"] == "complete" }
                    return false
                }
                guard let complete else {
                    Issue.record("no complete metric emitted"); return
                }
                if case let .metric(_, _, tags, _) = complete {
                    #expect(tags["step_count"] == "2",
                        "step_count must equal plan count 2; got \(tags["step_count"] ?? "nil")")
                }
            }
        }

        /// When monitoring is disabled, MigrationBenchmark emits nothing.
        @Test("MigrationBenchmark emits nothing when monitoring is disabled")
        func emitsNothingWhenDisabled() async throws {
            try await withCognitionLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let (kit, handle) = try await makeEstate()
                let recipe = MigrationBenchmark()
                let origin = ExternalCorpus(name: "src", entries: [
                    ExternalEntry(id: "e1", content: "first entry", tags: []),
                ])
                let plans: [MigrationPlan] = [
                    MigrationPlan(name: "plan-alpha", room: "r",
                        latticeCode: "600", embeddingModelID: "v1"),
                ]
                _ = try await recipe.run(
                    input: .init(origin: origin, plans: plans),
                    estate: handle,
                    kit: kit
                )

                #expect(sink.count == 0,
                    "MigrationBenchmark must not emit when monitoring is disabled; got \(sink.count)")
            }
        }
    }

    // MARK: - §4 Conformance gate

    @Suite("§4 CognitionKitTelemetry — conformance (recipe output unaffected by telemetry)")
    struct ConformanceTests {

        /// GroundedSynthesis output is identical whether monitoring is on or off.
        @Test("GroundedSynthesis output identical with monitoring on vs off")
        func groundedSynthesisOutputIdenticalWithAndWithoutTelemetry() async throws {
            try await withCognitionLock {
                let recipe = GroundedSynthesis()
                let frame = LocusKit.RecallFrame(filterChain: [.unconfirmed])

                // OFF path.
                let (kitOff, handleOff) = try await makeEstate(capturing: ["hello", "world"])
                Intellectus.setEnabled(false)
                let outputOff = try await recipe.run(
                    input: .init(frame: frame),
                    estate: handleOff,
                    kit: kitOff
                )

                // ON path — separate estate so captured rows are independent.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let (kitOn, handleOn) = try await makeEstate(capturing: ["hello", "world"])
                let outputOn = try await recipe.run(
                    input: .init(frame: frame),
                    estate: handleOn,
                    kit: kitOn
                )
                defer { resetIntellectus() }

                // Drawer count must be identical — the recipe's observable output.
                #expect(outputOff.drawerCount == outputOn.drawerCount,
                    "drawerCount must be identical regardless of monitoring state")
                // ON path must have emitted metrics (proves the on-path was active).
                #expect(sink.count > 0, "monitoring-on path must emit at least one metric")
            }
        }

        /// MigrationBenchmark comparison report is identical whether monitoring is on or off.
        @Test("MigrationBenchmark output identical with monitoring on vs off")
        func migrationBenchmarkOutputIdenticalWithAndWithoutTelemetry() async throws {
            try await withCognitionLock {
                let origin = ExternalCorpus(name: "origin", entries: [
                    ExternalEntry(id: "e1", content: "some content", tags: []),
                ])
                let plans: [MigrationPlan] = [
                    MigrationPlan(name: "plan-x", room: "room",
                        latticeCode: "600", embeddingModelID: "v1"),
                ]
                let recipe = MigrationBenchmark()

                // OFF path.
                let (kitOff, handleOff) = try await makeEstate()
                Intellectus.setEnabled(false)
                let outputOff = try await recipe.run(
                    input: .init(origin: origin, plans: plans),
                    estate: handleOff,
                    kit: kitOff
                )

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let (kitOn, handleOn) = try await makeEstate()
                let outputOn = try await recipe.run(
                    input: .init(origin: origin, plans: plans),
                    estate: handleOn,
                    kit: kitOn
                )
                defer { resetIntellectus() }

                // Both paths must produce the same winner status.
                #expect(outputOff.comparisonReport.winnerPlanName ==
                    outputOn.comparisonReport.winnerPlanName,
                    "winnerPlanName must be identical regardless of monitoring state")
                #expect(outputOff.comparisonReport.rankings.count ==
                    outputOn.comparisonReport.rankings.count,
                    "ranking count must be identical regardless of monitoring state")
                // ON path must have emitted metrics.
                #expect(sink.count > 0, "monitoring-on path must emit at least one metric")
            }
        }
    }
}
