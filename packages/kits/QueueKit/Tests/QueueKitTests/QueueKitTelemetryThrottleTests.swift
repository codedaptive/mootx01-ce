// QueueKitTelemetryThrottleTests.swift
//
// Verifies the 30-second emission throttle built into QueueLatencyWindowBox.
//
// Contract tested:
//   1. N drain ticks within the interval: only the first call returns shouldEmit=true.
//   2. A call at t >= lastEmission + interval returns shouldEmit=true (second emission).
//   3. The latency window keeps accumulating on every tick regardless of shouldEmit.
//
// These tests exercise QueueLatencyWindowBox.sample() directly — no Intellectus
// global state needed, so these tests are safe for concurrent execution with
// other suites.

import Testing
import Foundation
@testable import QueueKit

@Suite("QueueLatencyWindowBox emission throttle")
struct QueueKitTelemetryThrottleTests {

    // MARK: 1. Multiple ticks within interval: only first fires shouldEmit.

    @Test("N ticks within 30s interval → shouldEmit only on first tick")
    func multipleDrainTicksWithinIntervalEmitOnce() {
        let box = QueueLatencyWindowBox(capacity: 100)
        // First call: now=1000, lastEmission=0 → 1000-0=1000>=30 → shouldEmit=true.
        let (_, _, emit0) = box.sample(5.0, now: 1000.0, interval: 30.0)
        #expect(emit0, "first tick (t=1000, lastEmission=0) must fire shouldEmit")

        // Subsequent calls within 30s of t=1000 must NOT fire.
        var extraEmissions = 0
        for offset in stride(from: 1.0, to: 30.0, by: 1.0) {
            let (_, _, emit) = box.sample(5.0, now: 1000.0 + offset, interval: 30.0)
            if emit { extraEmissions += 1 }
        }
        #expect(extraEmissions == 0,
            "ticks within 30s of last emission must NOT set shouldEmit; got \(extraEmissions) extra")
    }

    // MARK: 2. A tick at or past the interval boundary fires the second emission.

    @Test("Tick at t=lastEmission+30.1 crosses boundary and fires second shouldEmit")
    func tickAtIntervalBoundaryFiresSecondEmission() {
        let box = QueueLatencyWindowBox(capacity: 100)

        // First emission at t=1000.
        let (_, _, emit0) = box.sample(5.0, now: 1000.0, interval: 30.0)
        #expect(emit0, "first tick must fire")

        // Just before boundary: t=1029.9 → 1029.9 - 1000 = 29.9 < 30 → no emit.
        let (_, _, emitBefore) = box.sample(5.0, now: 1029.9, interval: 30.0)
        #expect(!emitBefore, "t=1029.9 is still within the 30s window (29.9s elapsed)")

        // At boundary: t=1030.1 → 1030.1 - 1000 = 30.1 >= 30 → emit.
        let (_, _, emitAt) = box.sample(5.0, now: 1030.1, interval: 30.0)
        #expect(emitAt, "t=1030.1 crosses the 30s boundary — second emission must fire")
    }

    // MARK: 3. Window keeps accumulating between emissions.

    @Test("Latency window accumulates every tick even when shouldEmit=false")
    func windowAccumulatesOnNonEmittingTicks() {
        let box = QueueLatencyWindowBox(capacity: 100)

        // Emit at t=1000 with one sample (100ms).
        let (p50First, _, _) = box.sample(100.0, now: 1000.0, interval: 30.0)
        // With one sample p50 ≈ 100.
        #expect(p50First == 100.0)

        // Add several non-emitting samples (0ms each) within the interval.
        // The window should update its state; p50 should drop toward 0.
        for i in 1...10 {
            _ = box.sample(0.0, now: 1000.0 + Double(i), interval: 30.0)
        }

        // Force emission at t=1031 (past the 30s window). p50 should reflect
        // the accumulated 0ms samples (11 samples of 0ms vs 1 sample of 100ms).
        let (p50Second, _, emitSecond) = box.sample(0.0, now: 1031.0, interval: 30.0)
        #expect(emitSecond, "t=1031 must cross boundary and fire second emission")
        // 11 zeros + 1 hundred: p50 of 12 values sorted = the 6th (0-indexed: values[5]) = 0.
        #expect(p50Second < 100.0,
            "p50 must reflect accumulated 0ms samples; expected < 100, got \(p50Second)")
    }
}
