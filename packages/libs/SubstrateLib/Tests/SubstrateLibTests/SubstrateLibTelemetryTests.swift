// SubstrateLibTelemetryTests.swift
//
// Tests for the IntellectusLib telemetry emission added to SubstrateLib.
// Mirrors the Rust suite in rust/tests/substrate_lib_telemetry_tests.rs.
//
// ## Test isolation — CRITICAL
//
// `Intellectus` is a process-wide singleton. Swift Testing runs suites
// concurrently by default. Other test suites in this module (VerbsTests,
// AuditGateTests, etc.) call `substrate.capture`, `substrate.mutate`,
// etc., which now emit into the global sink whenever monitoring is
// enabled. If a telemetry test enables monitoring while another suite
// is concurrently calling Substrate verbs with the default `ts: 0.0`,
// those emissions arrive in the globally-installed sink and corrupt
// exact-count assertions.
//
// Isolation strategy — ts-filtered sink:
//
//   SubstrateLib has no per-estate UUID (unlike LocusKit). Instead, each
//   telemetry test assigns a unique sentinel epoch-seconds value as its
//   `ts` probe. `TsFilteredSink` records only samples whose `ts` field
//   matches the test's sentinel. Other tests and parallel verb calls use
//   `ts: 0.0` (the default) and are silently discarded by the filter.
//
//   All tests are nested under a `.serialized` parent suite to prevent
//   two telemetry tests from writing to the global singleton simultaneously.
//   Within each sub-suite, tests also carry `.serialized` because each
//   test installs + tears down the global state.
//
// Verification requirement (mission): run `swift test` 5 consecutive
// times and verify all 5 pass.

import Foundation
import Testing
@testable import SubstrateLib
import SubstrateTypes
import IntellectusLib

// MARK: - Helper: ts-filtered capturing sink

/// A `StatsSink` that records only `StatSample` values whose `ts` field
/// exactly equals the expected sentinel timestamp.
///
/// Emissions from other tests (which use `ts: 0.0` or their own unique
/// sentinel) are silently discarded. This makes exact-count assertions
/// immune to parallelism from concurrently-running non-telemetry suites.
private final class TsFilteredSink: StatsSink, @unchecked Sendable {
    private let _lock = NSLock()
    private var _samples: [StatSample] = []
    private let _expectedTs: Double

    init(ts sentinel: Double) {
        _expectedTs = sentinel
    }

    func receive(_ sample: StatSample) {
        // Filter: only record samples with the sentinel ts.
        guard sample.ts == _expectedTs else { return }
        _lock.withLock { _samples.append(sample) }
    }

    var count: Int {
        _lock.withLock { _samples.count }
    }

    func all() -> [StatSample] {
        _lock.withLock { _samples }
    }

    func withName(_ name: String) -> [StatSample] {
        _lock.withLock {
            _samples.filter {
                if case let .metric(n, _, _, _) = $0 { return n == name }
                return false
            }
        }
    }
}

// MARK: - Helper: Substrate fixture factory

/// Build a minimal valid `Substrate` for telemetry tests.
private func makeTelemetrySubstrate() -> Substrate {
    let hlc = HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 99)
    return Substrate(estateUuid: UUID(), hlc: hlc)
}

/// Build a minimal `LatticeAnchor` for test rows.
/// udcCode 4 (non-zero, therefore non-null) is a valid anchor.
private func testAnchor() -> LatticeAnchor {
    LatticeAnchor(udcCode: 4, qidPointer: 1)
}

/// Build a minimal `Fingerprint256` for test rows.
private func testFingerprint() -> Fingerprint256 {
    Fingerprint256(block0: 0xCAFEBABE, block1: 0xDEADBEEF, block2: 0, block3: 0)
}

// MARK: - Top-level serialised wrapper
//
// All telemetry tests are nested inside this struct. `.serialized` ensures
// they run one at a time: no two telemetry tests share the global Intellectus
// state simultaneously. The ts-filtered sink additionally isolates each test
// from concurrent non-telemetry verb calls in other suites.

@Suite("SubstrateLibTelemetry — all telemetry tests (serialized)", .serialized)
struct SubstrateLibTelemetryTests {

    // MARK: - §1 Disabled gate — capture

    @Suite("§1 disabled gate (capture)", .serialized)
    struct DisabledCapture {

        /// With monitoring OFF (the default), capture must not emit any metric.
        /// Sentinel ts: 100_001.0 — unique per test, never used by non-telemetry tests.
        @Test("capture emits no metrics when monitoring is disabled")
        func captureEmitsNoMetricsWhenDisabled() {
            let sentinelTs = 100_001.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            var substrate = makeTelemetrySubstrate()
            _ = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(),
                ts: sentinelTs
            )

