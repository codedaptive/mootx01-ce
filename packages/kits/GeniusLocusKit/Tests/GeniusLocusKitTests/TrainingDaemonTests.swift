// TrainingDaemonTests.swift
//
// Mission GLK-07 — coverage for the threshold gate, the enrichment
// pipeline, and the training daemon registered against the GLK-04
// scheduler.

import Testing
import SubstrateTypes
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
@testable import GeniusLocusKit

@Suite("Training daemon")
struct TrainingDaemonTests {

    // MARK: - Fixtures

    /// Synthesize a unified-audit log of `n` capture entries. Each
    /// entry carries a `.bitmap` after-value so the enrichment pipeline
    /// has signal to fold into the matrix tier's F counts.
    private func makeCaptureLog(
        count n: Int,
        startingAtMillis start: Int64 = 1_000
    ) -> UnifiedAuditLog {
        var log = UnifiedAuditLog()
        for i in 0..<n {
            let hlc = HLC(
                physicalTime: start + Int64(i),
                logicalCount: 0, nodeID: 1)
            let entry = UnifiedAuditEntry(
                tier: .locus, hlc: hlc,
                verb: .capture,
                rowID: UUID(),
                fieldPath: "tag_bits",
                beforeValue: .null,
                afterValue: .bitmap(UInt64(1) << (i % 8)))
            log.add(entry)
        }
        return log
    }

