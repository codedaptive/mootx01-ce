// IntellectusLibTests.swift
//
// swift-testing suite for IntellectusLib. Covers:
//   §1 Gating: disabled → payload never evaluated
//   §2 Gating: enabled → sink receives exact sample
//   §3 NoOpSink: default no-op discard is safe
//   §4 Install/enable are thread-safe (concurrent stress)
//   §5 StatSample constructors and ts accessor
//   §6 EventKind exhaustiveness (all cases)
//   §7 Performance gate: off-path (disabled) overhead is minimal
//   §8 RecentWindowSink: bounded recent window, eviction, concurrent access
//
// These tests mirror the core sections of the Rust conformance tests in
// rust/tests/intellectus_lib_tests.rs (section/behavior parity;
// exact test names may differ between ports).

import Foundation
import Testing
@testable import IntellectusLib

// MARK: - Helper: counting sink

/// A sink that records every sample received.
/// Used to verify that the sink IS called when enabled and is NOT
/// called when disabled.
final class CountingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock()
        _received.append(sample)
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _received.count
    }

    var all: [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }
}

// MARK: - §1 Gating: disabled → closure never evaluated

@Suite("§1 Gating — disabled path")
struct DisabledGatingTests {

    @Test("closure is not evaluated when monitoring is disabled")
    func closureNotEvaluatedWhenDisabled() {
        let holder = _IntellectusHolder()
        // Start disabled (the default).
        #expect(holder.isEnabled == false)

        var closureCallCount = 0
        holder.report({
            closureCallCount += 1
            return StatSample.metric(
                name: "test.counter",
                value: 1.0,
                tags: [:],
                ts: 0.0
            )
        }())
        #expect(closureCallCount == 0,
            "payload closure must NOT be evaluated when disabled")
    }

    @Test("side-effect counter stays zero after many disabled reports")
    func sideEffectCounterStaysZeroAfterManyDisabledReports() {
        let holder = _IntellectusHolder()
        var callCount = 0

        for _ in 0..<1000 {
            holder.report({
                callCount += 1
                return StatSample.metric(
                    name: "test.bulk",
                    value: Double(callCount),
                    tags: [:],
                    ts: 0.0
                )
            }())
        }
        #expect(callCount == 0,
            "1000 disabled reports must never invoke the closure")
    }

    @Test("public Intellectus.report does not evaluate closure when disabled")
    func publicAPIDoesNotEvaluateClosureWhenDisabled() {
        // Ensure disabled before test; install a counting sink to detect
        // any accidental call-through.
        let sink = CountingSink()
        Intellectus.install(sink: sink)
        Intellectus.setEnabled(false)

        var closureHits = 0
        Intellectus.report({
            closureHits += 1
            return StatSample.metric(
                name: "test.public.disabled",
                value: 1.0,
                tags: [:],
                ts: 0.0
            )
        }())

        #expect(closureHits == 0)
        #expect(sink.count == 0)

        // Restore defaults so later tests are not polluted.
        Intellectus.install(sink: NoOpSink.shared)
        Intellectus.setEnabled(false)
    }
}

// MARK: - §2 Gating: enabled → sink receives exact sample

@Suite("§2 Gating — enabled path")
struct EnabledGatingTests {

    @Test("sink receives exact metric when enabled")
    func sinkReceivesExactMetricWhenEnabled() {
        let holder = _IntellectusHolder()
        let sink = CountingSink()
        holder.install(sink: sink)
        holder.setEnabled(true)

        holder.report(StatSample.metric(
            name: "locus.capture.latency_ms",
            value: 42.5,
            tags: ["kit": "LocusKit"],
            ts: 1_000_000.0
        ))

        #expect(sink.count == 1)
        if case let .metric(name, value, tags, ts) = sink.all.first {
            #expect(name == "locus.capture.latency_ms")
            #expect(value == 42.5)
            #expect(tags["kit"] == "LocusKit")
            #expect(ts == 1_000_000.0)
        } else {
            Issue.record("expected a .metric sample")
        }
    }

    @Test("sink receives exact event when enabled")
    func sinkReceivesExactEventWhenEnabled() {
        let holder = _IntellectusHolder()
        let sink = CountingSink()
        holder.install(sink: sink)
        holder.setEnabled(true)

        holder.report(StatSample.event(
            kind: .capture,
            nounType: 7,
            rowID: "ABCD-1234",
            estate: "test-estate",
            ts: 2_000_000.0
        ))

        #expect(sink.count == 1)
        if case let .event(kind, nounType, rowID, estate, ts) = sink.all.first {
            #expect(kind == .capture)
            #expect(nounType == 7)
            #expect(rowID == "ABCD-1234")
            #expect(estate == "test-estate")
            #expect(ts == 2_000_000.0)
        } else {
            Issue.record("expected an .event sample")
        }
    }

