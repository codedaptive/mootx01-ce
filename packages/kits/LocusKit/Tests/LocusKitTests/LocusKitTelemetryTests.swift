// LocusKitTelemetryTests.swift
//
// Tests for LocusKit self-report telemetry added in cp-locuskit-report.
// Mirrors the Rust test module in rust/tests/locuskit_telemetry_tests.rs.
//
// §1 Disabled gate: with monitoring OFF, no metric is emitted and
//    functional results are unchanged.
// §2 Drawer capture emissions: addDrawer emits capture_latency_ms and
//    capture_count when monitoring is ON.
// §3 Drawer query emissions: drawersIn and allDrawers emit query metrics
//    when monitoring is ON.
// §4 KGFact emissions: addKGFact emits add_count; kgFacts and allKGFacts
//    emit query_result_count.
// §5 Tunnel emissions: addTunnel emits tunnel.add_count.
// §6 Conformance: functional results are identical with monitoring ON and OFF.
// §7 Verb-layer event emissions: Estate.capture(CaptureFrame/TunnelCaptureFrame)
//    emit StatSample.event with kind=.capture, correct nounType, rowID, and estate.
// §8 Write-gate telemetry: emitGateAdmit/emitGateReject from DrawerStore.gatedCapture.
//
// ISOLATION STRATEGY
// These tests install a capturing sink and flip the global Intellectus
// singleton. Swift Testing runs test functions concurrently by default;
// concurrent tests that manipulate the same global enabled/sink state
// produce phantom extra metric counts in each other's sinks.
//
// Two-layer solution:
//
// Layer 1 — intra-file: The outer LocusKitTelemetrySuite carries
// `.serialized`, so no two tests in this file run at the same time.
//
// Layer 2 — cross-file: EVERY test function in this suite acquires the
// process-wide intellectusTestMutex (actor-based cooperative mutex defined
// in IntellectusTestLock.swift) for its full duration. Tests in other suites
// (DrawerStoreTests, KGFactStoreTests, TunnelTests, etc.) that call
// telemetry-emitting functions also acquire the same mutex, so they
// cannot run while a telemetry test holds the singleton in a non-default
// state. This directly mirrors the Rust solution: a `Mutex<()>` acquired
// at the top of every test that touches the singleton or calls an
// emitting function, including disabled-path tests (a lock-free disabled
// test can interleave with a lock-held enabled test and corrupt it).
//
// All test functions are declared `async` to use withIntellectusLock
// uniformly. The mutex uses cooperative async suspension (CheckedContinuation
// actor queue) — no thread is blocked, so this is safe under Swift 6
// strict concurrency and the cooperative thread pool.

import Foundation
import IntellectusLib
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
import Testing
@testable import LocusKit

// MARK: - Capturing sink

