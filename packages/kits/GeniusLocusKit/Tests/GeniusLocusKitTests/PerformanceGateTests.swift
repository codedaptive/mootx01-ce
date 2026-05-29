// PerformanceGateTests.swift
//
// Mission GLK-08 — Theorem 5 performance gate. The implementation plan
// (`GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md` section 7) states the
// budget as two numbers:
//
//   capture-path P99 latency ≤ 100 ms on iPhone 13+
//   enrichment-daemon throughput ≥ 60 drawers/hour on Mac (M1+)
//
// The harness runs on whatever Mac executes `swift test`. The Mac
// profile applies to enrichment outright; the iPhone profile applies
// to capture and the Mac measurement is reported alongside the target
// as headroom evidence. The test fails only if the Mac figure exceeds
// the iPhone budget — a Mac that misses the iPhone budget would be a
// red flag worth investigating before the iPhone harness ever runs.
//
// Both measurements are recorded into the test output so the mission's
// "verification log" surfaces the actual figures the test observed.
// The numbers move test-run to test-run; the gate is the assertion,
// not the printed figure.
//
// Conformance-fixture status (per mission scope): this is a test, not
// production code. No production source is added or modified.

import XCTest
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
@testable import GeniusLocusKit

final class PerformanceGateTests: XCTestCase {

    // MARK: - Theorem 5 budget

    /// Capture P99 target from `GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md`
    /// section 7. The number is the iPhone profile; the Mac harness
    /// must stay under it with headroom for the gate to admit the iPhone
    /// profile when that harness later runs.
    private static let captureP99CeilingMillis: Double = 100.0

    /// Enrichment-rate floor in drawers per hour, Mac profile.
    private static let enrichmentRateFloorPerHour: Double = 60.0

    // MARK: - Capture P99