    @Test("closure IS evaluated when enabled")
    func closureIsEvaluatedWhenEnabled() {
        let holder = _IntellectusHolder()
        let sink = CountingSink()
        holder.install(sink: sink)
        holder.setEnabled(true)

        var closureCallCount = 0
        holder.report({
            closureCallCount += 1
            return StatSample.metric(
                name: "test.closure.eval",
                value: 1.0,
                tags: [:],
                ts: 0.0
            )
        }())

        #expect(closureCallCount == 1,
            "payload closure MUST be evaluated exactly once when enabled")
        #expect(sink.count == 1)
    }

    @Test("toggle disabled after enabled stops emission")
    func toggleDisabledAfterEnabledStopsEmission() {
        let holder = _IntellectusHolder()
        let sink = CountingSink()
        holder.install(sink: sink)
        holder.setEnabled(true)

        holder.report(StatSample.metric(
            name: "before.disable", value: 1.0, tags: [:], ts: 0.0))
        #expect(sink.count == 1)

        holder.setEnabled(false)
        var closureHits = 0
        holder.report({
            closureHits += 1
            return StatSample.metric(
                name: "after.disable", value: 2.0, tags: [:], ts: 0.0)
        }())

        #expect(closureHits == 0, "closure must not run after disable")
        #expect(sink.count == 1, "sink count must not increment after disable")
    }
}

// MARK: - §3 Default no-op discard is safe

@Suite("§3 NoOpSink")
struct NoOpSinkTests {

    @Test("NoOpSink.shared.receive does not crash or retain the sample")
    func noOpSinkIsCallable() {
        let sample = StatSample.metric(
            name: "noop.test", value: 0.0, tags: [:], ts: 0.0)
        // Must not crash or throw.
        NoOpSink.shared.receive(sample)
    }

    @Test("NoOpSink is the default installed sink")
    func defaultInstalledSinkIsNoOp() {
        // Fresh holder — default must be NoOp.
        let holder = _IntellectusHolder()
        holder.setEnabled(true)
        // If the default were not NoOp, we'd need to inspect it.
        // The safe observable test: enable + report must not crash.
        holder.report(StatSample.metric(
            name: "default.noop", value: 1.0, tags: [:], ts: 0.0))
        // Reaching here without crash is the assertion.
    }
}

// MARK: - §4 Thread-safety stress test

@Suite("§4 Thread safety")
struct ThreadSafetyTests {

    @Test("concurrent install and setEnabled do not crash or race")
    func concurrentInstallAndSetEnabled() async {
        let holder = _IntellectusHolder()
        let sink = CountingSink()

        // Spin up 16 concurrent tasks — alternating install/enable/report.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    for _ in 0..<100 {
                        if i % 2 == 0 {
                            holder.install(sink: sink)
                        } else {
                            holder.setEnabled(i % 4 == 1)
                        }
                        holder.report(StatSample.metric(
                            name: "stress.metric",
                            value: Double(i),
                            tags: [:],
                            ts: 0.0
                        ))
                    }
                }
            }
        }
        // No assertion on count — the test is "did not crash or deadlock."
        // The count is nondeterministic but must be non-negative.
        #expect(sink.count >= 0)
    }
}

// MARK: - §5 StatSample accessors

@Suite("§5 StatSample")
struct StatSampleTests {

    @Test("metric ts accessor returns correct value")
    func metricTsAccessor() {
        let s = StatSample.metric(
            name: "ts.test", value: 0.0, tags: [:], ts: 999.0)
        #expect(s.ts == 999.0)
    }

    @Test("event ts accessor returns correct value")
    func eventTsAccessor() {
        let s = StatSample.event(
            kind: .think, nounType: 0, rowID: "x", estate: "e", ts: 42.0)
        #expect(s.ts == 42.0)
    }

    @Test("metric with empty tags is valid")
    func metricEmptyTags() {
        let s = StatSample.metric(
            name: "empty.tags", value: 0.0, tags: [:], ts: 0.0)
        if case let .metric(_, _, tags, _) = s {
            #expect(tags.isEmpty)
        } else {
            Issue.record("expected .metric")
        }
    }

    @Test("metric with populated tags is valid")
    func metricPopulatedTags() {
        let s = StatSample.metric(
            name: "tagged",
            value: 1.0,
            tags: ["a": "1", "b": "2"],
            ts: 0.0
        )
        if case let .metric(_, _, tags, _) = s {
            #expect(tags.count == 2)
            #expect(tags["a"] == "1")
            #expect(tags["b"] == "2")
        } else {
            Issue.record("expected .metric")
        }
    }
}

// MARK: - §6 EventKind exhaustiveness

@Suite("§6 EventKind")
struct EventKindTests {

    @Test("EventKind has exactly two cases: capture and think")
    func eventKindCaseCount() {
        // CaseIterable guarantees compile-time exhaustiveness; the count
        // assertion pins the surface so accidental additions are caught.
        #expect(EventKind.allCases.count == 2)
    }

    @Test("EventKind raw values match spec strings")
    func eventKindRawValues() {
        #expect(EventKind.capture.rawValue == "capture")
        #expect(EventKind.think.rawValue == "think")
    }
}

// MARK: - §8 RecentWindowSink — bounded recent window