            #expect(sink.count == 0,
                "capture must not emit when monitoring is disabled; got \(sink.count)")
        }

        /// Functional result must be correct regardless of monitoring state.
        /// Sentinel ts: 100_002.0
        @Test("capture returns a valid RowId when monitoring is disabled")
        func captureReturnsValidRowIdWhenDisabled() {
            let sentinelTs = 100_002.0
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            var substrate = makeTelemetrySubstrate()
            let result = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(),
                ts: sentinelTs
            )

            guard case .success(let rowId) = result else {
                Issue.record("expected .success from capture")
                return
            }
            #expect(substrate.rows[rowId] != nil,
                "captured row must be present in the substrate")
        }
    }

    // MARK: - §2 Enabled gate — capture

    @Suite("§2 enabled gate (capture)", .serialized)
    struct EnabledCapture {

        /// With monitoring ON, capture must emit exactly one verb.capture_count.
        /// Sentinel ts: 200_001.0
        @Test("capture emits verb.capture_count when monitoring is enabled")
        func captureEmitsVerbCaptureCountWhenEnabled() {
            let sentinelTs = 200_001.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            var substrate = makeTelemetrySubstrate()
            _ = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(),
                ts: sentinelTs
            )

            let captureSamples = sink.withName(SubstrateLibMetric.verbCaptureCount)
            #expect(captureSamples.count == 1,
                "exactly one verb.capture_count expected; got \(captureSamples.count)")

            if case let .metric(name, value, tags, ts) = captureSamples.first {
                #expect(name == SubstrateLibMetric.verbCaptureCount)
                #expect(value == 1.0,
                    "capture_count value must be 1.0; got \(value)")
                #expect(tags["noun_type"] != nil,
                    "capture_count must carry noun_type tag")
                #expect(ts == sentinelTs,
                    "ts must match sentinel timestamp; got \(ts)")
            } else {
                Issue.record("expected a .metric sample for verb.capture_count")
            }
        }

        /// Two captures must produce exactly two count metrics with the sentinel ts.
        /// Sentinel ts: 200_002.0
        @Test("two captures produce two verb.capture_count metrics")
        func twoCapturesProduceTwoCountMetrics() {
            let sentinelTs = 200_002.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            var substrate = makeTelemetrySubstrate()
            _ = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(),
                ts: sentinelTs
            )
            _ = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(),
                ts: sentinelTs
            )

            let captureSamples = sink.withName(SubstrateLibMetric.verbCaptureCount)
            #expect(captureSamples.count == 2,
                "two captures must produce 2 verb.capture_count metrics; got \(captureSamples.count)")
        }
    }

    // MARK: - §3 Conformance gate — capture

    @Suite("§3 conformance gate (capture)", .serialized)
    struct ConformanceCapture {

        /// Capture result must be byte-identical whether monitoring is on or off.
        /// Sentinel ts: 300_001.0 (enabled path only — disabled uses 0.0 which is filtered)
        @Test("capture result is identical with monitoring enabled vs disabled")
        func captureResultIsIdenticalRegardlessOfMonitoring() {
            // Disabled path — functional result.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
            var substrateOff = makeTelemetrySubstrate()
            let resultOff = substrateOff.capture(
                nounType: .drawer,
                adjectiveBitmap: 0x12, operationalBitmap: 0x34, provenanceBitmap: 0x56,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(), ts: 0.0
            )
            guard case .success(let rowIdOff) = resultOff else {
                Issue.record("disabled-path capture failed"); return
            }
            let rowOff = substrateOff.rows[rowIdOff]!

            // Enabled path — same functional call.
            let sentinelTs = 300_001.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }
            var substrateOn = makeTelemetrySubstrate()
            let resultOn = substrateOn.capture(
                nounType: .drawer,
                adjectiveBitmap: 0x12, operationalBitmap: 0x34, provenanceBitmap: 0x56,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(),
                ts: sentinelTs
            )
            guard case .success(let rowIdOn) = resultOn else {
                Issue.record("enabled-path capture failed"); return
            }
            let rowOn = substrateOn.rows[rowIdOn]!

            // Functional fields must be identical.
            #expect(rowOff.adjectiveBitmap == rowOn.adjectiveBitmap,
                "adjectiveBitmap must be identical regardless of monitoring state")
            #expect(rowOff.operationalBitmap == rowOn.operationalBitmap,
                "operationalBitmap must be identical regardless of monitoring state")
            #expect(rowOff.provenanceBitmap == rowOn.provenanceBitmap,
                "provenanceBitmap must be identical regardless of monitoring state")
            #expect(rowOff.nounType == rowOn.nounType,
                "nounType must be identical regardless of monitoring state")
            #expect(rowOff.state == rowOn.state,
                "state must be identical regardless of monitoring state")

            // Prove monitoring ran on the enabled path.
            #expect(sink.count > 0,
                "monitoring path must emit at least one metric; got \(sink.count)")
        }
    }

    // MARK: - §4 Recall telemetry

    @Suite("§4 recall telemetry", .serialized)
    struct RecallTelemetry {

        /// With monitoring OFF, recall must not emit any metric.
        /// Sentinel ts: 400_001.0
        @Test("recall emits no metrics when monitoring is disabled")
        func recallEmitsNoMetricsWhenDisabled() {
            let sentinelTs = 400_001.0
            Intellectus.setEnabled(false)
            var substrate = makeTelemetrySubstrate()
            _ = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(), ts: 0.0
            )

            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            _ = substrate.recall(matching: { _ in true }, ts: sentinelTs)

            #expect(sink.count == 0,
                "recall must not emit when monitoring is disabled; got \(sink.count)")
        }

        /// With monitoring ON, recall must emit verb.recall_count.
        /// Sentinel ts: 400_002.0
        @Test("recall emits verb.recall_count when monitoring is enabled")
        func recallEmitsVerbRecallCountWhenEnabled() {
            let sentinelTs = 400_002.0
            Intellectus.setEnabled(false)
            var substrate = makeTelemetrySubstrate()
            _ = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(), ts: 0.0
            )
            _ = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(), ts: 0.0
            )

            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let rows = substrate.recall(matching: { _ in true }, ts: sentinelTs)

            let recallSamples = sink.withName(SubstrateLibMetric.verbRecallCount)
            #expect(recallSamples.count == 1,
                "exactly one verb.recall_count expected; got \(recallSamples.count)")

            if case let .metric(name, value, tags, ts) = recallSamples.first {
                #expect(name == SubstrateLibMetric.verbRecallCount)
                #expect(value == 1.0, "recall_count value must be 1.0; got \(value)")
                #expect(tags["result_count"] == "\(rows.count)",
                    "result_count tag must match actual result count")
                #expect(ts == sentinelTs,
                    "ts must match sentinel timestamp; got \(ts)")
            } else {
                Issue.record("expected a .metric sample for verb.recall_count")
            }
        }
    }

    // MARK: - §5 Withdraw / expunge / mutate telemetry

    @Suite("§5 mutating verb telemetry (withdraw, expunge, mutate)", .serialized)
    struct MutatingVerbTelemetry {

        /// withdraw emits verb.withdraw_count when enabled.
        /// Sentinel ts: 500_001.0
        @Test("withdraw emits verb.withdraw_count when monitoring is enabled")
        func withdrawEmitsCountWhenEnabled() {
            let sentinelTs = 500_001.0
            Intellectus.setEnabled(false)
            var substrate = makeTelemetrySubstrate()
            let captureResult = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(), ts: 0.0
            )
            guard case .success(let rowId) = captureResult else {
                Issue.record("capture setup failed"); return
            }

            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            _ = substrate.withdraw(rowId: rowId, ts: sentinelTs)

            let samples = sink.withName(SubstrateLibMetric.verbWithdrawCount)
            #expect(samples.count == 1,
                "exactly one verb.withdraw_count expected; got \(samples.count)")
        }

        /// withdraw emits no metrics when disabled.
        /// Sentinel ts: 500_002.0
        @Test("withdraw emits no metrics when monitoring is disabled")
        func withdrawEmitsNoMetricsWhenDisabled() {
            let sentinelTs = 500_002.0
            Intellectus.setEnabled(false)
            var substrate = makeTelemetrySubstrate()
            let captureResult = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(), ts: 0.0
            )
            guard case .success(let rowId) = captureResult else {
                Issue.record("capture setup failed"); return
            }

            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            _ = substrate.withdraw(rowId: rowId, ts: sentinelTs)

            #expect(sink.count == 0,
                "withdraw must not emit when monitoring is disabled; got \(sink.count)")
        }

        /// expunge emits verb.expunge_count when enabled.
        /// Sentinel ts: 500_003.0
        @Test("expunge emits verb.expunge_count when monitoring is enabled")
        func expungeEmitsCountWhenEnabled() {
            let sentinelTs = 500_003.0
            Intellectus.setEnabled(false)
            var substrate = makeTelemetrySubstrate()
            let captureResult = substrate.capture(
                nounType: .drawer,
                adjectiveBitmap: 0, operationalBitmap: 0, provenanceBitmap: 0,
                latticeAnchor: testAnchor(), fingerprint: testFingerprint(), ts: 0.0
            )
            guard case .success(let rowId) = captureResult else {
                Issue.record("capture setup failed"); return
            }

            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            _ = substrate.expunge(rowId: rowId, reason: "test-expunge", ts: sentinelTs)

            let samples = sink.withName(SubstrateLibMetric.verbExpungeCount)
            #expect(samples.count == 1,
                "exactly one verb.expunge_count expected; got \(samples.count)")
        }

        /// mutate emits verb.mutate_count when enabled.
        /// Sentinel ts: 500_004.0
        @Test("mutate emits verb.mutate_count when monitoring is enabled")
        func mutateEmitsCountWhenEnabled() {
            let sentinelTs = 500_004.0
            Intellectus.setEnabled(false)
            var substrate = makeTelemetrySubstrate()
            // Capture a row in pending state (proposal type → pending).
            let captureResult = substrate.capture(
                nounType: .proposal,
                adjectiveBitmap: Int64(RowState.pending.rawValue),
                operationalBitmap: 0,
                provenanceBitmap: 0,
                latticeAnchor: testAnchor(),
                fingerprint: testFingerprint(),
                ts: 0.0
            )
            guard case .success(let rowId) = captureResult else {
                Issue.record("capture setup failed"); return
            }

            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            // Confirm the pending proposal → accepted.
            // Trust field: bits 18-23 (width 6), canonical = 3 → 3 << 18 = 786432.
            // Sensitivity must be ≤ elevated (16) for S-4; default 0 is fine.
            let acceptedAdj = Int64(RowState.accepted.rawValue)
                | (Int64(3) << 18)   // trust = canonical (satisfies S-1)
            _ = substrate.mutate(
                rowId: rowId,
                mutationKind: .confirm,
                newAdjectiveBitmap: acceptedAdj,
                ts: sentinelTs
            )

            let samples = sink.withName(SubstrateLibMetric.verbMutateCount)
            #expect(samples.count == 1,
                "exactly one verb.mutate_count expected; got \(samples.count)")

            if case let .metric(_, _, tags, _) = samples.first {
                #expect(tags["mutation_kind"] == "confirm",
                    "mutation_kind tag must be 'confirm'; got \(tags["mutation_kind"] ?? "nil")")
            }
        }
    }

    // MARK: - §6 AuditGate telemetry

    @Suite("§6 AuditGate / write-gate telemetry", .serialized)
    struct AuditGateTelemetry {

        /// emitAuditGateAdmit emits audit_gate.admit_count when enabled.
        /// Sentinel ts: 600_001.0
        @Test("emitAuditGateAdmit emits when monitoring is enabled")
        func emitAuditGateAdmitEmitsWhenEnabled() {
            let sentinelTs = 600_001.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            // Unit test of the emit helper directly.
            emitAuditGateAdmit(nounTypeRaw: "1", ts: sentinelTs)

            let samples = sink.withName(SubstrateLibMetric.auditGateAdmitCount)
            #expect(samples.count == 1,
                "one audit_gate.admit_count expected; got \(samples.count)")

            if case let .metric(name, value, tags, ts) = samples.first {
                #expect(name == SubstrateLibMetric.auditGateAdmitCount)
                #expect(value == 1.0)
                #expect(tags["noun_type"] == "1")
                #expect(ts == sentinelTs)
            } else {
                Issue.record("expected .metric for audit_gate.admit_count")
            }
        }

        /// emitAuditGateReject emits audit_gate.reject_count when enabled.
        /// Sentinel ts: 600_002.0
        @Test("emitAuditGateReject emits when monitoring is enabled")
        func emitAuditGateRejectEmitsWhenEnabled() {
            let sentinelTs = 600_002.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            emitAuditGateReject(violationName: "undeclaredField", ts: sentinelTs)

            let samples = sink.withName(SubstrateLibMetric.auditGateRejectCount)
            #expect(samples.count == 1,
                "one audit_gate.reject_count expected; got \(samples.count)")

            if case let .metric(_, _, tags, _) = samples.first {
                #expect(tags["violation"] == "undeclaredField",
                    "violation tag must be 'undeclaredField'; got \(tags["violation"] ?? "nil")")
            }
        }

        /// emitWriteGateAdmitted emits when enabled.
        /// Sentinel ts: 600_003.0
        @Test("emitWriteGateAdmitted emits when monitoring is enabled")
        func emitWriteGateAdmittedEmitsWhenEnabled() {
            let sentinelTs = 600_003.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            emitWriteGateAdmitted(verb: "capture", ts: sentinelTs)

            let samples = sink.withName(SubstrateLibMetric.writeGateAdmittedCount)
            #expect(samples.count == 1)
            if case let .metric(_, _, tags, _) = samples.first {
                #expect(tags["verb"] == "capture")
            }
        }

        /// emitWriteGateRejected emits when enabled.
        /// Sentinel ts: 600_004.0
        @Test("emitWriteGateRejected emits when monitoring is enabled")
        func emitWriteGateRejectedEmitsWhenEnabled() {
            let sentinelTs = 600_004.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            emitWriteGateRejected(verb: "mutate", reason: "illegalValue", ts: sentinelTs)

            let samples = sink.withName(SubstrateLibMetric.writeGateRejectedCount)
            #expect(samples.count == 1)
            if case let .metric(_, _, tags, _) = samples.first {
                #expect(tags["verb"] == "mutate")
                #expect(tags["reason"] == "illegalValue")
            }
        }

        /// All emit helpers are no-ops when monitoring is disabled.
        /// Sentinel ts: 600_005.0
        @Test("all emit helpers are no-ops when monitoring is disabled")
        func emitHelpersAreNoOpsWhenDisabled() {
            let sentinelTs = 600_005.0
            let sink = TsFilteredSink(ts: sentinelTs)
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            emitAuditGateAdmit(nounTypeRaw: "1", ts: sentinelTs)
            emitAuditGateReject(violationName: "test", ts: sentinelTs)
            emitWriteGateAdmitted(verb: "capture", ts: sentinelTs)
            emitWriteGateRejected(verb: "capture", reason: "test", ts: sentinelTs)
            emitVerbCaptureCount(nounTypeRaw: "1", ts: sentinelTs)
            emitVerbMutateCount(mutationKindToken: "confirm", ts: sentinelTs)
            emitVerbWithdrawCount(ts: sentinelTs)
            emitVerbExpungeCount(ts: sentinelTs)
            emitVerbRecallCount(resultCount: 0, ts: sentinelTs)
            emitVerbReanchorCount(ts: sentinelTs)

            #expect(sink.count == 0,
                "all helpers must be no-ops when monitoring is disabled; got \(sink.count)")
        }
    }

    // MARK: - §7 Metric name constants

    @Suite("§7 metric name constants", .serialized)
    struct MetricNames {

        @Test("all SubstrateLibMetric constants use the substratelib. prefix")
        func allMetricNamesHaveSubstratelibPrefix() {
            let allMetrics = [
                SubstrateLibMetric.auditGateAdmitCount,
                SubstrateLibMetric.auditGateRejectCount,
                SubstrateLibMetric.verbCaptureCount,
                SubstrateLibMetric.verbMutateCount,
                SubstrateLibMetric.verbWithdrawCount,
                SubstrateLibMetric.verbExpungeCount,
                SubstrateLibMetric.verbRecallCount,
                SubstrateLibMetric.verbReanchorCount,
                SubstrateLibMetric.writeGateAdmittedCount,
                SubstrateLibMetric.writeGateRejectedCount,
            ]
            for name in allMetrics {
                #expect(name.hasPrefix("substratelib."),
                    "metric '\(name)' must start with 'substratelib.'")
            }
        }

        @Test("all SubstrateLibMetric constants are non-empty dot-separated names")
        func allMetricNamesAreNonEmptyDotSeparated() {
            let allMetrics = [
                SubstrateLibMetric.auditGateAdmitCount,
                SubstrateLibMetric.auditGateRejectCount,
                SubstrateLibMetric.verbCaptureCount,
                SubstrateLibMetric.verbMutateCount,
                SubstrateLibMetric.verbWithdrawCount,
                SubstrateLibMetric.verbExpungeCount,
                SubstrateLibMetric.verbRecallCount,
                SubstrateLibMetric.verbReanchorCount,
                SubstrateLibMetric.writeGateAdmittedCount,
                SubstrateLibMetric.writeGateRejectedCount,
            ]
            for name in allMetrics {
                #expect(!name.isEmpty, "metric name must not be empty")
                #expect(name.contains("."),
                    "metric '\(name)' must be dot-separated")
            }
        }
    }
}