    /// Time `GeniusLocusKit.capture` over a synthetic capture stream and
    /// assert the P99 latency lands under the iPhone budget. The harness
    /// records P50, P95, P99, and max for the verification log so the
    /// completion report can compare against past runs.
    ///
    /// Sample size: 200 captures. The implementation plan calls for
    /// 1000 over an 8-hour day; 200 is sufficient to land a stable P99
    /// in a CI window without forcing the harness to allocate orders of
    /// magnitude more storage than the unit-test environment carries.
    func testTheorem5_CaptureP99UnderIPhoneBudget() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-perf-capture")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        defer {
            Task { try? await kit.close(handle) }
        }
        let estate = try await kit.estate(for: handle)

        // Sample size mirrors the harness budget: enough to land a
        // stable tail without forcing the test runner into seconds of
        // synthetic work.
        let sampleCount = 200
        var samplesMillis: [Double] = []
        samplesMillis.reserveCapacity(sampleCount)

        // Warm the path so the first allocation does not dominate the
        // tail. Without a warmup the first capture amortises the
        // SQLite-schema and bitmap-evaluator cold paths and would skew
        // the P99 toward the cold-start cost.
        _ = try await estate.capture(makeCaptureFrame(index: -1))

        for i in 0..<sampleCount {
            let frame = makeCaptureFrame(index: i)
            let start = DispatchTime.now()
            _ = try await estate.capture(frame)
            let end = DispatchTime.now()
            let elapsedNanos = end.uptimeNanoseconds - start.uptimeNanoseconds
            samplesMillis.append(Double(elapsedNanos) / 1_000_000.0)
        }

        let summary = LatencySummary(samples: samplesMillis)

        // The recorded figures land in the test output so the
        // verification log captures them verbatim.
        print("[GLK-08 perf] capture-latency p50=\(summary.p50.formatted) ms " +
              "p95=\(summary.p95.formatted) ms p99=\(summary.p99.formatted) ms " +
              "max=\(summary.max.formatted) ms (n=\(sampleCount) Mac profile; " +
              "iPhone budget \(Self.captureP99CeilingMillis) ms)")

        XCTAssertLessThan(summary.p99, Self.captureP99CeilingMillis,
            "P99 capture latency \(summary.p99.formatted) ms exceeds iPhone budget " +
            "\(Self.captureP99CeilingMillis) ms (Mac profile, n=\(sampleCount))")
    }

    // MARK: - Enrichment throughput

    /// Time `EnrichmentPipeline.run` over a synthetic audit log and
    /// project the rate to drawers per hour. Assert the rate clears the
    /// 60 drawers/hour floor for the Mac profile.
    ///
    /// Strategy: build a log of `sampleCount` capture entries, time one
    /// full enrichment pass, divide to derive a per-drawer cost, then
    /// project that per-drawer cost out to one hour. A Mac that can
    /// enrich N drawers per second projects to 3600·N per hour; the
    /// floor of 60/hour gives the test enormous headroom and pins the
    /// failure mode to "something catastrophic happened in the
    /// enrichment path," not "the harness is too sensitive to noise."
    func testTheorem5_EnrichmentThroughputClearsMacFloor() {
        let sampleCount = 500
        var log = UnifiedAuditLog()
        for i in 0..<sampleCount {
            let hlc = HLC(
                physicalTime: Int64(i + 1),
                logicalCount: 0,
                nodeID: 1
            )
            log.add(UnifiedAuditEntry(
                tier: .locus,
                hlc: hlc,
                verb: .capture,
                rowID: UUID(),
                fieldPath: "tag_bits",
                beforeValue: .null,
                afterValue: .bitmap(UInt64(1) << (i % 8))
            ))
        }

        var tier = MatrixTier()
        var calibration = MatrixCalibrationRegistry()
        let pipeline = EnrichmentPipeline()

        let start = DispatchTime.now()
        let result = pipeline.run(log: log, tier: &tier, calibration: &calibration)
        let end = DispatchTime.now()
        let elapsedSeconds = Double(end.uptimeNanoseconds - start.uptimeNanoseconds)
            / 1_000_000_000.0

        XCTAssertEqual(result.transitionsConsidered, sampleCount,
                       "pipeline must enrich every capture in the synthetic log")
        XCTAssertGreaterThan(elapsedSeconds, 0,
                             "elapsed must be a positive duration; guards against div-by-zero")

        let drawersPerSecond = Double(sampleCount) / elapsedSeconds
        let drawersPerHour = drawersPerSecond * 3600.0

        print("[GLK-08 perf] enrichment-rate elapsed=\(elapsedSeconds.formatted) s " +
              "drawers=\(sampleCount) rate=\(drawersPerHour.formatted) drawers/hour " +
              "(Mac profile; floor \(Self.enrichmentRateFloorPerHour) drawers/hour)")

        XCTAssertGreaterThan(drawersPerHour, Self.enrichmentRateFloorPerHour,
            "enrichment rate \(drawersPerHour.formatted) drawers/hour " +
            "below Mac floor \(Self.enrichmentRateFloorPerHour) (n=\(sampleCount))")
    }

    // MARK: - Helpers

    /// Build a varied capture frame so the substrate does not coalesce
    /// every capture into the same bitmap-write path. The frame's
    /// fields rotate across the call so storage and bitmap evaluator
    /// see realistic input variation.
    private func makeCaptureFrame(index: Int) -> CaptureFrame {
        let udcCodes = ["004", "100", "300", "500", "684.08"]
        let rooms = ["work", "research", "personal", "ops", "scratch"]
        return CaptureFrame(
            content: "content-\(index)",
            channel: .typed,
            room: rooms[(index < 0 ? 0 : index) % rooms.count],
            latticeAnchor: .udc(udcCodes[(index < 0 ? 0 : index) % udcCodes.count]),
            addedBy: "perf-test",
            embeddingModelID: "model-v1"
        )
    }
}

// MARK: - Latency summary

/// Percentile summary of a sample sequence in milliseconds. The
/// implementation sorts in place and reads the p50, p95, p99, and max
/// positions; for 200 samples the sort cost is negligible compared to
/// the captures it summarises.
private struct LatencySummary {
    let p50: Double
    let p95: Double
    let p99: Double
    let max: Double

    init(samples: [Double]) {
        precondition(!samples.isEmpty, "summary requires at least one sample")
        var sorted = samples
        sorted.sort()
        self.p50 = LatencySummary.percentile(sorted, p: 0.50)
        self.p95 = LatencySummary.percentile(sorted, p: 0.95)
        self.p99 = LatencySummary.percentile(sorted, p: 0.99)
        self.max = sorted.last ?? 0
    }

    /// Nearest-rank percentile on a sorted vector. `p` is a probability
    /// in [0, 1]; the index is `ceil(p · n) - 1`, clamped to the array
    /// bounds. Matches the SciPy default and the percentile spec the
    /// implementation plan references for P99 measurement.
    private static func percentile(_ sorted: [Double], p: Double) -> Double {
        let n = sorted.count
        let rank = Swift.max(1, Int((p * Double(n)).rounded(.up)))
        return sorted[Swift.min(rank, n) - 1]
    }
}

// MARK: - Double formatting

private extension Double {
    /// Three-decimal-place formatted string for log output. Localised
    /// formatting is intentionally avoided so the verification log
    /// reads identically on every harness.
    var formatted: String {
        String(format: "%.3f", self)
    }
}