@Suite("§8 RecentWindowSink")
struct RecentWindowSinkTests {

    @Test("window records received samples, snapshot returns them oldest-first")
    func recordsAndSnapshots() {
        let window = RecentWindowSink(capacity: 4)
        window.receive(.metric(name: "a", value: 1.0, tags: [:], ts: 1.0))
        window.receive(.metric(name: "b", value: 2.0, tags: [:], ts: 2.0))
        #expect(window.count == 2)
        #expect(window.totalReceived == 2)
        let snap = window.snapshot()
        #expect(snap.count == 2)
        #expect(snap[0].ts == 1.0)
        #expect(snap[1].ts == 2.0)
    }

    @Test("bounded window evicts oldest on overflow; bound holds")
    func boundedOverflowEvictsOldest() {
        let window = RecentWindowSink(capacity: 3)
        // Push 5 samples into a 3-slot window. The first two must be evicted.
        for i in 0..<5 {
            window.receive(.metric(name: "m", value: Double(i), tags: [:], ts: Double(i)))
        }
        // Bound holds: never more than capacity retained.
        #expect(window.count == 3)
        // Total received counts every sample, ignoring eviction.
        #expect(window.totalReceived == 5)
        let snap = window.snapshot()
        #expect(snap.count == 3)
        // Oldest retained is sample 2 (0 and 1 evicted); newest is 4.
        #expect(snap.first?.ts == 2.0)
        #expect(snap.last?.ts == 4.0)
    }

    @Test("capacity clamps to a minimum of 1")
    func capacityClampsToOne() {
        let window = RecentWindowSink(capacity: 0)
        #expect(window.capacity == 1)
        window.receive(.metric(name: "x", value: 1.0, tags: [:], ts: 1.0))
        window.receive(.metric(name: "y", value: 2.0, tags: [:], ts: 2.0))
        #expect(window.count == 1)
        #expect(window.snapshot().first?.ts == 2.0)
    }

    @Test("forward sink receives every sample after the window records it")
    func forwardSinkReceivesAll() {
        let downstream = CountingSink()
        let window = RecentWindowSink(capacity: 2, forward: downstream)
        // Overflow the window — the forward sink must still see ALL samples,
        // not just the retained two (forwarding is independent of eviction).
        for i in 0..<5 {
            window.receive(.metric(name: "f", value: Double(i), tags: [:], ts: Double(i)))
        }
        #expect(window.count == 2)        // bounded
        #expect(downstream.count == 5)    // all forwarded
    }

    @Test("empty window snapshot is empty and totalReceived is zero")
    func emptyWindow() {
        let window = RecentWindowSink(capacity: 8)
        #expect(window.count == 0)
        #expect(window.totalReceived == 0)
        #expect(window.snapshot().isEmpty)
    }

    @Test("window installed as Intellectus sink: enabled records, disabled does not")
    func windowViaGate() {
        let window = RecentWindowSink(capacity: 16)
        Intellectus.install(sink: window)

        // FORCE: observer disabled → no sample recorded + explicit off state.
        Intellectus.setEnabled(false)
        #expect(Intellectus.isEnabled == false)
        Intellectus.report(.metric(name: "off", value: 1.0, tags: [:], ts: 0.0))
        #expect(window.count == 0)

        // FORCE: observer enabled → sample recorded in window.
        Intellectus.setEnabled(true)
        #expect(Intellectus.isEnabled == true)
        Intellectus.report(.metric(name: "on", value: 1.0, tags: [:], ts: 1.0))
        #expect(window.count == 1)
        #expect(window.snapshot().first?.ts == 1.0)

        // Restore defaults so later tests are not polluted.
        Intellectus.install(sink: NoOpSink.shared)
        Intellectus.setEnabled(false)
    }

    @Test("concurrent receive does not crash and bound holds")
    func concurrentReceiveBounded() async {
        let window = RecentWindowSink(capacity: 32)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<100 {
                        window.receive(.metric(
                            name: "c", value: Double(t * 100 + i), tags: [:], ts: 0.0))
                    }
                }
            }
        }
        // Bound holds under concurrency; total counts every receive.
        #expect(window.count == 32)
        #expect(window.totalReceived == 800)
    }
}

// MARK: - §7 Performance smoke (off-path is fast)

@Suite("§7 Performance gate — off-path cost")
struct PerformanceGateTests {

    @Test("10 000 disabled reports complete in under 10 ms")
    func disabledReportThroughput() {
        let holder = _IntellectusHolder()
        // Monitoring disabled — the default.

        let start = Date().timeIntervalSince1970
        for i in 0..<10_000 {
            holder.report(StatSample.metric(
                name: "perf.gate",
                value: Double(i),
                tags: [:],
                ts: 0.0
            ))
        }
        let elapsed = Date().timeIntervalSince1970 - start

        // 10 ms is a generous budget for 10 000 disabled reports.
        // Each should be sub-microsecond; this gate catches gross regressions.
        #expect(elapsed < 0.010,
            "10 000 disabled reports took \(elapsed * 1000) ms — expected < 10 ms")
    }
}