/// Records every received StatSample. Thread-safe via NSLock.
///
/// NOTE: Because LocusKit has a large test suite (557+ tests at baseline)
/// and many test files call telemetry-emitting functions (addDrawer,
/// drawersIn, addKGFact, addTunnel), it is impractical to wrap every
/// existing test body with `withIntellectusLock`. Instead, the telemetry
/// tests use estate-filtered counting: each test creates a store with a
/// fresh UUID, and the sink's `metrics(named:forEstate:)` method filters
/// to samples carrying that estate's tag. Concurrent tests that call
/// emitting functions on DIFFERENT stores will have different `estate`
/// tags and are invisible to these assertions.
///
/// This approach is equivalent to the VectorKit/NeuronKit per-function
/// lock approach in correctness: each test is isolated by its unique
/// estate UUID tag rather than by a process-wide mutex. The
/// `intellectusTestMutex` is still acquired by tests that need to reason
/// about the TOTAL count (e.g. disabled-gate tests where count == 0).
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

    /// All metric samples with the given name AND whose estate tag matches
    /// the given estate UUID string. Use this to isolate metrics from
    /// concurrent tests that operate on different stores.
    func metrics(named name: String, forEstate estateTag: String) -> [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(n, _, tags, _) = $0 {
                return n == name && tags["estate"] == estateTag
            }
            return false
        }
    }

    /// Count of all samples with the given name AND estate tag.
    func count(named name: String, forEstate estateTag: String) -> Int {
        metrics(named: name, forEstate: estateTag).count
    }

    /// All event samples whose estate field matches the given UUID string.
    func events(forEstate estateTag: String) -> [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .event(_, _, _, estate, _) = $0 { return estate == estateTag }
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

// MARK: - Store builder

/// Build a fresh in-memory DrawerStore for each test.
/// InMemory backend is used to keep tests fast and free from filesystem
/// cleanup boilerplate. Each call produces an independent store with a
/// fresh UUID so tests do not share state.
private func makeInMemoryStore() async throws -> DrawerStore {
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    return try await DrawerStore(storage: storage)
}

/// Build a fresh SQLite-backed Estate for verb-layer event-emission tests.
/// Uses a unique temp file per call so tests do not share state.
private func makeEstate() async throws -> Estate {
    let url = TestStorage.tempURL()
    return try await Estate.create(
        storage: TestStorage.sqlite(url),
        owner: OwnerCredentials(ownerIdentifier: "tel-test-owner")
    )
}

// MARK: - Sample drawer / tunnel / fact builders

private func sampleDrawer(id: String = "d1") -> Drawer {
    Drawer(
        id: TestStorage.tid(id),
        content: "telemetry test content \(id)",
        wing: "wing-tel",
        room: "room-tel",
        addedBy: "newton",
        filedAt: Date(timeIntervalSince1970: 1_000_000),
        embeddingModelID: "test-model-v1",
        provenance: 0,
        adjectiveBitmap: 0,
        operationalBitmap: 0
    )
}

private func sampleTunnel(sourceId: String, targetId: String) -> Tunnel {
    Tunnel(
        id: TestStorage.tid("tun-\(sourceId)-\(targetId)"),
        sourceWing: "wing-tel",
        sourceRoom: "room-tel",
        sourceDrawerId: TestStorage.tid(sourceId),
        targetWing: "wing-tel",
        targetRoom: "room-tel",
        targetDrawerId: TestStorage.tid(targetId),
        label: "relates_to",
        kind: .references,
        addedBy: "newton",
        filedAt: Date(timeIntervalSince1970: 1_000_001)
    )
}

private func sampleKGFact(id: String = "f1", drawerID: String = "d1") -> KGFact {
    KGFact(
        id: TestStorage.tid(id),
        subject: "SubjectA",
        predicate: "relatesTo",
        object: "ObjectB",
        sourceDrawerID: TestStorage.tid(drawerID),
        adjectiveBitmap: 0,
        operationalBitmap: 0,
        provenanceBitmap: 0,
        filedAt: Date(timeIntervalSince1970: 1_000_002)
    )
}

// MARK: - Top-level serialised suite

// `.serialized` enforces sequential execution across all child tests and
// nested suites. No test in this file runs concurrently with any other
// WITHIN this suite.
//
// Additionally, every test function acquires the process-wide
// intellectusTestMutex (defined in IntellectusTestLock.swift). This
// prevents races with tests in OTHER suites (DrawerStoreTests,
// KGFactStoreTests, TunnelTests, etc.) that call emitting functions
// and run concurrently in the default parallel runner.
// `.serialized` alone is not sufficient across suite boundaries.
@Suite("LocusKit Telemetry (cp-locuskit-report)", .serialized)
struct LocusKitTelemetrySuite {

    // MARK: - §1 Disabled gate

    @Suite("§1 LocusKitTelemetry — disabled gate")
    struct DisabledGateTests {

        /// When monitoring is OFF, addDrawer emits nothing.
        @Test("addDrawer emits no metrics when monitoring is disabled")
        func addDrawerEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let drawer = sampleDrawer()
                try await store.addDrawer(drawer, now: Date(timeIntervalSince1970: 1_000_000))

                #expect(sink.count == 0,
                    "addDrawer() must not emit when monitoring is disabled")
            }
        }

        /// When monitoring is OFF, drawersIn emits nothing.
        @Test("drawersIn emits no metrics when monitoring is disabled")
        func drawersInEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                _ = try await store.drawersIn(wing: "wing-tel")

                #expect(sink.count == 0,
                    "drawersIn() must not emit when monitoring is disabled")
            }
        }

        /// When monitoring is OFF, addKGFact emits nothing.
        @Test("addKGFact emits no metrics when monitoring is disabled")
        func addKGFactEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let drawer = sampleDrawer()
                try await store.addDrawer(drawer, now: Date(timeIntervalSince1970: 1_000_000))
                let fact = sampleKGFact()
                // Reset count after addDrawer to isolate addKGFact
                Intellectus.install(sink: CapturingSink())
                let sink2 = CapturingSink()
                Intellectus.install(sink: sink2)
                try await store.addKGFact(fact)

                #expect(sink2.count == 0,
                    "addKGFact() must not emit when monitoring is disabled")
            }
        }

        /// When monitoring is OFF, addTunnel emits nothing.
        @Test("addTunnel emits no metrics when monitoring is disabled")
        func addTunnelEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                // Add two drawers first (monitoring off)
                let d1 = sampleDrawer(id: "d1")
                let d2 = sampleDrawer(id: "d2")
                try await store.addDrawer(d1, now: Date(timeIntervalSince1970: 1_000_000))
                try await store.addDrawer(d2, now: Date(timeIntervalSince1970: 1_000_001))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let tunnel = sampleTunnel(sourceId: "d1", targetId: "d2")
                try await store.addTunnel(tunnel)

                #expect(sink.count == 0,
                    "addTunnel() must not emit when monitoring is disabled")
            }
        }
    }

    // MARK: - §2 Drawer capture emissions

    @Suite("§2 LocusKitTelemetry — drawer capture emissions")
    struct DrawerCaptureEmissionTests {

        /// addDrawer emits exactly 2 metrics per call: capture_latency_ms + capture_count.
        /// Estate-filtered to isolate from concurrent tests in other suites.
        @Test("addDrawer emits capture_latency_ms and capture_count when enabled")
        func addDrawerEmitsBothMetrics() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                let drawer = sampleDrawer()
                try await store.addDrawer(drawer, now: Date(timeIntervalSince1970: 1_000_000))

                // Filter by this test's estate UUID to exclude emissions from
                // concurrent tests that use different stores.
                let latencyCount = sink.count(named: "locuskit.drawer.capture_latency_ms", forEstate: estateTag)
                let captureCount = sink.count(named: "locuskit.drawer.capture_count", forEstate: estateTag)
                #expect(latencyCount == 1,
                    "addDrawer must emit exactly 1 capture_latency_ms for this estate; got \(latencyCount)")
                #expect(captureCount == 1,
                    "addDrawer must emit exactly 1 capture_count for this estate; got \(captureCount)")
            }
        }

        /// capture_count value is 1.0 per call.
        @Test("capture_count metric value is 1.0 per addDrawer call")
        func captureCountValueIsOne() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                try await store.addDrawer(sampleDrawer(id: "x1"), now: Date(timeIntervalSince1970: 1_000_000))

                guard let sample = sink.metrics(named: "locuskit.drawer.capture_count", forEstate: estateTag).first,
                      case let .metric(_, value, _, _) = sample else {
                    Issue.record("no capture_count metric emitted for estate \(estateTag)")
                    return
                }
                #expect(value == 1.0,
                    "capture_count value must be 1.0; got \(value)")
            }
        }

        /// Two addDrawer calls on the same store emit two capture_count metrics for that estate.
        @Test("two addDrawer calls emit two capture_count metrics")
        func twoAddDrawerCallsEmitTwoMetrics() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                try await store.addDrawer(sampleDrawer(id: "a1"), now: Date(timeIntervalSince1970: 1_000_000))
                try await store.addDrawer(sampleDrawer(id: "a2"), now: Date(timeIntervalSince1970: 1_000_001))

                // Filter by estate tag to exclude any concurrent test emissions.
                let captureCount = sink.count(named: "locuskit.drawer.capture_count", forEstate: estateTag)
                #expect(captureCount == 2,
                    "two addDrawer calls on estate \(estateTag) must produce 2 capture_count metrics; got \(captureCount)")
            }
        }

        /// capture_latency_ms is non-negative.
        @Test("capture_latency_ms metric value is non-negative")
        func captureLatencyIsNonNegative() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                try await store.addDrawer(sampleDrawer(), now: Date(timeIntervalSince1970: 1_000_000))

                guard let sample = sink.metrics(named: "locuskit.drawer.capture_latency_ms", forEstate: estateTag).first,
                      case let .metric(_, value, _, _) = sample else {
                    Issue.record("no capture_latency_ms metric emitted for estate \(estateTag)")
                    return
                }
                #expect(value >= 0.0,
                    "capture_latency_ms must be non-negative; got \(value)")
            }
        }
    }

    // MARK: - §3 Drawer query emissions

    @Suite("§3 LocusKitTelemetry — drawer query emissions")
    struct DrawerQueryEmissionTests {

        /// drawersIn(wing:) emits query_latency_ms and query_result_count.
        @Test("drawersIn(wing:) emits query metrics when enabled")
        func drawersInWingEmitsQueryMetrics() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                try await store.addDrawer(sampleDrawer(id: "q1"), now: Date(timeIntervalSince1970: 1_000_000))
                try await store.addDrawer(sampleDrawer(id: "q2"), now: Date(timeIntervalSince1970: 1_000_001))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let results = try await store.drawersIn(wing: "wing-tel")

                // Filter by estate tag to isolate from concurrent test emissions.
                let latencyCount = sink.count(named: "locuskit.drawer.query_latency_ms", forEstate: estateTag)
                let resultCountCount = sink.count(named: "locuskit.drawer.query_result_count", forEstate: estateTag)
                #expect(latencyCount == 1,
                    "drawersIn(wing:) must emit exactly 1 query_latency_ms for this estate; got \(latencyCount)")
                #expect(resultCountCount == 1,
                    "drawersIn(wing:) must emit exactly 1 query_result_count for this estate")

                // result_count value must match actual drawer count returned.
                guard let countSample = sink.metrics(named: "locuskit.drawer.query_result_count", forEstate: estateTag).first,
                      case let .metric(_, value, _, _) = countSample else {
                    Issue.record("no estate-filtered query_result_count metric emitted")
                    return
                }
                #expect(value == Double(results.count),
                    "query_result_count must equal actual result count; got \(value), expected \(results.count)")
            }
        }

        /// drawersIn(wing:) result_count tag includes "query":"wing".
        @Test("drawersIn(wing:) metric carries query=wing tag")
        func drawersInWingCarriesQueryTag() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                _ = try await store.drawersIn(wing: "wing-tel")

                guard let sample = sink.metrics(named: "locuskit.drawer.query_result_count", forEstate: estateTag).first,
                      case let .metric(_, _, tags, _) = sample else {
                    Issue.record("no estate-filtered query_result_count metric emitted")
                    return
                }
                #expect(tags["query"] == "wing",
                    "drawersIn(wing:) must tag query='wing'; got \(tags["query"] ?? "nil")")
            }
        }

        /// allDrawers emits query_result_count with query="all".
        @Test("allDrawers emits query_result_count with query=all tag")
        func allDrawersEmitsQueryMetrics() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                try await store.addDrawer(sampleDrawer(id: "all1"), now: Date(timeIntervalSince1970: 1_000_000))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                _ = try await store.allDrawers()

                guard let sample = sink.metrics(named: "locuskit.drawer.query_result_count", forEstate: estateTag).first,
                      case let .metric(_, _, tags, _) = sample else {
                    Issue.record("no estate-filtered query_result_count metric emitted for allDrawers")
                    return
                }
                #expect(tags["query"] == "all",
                    "allDrawers must tag query='all'; got \(tags["query"] ?? "nil")")
            }
        }
    }

    // MARK: - §4 KGFact emissions

    @Suite("§4 LocusKitTelemetry — KGFact emissions")
    struct KGFactEmissionTests {

        /// addKGFact emits add_count when monitoring is ON.
        @Test("addKGFact emits kgfact.add_count when enabled")
        func addKGFactEmitsAddCount() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                // Insert the drawer first (monitoring off for setup).
                try await store.addDrawer(sampleDrawer(), now: Date(timeIntervalSince1970: 1_000_000))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                try await store.addKGFact(sampleKGFact())

                let addCount = sink.count(named: "locuskit.kgfact.add_count", forEstate: estateTag)
                #expect(addCount == 1,
                    "addKGFact must emit exactly 1 kgfact.add_count for this estate; got \(addCount)")
            }
        }

        /// kgFacts(forDrawerID:) emits query_result_count with query="drawer".
        @Test("kgFacts(forDrawerID:) emits query_result_count with query=drawer")
        func kgFactsForDrawerEmitsResultCount() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                let drawer = sampleDrawer()
                try await store.addDrawer(drawer, now: Date(timeIntervalSince1970: 1_000_000))
                try await store.addKGFact(sampleKGFact(id: "f1"))
                try await store.addKGFact(sampleKGFact(id: "f2"))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let facts = try await store.kgFacts(forDrawerID: TestStorage.tid("d1"))

                guard let sample = sink.metrics(named: "locuskit.kgfact.query_result_count", forEstate: estateTag).first,
                      case let .metric(_, value, tags, _) = sample else {
                    Issue.record("no estate-filtered kgfact.query_result_count emitted")
                    return
                }
                #expect(tags["query"] == "drawer",
                    "kgFacts(forDrawerID:) must tag query='drawer'; got \(tags["query"] ?? "nil")")
                #expect(value == Double(facts.count),
                    "query_result_count must equal fact count; got \(value), expected \(facts.count)")
            }
        }

        /// allKGFacts emits query_result_count with query="all".
        @Test("allKGFacts emits query_result_count with query=all")
        func allKGFactsEmitsResultCountAll() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                let drawer = sampleDrawer()
                try await store.addDrawer(drawer, now: Date(timeIntervalSince1970: 1_000_000))
                try await store.addKGFact(sampleKGFact(id: "g1"))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                _ = try await store.allKGFacts()

                guard let sample = sink.metrics(named: "locuskit.kgfact.query_result_count", forEstate: estateTag).first,
                      case let .metric(_, _, tags, _) = sample else {
                    Issue.record("no estate-filtered kgfact.query_result_count emitted for allKGFacts")
                    return
                }
                #expect(tags["query"] == "all",
                    "allKGFacts must tag query='all'; got \(tags["query"] ?? "nil")")
            }
        }
    }

    // MARK: - §5 Tunnel emissions

    @Suite("§5 LocusKitTelemetry — tunnel emissions")
    struct TunnelEmissionTests {

        /// addTunnel emits add_count when monitoring is ON.
        @Test("addTunnel emits tunnel.add_count when enabled")
        func addTunnelEmitsAddCount() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                let d1 = sampleDrawer(id: "t1")
                let d2 = sampleDrawer(id: "t2")
                try await store.addDrawer(d1, now: Date(timeIntervalSince1970: 1_000_000))
                try await store.addDrawer(d2, now: Date(timeIntervalSince1970: 1_000_001))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let tunnel = sampleTunnel(sourceId: "t1", targetId: "t2")
                try await store.addTunnel(tunnel)

                let addCount = sink.count(named: "locuskit.tunnel.add_count", forEstate: estateTag)
                #expect(addCount == 1,
                    "addTunnel must emit exactly 1 tunnel.add_count for this estate; got \(addCount)")
            }
        }

        /// Two addTunnel calls on the same store emit two add_count metrics.
        @Test("two addTunnel calls emit two tunnel.add_count metrics")
        func twoTunnelCallsEmitTwo() async throws {
            try await withIntellectusLock {
                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                let d1 = sampleDrawer(id: "u1")
                let d2 = sampleDrawer(id: "u2")
                let d3 = sampleDrawer(id: "u3")
                try await store.addDrawer(d1, now: Date(timeIntervalSince1970: 1_000_000))
                try await store.addDrawer(d2, now: Date(timeIntervalSince1970: 1_000_001))
                try await store.addDrawer(d3, now: Date(timeIntervalSince1970: 1_000_002))

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                try await store.addTunnel(sampleTunnel(sourceId: "u1", targetId: "u2"))
                try await store.addTunnel(sampleTunnel(sourceId: "u2", targetId: "u3"))

                let tunnelCount = sink.count(named: "locuskit.tunnel.add_count", forEstate: estateTag)
                #expect(tunnelCount == 2,
                    "two addTunnel calls must emit 2 tunnel.add_count for estate \(estateTag); got \(tunnelCount)")
            }
        }
    }

    // MARK: - §6 Conformance gate

    @Suite("§6 LocusKitTelemetry — conformance (results unaffected by telemetry)")
    struct ConformanceTests {

        /// addDrawer result is identical with monitoring ON and OFF.
        @Test("addDrawer result is identical with monitoring on vs off")
        func addDrawerResultIdenticalWithAndWithoutTelemetry() async throws {
            try await withIntellectusLock {
                let drawer = sampleDrawer(id: "conf1")
                let now = Date(timeIntervalSince1970: 1_000_000)

                // OFF path.
                Intellectus.setEnabled(false)
                let storeOff = try await makeInMemoryStore()
                try await storeOff.addDrawer(drawer, now: now)
                let rowOff = try await storeOff.getDrawer(id: TestStorage.tid("conf1"))

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let storeOn = try await makeInMemoryStore()
                try await storeOn.addDrawer(drawer, now: now)
                let rowOn = try await storeOn.getDrawer(id: TestStorage.tid("conf1"))
                defer { resetIntellectus() }

                // Rows must be identical.
                #expect(rowOff?.id == rowOn?.id,
                    "drawer id must be identical regardless of monitoring state")
                #expect(rowOff?.content == rowOn?.content,
                    "drawer content must be identical regardless of monitoring state")
                #expect(rowOff?.adjectiveBitmap == rowOn?.adjectiveBitmap,
                    "drawer adjectiveBitmap must be identical regardless of monitoring state")
                // ON path emitted metrics (proves the on-path was active).
                #expect(sink.count > 0, "monitoring-on path must emit at least one metric")
            }
        }

        /// drawersIn result is identical with monitoring ON and OFF.
        @Test("drawersIn result is identical with monitoring on vs off")
        func drawersInResultIdentical() async throws {
            try await withIntellectusLock {
                let now = Date(timeIntervalSince1970: 1_000_000)

                // OFF path.
                Intellectus.setEnabled(false)
                let storeOff = try await makeInMemoryStore()
                try await storeOff.addDrawer(sampleDrawer(id: "cr1"), now: now)
                try await storeOff.addDrawer(sampleDrawer(id: "cr2"), now: now)
                let rowsOff = try await storeOff.drawersIn(wing: "wing-tel")

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let storeOn = try await makeInMemoryStore()
                try await storeOn.addDrawer(sampleDrawer(id: "cr1"), now: now)
                try await storeOn.addDrawer(sampleDrawer(id: "cr2"), now: now)
                let rowsOn = try await storeOn.drawersIn(wing: "wing-tel")
                defer { resetIntellectus() }

                #expect(rowsOff.count == rowsOn.count,
                    "drawersIn count must be identical regardless of monitoring state")
                // Sort both before comparing: SQLite row order across two
                // separate in-memory stores is not guaranteed to be identical.
                // The invariant is set equality, not sequence equality.
                #expect(Set(rowsOff.map(\.id)) == Set(rowsOn.map(\.id)),
                    "drawersIn ids must be identical regardless of monitoring state")
                #expect(sink.count > 0, "monitoring-on path must emit at least one metric")
            }
        }
    }

    // MARK: - §7 Verb-layer event emissions

    @Suite("§7 LocusKitTelemetry — verb-layer event emissions")
    struct EventEmissionTests {

        /// Drawer capture emits exactly one StatSample.event with kind=.capture,
        /// nounType=0 (drawer), matching rowID and estate UUID.
        @Test("capture(CaptureFrame) emits StatSample.event with kind=.capture")
        func capture_drawer_emits_capture_event() async throws {
            try await withIntellectusLock {
                let estate = try await makeEstate()
                let estateTag = await estate.estateUUID.uuidString

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let frame = CaptureFrame(
                    content: "tel-test-content",
                    channel: .typed,
                    room: "tel-room",
                    latticeAnchor: LatticeAnchor(udcCode: "004"),
                    addedBy: "tel-test",
                    embeddingModelID: "test-model-v1"
                )
                let drawer = try await estate.capture(frame)

                let receivedEvents = sink.events(forEstate: estateTag)
                #expect(receivedEvents.count == 1,
                    "capture(CaptureFrame) must emit exactly 1 .event sample; got \(receivedEvents.count)")

                guard let firstEvent = receivedEvents.first else {
                    Issue.record("no .event sample was emitted for estate \(estateTag)")
                    return
                }
                guard case let .event(kind, nounType, rowID, estateStr, ts) = firstEvent else {
                    Issue.record("received sample is not an .event variant: \(firstEvent)")
                    return
                }
                #expect(kind == .capture,
                    "event kind must be .capture; got \(kind)")
                #expect(nounType == Int(NounType.drawer.rawValue),
                    "nounType must be \(Int(NounType.drawer.rawValue)) (drawer); got \(nounType)")
                #expect(rowID == drawer.id,
                    "rowID must match drawer.id; got \(rowID), expected \(drawer.id)")
                #expect(estateStr == estateTag,
                    "estate must match estate UUID; got \(estateStr)")
                #expect(abs(ts - Date().timeIntervalSince1970) < 2.0,
                    "ts must be within 2 seconds of now")
            }
        }

        /// Tunnel capture emits exactly one StatSample.event with kind=.capture,
        /// nounType=1 (tunnel), matching rowID and estate UUID.
        @Test("capture(TunnelCaptureFrame) emits StatSample.event with kind=.capture")
        func capture_tunnel_emits_capture_event() async throws {
            try await withIntellectusLock {
                let estate = try await makeEstate()
                let estateTag = await estate.estateUUID.uuidString

                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let frame = TunnelCaptureFrame(
                    sourceWing: "wing_a", sourceRoom: "room_1",
                    targetWing: "wing_b", targetRoom: "room_2",
                    label: "relates_to",
                    addedBy: "tel-test"
                )
                let tunnel = try await estate.capture(frame)

                let receivedEvents = sink.events(forEstate: estateTag)
                #expect(receivedEvents.count == 1,
                    "capture(TunnelCaptureFrame) must emit exactly 1 .event sample; got \(receivedEvents.count)")

                guard let firstEvent = receivedEvents.first else {
                    Issue.record("no .event sample was emitted for estate \(estateTag)")
                    return
                }
                guard case let .event(kind, nounType, rowID, estateStr, _) = firstEvent else {
                    Issue.record("received sample is not an .event variant: \(firstEvent)")
                    return
                }
                #expect(kind == .capture,
                    "event kind must be .capture; got \(kind)")
                #expect(nounType == Int(NounType.tunnel.rawValue),
                    "nounType must be \(Int(NounType.tunnel.rawValue)) (tunnel); got \(nounType)")
                #expect(rowID == tunnel.id,
                    "rowID must match tunnel.id; got \(rowID), expected \(tunnel.id)")
                #expect(estateStr == estateTag,
                    "estate must match estate UUID; got \(estateStr)")
            }
        }
    }

    // MARK: - §8 Write-gate telemetry

    @Suite("§8 LocusKitTelemetry — write-gate emit")
    struct WriteGateTelemetryTests {

        // Forbidden adjective bitmap: secret (48 << 6 = 0xC00) | exportable (32 << 12 = 0x20000).
        // AuditGate.admit() returns .failure for this combination per I-22.
        private static let forbiddenBitmap: Int64 = 0x20C00

        /// Successful addDrawer emits exactly one gate.admit_count metric when monitoring is ON.
        @Test("gateAdmit emitted on successful addDrawer when monitoring ON")
        func gateAdmitEmittedOnSuccess() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                try await store.addDrawer(sampleDrawer(), now: Date(timeIntervalSince1970: 1_000_000))

                let admits = sink.count(named: "locuskit.gate.admit_count", forEstate: estateTag)
                #expect(admits == 1,
                    "addDrawer must emit 1 gate.admit_count for estate \(estateTag); got \(admits)")
            }
        }

        /// When monitoring is OFF, gate.admit_count is not emitted.
        @Test("gateAdmit NOT emitted when monitoring OFF")
        func gateAdmitSilentWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString
                try await store.addDrawer(sampleDrawer(), now: Date(timeIntervalSince1970: 1_000_000))

                let admits = sink.count(named: "locuskit.gate.admit_count", forEstate: estateTag)
                #expect(admits == 0,
                    "gate.admit_count must not emit when monitoring is disabled; got \(admits)")
            }
        }

        /// A drawer with the I-22-violating bitmap causes AuditGate to reject it;
        /// gate.reject_count is emitted before the throw when monitoring is ON.
        @Test("gateReject emitted on forbidden-bitmap addDrawer when monitoring ON")
        func gateRejectEmittedOnForbiddenCapture() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let store = try await makeInMemoryStore()
                let estateTag = await store.estateUuid.uuidString

                // secret (48 << 6) | exportable (32 << 12): rejected by AuditGate I-22.
                let forbidden = Drawer(
                    id: TestStorage.tid("forbidden-gate-tel"),
                    content: "gate reject telemetry test",
                    wing: "wing-tel",
                    room: "room-tel",
                    addedBy: "newton",
                    filedAt: Date(timeIntervalSince1970: 1_000_000),
                    embeddingModelID: "test-model-v1",
                    provenance: 0,
                    adjectiveBitmap: Self.forbiddenBitmap,
                    operationalBitmap: 0
                )
                do {
                    try await store.addDrawer(forbidden, now: Date(timeIntervalSince1970: 1_000_000))
                    Issue.record("expected LocusKitError.invalidContent for forbidden bitmap")
                } catch LocusKitError.invalidContent {
                    // expected — gate rejected the write
                }

                let rejects = sink.count(named: "locuskit.gate.reject_count", forEstate: estateTag)
                #expect(rejects == 1,
                    "gate.reject_count must fire after AuditGate rejection; got \(rejects)")
            }
        }
    }
}