    /// Mix of state-changing and pure-read verbs. Only the five
    /// state-changing verbs feed the transition count.
    private func makeMixedLog() -> (UnifiedAuditLog, transitions: Int) {
        var log = UnifiedAuditLog()
        let row = UUID()
        var t: Int64 = 1
        func add(verb: UnifiedAuditVerb, value: UnifiedAuditValue) {
            let hlc = HLC(physicalTime: t, logicalCount: 0, nodeID: 1)
            t += 1
            log.add(UnifiedAuditEntry(
                tier: .locus, hlc: hlc, verb: verb,
                rowID: row, fieldPath: "f",
                beforeValue: .null, afterValue: value))
        }
        // 5 state-changing verbs → transition count = 5
        add(verb: .capture,   value: .bitmap(0x01))
        add(verb: .mutate,    value: .bitmap(0x02))
        add(verb: .withdraw,  value: .null)
        add(verb: .expunge,   value: .null)
        add(verb: .reanchor,  value: .string("anchor-a"))
        // 6 read/derived verbs → ignored by the gate
        add(verb: .recall,        value: .null)
        add(verb: .propose,       value: .null)
        add(verb: .associate,     value: .null)
        add(verb: .learn,         value: .null)
        add(verb: .dreamCompact,  value: .null)
        add(verb: .migrate,       value: .null)
        return (log, 5)
    }

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
    }

    // MARK: - Gate

    @Test
    func gateDormantBelowThreshold() {
        let gate = TrainingThresholdGate(transitionThreshold: 10)
        let log = makeCaptureLog(count: 4)
        let decision = gate.decide(log: log)
        #expect(!decision.isActive)
        #expect(decision.transitionCount == 4)
        #expect(decision.threshold == 10)
        if case .dormant = decision {} else {
            Issue.record("expected dormant, got \(decision)")
        }
    }

    @Test
    func gateActiveAtThreshold() {
        let gate = TrainingThresholdGate(transitionThreshold: 5)
        let log = makeCaptureLog(count: 5)
        let decision = gate.decide(log: log)
        #expect(decision.isActive)
        #expect(decision.transitionCount == 5)
        #expect(decision.threshold == 5)
    }

    @Test
    func gateActiveAboveThreshold() {
        let gate = TrainingThresholdGate(transitionThreshold: 3)
        let log = makeCaptureLog(count: 12)
        #expect(gate.decide(log: log).isActive)
    }

    @Test
    func gateIgnoresReadOnlyVerbs() {
        let gate = TrainingThresholdGate(transitionThreshold: 5)
        let (log, transitions) = makeMixedLog()
        #expect(
            TrainingThresholdGate.transitionCount(in: log) == transitions,
            "only state-changing verbs feed the transition count")
        #expect(gate.decide(log: log).transitionCount == 5)
        #expect(gate.decide(log: log).isActive,
                "5 state-changing verbs meets threshold 5")
    }

    @Test
    func gateClampsNegativeThresholdToZero() {
        let gate = TrainingThresholdGate(transitionThreshold: -50)
        #expect(gate.transitionThreshold == 0)
        // Zero threshold always admits, even on an empty log.
        #expect(gate.decide(log: UnifiedAuditLog()).isActive)
    }

    @Test
    func provisionalDefaultMatchesDecisionRecord() {
        // the training transition threshold records the
        // provisional default at 500 transitions. The gate type
        // exposes that constant so callers can opt into the recommended
        // floor without hard-coding the number themselves.
        #expect(TrainingThresholdGate.provisionalDefault == 500)
        let gate = TrainingThresholdGate()
        #expect(gate.transitionThreshold == 500)
    }

    // MARK: - Enrichment pipeline

    @Test
    func enrichmentUpdatesMatricesFromAuditLog() {
        let log = makeCaptureLog(count: 8)
        var tier = MatrixTier()
        var calibration = MatrixCalibrationRegistry()
        let pipeline = EnrichmentPipeline()
        let result = pipeline.run(log: log,
                                  tier: &tier,
                                  calibration: &calibration)
        #expect(result.transitionsConsidered == 8)
        #expect(result.fCellsTouched > 0,
                "captures should land on the F matrix")
        #expect(tier.liveRowCount == 8,
                "every capture row contributes to liveRowCount")
        #expect(!tier.fieldPresence.isEmpty,
                "field presence should be non-empty after enrichment")
    }

    @Test
    func enrichmentRespectsAlreadyProcessedWatermark() {
        // First pass: enrich the first 4 captures. Second pass over
        // the full 8-entry log should add the new 4 only.
        let initialLog = makeCaptureLog(count: 4)
        var tier = MatrixTier()
        var calibration = MatrixCalibrationRegistry()
        let pipeline = EnrichmentPipeline()
        let first = pipeline.run(log: initialLog,
                                 tier: &tier,
                                 calibration: &calibration)
        #expect(first.transitionsConsidered == 4)
        let priorRowCount = tier.liveRowCount

        let fullLog = makeCaptureLog(count: 8)
        let second = pipeline.run(log: fullLog,
                                  tier: &tier,
                                  calibration: &calibration,
                                  highWaterMark: first.highWaterMark)
        #expect(second.transitionsConsidered == 4,
                "second pass should only see the tail entries")
        #expect(tier.liveRowCount == priorRowCount + 4)
    }

    // MARK: - Daemon

    @Test
    func daemonDormantBelowThresholdProducesNoMatrixWork() async {
        let log = makeCaptureLog(count: 3)
        var tier = MatrixTier()
        var calibration = MatrixCalibrationRegistry()
        let daemon = TrainingDaemon(
            gate: TrainingThresholdGate(transitionThreshold: 10))
        let tick = await daemon.runOnce(
            log: log,
            tier: &tier,
            calibration: &calibration)
        #expect(!tick.decision.isActive)
        #expect(tick.passResult.transitionsConsidered == 0,
                "dormant daemon must do no enrichment work")
        #expect(tier.fieldPresence.isEmpty)
        #expect(tier.liveRowCount == 0)
    }

    @Test
    func daemonActiveAtThresholdFiresPipeline() async {
        let log = makeCaptureLog(count: 12)
        var tier = MatrixTier()
        var calibration = MatrixCalibrationRegistry()
        let daemon = TrainingDaemon(
            gate: TrainingThresholdGate(transitionThreshold: 10))
        let tick = await daemon.runOnce(
            log: log,
            tier: &tier,
            calibration: &calibration)
        #expect(tick.decision.isActive)
        #expect(tick.passResult.transitionsConsidered == 12)
        #expect(tier.liveRowCount == 12)
    }

    @Test
    func daemonSchedulerRegistrationFiresOnlyWhenAdmitted() async throws {
        // Register the daemon as a standing signal with a short
        // interval, tick over time, and observe that a below-threshold
        // log does no enrichment while an above-threshold log does.
        // The signal's emit closure captures the daemon and shared
        // mutable state through reference-typed boxes.
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-training")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        defer {
            Task { try? await kit.close(handle) }
        }

        let logBox = AuditLogBox(log: makeCaptureLog(count: 6))
        let tierBox = MatrixTierBox()
        let calibrationBox = CalibrationBox()
        let daemon = TrainingDaemon(
            gate: TrainingThresholdGate(transitionThreshold: 10))

        let spec = SignalSpec(
            name: "training.daemon",
            trigger: .interval(seconds: 0.001),
            emit: { _ in
                let tick = await daemon.runOnce(
                    log: logBox.read(),
                    tier: &tierBox.value,
                    calibration: &calibrationBox.value)
                return [
                    .diagnostic(DiagnosticReport(
                        title: "training.daemon.tick",
                        detail: "transitions=\(tick.decision.transitionCount) " +
                                "active=\(tick.decision.isActive)",
                        observedAt: Date(timeIntervalSince1970: 0)))
                ]
            })

        let signalID = try await kit.registerStandingSignal(
            spec,
            in: handle,
            now: Date(timeIntervalSince1970: 0))

        // Tick 1 — log holds 6 transitions, threshold is 10 → dormant.
        try await kit.signalTick(
            in: handle,
            now: Date(timeIntervalSince1970: 60))
        #expect(tierBox.value.liveRowCount == 0,
                "below-threshold daemon must not enrich")

        // Push the log over the threshold and tick again — the daemon
        // crosses to active and the pipeline runs.
        logBox.replace(with: makeCaptureLog(count: 14))
        try await kit.signalTick(
            in: handle,
            now: Date(timeIntervalSince1970: 120))
        #expect(tierBox.value.liveRowCount == 14,
                "above-threshold daemon must enrich on the next tick")

        // The scheduler-registered daemon produced two diagnostic
        // emissions across the two ticks (one per tick); both surface
        // on the signal's report.
        let status = try await kit.signalStatus(in: handle)
        let report = status.first(where: { $0.signalID == signalID })
        #expect(report != nil)
        #expect(report?.emissionCount == 2,
                "daemon emits one diagnostic per tick regardless of gate state")
    }
}

// MARK: - Test scaffolding

/// Mutable box around an audit log so the spec closure (which captures
/// the box by reference) can observe log growth across ticks.
private final class AuditLogBox: @unchecked Sendable {
    private var current: UnifiedAuditLog
    init(log: UnifiedAuditLog) { self.current = log }
    func read() -> UnifiedAuditLog { current }
    func replace(with log: UnifiedAuditLog) { self.current = log }
}

/// Mutable box around a `MatrixTier`. The `&tierBox.value` syntax in
/// tests requires settable storage and `inout` is not legal across a
/// class boundary directly, so we expose `value` as a `var`.
private final class MatrixTierBox: @unchecked Sendable {
    var value: MatrixTier = MatrixTier()
}

private final class CalibrationBox: @unchecked Sendable {
    var value: MatrixCalibrationRegistry = MatrixCalibrationRegistry()
}
