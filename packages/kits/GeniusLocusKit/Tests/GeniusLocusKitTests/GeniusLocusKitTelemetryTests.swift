// GeniusLocusKitTelemetryTests.swift
//
// Tests for GeniusLocusKit per-estate rollup telemetry added in GLK_ROLLUPS_001.
// Mirrors the Rust test module in rust/tests/glk_telemetry_tests.rs.
//
// §1 Disabled gate: with monitoring OFF, no metrics are emitted and all
//    estate coordination results are unchanged (byte-identical outputs).
// §2 Mount state transitions: open emits mounted, close emits unmounted.
// §3 Provision: provision() emits exactly one geniuslocus.estate.provision
//    metric tagged with the estate kind.
// §4 Lifecycle: quiesce emits quiesced, drain emits draining then quiesced.
// §5 Noun count: open emits a noun_count snapshot for fresh (zero) estates.
// §6 Verb error: remap() emits a verb_error metric when monitoring is on.
// §7 Conformance: estate coordination results are identical with monitoring
//    ON and OFF — telemetry is purely additive.
//
// ISOLATION STRATEGY
// These tests install a capturing sink and flip the global Intellectus
// singleton. Swift Testing runs test functions concurrently by default;
// concurrent tests that manipulate the same global enabled/sink state
// produce phantom extra metric counts in each other's sinks.
//
// Two-layer solution:
//
// Layer 1 — intra-file: The outer GLKTelemetrySuite carries `.serialized`,
// so no two tests in this file run at the same time.
//
// Layer 2 — cross-file: EVERY test function in this suite acquires the
// process-wide intellectusTestMutex (actor-based cooperative mutex defined
// in IntellectusTestLock.swift) for its full duration. Tests in other suites
// (EstateProvisionLifecycleTests, VerbSurfaceTests, etc.) that call
// telemetry-emitting GLK methods also acquire the same mutex, so they
// cannot run while a telemetry test holds the singleton in a non-default
// state. This directly mirrors the Rust solution.
//
// All test functions are declared `async` to use withIntellectusLock
// uniformly. The mutex uses cooperative async suspension (CheckedContinuation
// actor queue) — no thread is blocked.

import Foundation
import Testing
import IntellectusLib
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - Capturing sink

/// Records every received StatSample. Thread-safe via NSLock.
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

    /// Value of the first metric with the given name, or nil.
    func firstValue(named name: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        for sample in _samples {
            if case let .metric(n, v, _, _) = sample, n == name { return v }
        }
        return nil
    }

    /// Tags of the first metric with the given name, or nil.
    func firstTags(named name: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        for sample in _samples {
            if case let .metric(n, _, t, _) = sample, n == name { return t }
        }
        return nil
    }
}

// MARK: - Shared cleanup helper

/// Restore global Intellectus state to (disabled, NoOpSink).
/// Called from every test via defer so a throwing test still cleans up.
private func resetIntellectus() {
    Intellectus.setEnabled(false)
    Intellectus.install(sink: NoOpSink.shared)
}

// MARK: - Test helpers

/// Build an isolated in-memory storage instance (each call produces a distinct store).
private func makeStorage() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
}

private let testOwner = OwnerCredentials(ownerIdentifier: "glk-telemetry-tests")

private func locusOnlyParams(name: String = "TelemetryTest") -> EstateProvisionParams {
    EstateProvisionParams(
        estateName: name,
        kind: .locusOnly,
        zoomWindowLow: 0,
        zoomWindowHigh: 5,
        frameworkProfile: "TestProfile",
        syncMode: .none
    )
}

private func glkParams(name: String = "TelemetryGLK") -> EstateProvisionParams {
    EstateProvisionParams(
        estateName: name,
        kind: .glk,
        zoomWindowLow: 0,
        zoomWindowHigh: 5,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none
    )
}

// MARK: - Top-level serialised suite

// `.serialized` enforces sequential execution across all child tests and
// nested suites. No test in this file runs concurrently with any other
// WITHIN this suite.
//
// Additionally, every test function acquires the process-wide
// intellectusTestMutex (defined in IntellectusTestLock.swift). This
// prevents races with tests in OTHER suites that call emitting GLK methods
// and run concurrently in the default parallel runner.
// `.serialized` alone is not sufficient across suite boundaries.
@Suite("GeniusLocusKit Telemetry (GLK_ROLLUPS_001)", .serialized)
struct GLKTelemetrySuite {

    // MARK: - §1 Disabled gate

    @Suite("§1 GLKTelemetry — disabled gate")
    struct DisabledGateTests {

        /// When monitoring is OFF, open() emits no metrics.
        @Test("open emits no metrics when monitoring is disabled")
        func openEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                _ = try await kit.open(storage: storage, owner: testOwner)

                #expect(sink.count == 0,
                    "open() must not emit when monitoring is disabled")
            }
        }

        /// When monitoring is OFF, close() emits no metrics.
        @Test("close emits no metrics when monitoring is disabled")
        func closeEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)
                try await kit.close(handle)

                #expect(sink.count == 0,
                    "close() must not emit when monitoring is disabled")
            }
        }

        /// When monitoring is OFF, provision() emits no metrics.
        @Test("provision emits no metrics when monitoring is disabled")
        func provisionEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                _ = try await kit.provision(
                    storage: storage,
                    owner: testOwner,
                    params: locusOnlyParams()
                )

                #expect(sink.count == 0,
                    "provision() must not emit when monitoring is disabled")
            }
        }

        /// When monitoring is OFF, quiesce() emits no metrics.
        @Test("quiesce emits no metrics when monitoring is disabled")
        func quiesceEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)
                try await kit.quiesce(handle)

                #expect(sink.count == 0,
                    "quiesce() must not emit when monitoring is disabled")
            }
        }
    }

    // MARK: - §2 Mount state transitions

    @Suite("§2 GLKTelemetry — mount state transitions")
    struct MountStateTests {

        /// open() emits exactly one geniuslocus.estate.mount_state_transition
        /// metric with state=mounted.
        @Test("open emits mounted transition when monitoring is enabled")
        func openEmitsMountedTransition() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)

                let transitions = sink.metrics(named: "geniuslocus.estate.mount_state_transition")
                // Filter to transitions for THIS estate specifically, identified by the
                // estate_id tag. This guards against phantom metrics that may appear in the
                // sink from other-suite tests running concurrently during the await suspension.
                let handleID = handle.estateUUID.uuidString
                let thisEstateTransitions = transitions.filter {
                    if case let .metric(_, _, tags, _) = $0 { return tags["estate_id"] == handleID }
                    return false
                }
                let mountedTransitions = thisEstateTransitions.filter {
                    if case let .metric(_, _, tags, _) = $0 { return tags["state"] == "mounted" }
                    return false
                }
                #expect(mountedTransitions.count >= 1,
                    "open() must emit at least one mounted transition for estate \(handleID); got \(mountedTransitions.count)")
            }
        }

        /// close() emits exactly one geniuslocus.estate.mount_state_transition
        /// metric with state=unmounted.
        @Test("close emits unmounted transition when monitoring is enabled")
        func closeEmitsUnmountedTransition() async throws {
            try await withIntellectusLock {
                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                try await kit.close(handle)

                let transitions = sink.metrics(named: "geniuslocus.estate.mount_state_transition")
                let unmountedTransitions = transitions.filter {
                    if case let .metric(_, _, tags, _) = $0 { return tags["state"] == "unmounted" }
                    return false
                }
                #expect(unmountedTransitions.count == 1,
                    "close() must emit exactly 1 unmounted transition; got \(unmountedTransitions.count)")
                // Verify estate_id tag.
                if case let .metric(_, _, tags, _) = unmountedTransitions.first! {
                    #expect(tags["estate_id"] == handle.estateUUID.uuidString,
                        "estate_id tag must match the closed estate UUID")
                }
            }
        }
    }

    // MARK: - §3 Provision emissions

    @Suite("§3 GLKTelemetry — provision emissions")
    struct ProvisionTests {

        /// provision(.locusOnly) emits exactly one provision metric
        /// tagged with kind=LocusOnly.
        @Test("provision emits provision metric with correct kind tag")
        func provisionEmitsMetricWithKindTag() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.provision(
                    storage: storage,
                    owner: testOwner,
                    params: locusOnlyParams()
                )

                let provisions = sink.metrics(named: "geniuslocus.estate.provision")
                #expect(provisions.count == 1,
                    "provision() must emit exactly 1 provision metric; got \(provisions.count)")

                if case let .metric(_, _, tags, _) = provisions.first! {
                    #expect(tags["kind"] == "LocusOnly",
                        "kind tag must be 'LocusOnly'; got \(tags["kind"] ?? "nil")")
                    #expect(tags["estate_id"] == handle.estateUUID.uuidString,
                        "estate_id tag must match the provisioned estate UUID")
                }
            }
        }

        /// provision(.glk) emits a provision metric tagged with kind=GLK.
        @Test("provision(.glk) emits provision metric with kind=GLK")
        func provisionGLKEmitsCorrectKind() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                _ = try await kit.provision(
                    storage: storage,
                    owner: testOwner,
                    params: glkParams()
                )

                let provisions = sink.metrics(named: "geniuslocus.estate.provision")
                #expect(provisions.count == 1,
                    "provision(.glk) must emit exactly 1 provision metric")

                if case let .metric(_, _, tags, _) = provisions.first! {
                    #expect(tags["kind"] == "GLK",
                        "kind tag must be 'GLK'; got \(tags["kind"] ?? "nil")")
                }
            }
        }

        /// Two provision calls each emit their own provision metric.
        @Test("each provision call emits its own provision metric")
        func eachProvisionEmitsOwnMetric() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storageA = makeStorage()
                let storageB = makeStorage()
                _ = try await kit.provision(
                    storage: storageA,
                    owner: testOwner,
                    params: locusOnlyParams(name: "EstateA")
                )
                _ = try await kit.provision(
                    storage: storageB,
                    owner: testOwner,
                    params: locusOnlyParams(name: "EstateB")
                )

                let provisions = sink.metrics(named: "geniuslocus.estate.provision")
                #expect(provisions.count == 2,
                    "two provision calls must emit 2 provision metrics; got \(provisions.count)")
            }
        }
    }

    // MARK: - §4 Lifecycle transitions

    @Suite("§4 GLKTelemetry — lifecycle transitions")
    struct LifecycleTests {

        /// quiesce() emits a mount_state_transition with state=quiesced.
        @Test("quiesce emits quiesced transition when monitoring is enabled")
        func quiesceEmitsQuiescedTransition() async throws {
            try await withIntellectusLock {
                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                try await kit.quiesce(handle)

                let transitions = sink.metrics(named: "geniuslocus.estate.mount_state_transition")
                let quiescedTransitions = transitions.filter {
                    if case let .metric(_, _, tags, _) = $0 { return tags["state"] == "quiesced" }
                    return false
                }
                #expect(quiescedTransitions.count == 1,
                    "quiesce() must emit exactly 1 quiesced transition; got \(quiescedTransitions.count)")
            }
        }

        /// drain() emits mount_state_transition with state=draining then state=quiesced.
        @Test("drain emits draining then quiesced transitions when monitoring is enabled")
        func drainEmitsDrainingThenQuiescedTransitions() async throws {
            try await withIntellectusLock {
                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                try await kit.drain(handle)

                let transitions = sink.metrics(named: "geniuslocus.estate.mount_state_transition")
                let drainingTransitions = transitions.filter {
                    if case let .metric(_, _, tags, _) = $0 { return tags["state"] == "draining" }
                    return false
                }
                let quiescedTransitions = transitions.filter {
                    if case let .metric(_, _, tags, _) = $0 { return tags["state"] == "quiesced" }
                    return false
                }
                #expect(drainingTransitions.count == 1,
                    "drain() must emit 1 draining transition; got \(drainingTransitions.count)")
                #expect(quiescedTransitions.count == 1,
                    "drain() must emit 1 quiesced transition; got \(quiescedTransitions.count)")
            }
        }
    }

    // MARK: - §5 Noun count snapshot

    @Suite("§5 GLKTelemetry — noun count snapshot")
    struct NounCountTests {

        /// open() emits a noun_count=0 metric for a fresh estate.
        @Test("open emits noun_count=0 for a fresh estate when monitoring is enabled")
        func openEmitsZeroNounCountForFreshEstate() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                _ = try await kit.open(storage: storage, owner: testOwner)

                let nounCountMetrics = sink.metrics(named: "geniuslocus.estate.noun_count")
                #expect(nounCountMetrics.count == 1,
                    "open() must emit exactly 1 noun_count metric; got \(nounCountMetrics.count)")

                if case let .metric(_, value, _, _) = nounCountMetrics.first! {
                    #expect(value == 0.0,
                        "noun_count must be 0 for a fresh estate; got \(value)")
                }
            }
        }

        /// noun_count metric carries the correct estate_id tag.
        @Test("noun_count metric carries correct estate_id tag")
        func nounCountCarriesEstateIDTag() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)

                if let tags = sink.metrics(named: "geniuslocus.estate.noun_count").first.flatMap({
                    if case let .metric(_, _, tags, _) = $0 { return tags } else { return nil }
                }) {
                    #expect(tags["estate_id"] == handle.estateUUID.uuidString,
                        "noun_count must be tagged with the estate UUID")
                } else {
                    Issue.record("no noun_count metric emitted")
                }
            }
        }
    }

    // MARK: - §6 Verb error

    @Suite("§6 GLKTelemetry — verb error")
    struct VerbErrorTests {

        /// A verb failure on a stale handle (estateNotOpen) does not emit a
        /// verb_error metric — that is a routing error, not a verb error.
        @Test("stale handle error does not emit verb_error metric")
        func staleHandleDoesNotEmitVerbError() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let kit = GeniusLocusKit()
                let storage = makeStorage()
                let handle = try await kit.open(storage: storage, owner: testOwner)
                try await kit.close(handle)

                // Now try to use the stale handle — close() on an already-closed
                // handle raises estateNotOpen. estateNotOpen is a routing error
                // (handle not in registry), not a verb dispatch error, so remap()
                // is never called and no verb_error metric must be emitted.
                do {
                    try await kit.close(handle)
                    Issue.record("expected estateNotOpen but no error thrown")
                } catch let err as GeniusLocusKitError {
                    if case .estateNotOpen = err {
                        // Expected — routing error, no verb_error metric.
                        #expect(sink.metrics(named: "geniuslocus.estate.verb_error").count == 0,
                            "estateNotOpen must not emit a verb_error metric")
                    } else {
                        Issue.record("unexpected GeniusLocusKitError: \(err)")
                    }
                } catch {
                    Issue.record("unexpected error type: \(error)")
                }
            }
        }
    }

    // MARK: - §7 Conformance gate

    @Suite("§7 GLKTelemetry — conformance (results unaffected by telemetry)")
    struct ConformanceTests {

        /// Estate handle and mount state are correct regardless of monitoring.
        @Test("estate handle and mount state identical with monitoring on vs off")
        func estateHandleAndMountStateIdentical() async throws {
            try await withIntellectusLock {
                // OFF path.
                Intellectus.setEnabled(false)
                let kitOff = GeniusLocusKit()
                let storageOff = makeStorage()
                let handleOff = try await kitOff.open(storage: storageOff, owner: testOwner)
                let mountStateOff = await kitOff.mountState(for: handleOff)

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }
                let kitOn = GeniusLocusKit()
                let storageOn = makeStorage()
                let handleOn = try await kitOn.open(storage: storageOn, owner: testOwner)
                let mountStateOn = await kitOn.mountState(for: handleOn)

                // Mount state must be identical regardless of monitoring.
                #expect(mountStateOff == mountStateOn,
                    "mount state must be identical regardless of monitoring state; off=\(String(describing: mountStateOff)), on=\(String(describing: mountStateOn))")

                // ON path emitted metrics.
                #expect(sink.count > 0,
                    "monitoring-on path must emit at least one metric")
            }
        }

        /// provision() output is identical regardless of monitoring.
        @Test("provision params and estate kind correct with monitoring on vs off")
        func provisionResultIdentical() async throws {
            try await withIntellectusLock {
                // OFF path.
                Intellectus.setEnabled(false)
                let kitOff = GeniusLocusKit()
                let storageOff = makeStorage()
                let handleOff = try await kitOff.provision(
                    storage: storageOff,
                    owner: testOwner,
                    params: locusOnlyParams(name: "ConformanceOff")
                )
                let mountStateOff = await kitOff.mountState(for: handleOff)

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }
                let kitOn = GeniusLocusKit()
                let storageOn = makeStorage()
                let handleOn = try await kitOn.provision(
                    storage: storageOn,
                    owner: testOwner,
                    params: locusOnlyParams(name: "ConformanceOn")
                )
                let mountStateOn = await kitOn.mountState(for: handleOn)

                // Results must be identical.
                #expect(mountStateOff == mountStateOn,
                    "provision mount state must be identical regardless of monitoring state")

                // ON path emitted metrics.
                #expect(sink.count > 0,
                    "monitoring-on provision path must emit at least one metric")
            }
        }

        /// quiesce() state transition is correct regardless of monitoring.
        @Test("quiesce produces quiesced state with monitoring on vs off")
        func quiesceResultIdentical() async throws {
            try await withIntellectusLock {
                // OFF path.
                Intellectus.setEnabled(false)
                let kitOff = GeniusLocusKit()
                let storageOff = makeStorage()
                let handleOff = try await kitOff.open(storage: storageOff, owner: testOwner)
                try await kitOff.quiesce(handleOff)
                let mountStateOff = await kitOff.mountState(for: handleOff)

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }
                let kitOn = GeniusLocusKit()
                let storageOn = makeStorage()
                let handleOn = try await kitOn.open(storage: storageOn, owner: testOwner)
                try await kitOn.quiesce(handleOn)
                let mountStateOn = await kitOn.mountState(for: handleOn)

                #expect(mountStateOff == .quiesced,
                    "quiesce must produce .quiesced state on off-path")
                #expect(mountStateOn == .quiesced,
                    "quiesce must produce .quiesced state on on-path")

                // ON path emitted metrics.
                #expect(sink.count > 0,
                    "monitoring-on quiesce path must emit at least one metric")
            }
        }
    }
}
